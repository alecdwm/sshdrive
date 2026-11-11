import Foundation
import AgentCore
import Config
import Logging
import SFTP
import SSHProcess
import XPCProtocols

/// The environment every `ssh` the agent spawns runs in (docs/design/ssh.md): launchd's,
/// with `HOME`, and with `PATH` and `SSH_AUTH_SOCK` replaced by a snapshot of the user's
/// login shell.
///
/// The snapshot is taken once and reused, because taking it runs the user's rc files and
/// costs up to ten seconds. `refresh()` retakes it at agent start and on every `add`.
public actor AgentSSHEnvironment {
    public static let shared = AgentSSHEnvironment()

    private var snapshot: LoginShellSnapshot?

    public func current() async -> LoginShellSnapshot {
        if let snapshot { return snapshot }
        return await refresh()
    }

    @discardableResult
    public func refresh() async -> LoginShellSnapshot {
        let taken = await SSHProcess.loginShellSnapshot()
        snapshot = taken
        if taken.succeeded {
            Log.ssh.notice(
                "login shell snapshot from \(taken.shell, privacy: .public): PATH \(taken.path?.count ?? 0, privacy: .public) bytes, SSH_AUTH_SOCK \(taken.sshAuthSock == nil ? "unset" : "set", privacy: .public)"
            )
        } else {
            // launchd's values are used and `doctor` says so.
            Log.ssh.error(
                "login shell snapshot failed (\(taken.diagnostic ?? "no diagnostic", privacy: .public)); using launchd's PATH and SSH_AUTH_SOCK"
            )
        }
        return taken
    }

    /// The base environment plus the snapshot. The askpass variables are added per spawn
    /// by `SSHMaster`, which is the only thing that knows the token.
    public func environment() async -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        if base["HOME"] == nil { base["HOME"] = NSHomeDirectory() }
        base.removeValue(forKey: AskpassEnvironment.promptVariable)
        base.removeValue(forKey: AskpassEnvironment.tokenVariable)
        return await current().applied(to: base)
    }
}

/// One location's live transport: the `-N` master, the **two** SFTP channels opened on
/// its mux socket, and a wire client on each channel's stdio (docs/design/ssh.md,
/// docs/design/sftp.md).
///
/// It is an `SFTPTransport` like `FakeTransport`, so nothing in `LocationRuntime` or the
/// File Provider paths changes when a location is real rather than fake. What it adds
/// over `RealSFTPTransport` is two things the extension needs:
///
/// - **Every call has a deadline.** The wire client has per-request deadlines of its own,
///   but a call can also wedge before it reaches the wire - the actor ahead of it, a
///   channel that never opened - and an extension call that never returns hangs Finder.
///   So each method runs under a wall-clock deadline of its own and a miss is
///   `.deadlineExceeded`, which the agent maps to `.serverUnreachable`.
/// - **A lost master is `.serverUnreachable`.** When the `-N` master has gone, every
///   channel on it is dead; the error is reported as a lost connection rather than
///   whatever the dying channel happened to say.
///
/// The `NWPathMonitor` gate, the circuit breaker and reconnection with backoff sit above
/// this in `ReconnectingTransport`. What is here is only enough that nothing hangs.
public final class SSHBackedTransport: SFTPTransport, LiveConnection, @unchecked Sendable {

    /// The wire client's metadata deadline (20 s) with a little room for the actor hop, so
    /// the wire client's own deadline is normally what fires and says which request it
    /// was.
    static let metadataDeadlineSeconds: Double = 25
    /// Transfers are bounded far more loosely: the client re-arms its own deadline while
    /// bytes keep arriving, and this is only the backstop.
    static let transferDeadlineSeconds: Double = 3600

