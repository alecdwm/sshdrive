import Foundation
import Config
import Logging
import SFTP
import SSHProcess
import XPCProtocols

/// The environment every `ssh` the agent spawns runs in (DESIGN.md section 6.1):
/// launchd's, with `HOME`, and with `PATH` and `SSH_AUTH_SOCK` replaced by a snapshot of
/// the user's login shell.
///
/// The snapshot is taken once and reused, because taking it runs the user's rc files and
/// costs up to ten seconds. Section 6.1 refreshes it at agent start and on every `add`,
/// `test` and `passwd`; those three commands are milestone 3, and `refresh()` is what
/// they will call.
actor AgentSSHEnvironment {
    static let shared = AgentSSHEnvironment()

    private var snapshot: LoginShellSnapshot?

    func current() async -> LoginShellSnapshot {
        if let snapshot { return snapshot }
        return await refresh()
    }

    @discardableResult
    func refresh() async -> LoginShellSnapshot {
        let taken = await SSHProcess.loginShellSnapshot()
        snapshot = taken
        if taken.succeeded {
            Log.ssh.notice(
                "login shell snapshot from \(taken.shell, privacy: .public): PATH \(taken.path?.count ?? 0, privacy: .public) bytes, SSH_AUTH_SOCK \(taken.sshAuthSock == nil ? "unset" : "set", privacy: .public)"
            )
        } else {
            // Section 6.1: launchd's values are used and `doctor` says so.
            Log.ssh.error(
                "login shell snapshot failed (\(taken.diagnostic ?? "no diagnostic", privacy: .public)); using launchd's PATH and SSH_AUTH_SOCK"
            )
        }
        return taken
    }

    /// The base environment plus the snapshot. The askpass variables are added per spawn
    /// by `SSHMaster`, which is the only thing that knows the token (section 4.2).
    func environment() async -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        if base["HOME"] == nil { base["HOME"] = NSHomeDirectory() }
        base.removeValue(forKey: AskpassEnvironment.promptVariable)
        base.removeValue(forKey: AskpassEnvironment.tokenVariable)
        return await current().applied(to: base)
    }
}

/// One location's live transport: the `-N` master, the SFTP channel opened on its mux
/// socket, and the wire client on that channel's stdio (DESIGN.md sections 6.1 and 6.2).
///
/// It is an `SFTPTransport` like `FakeTransport`, so nothing in `LocationRuntime` or the
/// File Provider paths changes when a location is real rather than fake. What it adds
/// over `RealSFTPTransport` is the two things milestone 2 owes the extension:
///
/// - **Every call has a deadline.** The wire client already has per-request deadlines
///   (section 6.2), but a call can also wedge before it reaches the wire - the actor
///   ahead of it, a channel that never opened - and an extension call that never returns
///   hangs Finder. So each method runs under a wall-clock deadline of its own and a miss
///   is `.deadlineExceeded`, which the agent maps to `.serverUnreachable`.
/// - **A lost master is `.serverUnreachable`.** When the `-N` master has gone, every
///   channel on it is dead; the error is reported as a lost connection rather than
///   whatever the dying channel happened to say.
///
/// The rest of section 6.3 - the `NWPathMonitor` gate, the circuit breaker, reconnection
/// with backoff - is milestone 5. What is here is only enough that nothing hangs.
final class SSHBackedTransport: SFTPTransport, @unchecked Sendable {

    /// Section 6.2's metadata deadline (20 s) with a little room for the actor hop, so
    /// the wire client's own deadline is normally what fires and says which request it
    /// was.
    static let metadataDeadlineSeconds: Double = 25
    /// Transfers are bounded far more loosely: the client re-arms its own deadline while
    /// bytes keep arriving (section 6.2), and this is only the backstop.
    static let transferDeadlineSeconds: Double = 3600

    let locationID: String
    private let master: SSHMaster
    private let channel: SFTPChannel
    private let inner: RealSFTPTransport

    private init(
        locationID: String, master: SSHMaster, channel: SFTPChannel, inner: RealSFTPTransport
    ) {
        self.locationID = locationID
        self.master = master
        self.channel = channel
        self.inner = inner
    }

