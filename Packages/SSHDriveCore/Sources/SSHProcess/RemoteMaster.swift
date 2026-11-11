import Foundation

/// Wall-clock time and a sleep, as the deadline loops below `AgentRuntime` read them.
///
/// `AgentRuntime.AgentClock` refines this, so the agent hands its injected clock straight
/// to `RemoteSweep`, `ServerProbe` and `SFTPClient`, which cannot see `AgentRuntime`. Every
/// parameter that takes one defaults to `SystemTimeSource`, which is `Date()` and
/// `Task.sleep`, so a call site that passes nothing behaves exactly as the system clock
/// says.
///
/// A deadline handed to `ByteStream.read(upTo:deadline:)` is built from `now()`, so a
/// stream that is not a real pipe can compare it against the same clock.
public protocol TimeSource: Sendable {
    /// Wall clock, seconds since 1970.
    func now() -> Double
    /// Returns after `seconds`, or early when the calling task is cancelled. It never
    /// throws: a cancelled sleep simply returns, as `try? await Task.sleep` does.
    func sleep(seconds: Double) async
}

public extension TimeSource {
    /// `now() + seconds`, as the `Date` a `ByteStream` read takes.
    func deadline(after seconds: Double) -> Date {
        Date(timeIntervalSince1970: now() + seconds)
    }
}

/// `Date()` and `Task.sleep`.
public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// An exec channel, as everything that runs a script on one uses it: `ServerProbe`,
/// `RemoteSweep`, the helper's deployment and its stream (docs/design/security.md).
///
/// By the time a caller holds one the opening sentinel has arrived, everything the
/// account's rc files printed is in `prefix`, and `stream` carries the script's own
/// output. `ExecChannel` is the mux client that ships; a test can stand anything in its
/// place that speaks the same bytes.
public protocol RemoteExecChannel: AnyObject, Sendable {
    associatedtype Stream: ByteStream
    var stream: Stream { get }
    /// What the account printed before the sentinel.
    var prefix: Data { get }
    /// Everything the channel's `ssh` wrote on stderr so far.
    var stderrText: String { get }
    /// One heartbeat line for the wrapper on the server.
    func sendHeartbeat() async throws
    /// Closes the channel's stdin, which the wrapper reads as EOF.
    func endInput()
    func close()
    /// Nil while the channel is still running.
    func exitStatus() -> ProcessExit?
}

/// An SFTP channel: a byte stream the SFTP wire client sits on, and the stderr that
/// explains a channel that never spoke SFTP (docs/design/sftp.md).
public protocol RemoteSFTPChannel: AnyObject, Sendable {
    associatedtype Stream: ByteStream
    var stream: Stream { get }
    var stderrText: String { get }
    func close()
}

/// An authenticated connection that channels are opened on: everything downstream of
/// `SSHMaster.connect()` - the SFTP channels, the channel probe, the server probe, the
/// sweep, the helper's deployment and its stream - and nothing that spawns or
/// authenticates (docs/design/ssh.md).
///
/// `SSHMaster` is the implementation that ships. The protocol exists so the whole connect
/// path after authentication can run against an in-process server.
///
/// Called on `any RemoteMaster`, the channel-opening methods answer
/// `any RemoteExecChannel` and `any RemoteSFTPChannel`, and `stream` on either answers
/// `any ByteStream`.
public protocol RemoteMaster: AnyObject, Sendable {
    associatedtype ExecChannelType: RemoteExecChannel
    associatedtype SFTPChannelType: RemoteSFTPChannel

    /// Whether the master process is still there. Cheap and local.
    var isRunning: Bool { get async }
    /// What the master wrote on stderr when it last ended or failed to start.
    var lastStderr: String { get async }
    /// `-O check`: whether our own master answers on its socket.
    func check() async -> Bool
    /// `-O exit`, and the master with it.
    func shutdown() async
    /// `ssh $MUX -s <host> sftp`.
    func openSFTPChannel(readinessDeadline: TimeInterval) async throws -> SFTPChannelType
    /// `ssh $MUX <host> sh -s` with the script on stdin, returned once the opening
    /// sentinel has arrived. Throws `SSHProcessError.noShellAccess`,
    /// `.shellOutputUnusable` or `.channelFailed` the way `SSHMaster` does.
    func openExecChannel(script: RemoteScript, readinessDeadline: TimeInterval) async throws
        -> ExecChannelType
}

extension SSHMaster: RemoteMaster {}
extension ExecChannel: RemoteExecChannel {}
extension SFTPChannel: RemoteSFTPChannel {}
