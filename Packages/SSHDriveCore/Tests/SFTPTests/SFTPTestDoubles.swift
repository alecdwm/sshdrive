import Foundation
import XCTest

@testable import SFTP
import SSHProcess

/// A status the in-memory server wants to answer with.
struct ServerStatus: Error {
    let code: SFTPStatusCode
}

/// One packet the client wrote, already split out of the stream.
struct WirePacket {
    var type: UInt8
    /// The body after the type byte, request id included.
    var body: [UInt8]

    var packetType: SFTPPacketType? { SFTPPacketType(rawValue: type) }

    /// A reader positioned just past the type byte.
    func reader() -> SFTPPacketReader { SFTPPacketReader(body) }

    /// The request id, for every packet type that carries one.
    var requestID: UInt32 {
        var reader = self.reader()
        return (try? reader.readUInt32()) ?? 0
    }
}

/// A byte stream with a programmable other end (DESIGN.md section 6.2's "tested against
/// `sftp-server` directly on stdio without any network", minus even the stdio).
///
/// Everything the client writes is split into packets and handed to `responder`, which
/// may answer at once, answer later, or never answer at all - which is how the deadline
/// and pipelining behaviour is tested without a server.
final class ScriptedByteStream: ByteStream, @unchecked Sendable {

    typealias Responder = @Sendable (WirePacket, ScriptedByteStream) -> Void

    private let lock = NSLock()
    private var outbound = Data()
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    private var inboundScratch = [UInt8]()
    private var recorded: [WirePacket] = []
    private var responderStorage: Responder?

    var responder: Responder? {
        get { lock.lock(); defer { lock.unlock() }; return responderStorage }
        set { lock.lock(); responderStorage = newValue; lock.unlock() }
    }

    /// Every packet the client has written so far.
    var written: [WirePacket] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func writtenPackets(ofType type: SFTPPacketType) -> [WirePacket] {
        written.filter { $0.type == type.rawValue }
    }

    // MARK: Answering

    /// Queues a finished packet for the client to read.
    func push(_ packet: Data) {
        lock.lock()
        if let waiter, outbound.isEmpty {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: packet)
            return
        }
        outbound.append(packet)
        let pending = waiter
        waiter = nil
        var handoff = Data()
        if pending != nil {
            handoff = outbound
            outbound = Data()
        }
        lock.unlock()
        pending?.resume(returning: handoff)
    }

    func pushStatus(id: UInt32, _ code: SFTPStatusCode, message: String = "") {
        var writer = SFTPPacketWriter(.status, requestID: id)
        writer.writeUInt32(code.rawValue)
        writer.writeString(message)
        push(writer.finish())
    }

    /// The SSH_FXP_VERSION every handshake needs, with the extension list the test wants.
    func pushVersion(_ version: UInt32 = 3, extensions: [String]) {
        var writer = SFTPPacketWriter(.version)
        writer.writeUInt32(version)
        for name in extensions {
            writer.writeString(name)
            writer.writeString("1")
        }
        push(writer.finish())
    }

    // MARK: ByteStream

    /// The deadline is the client's own business (section 6.2), and this double never
    /// answers late by accident: a test that wants a request to miss its deadline simply
    /// does not answer it at all.
    func read(upTo maxLength: Int, deadline: Date) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.takeOrPark(maxLength: maxLength, continuation: continuation)
        }
    }

    private func takeOrPark(
        maxLength: Int, continuation: CheckedContinuation<Data, Error>
    ) {
        lock.lock()
        if !outbound.isEmpty {
            let take = min(outbound.count, maxLength)
            let out = outbound.prefix(take)
            outbound.removeFirst(take)
            lock.unlock()
            continuation.resume(returning: Data(out))
            return
        }
        if closed {
            lock.unlock()
            continuation.resume(returning: Data())
            return
        }
        waiter = continuation
        lock.unlock()
    }

    func write(_ data: Data) async throws {
        try acceptWrite(data)
    }

    private func acceptWrite(_ data: Data) throws {
        lock.lock()
        if closed {
            lock.unlock()
            throw SFTPError.connectionLost
        }
        inboundScratch.append(contentsOf: data)
        var packets: [WirePacket] = []
        var start = 0
        while inboundScratch.count - start >= 4 {
            let length =
                Int(inboundScratch[start]) << 24 | Int(inboundScratch[start + 1]) << 16
                | Int(inboundScratch[start + 2]) << 8 | Int(inboundScratch[start + 3])
            guard inboundScratch.count - start >= 4 + length, length >= 1 else { break }
            let type = inboundScratch[start + 4]
            let body = Array(inboundScratch[(start + 5)..<(start + 4 + length)])
            packets.append(WirePacket(type: type, body: body))
            start += 4 + length
        }
        if start > 0 { inboundScratch.removeFirst(start) }
        recorded.append(contentsOf: packets)
        let responder = responderStorage
        lock.unlock()
        for packet in packets { responder?(packet, self) }
    }

    func closeWrite() {}

    func close() {
        closeNow()
    }

    private func closeNow() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: Data())
    }
}

