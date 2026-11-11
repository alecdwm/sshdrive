import Foundation
import SSHProcess

/// One remote server, in process: one filesystem served over SFTP and over exec channels,
/// an `sshd` that accepts or refuses connections, a link that can go down or half-open,
/// and a clock of its own (docs/design/testing.md).
///
/// The filesystem is a `FakeSFTPServer`, so the SFTP side is the real v3 wire. The exec
/// side answers the scripts the agent actually sends - the server probe, the helper's
/// interrogation, `date +%s`, the tier 1 sweep and the tier 2 helper stream - by reading
/// the `RemoteScript` it was handed and evaluating it against the same tree: a file the
/// deployment uploads over SFTP is the file `sha256sum` hashes, and a file a scenario
/// changes is seen by a listing, by a sweep and by the helper stream alike.
///
/// Everything time-shaped runs on `clock`: read deadlines, the helper's `ready` delay and
/// heartbeat, the wrapper's 60 s watchdog, `ServerAliveInterval`, and the server's own
/// wall clock (`serverNow`), which can be set apart from the Mac's.
///
/// What a connect attempt meets is decided by `connect()`, which `FakeHostLauncher`
/// (in `AgentRuntimeTestSupport`) turns into the same `SSHProcessError` an `ssh -N`
/// would have produced, classified by the real `SSHExitClassifier`.
public final class FakeRemoteHost: @unchecked Sendable {

    // MARK: Types

    /// What an exec channel was asked to run, recognised from the `RemoteScript` itself.
    public enum ScriptKind: String, Sendable, CaseIterable {
        case probe, interrogate, serverTime, sweep, helper, unknown
    }

    /// The state of the helper's cache directory, as the probe's `mkdir`/write/exec test
    /// would find it.
    public enum CacheDirectoryState: String, Sendable {
        case exec, noexec, unwritable, nodir
    }

    /// The network between the Mac and the server.
    public enum LinkState: String, Sendable {
        case up
        /// No route: connects fail at once with `Network is unreachable`.
        case unreachable
        /// Packets vanish: connects time out after `ConnectTimeout`.
        case blackhole
    }

    /// The server's `sshd`.
    public enum SSHDState: String, Sendable {
        case running
        /// Restarting or down: `Connection refused` at once.
        case refusing
        /// TCP is accepted and the banner never comes.
        case bannerHang
    }

    /// How an exec channel is refused.
    public enum ExecRefusal: String, Sendable {
        /// `MaxSessions` reached: `session request failed`.
        case sessionLimit
        /// A `ForceCommand internal-sftp` account's sentence.
        case noShell
        /// The sentinel never arrives.
        case unusable
    }

    /// One connect attempt's fate, for a scenario that scripts a sequence of them.
    public enum ConnectOutcome: Sendable, Equatable {
        case succeed
        /// `ssh` exits `status` after `after` seconds with this stderr.
        case fail(stderr: String, after: Double = 0, status: Int32 = 255)
        /// The key agent's socket is not there yet; `ssh` is never run.
        case keyAgentNotReady
        /// Nothing answers until the 60 s authentication deadline.
        case authenticationDeadline
    }

    /// What `connect()` hands the launcher.
    public enum ConnectResult {
        case connected(FakeHostMaster)
        case failed(stderr: String, status: Int32, after: Double)
        /// `ssh` raised a password prompt, sent the answer, and the server refused it.
        case passwordRefused(stderr: String)
        case keyAgentNotReady
        case authenticationDeadline(after: Double)
    }

    /// One connect attempt, for the bounded-effort check.
    public struct Attempt: Sendable {
        /// The Mac's wall clock, comparable with the replica's call times.
        public var at: Double
        /// The server's clock, which a jump of the Mac's wall clock does not move: what a
        /// rate is measured on.
        public var serverAt: Double
        public var outcome: String
        public var succeeded: Bool
    }

    /// One change a scenario made on the server, with the server time it was made at.
    public struct Mutation: Sendable {
        public var at: Double
        public var kind: FakeSFTPServer.Change.Kind
        /// Relative to the location root.
        public var path: String
        public var from: String?
    }

    // MARK: Identity

    public let sftp: FakeSFTPServer
    public let clock: any TimeSource
    /// The canonical location root, absolute.
    public let root: String
    public let hostName: String
    public let user: String
    public let uid: UInt32
    public let gid: UInt32

    private let lock = NSLock()
    private var _profile: ServerProfile

    public var profile: ServerProfile {
        get { lock.withLock { _profile } }
        set { lock.withLock { _profile = newValue } }
    }

    public init(
        profile: ServerProfile = .debian, root: String? = nil, hostName: String = "nas",
        user: String = "alec", uid: UInt32 = 1000, gid: UInt32 = 1000,
        clock: any TimeSource
    ) {
        self._profile = profile
        self.clock = clock
        self.hostName = hostName
        self.user = user
        self.uid = uid
        self.gid = gid
        let root = root ?? "\(profile.home)/data"
        self.root = root
        self.sftp = FakeSFTPServer(profile: profile, root: root)
        self._maxSessions = profile.maxSessions
        self._serverClockOffset = profile.clockOffset
        sftp.realpathRequiresExistence = true
        // Every directory above the root, so `mkdir` of the helper's cache directory
        // under `$HOME` has a parent to land in.
        var parent = ""
        for component in (root as NSString).deletingLastPathComponent.split(separator: "/") {
            parent += "/\(component)"
            sftp.putDirectory(parent)
        }
        if !profile.home.isEmpty, sftp.node(profile.home) == nil {
            sftp.putDirectory(profile.home)
        }
        sftp.clock = { [weak self] in Int64(self?.serverNow ?? 0) }
        sftp.onChange = { [weak self] changes in self?.treeChanged(changes) }
    }

