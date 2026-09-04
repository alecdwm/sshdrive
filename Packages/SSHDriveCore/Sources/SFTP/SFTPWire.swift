import Foundation

// The SFTP version 3 wire format (draft-ietf-secsh-filexfer-02), plus the two packet
// types the OpenSSH extensions ride on. DESIGN.md section 6.2: we implement the protocol
// ourselves rather than take a library, so this file is the whole of the framing.
//
// Everything here is byte-level and deliberately String-free: server names need not be
// valid UTF-8 (section 5.4), so a `string` on the wire is a `Data`, never a `String`,
// except for the few fields the protocol defines as UTF-8 text (status messages).

// MARK: - Packet types

enum SFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

/// The nine status codes SFTP v3 carries. There is no errno on the wire: OpenSSH's
/// `errno_to_portable` folds whole families into each of these (DESIGN.md section 6.2).
enum SFTPStatusCode: UInt32 {
    case ok = 0
    case endOfFile = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case operationUnsupported = 8

    /// The error class this status maps to, or nil for `ok`. This mapping is the whole
    /// of the client's error taxonomy; nothing finer exists on the wire.
    func asError(message: String) -> SFTPError? {
        switch self {
        case .ok: return nil
        case .endOfFile: return .eof
        case .noSuchFile: return .noSuchFile
        case .permissionDenied: return .permissionDenied
        case .failure: return .failure(message.isEmpty ? "Failure" : message)
        case .badMessage: return .badMessage
        case .noConnection: return .noConnection
        case .connectionLost: return .connectionLost
        case .operationUnsupported: return .operationUnsupported
        }
    }
}

/// The ATTRS bitmask of SFTP v3.
enum SFTPAttributeFlags {
    static let size: UInt32 = 0x0000_0001
    static let uidgid: UInt32 = 0x0000_0002
    static let permissions: UInt32 = 0x0000_0004
    static let accessModifiedTime: UInt32 = 0x0000_0008
    static let extended: UInt32 = 0x8000_0000
}

/// The `pflags` of SSH_FXP_OPEN.
public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x0000_0001)
    public static let write = SFTPOpenFlags(rawValue: 0x0000_0002)
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    public static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    public static let truncate = SFTPOpenFlags(rawValue: 0x0000_0010)
    /// With `create`, fails when the path exists. This is what makes an upload's temp
    /// file safe to open (section 5.5).
    public static let exclusive = SFTPOpenFlags(rawValue: 0x0000_0020)
}

/// The POSIX file-type bits carried in the permissions word.
enum SFTPFileModeBits {
    static let formatMask: UInt32 = 0xF000
    static let regular: UInt32 = 0x8000
    static let directory: UInt32 = 0x4000
    static let symlink: UInt32 = 0xA000

    static func type(fromMode mode: UInt32) -> SFTPFileType {
        switch mode & formatMask {
        case regular: return .file
        case directory: return .directory
        case symlink: return .symlink
        default: return .other
        }
    }
}

// MARK: - The OpenSSH extension names section 6.2 lists

enum SFTPExtensionName {
    static let posixRename = "posix-rename@openssh.com"
    static let statvfs = "statvfs@openssh.com"
    static let fstatvfs = "fstatvfs@openssh.com"
    static let fsync = "fsync@openssh.com"
    static let limits = "limits@openssh.com"
    static let lsetstat = "lsetstat@openssh.com"
}

// MARK: - Attributes

/// A decoded ATTRS structure. Every field is optional because the flags word says which
/// of them the server actually sent.
struct SFTPRawAttributes {
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var atime: UInt32?
    var mtime: UInt32?

    static let empty = SFTPRawAttributes()

    /// Converts to the model type. `fallbackType` is used when the server did not send
    /// permissions, which is legal in v3; readdir recovers the type from `longname`.
    func fileAttributes(fallbackType: SFTPFileType = .other, symlinkTarget: String? = nil)
        -> SFTPFileAttributes
    {
        let mode = permissions ?? 0
        let type = permissions == nil ? fallbackType : SFTPFileModeBits.type(fromMode: mode)
        return SFTPFileAttributes(
            type: type,
            size: Int64(clamping: size ?? 0),
            mtime: Int64(mtime ?? 0),
            // Only the permission bits; the format bits are carried by `type`.
            mode: mode & 0o7777,
            uid: uid ?? 0,
            gid: gid ?? 0,
            // SFTP v3 has whole-second times only. Nanoseconds and inode come from the
            // sweep or the helper (section 5.3), never from here, and nil means
            // "record whatever comes next without comparing".
            mtimeNanoseconds: nil,
            inode: nil,
            symlinkTarget: symlinkTarget)
    }
}

/// The attributes an outgoing setstat/open carries. Only the fields that are set are
/// sent, so a mode-only setstat does not clobber the times.
public struct SFTPSettableAttributes: Sendable, Equatable {
    public var permissions: UInt32?
    public var size: UInt64?
    public var accessTime: UInt32?
    public var modifiedTime: UInt32?

    public init(
        permissions: UInt32? = nil, size: UInt64? = nil,
        accessTime: UInt32? = nil, modifiedTime: UInt32? = nil
    ) {
        self.permissions = permissions
        self.size = size
        self.accessTime = accessTime
        self.modifiedTime = modifiedTime
    }

    public static let none = SFTPSettableAttributes()
    public var isEmpty: Bool {
        permissions == nil && size == nil && accessTime == nil && modifiedTime == nil
    }
}

// MARK: - Writing

/// Builds one packet: a four-byte big-endian length, the type byte, and the body.
struct SFTPPacketWriter {
    private(set) var bytes: [UInt8] = []

