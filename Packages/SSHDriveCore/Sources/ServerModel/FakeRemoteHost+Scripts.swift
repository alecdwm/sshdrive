import Foundation
import SSHProcess

/// What runs on the far end of one exec channel.
protocol HostProcess: AnyObject, Sendable {
    func start()
    /// Bytes on the channel's stdin: heartbeat lines, and for the helper its root set.
    func input(_ data: Data)
    /// The agent closed stdin, which the heartbeat wrapper reads as "the agent is gone".
    func inputEOF()
    /// The agent closed the channel.
    func clientClosed()
    /// The connection under it went.
    func masterDied()
}

extension FakeRemoteHost {

    /// Which script this is, from its shape. The fake recognises the agent's scripts
    /// rather than sharing code with it, so a script that changes shape is reported in
    /// `unrecognisedScripts` instead of being answered by a guess.
    public static func classify(_ script: RemoteScript) -> ScriptKind {
        let body = script.body
        if script.heartbeat != nil, script.stdinRelay != nil { return .helper }
        if script.heartbeat != nil, body.hasPrefix("__sd_root=\"$1\"; shift") { return .sweep }
        if body.contains("probe_dir=") && body.contains("uname -s") && body.contains("id -u") {
            return .probe
        }
        if body.hasPrefix("__sd_f=\"$1\"") && body.contains("--version") { return .interrogate }
        if body.trimmingCharacters(in: .whitespacesAndNewlines)
            == "printf '%s\\000' \"$(date +%s)\""
        {
            return .serverTime
        }
        return .unknown
    }

    static func makeProcess(
        kind: ScriptKind, script: RemoteScript, host: FakeRemoteHost, channel: HostExecChannel,
        exited: @escaping @Sendable () -> Void
    ) -> HostProcess {
        switch kind {
        case .helper:
            return HelperProcess(host: host, script: script, channel: channel, exited: exited)
        case .sweep:
            host.noteSweepStarted()
            let stalls = host.takeScriptStall(.sweep)
            return OneShotProcess(
                host: host, channel: channel, exited: exited, stalls: stalls,
                stalledOutput: Self.record("\(Int64(host.serverNow))")
            ) { [weak host] in
                guard let host else { return (Data(), 1, "") }
                host.noteSweep()
                return host.runSweep(script)
            }
        case .probe, .interrogate, .serverTime:
            let stalls = host.takeScriptStall(kind)
            return OneShotProcess(host: host, channel: channel, exited: exited, stalls: stalls) {
                [weak host] in
                guard let host else { return (Data(), 1, "") }
                switch kind {
                case .probe: return (host.probeOutput(), 0, "")
                case .interrogate: return (host.interrogationOutput(script), 0, "")
                default: return (Self.record("\(Int64(host.serverNow))"), 0, "")
                }
            }
        case .unknown:
            host.noteUnrecognised(script.body)
            return OneShotProcess(host: host, channel: channel, exited: exited, stalls: false) {
                (Data(), 127, "sh: the fake host does not recognise this script\n")
            }
        }
    }

    /// One NUL-terminated record, as `printf '%s\000'` prints it.
    static func record(_ text: String) -> Data {
        var data = Data(text.utf8)
        data.append(0)
        return data
    }

    // MARK: The server probe