    // MARK: The server's clock

    private var _serverClockOffset: Double

    /// How far the server's wall clock is from the Mac's, in seconds. Positive is ahead.
    public var serverClockOffset: Double {
        get { lock.withLock { _serverClockOffset } }
        set { lock.withLock { _serverClockOffset = newValue } }
    }

    /// The server's own `date +%s`, with a fraction.
    public var serverNow: Double { clock.now() + serverClockOffset }

    // MARK: Activity

    private var _activity = 0

    /// Bumped on every byte, open, exit and attempt, so a harness can tell a quiet host
    /// from a busy one.
    public var activity: Int { lock.withLock { _activity } }

    func noteActivity() { lock.withLock { _activity += 1 } }

    // MARK: Server-side changes

    private var _journal: [Mutation] = []

    /// Every change made through the methods below, oldest first.
    public var journal: [Mutation] { lock.withLock { _journal } }

    private func note(_ kind: FakeSFTPServer.Change.Kind, _ path: String, from: String? = nil) {
        let at = serverNow
        lock.withLock { _journal.append(Mutation(at: at, kind: kind, path: path, from: from)) }
    }

    /// Creates or overwrites a file, stamped with the server's clock. Paths are relative
    /// to the location root unless they start with `/`.
    @discardableResult
    public func writeFile(_ path: String, contents: Data = Data(), mode: UInt32? = nil) -> Bool {
        let existed = sftp.node(path) != nil
        guard sftp.writeFile(path, contents: contents, mode: mode, at: Int64(serverNow)) else {
            return false
        }
        note(existed ? .modify : .create, path)
        return true
    }

    @discardableResult
    public func writeFile(_ path: String, text: String) -> Bool {
        writeFile(path, contents: Data(text.utf8))
    }

    @discardableResult
    public func makeDirectory(_ path: String) -> Bool {
        guard sftp.makeDirectory(path, at: Int64(serverNow)) else { return false }
        note(.create, path)
        return true
    }

    /// `chmod`, which moves the ctime and not the mtime.
    @discardableResult
    public func changeMode(_ path: String, to mode: UInt32) -> Bool {
        guard sftp.changeMode(path, to: mode, at: Int64(serverNow)) else { return false }
        note(.modify, path)
        return true
    }

    /// `rm -rf`.
    @discardableResult
    public func delete(_ path: String) -> Bool {
        guard sftp.removeTree(path, at: Int64(serverNow)) else { return false }
        note(.delete, path)
        return true
    }

    /// `mv`.
    @discardableResult
    public func rename(_ from: String, to: String) -> Bool {
        guard sftp.moveNode(from, to: to, at: Int64(serverNow)) else { return false }
        note(.rename, to, from: from)
        return true
    }

    public func exists(_ path: String) -> Bool { sftp.exists(path) }
    public func node(_ path: String) -> FakeSFTPServer.Node? { sftp.node(path) }

    // MARK: Capabilities

    private var _maxSessions: Int
    private var _extraSessions = 0
    private var _cacheState: CacheDirectoryState = .exec
    private var _helpers: [String: (version: String, os: String, arch: String)] = [:]

    /// `MaxSessions`, enforced on every channel open of every master.
    public var maxSessions: Int {
        get { lock.withLock { _maxSessions } }
        set { lock.withLock { _maxSessions = newValue } }
    }

    /// Sessions something else holds against the limit on every connection, which is how
    /// a scenario makes the channel probe meet a full server without changing the limit.
    public var extraSessionsHeld: Int {
        get { lock.withLock { _extraSessions } }
        set { lock.withLock { _extraSessions = newValue } }
    }

    public var cacheDirectoryState: CacheDirectoryState {
        get { lock.withLock { _cacheState } }
        set { lock.withLock { _cacheState = newValue } }
    }

    /// `${XDG_CACHE_HOME:-$HOME/.cache}/sshdrive`, as the probe spells it.
    public var cacheDirectory: String { "\(profile.home)/.cache/sshdrive" }

    /// Registers the bytes of a helper build: a file with this SHA-256 runs, and prints
    /// `sshdrive-helper <version> <os>/<arch> sha256=<digest of itself>` for `--version`.
    /// Any other file in the cache directory is not a helper and does not run.
    public func registerHelperBinary(_ bytes: Data, version: String, os: String, arch: String) {
        let digest = SHA256Digest.hex(bytes)
        lock.withLock { _helpers[digest] = (version, os, arch) }
    }

    /// The reboot that empties `~/.cache`, or a user who cleared it.
    public func wipeHelperCache() {
        _ = sftp.removeTree(cacheDirectory, at: Int64(serverNow))
    }

