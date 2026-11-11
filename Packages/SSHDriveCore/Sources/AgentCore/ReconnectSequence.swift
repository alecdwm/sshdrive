import Foundation

/// The order in which a location is put back together when a connection comes up
/// (docs/design/offline.md, docs/design/change-detection.md).
///
/// It is a value in the package rather than the shape of one function in the agent because
/// the order matters and is invisible from outside: the helper stream runs on an exec
/// channel opened against the same master the SFTP channels sit on, so re-opening it
/// before `applyConnection` has re-derived those would start tier 2 on the connection that
/// is going away. And it belongs *here* at all because the stream is per connection:
/// leaving it to the next poll cycle costs up to 60 s on a touched location, up to 10
/// minutes on an idle one, and never happens on one a runtime failure has dropped a tier.
public enum ReconnectStep: String, Sendable, Equatable, CaseIterable {
    /// The identity, the channel budget, both SFTP channels, both spellings of the root
    /// and the root row (`LocationRuntime.applyConnection`).
    case applyConnection
    /// The ladder re-reads the probe: a NAS can come back with a busybox `find` where
    /// there was GNU, or an account can have lost its shell.
    case applyCapabilities
    /// Tier 2's exec channel, and the full sweep every reconnect owes.
    case reopenHelperStream
    /// The system's cue to retry the uploads and fetches it queued
    /// (docs/design/offline.md).
    case signalErrorResolved
    /// And the working set, for the working set.
    case signalWorkingSet

    /// Whether this step needs a connection that has already been applied.
    public var needsAppliedConnection: Bool { self != .applyConnection }
}

/// The sequence runs once per connection, after the gate has handed the connection out,
/// on a task of its own. Two rules keep it about the connection it was started for:
///
/// - **One at a time per location.** A sequence for connection N+1 starts only once N's
///   has finished, so N's steps can never land after N+1's.
/// - **Every step is for the current connection.** Each connection the gate brings up has
///   a generation, and a step runs only while that generation is still the gate's. A
///   connection that dropped during its own sequence - during the server probe, during
///   `applyConnection` - leaves the rest of it undone; the next connection's sequence does
///   all of it.
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

    /// Whether a sequence started for `generation` may run its next step, given the
    /// generation of the connection the gate holds now (nil when it holds none).
    public static func mayRun(generation: Int, current: Int?) -> Bool {
        current == generation
    }

    /// When a connection that came up with an unanswered server probe or an inconclusive
    /// channel budget asks again on the same connection: 30 s after it came up, doubling to
    /// 10 minutes, for as long as that connection lasts (docs/design/offline.md).
    public static let firstRecheckSeconds: Double = 30
    public static let recheckCapSeconds: Double = 600

    /// The wait before the re-check numbered `attempt`, counting from 0.
    public static func recheckDelay(attempt: Int) -> Double {
        min(firstRecheckSeconds * pow(2, Double(max(0, min(attempt, 20)))), recheckCapSeconds)
    }

    /// How many budget re-checks in a row may come back inconclusive, with the master
    /// still running, before the connection stops asking. Wording nobody has seen keeps a
    /// channel neither opened nor refused for good; the next connect probes again from
    /// scratch, as it does for any budget below the full one.
    public static let inconclusiveBudgetRecheckLimit = 3

    /// What a budget re-check that found room for `found` channels does with the
    /// connection that holds `current`.
    public enum BudgetRecheckAction: Sendable, Equatable {
        /// Nothing to gain: the connection keeps what it has.
        case keep
        /// Drop the connection and reconnect, which is the only way to add a channel.
        case reconnect
        /// Not now: a download or an upload is running, and dropping the connection under
        /// it loses it - the system never re-issues a failed `fetchContents` (gotcha 59).
        /// The next re-check, or the next reconnect that happens anyway, picks up the
        /// budget, which is on record by then.
        case deferReconnect
    }

    public static func budgetRecheckAction(
        current: Int, found: Int, transferInFlight: Bool
    ) -> BudgetRecheckAction {
        guard found > current else { return .keep }
        return transferInFlight ? .deferReconnect : .reconnect
    }
}
