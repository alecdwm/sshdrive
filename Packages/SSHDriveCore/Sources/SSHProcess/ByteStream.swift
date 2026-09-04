import Foundation

/// A bidirectional byte pipe with an async read and a write.
///
/// This is what an exec channel is, once the sentinel has been stripped: the child `ssh`
/// process's stdin and stdout, and it is also exactly what an SFTP channel is
/// (`ssh $MUX -s <host> sftp`), so the SFTP wire client of DESIGN.md section 6.2 sits on
/// this same protocol rather than a second one of its own: `SFTP` depends on
/// `SSHProcess`, which is the side that produces a channel. `SFTP`'s own
/// `SFTPByteStream` was merged into this on 2026-09-04.
///
/// `read` returning an empty `Data` means end of stream. Every read takes a deadline,
/// without exception: the `deb-shells` `bashbg` account leaves a background child holding
/// stdout, so EOF simply never arrives, and a read that waits for it hangs for ever
/// (testbed README, section 9.2).
public protocol ByteStream: AnyObject, Sendable {
    /// Up to `count` bytes, or fewer. Empty means EOF. Throws `.readTimedOut` at `deadline`.
    func read(upTo count: Int, deadline: Date) async throws -> Data
    /// Writes all of `data`.
    func write(_ data: Data) async throws
    /// Closes our end of the child's stdin; the child sees EOF.
    func closeWrite()
    /// Tears both halves down.
    func close()
}

public enum ByteStreamError: Error, LocalizedError, Equatable {
    case readTimedOut
    case closed
    case posix(Int32)

    public var errorDescription: String? {
        switch self {
        case .readTimedOut: return "Timed out reading from the ssh channel."
        case .closed: return "The ssh channel is closed."
        case let .posix(code): return "ssh channel I/O failed: \(String(cString: strerror(code)))."
        }
    }
}

/// `ByteStream` over a pair of file descriptors, which for us is always a child `ssh`
/// process's stdout and stdin.
///
/// A dedicated reader thread doing a blocking `read(2)` rather than `DispatchIO` or
/// `FileHandle.readabilityHandler`: the channel must keep draining while the agent is
/// blocked writing a script, and both alternatives run on a shared queue where one wedged
/// channel would stall the others.
public final class PipeByteStream: ByteStream, @unchecked Sendable {
    private let readFD: Int32
    private var writeFD: Int32
    /// A condition rather than a plain lock, because the reader thread has to be able to
    /// wait: the buffer is bounded, and the bound is the backpressure that stops a 1 GB
    /// SFTP transfer outrunning the parser into memory (section 6.2).
    private let lock = NSCondition()
    private let bufferLimit: Int
    private var buffer: [UInt8] = []
    /// How far into `buffer` the consumer has read. A cursor rather than a
    /// `removeFirst` per read: on the bulk transfer path this buffer holds megabytes and
    /// shifting it down on every 256 KiB read would copy the whole window each time.
    private var bufferStart = 0
    private var atEOF = false
    private var failure: Int32?
    private var waiter: (continuation: CheckedContinuation<Data, Error>, max: Int, id: UInt64)?
    private var nextWaiterID: UInt64 = 0
    private var closedFlag = false
    private let writeQueue: DispatchQueue