    /// What `--version` prints for the file at `path`, or nil when it would not run.
    func helperVersionLine(at path: String) -> String? {
        guard let node = sftp.node(path), node.type == .file, node.mode & 0o100 != 0,
            cacheDirectoryState == .exec
        else { return nil }
        let digest = SHA256Digest.hex(node.contents)
        guard let build = lock.withLock({ _helpers[digest] }) else { return nil }
        return "sshdrive-helper \(build.version) \(build.os)/\(build.arch) sha256=\(digest)"
    }

    // MARK: Faults: the link and sshd

    private var _link: LinkState = .up
    private var _sshd: SSHDState = .running
    private var _authFailures = 0
    private var _authStderr = ""
    private var _passwordRefusals = 0
    private var _hostKeyFailure = false
    private var _dnsFailures = 0
    private var _outcomes: [ConnectOutcome] = []
    private var _serverAlive = true

    public var link: LinkState { lock.withLock { _link } }
    public var sshd: SSHDState {
        get { lock.withLock { _sshd } }
        set { lock.withLock { _sshd = newValue } }
    }

    /// Emulates `ServerAliveInterval 15` / `ServerAliveCountMax 2`: a master whose
    /// connection has carried nothing for 45 s exits `Timeout, server … not responding.`
    public var serverAliveKills: Bool {
        get { lock.withLock { _serverAlive } }
        set { lock.withLock { _serverAlive = newValue } }
    }

    public static let serverAliveSeconds: Double = 45
    /// `ConnectTimeout=15`, which bounds the TCP connect and the banner exchange.
    public static let connectTimeoutSeconds: Double = 15

    /// Takes the link down or up. Down stalls every live connection (a master whose link
    /// went is half-open until `ServerAliveInterval` gives up on it) and fails or times out
    /// every new connect; up resumes whatever is still alive.
    public func setLink(_ state: LinkState) {
        lock.withLock { _link = state }
        for master in liveMasters {
            master.setLinkStalled(state != .up)
        }
    }

    /// The next `count` connects are refused `Permission denied (publickey)`.
    public func failAuthentication(times count: Int, stderr: String? = nil) {
        lock.withLock {
            _authFailures = count
            _authStderr = stderr ?? "\(user)@\(hostName): Permission denied (publickey)."
        }
    }

    /// The next `count` connects get past every key, are asked for a password and have
    /// the answer refused: the password in the keychain is stale.
    public func refusePassword(times count: Int) { lock.withLock { _passwordRefusals = count } }

    /// A server whose host key does not match `known_hosts`, until set back.
    public func failHostKey(_ value: Bool) { lock.withLock { _hostKeyFailure = value } }

    /// The next `count` connects fail to resolve the host name.
    public func failNameResolution(times count: Int) { lock.withLock { _dnsFailures = count } }

    /// Outcomes for the next attempts, in order, ahead of every other rule.
    public func enqueueConnectOutcomes(_ outcomes: [ConnectOutcome]) {
        lock.withLock { _outcomes.append(contentsOf: outcomes) }
    }

    public func clearConnectOutcomes() { lock.withLock { _outcomes.removeAll() } }

    // MARK: Faults: live connections

    /// Every live master dies now, as a server reboot or a `kill -9` of the client does.
    public func severConnections(stderr: String? = nil) {
        let text = stderr ?? "Connection to \(hostName) closed by remote host."
        for master in liveMasters { master.die(stderr: text) }
    }

    /// The connections that are up go silent while new ones work: a Mac that slept with
    /// no will-sleep message wakes to a TCP connection the server already forgot.
    public func stallLiveConnections() {
        for master in liveMasters { master.setSelfStalled(true) }
    }

    public func resumeLiveConnections() {
        for master in liveMasters { master.setSelfStalled(false) }
    }

    // MARK: Faults: channels and scripts

    private var _execRefusal: (kind: ExecRefusal, remaining: Int?)?
    private var _scriptStalls: [ScriptKind: Int?] = [:]
    private var _stalledSFTPOrdinals: Set<Int> = []
    private var _helperReadyDelay: Double = 0.5
    private var _helperNeverReady = false

    /// Refuses exec channels: all of them, or the next `count`.
    public func refuseExec(_ kind: ExecRefusal, count: Int? = nil) {
        lock.withLock { _execRefusal = (kind, count) }
    }

    public func clearExecRefusal() { lock.withLock { _execRefusal = nil } }

    /// Opens the channel and then never answers, for this kind of script: all of them, or
    /// the next `count`. The sweep variant prints the server time and then hangs, as a
    /// `find` stuck on an NFS mount does.
    public func stallScript(_ kind: ScriptKind, count: Int? = nil) {
        lock.withLock { _scriptStalls[kind] = .some(count) }
    }

    public func clearScriptStalls() { lock.withLock { _scriptStalls.removeAll() } }

    /// The SFTP channels, by their 1-based order on each master, that open and then never
    /// answer - 2 and 3 are the channel probe's.
    public var stalledSFTPChannelOrdinals: Set<Int> {
        get { lock.withLock { _stalledSFTPOrdinals } }
        set { lock.withLock { _stalledSFTPOrdinals = newValue } }
    }