/// A small `sftp-server` in memory, speaking the wire.
///
/// It is not the fake backend of milestone 1 - that is `FakeTransport`, which sits above
/// the protocol. This one sits below it, so `RealSFTPTransport` and every byte of the
/// codec are exercised end to end without a network, which is what section 6.2 claims is
/// the easy part of this project to test exhaustively.
final class InMemorySFTPServer: @unchecked Sendable {

    struct Node {
        var type: SFTPFileType
        var contents: Data = Data()
        var mode: UInt32 = 0o644
        var mtime: Int64 = 1_700_000_000
        var target: Data?
    }

    private let lock = NSLock()
    private(set) var nodes: [Data: Node] = [:]
    private var handles: [Data: Data] = [:]
    private var directoryPages: [Data: [[Data]]] = [:]
    private var nextHandle = 1

    var advertisedExtensions: [String] = [
        SFTPExtensionName.posixRename,
        SFTPExtensionName.statvfs,
        SFTPExtensionName.fsync,
        SFTPExtensionName.limits,
        SFTPExtensionName.lsetstat,
    ]
    var limits = SFTPLimits(
        maxPacketLength: 34000, maxReadLength: 32768, maxWriteLength: 32768, maxOpenHandles: 100)
    var readdirPageSize = 100
    /// Serve short reads, to exercise the client's "ask for the rest" path.
    var shortReadFactor = 1.0
    var availableBlocks: UInt64 = 1000

    let root = Data("/home/alec/root".utf8)

    init() {
        nodes[root] = Node(type: .directory, mode: 0o755)
    }

    // MARK: Seeding

    func put(_ path: String, contents: Data, mode: UInt32 = 0o644) {
        lock.lock()
        nodes[absolute(path)] = Node(type: .file, contents: contents, mode: mode)
        lock.unlock()
    }

    func putDirectory(_ path: String, mode: UInt32 = 0o755) {
        lock.lock()
        nodes[absolute(path)] = Node(type: .directory, mode: mode)
        lock.unlock()
    }

    func putRawName(_ name: Data, contents: Data) {
        lock.lock()
        var path = root
        path.append(0x2F)
        path.append(name)
        nodes[path] = Node(type: .file, contents: contents)
        lock.unlock()
    }

    func contents(of path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[absolute(path)]?.contents
    }

    func exists(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes[absolute(path)] != nil
    }