    /// The eleven records of `ServerProbe.script`, from the profile and the cache
    /// directory's state. The probe's `mkdir -p` is real: the directory exists afterwards
    /// whenever the state lets it be made.
    func probeOutput() -> Data {
        let profile = self.profile
        let flavour = profile.findFlavour
        var versionLines: [String] = []
        if !flavour.versionBanner.line.isEmpty { versionLines.append(flavour.versionBanner.line) }
        if let banner = flavour.busyboxBanner { versionLines.append(banner) }
        let directory = cacheDirectory
        let state = cacheDirectoryState
        let cacheLine: String
        switch state {
        case .nodir:
            cacheLine = "nodir \(directory)"
        case .exec, .noexec, .unwritable:
            let now = Int64(serverNow)
            var path = ""
            for component in directory.split(separator: "/") {
                path += "/\(component)"
                if sftp.node(path) == nil { sftp.makeDirectory(path, at: now) }
            }
            cacheLine = "\(state.rawValue) \(directory)"
        }
        var out = Data()
        for value in [
            profile.unameSM, "\(uid)", "\(gid)", "\(gid)", user, profile.home,
            flavour.takesCmin ? "yes" : "no", flavour.takesPrintf ? "yes" : "no",
            versionLines.joined(separator: "\n"),
            profile.hasSHA256Sum ? "/usr/bin/sha256sum" : "",
            cacheLine,
        ] {
            out.append(Self.record(value))
        }
        return out
    }

    // MARK: The helper's interrogation

    /// `sha256sum` of the file and its own `--version`, from the bytes actually in the
    /// tree.
    func interrogationOutput(_ script: RemoteScript) -> Data {
        let path = script.arguments.first ?? ""
        let hasTool = profile.hasSHA256Sum
        var digest = ""
        if hasTool, let node = sftp.node(path), node.type == .file {
            digest = SHA256Digest.hex(node.contents)
        }
        var out = Data()
        out.append(Self.record(hasTool ? "sha256sum" : "none"))
        out.append(Self.record(digest))
        out.append(Self.record(helperVersionLine(at: path) ?? ""))
        return out
    }

    // MARK: The sweep

    /// What `RemoteSweep.script` would print on this server: the server's clock, the hits
    /// of every batch with the plan's window, prunes and output format applied to the
    /// tree's change times, and the closing sentinel.
    func runSweep(_ script: RemoteScript) -> (Data, Int32, String) {
        let arguments = script.arguments
        guard let canonical = arguments.first else { return (Data(), 1, "") }
        let body = script.body
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let excludedCount = lines.filter {
            $0.hasPrefix("__sd_x") && $0.hasSuffix("=\"$1\"")
        }.count
        let batchKinds = lines.compactMap { line -> Bool? in
            guard line.hasPrefix("# batch ") else { return nil }
            return line.hasSuffix("recursive")
        }
        let printf = body.contains("-printf")
        var window: (ctime: Bool, minutes: Int)?
        for (flag, ctime) in [("-cmin -", true), ("-mmin -", false)] {
            guard let range = body.range(of: flag) else { continue }
            let digits = body[range.upperBound...].prefix(while: \.isNumber)
            if let minutes = Int(digits) { window = (ctime, minutes) }
        }

        // `cd -- "$__sd_root" || exit 1`: nothing at all, not even the server time.
        guard let rootNode = sftp.node(canonical), rootNode.type == .directory else {
            return (Data(), 1, "sh: cd: \(canonical): No such file or directory\n")
        }

        var rest = Array(arguments.dropFirst())
        let excluded = Array(rest.prefix(excludedCount))
        rest.removeFirst(min(excludedCount, rest.count))
        let now = serverNow
        var out = Self.record("\(Int64(now))")
        var stderr = ""
        for recursive in batchKinds {
            guard let first = rest.first, let count = Int(first) else { break }
            rest.removeFirst()
            let roots = Array(rest.prefix(count))
            rest.removeFirst(min(count, rest.count))
            for spelled in roots {
                let absolute = spelled == "."
                    ? canonical : canonical + "/" + spelled.dropFirst(2)
                guard sftp.node(absolute) != nil else {
                    stderr += "find: '\(spelled)': No such file or directory\n"
                    continue
                }
                walk(
                    absolute: absolute, printed: spelled, depth: 0,
                    maxDepth: recursive ? nil : 1, excluded: excluded, window: window,
                    now: now, printf: printf, into: &out)
            }
        }
        out.append(Data(script.sentinel.hex.utf8))
        out.append(0)
        return (out, 0, stderr)
    }

