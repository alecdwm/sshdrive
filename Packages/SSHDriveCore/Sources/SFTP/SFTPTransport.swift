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