    /// How long the helper takes between starting and its `ready` line, which is its
    /// first walk of the root set.
    public var helperReadyDelay: Double {
        get { lock.withLock { _helperReadyDelay } }
        set { lock.withLock { _helperReadyDelay = newValue } }
    }

    private var _helperRootsWalkSeconds: Double = 0

    /// How long a running helper takes to apply a new root set, during which it writes
    /// nothing at all - no events, no heartbeat - as a helper re-walking a large tree with
    /// no heartbeat inside the walk does. Events that happen meanwhile are written when
    /// the walk ends.
    public var helperRootsWalkSeconds: Double {
        get { lock.withLock { _helperRootsWalkSeconds } }
        set { lock.withLock { _helperRootsWalkSeconds = newValue } }
    }

    /// A helper that starts and never says `ready`.
    public var helperNeverReady: Bool {
        get { lock.withLock { _helperNeverReady } }
        set { lock.withLock { _helperNeverReady = newValue } }
    }

    /// Kills every running helper while its connection stays up.
    public func killHelpers() {
        for process in helperProcesses { process.kill() }
    }

    /// Every helper running now stops producing output for good - no events, no
    /// heartbeat - while its wrapper stays alive and keeps reading the agent's heartbeats:
    /// a helper stuck in uninterruptible sleep on a hung filesystem. Helpers started later
    /// are not affected.
    public func freezeHelpers() {
        for process in helperProcesses { process.freeze() }
    }

    private var _stalledScripts: [OneShotProcess] = []

    func noteStalled(_ process: OneShotProcess) {
        lock.withLock { _stalledScripts.append(process) }
    }

    func forgetStalled(_ process: OneShotProcess) {
        lock.withLock { _stalledScripts.removeAll { $0 === process } }
    }

    /// Every script stalled by `stallScript` that is still waiting finishes now and prints
    /// what it would have printed: the NFS server came back and the `find` stuck on it
    /// completes. A script the agent already gave up on has nobody left to read it.
    public func resumeStalledScripts() {
        let stalled = lock.withLock { () -> [OneShotProcess] in
            defer { _stalledScripts.removeAll() }
            return _stalledScripts
        }
        for process in stalled { process.resume() }
    }

    private var hiddenRoot: [Data: FakeSFTPServer.Node]?

    /// The root stops resolving: an autofs mount that is not there yet, a dataset that is
    /// locked. Nothing is deleted.
    public func hideRoot() {
        let taken = sftp.detachTree(root)
        lock.withLock { hiddenRoot = taken }
    }

    public func restoreRoot() {
        guard let taken = lock.withLock({ () -> [Data: FakeSFTPServer.Node]? in
            defer { hiddenRoot = nil }
            return hiddenRoot
        }) else { return }
        sftp.attachTree(taken)
    }

    /// A full disk: every SFTP write fails with a bare `FAILURE` and `statvfs` says why.
    public func setDiskFull(_ full: Bool) { sftp.availableBlocks = full ? 0 : 100_000 }

    // MARK: Faults at a moment

    /// A moment in the agent's own sequence, for a fault that has to land inside it: the
    /// connection dropping during the reconnect sequence, or mid-way through the helper's
    /// upload.
    public enum Trigger: Sendable, Equatable {
        /// An exec channel for this kind of script has just opened.
        case scriptOpened(ScriptKind)
        /// The `ordinal`th SFTP channel of a master has just opened.
        case sftpChannelOpened(ordinal: Int)
        /// Something changed a path containing this text: an upload's first write, say.
        case treeChange(pathContaining: String)
        /// An SFTP extended request with this name (`statvfs@openssh.com`, say) has
        /// arrived on any channel, before it is answered.
        case sftpExtended(name: String)
    }

    private var _severTriggers: [(trigger: Trigger, stderr: String?)] = []

    /// Severs every live connection the first time `trigger` happens. One-shot.
    public func sever(when trigger: Trigger, stderr: String? = nil) {
        lock.withLock { _severTriggers.append((trigger, stderr)) }
    }

    /// Fires every armed trigger that matches.
    func fire(_ happened: (Trigger) -> Bool) {
        let fired = lock.withLock { () -> [(trigger: Trigger, stderr: String?)] in
            let matching = _severTriggers.filter { happened($0.trigger) }
            _severTriggers.removeAll { happened($0.trigger) }
            return matching
        }
        for entry in fired { severConnections(stderr: entry.stderr) }
    }

    // MARK: Timed faults

    private var timers: [Task<Void, Never>] = []

    /// Runs `body` after `seconds` on the host's clock. For a fault with a duration:
    /// turn it on now, and schedule the call that turns it off.
    public func after(_ seconds: Double, _ body: @escaping @Sendable () -> Void) {
        let clock = self.clock
        let task = Task {
            await clock.sleep(seconds: seconds)
            guard !Task.isCancelled else { return }
            body()
        }
        lock.withLock { timers.append(task) }
    }

    // MARK: Connecting

    private var _masters: [FakeHostMaster] = []
    private var _attempts: [Attempt] = []