    public let locationID: String
    /// `SSHMaster` in the agent; an in-process server's master in a scenario.
    public let master: any RemoteMaster
    /// The same master, as the seam names it (docs/design/testing.md): nil means "no exec
    /// channel", which is what a location with no real `ssh` behind it means everywhere in
    /// change detection.
    public var execMaster: (any RemoteMaster)? { master }
    /// What the server let us hold at once, and what that cost.
    public let budget: ChannelBudget
    /// What the capability probe found on one exec channel at connect: the account the
    /// server sees us as, `uname`, the `find` flavour, a checksum tool and a cache
    /// directory for the helper. Everything below `uname` is unknown where there is no
    /// shell, or no channel to spare for one.
    ///
    /// Where the probe went unanswered this is replaced by the answer in force - the last
    /// one the server gave, then the re-check's (`adopt(probe:)`) - so the helper's
    /// deployment, which reads it here, decides on an answer rather than on a stall.
    public var probe: ServerProbe.Result { probeLock.withLock { currentProbe } }
    private let probeLock = NSLock()
    private var currentProbe: ServerProbe.Result

    /// Channel 1: `stat`, `readdir`, `rename`, small files. Never carries a transfer
    /// unless the budget dropped the bulk channel.
    private let channel: any RemoteSFTPChannel
    private let inner: RealSFTPTransport
    /// Channel 2: fetches and uploads, so a long transfer never blocks a listing. Nil on
    /// a `MaxSessions 2` server, where transfers share channel 1 under the scheduler.
    private let bulkChannel: (any RemoteSFTPChannel)?
    private let bulk: RealSFTPTransport?

    /// Where a transfer runs. The same object on a degraded location: at a `MaxSessions`
    /// of 2 the same scheduler runs on the metadata channel.
    private var transferTransport: RealSFTPTransport { bulk ?? inner }

    /// The metadata channel's client, for the one caller that needs to address a path
    /// outside every location root: the helper's deployment into the cache directory the
    /// probe chose (`HelperLocation.swift` on why that door is narrow). Nothing on the
    /// File Provider path uses it.
    public var metadataTransport: RealSFTPTransport? { inner }

    /// The `<mac8>` of the upload temp name, kept so the helper's upload can use the same
    /// shape as every other upload.
    public let uploadTag: String

    /// True when transfers share the metadata channel, which the scheduler needs to know
    /// so it leaves request slots free for the metadata calls served ahead of them.
    public var transfersShareMetadataChannel: Bool { bulk == nil }

    /// What every call's deadline is measured on.
    private let clock: any AgentClock
    /// The canonical root and the client configuration the channels were opened with, so
    /// a channel opened later - the budget re-check - is opened the same way.
    private let root: String
    private let sftpConfiguration: SFTPClient.Configuration

    private init(
        locationID: String, master: any RemoteMaster, channel: any RemoteSFTPChannel,
        inner: RealSFTPTransport, bulkChannel: (any RemoteSFTPChannel)?,
        bulk: RealSFTPTransport?, budget: ChannelBudget, probe: ServerProbe.Result,
        uploadTag: String, clock: any AgentClock, root: String,
        sftpConfiguration: SFTPClient.Configuration
    ) {
        self.clock = clock
        self.root = root
        self.sftpConfiguration = sftpConfiguration
        self.uploadTag = uploadTag
        self.locationID = locationID
        self.master = master
        self.channel = channel
        self.inner = inner
        self.bulkChannel = bulkChannel
        self.bulk = bulk
        self.budget = budget
        self.currentProbe = probe
    }

    /// Puts an answered probe in force on this connection in place of one that went
    /// unanswered. An answer already in force is not replaced by a stall.
    public func adopt(probe: ServerProbe.Result) {
        guard !probe.unanswered else { return }
        probeLock.withLock { currentProbe = probe }
    }

    /// Snapshot, spawn, open, verify. In that order, because each step needs the one
    /// before it: the master cannot authenticate without the snapshot's `SSH_AUTH_SOCK`
    /// and `PATH`, the channel cannot open without the master's socket, and the root
    /// cannot be canonicalised without the channel (sections 6.1, 9.1).
    ///
    /// This is the first two; `establish` is everything after the master is up.
    public static func connect(
        location: Location,
        askpassPath: String?,
        askpass: (any AskpassTokenProviding)?,
        uploadTag: String,
        reprobeChannels: Bool = false,
        clock: any AgentClock = SystemAgentClock()
    ) async throws -> SSHBackedTransport {
        let environment = await AgentSSHEnvironment.shared.environment()
        let snapshot = await AgentSSHEnvironment.shared.current()
        var configuration = try SSHProcess.masterConfiguration(
            for: location, environment: environment, snapshot: snapshot)
        configuration.askpassPath = askpassPath
        configuration.askpass = askpass

        let master = SSHMaster(configuration: configuration)
        do {
            try await master.connect()
        } catch {
            Log.ssh.error(
                "master for \(location.id, privacy: .public) did not come up: \(error, privacy: .public)")
            throw error
        }
        return try await establish(
            master: master, location: location, uploadTag: uploadTag,
            reprobeChannels: reprobeChannels, clock: clock)
    }

