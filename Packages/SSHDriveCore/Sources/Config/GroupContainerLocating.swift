import Foundation

/// How a process finds the app-group container (docs/design/components.md).
///
/// On macOS this is `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
/// and nothing else; the seam exists so the package compiles and tests off Darwin, where
/// there is no app group and no entitlement to check. See `docs/design/testing.md`.
public protocol GroupContainerLocating: Sendable {
    /// The container directory for `identifier`, or nil when this process has none.
    func containerURL(forGroupIdentifier identifier: String) -> URL?
}

#if canImport(Darwin)
    /// The real thing: the app-group container the entitlement grants, from the one
    /// call that reads it.
    public struct SystemGroupContainerLocator: GroupContainerLocating {
        public init() {}

        public func containerURL(forGroupIdentifier identifier: String) -> URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
    }
#endif

/// A container named by the environment, for the Linux suite: `SSHDRIVE_GROUP_CONTAINER`
/// is a directory a test points at a temp dir. Unset means "this process has no
/// container", which is the same answer an unentitled process gets on macOS.
///
/// The directory is created on first use, because that is what
/// `containerURL(forSecurityApplicationGroupIdentifier:)` does for an entitled process.
public struct EnvironmentGroupContainerLocator: GroupContainerLocating {
    public static let variableName = "SSHDRIVE_GROUP_CONTAINER"

    public init() {}

    public func containerURL(forGroupIdentifier identifier: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[Self.variableName],
            !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// An explicit directory, for a test that would rather hand one over than set a variable.
public struct FixedGroupContainerLocator: GroupContainerLocating {
    private let url: URL?

    public init(_ url: URL?) { self.url = url }

    public func containerURL(forGroupIdentifier identifier: String) -> URL? {
        if let url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
