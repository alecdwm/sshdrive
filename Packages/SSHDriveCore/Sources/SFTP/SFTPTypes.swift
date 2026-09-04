import Foundation

/// The item types File Provider has a place for. Sockets, FIFOs and device nodes that a
/// readdir reports are never enumerated and never get a row (DESIGN.md section 5.4).
public enum SFTPFileType: String, Sendable, Codable {
    case file
    case directory
    case symlink
    /// Anything else readdir reported. Dropped by the enumerator.
    case other
}

/// What an SFTP v3 lstat gives us, plus the two fields only the helper or a GNU sweep
/// can report (DESIGN.md section 5.3). `mtimeNanoseconds` and `inode` are nil when
/// unknown, and nil means "record whatever comes next without comparing".
public struct SFTPFileAttributes: Sendable, Equatable {
    public var type: SFTPFileType
    public var size: Int64
    /// Whole seconds, as SFTP v3 reports.
    public var mtime: Int64
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var mtimeNanoseconds: Int64?
    public var inode: UInt64?
    /// The raw target string of a symlink, exactly as the server gave it. Never joined
    /// to a remote path or resolved on the server (section 9.1).
    public var symlinkTarget: String?

    public init(
        type: SFTPFileType,
        size: Int64 = 0,
        mtime: Int64 = 0,
        mode: UInt32 = 0o644,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        mtimeNanoseconds: Int64? = nil,
        inode: UInt64? = nil,
        symlinkTarget: String? = nil
    ) {
        self.type = type
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
        self.symlinkTarget = symlinkTarget
    }
}

/// One readdir entry. The name is bytes: it need not be valid UTF-8.
public struct SFTPDirectoryEntry: Sendable, Equatable {
    public var name: Data
    public var attributes: SFTPFileAttributes

    public init(name: Data, attributes: SFTPFileAttributes) {
        self.name = name
        self.attributes = attributes
    }
}

/// The reply to statvfs@openssh.com, which is how a full or over-quota filesystem is
/// told apart from any other bare FAILURE (DESIGN.md sections 5.1, 6.2).
public struct SFTPFilesystemStats: Sendable, Equatable {
    public var blockSize: UInt64
    public var totalBlocks: UInt64
    public var availableBlocks: UInt64
    public var totalInodes: UInt64
    public var availableInodes: UInt64

    public init(
        blockSize: UInt64, totalBlocks: UInt64, availableBlocks: UInt64,
        totalInodes: UInt64, availableInodes: UInt64
    ) {
        self.blockSize = blockSize
        self.totalBlocks = totalBlocks
        self.availableBlocks = availableBlocks
        self.totalInodes = totalInodes
        self.availableInodes = availableInodes
    }

    public var isFull: Bool { availableBlocks == 0 || availableInodes == 0 }
}

/// Which OpenSSH extensions the server offered. Every server-dependent feature has a
/// fallback, and `sshdrive status` shows the tier each feature runs at (section 8.1).
public struct SFTPServerExtensions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let posixRename = SFTPServerExtensions(rawValue: 1 << 0)
    public static let statvfs = SFTPServerExtensions(rawValue: 1 << 1)
    public static let fsync = SFTPServerExtensions(rawValue: 1 << 2)
    public static let limits = SFTPServerExtensions(rawValue: 1 << 3)
    public static let lsetstat = SFTPServerExtensions(rawValue: 1 << 4)
}

/// The error classes the wire can actually carry (DESIGN.md section 6.2). OpenSSH's
/// `errno_to_portable` folds ENOENT, ENOTDIR and ELOOP into NO_SUCH_FILE, EPERM and
/// EACCES into PERMISSION_DENIED, EINVAL and ENAMETOOLONG into BAD_MESSAGE, ENOSYS into
/// OP_UNSUPPORTED, and everything else, ENOSPC, EDQUOT, EEXIST, ENOTEMPTY and EXDEV
/// included, into FAILURE with the literal message "Failure".
///
/// The client exposes exactly these and nothing finer. Every place that wants to know
/// more asks a second question: an lstat, a statvfs, a readdir.
public enum SFTPError: Error, Equatable, Sendable {
    case noSuchFile
    case permissionDenied
    /// A bare FAILURE. Could be ENOSPC, EDQUOT, EEXIST, ENOTEMPTY, EXDEV or anything else.
    case failure(String)
    case badMessage
    case operationUnsupported
    case noConnection
    case connectionLost
    /// The request missed its deadline (20 s for metadata, scaled by size for transfers).
    case deadlineExceeded
    /// The caller's Task was cancelled: the extension's `Progress` was cancelled, or the
    /// transfer's XPC connection went away, and the agent abandoned the SFTP requests in
    /// flight (sections 5.2, 6.2).
    case cancelled
    case eof
}
