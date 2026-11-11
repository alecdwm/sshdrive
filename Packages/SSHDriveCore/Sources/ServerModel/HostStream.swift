import Foundation
import SSHProcess

/// One mux client's stdio as `FakeRemoteHost` serves it: the agent's end is a
/// `ByteStream`, the server's end is a pair of callbacks and an `emit`.
///
/// Three things set it apart from `FakeSFTPStream`:
///
/// - **Every read deadline is measured on the host's clock**, which in a scenario is the
///   agent's driven clock. A deadline the agent built from `clock.now()` therefore fires
///   in model time, never in real time.
/// - **It can stall.** While the link under it is half-open nothing moves in either
///   direction: what the agent writes is held, what the server emits is held, and reads
///   park until their own deadlines. `flush()` delivers both halves in order when the link
///   comes back.
/// - **It can be severed.** A master that dies takes every channel with it: the agent's
///   next read is EOF and its next write fails, exactly as a mux client whose master went
///   away behaves.
public final class HostStream: ByteStream, @unchecked Sendable {

    private enum Held { case data(Data), eof, close }

    private let clock: any TimeSource
    private let lock = NSLock()
    private var outbound = Data()
    private var outboundEOF = false
    private var heldOutbound = Data()
    private var heldOutboundEOF = false
    private var heldInput: [Held] = []
    private var waiter: (continuation: CheckedContinuation<Data, Error>, limit: Int, ticket: Int,
                         timer: Task<Void, Never>?)?
    private var nextTicket = 0
    private var clientClosed = false
    private var inputClosed = false
    private var severed = false
    private var stalledFlag = false
    private var closeReported = false

    /// What the server does with the agent's bytes. Called outside the stream's lock.
    var onInput: (@Sendable (Data) -> Void)?
    /// The agent closed its end of stdin.
    var onInputEOF: (@Sendable () -> Void)?
    /// The agent closed the channel.
    var onClientClose: (@Sendable () -> Void)?
    /// Bumped on every byte that moves, so a harness can tell a quiet system from a busy
    /// one.
    var onActivity: (@Sendable () -> Void)?

    init(clock: any TimeSource) { self.clock = clock }

    /// A stream whose far end is already gone: EOF on the first read.
    static func closed(clock: any TimeSource) -> HostStream {
        let stream = HostStream(clock: clock)
        stream.outboundEOF = true
        stream.severed = true
        return stream
    }

    // MARK: The agent's end