    private func walk(
        absolute: String, printed: String, depth: Int, maxDepth: Int?, excluded: [String],
        window: (ctime: Bool, minutes: Int)?, now: Double, printf: Bool, into out: inout Data
    ) {
        guard let node = sftp.node(absolute) else { return }
        // `-path <glob> -prune -o …`: a pruned path is neither printed nor descended.
        if excluded.contains(where: { Self.globMatches($0, printed) }) { return }
        if node.type == .directory || node.type == .file {
            let stamp = window.map { $0.ctime ? node.ctime : node.mtime }
            let inWindow = window.map { Double(stamp ?? 0) > now - Double($0.minutes * 60) } ?? true
            if inWindow {
                if printf {
                    let size = node.type == .directory ? 4096 : node.contents.count
                    for field in [
                        printed, node.type == .directory ? "d" : "f", "\(size)",
                        "\(node.mtime).0000000000", "\(node.inode)",
                        String(node.mode & 0o7777, radix: 8), "\(node.uid)", "\(node.gid)",
                    ] {
                        out.append(Self.record(field))
                    }
                } else {
                    out.append(Self.record(printed))
                }
            }
        }
        guard node.type == .directory else { return }
        if let maxDepth, depth >= maxDepth { return }
        for name in sftp.names(in: absolute) {
            let childPrinted = printed == "." ? "./\(name)" : "\(printed)/\(name)"
            walk(
                absolute: "\(absolute)/\(name)", printed: childPrinted, depth: depth + 1,
                maxDepth: maxDepth, excluded: excluded, window: window, now: now,
                printf: printf, into: &out)
        }
    }

    /// `fnmatch` without `FNM_PATHNAME`, which is what `find -path` applies: `*` crosses
    /// `/`, and a backslash makes the next character literal.
    static func globMatches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        func match(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == t.count }
            switch p[i] {
            case "*":
                var k = j
                while true {
                    if match(i + 1, k) { return true }
                    if k == t.count { return false }
                    k += 1
                }
            case "?":
                return j < t.count && match(i + 1, j + 1)
            case "[":
                guard j < t.count, let close = p[(i + 1)...].firstIndex(of: "]") else {
                    return j < t.count && t[j] == "[" && match(i + 1, j + 1)
                }
                let set = p[(i + 1) ..< close]
                return set.contains(t[j]) && match(close + 1, j + 1)
            case "\\":
                guard i + 1 < p.count else { return false }
                return j < t.count && t[j] == p[i + 1] && match(i + 2, j + 1)
            default:
                return j < t.count && t[j] == p[i] && match(i + 1, j + 1)
            }
        }
        return match(0, 0)
    }
}

/// A script that prints its answer and exits: the probe, the interrogation, `date +%s`
/// and a sweep. A stalled one opens and says nothing until the agent gives up on it, or
/// until `FakeRemoteHost.resumeStalledScripts()` lets it finish.
final class OneShotProcess: HostProcess, @unchecked Sendable {
    private weak var host: FakeRemoteHost?
    private let channel: HostExecChannel
    private let exited: @Sendable () -> Void
    private let stalls: Bool
    private let stalledOutput: Data
    private let output: @Sendable () -> (Data, Int32, String)
    private let lock = NSLock()
    private var done = false

    init(
        host: FakeRemoteHost, channel: HostExecChannel, exited: @escaping @Sendable () -> Void,
        stalls: Bool, stalledOutput: Data = Data(),
        output: @escaping @Sendable () -> (Data, Int32, String)
    ) {
        self.host = host
        self.channel = channel
        self.exited = exited
        self.stalls = stalls
        self.stalledOutput = stalledOutput
        self.output = output
    }

    func start() {
        guard !stalls else {
            channel.stream.emit(stalledOutput)
            host?.noteStalled(self)
            return
        }
        let (stdout, status, stderr) = output()
        if !stderr.isEmpty { channel.appendStderr(stderr) }
        channel.stream.emit(stdout)
        finish(status: status)
    }

