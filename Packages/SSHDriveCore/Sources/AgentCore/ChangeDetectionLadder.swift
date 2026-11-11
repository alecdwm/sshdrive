import Config
import Foundation

/// Which change-detection tier a location runs at, and why it is not higher
/// (docs/design/change-detection.md, reported by `sshdrive status`).
///
/// `watchMode: auto`, the default, tries the tiers from the top: helper first, then sweep,
/// then poll, settling on the first one that starts successfully. A tier that fails at
/// runtime drops the location one tier down and records why, which `sshdrive status`
/// shows: for a backoff of seconds when the failure is transient, for the rest of the
/// connection (and at most 30 minutes) when it is one of the server facts the design
/// lists as permanent. Setting `watchMode` to a specific tier disables the fallback
/// ladder except to `poll`, which always works.
///
/// The tier is a decision, not a connection, so this is a value with the clock passed in.
/// Nothing on the File Provider side knows which tier is active; the content version
/// format (docs/design/item-index.md) is the same at every tier so a tier change is
/// invisible too.
public struct ChangeDetectionLadder: Sendable, Equatable {

    /// The three tiers, ordered worst to best. `poll` is the floor: it
    /// needs SFTP and nothing else, so it always works and nothing ever drops below it.
    public enum Tier: String, Sendable, Comparable, CaseIterable {
        case poll
        case sweep
        case helper

        private var rank: Int {
            switch self {
            case .poll: return 0
            case .sweep: return 1
            case .helper: return 2
            }
        }

        public static func < (left: Tier, right: Tier) -> Bool { left.rank < right.rank }

        /// One tier down, or nil at the floor.
        public var oneLower: Tier? {
            switch self {
            case .helper: return .sweep
            case .sweep: return .poll
            case .poll: return nil
            }
        }
    }

    /// What the probe measured about this server (docs/design/cli.md).
    public struct ServerCapabilities: Sendable, Equatable {
        /// The account has shell (exec) access at all. False for a chrooted
        /// `internal-sftp` or a `ForceCommand internal-sftp` account, which is the one
        /// case that pins a location to tier 0.
        public var hasExecChannel: Bool
        public var hasFind: Bool
        /// False for every busybox build measured, which answers
        /// `find: unrecognized: -cmin` (docs/design/change-detection.md).
        public var takesCmin: Bool
        public var takesPrintf: Bool
        /// False for a server that cannot run the helper: no writable executable
        /// directory, a `noexec` mount, an unsupported OS or arch, no channel to spare, a
        /// failed upload or a failed hash check.
        public var helperAvailable: Bool
        /// The user's own `helper off` for this location.
        public var helperEnabledForLocation: Bool
        /// What the deployment said when it refused, verbatim, so `status` prints the real
        /// reason - `cache directory is noexec`, `helper unsupported: Linux mips`, `helper
        /// upload failed: …` - rather than a category (docs/design/cli.md).
        public var helperBlockReason: String?

        public init(hasExecChannel: Bool = false, hasFind: Bool = false, takesCmin: Bool = false,
                    takesPrintf: Bool = false, helperAvailable: Bool = false,
                    helperEnabledForLocation: Bool = true, helperBlockReason: String? = nil) {
            self.hasExecChannel = hasExecChannel
            self.hasFind = hasFind
            self.takesCmin = takesCmin
            self.takesPrintf = takesPrintf
            self.helperAvailable = helperAvailable
            self.helperEnabledForLocation = helperEnabledForLocation
            self.helperBlockReason = helperBlockReason
        }
    }

    /// One runtime failure that cost the location a tier, kept for `sshdrive status`.
    public struct Downgrade: Sendable, Equatable {
        public var from: Tier
        public var to: Tier
        public var reason: String
        public var at: Double
        /// Whether it cost the tier for the connection or only for a backoff. `status` says
        /// so, because a transient downgrade the location has already climbed out of
        /// otherwise reads as a tier it is still stuck at.
        public var permanence: Permanence
        /// When a permanent downgrade stopped binding: a new connection came up, or its 30
        /// minutes ran out. Nil while it is in force, and always nil for a transient one,
        /// whose end is its hold.
        public var liftedAt: Double?

        public init(from: Tier, to: Tier, reason: String, at: Double,
                    permanence: Permanence = .permanent, liftedAt: Double? = nil) {
            self.from = from
            self.to = to
            self.reason = reason
            self.at = at
            self.permanence = permanence
            self.liftedAt = liftedAt
        }
    }

