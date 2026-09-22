import Foundation
import SSHProcess

/// A real SFTP v3 **wire** server over a `ByteStream`, driven by a `ServerProfile`.
///
/// It speaks the protocol, not a mock of it (docs/design/testing.md): `SFTPClient` and
/// `RealSFTPTransport` run against it unmodified, because an SFTP channel
/// *is* a `ByteStream` - the same protocol a mux client's stdio satisfies - so every byte
/// of the client's codec, its pipelining, its deadlines and its extension handling are
/// exercised with no network and no server.
///
/// It is not `SFTP.FakeTransport`, which sits *above* the protocol and stays the fast
/// double for tests that do not care about the wire.
///
/// The rules it applies, each from `docs/quirks/servers.md`:
///
/// - `SQ-024`/`SQ-025`/`SQ-026` the advertised extension list, in the profile's order.
/// - `SQ-027` `limits@openssh.com` sizes the request, not the window.
/// - `SQ-028` nine status codes and no errno: `ENOSPC`, `EEXIST`, `ENOTEMPTY` and
///   `EXDEV` all arrive as a bare `FAILURE` with the literal message "Failure".
/// - `SQ-029` `SSH2_FXP_SYMLINK` takes target first, then link path.
/// - `SQ-030` `opendir` **follows a symlink**.
/// - `SQ-031` `readdir` carries attributes but no link target.
/// - `SQ-032` a write over a running executable is `ETXTBSY`, which on the wire is a bare
///   `FAILURE`.
/// - `SQ-033` `mkdir`'s attributes go through the server's umask.
/// - `SQ-034` a plain `rename` overwrites or refuses, by profile.
public final class FakeSFTPServer: @unchecked Sendable {

    public struct Node: Sendable, Equatable {
        public var type: SFTPNodeType
        public var contents: Data
        /// Permission bits only; the format bits come from `type`.
        public var mode: UInt32
        public var mtime: Int64
        public var uid: UInt32
        public var gid: UInt32
        /// The raw target bytes of a symlink, exactly as the server would give them.
        public var target: Data?

        public init(
            type: SFTPNodeType, contents: Data = Data(), mode: UInt32? = nil,
            mtime: Int64 = 1_700_000_000, uid: UInt32 = 1000, gid: UInt32 = 1000,
            target: Data? = nil
        ) {
            self.type = type
            self.contents = contents
            self.mode = mode ?? (type == .directory ? 0o755 : (type == .symlink ? 0o777 : 0o644))
            self.mtime = mtime
            self.uid = uid
            self.gid = gid
            self.target = target
        }
    }

    public enum SFTPNodeType: String, Sendable, Equatable {
        case file, directory, symlink, fifo, socket
    }

    public let profile: ServerProfile
    /// The canonical root the client's `RelativePath`s are joined to.
    public let root: String

    private let lock = NSLock()
    private var nodes: [Data: Node] = [:]
    private var handles: [Data: Data] = [:]
    private var directoryPages: [Data: [[Data]]] = [:]
    private var nextHandle = 1
    private var requestLog: [String] = []
    private var readdirRequestCount = 0

    /// Paths a write must fail on with `ETXTBSY` - a bare `FAILURE` on the wire
    /// (`SQ-032`). The temp-name-and-rename path is what gets past it.
    public var runningExecutables: Set<String> = []
    /// Paths the account may not read or traverse, so `PERMISSION_DENIED` is reachable
    /// without a real uid.
    public var denied: Set<String> = []
    /// Zero means a full filesystem, which the wire reports as a bare `FAILURE` on write
    /// and only `statvfs` can explain (`SQ-028`).
    public var availableBlocks: UInt64 = 100_000
    public var readdirPageSize = 100
    /// Serve short reads, to exercise the client's "ask for the rest" path.
    public var shortReadFactor = 1.0

    public init(profile: ServerProfile, root: String? = nil) {
        self.profile = profile
        self.root = root ?? profile.home
        nodes[Data(self.root.utf8)] = Node(type: .directory, mode: 0o755)
    }

    // MARK: - Seeding