    /// Every master ever handed out, oldest first.
    public var masters: [FakeHostMaster] { lock.withLock { _masters } }
    public var liveMasters: [FakeHostMaster] { masters.filter(\.alive) }
    public var attempts: [Attempt] { lock.withLock { _attempts } }

    /// One `ssh -N`'s fate.
    public func connect() -> ConnectResult {
        noteActivity()
        let now = clock.now()
        let result: ConnectResult = lock.withLock {
            if !_outcomes.isEmpty {
                switch _outcomes.removeFirst() {
                case .succeed: break
                case let .fail(stderr, after, status):
                    return .failed(stderr: stderr, status: status, after: after)
                case .keyAgentNotReady:
                    return .keyAgentNotReady
                case .authenticationDeadline:
                    return .authenticationDeadline(after: 60)
                }
            } else {
                if _dnsFailures > 0 {
                    _dnsFailures -= 1
                    return .failed(
                        stderr: "ssh: Could not resolve hostname \(hostName): nodename nor servname provided, or not known\r\n",
                        status: 255, after: 0)
                }
                switch _link {
                case .up: break
                case .unreachable:
                    return .failed(
                        stderr: "ssh: connect to host \(hostName) port 22: Network is unreachable\r\n",
                        status: 255, after: 0)
                case .blackhole:
                    return .failed(
                        stderr: "ssh: connect to host \(hostName) port 22: Operation timed out\r\n",
                        status: 255, after: Self.connectTimeoutSeconds)
                }
                switch _sshd {
                case .running: break
                case .refusing:
                    return .failed(
                        stderr: "ssh: connect to host \(hostName) port 22: Connection refused\r\n",
                        status: 255, after: 0)
                case .bannerHang:
                    return .failed(
                        stderr: "Connection timed out during banner exchange\r\nConnection to \(hostName) port 22 timed out\r\n",
                        status: 255, after: Self.connectTimeoutSeconds)
                }
                if _hostKeyFailure {
                    return .failed(
                        stderr: """
                            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
                            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
                            Host key for \(hostName) has changed and you have requested strict checking.
                            Host key verification failed.\r\n
                            """,
                        status: 255, after: 0)
                }
                if _passwordRefusals > 0 {
                    _passwordRefusals -= 1
                    return .passwordRefused(
                        stderr: "\(user)@\(hostName): Permission denied (publickey,password).\r\n")
                }
                if _authFailures > 0 {
                    _authFailures -= 1
                    return .failed(stderr: _authStderr + "\r\n", status: 255, after: 0)
                }
            }
            let master = FakeHostMaster(host: self, ordinal: _masters.count + 1)
            _masters.append(master)
            return .connected(master)
        }
        let serverAt = now + serverClockOffset
        let record: Attempt
        switch result {
        case .connected(let master):
            record = Attempt(
                at: now, serverAt: serverAt, outcome: "connected (master \(master.ordinal))",
                succeeded: true)
        case .failed(let stderr, _, let after):
            record = Attempt(
                at: now, serverAt: serverAt,
                outcome: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    + (after > 0 ? " (after \(Int(after)) s)" : ""),
                succeeded: false)
        case .passwordRefused(let stderr):
            record = Attempt(
                at: now, serverAt: serverAt,
                outcome: "password refused: " + stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                succeeded: false)
        case .keyAgentNotReady:
            record = Attempt(
                at: now, serverAt: serverAt, outcome: "key agent not ready", succeeded: false)
        case .authenticationDeadline:
            record = Attempt(
                at: now, serverAt: serverAt, outcome: "authentication deadline", succeeded: false)
        }
        lock.withLock { _attempts.append(record) }
        if case .connected(let master) = result, link != .up {
            master.setLinkStalled(true)
        }
        return result
    }

    // MARK: Sessions and processes

    /// What a channel open meets before it gets a session.
    enum ChannelAdmission {
        case admitted
        case refused(ExecRefusal)
    }

    func admitExec(on master: FakeHostMaster) -> ChannelAdmission {
        lock.withLock {
            if var refusal = _execRefusal {
                if let remaining = refusal.remaining {
                    if remaining <= 1 { _execRefusal = nil } else {
                        refusal.remaining = remaining - 1
                        _execRefusal = refusal
                    }
                }
                return .refused(refusal.kind)
            }
            return .admitted
        }
    }

    func sessionLimitReached(on master: FakeHostMaster) -> Bool {
        let held = master.openSessionCount
        return lock.withLock { held + _extraSessions >= _maxSessions }
    }

    /// Takes one stall of this kind, if one is armed.
    func takeScriptStall(_ kind: ScriptKind) -> Bool {
        lock.withLock {
            guard let entry = _scriptStalls[kind] else { return false }
            if let remaining = entry {
                if remaining <= 1 { _scriptStalls[kind] = nil } else {
                    _scriptStalls[kind] = .some(remaining - 1)
                }
            }
            return true
        }
    }

    private var _helperProcesses: [HelperProcess] = []
    private var _unrecognised: [String] = []
    private var _sweeps = 0

    var helperProcesses: [HelperProcess] { lock.withLock { _helperProcesses } }

    private var _peakHelpers = 0
    private var _helperStarts = 0