    /// Snapshot, spawn, open, verify. In that order, because each step needs the one
    /// before it: the master cannot authenticate without the snapshot's `SSH_AUTH_SOCK`
    /// and `PATH`, the channel cannot open without the master's socket, and the root
    /// cannot be canonicalised without the channel (sections 6.1, 9.1).
    static func connect(
        location: Location,
        askpassPath: String?,
        askpass: (any AskpassTokenProviding)?,
        uploadTag: String
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

        let channel: SFTPChannel
        do {
            channel = try await master.openSFTPChannel()
        } catch {
            await master.shutdown()
            throw error
        }

        do {
            // The metadata channel. A second, bulk channel is what section 6.1 wants next
            // to it; the transfer scheduler that would use it is milestone 3's, so this
            // one carries everything for now.
            let transport = try await RealSFTPTransport.connect(
                stream: channel.stream,
                root: location.remotePath ?? ".",
                uploadTag: uploadTag)
            try await transport.verifyRoot()
            let root = await transport.root
            Log.sftp.notice(
                "location \(location.id, privacy: .public) rooted at \(root, privacy: .public)")
            return SSHBackedTransport(
                locationID: location.id, master: master, channel: channel, inner: transport)
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

    /// `-O exit` and the channel with it. Called when a location is unmounted or removed.
    func shutdown() async {
        await inner.shutdown()
        channel.close()
        await master.shutdown()
    }

    /// The `-O check` of section 6.1: our own child, over the socket. Cheap, and says
    /// nothing about the server.
    func isMasterAlive() async -> Bool {
        guard await master.isRunning else { return false }
        return await master.check()
    }

    // MARK: The deadline and the lost-master rule

    private func guarded<T: Sendable>(
        _ what: String,
        seconds: Double = SSHBackedTransport.metadataDeadlineSeconds,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await Deadline.run("SFTP \(what)", seconds: seconds, body)
        } catch let expired as Deadline.Expired {
            Log.sftp.error(
                "\(expired.operation, privacy: .public) missed its deadline on \(self.locationID, privacy: .public)"
            )
            throw SFTPError.deadlineExceeded
        } catch let error as SFTPError {
            // A wire error on a channel whose master has gone is a lost connection, not
            // whatever the dying channel managed to say on the way out (section 6.1).
            if await !master.isRunning { throw SFTPError.connectionLost }
            throw error
        } catch {
            if await !master.isRunning { throw SFTPError.connectionLost }
            throw error
        }
    }

    // MARK: SFTPTransport

    var extensions: SFTPServerExtensions {
        get async { await inner.extensions }
    }

    func realpath(_ path: RelativePath) async throws -> String {
        let inner = self.inner
        return try await guarded("realpath") { try await inner.realpath(path) }
    }

    func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        let inner = self.inner
        return try await guarded("lstat") { try await inner.lstat(path) }
    }

    func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        let inner = self.inner
        return try await guarded("readdir") { try await inner.readdir(path) }
    }

    func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        let inner = self.inner
        return try await guarded("read", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await inner.read(path, offset: offset, length: length)
        }
    }

    func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        let inner = self.inner
        try await guarded("write", seconds: SSHBackedTransport.transferDeadlineSeconds) {
            try await inner.write(path, contents: contents, mode: mode)
        }
    }

    func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        let inner = self.inner
        try await guarded("mkdir") { try await inner.mkdir(path, mode: mode) }
    }

    func remove(_ path: RelativePath) async throws {
        let inner = self.inner
        try await guarded("remove") { try await inner.remove(path) }
    }

    func rmdir(_ path: RelativePath) async throws {
        let inner = self.inner
        try await guarded("rmdir") { try await inner.rmdir(path) }
    }

    func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        let inner = self.inner
        try await guarded("rename") { try await inner.rename(source, to: destination) }
    }

    func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        let inner = self.inner
        try await guarded("posix-rename") { try await inner.posixRename(source, to: destination) }
    }

    func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        let inner = self.inner
        try await guarded("setstat") { try await inner.setstat(path, mode: mode, mtime: mtime) }
    }

    func symlink(target: String, at path: RelativePath) async throws {
        let inner = self.inner
        try await guarded("symlink") { try await inner.symlink(target: target, at: path) }
    }

    func readlink(_ path: RelativePath) async throws -> String {
        let inner = self.inner
        return try await guarded("readlink") { try await inner.readlink(path) }
    }

    func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        let inner = self.inner
        return try await guarded("statvfs") { try await inner.statvfs(path) }
    }
}