    /// An absolute path from one relative to the root.
    public func absolute(_ path: String) -> Data {
        if path.isEmpty || path == "." { return Data(root.utf8) }
        if path.hasPrefix("/") { return Data(path.utf8) }
        return Data("\(root)/\(path)".utf8)
    }

    public func put(_ path: String, contents: Data = Data(), mode: UInt32 = 0o644,
                    mtime: Int64 = 1_700_000_000) {
        lock.withLock {
            nodes[absolute(path)] = Node(
                type: .file, contents: contents, mode: mode, mtime: mtime)
        }
    }

    public func putDirectory(_ path: String, mode: UInt32 = 0o755) {
        lock.withLock { nodes[absolute(path)] = Node(type: .directory, mode: mode) }
    }

    /// A symlink whose target is stored verbatim and never resolved on the server, exactly
    /// as path containment requires of the client's side too (docs/design/security.md).
    public func putSymlink(_ path: String, target: String) {
        lock.withLock {
            nodes[absolute(path)] = Node(type: .symlink, target: Data(target.utf8))
        }
    }

    /// A name that need not be valid UTF-8.
    public func putRawName(_ name: Data, in directory: String = "", contents: Data = Data()) {
        lock.withLock {
            var path = absolute(directory)
            path.append(0x2F)
            path.append(name)
            nodes[path] = Node(type: .file, contents: contents)
        }
    }

    /// A **directory** whose own name need not be valid UTF-8, and the names it holds.
    ///
    /// `SQ-055`: this is the shape tier 1 cannot reach at all - `set --` is a String
    /// pipeline, so such a root has no spelling that survives the trip to `find` - and
    /// tier 0's `readdir` must, in the same cycle. Nothing else in the model can build
    /// one, because `absolute(_:)` starts from a `String`.
    public func putRawDirectory(
        _ name: Data, in directory: String = "", containing children: [String] = [],
        mode: UInt32 = 0o755
    ) {
        lock.withLock {
            var path = absolute(directory)
            path.append(0x2F)
            path.append(name)
            nodes[path] = Node(type: .directory, mode: mode)
            for child in children {
                var childPath = path
                childPath.append(0x2F)
                childPath.append(Data(child.utf8))
                nodes[childPath] = Node(type: .file, contents: Data())
            }
        }
    }

    /// A FIFO or socket, which the enumerator drops: they get no row.
    public func putSpecial(_ path: String, type: SFTPNodeType) {
        lock.withLock { nodes[absolute(path)] = Node(type: type) }
    }

    public func remove(_ path: String) { lock.withLock { nodes[absolute(path)] = nil } }

    public func exists(_ path: String) -> Bool {
        lock.withLock { nodes[absolute(path)] != nil }
    }

    public func node(_ path: String) -> Node? { lock.withLock { nodes[absolute(path)] } }

    public func contents(of path: String) -> Data? {
        lock.withLock { nodes[absolute(path)]?.contents }
    }

    public func mode(of path: String) -> UInt32? { lock.withLock { nodes[absolute(path)]?.mode } }

    /// Every path that exists, as text, for the "nothing left behind" assertions.
    public var allPaths: [String] {
        lock.withLock { nodes.keys.map { String(decoding: $0, as: UTF8.self) }.sorted() }
    }

    /// Names directly under a directory, as text.
    public func names(in directory: String) -> [String] {
        lock.withLock {
            children(of: absolute(directory)).map { path in
                String(decoding: lastComponent(path), as: UTF8.self)
            }
        }
    }

    /// Every request the client has made, as `"opendir /home/alec/x"` lines. The order
    /// matters to the containment rule: a listing must `lstat` its own directory *before*
    /// it `opendir`s it (`SQ-030`).
    public var requests: [String] { lock.withLock { requestLog } }

    public func clearRequestLog() { lock.withLock { requestLog.removeAll() } }

