import Foundation
import Logging

/// Writes a transfer's chunks into the file handle the extension opened on its temp file
/// (DESIGN.md section 5.2).
///
/// Chunks arrive in whatever order the pipelined reads land (section 6.2), so each one is
/// written at its own offset rather than appended. The handle belongs to the extension and
/// crosses XPC; the agent never resolves, and is never allowed to reach, a path inside the
/// extension's container.
final class HandleSink: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var highWaterMark: Int64 = 0
    private var bytes: Int64 = 0
    private var failure: Error?

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Bytes delivered so far, which is what the progress callback reports.
    var written: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func truncate() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.truncate(atOffset: 0)
        highWaterMark = 0
        bytes = 0
        failure = nil
    }

    func write(at offset: UInt64, data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
            highWaterMark = max(highWaterMark, Int64(offset) + Int64(data.count))
        } catch {
            // Kept and rethrown at `finish`, because the receiver the wire client calls
            // cannot throw: a failure here must not be mistaken for a short file.
            failure = error
            Log.agent.error("writing a fetched chunk failed: \(error, privacy: .public)")
        }
    }

    /// Flushes, and rethrows whatever a chunk write hit.
    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        try handle.synchronize()
    }
}

/// Reads an upload's bytes out of the file handle the extension opened on the new
/// contents, a chunk at a time, so a large upload never sits in the agent's memory
/// (section 6.2).
final class HandleSource: @unchecked Sendable {
    private let handle: FileHandle
    private let chunk: Int
    private let lock = NSLock()
    private var read: Int64 = 0

    init(handle: FileHandle, chunk: Int = 1024 * 1024) {
        self.handle = handle
        self.chunk = chunk
    }

    var bytesRead: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return read
    }

    /// The next chunk, or an empty `Data` at end of file.
    func next() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = try handle.read(upToCount: chunk) ?? Data()
        read += Int64(data.count)
        return data
    }
}