    /// Whether a runtime failure is one docs/design/change-detection.md counts as
    /// permanent.
    ///
    /// The permanent list is the typed facts about the server - no shell, an unsupported
    /// architecture, a `noexec` or foreign directory, a hash that did not match after a
    /// redeploy. A permanent failure holds the tier down for the rest of the connection,
    /// and on a connection that lives for hours it is decided again every
    /// `permanentRecheckSeconds`, because a fact about a server can change without the
    /// connection noticing. Everything else is transient, held down for a bounded backoff
    /// and then tried again: an error that is not one of those facts is far more often an
    /// outage, and an outage read as a verdict leaves the location below its best tier
    /// long after the link is back.
    public enum Permanence: String, Sendable, Equatable {
        case permanent
        case transient
    }

    /// The first transient hold, doubling to `retryCapSeconds`. Small, because the common
    /// transient failure is "the link went away and came back" and the user is watching a
    /// mount that has stopped updating.
    public static let firstRetrySeconds: Double = 2
    public static let retryCapSeconds: Double = 60
    /// How long a tier has to run without dying before its transient failures are
    /// forgotten, so a server that is fine again does not carry a 60 s backoff for ever.
    public static let stabilitySeconds: Double = 120
    /// How long a permanent failure holds the tier down on a connection that stays up.
    /// The next connection decides again at once; this bounds the verdict on one that
    /// never drops.
    public static let permanentRecheckSeconds: Double = 30 * 60
    /// How many downgrades the history keeps for `status`. A location that sits through
    /// an outage of hours records one transient downgrade per retry, and `status` prints
    /// every entry it is given.
    public static let historyLimit = 20

    public private(set) var tier: Tier
    public private(set) var downgrades: [Downgrade]
    /// Why the tier is not `helper`, for the `note:` line `sshdrive status` prints. Nil at
    /// the best tier.
    public private(set) var note: String?

    /// What the last probe said, kept so a `status` line can explain the tier without the
    /// caller holding the capabilities separately.
    public private(set) var capabilities: ServerCapabilities
    public private(set) var watchMode: WatchMode

    /// The best tier a **permanent** runtime failure has left available, and since when.
    /// A later probe may lower the tier but never raise it back over one of those; a new
    /// connection (`noteConnected`) or `permanentRecheckSeconds` lifts it.
    private var permanentCeiling: Tier
    private var permanentSince: Double = 0
    /// The best tier a **transient** failure is holding the location to, and until when.
    /// Cleared by `climbBack` once the hold expires, and by `noteConnected`, because a
    /// connection that came up is the evidence the outage is over.
    private var transientCeiling: Tier?
    private var transientUntil: Double = 0
    private var transientFailures = 0
    private var transientReason: String?

    public init(watchMode: WatchMode, capabilities: ServerCapabilities, now: Double) {
        self.watchMode = watchMode
        self.capabilities = capabilities
        self.downgrades = []
        self.permanentCeiling = .helper
        let selected = ChangeDetectionLadder.select(watchMode: watchMode, capabilities: capabilities)
        self.tier = selected
        self.note = ChangeDetectionLadder.note(tier: selected, watchMode: watchMode, capabilities: capabilities)
    }

    // MARK: Selection

    /// The ladder. `auto` walks down from the top and takes the first tier that
    /// can start; a specific `watchMode` takes that tier or falls straight to `poll`,
    /// never to the tier in between, because asking for the helper and silently getting a
    /// sweep is not what "set `watchMode` to a specific tier" means.
    private static func select(watchMode: WatchMode, capabilities: ServerCapabilities) -> Tier {
        let helperCanStart =
            capabilities.hasExecChannel && capabilities.helperAvailable && capabilities.helperEnabledForLocation
        let sweepCanStart = capabilities.hasExecChannel && capabilities.hasFind
        switch watchMode {
        case .auto:
            if helperCanStart { return .helper }
            if sweepCanStart { return .sweep }
            return .poll
        case .helper:
            return helperCanStart ? .helper : .poll
        case .sweep:
            return sweepCanStart ? .sweep : .poll
        case .poll:
            return .poll
        }
    }

    /// Why the helper is not running, in the order that is most useful to read: the user's
    /// own setting first, because it is the one thing they changed; then shell access,
    /// because nothing above `poll` works without it; then availability.
    private static func helperBlocked(_ capabilities: ServerCapabilities) -> String {
        if !capabilities.helperEnabledForLocation { return "the helper is off for this location" }
        if !capabilities.hasExecChannel { return "the account has no shell access" }
        if let reason = capabilities.helperBlockReason { return reason }
        if !capabilities.helperAvailable { return "the server cannot run the remote helper" }
        return "the helper did not start"
    }

