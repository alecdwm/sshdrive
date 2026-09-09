import Foundation

/// The one chokepoint for every remote path (DESIGN.md section 9.1).
///
/// The SFTP layer has no API that takes a string path. Every operation takes a
/// `RelativePath`, which can only be built from validated components, and the transport
/// joins it to the canonical root itself. A path may have zero components, which is the
/// root; a component is rejected if it is empty, ".", "..", or contains "/" or NUL.
///
/// Components are bytes, not Strings: server names need not be valid UTF-8 (section 5.4).
public struct RelativePath: Hashable, Sendable, CustomStringConvertible {
    public enum ValidationError: Error, LocalizedError, Equatable {
        case emptyComponent
        case dotComponent
        case dotDotComponent
        case separatorInComponent
        case nulInComponent

        public var errorDescription: String? {
            switch self {
            case .emptyComponent: return "A path component may not be empty."
            case .dotComponent: return "A path component may not be \".\"."
            case .dotDotComponent: return "A path component may not be \"..\"."
            case .separatorInComponent: return "A path component may not contain \"/\"."
            case .nulInComponent: return "A path component may not contain NUL."
            }
        }
    }

    /// The validated components, as raw server bytes.
    public let components: [Data]

    /// The path as raw bytes, "a/b/c", with no leading slash. This is what the index
    /// stores in its BLOB `path` column.
    ///
    /// Stored rather than computed: a listing asks for it four or five times per entry -
    /// the seen set, the in-flight set, the incumbent row read, the row itself - so
    /// computing it would rebuild the same `Data` fifty thousand times over a directory of
    /// ten thousand entries (section 5.3). It is derived from `components` and nothing
    /// else.
    public let bytes: Data

    /// The location root itself.
    public static let root = RelativePath()

    private init() {
        components = []
        bytes = Data()
    }

    private init(validated: [Data], bytes: Data) {
        components = validated
        self.bytes = bytes
    }

    /// Builds a path from raw component bytes, validating each.
    public init(components: [Data]) throws {
        for component in components {
            try RelativePath.validate(component)
        }
        self.components = components
        self.bytes = RelativePath.join(components)
    }

    /// Builds a path from a "a/b/c" string. Leading and trailing slashes are allowed and
    /// ignored, so both "/" and "" mean the root; every other component is validated.
    public init(string: String) throws {
        let parts = string.split(separator: "/", omittingEmptySubsequences: true)
        try self.init(components: parts.map { Data($0.utf8) })
    }

    private static func validate(_ component: Data) throws {
        if component.isEmpty { throw ValidationError.emptyComponent }
        if component.contains(0x2F) { throw ValidationError.separatorInComponent }
        if component.contains(0x00) { throw ValidationError.nulInComponent }
        if component == Data(".".utf8) { throw ValidationError.dotComponent }
        if component == Data("..".utf8) { throw ValidationError.dotDotComponent }
    }

    public var isRoot: Bool { components.isEmpty }

    /// The last component, or nil at the root.
    public var lastComponent: Data? { components.last }

    /// The parent path, or nil at the root.
    public var parent: RelativePath? {
        guard let last = components.last else { return nil }
        // The parent's bytes are this path's without the last component and the slash
        // that precedes it; at depth one they are empty.
        let trimmed = bytes.count - last.count
        let cut = trimmed > 0 ? trimmed - 1 : 0
        return RelativePath(
            validated: Array(components.dropLast()), bytes: Data(bytes.prefix(cut)))
    }

    public func appending(component: Data) throws -> RelativePath {
        try RelativePath.validate(component)
        var joined = bytes
        if !joined.isEmpty { joined.append(0x2F) }
        joined.append(component)
        return RelativePath(validated: components + [component], bytes: joined)
    }

    public func appending(component: String) throws -> RelativePath {
        try appending(component: Data(component.utf8))
    }

    public func appending(_ other: RelativePath) -> RelativePath {
        RelativePath(
            validated: components + other.components,
            bytes: RelativePath.join(components + other.components))
    }

    /// True when `self` is `other` or lies under it.
    public func isUnder(_ other: RelativePath) -> Bool {
        guard other.components.count <= components.count else { return false }
        return Array(components.prefix(other.components.count)) == other.components
    }

    private static func join(_ components: [Data]) -> Data {
        var out = Data()
        for (offset, component) in components.enumerated() {
            if offset > 0 { out.append(0x2F) }
            out.append(component)
        }
        return out
    }

    /// Two paths are the same path when their bytes are: a component may not contain a
    /// slash, so the joined form and the component list determine one another exactly,
    /// and comparing one `Data` beats comparing an array of them.
    public static func == (lhs: RelativePath, rhs: RelativePath) -> Bool {
        lhs.bytes == rhs.bytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }

    /// Builds a path from the bytes `bytes` produced.
    public static func fromIndexBytes(_ data: Data) throws -> RelativePath {
        guard !data.isEmpty else { return .root }
        let parts: [Data] = data.split(separator: UInt8(0x2F)).map { Data($0) }
        return try RelativePath(components: parts)
    }

    /// A lossy display form, for logs and the CLI. Never sent to a server.
    public var description: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Joins to an absolute server root, byte for byte. This is the form that goes on
    /// the wire: a component need not be valid UTF-8 (section 5.4), so it must never be
    /// round-tripped through a String on the way there. Only the transport calls this.
    public func absoluteBytes(root: Data) -> Data {
        var out = root
        // A trailing slash on the root would produce "//" here, which is legal but ugly
        // in a log line; an empty root would produce a relative path, which is not what
        // any caller means, so it becomes "/" plus the components.
        while out.count > 1, out.last == 0x2F { out.removeLast() }
        guard !components.isEmpty else { return out.isEmpty ? Data("/".utf8) : out }
        for component in components {
            out.append(0x2F)
            out.append(component)
        }
        return out
    }

    /// Joins to an absolute server root. Only the transport calls this.
    public func absolute(root: String) -> String {
        guard !components.isEmpty else { return root }
        let suffix = components
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "/")
        return root.hasSuffix("/") ? root + suffix : root + "/" + suffix
    }
}