    /// Every path that exists, for the "no temp file left behind" assertions.
    var allPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return nodes.keys.map { String(decoding: $0, as: UTF8.self) }.sorted()
    }

    private func absolute(_ path: String) -> Data {
        if path.isEmpty { return root }
        var out = root
        out.append(0x2F)
        out.append(Data(path.utf8))
        return out
    }

    // MARK: The responder

    func responder() -> ScriptedByteStream.Responder {
        { [weak self] packet, stream in
            self?.handle(packet, stream)
        }
    }

    private func handle(_ packet: WirePacket, _ stream: ScriptedByteStream) {
        guard let type = packet.packetType else { return }
        if type == .initialize {
            stream.pushVersion(3, extensions: advertisedExtensions)
            return
        }
        var reader = packet.reader()
        guard let id = try? reader.readUInt32() else { return }
        do {
            try answer(type: type, id: id, reader: &reader, stream: stream)
        } catch let error as ServerStatus {
            stream.pushStatus(id: id, error.code)
        } catch {
            stream.pushStatus(id: id, .failure, message: "Failure")
        }
    }

    private func attributesPacket(_ node: Node, into writer: inout SFTPPacketWriter) {
        writer.writeUInt32(
            SFTPAttributeFlags.size | SFTPAttributeFlags.uidgid
                | SFTPAttributeFlags.permissions | SFTPAttributeFlags.accessModifiedTime)
        writer.writeUInt64(UInt64(node.contents.count))
        writer.writeUInt32(501)
        writer.writeUInt32(20)
        writer.writeUInt32(formatBits(node) | (node.mode & 0o7777))
        writer.writeUInt32(UInt32(node.mtime))
        writer.writeUInt32(UInt32(node.mtime))
    }

    private func formatBits(_ node: Node) -> UInt32 {
        switch node.type {
        case .directory: return SFTPFileModeBits.directory
        case .symlink: return SFTPFileModeBits.symlink
        default: return SFTPFileModeBits.regular
        }
    }

    private func children(of path: Data) -> [Data] {
        var prefix = path
        prefix.append(0x2F)
        return nodes.keys.filter { candidate in
            guard candidate.count > prefix.count, candidate.starts(with: prefix) else {
                return false
            }
            return !candidate.dropFirst(prefix.count).contains(0x2F)
        }.sorted { String(decoding: $0, as: UTF8.self) < String(decoding: $1, as: UTF8.self) }
    }

    private func answer(
        type: SFTPPacketType, id: UInt32, reader: inout SFTPPacketReader,
        stream: ScriptedByteStream
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        switch type {
        case .realpath:
            let path = try reader.readString()
            var writer = SFTPPacketWriter(.name, requestID: id)
            writer.writeUInt32(1)
            writer.writeString(path)
            writer.writeString(path)
            writer.writeUInt32(0)
            stream.push(writer.finish())

        case .lstat, .stat:
            let path = try reader.readString()
            guard let node = nodes[path] else { throw ServerStatus(code: .noSuchFile) }
            var writer = SFTPPacketWriter(.attrs, requestID: id)
            attributesPacket(node, into: &writer)
            stream.push(writer.finish())

        case .fstat:
            let handle = try reader.readString()
            guard let path = handles[handle], let node = nodes[path] else {
                throw ServerStatus(code: .failure)
            }
            var writer = SFTPPacketWriter(.attrs, requestID: id)
            attributesPacket(node, into: &writer)
            stream.push(writer.finish())

        case .setstat:
            let path = try reader.readString()
            let attributes = try reader.readAttributes()
            guard var node = nodes[path] else { throw ServerStatus(code: .noSuchFile) }
            if let permissions = attributes.permissions { node.mode = permissions & 0o7777 }
            if let mtime = attributes.mtime { node.mtime = Int64(mtime) }
            nodes[path] = node
            stream.pushStatus(id: id, .ok)

        case .open:
            let path = try reader.readString()
            let flags = SFTPOpenFlags(rawValue: try reader.readUInt32())
            let attributes = try reader.readAttributes()
            if nodes[path] == nil {
                guard flags.contains(.create) else { throw ServerStatus(code: .noSuchFile) }
                nodes[path] = Node(
                    type: .file, mode: (attributes.permissions ?? 0o644) & 0o7777)
            } else if flags.contains(.exclusive) && flags.contains(.create) {
                throw ServerStatus(code: .failure)
            } else if flags.contains(.truncate) {
                nodes[path]?.contents = Data()
            }
            let handle = makeHandle()
            handles[handle] = path
            var writer = SFTPPacketWriter(.handle, requestID: id)
            writer.writeString(handle)
            stream.push(writer.finish())

        case .opendir:
            let path = try reader.readString()
            guard nodes[path]?.type == .directory else { throw ServerStatus(code: .noSuchFile) }
            let handle = makeHandle()
            handles[handle] = path
            let all = children(of: path)
            var pages: [[Data]] = []
            var index = 0
            while index < all.count {
                pages.append(Array(all[index..<min(index + readdirPageSize, all.count)]))
                index += readdirPageSize
            }
            directoryPages[handle] = pages
            var writer = SFTPPacketWriter(.handle, requestID: id)
            writer.writeString(handle)
            stream.push(writer.finish())

        case .readdir:
            let handle = try reader.readString()
            guard var pages = directoryPages[handle], !pages.isEmpty else {
                stream.pushStatus(id: id, .endOfFile)
                return
            }
            let page = pages.removeFirst()
            directoryPages[handle] = pages
            var writer = SFTPPacketWriter(.name, requestID: id)
            writer.writeUInt32(UInt32(page.count))
            for path in page {
                guard let node = nodes[path] else { continue }
                var name = path
                if let slash = path.lastIndex(of: 0x2F) {
                    name = Data(path[path.index(after: slash)...])
                }
                writer.writeString(name)
                let kind = node.type == .directory ? "d" : (node.type == .symlink ? "l" : "-")
                writer.writeString(Data("\(kind)rw-r--r-- 1 alec alec".utf8))
                attributesPacket(node, into: &writer)
            }
            stream.push(writer.finish())

        case .close:
            let handle = try reader.readString()
            handles.removeValue(forKey: handle)
            directoryPages.removeValue(forKey: handle)
            stream.pushStatus(id: id, .ok)

        case .read:
            let handle = try reader.readString()
            let offset = try reader.readUInt64()
            let length = Int(try reader.readUInt32())
            guard let path = handles[handle], let node = nodes[path] else {
                throw ServerStatus(code: .failure)
            }
            guard offset < UInt64(node.contents.count) else {
                stream.pushStatus(id: id, .endOfFile)
                return
            }
            let start = Int(offset)
            let want = max(1, Int(Double(length) * shortReadFactor))
            let end = min(node.contents.count, start + want)
            var writer = SFTPPacketWriter(.data, requestID: id)
            writer.writeString(node.contents.subdata(in: start..<end))
            stream.push(writer.finish())

        case .write:
            let handle = try reader.readString()
            let offset = Int(try reader.readUInt64())
            let payload = try reader.readString()
            guard let path = handles[handle], var node = nodes[path] else {
                throw ServerStatus(code: .failure)
            }
            if node.contents.count < offset + payload.count {
                node.contents.append(
                    Data(repeating: 0, count: offset + payload.count - node.contents.count))
            }
            node.contents.replaceSubrange(offset..<(offset + payload.count), with: payload)
            nodes[path] = node
            stream.pushStatus(id: id, .ok)

        case .mkdir:
            let path = try reader.readString()
            let attributes = try reader.readAttributes()
            guard nodes[path] == nil else { throw ServerStatus(code: .failure) }
            nodes[path] = Node(type: .directory, mode: (attributes.permissions ?? 0o755) & 0o7777)
            stream.pushStatus(id: id, .ok)

        case .rmdir:
            let path = try reader.readString()
            guard nodes[path]?.type == .directory else { throw ServerStatus(code: .noSuchFile) }
            guard children(of: path).isEmpty else { throw ServerStatus(code: .failure) }
            nodes.removeValue(forKey: path)
            stream.pushStatus(id: id, .ok)

        case .remove:
            let path = try reader.readString()
            guard let node = nodes[path] else { throw ServerStatus(code: .noSuchFile) }
            guard node.type != .directory else { throw ServerStatus(code: .failure) }
            nodes.removeValue(forKey: path)
            stream.pushStatus(id: id, .ok)

        case .rename:
            let source = try reader.readString()
            let destination = try reader.readString()
            guard let node = nodes[source] else { throw ServerStatus(code: .noSuchFile) }
            // The plain rename never overwrites (section 5.5).
            guard nodes[destination] == nil else { throw ServerStatus(code: .failure) }
            nodes.removeValue(forKey: source)
            nodes[destination] = node
            stream.pushStatus(id: id, .ok)

        case .readlink:
            let path = try reader.readString()
            guard let node = nodes[path], node.type == .symlink, let target = node.target else {
                throw ServerStatus(code: .noSuchFile)
            }
            var writer = SFTPPacketWriter(.name, requestID: id)
            writer.writeUInt32(1)
            writer.writeString(target)
            writer.writeString(target)
            writer.writeUInt32(0)
            stream.push(writer.finish())

        case .symlink:
            // OpenSSH's order: target first, then the link path (section 6.2).
            let target = try reader.readString()
            let linkPath = try reader.readString()
            guard nodes[linkPath] == nil else { throw ServerStatus(code: .failure) }
            nodes[linkPath] = Node(type: .symlink, mode: 0o777, target: target)
            stream.pushStatus(id: id, .ok)

        case .extended:
            let name = try reader.readText()
            switch name {
            case SFTPExtensionName.limits:
                var writer = SFTPPacketWriter(.extendedReply, requestID: id)
                writer.writeUInt64(limits.maxPacketLength)
                writer.writeUInt64(limits.maxReadLength)
                writer.writeUInt64(limits.maxWriteLength)
                writer.writeUInt64(limits.maxOpenHandles)
                stream.push(writer.finish())
            case SFTPExtensionName.posixRename:
                let source = try reader.readString()
                let destination = try reader.readString()
                guard let node = nodes[source] else { throw ServerStatus(code: .noSuchFile) }
                nodes.removeValue(forKey: source)
                nodes[destination] = node
                stream.pushStatus(id: id, .ok)
            case SFTPExtensionName.fsync:
                stream.pushStatus(id: id, .ok)
            case SFTPExtensionName.lsetstat:
                let path = try reader.readString()
                let attributes = try reader.readAttributes()
                guard var node = nodes[path] else { throw ServerStatus(code: .noSuchFile) }
                if let permissions = attributes.permissions { node.mode = permissions & 0o7777 }
                nodes[path] = node
                stream.pushStatus(id: id, .ok)
            case SFTPExtensionName.statvfs:
                _ = try reader.readString()
                var writer = SFTPPacketWriter(.extendedReply, requestID: id)
                writer.writeUInt64(4096)  // f_bsize
                writer.writeUInt64(4096)  // f_frsize
                writer.writeUInt64(2048)  // f_blocks
                writer.writeUInt64(availableBlocks)  // f_bfree
                writer.writeUInt64(availableBlocks)  // f_bavail
                writer.writeUInt64(100)  // f_files
                writer.writeUInt64(50)  // f_ffree
                writer.writeUInt64(50)  // f_favail
                stream.push(writer.finish())
            default:
                stream.pushStatus(id: id, .operationUnsupported, message: "Unsupported")
            }

        default:
            stream.pushStatus(id: id, .operationUnsupported, message: "Unsupported")
        }
    }

    private func makeHandle() -> Data {
        defer { nextHandle += 1 }
        return Data("h\(nextHandle)".utf8)
    }
}

