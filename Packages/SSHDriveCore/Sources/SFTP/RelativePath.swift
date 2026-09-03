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

    /// The location root itself.
    public static let root = RelativePath()

    private init() {
        components = []
    }

    private init(validated: [Data]) {
        components = validated
    }

    /// Builds a path from raw component bytes, validating each.
    public init(components: [Data]) throws {
        for component in components {
            try RelativePath.validate(component)
        }
        self.components = components
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
        guard !components.isEmpty else { return nil }
        return RelativePath(validated: Array(components.dropLast()))
    }

    public func appending(component: Data) throws -> RelativePath {
        try RelativePath.validate(component)
        return RelativePath(validated: components + [component])
    }

    public func appending(component: String) throws -> RelativePath {
        try appending(component: Data(component.utf8))
    }

    public func appending(_ other: RelativePath) -> RelativePath {
        RelativePath(validated: components + other.components)
    }

    /// True when `self` is `other` or lies under it.
    public func isUnder(_ other: RelativePath) -> Bool {
        guard other.components.count <= components.count else { return false }
        return Array(components.prefix(other.components.count)) == other.components
    }

    /// The path as raw bytes, "a/b/c", with no leading slash. This is what the index
    /// stores in its BLOB `path` column.
    public var bytes: Data {
        var out = Data()
        for (offset, component) in components.enumerated() {
            if offset > 0 { out.append(0x2F) }
            out.append(component)
        }
        return out
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

    /// Joins to an absolute server root. Only the transport calls this.
    public func absolute(root: String) -> String {
        guard !components.isEmpty else { return root }
        let suffix = components
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "/")
        return root.hasSuffix("/") ? root + suffix : root + "/" + suffix
    }
}
