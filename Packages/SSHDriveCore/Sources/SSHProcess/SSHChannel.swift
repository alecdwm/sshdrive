import Foundation
import Logging

/// Accumulates a child's stderr on a thread of its own. `ssh` writes little of it and the
/// agent keeps all of it: stderr is what `sshdrive status` shows in every case
/// (docs/design/ssh.md).
final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var finished = false
    private let limit: Int

    init(fd: Int32, limit: Int = 64 * 1024) {
        self.limit = limit
        guard fd >= 0 else { finished = true; return }
        let thread = Thread { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 8 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { sshRead(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    self?.append(Array(chunk[0 ..< n]))
                    continue
                }
                if n < 0, errno == EINTR { continue }
                break
            }
            close(fd)
            self?.finish()
        }
        thread.name = "org.shirls.sshdrive.ssh.stderr"
        thread.start()
    }

    private func append(_ new: [UInt8]) {
        lock.lock()
        if bytes.count < limit { bytes.append(contentsOf: new.prefix(limit - bytes.count)) }
        lock.unlock()
    }

    private func finish() { lock.lock(); finished = true; lock.unlock() }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// An exec channel: a mux client running `ssh $MUX <host> sh -s` with a script on stdin
/// (docs/design/security.md).
///
/// By the time one of these exists the opening sentinel has arrived and everything the
/// account's rc files printed is in `prefix`. `stream` is the script's own output from
/// there on, and the agent's heartbeat lines go back over `sendHeartbeat`.
public final class ExecChannel: @unchecked Sendable {
    public let stream: PipeByteStream
    /// What the account printed before the sentinel; `status` shows it
    /// (docs/design/security.md).
    public let prefix: Data
    public let sentinel: Sentinel
    private let process: SpawnedProcess
    private let stderrCollector: StderrCollector

    init(stream: PipeByteStream, prefix: Data, sentinel: Sentinel,
         process: SpawnedProcess, stderrCollector: StderrCollector) {
        self.stream = stream
        self.prefix = prefix
        self.sentinel = sentinel
        self.process = process
        self.stderrCollector = stderrCollector
    }

    public var pid: pid_t { process.pid }
    public var stderrText: String { stderrCollector.text }

    /// One heartbeat line. The agent writes one every 15 s; 60 s of silence, or EOF, and
    /// the wrapper on the server kills its child (docs/design/change-detection.md).
    public func sendHeartbeat() async throws {
        try await stream.write(RemoteScript.heartbeatLine)
    }

    /// Closes stdin, which the wrapper reads as EOF and treats exactly as a dead agent.
    public func endInput() { stream.closeWrite() }

    public func close() {
        stream.close()
        Spawn.terminate(process, grace: 1)
    }

    /// Nil while still running.
    public func exitStatus() -> ProcessExit? { Spawn.poll(pid: process.pid) }

    public func waitForExit() -> ProcessExit { Spawn.wait(pid: process.pid) }
}

/// An SFTP channel: `ssh $MUX -s <host> sftp`. Handed to the SFTP client as a byte stream
/// and nothing more; the wire protocol belongs to the SFTP client
/// (docs/design/sftp.md).
public final class SFTPChannel: @unchecked Sendable {
    public let stream: PipeByteStream
    private let process: SpawnedProcess
    private let stderrCollector: StderrCollector

    init(stream: PipeByteStream, process: SpawnedProcess, stderrCollector: StderrCollector) {
        self.stream = stream
        self.process = process
        self.stderrCollector = stderrCollector
    }

    public var pid: pid_t { process.pid }
    public var stderrText: String { stderrCollector.text }

    /// A wedged SFTP channel is killed and reopened on its own without touching the
    /// connection: the master outlives any one of them (docs/design/ssh.md).
    public func close() {
        stream.close()
        Spawn.terminate(process, grace: 1)
    }

    public func exitStatus() -> ProcessExit? { Spawn.poll(pid: process.pid) }
}

