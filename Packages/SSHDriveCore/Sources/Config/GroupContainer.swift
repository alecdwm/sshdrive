import Foundation
import Logging

/// The app-group container, the one place all four processes share
/// (DESIGN.md section 3):
///
///     config.json                  schema version, the install's macId, locations
///     domains/<location-id>/index.sqlite
///     domains/<location-id>/index.sqlite.bak
///     domains/<location-id>/pins.json
///     domains/<location-id>/capabilities.json
///
/// These paths stay where section 3 puts them, at the root of the group container, and
/// are deliberately *not* moved somewhere "outside" the extension's
/// `NSExtensionFileProviderDocumentGroup`. There is nowhere to move them to: the document
/// group is the app group identifier, so its path is this container, and fileproviderd's
/// own replica lives in a subdirectory of it (`File Provider Storage`, which is what
/// `fileproviderctl dump` reports as the extension storage URL). Everything we write is
/// already a sibling of that directory, and any other subdirectory would still be inside
/// the same coordinated container. Section 5.2 also pins the index here on purpose: the
/// read-only WAL reader in the sandboxed extension is possible *because* the index sits
/// in the group container, which the extension may write `-shm` into.
///
/// The three-minute `config.json` write seen during S1 (docs/spikes/results.md,
/// 2026-09-04) was file coordination on the container, not the choice of subdirectory, so
/// it is fixed where it belongs: the blocking I/O runs off the agent's actors
/// (`Apps/Agent/ConfigAccess.swift`) and every File Provider call is bounded
/// (`Apps/Agent/Deadline.swift`).
public enum GroupContainer {
    public static let identifier = "RWGDZAYBM8.org.shirls.sshdrive"

    public enum ContainerError: Error, LocalizedError {
        case unavailable

        public var errorDescription: String? {
            "The app group container \(GroupContainer.identifier) is not available. "
                + "The app is probably unsigned or missing its application-groups entitlement."
        }
    }

    /// The container URL, or nil when the calling process has no app-group entitlement.
    public static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func requireURL() throws -> URL {
        guard let url else { throw ContainerError.unavailable }
        return url
    }

    public static func configURL() throws -> URL {
        try requireURL().appendingPathComponent("config.json")
    }

    public static func domainsURL() throws -> URL {
        try requireURL().appendingPathComponent("domains", isDirectory: true)
    }

    public static func domainURL(locationID: String) throws -> URL {
        try domainsURL().appendingPathComponent(locationID, isDirectory: true)
    }

    public static func indexURL(locationID: String) throws -> URL {
        try domainURL(locationID: locationID).appendingPathComponent("index.sqlite")
    }

    public static func indexBackupURL(locationID: String) throws -> URL {
        try domainURL(locationID: locationID).appendingPathComponent("index.sqlite.bak")
    }

    public static func pinsURL(locationID: String) throws -> URL {
        try domainURL(locationID: locationID).appendingPathComponent("pins.json")
    }

    public static func capabilitiesURL(locationID: String) throws -> URL {
        try domainURL(locationID: locationID).appendingPathComponent("capabilities.json")
    }

    /// Creates the per-domain directory. Only the agent calls this; the extension never
    /// writes anything in the container.
    @discardableResult
    public static func createDomainDirectory(locationID: String) throws -> URL {
        let url = try domainURL(locationID: locationID)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