    /// How many `SSH_FXP_READDIR`s have arrived, the ones answered `EOF` included.
    ///
    /// It is a counter rather than a `requestLog` line because a page carries no argument
    /// worth logging and a hundred of them would bury every other request in the log. The
    /// pipelining scenario is what reads it: a window deeper than the directory has pages
    /// over-issues by design, and what has to stay bounded is *how far* - at most one
    /// window short of a wasted round trip, never a wasted round trip per page.
    public var readdirRequests: Int { lock.withLock { readdirRequestCount } }

    // MARK: - The stream

    /// A `ByteStream` whose other end is this server. Hand it straight to `SFTPClient`.
    public func makeStream() -> FakeSFTPStream { FakeSFTPStream(server: self) }

    // MARK: - Serving

    /// Answers one framed packet, returning the bytes to send back.
    ///
    /// One `FakeSFTPServer` serves as many `FakeSFTPStream`s as a scenario makes - two
    /// locations on one host are two clients (`Q2`), and the metadata and bulk channels
    /// are two more - so this is reached on whichever thread each client's `write` was
    /// called from. The state those calls share is behind the lock `handle` takes, and it
    /// is taken **there** rather than here: the `.initialize` branch below reads only the
    /// immutable profile, and wrapping this method as well would take a non-recursive
    /// `NSLock` twice on one thread and wedge the channel.
    func answer(_ packet: SFTPWire.Packet) -> Data {
        guard let type = packet.packetType else { return Data() }
        if type == .initialize {
            // The extension list, in the profile's own order: `status` reads it and the
            // fingerprint is what identifies the server (`SQ-024`, `SQ-025`).
            var writer = SFTPWire.Writer(.version)
            writer.writeUInt32(3)
            for name in profile.extensions {
                writer.writeString(name)
                // OpenSSH sends a version string; `copy-data` and `home-directory` send
                // "1" like the rest.
                writer.writeString("1")
            }
            return writer.finish()
        }
        var reader = packet.reader()
        guard let id = try? reader.readUInt32() else { return Data() }
        do {
            return try handle(type: type, id: id, reader: &reader)
        } catch let status as SFTPWire.Status {
            return statusPacket(id: id, status)
        } catch {
            return statusPacket(id: id, .failure)
        }
    }

    private func statusPacket(id: UInt32, _ status: SFTPWire.Status) -> Data {
        var writer = SFTPWire.Writer(.status, requestID: id)
        writer.writeUInt32(status.rawValue)
        // The literal message OpenSSH sends. "Failure" for everything from ENOSPC to
        // EXDEV, which is the whole of `SQ-028`.
        writer.writeString(status.message)
        writer.writeString("")
        return writer.finish()
    }

    private func log(_ line: String) { requestLog.append(line) }

    private func text(_ path: Data) -> String { String(decoding: path, as: UTF8.self) }

    private func lastComponent(_ path: Data) -> Data {
        guard let slash = path.lastIndex(of: 0x2F) else { return path }
        return Data(path[path.index(after: slash)...])
    }

    private func parent(_ path: Data) -> Data {
        guard let slash = path.lastIndex(of: 0x2F) else { return path }
        return Data(path[path.startIndex ..< slash])
    }

    /// Case folding, where the profile says the server has it.
    private func lookup(_ path: Data) -> Node? {
        if let node = nodes[path] { return node }
        guard profile.caseInsensitive else { return nil }
        let wanted = text(path).lowercased()
        for (key, node) in nodes where text(key).lowercased() == wanted { return node }
        return nil
    }

    private func key(_ path: Data) -> Data {
        if nodes[path] != nil { return path }
        guard profile.caseInsensitive else { return path }
        let wanted = text(path).lowercased()
        for key in nodes.keys where text(key).lowercased() == wanted { return key }
        return path
    }