    /// The stall ends: the rest of the answer, after the part already printed. A stalled
    /// sweep has printed its server-time record, which the full answer starts with too.
    func resume() {
        guard lock.withLock({ !done }) else { return }
        var (stdout, status, stderr) = output()
        if !stalledOutput.isEmpty, let end = stdout.firstIndex(of: 0) {
            stdout = Data(stdout[stdout.index(after: end)...])
        }
        if !stderr.isEmpty { channel.appendStderr(stderr) }
        channel.stream.emit(stdout)
        finish(status: status)
    }

    func input(_ data: Data) {}

    /// The heartbeat wrapper reads EOF, kills what it started and exits.
    func inputEOF() { finish(status: 0) }

    func clientClosed() { finish(status: 0, quietly: true) }

    func masterDied() { finish(status: 255, quietly: true) }

    private func finish(status: Int32, quietly: Bool = false) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        host?.forgetStalled(self)
        channel.setExit(ProcessExit(status: status, signal: nil))
        if !quietly { channel.stream.finishOutput() }
        exited()
    }
}

/// `sshdrive-helper watch --json` under the heartbeat wrapper.
///
/// It says `ready` after the host's `helperReadyDelay` - its first walk of the root set -
/// then a heartbeat every 15 s and one NDJSON line for every change under its roots, with
/// the same metadata the real helper attaches. The wrapper's half is here too: a line on
/// stdin is a heartbeat (and a `roots` line also replaces the root set), 60 s without
/// one kills it, and EOF on stdin kills it at once.
final class HelperProcess: HostProcess, @unchecked Sendable {

    enum State { case starting, ready, exited }

    private unowned let host: FakeRemoteHost
    private let channel: HostExecChannel
    private let exited: @Sendable () -> Void
    private let helperPath: String
    private let rootBytes: Data
    private let lock = NSLock()
    private var state = State.starting
    private var shallow: [Data] = []
    private var recursive: [Data] = []
    private var excluded: [Data] = []
    private var lastInput: Double = 0
    private var inputBuffer = Data()
    private var tasks: [Task<Void, Never>] = []
    private var frozen = false
    /// While the server's clock is before this, the helper is walking a new root set:
    /// heartbeats are not written and events are held for the end of the walk.
    private var walkingUntil: Double = -.infinity
    private var heldDuringWalk: [Data] = []
    /// The ordinal of the master whose session runs this helper.
    var connection = 0

    static let heartbeatSeconds: Double = 15
    static let silenceSeconds: Double = 60

    init(
        host: FakeRemoteHost, script: RemoteScript, channel: HostExecChannel,
        exited: @escaping @Sendable () -> Void
    ) {
        self.host = host
        self.channel = channel
        self.exited = exited
        let arguments = script.arguments
        helperPath = arguments.first ?? ""
        rootBytes = Data((arguments.count > 1 ? arguments[1] : host.root).utf8)
        var index = 2
        while index + 1 < arguments.count {
            let value = Data(arguments[index + 1].utf8)
            switch arguments[index] {
            case "--shallow": shallow.append(value)
            case "--recursive": recursive.append(value)
            case "--exclude": excluded.append(value)
            default: break
            }
            index += 2
        }
    }

    var isReady: Bool { lock.withLock { state == .ready } }

