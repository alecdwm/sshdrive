import Foundation

/// The SFTP version 3 wire format, written from the **server's** side.
///
/// Deliberately a second implementation rather than a reuse of `SFTP`'s own codec: a wire
/// server that shares the client's encoder can only ever agree with it, and the point of
/// `FakeSFTPServer` (`docs/testing-architecture.md` section 4.2) is that it "speaks the
/// protocol, not a mock of it". Everything here is byte-level and String-free, because a
/// server's names need not be valid UTF-8 (section 5.4).
enum SFTPWire {

    enum PacketType: UInt8 {
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
    /// `errno_to_portable` folds whole families into each of these, so `ENOSPC`,
    /// `EEXIST`, `ENOTEMPTY` and `EXDEV` all arrive as a bare `failure` (`SQ-028`).
    enum Status: UInt32, Error {
        case ok = 0
        case endOfFile = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case operationUnsupported = 8

        /// The message OpenSSH sends with it. `failure` is the literal "Failure", which is
        /// exactly why a second question is the only way to tell its causes apart.
        var message: String {
            switch self {
            case .ok: return "Success"
            case .endOfFile: return "End of file"
            case .noSuchFile: return "No such file"
            case .permissionDenied: return "Permission denied"
            case .failure: return "Failure"
            case .badMessage: return "Bad message"
            case .noConnection: return "No connection"
            case .connectionLost: return "Connection lost"
            case .operationUnsupported: return "Operation unsupported"
            }
        }
    }

    enum AttributeFlags {
        static let size: UInt32 = 0x0000_0001
        static let uidgid: UInt32 = 0x0000_0002
        static let permissions: UInt32 = 0x0000_0004
        static let accessModifiedTime: UInt32 = 0x0000_0008
        static let extended: UInt32 = 0x8000_0000
    }

    enum OpenFlags {
        static let read: UInt32 = 0x0000_0001
        static let write: UInt32 = 0x0000_0002
        static let append: UInt32 = 0x0000_0004
        static let create: UInt32 = 0x0000_0008
        static let truncate: UInt32 = 0x0000_0010
        static let exclusive: UInt32 = 0x0000_0020
    }

    enum ModeBits {
        static let formatMask: UInt32 = 0xF000
        static let regular: UInt32 = 0x8000
        static let directory: UInt32 = 0x4000
        static let symlink: UInt32 = 0xA000
    }

    /// Builds one packet: a four-byte big-endian length, the type byte, then the body.
    struct Writer {
        private var bytes: [UInt8] = []

        init(_ type: PacketType, requestID: UInt32? = nil) {
            bytes.reserveCapacity(64)
            bytes.append(contentsOf: [0, 0, 0, 0])
            bytes.append(type.rawValue)
            if let requestID { writeUInt32(requestID) }
        }

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

    /// Reads one packet body. Every accessor throws rather than trapping: the bytes come
    /// from a client, and a server that traps on a short packet is a server that cannot
    /// be used to test one.
    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        struct Truncated: Error {}

        var remaining: Int { bytes.count - offset }

        mutating func readUInt32() throws -> UInt32 {
            guard remaining >= 4 else { throw Truncated() }
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
            guard length >= 0, remaining >= length else { throw Truncated() }
            defer { offset += length }
            return Data(bytes[offset ..< (offset + length)])
        }

        mutating func readText() throws -> String {
            String(decoding: try readString(), as: UTF8.self)
        }

        /// The v3 ATTRS structure the client sends with `open`, `setstat` and `mkdir`.
        mutating func readAttributes() throws -> Attributes {
            var attributes = Attributes()
            let flags = try readUInt32()
            if flags & AttributeFlags.size != 0 { attributes.size = try readUInt64() }
            if flags & AttributeFlags.uidgid != 0 {
                attributes.uid = try readUInt32()
                attributes.gid = try readUInt32()
            }
            if flags & AttributeFlags.permissions != 0 {
                attributes.permissions = try readUInt32()
            }
            if flags & AttributeFlags.accessModifiedTime != 0 {
                attributes.atime = try readUInt32()
                attributes.mtime = try readUInt32()
            }
            if flags & AttributeFlags.extended != 0 {
                let count = try readUInt32()
                for _ in 0 ..< count { _ = try readString(); _ = try readString() }
            }
            return attributes
        }
    }

    struct Attributes {
        var size: UInt64?
        var uid: UInt32?
        var gid: UInt32?
        var permissions: UInt32?
        var atime: UInt32?
        var mtime: UInt32?
    }

    /// One packet, already framed out of the stream.
    struct Packet {
        var type: UInt8
        /// The body after the type byte, request id included.
        var body: [UInt8]
        var packetType: PacketType? { PacketType(rawValue: type) }
        func reader() -> Reader { Reader(body) }
    }

    /// Splits a byte buffer into whole packets, leaving the remainder in place.
    static func frame(_ scratch: inout [UInt8]) -> [Packet] {
        var packets: [Packet] = []
        var start = 0
        while scratch.count - start >= 4 {
            let length = Int(scratch[start]) << 24 | Int(scratch[start + 1]) << 16
                | Int(scratch[start + 2]) << 8 | Int(scratch[start + 3])
            guard length >= 1, scratch.count - start >= 4 + length else { break }
            let type = scratch[start + 4]
            let body = Array(scratch[(start + 5) ..< (start + 4 + length)])
            packets.append(Packet(type: type, body: body))
            start += 4 + length
        }
        if start > 0 { scratch.removeFirst(start) }
        return packets
    }
}
