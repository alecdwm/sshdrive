import Foundation
import Logging
import SSHProcess

/// `SFTPTransport` on top of the real wire client (DESIGN.md sections 6.2 and 9.1).
///
/// This is the one path chokepoint: every method takes a `RelativePath`, and the only
/// thing in the process that turns one into an absolute server path is
/// `serverPath(_:)` below, which joins it to the canonical root. `SFTPServerPath`'s
/// initialiser is internal to this module, so nothing outside can hand the client a
/// path at all.
public actor RealSFTPTransport: SFTPTransport {

    public nonisolated let client: SFTPClient
    /// The canonical absolute root, as `realpath` resolved it, in server bytes.
    public private(set) var rootBytes: Data
    /// A per-process tag for upload temp files. Section 5.5 names them
    /// `.sshdrive-upload-<mac8>-<uuid>`; the `<mac8>` is the agent's, and is handed in
    /// here rather than derived, because this module has no business reading a Mac's
    /// hardware identifiers.
    private let uploadTag: String

    public var root: String { String(decoding: rootBytes, as: UTF8.self) }

    init(client: SFTPClient, rootBytes: Data, uploadTag: String) {
        self.client = client
        self.rootBytes = rootBytes
        self.uploadTag = uploadTag
    }

    /// Handshakes on `stream` and canonicalises `root` with SFTP `realpath`, which is
    /// what section 9.1 requires at `add` time and on every connection.
    public static func connect(
        stream: any ByteStream,
        root: String,
        uploadTag: String = RealSFTPTransport.defaultUploadTag,
        configuration: SFTPClient.Configuration = SFTPClient.Configuration()
    ) async throws -> RealSFTPTransport {
        let client = SFTPClient(stream: stream, configuration: configuration)
        try await client.connect()
        let canonical = try await client.realpath(SFTPServerPath(bytes: Data(root.utf8)))
        return RealSFTPTransport(client: client, rootBytes: canonical, uploadTag: uploadTag)
    }

    /// Eight hex characters, stable for the life of the process. The agent overrides it
    /// with the `<mac8>` of section 5.5.
    public static var defaultUploadTag: String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    /// Section 9.1: on every connection the root is resolved again and the location
    /// refuses to operate if it moved. Throws `.noSuchFile` when the root is gone and
    /// `.failure` when it now resolves somewhere else.
    public func verifyRoot() async throws {
        let resolved = try await client.realpath(SFTPServerPath(bytes: rootBytes))
        guard resolved == rootBytes else {
            throw SFTPError.failure(
                "The location root now resolves to \(String(decoding: resolved, as: UTF8.self))")
        }
    }

    public func shutdown() async {
        await client.shutdown()
    }

    // MARK: The chokepoint

    private func serverPath(_ path: RelativePath) -> SFTPServerPath {
        SFTPServerPath(bytes: path.absoluteBytes(root: rootBytes))
    }

    // MARK: SFTPTransport

    public var extensions: SFTPServerExtensions {
        get async { await client.extensions }
    }

    public func realpath(_ path: RelativePath) async throws -> String {
        let resolved = try await client.realpath(serverPath(path))
        return String(decoding: resolved, as: UTF8.self)
    }

    public func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        var attributes = try await client.lstat(serverPath(path))
        // Section 5.7: the target string is read once and handed to the Mac verbatim. It
        // is never joined to a remote path, so a `..` inside it cannot steer anything.
        if attributes.type == .symlink, attributes.symlinkTarget == nil {
            attributes.symlinkTarget = try? await readlink(path)
        }
        return attributes
    }

    public func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        try await client.listDirectory(serverPath(path))
    }

    public func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        let handle = try await client.open(serverPath(path), flags: .read)
        do {
            let data = try await client.readAll(
                handle: handle, offset: offset, length: length.map { UInt64($0) })
            try? await client.close(handle)
            return data
        } catch {
            try? await client.close(handle)
            throw error
        }
    }

    /// Streams a byte range to `receiver` without ever holding the whole file, at
    /// `window` requests in flight. The transfer scheduler of section 6.2 and the
    /// `fetchContents` FileHandle of section 5.2 both want this rather than `read`.
    public func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int = 16,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        let handle = try await client.open(serverPath(path), flags: .read)
        do {
            let count = try await client.read(
                handle: handle, offset: offset, length: length, window: window,
                receiver: receiver)
            try? await client.close(handle)
            return count
        } catch {
            try? await client.close(handle)
            throw error
        }
    }

    /// Section 5.5's temp file plus rename, fed a chunk at a time so that a large upload
    /// never sits in the agent's memory, and section 6.2's window share while it does it.
    ///
    /// A cancel (the extension's `Progress`, or its connection going away) removes the
    /// temp file it had started on the server, which is what section 5.2 requires.
    public func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int = 16,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let parent = path.parent else {
            throw SFTPError.failure("Cannot write to the location root")
        }
        let temporaryName = ".sshdrive-upload-\(uploadTag)-\(UUID().uuidString.lowercased())"
        let temporary = try parent.appending(component: temporaryName)
        let temporaryPath = serverPath(temporary)

        let handle = try await client.open(
            temporaryPath,
            flags: [.write, .create, .exclusive],
            attributes: SFTPSettableAttributes(permissions: mode))
        var written: Int64 = 0
        do {
            while true {
                if Task.isCancelled { throw SFTPError.cancelled }
                let piece = try source()
                if piece.isEmpty { break }
                try await client.write(
                    handle: handle, offset: UInt64(written), data: piece, window: window)
                written += Int64(piece.count)
                progress(written)
            }
            if await client.extensions.contains(.fsync) {
                try? await client.fsync(handle)
            }
            try await client.close(handle)
        } catch {
            try? await client.close(handle)
            try? await client.remove(temporaryPath)
            throw error
        }

        do {
            try await rename(temporary, into: path)
        } catch {
            try? await client.remove(temporaryPath)
            throw error
        }
        try? await client.setstat(serverPath(path), SFTPSettableAttributes(permissions: mode))
    }

    /// The create-versus-overwrite choice of section 5.5, shared by both write paths.
    private func rename(_ temporary: RelativePath, into path: RelativePath) async throws {
        let temporaryPath = serverPath(temporary)
        if await client.extensions.contains(.posixRename) {
            try await client.posixRename(temporaryPath, to: serverPath(path))
            return
        }
        do {
            try await client.rename(temporaryPath, to: serverPath(path))
        } catch {
            try await client.remove(serverPath(path))
            try await client.rename(temporaryPath, to: serverPath(path))
        }
    }

    /// Section 5.5: never write in place. The bytes go to
    /// `.sshdrive-upload-<tag>-<uuid>` beside the destination, are flushed with
    /// `fsync@openssh.com` where the server has it, and only then take the name.
    ///
    /// The create-versus-overwrite choice of section 5.5 (a non-overwriting `rename` for
    /// a create, `posix-rename@openssh.com` for a replacement) belongs to the agent's
    /// upload path in milestone 4, which drives the client directly; this method is the
    /// `SFTPTransport` shape the fake backend already has, so it replaces.
    public func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        guard let parent = path.parent else {
            throw SFTPError.failure("Cannot write to the location root")
        }
        let temporaryName = ".sshdrive-upload-\(uploadTag)-\(UUID().uuidString.lowercased())"
        let temporary = try parent.appending(component: temporaryName)
        let temporaryPath = serverPath(temporary)

        let handle = try await client.open(
            temporaryPath,
            flags: [.write, .create, .exclusive],
            attributes: SFTPSettableAttributes(permissions: mode))
        do {
            if !contents.isEmpty {
                try await client.write(handle: handle, offset: 0, data: contents)
            }
            if await client.extensions.contains(.fsync) {
                try? await client.fsync(handle)
            }
            try await client.close(handle)
        } catch {
            try? await client.close(handle)
            try? await client.remove(temporaryPath)
            throw error
        }

        do {
            if await client.extensions.contains(.posixRename) {
                try await client.posixRename(temporaryPath, to: serverPath(path))
            } else {
                // Without posix-rename there is no atomic replace on the wire. The
                // non-overwriting rename is tried first so the common create case stays
                // atomic, and only a genuine replacement takes the unlink-then-rename
                // window. Section 8.1 reports the difference as a capability tier.
                do {
                    try await client.rename(temporaryPath, to: serverPath(path))
                } catch {
                    try await client.remove(serverPath(path))
                    try await client.rename(temporaryPath, to: serverPath(path))
                }
            }
        } catch {
            try? await client.remove(temporaryPath)
            throw error
        }
        // The temp file was created with `mode`, but the server's umask may have taken
        // bits off it, so the mode is restored after the rename (section 5.5).
        try? await client.setstat(
            serverPath(path), SFTPSettableAttributes(permissions: mode))
    }

    public func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        try await client.mkdir(serverPath(path), mode: mode)
    }

    public func remove(_ path: RelativePath) async throws {
        try await client.remove(serverPath(path))
    }

    public func rmdir(_ path: RelativePath) async throws {
        try await client.rmdir(serverPath(path))
    }

    public func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await client.rename(serverPath(source), to: serverPath(destination))
    }

    public func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await client.posixRename(serverPath(source), to: serverPath(destination))
    }

    public func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        let attributes = SFTPSettableAttributes(
            permissions: mode,
            modifiedTime: mtime.map { UInt32(truncatingIfNeeded: $0) })
        guard !attributes.isEmpty else { return }
        // lsetstat where the server has it, so a setstat on a symlink cannot walk through
        // it (section 9.1's "never descend through a link").
        if await client.extensions.contains(.lsetstat) {
            do {
                try await client.lsetstat(serverPath(path), attributes)
                return
            } catch SFTPError.operationUnsupported {
                // Advertised and refused. Fall through.
            }
        }
        try await client.setstat(serverPath(path), attributes)
    }

    public func symlink(target: String, at path: RelativePath) async throws {
        try await client.symlink(target: Data(target.utf8), at: serverPath(path))
    }

    public func readlink(_ path: RelativePath) async throws -> String {
        String(decoding: try await client.readlink(serverPath(path)), as: UTF8.self)
    }

    public func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        try await client.statvfs(serverPath(path))
    }

    // MARK: Handles, for the callers that want them

    /// Opens a file. Exposed because the milestone 4 upload path and the transfer
    /// scheduler of section 6.2 need the handle, not just whole-file reads.
    public func open(_ path: RelativePath, flags: SFTPOpenFlags, mode: UInt32? = nil) async throws
        -> SFTPFileHandle
    {
        try await client.open(
            serverPath(path), flags: flags,
            attributes: SFTPSettableAttributes(permissions: mode))
    }

    public func close(_ handle: SFTPFileHandle) async throws {
        try await client.close(handle)
    }
}