    func start() {
        guard let line = host.helperVersionLine(at: helperPath) else {
            let why = host.sftp.node(helperPath) == nil ? "not found" : "Permission denied"
            channel.appendStderr("sh: 1: exec: \(helperPath): \(why)\n")
            finish(status: 126)
            return
        }
        let fields = line.split(separator: " ").map(String.init)
        let target = fields.count > 2 ? fields[2].split(separator: "/").map(String.init) : []
        let version = fields.count > 1 ? fields[1] : "?"
        let os = target.first ?? "?"
        let arch = target.count > 1 ? target[1] : "?"
        // The master can die between the channel opening and this line, and `masterDied`
        // has then finished a process that never registered. It stays finished.
        guard lock.withLock({ state == .starting }) else { return }
        host.register(self)
        if lock.withLock({ state == .exited }) {
            host.unregister(self)
            return
        }
        let clock = host.clock
        // The server's own clock: a jump of the Mac's wall clock is nothing to the wrapper
        // counting its 60 s.
        lock.withLock { lastInput = host.serverNow }

        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.lock.withLock { self.lastInput } + Self.silenceSeconds
                let now = self.host.serverNow
                if now >= due {
                    self.finish(status: 0)
                    return
                }
                await clock.sleep(seconds: due - now)
            }
        }
        lock.withLock { tasks.append(watchdog) }

        guard !host.helperNeverReady else { return }
        let delay = host.helperReadyDelay
        let ready = Task { [weak self] in
            await clock.sleep(seconds: delay)
            guard !Task.isCancelled else { return }
            self?.becomeReady(version: version, os: os, arch: arch)
        }
        lock.withLock { tasks.append(ready) }
    }

    private func becomeReady(version: String, os: String, arch: String) {
        let roots = lock.withLock { () -> Int? in
            guard state == .starting else { return nil }
            state = .ready
            return shallow.count + recursive.count
        }
        guard let roots else { return }
        emit([
            "op": "ready", "version": version, "os": os, "arch": arch,
            "mechanism": "inotify", "roots": roots,
        ])
        let clock = host.clock
        let beat = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(seconds: Self.heartbeatSeconds)
                guard !Task.isCancelled, let self else { return }
                self.emit(["op": "heartbeat", "t": Int64(self.host.serverNow)])
            }
        }
        lock.withLock { tasks.append(beat) }
    }

    func input(_ data: Data) {
        let now = host.serverNow
        let lines = lock.withLock { () -> [Data] in
            lastInput = now
            inputBuffer.append(data)
            var out: [Data] = []
            while let newline = inputBuffer.firstIndex(of: 0x0A) {
                out.append(Data(inputBuffer[inputBuffer.startIndex ..< newline]))
                inputBuffer = Data(inputBuffer[inputBuffer.index(after: newline)...])
            }
            return out
        }
        for line in lines where line.first == UInt8(ascii: "{") {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["op"] as? String == "roots"
            else { continue }
            func paths(_ key: String) -> [Data] {
                (object[key] as? [Any] ?? []).compactMap { item in
                    if let text = item as? String { return Data(text.utf8) }
                    if let encoded = (item as? [String: Any])?["b64"] as? String {
                        return Data(base64Encoded: encoded)
                    }
                    return nil
                }
            }
            lock.withLock {
                shallow = paths("shallow")
                recursive = paths("recursive")
                excluded = paths("excluded")
            }
            startWalk()
        }
    }

    /// The silent re-walk a new root set costs, when the host asks for one.
    private func startWalk() {
        let seconds = host.helperRootsWalkSeconds
        guard seconds > 0 else { return }
        let until = host.serverNow + seconds
        lock.withLock { walkingUntil = max(walkingUntil, until) }
        let clock = host.clock
        let end = Task { [weak self] in
            await clock.sleep(seconds: seconds)
            guard !Task.isCancelled, let self else { return }
            let now = self.host.serverNow
            let held = self.lock.withLock { () -> [Data]? in
                guard now >= self.walkingUntil else { return nil }
                defer { self.heldDuringWalk.removeAll() }
                return self.heldDuringWalk
            }
            for line in held ?? [] { self.channel.stream.emit(line) }
        }
        lock.withLock { tasks.append(end) }
    }

    func inputEOF() { finish(status: 0) }
    func clientClosed() { finish(status: 0, quietly: true) }
    func masterDied() { finish(status: 255, quietly: true) }

    /// The helper stops producing output and never starts again; the wrapper around it
    /// is untouched.
    func freeze() { lock.withLock { frozen = true } }

    /// `kill -9` of the helper: the wrapper sees its child gone and exits.
    func kill() {
        channel.appendStderr("Killed\n")
        finish(status: 137)
    }

    private func finish(status: Int32, quietly: Bool = false) {
        let pending = lock.withLock { () -> [Task<Void, Never>]? in
            guard state != .exited else { return nil }
            state = .exited
            defer { tasks.removeAll() }
            return tasks
        }
        guard let pending else { return }
        for task in pending { task.cancel() }
        host.unregister(self)
        channel.setExit(ProcessExit(status: status, signal: nil))
        if !quietly { channel.stream.finishOutput() }
        exited()
    }

    // MARK: Events

    func treeChanged(_ changes: [FakeSFTPServer.Change]) {
        guard isReady else { return }
        for change in changes {
            let to = relative(change.path)
            switch change.kind {
            case .create, .modify:
                guard let to, watched(to), let node = host.sftp.node(absolute: change.path)
                else { continue }
                emit(event(change.kind.rawValue, path: to, node: node))
            case .delete:
                guard let to, watched(to) else { continue }
                emit(event("delete", path: to, node: nil))
            case .rename:
                let from = change.from.flatMap(relative)
                let fromWatched = from.map(watched) ?? false
                let toWatched = to.map(watched) ?? false
                let node = host.sftp.node(absolute: change.path)
                if fromWatched, toWatched, let from, let to {
                    var object = event("rename", path: to, node: node)
                    Self.put(from, as: "from", into: &object)
                    emit(object)
                } else if fromWatched, let from {
                    emit(event("delete", path: from, node: nil))
                } else if toWatched, let to {
                    emit(event("create", path: to, node: node))
                }
            }
        }
    }

    /// Relative to the location root, or nil for a path outside it (and the root itself).
    private func relative(_ path: Data) -> Data? {
        var prefix = rootBytes
        prefix.append(0x2F)
        guard path.count > prefix.count, path.starts(with: prefix) else { return nil }
        return Data(path.dropFirst(prefix.count))
    }

    /// Whether an inotify watch on the root set sees this path: a direct child of a
    /// shallow root, or anything under a recursive one that no exclusion covers.
    private func watched(_ path: Data) -> Bool {
        let (shallow, recursive, excluded) = lock.withLock { (self.shallow, self.recursive, self.excluded) }
        func under(_ root: Data) -> Bool {
            if root.isEmpty { return true }
            if path == root { return true }
            var prefix = root
            prefix.append(0x2F)
            return path.starts(with: prefix)
        }
        if excluded.contains(where: { !$0.isEmpty && under($0) }) { return false }
        let parent = path.lastIndex(of: 0x2F).map { Data(path[path.startIndex ..< $0]) } ?? Data()
        if shallow.contains(parent) { return true }
        return recursive.contains(where: under)
    }

    private func event(_ op: String, path: Data, node: FakeSFTPServer.Node?) -> [String: Any] {
        var object: [String: Any] = ["op": op]
        Self.put(path, as: "path", into: &object)
        if let node {
            object["type"] = node.type == .directory ? "d" : "f"
            object["size"] = node.type == .directory ? 4096 : node.contents.count
            object["mtime_ns"] = node.mtime * 1_000_000_000
            object["inode"] = node.inode
            object["mode"] = node.mode & 0o7777
            object["uid"] = node.uid
            object["gid"] = node.gid
        }
        return object
    }

    /// `path` when the bytes are UTF-8, `path_b64` when they are not.
    private static func put(_ path: Data, as key: String, into object: inout [String: Any]) {
        if let text = String(data: path, encoding: .utf8) {
            object[key] = text
        } else {
            object[key + "_b64"] = path.base64EncodedString()
        }
    }

    private func emit(_ object: [String: Any]) {
        guard !lock.withLock({ frozen }) else { return }
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        line.append(0x0A)
        let now = host.serverNow
        let held = lock.withLock { () -> Bool in
            guard now < walkingUntil else { return false }
            if object["op"] as? String != "heartbeat" { heldDuringWalk.append(line) }
            return true
        }
        guard !held else { return }
        channel.stream.emit(line)
    }
}
