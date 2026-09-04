import Foundation

/// Errors the agent hands back over XPC. The extension maps each to an
/// NSFileProviderError before it reaches the system (DESIGN.md section 5.1); nothing
/// here names an NSFileProvider type, because the CLI and askpass link this module too.
public enum SSHDriveAgentError: Int, Sendable {
    /// Connect timeout, EOF, ENETUNREACH, DNS, or ssh exiting with a connection error.
    /// Also every call refused while a reconcile runs (section 5.3).
    case serverUnreachable = 1
    /// Auth or host-key failure. The domain shows as needing attention.
    case notAuthenticated = 2
    /// The item has no row, and the index is known to be complete.
    case noSuchItem = 3
    /// A name held by a hidden symlink or by a collision (sections 5.4, 5.7).
    case filenameCollision = 4
    /// A bare FAILURE followed by a statvfs that showed the filesystem full or over quota.
    case insufficientQuota = 5
    /// The remote state moved under us; the caller should re-fetch rather than retry.
    case versionMismatch = 6
    /// A held deletion: the item is left in place (section 6.4).
    case cannotSynchronize = 7
    /// Not implemented in this milestone.
    case notImplemented = 8
    /// The caller's interface version does not match the agent's (section 5.2).
    case interfaceVersionMismatch = 9
    /// No location with that identifier.
    case unknownDomain = 10
    /// The operation is not permitted on the server.
    case permissionDenied = 11
    /// A delete the agent will not perform: a non-empty directory the system did not ask
    /// to remove recursively (section 5.5). The system leaves the item in place rather
    /// than retrying, which is the whole point of having an error of its own.
    case deletionRejected = 12

    public static let domain = "org.shirls.sshdrive.AgentError"

    public func asNSError(_ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: Self.domain, code: rawValue, userInfo: info)
    }
}

extension NSError {
    /// The agent error this NSError carries, if any.
    public var sshDriveAgentError: SSHDriveAgentError? {
        guard domain == SSHDriveAgentError.domain else { return nil }
        return SSHDriveAgentError(rawValue: code)
    }
}
