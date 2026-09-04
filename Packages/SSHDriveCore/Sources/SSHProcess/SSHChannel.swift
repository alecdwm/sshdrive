import Foundation

/// Accumulates a child's stderr on a thread of its own. `ssh` writes little of it and the
/// agent keeps all of it: stderr is what `sshdrive status` shows in every case (section 6.1).
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
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
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
/// (DESIGN.md section 9.2).
///
/// By the time one of these exists the opening sentinel has arrived and everything the
/// account's rc files printed is in `prefix`. `stream` is the script's own output from
/// there on, and the agent's heartbeat lines go back over `sendHeartbeat`.
public final class ExecChannel: @unchecked Sendable {
    public let stream: PipeByteStream
    /// What the account printed before the sentinel; `status` shows it (section 9.2).
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
    /// the wrapper on the server kills its child (section 6.4).
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
/// and nothing more; the wire protocol is section 6.2's problem.
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
    /// connection: the master outlives any one of them (section 6.1).
    public func close() {
        stream.close()
        Spawn.terminate(process, grace: 1)
    }

    public func exitStatus() -> ProcessExit? { Spawn.poll(pid: process.pid) }
}
