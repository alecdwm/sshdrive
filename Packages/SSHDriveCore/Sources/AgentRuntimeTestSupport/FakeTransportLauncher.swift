import AgentCore
import AgentRuntime
import Config
import Foundation
import SFTP
import XPCProtocols
import SSHProcess
import Secrets

/// One location's connection, without an `ssh` (docs/testing-architecture.md section 2.3's
/// `TransportLauncher` row).
///
/// It is an `SFTPTransport` forwarding to whatever double the scenario handed it - the
/// existing `SFTP.FakeTransport` by default, or `ServerModel.FakeSFTPServer` over a real
/// wire once that exists - plus the three things the layers above a transport ask a *live
/// connection* for: the channel budget, the probe, and the master an exec channel would be
/// opened on.
///
/// `execMaster` is nil, and that is not a gap: "no exec channel" is a real state of a real
/// location (a `MaxSessions` of 1, a `ForceCommand internal-sftp` account), and every tier
/// above 0 already refuses itself when there is none. A scenario that needs a shell needs
/// `ServerModel.FakeExecChannel`, which is step 6.
public final class FakeLiveConnection: LiveConnection, @unchecked Sendable {
    private let inner: any SFTPTransport
    public let budget: ChannelBudget
    public let probe: ServerProbe.Result
    public let transfersShareMetadataChannel: Bool
    public let uploadTag: String
    private let lock = NSLock()
    private var _alive = true
    private var _shutdowns = 0
    private var _statvfs = 0
    private var _aliveChecks = 0

    public init(
        transport: any SFTPTransport,
        budget: ChannelBudget = .unrestricted,
        probe: ServerProbe.Result = ServerProbe.Result(),
        transfersShareMetadataChannel: Bool = false,
        uploadTag: String = "00000000"
    ) {
        self.inner = transport
        self.budget = budget
        self.probe = probe
        self.transfersShareMetadataChannel = transfersShareMetadataChannel
        self.uploadTag = uploadTag
    }

    /// How many times `-O exit` was run on this connection. `F6` counts it: the will-sleep
    /// drop takes every master, and the wake brings up new ones.
    public var shutdownCount: Int { lock.lock(); defer { lock.unlock() }; return _shutdowns }

    /// How many `statvfs` calls reached this connection. Section 8.1's free-space figure
    /// is taken at probe time and read from `capabilities.json` afterwards, so `status`
    /// must never move this number (2026-09-09).
    public var statvfsCount: Int { lock.lock(); defer { lock.unlock() }; return _statvfs }

    /// How many liveness checks reached this connection. On a real one this is
    /// `SSHBackedTransport.isMasterAlive()` -> `SSHMaster.check()`, which spawns
    /// `ssh -O check` and waits up to ten seconds for it; `status` answers online/offline
    /// from the gate instead and must never move this number (2026-09-09).
    public var aliveCheckCount: Int { lock.lock(); defer { lock.unlock() }; return _aliveChecks }

    /// The master dying under us without a call noticing - a `kill -9`, a link that went.
    public func killMaster() { lock.lock(); _alive = false; lock.unlock() }

    public var extensionNames: [String] { get async { [] } }
    public var execMaster: SSHMaster? { nil }
    public var metadataTransport: RealSFTPTransport? { nil }

    public func shutdown() async {
        lock.lock()
        _shutdowns += 1
        _alive = false
        lock.unlock()
    }