    private var _peakHelperConnections: [Int] = []
    private var _peakOnOneConnection = 0
    private var _peakConnection = 0

    func register(_ process: HelperProcess) {
        lock.withLock {
            _helperProcesses.append(process)
            _helperStarts += 1
            if _helperProcesses.count > _peakHelpers {
                _peakHelpers = _helperProcesses.count
                _peakHelperConnections = _helperProcesses.map(\.connection)
            }
            let sharing = _helperProcesses.filter { $0.connection == process.connection }.count
            if sharing > _peakOnOneConnection {
                _peakOnOneConnection = sharing
                _peakConnection = process.connection
            }
        }
    }

    /// The most helper processes that were ever running on the server at the same moment.
    /// Helpers of different connections can overlap: one left behind by a connection that
    /// went half-open runs until its wrapper has heard nothing for 60 s.
    public var peakConcurrentHelpers: Int { lock.withLock { _peakHelpers } }
    /// The masters the helpers of that moment ran on, by ordinal, one entry per helper.
    public var peakHelperConnections: [Int] { lock.withLock { _peakHelperConnections } }
    /// The most helper processes one connection ever ran at the same moment, and which
    /// master that was. More than one is the agent starting a second stream on a
    /// connection that already has one.
    public var peakHelpersOnOneConnection: (count: Int, master: Int) {
        lock.withLock { (_peakOnOneConnection, _peakConnection) }
    }
    /// The masters the helpers registered now run on, by ordinal.
    public var helperConnections: [Int] { helperProcesses.map(\.connection) }
    /// How many helper processes have been started, over the whole run.
    public var helperStarts: Int { lock.withLock { _helperStarts } }

    private var _helperUploads = 0
    /// How many times a helper binary was uploaded into the cache directory, over the
    /// whole run: each temp file the deployment created there is one.
    public var helperUploads: Int { lock.withLock { _helperUploads } }
    func unregister(_ process: HelperProcess) {
        lock.withLock { _helperProcesses.removeAll { $0 === process } }
    }

    func noteUnrecognised(_ body: String) { lock.withLock { _unrecognised.append(body) } }
    func noteSweep() { lock.withLock { _sweeps += 1 } }

    private var _sweepsStarted = 0
    func noteSweepStarted() { lock.withLock { _sweepsStarted += 1 } }
    /// Every sweep script an exec channel was opened for, finished or stalled.
    public var sweepsStarted: Int { lock.withLock { _sweepsStarted } }

    /// Scripts the host did not recognise. A scenario asserts this is empty: an agent
    /// change that altered a script must fail loudly rather than be answered wrongly.
    public var unrecognisedScripts: [String] { lock.withLock { _unrecognised } }
    /// How many sweeps have run on the host.
    public var sweepCount: Int { lock.withLock { _sweeps } }
    /// Helper processes that have said `ready` and are still running.
    public var runningHelperCount: Int { helperProcesses.filter(\.isReady).count }

    /// Exec and SFTP sessions open on live masters.
    public var liveSessions: (sftp: Int, exec: Int) {
        var sftp = 0, exec = 0
        for master in liveMasters {
            let counts = master.sessionCounts
            sftp += counts.sftp
            exec += counts.exec
        }
        return (sftp, exec)
    }

    private func treeChanged(_ changes: [FakeSFTPServer.Change]) {
        noteActivity()
        let uploads = changes.filter {
            let path = String(decoding: $0.path, as: UTF8.self)
            return $0.kind == .create && path.contains(".cache/sshdrive/.sshdrive-upload-")
        }.count
        if uploads > 0 { lock.withLock { _helperUploads += uploads } }
        for process in helperProcesses { process.treeChanged(changes) }
        fire { trigger in
            guard case .treeChange(let text) = trigger else { return false }
            return changes.contains {
                String(decoding: $0.path, as: UTF8.self).contains(text)
                    || $0.from.map { String(decoding: $0, as: UTF8.self).contains(text) } == true
            }
        }
    }

    /// The name of an SFTP extended request, or nil for any other packet.
    static func extendedRequestName(_ packet: SFTPWire.Packet) -> String? {
        guard packet.packetType == .extended, packet.body.count >= 8 else { return nil }
        let body = packet.body
        let length = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
        guard length >= 0, body.count >= 8 + length else { return nil }
        return String(decoding: body[8 ..< 8 + length], as: UTF8.self)
    }

    /// Cancels every timer and kills every master, for the end of a scenario.
    public func tearDown() {
        let pending = lock.withLock { () -> [Task<Void, Never>] in
            defer { timers.removeAll() }
            return timers
        }
        for task in pending { task.cancel() }
        for master in liveMasters { master.die(stderr: "") }
    }
}

/// An authenticated connection to a `FakeRemoteHost`: the `ssh -N` master, as
/// `SSHBackedTransport.establish` uses it.
public final class FakeHostMaster: RemoteMaster, @unchecked Sendable {
    public typealias ExecChannelType = HostExecChannel
    public typealias SFTPChannelType = HostSFTPChannel

