import Foundation
import XPCProtocols

/// Every answer the extension may give the system, as a platform-free value
/// (`docs/testing-architecture.md` section 2.2).
///
/// **Which error** is a rule, not an adapter detail, and the 0.1.2 field failure was
/// exactly a wrong value of this type: the working set answered `.serverUnreachable` for
/// any reader it could not use, and fileproviderd throttles a change enumeration that
/// keeps failing (`MQ-005`). Every rule in DESIGN.md about which error to return is a rule
/// about `ProviderFailure`, and each case carries the Apple domain and code the adapter
/// must produce, so a drift is one assert away in `MirroredProviderConstantsTests`.
public enum ProviderFailure: Error, Equatable, Hashable, Sendable {
    /// The one honest "there is nothing to say": the agent could not be reached at all.
    /// Never for a reader that is merely not ready - see `MQ-005`.
    case serverUnreachable
    /// A real answer about a real identifier. From `item(for:)` the system deletes the
    /// user's file (`MQ-011`), so it is never the answer to a reader that failed.
    case noSuchItem
    /// The remote state moved, a held deletion, a refusal we cannot express otherwise.
    case cannotSynchronize
    /// The anchor the system holds is older than the oldest row we still have; it re-asks
    /// from a fresh one (`MQ-006`).
    case syncAnchorExpired
    /// The name is taken. Retried for ever with no alert (`MQ-014`), so it is only ever
    /// the answer where the name is about to free itself.
    case filenameCollision
    case notAuthenticated
    case insufficientQuota
    /// `-2008`: refused for a pending upload and for a kept item alike, so the code says
    /// nothing about why (`MQ-018`).
    case nonEvictable
    /// A delete the agent will not perform - a non-empty directory the system did not ask
    /// to remove recursively (section 5.5).
    case deletionRejected
    case excludedFromSync
    /// `NSCocoaErrorDomain` / `NSFeatureUnsupportedError`. The trash contract of
    /// section 5.4: answering `.noSuchItem` to `enumerator(for: .trashContainer)` makes
    /// the system delete, fail, re-materialize and ask again for ever (`MQ-009`), while
    /// this one makes it give up after two attempts and remove `.Trash` (`MQ-010`).
    case featureUnsupported

    /// The error domain the adapter must raise this in.
    public var appleErrorDomain: String {
        switch self {
        case .featureUnsupported: return "NSCocoaErrorDomain"
        default: return "NSFileProviderErrorDomain"
        }
    }

    /// The code the adapter must raise this with. `NSFileProviderError.Code`'s raw values
    /// and `NSFeatureUnsupportedError`; the macOS-only test asserts every one of these
    /// against the framework's own symbol, because a number that drifted here would be
    /// silent everywhere else.
    public var appleErrorCode: Int {
        switch self {
        case .notAuthenticated: return -1000
        case .filenameCollision: return -1001
        case .syncAnchorExpired: return -1002
        case .insufficientQuota: return -1003
        case .serverUnreachable: return -1004
        case .noSuchItem: return -1005
        case .deletionRejected: return -1006
        case .cannotSynchronize: return -2005
        case .nonEvictable: return -2008
        case .excludedFromSync: return -2010
        case .featureUnsupported: return 3328
        }
    }

    /// The agent's own error codes, mapped once (section 5.1). A connection failure is
    /// `.serverUnreachable`, so the system queues and retries rather than showing an
    /// error; everything the agent cannot do becomes `.cannotSynchronize`, which leaves
    /// the item in place.
    public init(agentError: SSHDriveAgentError) {
        switch agentError {
        case .serverUnreachable, .interfaceVersionMismatch, .unknownDomain:
            self = .serverUnreachable
        case .notAuthenticated: self = .notAuthenticated
        case .noSuchItem: self = .noSuchItem
        case .filenameCollision: self = .filenameCollision
        case .insufficientQuota: self = .insufficientQuota
        case .deletionRejected: self = .deletionRejected
        case .versionMismatch, .cannotSynchronize, .permissionDenied, .notImplemented:
            self = .cannotSynchronize
        }
    }

    /// The reverse trip: an error the agent raised in the system's own domain - the
    /// `.syncAnchorExpired` that comes back off the working-set fallback - is already the
    /// answer and must survive the crossing (section 5.3). Anything unrecognised becomes
    /// `.cannotSynchronize`, which leaves the item in place.
    public init(appleErrorCode code: Int) {
        switch code {
        case -1000: self = .notAuthenticated
        case -1001: self = .filenameCollision
        case -1002: self = .syncAnchorExpired
        case -1003: self = .insufficientQuota
        case -1004: self = .serverUnreachable
        case -1005: self = .noSuchItem
        case -1006: self = .deletionRejected
        case -2008: self = .nonEvictable
        case -2010: self = .excludedFromSync
        default: self = .cannotSynchronize
        }
    }

    /// The message a refused trash operation carries.
    public static let trashUnsupportedMessage =
        "SSH Drive has no trash; items are deleted on the server."
}