    private func children(of path: Data) -> [Data] {
        var prefix = path
        prefix.append(0x2F)
        // Decorated with the text form before sorting rather than converting inside the
        // comparator: a directory of ten thousand entries is 130,000 comparisons, and a
        // `String(decoding:)` in each of them would put most of a large listing's time on
        // the model server rather than on the code under test.
        return nodes.keys.filter { candidate in
            guard candidate.count > prefix.count, candidate.starts(with: prefix) else { return false }
            return !candidate.dropFirst(prefix.count).contains(0x2F)
        }
        .map { (text($0), $0) }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func formatBits(_ node: Node) -> UInt32 {
        switch node.type {
        case .directory: return SFTPWire.ModeBits.directory
        case .symlink: return SFTPWire.ModeBits.symlink
        case .file: return SFTPWire.ModeBits.regular
        case .fifo: return 0x1000
        case .socket: return 0xC000
        }
    }

    private func writeAttributes(_ node: Node, into writer: inout SFTPWire.Writer) {
        writer.writeUInt32(
            SFTPWire.AttributeFlags.size | SFTPWire.AttributeFlags.uidgid
                | SFTPWire.AttributeFlags.permissions
                | SFTPWire.AttributeFlags.accessModifiedTime)
        writer.writeUInt64(UInt64(node.contents.count))
        writer.writeUInt32(node.uid)
        writer.writeUInt32(node.gid)
        writer.writeUInt32(formatBits(node) | (node.mode & 0o7777))
        writer.writeUInt32(UInt32(truncatingIfNeeded: node.mtime))
        writer.writeUInt32(UInt32(truncatingIfNeeded: node.mtime))
    }

    /// `SQ-030`: `opendir` follows a symlink. A directory swapped on the server for a link
    /// to `/etc` is read straight through, which is why every listing has to re-`lstat`
    /// its own directory before `readdir` (docs/design/security.md).
    private func resolvingForOpendir(_ path: Data) -> Data {
        var current = path
        var hops = 0
        while let node = lookup(current), node.type == .symlink, let target = node.target, hops < 8 {
            current = target.first == 0x2F ? target : {
                var joined = parent(current)
                joined.append(0x2F)
                joined.append(target)
                return joined
            }()
            hops += 1
        }
        return current
    }

    private func handle(
        type: SFTPWire.PacketType, id: UInt32, reader: inout SFTPWire.Reader
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        switch type {
        case .realpath:
            let path = try reader.readString()
            log("realpath \(text(path))")
            var writer = SFTPWire.Writer(.name, requestID: id)
            writer.writeUInt32(1)
            writer.writeString(path)
            writer.writeString(path)
            writer.writeUInt32(0)
            return writer.finish()

        case .lstat, .stat:
            let path = try reader.readString()
            log("\(type == .lstat ? "lstat" : "stat") \(text(path))")
            // lstat never follows; stat does, which is the only difference the client
            // ever relies on.
            let target = type == .stat ? resolvingForOpendir(path) : path
            guard let node = lookup(target) else { throw SFTPWire.Status.noSuchFile }
            var writer = SFTPWire.Writer(.attrs, requestID: id)
            writeAttributes(node, into: &writer)
            return writer.finish()

        case .fstat:
            let handle = try reader.readString()
            guard let path = handles[handle], let node = lookup(path) else {
                throw SFTPWire.Status.failure
            }
            var writer = SFTPWire.Writer(.attrs, requestID: id)
            writeAttributes(node, into: &writer)
            return writer.finish()

        case .setstat, .fsetstat:
            let target: Data
            if type == .setstat {
                target = try reader.readString()
            } else {
                let handle = try reader.readString()
                guard let path = handles[handle] else { throw SFTPWire.Status.failure }
                target = path
            }
            let attributes = try reader.readAttributes()
            log("setstat \(text(target))")
            let resolved = key(target)
            guard var node = nodes[resolved] else { throw SFTPWire.Status.noSuchFile }
            // A `setstat` is *not* filtered by the umask; that is `mkdir`'s rule alone
            // (`SQ-033`), and is exactly why the deployment asserts 0700 afterwards.
            if let permissions = attributes.permissions { node.mode = permissions & 0o7777 }
            if let mtime = attributes.mtime { node.mtime = Int64(mtime) }
            if let size = attributes.size {
                let wanted = Int(size)
                if node.contents.count > wanted {
                    node.contents = node.contents.prefix(wanted)
                } else if node.contents.count < wanted {
                    node.contents.append(Data(repeating: 0, count: wanted - node.contents.count))
                }
            }
            nodes[resolved] = node
            return statusPacket(id: id, .ok)

        case .open:
            let path = try reader.readString()
            let flags = try reader.readUInt32()
            let attributes = try reader.readAttributes()
            log("open \(text(path))")
            if denied.contains(text(path)) { throw SFTPWire.Status.permissionDenied }
            let wants = flags & (SFTPWire.OpenFlags.write | SFTPWire.OpenFlags.truncate)
            // `SQ-032`: writing over a *running* executable is ETXTBSY, and ETXTBSY has
            // no code of its own on the wire - it is the bare FAILURE of `SQ-028`.
            if wants != 0, runningExecutables.contains(text(path)) {
                throw SFTPWire.Status.failure
            }
            let resolved = key(path)
            if nodes[resolved] == nil {
                guard flags & SFTPWire.OpenFlags.create != 0 else {
                    throw SFTPWire.Status.noSuchFile
                }
                guard nodes[parent(resolved)]?.type == .directory else {
                    throw SFTPWire.Status.noSuchFile
                }
                // `SQ-033`: a **create**'s attributes go through the server's umask too,
                // exactly as `mkdir`'s do, which is why an upload sets the mode back with
                // a `setstat` after the rename rather than trusting the `open`
                // (docs/design/writes.md).
                // Confidence: the umask itself is measured (`deb`, 2026-09-05, on `mkdir`);
                // that `open(O_CREAT)` takes the same filter is POSIX and is what the
                // write protocol already assumes ("the server's umask still applies"), not
                // a separate measurement.
                nodes[resolved] = Node(
                    type: .file,
                    mode: ((attributes.permissions ?? 0o644) & ~profile.umask) & 0o7777)
            } else if flags & SFTPWire.OpenFlags.exclusive != 0,
                      flags & SFTPWire.OpenFlags.create != 0 {
                // EEXIST, which is also a bare FAILURE (`SQ-028`).
                throw SFTPWire.Status.failure
            } else if flags & SFTPWire.OpenFlags.truncate != 0 {
                nodes[resolved]?.contents = Data()
            }
            let handle = makeHandle()
            handles[handle] = resolved
            var writer = SFTPWire.Writer(.handle, requestID: id)
            writer.writeString(handle)
            return writer.finish()

        case .opendir:
            let path = try reader.readString()
            log("opendir \(text(path))")
            if denied.contains(text(path)) { throw SFTPWire.Status.permissionDenied }
            // The whole of `SQ-030` is this one line: the link is resolved, not refused.
            let resolved = resolvingForOpendir(path)
            guard lookup(resolved)?.type == .directory else { throw SFTPWire.Status.noSuchFile }
            let handle = makeHandle()
            handles[handle] = key(resolved)
            let all = children(of: key(resolved))
            var pages: [[Data]] = []
            var index = 0
            while index < all.count {
                pages.append(Array(all[index ..< min(index + readdirPageSize, all.count)]))
                index += readdirPageSize
            }
            directoryPages[handle] = pages
            var writer = SFTPWire.Writer(.handle, requestID: id)
            writer.writeString(handle)
            return writer.finish()

        case .readdir:
            let handle = try reader.readString()
            readdirRequestCount += 1
            guard var pages = directoryPages[handle], !pages.isEmpty else {
                return statusPacket(id: id, .endOfFile)
            }
            let page = pages.removeFirst()
            directoryPages[handle] = pages
            // The count is what is **written**, not the size of the page.
            //
            // The pages are cut at `opendir`, and a name can go between then and the
            // `readdir` that reports it - our own stale-temp sweep removes
            // `.sshdrive-upload-*` while a listing of the same directory is in flight,
            // which is exactly how this was found. Skipping the entry while still
            // announcing the page's size produced a `SSH_FXP_NAME` whose header promised
            // more entries than its body held; the client read past the end of the packet
            // into the next one, and the channel died `badMessage` a millisecond after it
            // came up. A real server cannot emit that packet, and neither may this one.
            let entries = page.compactMap { path -> (Data, Node)? in
                guard let node = nodes[path] else { return nil }
                return (path, node)
            }
            var writer = SFTPWire.Writer(.name, requestID: id)
            writer.writeUInt32(UInt32(entries.count))
            for (path, node) in entries {
                writer.writeString(lastComponent(path))
                let kind: String
                switch node.type {
                case .directory: kind = "d"
                case .symlink: kind = "l"
                case .fifo: kind = "p"
                case .socket: kind = "s"
                case .file: kind = "-"
                }
                // `SQ-031`: attributes, but **no link target**. Every symlink a listing
                // reports therefore costs a `readlink` before its row can be built.
                writer.writeString(Data("\(kind)rw-r--r-- 1 alec alec".utf8))
                writeAttributes(node, into: &writer)
            }
            return writer.finish()

        case .close:
            let handle = try reader.readString()
            handles[handle] = nil
            directoryPages[handle] = nil
            return statusPacket(id: id, .ok)

        case .read:
            let handle = try reader.readString()
            let offset = try reader.readUInt64()
            let length = Int(try reader.readUInt32())
            guard let path = handles[handle], let node = nodes[path] else {
                throw SFTPWire.Status.failure
            }
            guard offset < UInt64(node.contents.count) else {
                return statusPacket(id: id, .endOfFile)
            }
            let start = Int(offset)
            let want = max(1, Int(Double(length) * shortReadFactor))
            let end = min(node.contents.count, start + want)
            var writer = SFTPWire.Writer(.data, requestID: id)
            writer.writeString(node.contents.subdata(in: start ..< end))
            return writer.finish()

        case .write:
            let handle = try reader.readString()
            let offset = Int(try reader.readUInt64())
            let payload = try reader.readString()
            guard let path = handles[handle], var node = nodes[path] else {
                throw SFTPWire.Status.failure
            }
            // ENOSPC. A bare FAILURE, so only a second question - `statvfs` - can say
            // that the disk is what is wrong (`SQ-028`).
            guard availableBlocks > 0 else { throw SFTPWire.Status.failure }
            if node.contents.count < offset + payload.count {
                node.contents.append(
                    Data(repeating: 0, count: offset + payload.count - node.contents.count))
            }
            node.contents.replaceSubrange(offset ..< (offset + payload.count), with: payload)
            nodes[path] = node
            return statusPacket(id: id, .ok)

        case .mkdir:
            let path = try reader.readString()
            let attributes = try reader.readAttributes()
            log("mkdir \(text(path))")
            guard nodes[key(path)] == nil else { throw SFTPWire.Status.failure }
            guard nodes[parent(path)]?.type == .directory else { throw SFTPWire.Status.noSuchFile }
            // `SQ-033`: the attributes go through the server's **umask**, so an asked-for
            // 0700 lands 0755 on a 022 server and the mode has to be asserted with a
            // `setstat` afterwards.
            let asked = attributes.permissions ?? 0o777
            nodes[path] = Node(type: .directory, mode: (asked & ~profile.umask) & 0o7777)
            return statusPacket(id: id, .ok)

        case .rmdir:
            let path = try reader.readString()
            log("rmdir \(text(path))")
            let resolved = key(path)
            guard nodes[resolved]?.type == .directory else { throw SFTPWire.Status.noSuchFile }
            // ENOTEMPTY: a bare FAILURE, which is why the caller confirms with a readdir.
            guard children(of: resolved).isEmpty else { throw SFTPWire.Status.failure }
            nodes[resolved] = nil
            return statusPacket(id: id, .ok)

        case .remove:
            let path = try reader.readString()
            log("remove \(text(path))")
            let resolved = key(path)
            guard let node = nodes[resolved] else { throw SFTPWire.Status.noSuchFile }
            guard node.type != .directory else { throw SFTPWire.Status.failure }
            nodes[resolved] = nil
            return statusPacket(id: id, .ok)

        case .rename:
            let source = try reader.readString()
            let destination = try reader.readString()
            log("rename \(text(source)) -> \(text(destination))")
            let from = key(source)
            guard let node = nodes[from] else { throw SFTPWire.Status.noSuchFile }
            // `SQ-034`: some servers refuse an existing name and some overwrite it, and
            // the probe is what decides. busybox + internal-sftp refuses.
            if nodes[key(destination)] != nil, !profile.renameOverwrites {
                throw SFTPWire.Status.failure
            }
            nodes[from] = nil
            nodes[destination] = node
            return statusPacket(id: id, .ok)

        case .readlink:
            let path = try reader.readString()
            log("readlink \(text(path))")
            guard let node = lookup(path), node.type == .symlink, let target = node.target else {
                throw SFTPWire.Status.noSuchFile
            }
            var writer = SFTPWire.Writer(.name, requestID: id)
            writer.writeUInt32(1)
            writer.writeString(target)
            writer.writeString(target)
            writer.writeUInt32(0)
            return writer.finish()

        case .symlink:
            // `SQ-029`: OpenSSH takes its two paths in the **opposite order from the
            // draft** - target first, then the link path.
            let target = try reader.readString()
            let linkPath = try reader.readString()
            log("symlink \(text(linkPath)) -> \(text(target))")
            guard nodes[key(linkPath)] == nil else { throw SFTPWire.Status.failure }
            nodes[linkPath] = Node(type: .symlink, target: target)
            return statusPacket(id: id, .ok)

        case .extended:
            let name = try reader.readText()
            log("extended \(name)")
            // An extension the profile does not advertise is refused, which is how a
            // client that ignored the fingerprint would be caught (`SQ-024`).
            guard profile.extensions.contains(name) else {
                throw SFTPWire.Status.operationUnsupported
            }
            switch name {
            case "limits@openssh.com":
                // `SQ-027`, measured on `deb`: it sizes the *request*, and says nothing
                // about how many may be outstanding.
                var writer = SFTPWire.Writer(.extendedReply, requestID: id)
                writer.writeUInt64(262_144)   // maxPacketLength
                writer.writeUInt64(261_120)   // maxReadLength
                writer.writeUInt64(261_120)   // maxWriteLength
                writer.writeUInt64(20_475)    // maxOpenHandles
                return writer.finish()
            case "posix-rename@openssh.com":
                let source = try reader.readString()
                let destination = try reader.readString()
                log("posix-rename \(text(source)) -> \(text(destination))")
                let from = key(source)
                guard let node = nodes[from] else { throw SFTPWire.Status.noSuchFile }
                nodes[from] = nil
                nodes[destination] = node   // always overwrites: that is the point of it
                return statusPacket(id: id, .ok)
            case "fsync@openssh.com":
                _ = try? reader.readString()
                return statusPacket(id: id, .ok)
            case "lsetstat@openssh.com":
                let path = try reader.readString()
                let attributes = try reader.readAttributes()
                let resolved = key(path)
                guard var node = nodes[resolved] else { throw SFTPWire.Status.noSuchFile }
                if let permissions = attributes.permissions { node.mode = permissions & 0o7777 }
                if let mtime = attributes.mtime { node.mtime = Int64(mtime) }
                nodes[resolved] = node
                return statusPacket(id: id, .ok)
            case "statvfs@openssh.com":
                _ = try reader.readString()
                var writer = SFTPWire.Writer(.extendedReply, requestID: id)
                writer.writeUInt64(4096)              // f_bsize
                writer.writeUInt64(4096)              // f_frsize
                writer.writeUInt64(1_000_000)         // f_blocks
                writer.writeUInt64(availableBlocks)   // f_bfree
                writer.writeUInt64(availableBlocks)   // f_bavail
                writer.writeUInt64(100_000)           // f_files
                writer.writeUInt64(availableBlocks == 0 ? 0 : 50_000)  // f_ffree
                writer.writeUInt64(availableBlocks == 0 ? 0 : 50_000)  // f_favail
                return writer.finish()
            default:
                throw SFTPWire.Status.operationUnsupported
            }

        default:
            return statusPacket(id: id, .operationUnsupported)
        }
    }

    private func makeHandle() -> Data {
        defer { nextHandle += 1 }
        return Data("h\(nextHandle)".utf8)
    }
}

/// The client's end of a `FakeSFTPServer`.
///
/// A `ByteStream` and nothing more, which is the whole point: `SFTPClient` cannot tell it
/// from a mux client's stdio, so the codec, the pipelining and the deadlines all run
/// unmodified (docs/design/testing.md).
public final class FakeSFTPStream: ByteStream, @unchecked Sendable {