    /// Everything after authentication, on a master that is already up: channel 1 and the
    /// canonical root, the channel budget (cached, or probed with the bulk channel as its
    /// second channel), the server probe on one exec channel, and the capability cache.
    ///
    /// The master is shut down when anything here fails. `sftpConfiguration` is the base
    /// every SFTP channel's client is built from; the agent takes the default, and a
    /// scenario sets its `clock` so a missed request deadline happens in model time.
    public static func establish(
        master: any RemoteMaster,
        location: Location,
        uploadTag: String,
        reprobeChannels: Bool = false,
        clock: any AgentClock = SystemAgentClock(),
        sftpConfiguration: SFTPClient.Configuration = SFTPClient.Configuration()
    ) async throws -> SSHBackedTransport {
        let channel: any RemoteSFTPChannel
        do {
            channel = try await master.openSFTPChannel(readinessDeadline: 15)
        } catch {
            await master.shutdown()
            throw error
        }

        do {
            // Channel 1, the metadata channel, and the canonical root every other channel
            // is opened against. The root is resolved again on every connection and the
            // location refuses to operate if it moved.
            let transport = try await RealSFTPTransport.connect(
                stream: channel.stream,
                root: location.remotePath ?? ".",
                uploadTag: uploadTag,
                configuration: sftpConfiguration)
            try await transport.verifyRoot()
            let root = await transport.root
            Log.sftp.notice(
                "location \(location.id, privacy: .public) rooted at \(root, privacy: .public)")

            // Channel 2, the bulk channel, and with it the answer to "may I hold three
            // channels at once" that becomes the whole channel budget. Only a cached full
            // budget is taken on trust, and only as far as the bulk channel actually opening:
            // anything less is asked again on every connect, because two channel opens is
            // all a wrong "MaxSessions 1" would have cost to correct.
            if reprobeChannels { CapabilityCache.forgetChannelBudget(locationID: location.id) }
            var budget: ChannelBudget?
            var bulk: ChannelProbe.Opened?
            if let cached = CapabilityCache.channelBudget(locationID: location.id),
                cached.hasBulkChannel
            {
                switch await ChannelProbe.openVerifiedChannel(
                    master: master, root: root, uploadTag: uploadTag,
                    configuration: sftpConfiguration)
                {
                case .success(let opened):
                    budget = cached
                    bulk = opened
                case .failure(let refusal):
                    // The cache said three were affordable and two are not. Ask the server
                    // from scratch - unless what failed was the connection, in which case
                    // there is nothing to believe either way.
                    guard !refusal.connectionDied else {
                        throw SFTPError.connectionLost
                    }
                    Log.ssh.notice(
                        "\(location.id, privacy: .public): cached budget no longer holds (\(refusal.diagnostics, privacy: .public)); re-probing"
                    )
                }
            }
            if budget == nil {
                let probed = await ChannelProbe.probe(
                    master: master, root: root, uploadTag: uploadTag, locationID: location.id,
                    configuration: sftpConfiguration)
                // A probe that failed because the connection died records nothing: the
                // attempt fails and the breaker tries again. An inconclusive one is used for
                // this connection and recorded nowhere.
                guard let measured = probed.budget else { throw SFTPError.connectionLost }
                budget = measured
                bulk = probed.bulk
                CapabilityCache.store(measured, locationID: location.id)
            }
            let granted = budget ?? .forConcurrentChannels(1)
            if !granted.note.isEmpty {
                Log.ssh.notice("\(location.id, privacy: .public): \(granted.note, privacy: .public)")
            }

            // The server identity, from one `id` exec channel. At a budget of 1 there
            // is no channel to spare and the location is SFTP-only in every respect - a
            // verdict when the server refused the second channel, and no answer at all when
            // the budget itself was inconclusive.
            var probe = ServerProbe.Result()
            if granted.allowsExecChannel {
                probe = await ServerProbe.run(master: master, clock: clock)
                if probe.sessionRefused {
                    CapabilityCache.markChannelBudgetSuspect(locationID: location.id)
                }
                if probe.unanswered, await !master.isRunning {
                    // The connection went during the probe. Handing it out would apply "no
                    // shell" for a server that has one, so the attempt fails instead and
                    // the breaker tries again.
                    if let bulk {
                        await bulk.transport.shutdown()
                        bulk.channel.close()
                    }
                    throw SFTPError.connectionLost
                }
                if !probe.failure.isEmpty {
                    Log.agent.notice(
                        "\(location.id, privacy: .public): no remote identity (\(probe.failure, privacy: .public))\(probe.unanswered ? "; the probe is asked again on this connection" : ""); every item gets full capabilities"
                    )
                }
            } else {
                probe.failure = "the server allows only one channel at a time"
                probe.unanswered = !granted.conclusive
            }
            // The probe's result is cached in `domains/<id>/capabilities.json` with a
            // timestamp, beside the channel budget that `CapabilityCache` already owns.
            let advertised = await transport.extensionNames
            Log.sftp.notice(
                "\(location.id, privacy: .public): SFTP extensions advertised: \(advertised.joined(separator: " "), privacy: .public)"
            )
            CapabilityCache.storeProbe(
                probe, extensions: await transport.extensions, advertised: advertised,
                locationID: location.id)

            return SSHBackedTransport(
                locationID: location.id, master: master, channel: channel, inner: transport,
                bulkChannel: bulk?.channel, bulk: bulk?.transport,
                budget: granted, probe: probe, uploadTag: uploadTag, clock: clock, root: root,
                sftpConfiguration: sftpConfiguration)
        } catch {
            let diagnostics = channel.stderrText
            channel.close()
            await master.shutdown()
            if diagnostics.isEmpty {
                throw error
            }
            // ssh's own diagnostics are the only explanation of a channel that never
            // spoke SFTP; without them the user sees "connection lost" and nothing else.
            throw SFTPError.failure("\(error.localizedDescription) ssh said: \(diagnostics)")
        }
    }