    public func isMasterAlive() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        _aliveChecks += 1
        return _alive
    }

    // MARK: SFTPTransport, forwarded

    public var extensions: SFTPServerExtensions { get async { await inner.extensions } }

    public func realpath(_ path: RelativePath) async throws -> String {
        try await inner.realpath(path)
    }
    public func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        try await inner.lstat(path)
    }
    public func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        try await inner.readdir(path)
    }
    public func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        try await inner.read(path, offset: offset, length: length)
    }
    public func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        try await inner.readStreaming(
            path, offset: offset, length: length, window: window, receiver: receiver)
    }
    public func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        try await inner.write(path, contents: contents, mode: mode)
    }
    public func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await inner.writeStreaming(
            path, mode: mode, window: window, source: source, progress: progress)
    }
    public func writeExclusive(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await inner.writeExclusive(
            path, mode: mode, window: window, source: source, progress: progress)
    }
    public func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        try await inner.mkdir(path, mode: mode)
    }
    public func remove(_ path: RelativePath) async throws { try await inner.remove(path) }
    public func rmdir(_ path: RelativePath) async throws { try await inner.rmdir(path) }
    public func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await inner.rename(source, to: destination)
    }
    public func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await inner.posixRename(source, to: destination)
    }
    public func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        try await inner.setstat(path, mode: mode, mtime: mtime)
    }
    public func symlink(target: String, at path: RelativePath) async throws {
        try await inner.symlink(target: target, at: path)
    }
    public func readlink(_ path: RelativePath) async throws -> String {
        try await inner.readlink(path)
    }
    public func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        lock.lock(); _statvfs += 1; lock.unlock()
        return try await inner.statvfs(path)
    }
}

/// What stands in for spawning `/usr/bin/ssh` (section 6.1).
///
/// A scenario stages the outcome of the *next* attempt - a connection, or a failure with a
/// named `SSHExitClassification`, which is what section 6.3's breaker branches on - and
/// reads back how many attempts were made and what each one produced. `connectionFactory`
/// is the hook `ServerModel` fills in: hand out a connection over its fake channels and
/// nothing above this changes.
public final class FakeTransportLauncher: TransportLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0
    private var _connections: [FakeLiveConnection] = []
    private var _failure: Error?
    private var _budget: ChannelBudget = .unrestricted
    private var _probe = ServerProbe.Result()
    /// Makes the transport each connection forwards to. One `FakeTransport` per attempt by
    /// default, so a reconnect really is a new connection.
    public var transportFactory: @Sendable (Location) -> any SFTPTransport = { location in
        FakeTransport(root: location.remotePath ?? "/srv/fake")
    }

    public init() {}

    public var attempts: Int { lock.lock(); defer { lock.unlock() }; return _attempts }
    /// Every connection handed out, oldest first. `F6` asserts each of the old ones was
    /// shut down and that a new one exists after the wake.
    public var connections: [FakeLiveConnection] {
        lock.lock(); defer { lock.unlock() }
        return _connections
    }
    public var live: FakeLiveConnection? {
        lock.lock(); defer { lock.unlock() }
        return _connections.last
    }

    /// Every attempt fails this way until `succeed()`. `classification` is what the
    /// breaker reads: `.transient` retries, `.authenticationDeadline` stops and waits for
    /// section 4.2's re-arm, `.authentication` waits for the user.
    public func fail(classification: SSHExitClassification = .transient, stderr: String = "fake") {
        lock.lock()
        _failure = SSHProcessError.connectionFailed(
            classification: classification, stderr: stderr)
        lock.unlock()
    }

    public func succeed(budget: ChannelBudget? = nil, probe: ServerProbe.Result? = nil) {
        lock.lock()
        _failure = nil
        if let budget { _budget = budget }
        if let probe { _probe = probe }
        lock.unlock()
    }

    public func connect(
        location: Location, askpassPath: String?, askpass: (any AskpassTokenProviding)?,
        uploadTag: String, reprobeChannels: Bool
    ) async throws -> any LiveConnection {
        lock.lock()
        _attempts += 1
        let failure = _failure
        let budget = _budget
        let probe = _probe
        let factory = transportFactory
        lock.unlock()
        if let failure { throw failure }
        let connection = FakeLiveConnection(
            transport: factory(location), budget: budget, probe: probe, uploadTag: uploadTag)
        lock.lock()
        _connections.append(connection)
        lock.unlock()
        return connection
    }
}