    private static func sweepBlocked(_ capabilities: ServerCapabilities) -> String {
        if !capabilities.hasExecChannel { return "the account has no shell access" }
        if !capabilities.hasFind { return "the server has no usable find" }
        return "the sweep did not start"
    }

    private static func note(tier: Tier, watchMode: WatchMode, capabilities: ServerCapabilities) -> String? {
        guard tier != .helper else { return nil }
        switch watchMode {
        case .poll:
            return "watchMode is set to poll"
        case .sweep:
            return tier == .sweep
                ? "watchMode is set to sweep"
                : "watchMode is set to sweep, but \(sweepBlocked(capabilities))"
        case .helper:
            return "watchMode is set to helper, but \(helperBlocked(capabilities))"
        case .auto:
            let helper = helperBlocked(capabilities)
            guard tier == .poll else { return helper }
            // An account with no shell blocks both tiers for the same reason, and saying
            // it twice would read as two separate problems.
            let sweep = sweepBlocked(capabilities)
            return helper == sweep ? helper : "\(helper); \(sweep)"
        }
    }

    // MARK: Runtime failures

    /// A tier that failed while running: the helper's stream died or never said `ready`,
    /// the deployment found the server unable to run it, the account has no shell.
    ///
    /// A **permanent** failure lasts for the rest of the connection, and at most
    /// `permanentRecheckSeconds` on a connection that stays up: re-trying it every minute
    /// would turn one broken server into a stream of failures instead of a working tier
    /// below, while holding it for the session would keep a server that was fixed - or a
    /// verdict that was wrong - from ever being looked at again. A **transient** one - an
    /// outage, a channel that went with the connection, a helper that did not answer this
    /// time - holds the tier down for a bounded backoff (2 s, doubling to 60 s) and is then
    /// tried again, because the alternative is a mount left at the sweep tier by a network
    /// blink until something restarts the agent.
    ///
    /// Returns true when the tier changed; at `poll` there is nowhere to go, so the
    /// reason is kept for `status` and the answer is false.
    @discardableResult
    public mutating func recordRuntimeFailure(
        reason: String, permanence: Permanence = .permanent, now: Double
    ) -> Bool {
        guard let lower = tier.oneLower else {
            note = "poll failed: \(reason)"
            return false
        }
        let from = tier
        downgrades.append(
            Downgrade(from: from, to: lower, reason: reason, at: now, permanence: permanence))
        if downgrades.count > Self.historyLimit {
            downgrades.removeFirst(downgrades.count - Self.historyLimit)
        }
        switch permanence {
        case .permanent:
            permanentCeiling = min(permanentCeiling, lower)
            permanentSince = now
            transientCeiling = nil
            transientReason = nil
        case .transient:
            transientFailures += 1
            transientCeiling = min(transientCeiling ?? .helper, lower)
            transientUntil = now + retryBackoffSeconds
            transientReason = reason
        }
        recompute(now: now)
        note = permanence == .permanent
            ? "\(from.rawValue) failed: \(reason)"
            : "\(from.rawValue) failed: \(reason); retrying in \(Int(retryBackoffSeconds.rounded())) s"
        return tier < from
    }

    /// The hold the failure just recorded will run for.
    public var retryBackoffSeconds: Double {
        let exponent = max(0, transientFailures - 1)
        return min(Self.firstRetrySeconds * pow(2, Double(exponent)), Self.retryCapSeconds)
    }

    /// True while a transient failure is holding the tier below what the server can do.
    public var isHeldByTransientFailure: Bool { transientCeiling != nil }

    /// When the hold expires, for `sshdrive status`.
    public var transientHoldExpiresAt: Double? { transientCeiling == nil ? nil : transientUntil }

    /// When a permanent failure is decided again on this connection, or nil when none is
    /// binding.
    public var permanentHoldExpiresAt: Double? {
        permanentCeiling == .helper ? nil : permanentSince + Self.permanentRecheckSeconds
    }

    /// The earliest moment either kind of hold expires: when the detector has to be awake
    /// to climb back.
    public var nextClimbBackAt: Double? {
        [transientHoldExpiresAt, permanentHoldExpiresAt].compactMap { $0 }.min()
    }