    /// `-O exit` and both channels with it. Called when a location is unmounted or
    /// removed.
    public func shutdown() async {
        if let bulk { await bulk.shutdown() }
        bulkChannel?.close()
        await inner.shutdown()
        channel.close()
        await master.shutdown()
    }

    /// `-O check`: our own child, over the socket. Cheap, and says
    /// nothing about the server.
    public func isMasterAlive() async -> Bool {
        guard await master.isRunning else { return false }
        return await master.check()
    }

    /// The channel-budget question again, on this connection, for a budget that was
    /// inconclusive when it came up (`ChannelProbe.recheck`). Nil until the server answers
    /// clearly; nothing opened for it is kept.
    public func recheckChannelBudget() async -> ChannelBudget? {
        await ChannelProbe.recheck(
            master: master, root: root, uploadTag: uploadTag, current: budget,
            locationID: locationID, configuration: sftpConfiguration)
    }

    // MARK: The deadline and the lost-master rule

    private func guarded<T: Sendable>(
        _ what: String,
        seconds: Double = SSHBackedTransport.metadataDeadlineSeconds,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await Deadline.run("SFTP \(what)", seconds: seconds, clock: clock, body)
        } catch let expired as Deadline.Expired {
            Log.sftp.error(
                "\(expired.operation, privacy: .public) missed its deadline on \(self.locationID, privacy: .public)"
            )
            throw SFTPError.deadlineExceeded
        } catch let error as SFTPError {
            // A wire error on a channel whose master has gone is a lost connection, not
            // whatever the dying channel managed to say on the way out.
            if await !master.isRunning { throw SFTPError.connectionLost }
            throw error
        } catch is CancellationError {
            // The deadline of `Deadline.run` is a second child task on the clock's sleep,
            // and a cancelled sleep throws `CancellationError` before the body notices
            // its own cancellation - so without this the caller sees Swift's error rather
            // than the transport's, and a user who cancelled a download in Finder gets an
            // unmapped one (measured against the testbed, 2026-09-04).
            throw SFTPError.cancelled
        } catch {
            if await !master.isRunning { throw SFTPError.connectionLost }
            throw error
        }
    }

    // MARK: SFTPTransport

    public var extensions: SFTPServerExtensions {
        get async { await inner.extensions }
    }

    /// Every name the metadata channel's handshake recorded.
    public var extensionNames: [String] {
        get async { await inner.extensionNames }
    }

    public func realpath(_ path: RelativePath) async throws -> String {
        let inner = self.inner
        return try await guarded("realpath") { try await inner.realpath(path) }
    }

    public func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        let inner = self.inner
        return try await guarded("lstat") { try await inner.lstat(path) }
    }

    public func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        let inner = self.inner
        return try await guarded("readdir") { try await inner.readdir(path) }
    }

    public func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        let transport = transferTransport
        return try await guarded("read", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await transport.read(path, offset: offset, length: length)
        }
    }

    public func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        // On the bulk channel, at the scheduler's share of the pipelined window.
        let transport = transferTransport
        return try await guarded("read", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await transport.readStreaming(
                path, offset: offset, length: length, window: window, receiver: receiver)
        }
    }

    public func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        let transport = transferTransport
        try await guarded("write", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await transport.write(path, contents: contents, mode: mode)
        }
    }

    public func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let transport = transferTransport
        try await guarded("write", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await transport.writeStreaming(
                path, mode: mode, window: window, source: source, progress: progress)
        }
    }

    public func writeExclusive(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let transport = transferTransport
        try await guarded("write", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await transport.writeExclusive(
                path, mode: mode, window: window, source: source, progress: progress)
        }
    }

    public func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        let inner = self.inner
        try await guarded("mkdir") { try await inner.mkdir(path, mode: mode) }
    }

    public func remove(_ path: RelativePath) async throws {
        let inner = self.inner
        try await guarded("remove") { try await inner.remove(path) }
    }

    public func rmdir(_ path: RelativePath) async throws {
        let inner = self.inner
        try await guarded("rmdir") { try await inner.rmdir(path) }
    }

    public func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        let inner = self.inner
        try await guarded("rename") { try await inner.rename(source, to: destination) }
    }

    public func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        let inner = self.inner
        try await guarded("posix-rename") { try await inner.posixRename(source, to: destination) }
    }

    public func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        let inner = self.inner
        try await guarded("setstat") { try await inner.setstat(path, mode: mode, mtime: mtime) }
    }

    public func symlink(target: String, at path: RelativePath) async throws {
        let inner = self.inner
        try await guarded("symlink") { try await inner.symlink(target: target, at: path) }
    }

    public func readlink(_ path: RelativePath) async throws -> String {
        let inner = self.inner
        return try await guarded("readlink") { try await inner.readlink(path) }
    }

    public func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        let inner = self.inner
        return try await guarded("statvfs") { try await inner.statvfs(path) }
    }
}


/// `TransportLauncher` over `SSHBackedTransport`: the only thing in the agent that spawns
/// `/usr/bin/ssh` (docs/design/ssh.md).
///
/// It is in the package rather than in `Apps/Agent` because everything under it - the argv
/// assembly, the control socket, the exit classification, the mux clients - is already
/// platform-free in `SSHProcess`. What stands in for a server on Linux is the *binary*
/// (`ServerModel.FakeSSH`), not this code, which is the whole point of `SQ-035`'s argv
/// scenarios exercising the real assembly.
public struct SSHTransportLauncher: TransportLauncher {
    private let clock: any AgentClock

    public init(clock: any AgentClock = SystemAgentClock()) {
        self.clock = clock
    }

    public func connect(
        location: Location, askpassPath: String?, askpass: (any AskpassTokenProviding)?,
        uploadTag: String, reprobeChannels: Bool
    ) async throws -> any LiveConnection {
        try await SSHBackedTransport.connect(
            location: location, askpassPath: askpassPath, askpass: askpass,
            uploadTag: uploadTag, reprobeChannels: reprobeChannels, clock: clock)
    }
}