    init(_ type: SFTPPacketType, requestID: UInt32? = nil) {
        bytes.reserveCapacity(64)
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(type.rawValue)
        if let requestID { writeUInt32(requestID) }
    }

    mutating func writeByte(_ value: UInt8) { bytes.append(value) }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32(truncatingIfNeeded: value >> 32))
        writeUInt32(UInt32(truncatingIfNeeded: value))
    }

    mutating func writeString(_ value: Data) {
        writeUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func writeString(_ value: String) { writeString(Data(value.utf8)) }

    mutating func writeAttributes(_ attributes: SFTPSettableAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPAttributeFlags.size }
        if attributes.permissions != nil { flags |= SFTPAttributeFlags.permissions }
        // ACMODTIME is one flag for both times, so setting either sends both.
        if attributes.accessTime != nil || attributes.modifiedTime != nil {
            flags |= SFTPAttributeFlags.accessModifiedTime
        }
        writeUInt32(flags)
        if let size = attributes.size { writeUInt64(size) }
        if let permissions = attributes.permissions { writeUInt32(permissions) }
        if attributes.accessTime != nil || attributes.modifiedTime != nil {
            let now = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
            writeUInt32(attributes.accessTime ?? now)
            writeUInt32(attributes.modifiedTime ?? now)
        }
    }

    /// Patches the length prefix and hands back the finished packet.
    func finish() -> Data {
        var out = bytes
        let length = UInt32(out.count - 4)
        out[0] = UInt8(truncatingIfNeeded: length >> 24)
        out[1] = UInt8(truncatingIfNeeded: length >> 16)
        out[2] = UInt8(truncatingIfNeeded: length >> 8)
        out[3] = UInt8(truncatingIfNeeded: length)
        return Data(out)
    }
}

// MARK: - Reading

/// Reads one packet body. Every accessor throws `.badMessage` on truncation rather than
/// trapping, because the bytes come from a server we do not control.
struct SFTPPacketReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    init(_ data: Data) { self.init([UInt8](data)) }

    var remaining: Int { bytes.count - offset }

    /// How many bytes of the packet body have been consumed. The extension replies hand
    /// the rest of the body to a second reader.
    var consumedCount: Int { offset }

    mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPError.badMessage }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.badMessage }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = try readUInt32()
        let low = try readUInt32()
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard length >= 0, remaining >= length else { throw SFTPError.badMessage }
        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }

    /// For the fields the protocol defines as text. Lossy on purpose: a status message is
    /// for a log line, never for a path.
    mutating func readText() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    mutating func readAttributes() throws -> SFTPRawAttributes {
        var attributes = SFTPRawAttributes()
        let flags = try readUInt32()
        if flags & SFTPAttributeFlags.size != 0 { attributes.size = try readUInt64() }
        if flags & SFTPAttributeFlags.uidgid != 0 {
            attributes.uid = try readUInt32()
            attributes.gid = try readUInt32()
        }
        if flags & SFTPAttributeFlags.permissions != 0 {
            attributes.permissions = try readUInt32()
        }
        if flags & SFTPAttributeFlags.accessModifiedTime != 0 {
            attributes.atime = try readUInt32()
            attributes.mtime = try readUInt32()
        }
        if flags & SFTPAttributeFlags.extended != 0 {
            let count = try readUInt32()
            // Bounded by the packet: readString throws on truncation, so a bogus count
            // cannot spin.
            for _ in 0..<count {
                _ = try readString()
                _ = try readString()
            }
        }
        return attributes
    }
}

// MARK: - Replies

/// One entry of an SSH_FXP_NAME reply.
struct SFTPNameReplyEntry {
    var filename: Data
    var longname: Data
    var attributes: SFTPRawAttributes

    /// `-rw-r--r-- 1 alec alec 12 Jan 1 00:00 name`: the first character is the type, and
    /// it is the only source when the server sent no permissions.
    var typeFromLongname: SFTPFileType {
        guard let first = longname.first else { return .other }
        switch first {
        case UInt8(ascii: "d"): return .directory
        case UInt8(ascii: "l"): return .symlink
        case UInt8(ascii: "-"): return .file
        default: return .other
        }
    }
}

/// A parsed reply packet, before the caller decides what it wanted.
enum SFTPReply {
    case status(SFTPStatusCode, String)
    case handle(Data)
    case data(Data)
    case name([SFTPNameReplyEntry])
    case attributes(SFTPRawAttributes)
    /// The body of an SSH_FXP_EXTENDED_REPLY, past the request id.
    case extendedReply(Data)

    /// Turns a non-OK status into a throw and everything else into a pass-through.
    func rejectingStatus() throws -> SFTPReply {
        if case .status(let code, let message) = self, let error = code.asError(message: message) {
            throw error
        }
        return self
    }

    func expectHandle() throws -> Data {
        switch try rejectingStatus() {
        case .handle(let handle): return handle
        default: throw SFTPError.badMessage
        }
    }

    func expectAttributes() throws -> SFTPRawAttributes {
        switch try rejectingStatus() {
        case .attributes(let attributes): return attributes
        default: throw SFTPError.badMessage
        }
    }

    func expectNames() throws -> [SFTPNameReplyEntry] {
        switch try rejectingStatus() {
        case .name(let entries): return entries
        default: throw SFTPError.badMessage
        }
    }

    func expectExtendedReply() throws -> Data {
        switch try rejectingStatus() {
        case .extendedReply(let body): return body
        default: throw SFTPError.badMessage
        }
    }

    /// SSH_FXP_STATUS with OK is the success reply for close, remove, rename and friends.
    func expectOK() throws {
        _ = try rejectingStatus()
    }
}