    public init(
        readFD: Int32, writeFD: Int32, label: String = "ssh-channel",
        bufferLimit: Int = 4 * 1024 * 1024
    ) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.bufferLimit = bufferLimit
        self.writeQueue = DispatchQueue(label: "org.shirls.sshdrive.\(label).write")
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "org.shirls.sshdrive.\(label).read"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock()
            while !closedFlag && waiter == nil && (buffer.count - bufferStart) >= bufferLimit {
                lock.wait()
            }
            let stop = closedFlag
            lock.unlock()
            if stop { return }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if n > 0 {
                deliver(bytes: Array(chunk[0 ..< n]), eof: false, error: nil)
                continue
            }
            if n == 0 { deliver(bytes: [], eof: true, error: nil); return }
            if errno == EINTR { continue }
            deliver(bytes: [], eof: true, error: errno)
            return
        }
    }

    private func deliver(bytes: [UInt8], eof: Bool, error: Int32?) {
        lock.lock()
        appendLocked(bytes)
        if eof { atEOF = true }
        if let error, error != 0, failure == nil { failure = error }
        guard let pending = waiter else { lock.unlock(); return }
        if let data = takeLocked(max: pending.max) {
            waiter = nil
            lock.broadcast()
            lock.unlock()
            pending.continuation.resume(returning: data)
            return
        }
        if atEOF {
            waiter = nil
            let err = failure
            lock.broadcast()
            lock.unlock()
            if let err, err != 0 {
                pending.continuation.resume(throwing: ByteStreamError.posix(err))
            } else {
                pending.continuation.resume(returning: Data())
            }
            return
        }
        lock.unlock()
    }

    /// Caller holds the lock. Returns nil when there is nothing to hand over yet.
    private func takeLocked(max: Int) -> Data? {
        let available = buffer.count - bufferStart
        guard available > 0 else { return nil }
        let n = Swift.min(max, available)
        let out = Data(buffer[bufferStart ..< bufferStart + n])
        bufferStart += n
        if bufferStart == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            bufferStart = 0
        }
        return out
    }

    /// Caller holds the lock. Compacts when the consumed prefix has grown past half the
    /// buffer, so the cursor cannot let it grow without bound.
    private func appendLocked(_ bytes: [UInt8]) {
        if bufferStart > 0, bufferStart >= buffer.count - bufferStart {
            buffer.removeFirst(bufferStart)
            bufferStart = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// Returns bytes to the front of the buffer. Used by the sentinel scan, which reads
    /// past the marker and must not swallow the payload that followed it in the same read.
    public func pushBack(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.insert(contentsOf: [UInt8](data), at: bufferStart)
        lock.unlock()
    }

    public func read(upTo count: Int, deadline: Date) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closedFlag {
                lock.unlock(); continuation.resume(throwing: ByteStreamError.closed); return
            }
            if let data = takeLocked(max: count) {
                lock.broadcast()
                lock.unlock(); continuation.resume(returning: data); return
            }
            if atEOF {
                let error = failure
                lock.unlock()
                if let error, error != 0 {
                    continuation.resume(throwing: ByteStreamError.posix(error))
                } else {
                    continuation.resume(returning: Data())
                }
                return
            }
            nextWaiterID += 1
            let id = nextWaiterID
            waiter = (continuation, count, id)
            // A waiter outranks the bound: the consumer is asking for bytes, so the
            // reader thread must not be parked on a full buffer.
            lock.broadcast()
            lock.unlock()
            // A wall-clock timer rather than task cancellation: the reader thread is
            // blocked in read(2) and cannot be interrupted, so the deadline has to be the
            // caller's, and it must fire even if nothing is ever written again.
            let delay = deadline.timeIntervalSinceNow
            // `.distantFuture` means "no deadline"; adding it to a DispatchTime overflows.
            guard delay < 86_400 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + Swift.max(0, delay)) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let pending = self.waiter, pending.id == id else { self.lock.unlock(); return }
                self.waiter = nil
                self.lock.unlock()
                pending.continuation.resume(throwing: ByteStreamError.readTimedOut)
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else { return continuation.resume(throwing: ByteStreamError.closed) }
                self.lock.lock()
                let fd = self.writeFD
                let closed = self.closedFlag
                self.lock.unlock()
                guard !closed, fd >= 0 else {
                    return continuation.resume(throwing: ByteStreamError.closed)
                }
                let bytes = [UInt8](data)
                var offset = 0
                while offset < bytes.count {
                    let n = bytes.withUnsafeBytes {
                        Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
                    }
                    if n > 0 { offset += n; continue }
                    if errno == EINTR { continue }
                    return continuation.resume(throwing: ByteStreamError.posix(errno))
                }
                continuation.resume(returning: ())
            }
        }
    }

    public func closeWrite() {
        lock.lock()
        let fd = writeFD
        writeFD = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    public func close() {
        closeWrite()
        lock.lock()
        guard !closedFlag else { lock.unlock(); return }
        closedFlag = true
        buffer.removeAll()
        bufferStart = 0
        let pending = waiter
        waiter = nil
        lock.broadcast()
        lock.unlock()
        Darwin.close(readFD)
        pending?.continuation.resume(throwing: ByteStreamError.closed)
    }
}

public extension ByteStream {
    /// The deadline-free spelling the SFTP client uses. It applies a deadline per
    /// *request* and not per read (section 6.2): one dead read would otherwise have to
    /// stand in for every request waiting behind it, and the client's own sweeper is what
    /// decides which request missed. Every other caller passes a real deadline, because
    /// EOF is not a reliable end (`bashbg`, testbed README).
    func read(upTo count: Int) async throws -> Data {
        try await read(upTo: count, deadline: .distantFuture)
    }

    /// Reads until the closure says stop or the deadline passes, handing every chunk over.
    /// The only read loop in the module, so the deadline rule has one place to live.
    func drain(
        deadline: Date,
        onChunk: (Data) throws -> Bool
    ) async throws {
        while true {
            let chunk = try await read(upTo: 64 * 1024, deadline: deadline)
            if chunk.isEmpty { return }   // EOF
            if try onChunk(chunk) { return }
        }
    }
}