    public func read(upTo count: Int, deadline: Date) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !outbound.isEmpty {
                let take = min(outbound.count, count)
                let out = Data(outbound.prefix(take))
                outbound.removeFirst(take)
                lock.unlock()
                continuation.resume(returning: out)
                return
            }
            if outboundEOF || clientClosed {
                lock.unlock()
                continuation.resume(returning: Data())
                return
            }
            let wait = deadline.timeIntervalSince1970 - clock.now()
            if wait <= 0 {
                lock.unlock()
                continuation.resume(throwing: ByteStreamError.readTimedOut)
                return
            }
            nextTicket += 1
            let ticket = nextTicket
            // `.distantFuture` is the SFTP client's reader, which has no deadline of its
            // own; anything else is a real bound and gets a timer on the host's clock.
            var timer: Task<Void, Never>?
            if wait < 1e9 {
                let clock = self.clock
                timer = Task { [weak self] in
                    await clock.sleep(seconds: wait)
                    guard !Task.isCancelled else { return }
                    self?.timeOut(ticket: ticket)
                }
            }
            waiter = (continuation, count, ticket, timer)
            lock.unlock()
        }
    }

    private func timeOut(ticket: Int) {
        lock.lock()
        guard let pending = waiter, pending.ticket == ticket else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        pending.continuation.resume(throwing: ByteStreamError.readTimedOut)
    }

    public func write(_ data: Data) async throws {
        guard let handler = try accept(data) else { return }
        onActivity?()
        handler(data)
    }

    /// The synchronous half of `write`: an `NSLock` may not be taken in an `async`
    /// function. Answers the handler to call, or nil when the bytes were held.
    private func accept(_ data: Data) throws -> (@Sendable (Data) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        if clientClosed || inputClosed { throw ByteStreamError.closed }
        if severed { throw ByteStreamError.posix(EPIPE) }
        if stalledFlag {
            heldInput.append(.data(data))
            return nil
        }
        return onInput ?? { _ in }
    }

    public func closeWrite() {
        lock.lock()
        guard !inputClosed, !clientClosed else { lock.unlock(); return }
        inputClosed = true
        if stalledFlag || severed {
            if stalledFlag { heldInput.append(.eof) }
            lock.unlock()
            return
        }
        let handler = onInputEOF
        lock.unlock()
        handler?()
    }

    /// The agent closes the channel. The server hears it the way it hears anything else:
    /// at once over a working link, once a stall lifts, and never once the master is gone.
    public func close() {
        lock.lock()
        clientClosed = true
        let pending = waiter
        waiter = nil
        var report = !closeReported
        closeReported = true
        if report, severed {
            report = false
        } else if report, stalledFlag {
            heldInput.append(.close)
            report = false
        }
        let handler = onClientClose
        lock.unlock()
        pending?.timer?.cancel()
        pending?.continuation.resume(returning: Data())
        if report { handler?() }
    }

    // MARK: The server's end

    /// Output for the agent. Held while the stream is stalled.
    func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !severed, !clientClosed, !outboundEOF else { lock.unlock(); return }
        if stalledFlag {
            heldOutbound.append(data)
            lock.unlock()
            return
        }
        outbound.append(data)
        let handoff = takeForWaiter()
        lock.unlock()
        onActivity?()
        deliver(handoff)
    }

    /// The process exited: EOF once everything already emitted has been read.
    func finishOutput() {
        lock.lock()
        if stalledFlag {
            heldOutboundEOF = true
            lock.unlock()
            return
        }
        outboundEOF = true
        let handoff = takeForWaiter()
        lock.unlock()
        onActivity?()
        deliver(handoff)
    }

    /// The master died. What is already in the pipe can still be read; anything the
    /// stall was holding is lost with the connection.
    func sever() {
        lock.lock()
        severed = true
        stalledFlag = false
        heldOutbound.removeAll()
        heldInput.removeAll()
        outboundEOF = true
        let handoff = takeForWaiter()
        lock.unlock()
        onActivity?()
        deliver(handoff)
    }

    var isStalled: Bool { lock.withLock { stalledFlag } }

    func setStalled(_ value: Bool) {
        lock.lock()
        guard !severed else { lock.unlock(); return }
        stalledFlag = value
        guard !value else { lock.unlock(); return }
        // The link is back: what the server said while it was down arrives first, then
        // what the agent said is processed, in order.
        outbound.append(heldOutbound)
        heldOutbound.removeAll()
        if heldOutboundEOF { outboundEOF = true; heldOutboundEOF = false }
        let input = heldInput
        heldInput.removeAll()
        let handoff = takeForWaiter()
        let onInput = self.onInput
        let onEOF = self.onInputEOF
        let onClose = self.onClientClose
        lock.unlock()
        onActivity?()
        deliver(handoff)
        for item in input {
            switch item {
            case .data(let data): onInput?(data)
            case .eof: onEOF?()
            case .close: onClose?()
            }
        }
    }

    /// Hands the parked reader what it may take. Called with the lock held; the resume
    /// happens in `deliver`, outside it.
    private func takeForWaiter() -> (CheckedContinuation<Data, Error>, Data, Task<Void, Never>?)? {
        guard let pending = waiter else { return nil }
        if !outbound.isEmpty {
            waiter = nil
            let take = min(outbound.count, pending.limit)
            let out = Data(outbound.prefix(take))
            outbound.removeFirst(take)
            return (pending.continuation, out, pending.timer)
        }
        if outboundEOF {
            waiter = nil
            return (pending.continuation, Data(), pending.timer)
        }
        return nil
    }

    private func deliver(_ handoff: (CheckedContinuation<Data, Error>, Data, Task<Void, Never>?)?) {
        guard let (continuation, data, timer) = handoff else { return }
        timer?.cancel()
        continuation.resume(returning: data)
    }
}

/// An SFTP channel on a `FakeHostMaster`.
public final class HostSFTPChannel: RemoteSFTPChannel, @unchecked Sendable {
    public let stream: HostStream
    private let stderr: String
    init(stream: HostStream, stderr: String = "") {
        self.stream = stream
        self.stderr = stderr
    }
    public var stderrText: String { stderr }
    public func close() { stream.close() }
}

/// An exec channel on a `FakeHostMaster`, returned once the opening sentinel has
/// "arrived": `stream` carries the script's own output and nothing before it.
public final class HostExecChannel: RemoteExecChannel, @unchecked Sendable {
    public let stream: HostStream
    public let prefix: Data
    private let lock = NSLock()
    private var stderr = ""
    private var exit: ProcessExit?

    init(stream: HostStream, prefix: Data) {
        self.stream = stream
        self.prefix = prefix
    }

    public var stderrText: String { lock.withLock { stderr } }
    public func sendHeartbeat() async throws { try await stream.write(RemoteScript.heartbeatLine) }
    public func endInput() { stream.closeWrite() }
    public func close() { stream.close() }
    public func exitStatus() -> ProcessExit? { lock.withLock { exit } }

    func appendStderr(_ text: String) { lock.withLock { stderr += text } }
    func setExit(_ value: ProcessExit) { lock.withLock { if exit == nil { exit = value } } }
}