    private let server: FakeSFTPServer
    private let lock = NSLock()
    private var outbound = Data()
    /// The parked reader, the size **it asked for**, and a ticket.
    ///
    /// Both of the extra fields are bugs this stream had. `ByteStream.read(upTo:)` is a
    /// ceiling, and handing a reader more bytes than it asked for overran `SFTPClient`'s
    /// buffer and surfaced as `SFTP reply could not be parsed; the channel is dead` -
    /// a dead connection where nothing was wrong with either end. And a read that is
    /// satisfied by data leaves its deadline timer armed, so the *next* read could be
    /// failed `readTimedOut` by the previous read's timer; the ticket is what makes a
    /// timer only ever able to time out its own read.
    private var waiter: (continuation: CheckedContinuation<Data, Error>, limit: Int, ticket: Int)?
    private var nextTicket = 0
    private var scratch: [UInt8] = []
    private var closed = false
    /// Set to drop the connection mid-flight, which is what a dying master looks like to
    /// the client (`SQ-079`).
    public var refusesWrites = false

    init(server: FakeSFTPServer) { self.server = server }

    /// Ends the stream as a server that went away does: EOF, not an error.
    public func endOfStream() {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.continuation.resume(returning: Data())
    }

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
            if closed {
                lock.unlock()
                continuation.resume(returning: Data())
                return
            }
            nextTicket += 1
            let ticket = nextTicket
            waiter = (continuation, count, ticket)
            lock.unlock()
            // Every read takes a deadline, without exception (`ByteStream`): a server
            // that never answers must time the caller out, not hang it. The ticket is
            // what keeps this timer to its own read: a read satisfied by data leaves its
            // timer armed, and without the check it would fail whichever read happened to
            // be parked when it fired.
            let delay = deadline.timeIntervalSinceNow
            guard delay < 86_400 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard let pending = self.waiter, pending.ticket == ticket else {
                    self.lock.unlock(); return
                }
                self.waiter = nil
                self.lock.unlock()
                pending.continuation.resume(throwing: ByteStreamError.readTimedOut)
            }
        }
    }

    public func write(_ data: Data) async throws {
        // Both halves are synchronous by construction: `NSLock` may not be held across a
        // suspension point, and nothing here needs to be - framing is a byte split and the
        // server answers a packet without awaiting anything.
        let packets = try frame(data)
        var replies = Data()
        for packet in packets { replies.append(server.answer(packet)) }
        guard !replies.isEmpty else { return }
        if let (continuation, handoff) = enqueue(replies) {
            continuation.resume(returning: handoff)
        }
    }

    /// Appends to the inbound buffer and splits whole packets out of it.
    private func frame(_ data: Data) throws -> [SFTPWire.Packet] {
        try lock.withLock {
            if closed || refusesWrites { throw ByteStreamError.closed }
            scratch.append(contentsOf: data)
            return SFTPWire.frame(&scratch)
        }
    }

    /// Queues the replies and hands the parked reader **at most what it asked for**,
    /// leaving the rest for its next read. A `ByteStream` read is `upTo:`, and a real
    /// pipe never returns more than the buffer handed to it.
    private func enqueue(_ replies: Data) -> (CheckedContinuation<Data, Error>, Data)? {
        lock.withLock {
            outbound.append(replies)
            guard let pending = waiter else { return nil }
            waiter = nil
            let take = min(outbound.count, pending.limit)
            let handoff = Data(outbound.prefix(take))
            outbound.removeFirst(take)
            return (pending.continuation, handoff)
        }
    }

    public func closeWrite() {}

    public func close() { endOfStream() }
}
