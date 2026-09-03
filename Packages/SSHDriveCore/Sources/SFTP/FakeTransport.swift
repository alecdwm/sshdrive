import Foundation
import Logging

/// A remote change, applied to the fake tree from a test hook (`sshdrive debug mutate`).
/// This is what lets the File Provider half be exercised before a byte of SSH exists
/// (DESIGN.md section 12, milestone 1): change detection sees the tree move without
/// anything of ours having asked for it.
public enum FakeMutation: Sendable, Equatable {
    case createFile(path: RelativePath, contents: Data, mode: UInt32)
    case createDirectory(path: RelativePath, mode: UInt32)
    case createSymlink(path: RelativePath, target: String)
    case write(path: RelativePath, contents: Data)
    /// Advances mtime by one second without changing anything else, so a listing diff
    /// sees a new content version.
    case touch(path: RelativePath)
    /// Rewrites contents in place keeping size and second-mtime, and moves the
    /// nanosecond mtime only. This is the case the `generation` column exists for
    /// (section 5.3): SFTP alone cannot see it.
    case rewriteInvisibly(path: RelativePath, contents: Data)
    case chmod(path: RelativePath, mode: UInt32)
    case rename(from: RelativePath, to: RelativePath)
    case delete(path: RelativePath, recursive: Bool)
}

