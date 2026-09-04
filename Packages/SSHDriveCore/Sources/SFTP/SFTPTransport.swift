import Foundation

/// The SFTP surface the rest of the app talks to (DESIGN.md section 6.2).
///
/// Every method takes a `RelativePath`; the transport joins it to the canonical root
/// itself (section 9.1). Two implementations exist: `FakeTransport` from milestone 1,
/// which stays as the test double for every later milestone, and the real SFTP v3 wire
/// client over the ssh process's stdio, which arrives in milestone 2.
public protocol SFTPTransport: AnyObject, Sendable {

    /// Which OpenSSH extensions the server offered.
    var extensions: SFTPServerExtensions { get async }

    /// SFTP realpath, used at add time to canonicalise the root and on every connection
    /// to confirm it has not moved (section 9.1).
    func realpath(_ path: RelativePath) async throws -> String

    /// lstat semantics: links are leaf items and are never followed (section 9.1).
    func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes

    /// One directory listing. Pages are requested back to back by the real client; the
    /// protocol hands back the whole directory because every caller wants it all.
    func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry]

    /// Reads a byte range. `length` of nil means "to EOF".
    func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data

    /// Streams a byte range to `receiver` without ever holding the whole file, at
    /// `window` requests in flight - the scheduler's share of the pipelined window
    /// (section 6.2). Returns the number of bytes delivered.
    func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64

    /// Streams to `path`, pulling at most `chunk` bytes at a time from `source` until it
    /// returns an empty `Data`. `progress` is called with the running total. The upload
    /// still goes through a temp file and a rename (section 5.5); what this adds over
    /// `write` is that a 64 MiB upload never sits in the agent's memory.
    func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// Writes whole contents, through the temp-file plus rename dance of section 5.5 in
    /// the real client. `mode` is the permission bits the temp file is opened with.
    func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws

    func mkdir(_ path: RelativePath, mode: UInt32) async throws

    /// Plain SFTP remove. Fails on a directory.
    func remove(_ path: RelativePath) async throws

    /// Fails when the directory is not empty; the caller confirms with a readdir, since
    /// the wire carries no ENOTEMPTY (section 6.2).
    func rmdir(_ path: RelativePath) async throws

    /// The plain, non-overwriting SFTP rename that section 5.5 relies on.
    func rename(_ source: RelativePath, to destination: RelativePath) async throws

    /// posix-rename@openssh.com: overwrites. Used for content replacement (section 5.5).
    func posixRename(_ source: RelativePath, to destination: RelativePath) async throws

    func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws

    /// OpenSSH's SSH2_FXP_SYMLINK takes targetpath first, then linkpath, the opposite
    /// order from the draft (section 6.2). That is the transport's problem, not this
    /// protocol's: the arguments here are named.
    func symlink(target: String, at path: RelativePath) async throws

    func readlink(_ path: RelativePath) async throws -> String

    /// statvfs@openssh.com, where the server offers it.
    func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats
}


/// Defaults, so a transport that has nothing better to offer than whole-file reads and
/// writes - `FakeTransport`, and anything a test stands in with - satisfies the protocol
/// without pretending to stream. The real client overrides both.
extension SFTPTransport {
    public func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        let data = try await read(path, offset: offset, length: length.map { Int($0) })
        guard !data.isEmpty else { return 0 }
        // Handed over in chunks even here, so a scheduler test sees more than one
        // progress report and a cancel has somewhere to land.
        let chunk = 64 * 1024
        var delivered: UInt64 = 0
        var cursor = 0
        while cursor < data.count {
            if Task.isCancelled { throw SFTPError.cancelled }
            let size = min(chunk, data.count - cursor)
            let start = data.index(data.startIndex, offsetBy: cursor)
            let piece = Data(data[start..<data.index(start, offsetBy: size)])
            await receiver(offset + UInt64(cursor), piece)
            delivered += UInt64(size)
            cursor += size
        }
        return delivered
    }

    public func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var contents = Data()
        while true {
            if Task.isCancelled { throw SFTPError.cancelled }
            let piece = try source()
            if piece.isEmpty { break }
            contents.append(piece)
            progress(Int64(contents.count))
        }
        try await write(path, contents: contents, mode: mode)
    }
}