    final class Session: @unchecked Sendable {
        enum Kind { case sftp, exec(FakeRemoteHost.ScriptKind) }
        let kind: Kind
        let stream: HostStream
        var open = true
        var process: HostProcess?
        init(kind: Kind, stream: HostStream) {
            self.kind = kind
            self.stream = stream
        }
    }

    unowned let host: FakeRemoteHost
    /// 1 for the first master the host handed out.
    public let ordinal: Int
    private let lock = NSLock()
    private var _alive = true
    private var _lastStderr = ""
    private var linkStalled = false
    private var selfStalled = false
    private var stallEpoch = 0
    private var sessions: [Session] = []
    private var sftpOpens = 0
    private var _shutdownByClient = false

    init(host: FakeRemoteHost, ordinal: Int) {
        self.host = host
        self.ordinal = ordinal
    }

    public var alive: Bool { lock.withLock { _alive } }
    /// True when the agent ran `-O exit` on it, rather than it dying under the agent.
    public var shutDownByClient: Bool { lock.withLock { _shutdownByClient } }
    var isStalled: Bool { lock.withLock { linkStalled || selfStalled } }

    var openSessionCount: Int { lock.withLock { sessions.filter(\.open).count } }

    /// Open sessions on this master, by kind.
    public var sessionCounts: (sftp: Int, exec: Int) {
        lock.withLock {
            var sftp = 0, exec = 0
            for session in sessions where session.open {
                if case .sftp = session.kind { sftp += 1 } else { exec += 1 }
            }
            return (sftp, exec)
        }
    }

    /// The open exec sessions by script kind, for a diagnostic.
    public var openExecKinds: [FakeRemoteHost.ScriptKind] {
        lock.withLock {
            sessions.compactMap { session in
                guard session.open, case .exec(let kind) = session.kind else { return nil }
                return kind
            }
        }
    }

    // MARK: RemoteMaster

    public var isRunning: Bool { alive }
    public var lastStderr: String { lock.withLock { _lastStderr } }

    /// `-O check` asks the local master over its socket, so it answers true on a
    /// half-open connection: it says nothing about the server.
    public func check() -> Bool { alive }

    /// `-O exit`. Over a link that carries it, sshd closes every session and the wrapper
    /// on each kills its child; over a stalled one the server hears nothing.
    public func shutdown() {
        lock.withLock { if _alive { _shutdownByClient = true } }
        die(stderr: "", reachesServer: !isStalled)
    }

    public func openSFTPChannel(readinessDeadline: TimeInterval) -> HostSFTPChannel {
        host.noteActivity()
        let clock = host.clock
        guard alive else {
            return HostSFTPChannel(
                stream: .closed(clock: clock),
                stderr: OpenSSHPrompts.deadMaster(controlPath: controlPath) + "\r\n")
        }
        let ordinal = lock.withLock { () -> Int in
            sftpOpens += 1
            return sftpOpens
        }
        if host.sessionLimitReached(on: self) {
            return HostSFTPChannel(
                stream: .closed(clock: clock),
                stderr: OpenSSHPrompts.sessionRefused + ": Session open refused by peer\r\n")
        }
        let stream = HostStream(clock: clock)
        let session = Session(kind: .sftp, stream: stream)
        let silent = host.stalledSFTPChannelOrdinals.contains(ordinal)
        let server = host.sftp
        let framer = SFTPFramer()
        stream.onActivity = { [weak host] in host?.noteActivity() }
        stream.onInput = { [weak stream, weak self, weak host] data in
            guard !silent, let stream else { return }
            for packet in framer.frame(data) {
                if let name = FakeRemoteHost.extendedRequestName(packet) {
                    host?.fire { $0 == .sftpExtended(name: name) }
                    guard self?.alive == true else { return }
                }
                let reply = server.answer(packet)
                stream.emit(reply)
            }
        }
        stream.onClientClose = { [weak self, weak session] in
            guard let session else { return }
            self?.end(session)
        }
        attach(session)
        if isStalled { stream.setStalled(true) }
        host.fire { $0 == .sftpChannelOpened(ordinal: ordinal) }
        return HostSFTPChannel(stream: stream)
    }