/// The in-memory tree behind `SFTPTransport` (DESIGN.md section 12, milestone 1). It
/// lists, fetches, writes, renames and deletes, and can be mutated from a test hook to
/// stand in for a remote change. It stays as the test double for every later milestone.
///
/// Deliberately faithful in three ways that matter for the spikes: names are bytes, the
/// error classes are exactly those of section 6.2, and a rename refuses to overwrite,
/// which is what section 5.5's create path relies on.
public actor FakeTransport: SFTPTransport {

    final class Node {
        var type: SFTPFileType
        var contents: Data
        var mode: UInt32
        var uid: UInt32
        var gid: UInt32
        var mtime: Int64
        var mtimeNanoseconds: Int64
        var inode: UInt64
        var symlinkTarget: String?
        var children: [Data: Node]

        init(
            type: SFTPFileType, contents: Data = Data(), mode: UInt32, uid: UInt32, gid: UInt32,
            mtime: Int64, mtimeNanoseconds: Int64, inode: UInt64, symlinkTarget: String? = nil
        ) {
            self.type = type
            self.contents = contents
            self.mode = mode
            self.uid = uid
            self.gid = gid
            self.mtime = mtime
            self.mtimeNanoseconds = mtimeNanoseconds
            self.inode = inode
            self.symlinkTarget = symlinkTarget
            self.children = [:]
        }

        var attributes: SFTPFileAttributes {
            SFTPFileAttributes(
                type: type,
                size: type == .directory ? 0 : Int64(contents.count),
                mtime: mtime,
                mode: mode,
                uid: uid,
                gid: gid,
                mtimeNanoseconds: mtimeNanoseconds,
                inode: inode,
                symlinkTarget: symlinkTarget)
        }
    }

    /// The canonical absolute root the real transport would have resolved.
    public let root: String
    /// The identity the fake server reports, so the capability probe of section 8.1 has
    /// something to map permissions from in milestone 1.
    public let serverUID: UInt32
    public let serverGID: UInt32

    private var tree: Node
    private var nextInode: UInt64 = 2
    /// Every mutation applied since the transport was created, so a test can assert on
    /// what it asked for.
    private(set) public var mutationCount: Int = 0

    public init(root: String = "/srv/fake", uid: UInt32 = 501, gid: UInt32 = 20) {
        self.root = root
        self.serverUID = uid
        self.serverGID = gid
        self.tree = Node(
            type: .directory, mode: 0o755, uid: uid, gid: gid,
            mtime: Int64(Date().timeIntervalSince1970), mtimeNanoseconds: 0, inode: 1)
    }

    public var extensions: SFTPServerExtensions {
        [.posixRename, .statvfs, .fsync, .limits, .lsetstat]
    }

    // MARK: Tree walking

    private func node(at path: RelativePath) throws -> Node {
        var current = tree
        for component in path.components {
            guard current.type == .directory else { throw SFTPError.noSuchFile }
            guard let child = current.children[component] else { throw SFTPError.noSuchFile }
            current = child
        }
        return current
    }

    private func parentNode(of path: RelativePath) throws -> Node {
        guard let parent = path.parent else { throw SFTPError.failure("Failure") }
        let node = try node(at: parent)
        guard node.type == .directory else { throw SFTPError.noSuchFile }
        return node
    }

    private func newInode() -> UInt64 {
        nextInode += 1
        return nextInode
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: SFTPTransport

    public func realpath(_ path: RelativePath) async throws -> String {
        _ = try node(at: path)
        return path.absolute(root: root)
    }

    public func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        try node(at: path).attributes
    }

    public func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        let node = try node(at: path)
        guard node.type == .directory else { throw SFTPError.failure("Failure") }
        return node.children
            .map { SFTPDirectoryEntry(name: $0.key, attributes: $0.value.attributes) }
            // readdir order is not stable on a real server (section 5.4); returning
            // sorted order here would let a bug that depends on it pass.
            .shuffled()
    }

    public func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        let node = try node(at: path)
        guard node.type == .file else { throw SFTPError.failure("Failure") }
        let start = Int(min(offset, UInt64(node.contents.count)))
        let end = length.map { min(start + $0, node.contents.count) } ?? node.contents.count
        guard start < end else { return Data() }
        return node.contents.subdata(in: start..<end)
    }

    public func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        let parent = try parentNode(of: path)
        guard let name = path.lastComponent else { throw SFTPError.failure("Failure") }
        if let existing = parent.children[name] {
            guard existing.type == .file else { throw SFTPError.failure("Failure") }
            existing.contents = contents
            existing.mtime = now()
            existing.mtimeNanoseconds = 0
        } else {
            parent.children[name] = Node(
                type: .file, contents: contents, mode: mode, uid: serverUID, gid: serverGID,
                mtime: now(), mtimeNanoseconds: 0, inode: newInode())
        }
        parent.mtime = now()
    }

    public func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        let parent = try parentNode(of: path)
        guard let name = path.lastComponent else { throw SFTPError.failure("Failure") }
        // EEXIST reaches the wire as a bare FAILURE (section 6.2).
        guard parent.children[name] == nil else { throw SFTPError.failure("Failure") }
        parent.children[name] = Node(
            type: .directory, mode: mode, uid: serverUID, gid: serverGID,
            mtime: now(), mtimeNanoseconds: 0, inode: newInode())
        parent.mtime = now()
    }

    public func remove(_ path: RelativePath) async throws {
        let parent = try parentNode(of: path)
        guard let name = path.lastComponent, let node = parent.children[name] else {
            throw SFTPError.noSuchFile
        }
        guard node.type != .directory else { throw SFTPError.failure("Failure") }
        parent.children.removeValue(forKey: name)
        parent.mtime = now()
    }

    public func rmdir(_ path: RelativePath) async throws {
        let parent = try parentNode(of: path)
        guard let name = path.lastComponent, let node = parent.children[name] else {
            throw SFTPError.noSuchFile
        }
        guard node.type == .directory else { throw SFTPError.failure("Failure") }
        // ENOTEMPTY is a bare FAILURE too; the caller confirms with a readdir.
        guard node.children.isEmpty else { throw SFTPError.failure("Failure") }
        parent.children.removeValue(forKey: name)
        parent.mtime = now()
    }

    public func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        let sourceParent = try parentNode(of: source)
        let destinationParent = try parentNode(of: destination)
        guard
            let sourceName = source.lastComponent,
            let destinationName = destination.lastComponent,
            let node = sourceParent.children[sourceName]
        else { throw SFTPError.noSuchFile }
        // Non-overwriting: this is the property section 5.5's create path depends on.
        guard destinationParent.children[destinationName] == nil else {
            throw SFTPError.failure("Failure")
        }
        sourceParent.children.removeValue(forKey: sourceName)
        destinationParent.children[destinationName] = node
        sourceParent.mtime = now()
        destinationParent.mtime = now()
    }

    public func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        let sourceParent = try parentNode(of: source)
        let destinationParent = try parentNode(of: destination)
        guard
            let sourceName = source.lastComponent,
            let destinationName = destination.lastComponent,
            let node = sourceParent.children[sourceName]
        else { throw SFTPError.noSuchFile }
        sourceParent.children.removeValue(forKey: sourceName)
        destinationParent.children[destinationName] = node
        sourceParent.mtime = now()
        destinationParent.mtime = now()
    }

    public func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        let node = try node(at: path)
        if let mode { node.mode = (node.mode & ~0o7777) | (mode & 0o7777) }
        if let mtime { node.mtime = mtime }
    }

    public func symlink(target: String, at path: RelativePath) async throws {
        let parent = try parentNode(of: path)
        guard let name = path.lastComponent else { throw SFTPError.failure("Failure") }
        guard parent.children[name] == nil else { throw SFTPError.failure("Failure") }
        parent.children[name] = Node(
            type: .symlink, mode: 0o777, uid: serverUID, gid: serverGID,
            mtime: now(), mtimeNanoseconds: 0, inode: newInode(), symlinkTarget: target)
        parent.mtime = now()
    }

    public func readlink(_ path: RelativePath) async throws -> String {
        let node = try node(at: path)
        guard node.type == .symlink, let target = node.symlinkTarget else {
            throw SFTPError.failure("Failure")
        }
        return target
    }

    public func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        _ = try node(at: path)
        return SFTPFilesystemStats(
            blockSize: 4096, totalBlocks: 1 << 20, availableBlocks: 1 << 19,
            totalInodes: 1 << 16, availableInodes: 1 << 15)
    }

    // MARK: The mutation hook

    /// Applies a change as if it had happened on the server, with nothing of ours having
    /// asked for it. Reachable from `sshdrive debug mutate`.
    public func apply(_ mutation: FakeMutation) throws {
        switch mutation {
        case let .createFile(path, contents, mode):
            let parent = try parentNode(of: path)
            guard let name = path.lastComponent, parent.children[name] == nil else {
                throw SFTPError.failure("Failure")
            }
            parent.children[name] = Node(
                type: .file, contents: contents, mode: mode, uid: serverUID, gid: serverGID,
                mtime: now(), mtimeNanoseconds: 0, inode: newInode())

        case let .createDirectory(path, mode):
            let parent = try parentNode(of: path)
            guard let name = path.lastComponent, parent.children[name] == nil else {
                throw SFTPError.failure("Failure")
            }
            parent.children[name] = Node(
                type: .directory, mode: mode, uid: serverUID, gid: serverGID,
                mtime: now(), mtimeNanoseconds: 0, inode: newInode())

        case let .createSymlink(path, target):
            let parent = try parentNode(of: path)
            guard let name = path.lastComponent, parent.children[name] == nil else {
                throw SFTPError.failure("Failure")
            }
            parent.children[name] = Node(
                type: .symlink, mode: 0o777, uid: serverUID, gid: serverGID,
                mtime: now(), mtimeNanoseconds: 0, inode: newInode(), symlinkTarget: target)

        case let .write(path, contents):
            let node = try node(at: path)
            guard node.type == .file else { throw SFTPError.failure("Failure") }
            node.contents = contents
            node.mtime = now()
            node.mtimeNanoseconds = 0
            node.inode = newInode()

        case let .touch(path):
            let node = try node(at: path)
            node.mtime = max(node.mtime + 1, now())

        case let .rewriteInvisibly(path, contents):
            let node = try node(at: path)
            guard node.type == .file else { throw SFTPError.failure("Failure") }
            guard contents.count == node.contents.count else {
                throw SFTPError.failure("Failure")
            }
            node.contents = contents
            node.mtimeNanoseconds += 1
            node.inode = newInode()

        case let .chmod(path, mode):
            let node = try node(at: path)
            node.mode = (node.mode & ~0o7777) | (mode & 0o7777)

        case let .rename(from, to):
            let sourceParent = try parentNode(of: from)
            let destinationParent = try parentNode(of: to)
            guard
                let sourceName = from.lastComponent,
                let destinationName = to.lastComponent,
                let node = sourceParent.children[sourceName]
            else { throw SFTPError.noSuchFile }
            sourceParent.children.removeValue(forKey: sourceName)
            destinationParent.children[destinationName] = node

        case let .delete(path, recursive):
            let parent = try parentNode(of: path)
            guard let name = path.lastComponent, let node = parent.children[name] else {
                throw SFTPError.noSuchFile
            }
            if node.type == .directory, !node.children.isEmpty, !recursive {
                throw SFTPError.failure("Failure")
            }
            parent.children.removeValue(forKey: name)
        }
        mutationCount += 1
    }

    /// A depth-first dump of the tree, for `sshdrive debug tree`.
    public func dump(from path: RelativePath = .root) throws -> [(path: RelativePath, attributes: SFTPFileAttributes)] {
        var out: [(path: RelativePath, attributes: SFTPFileAttributes)] = []
        func walk(_ node: Node, _ prefix: RelativePath) {
            out.append((path: prefix, attributes: node.attributes))
            for (name, child) in node.children.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                guard let next = try? prefix.appending(component: name) else { continue }
                walk(child, next)
            }
        }
        walk(try node(at: path), path)
        return out
    }

    /// Fills the tree with a small, deterministic sample so a fresh fake location has
    /// something in it for spikes S3, S4 and S6.
    public func seedSample(fileCount: Int = 8) throws {
        try apply(.createDirectory(path: RelativePath(string: "Documents"), mode: 0o755))
        try apply(.createDirectory(path: RelativePath(string: "Documents/Reports"), mode: 0o755))
        try apply(.createDirectory(path: RelativePath(string: "Media"), mode: 0o755))
        try apply(.createFile(
            path: RelativePath(string: "README.txt"),
            contents: Data("SSH Drive fake backend, milestone 1.\n".utf8), mode: 0o644))
        try apply(.createFile(
            path: RelativePath(string: "run.sh"),
            contents: Data("#!/bin/sh\necho hello\n".utf8), mode: 0o755))
        for index in 0..<max(0, fileCount) {
            let name = String(format: "Documents/Reports/report-%03d.txt", index)
            let body = String(repeating: "line \(index)\n", count: 16 + index)
            try apply(.createFile(
                path: RelativePath(string: name), contents: Data(body.utf8), mode: 0o644))
        }
    }
}
