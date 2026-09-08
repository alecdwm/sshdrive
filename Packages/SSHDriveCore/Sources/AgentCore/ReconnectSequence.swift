import Foundation

/// The order in which a location is put back together when a connection comes up
/// (DESIGN.md sections 5.6 and 6.4).
///
/// It is a value in the package rather than the shape of one function in the agent because
/// the order is a decision that has been got wrong once and is invisible from outside:
/// section 6.4's helper stream runs on an exec channel opened against the same master the
/// SFTP channels sit on, so re-opening it before `applyConnection` has re-derived those
/// would start tier 2 on the connection that is going away. And it must happen *here* at
/// all: the stream is per connection, and leaving it to the next poll cycle is up to 60 s
/// on a touched location, up to 10 minutes on an idle one, and never on one a runtime
/// failure had dropped a tier (2026-09-08).
public enum ReconnectStep: String, Sendable, Equatable, CaseIterable {
    /// The identity, the channel budget, both SFTP channels, both spellings of the root
    /// and the root row (`LocationRuntime.applyConnection`).
    case applyConnection
    /// The ladder re-reads the probe: a NAS can come back with a busybox `find` where
    /// there was GNU, or an account can have lost its shell.
    case applyCapabilities
    /// Tier 2's exec channel, and the full sweep section 6.4 owes every reconnect.
    case reopenHelperStream
    /// Section 5.6: the system's cue to retry the uploads and fetches it queued.
    case signalErrorResolved
    /// And the working set, for the working set.
    case signalWorkingSet

    /// Whether this step needs a connection that has already been applied.
    public var needsAppliedConnection: Bool { self != .applyConnection }
}

public enum ReconnectSequence {
    public static let steps: [ReconnectStep] = [
        .applyConnection, .applyCapabilities, .reopenHelperStream,
        .signalErrorResolved, .signalWorkingSet,
    ]

    /// Every step runs exactly once, and the helper's stream is re-opened after the
    /// channels it shares a master with.
    public static func indexOf(_ step: ReconnectStep) -> Int {
        steps.firstIndex(of: step) ?? -1
    }
}