/// What killed an exec channel, once it has an exit (docs/design/ssh.md,
/// docs/design/change-detection.md).
///
/// `ssh` answers **255** both for a failure of its own and for a remote command killed by
/// a signal, and in the second case it prints **nothing at all** on stderr (`SQ-011`,
/// measured on `ts-ssh`, 2026-09-08). The two mean opposite things to the agent. Its own
/// failure is a channel that never opened, which for a mux client is always master lost
/// (docs/design/ssh.md) and takes the connection down with it. A signal-killed remote
/// command is
/// **the wrapper on the server** dying with the connection still perfectly good, and the
/// answer is to start the tier again, not to rebuild the master.
///
/// Nothing in the exit status tells them apart. The channel's own history does: this one
/// had opened, which is what `channelOpened: true` carries into the classifier, and it is
/// the whole of the rule.
///
/// The exit status and the stderr are carried and logged **whichever** it was: "an outage
/// that is silently swallowed" is the failure this defends. Without them a helper that
/// dies on a real server leaves one sentence in the log, "the helper exited", with no
/// status, no signal and no stderr to say why.
public struct ExecChannelDeath: Sendable, Equatable {
    /// What the caller noticed - an EOF, a read error, a `ready` that never came.
    public var reason: String
    /// Nil while the mux client has not been reaped at all.
    public var exit: ProcessExit?
    /// Everything `ssh` wrote, kept for `sshdrive status` (docs/design/ssh.md).
    public var stderr: String
    public var classification: SSHExitClassification
    /// `SQ-011`'s exact signature: exit **255**, `ssh` itself not signalled, and
    /// **nothing** on stderr, on a channel that had opened - the remote command was
    /// killed by a signal and `ssh` is only relaying that.
    ///
    /// **Inferred** from the measurement rather than measured on its own: `ssh` writes a
    /// line of its own for every failure of its own (`SQ-035` is a statement about those
    /// lines), so an empty stderr on a channel that opened leaves the remote end as the
    /// only candidate. Confidence: high for OpenSSH, and the row itself was measured on
    /// the Tailscale node.
    public var isSignalKilledRemoteCommand: Bool
    /// The sentence the log carries: the reason, the exit status or the signal, and the
    /// tail of stderr.
    public var summary: String

    /// The tail of stderr a log line carries. `ssh` writes little, and all of it is kept
    /// for `status`; the log gets the end of it.
    public static let stderrTailLimit = 500

    public init(reason: String, exit: ProcessExit?, stderr: String) {
        self.reason = reason
        self.exit = exit
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.stderr = stderr
        var parts: [String] = []
        if let exit {
            if let signal = exit.signal {
                parts.append("the channel was killed by signal \(signal)")
            } else {
                parts.append("the channel exited \(exit.status)")
            }
        } else {
            parts.append("the channel is still running")
        }
        if trimmed.isEmpty {
            parts.append("nothing on stderr")
        } else {
            parts.append("stderr: \(String(trimmed.suffix(ExecChannelDeath.stderrTailLimit)))")
        }
        summary = "\(reason) (\(parts.joined(separator: "; ")))"
        guard let exit else {
            classification = .transient
            isSignalKilledRemoteCommand = false
            return
        }
        // The channel had opened: `channelOpened: true` is the difference between "the
        // remote command died" and "the mux client could not get a channel", which is the
        // one thing the exit status cannot say (`SQ-011`).
        classification = SSHExitClassifier.classify(
            role: .muxClient, exitStatus: exit.status, terminationSignal: exit.signal,
            stderr: stderr, channelOpened: true)
        isSignalKilledRemoteCommand =
            exit.status == 255 && exit.signal == nil && trimmed.isEmpty
    }
}

extension ExecChannel {

    /// Reaps the mux client and reports what killed the channel, at `error`, **with the
    /// exit status and the stderr in the line** (`SQ-011`).
    ///
    /// The one grace sleep is not politeness: the mux client is usually a hair behind the
    /// EOF that brought the caller here, and a report written before it has exited says
    /// "still running" about a channel that is already dead.
    @discardableResult
    public func reportDeath(
        reason: String, grace: TimeInterval = 0.3
    ) async -> ExecChannelDeath {
        var exit = exitStatus()
        let deadline = Date().addingTimeInterval(grace)
        while exit == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
            exit = exitStatus()
        }
        let death = ExecChannelDeath(reason: reason, exit: exit, stderr: stderrText)
        Log.ssh.error("the exec channel died: \(death.summary, privacy: .public)")
        return death
    }
}