    /// Lets the tier climb back once a hold has expired: a transient one after its
    /// backoff, a permanent one after `permanentRecheckSeconds`. Called at the top of every
    /// detector cycle. Returns true when the tier rose, which is the detector's cue to
    /// start the stream the new tier names.
    @discardableResult
    public mutating func climbBack(now: Double) -> Bool {
        let transientExpired = transientCeiling != nil && now >= transientUntil
        let permanentExpired = permanentHoldExpiresAt.map { now >= $0 } ?? false
        guard transientExpired || permanentExpired else { return false }
        let from = tier
        if transientExpired {
            transientCeiling = nil
            transientReason = nil
        }
        if permanentExpired { liftPermanentCeiling(now: now) }
        recompute(now: now)
        return tier > from
    }

    /// A connection came up, and both kinds of hold end here. The outage case: the stream
    /// died with the link, the link is back, so the transient hold is dropped and the
    /// backoff starts again from the bottom. A permanent failure was a verdict about the
    /// connection it was made on, and this connection's probe and deployment make their
    /// own. A failure on this connection pays its hold again, and connections themselves
    /// are bounded by the breaker's backoff (docs/design/offline.md), so nothing here can
    /// spin.
    @discardableResult
    public mutating func noteConnected(now: Double) -> Bool {
        transientFailures = 0
        let permanent = permanentCeiling != .helper
        guard transientCeiling != nil || permanent else { return false }
        let from = tier
        transientCeiling = nil
        transientReason = nil
        transientUntil = 0
        if permanent { liftPermanentCeiling(now: now) }
        recompute(now: now)
        return tier > from
    }

    private mutating func liftPermanentCeiling(now: Double) {
        permanentCeiling = .helper
        permanentSince = 0
        for index in downgrades.indices
        where downgrades[index].permanence == .permanent && downgrades[index].liftedAt == nil {
            downgrades[index].liftedAt = now
        }
        // The note named the failure; with the ceiling gone, `recompute` writes the one the
        // capabilities give, so it is cleared rather than left to describe a verdict that
        // no longer binds.
        note = nil
    }

    /// The current tier has been running for `stabilitySeconds`, so the failures that
    /// preceded it are forgotten and the next one starts at the 2 s hold again.
    public mutating func noteTierHealthy(now: Double) {
        transientFailures = 0
    }

    /// The tier the ladder can serve right now: what the capabilities allow, held down by
    /// whatever ceiling is binding.
    private mutating func recompute(now: Double) {
        let selected = ChangeDetectionLadder.select(watchMode: watchMode, capabilities: capabilities)
        var ceiling = permanentCeiling
        if let transientCeiling { ceiling = min(ceiling, transientCeiling) }
        if selected <= ceiling {
            tier = selected
            note = ChangeDetectionLadder.note(
                tier: selected, watchMode: watchMode, capabilities: capabilities)
        } else {
            tier = ceiling
            if let transientReason {
                note = "\(selected.rawValue) failed: \(transientReason); retrying in "
                    + "\(Int(max(0, transientUntil - now).rounded(.up))) s"
            } else if note == nil {
                note = ChangeDetectionLadder.note(
                    tier: ceiling, watchMode: watchMode, capabilities: capabilities)
            }
        }
    }

    // MARK: A new probe

    /// Re-evaluated when a reconnect brings a different server, or when the user changes
    /// `watchMode`. The ladder is recomputed from the new capabilities, but never above
    /// what a **permanent** runtime failure still binding already ruled out, nor above a
    /// transient hold that has not expired yet.
    public mutating func applyCapabilities(_ capabilities: ServerCapabilities, watchMode: WatchMode, now: Double) {
        self.capabilities = capabilities
        self.watchMode = watchMode
        recompute(now: now)
    }

    // MARK: Reporting

    /// True when the sweep runs `-mmin` rather than `-cmin` and therefore misses `chmod`,
    /// `chown` and preserved-mtime writes (`rsync -t`, `cp -p`, `touch -r`).
    ///
    /// That fallback is the ordinary path for every busybox server, a NAS included, rather
    /// than a legacy fringe, so the note is a normal `status` line and not an alarm.
    ///
    /// It is gated on the tier because a location at `poll` runs no sweep at all, and a
    /// note about a sweep's blind spot on a location that has no sweep would be noise. The
    /// helper tier is not excluded: a sweep still runs there every 30 minutes as insurance,
    /// and that sweep has the same blind spot.
    public var sweepUsesMmin: Bool { tier != .poll && !capabilities.takesCmin }

    /// One line for `sshdrive status`.
    public var description: String {
        guard let note else { return tier.rawValue }
        return "\(tier.rawValue) (\(note))"
    }
}
