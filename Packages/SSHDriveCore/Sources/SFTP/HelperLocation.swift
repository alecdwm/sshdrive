import Foundation

/// The one deliberate exception to the `RelativePath` chokepoint of DESIGN.md section 9.1.
///
/// Everything the user's files travel through is a `RelativePath` joined to the location's
/// canonical root, and `SFTPServerPath`'s initialiser is internal to this module precisely
/// so that nothing outside can hand the client a string. The helper of section 6.4 tier 2
/// does not fit that shape: it is deployed to `$XDG_CACHE_HOME/sshdrive`,
/// `~/.cache/sshdrive` or `/tmp/sshdrive-<uid>`, which are outside every location root by
/// design - the binary is shared by every location on that account and must not appear
/// inside anybody's mount.
///
/// So there is a second, much narrower door. It admits an **absolute** directory the
/// *probe* chose (never a user string), and a single filename component under it. It has
/// no `..`, no nesting, and no way to express a path anywhere else: a `HelperFile` is
/// exactly `<directory>/<one component>`. Nothing in the File Provider path ever
/// constructs one (2026-09-05, section 13).
public struct HelperDirectory: Sendable, Equatable, Hashable {
    /// Absolute, with no trailing slash.
    public let path: String

    /// Nil for anything that is not a plain absolute path: a relative path, one with a
    /// `.` or `..` component, an empty one, or one carrying a NUL. The probe's answer is
    /// the only thing that is ever passed here, and it is still checked.
    public init?(absolute: String) {
        guard absolute.hasPrefix("/"), !absolute.contains("\0") else { return nil }
        let components = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        // Re-spelled from its own components, so a path with doubled or trailing slashes
        // has exactly one canonical form here.
        self.path = "/" + components.joined(separator: "/")
    }

    /// One file directly inside the directory. `name` must be a single component.
    public func file(_ name: String) -> HelperFile? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        return HelperFile(directory: self, name: name)
    }

    /// The parent, for the `mkdir -p` the deployment does one level at a time. Nil at the
    /// filesystem root.
    public var parent: HelperDirectory? {
        var components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        components.removeLast()
        return HelperDirectory(absolute: "/" + components.joined(separator: "/"))
    }

    var serverPath: SFTPServerPath { SFTPServerPath(bytes: Data(path.utf8)) }
}

public struct HelperFile: Sendable, Equatable, Hashable {
    public let directory: HelperDirectory
    public let name: String

    public var path: String { directory.path + "/" + name }

    var serverPath: SFTPServerPath { SFTPServerPath(bytes: Data(path.utf8)) }
}

/// The SFTP operations the helper's deployment needs, and no others.
///
/// Deliberately not on `SFTPTransport`: the protocol is the File Provider's surface and
/// every method on it takes a `RelativePath`. These sit on the real client, are reached
/// only from `HelperDeployer`, and are listed one by one rather than exposed as a general
/// absolute-path API.
extension RealSFTPTransport {

    public func helperLstat(_ file: HelperFile) async throws -> SFTPFileAttributes {
        try await client.lstat(file.serverPath)
    }

    public func helperLstat(_ directory: HelperDirectory) async throws -> SFTPFileAttributes {
        try await client.lstat(directory.serverPath)
    }

    /// Section 6.4: "The directory is created with `mkdir -m 700`". SFTP has no `-p`, so a
    /// missing parent is created first; an existing directory answers `FAILURE` and is not
    /// an error here.
    public func helperMkdir(_ directory: HelperDirectory, mode: UInt32 = 0o700) async throws {
        if let parent = directory.parent, (try? await helperLstat(parent)) == nil {
            try? await client.mkdir(parent.serverPath, mode: 0o700)
        }
        try? await client.mkdir(directory.serverPath, mode: mode)
        // Whether it existed already or was just made, it has to be there now.
        let attributes = try await helperLstat(directory)
        // `mkdir`'s attributes go through the server's umask, so a 0700 that was asked for
        // can land as 0755. Assert it (2026-09-05).
        if attributes.mode & 0o777 != mode & 0o777 {
            try? await helperSetstat(directory, mode: mode)
        }
    }

    /// `chmod` on the helper's own directory. Section 6.4 wants it at 0700 and a server's
    /// umask applies to `mkdir`'s attributes, so the mode is asserted after the fact as
    /// well as asked for (2026-09-05).
    public func helperSetstat(_ directory: HelperDirectory, mode: UInt32) async throws {
        try await client.setstat(
            directory.serverPath, SFTPSettableAttributes(permissions: mode))
    }

    public func helperReaddir(_ directory: HelperDirectory) async throws -> [SFTPDirectoryEntry] {
        try await client.listDirectory(directory.serverPath)
    }

    /// Writes a whole file that must not already exist. The upload goes to a temp name and
    /// is renamed into place by the caller, exactly like every other upload (section 5.5):
    /// writing over a running executable fails `ETXTBSY` on Linux, and the rename leaves
    /// the old inode to whatever process is using it.
    public func helperWriteExclusive(_ file: HelperFile, contents: Data, mode: UInt32) async throws {
        let handle = try await client.open(
            file.serverPath, flags: [.write, .create, .exclusive],
            attributes: SFTPSettableAttributes(permissions: mode))
        do {
            try await client.write(handle: handle, offset: 0, data: contents)
            try await client.close(handle)
        } catch {
            try? await client.close(handle)
            try? await client.remove(file.serverPath)
            throw error
        }
        // The mode `open` was given is only a *creation* mode and a server may apply its
        // umask to it; the helper has to be executable or nothing else here matters.
        try? await client.setstat(file.serverPath, SFTPSettableAttributes(permissions: mode))
    }

    public func helperRename(_ source: HelperFile, to destination: HelperFile) async throws {
        try await client.posixRename(source.serverPath, to: destination.serverPath)
    }

    public func helperRemove(_ file: HelperFile) async throws {
        try await client.remove(file.serverPath)
    }

    public func helperRmdir(_ directory: HelperDirectory) async throws {
        try await client.rmdir(directory.serverPath)
    }

    /// Only ever used to read back a short file the deployment itself wrote.
    public func helperRead(_ file: HelperFile, length: Int) async throws -> Data {
        let handle = try await client.open(file.serverPath, flags: [.read])
        defer { Task { try? await client.close(handle) } }
        return try await client.readAll(handle: handle, offset: 0, length: UInt64(length))
    }
}