    public func openExecChannel(script: RemoteScript, readinessDeadline: TimeInterval) async throws
        -> HostExecChannel
    {
        host.noteActivity()
        guard alive else { throw Self.masterLost(controlPath: controlPath) }
        if case .refused(let kind) = host.admitExec(on: self) {
            switch kind {
            case .sessionLimit: throw Self.sessionRefused()
            case .noShell:
                throw SSHProcessError.noShellAccess(
                    prefix: Data(OpenSSHPrompts.forceCommandSentence.utf8))
            case .unusable:
                throw SSHProcessError.shellOutputUnusable(prefix: Data())
            }
        }
        let profile = host.profile
        if let force = profile.forceCommand {
            switch force {
            case .internalSFTP:
                throw SSHProcessError.noShellAccess(
                    prefix: Data(OpenSSHPrompts.forceCommandSentence.utf8))
            case .internalSFTPFraming:
                throw SSHProcessError.noShellAccess(prefix: Data([0, 0, 0, 5, 2, 0, 0, 0, 3]))
            }
        }
        if host.sessionLimitReached(on: self) { throw Self.sessionRefused() }

        let stream = HostStream(clock: host.clock)
        stream.onActivity = { [weak host] in host?.noteActivity() }
        let kind = FakeRemoteHost.classify(script)
        let session = Session(kind: .exec(kind), stream: stream)
        attach(session)
        if isStalled { stream.setStalled(true) }

        // The opening sentinel crosses the link like everything else: a half-open
        // connection never delivers it, and the open fails at its readiness deadline the
        // way `SSHMaster.openExecChannel` fails, "shell output unusable" with nothing
        // received.
        let clock = host.clock
        let deadline = clock.now() + readinessDeadline
        while isStalled, alive, clock.now() < deadline {
            await clock.sleep(seconds: min(0.5, max(0.01, deadline - clock.now())))
            if Task.isCancelled { break }
        }
        guard alive else {
            end(session)
            throw Self.masterLost(controlPath: controlPath)
        }
        if isStalled {
            end(session)
            stream.close()
            throw SSHProcessError.shellOutputUnusable(prefix: Data())
        }

        let channel = HostExecChannel(
            stream: stream, prefix: Data(profile.loginShell.rcNoise.utf8))
        let process = FakeRemoteHost.makeProcess(
            kind: kind, script: script, host: host, channel: channel,
            exited: { [weak self, weak session] in
                guard let session else { return }
                self?.end(session)
            })
        (process as? HelperProcess)?.connection = ordinal
        lock.withLock { session.process = process }
        stream.onInput = { [weak process] data in process?.input(data) }
        stream.onInputEOF = { [weak process] in process?.inputEOF() }
        stream.onClientClose = { [weak self, weak session, weak process] in
            process?.clientClosed()
            guard let session else { return }
            self?.end(session)
        }
        // A trigger on this script lands after the sentinel and before any of its output.
        host.fire { $0 == .scriptOpened(kind) }
        if alive { process.start() }
        return channel
    }

    // MARK: Life and death

    private var controlPath: String { "/tmp/sshdrive-\(String(format: "%08x", ordinal))" }

    private static func masterLost(controlPath: String) -> SSHProcessError {
        let stderr = OpenSSHPrompts.deadMaster(controlPath: controlPath) + "\r\n"
        return .channelFailed(
            classification: SSHExitClassifier.classify(
                role: .muxClient, exitStatus: 255, stderr: stderr, channelOpened: false),
            stderr: stderr)
    }

    private static func sessionRefused() -> SSHProcessError {
        let stderr = OpenSSHPrompts.sessionRefused + ": Session open refused by peer\r\n"
        return .channelFailed(
            classification: SSHExitClassifier.classify(
                role: .muxClient, exitStatus: 255, stderr: stderr, channelOpened: false),
            stderr: stderr)
    }

    private func attach(_ session: Session) {
        lock.withLock { sessions.append(session) }
    }

    func end(_ session: Session) {
        lock.withLock { session.open = false }
        host.noteActivity()
    }

    /// The master exits: every channel on it is severed. With `reachesServer` - the
    /// server dropped the connection, or the agent's `-O exit` crossed a working link -
    /// sshd closes the sessions and every process on the server that belonged to them
    /// goes too. Without it - the master gave up on a half-open link - the server never
    /// learns: what it was running carries on until it notices for itself, which for the
    /// helper is its wrapper's 60 s without a heartbeat.
    func die(stderr: String, reachesServer: Bool = true) {
        let (wasAlive, doomed) = lock.withLock { () -> (Bool, [Session]) in
            guard _alive else { return (false, []) }
            _alive = false
            if !stderr.isEmpty { _lastStderr = stderr }
            for session in sessions { session.open = false }
            return (true, sessions)
        }
        guard wasAlive else { return }
        host.noteActivity()
        for session in doomed {
            if reachesServer { session.process?.masterDied() }
            session.stream.sever()
        }
    }

    func setLinkStalled(_ value: Bool) {
        let streams = lock.withLock { () -> [HostStream] in
            linkStalled = value
            stallEpoch += 1
            return sessions.map(\.stream)
        }
        applyStall(streams)
    }

    func setSelfStalled(_ value: Bool) {
        let streams = lock.withLock { () -> [HostStream] in
            selfStalled = value
            stallEpoch += 1
            return sessions.map(\.stream)
        }
        applyStall(streams)
    }

    private func applyStall(_ streams: [HostStream]) {
        let stalled = isStalled
        for stream in streams { stream.setStalled(stalled) }
        guard stalled, host.serverAliveKills else { return }
        let epoch = lock.withLock { stallEpoch }
        host.after(FakeRemoteHost.serverAliveSeconds) { [weak self] in
            guard let self else { return }
            let still = self.lock.withLock { self.stallEpoch == epoch && (self.linkStalled || self.selfStalled) }
            guard still else { return }
            self.die(
                stderr: "Timeout, server \(self.host.hostName) not responding.\r\n",
                reachesServer: false)
        }
    }
}

/// Splits a byte stream into SFTP packets, for one channel.
final class SFTPFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var scratch: [UInt8] = []

    func frame(_ data: Data) -> [SFTPWire.Packet] {
        lock.withLock {
            scratch.append(contentsOf: data)
            return SFTPWire.frame(&scratch)
        }
    }
}
