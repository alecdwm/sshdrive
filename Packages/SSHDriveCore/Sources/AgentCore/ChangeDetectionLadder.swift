import Config
import Foundation

/// Which change-detection tier a location runs at, and why it is not higher
/// (DESIGN.md section 6.4, reported by section 8.1).
///
/// Section 6.4: "`watchMode: auto` (the default) tries the tiers from the top: helper
/// first, then sweep, then poll, settling on the first one that starts successfully ... A
/// tier that fails at runtime (the helper's stream dies with a non-network error, `find`
/// is missing) drops the location one tier down for the rest of the session and records
/// why, which `sshdrive status` shows. Setting `watchMode` to a specific tier disables the
/// fallback ladder except to `poll`, which always works."
///
/// The tier is a decision, not a connection, so this is a value with the clock passed in.
/// Nothing on the File Provider side knows which tier is active; the version format of
/// section 5.3 is the same at every tier so a tier change is invisible too.
public struct ChangeDetectionLadder: Sendable, Equatable {

    /// The three tiers of section 6.4, ordered worst to best. `poll` is the floor: it
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

    /// What the probe measured about this server (section 8.1).
    public struct ServerCapabilities: Sendable, Equatable {
        /// The account has shell (exec) access at all. False for a chrooted
        /// `internal-sftp` or a `ForceCommand internal-sftp` account, which is the one
        /// case that pins a location to tier 0.
        public var hasExecChannel: Bool
        public var hasFind: Bool
        /// False for every busybox build measured, which answers
        /// `find: unrecognized: -cmin` (section 6.4).
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
        /// upload failed: …` - rather than a category (section 8.1).
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

        public init(from: Tier, to: Tier, reason: String, at: Double) {
            self.from = from
            self.to = to
            self.reason = reason
            self.at = at
        }
    }

    public private(set) var tier: Tier
    public private(set) var downgrades: [Downgrade]
    /// Why the tier is not `helper`, for section 8.1's `note:` line. Nil at the best tier.
    public private(set) var note: String?

    /// What the last probe said, kept so a `status` line can explain the tier without the
    /// caller holding the capabilities separately.
    public private(set) var capabilities: ServerCapabilities
    public private(set) var watchMode: WatchMode

    /// The best tier a runtime failure has left available. Section 6.4's downgrade lasts
    /// "for the rest of the session", so a later probe may lower the tier but never raise
    /// it back over a failure this session already saw.
    private var sessionCeiling: Tier

    public init(watchMode: WatchMode, capabilities: ServerCapabilities, now: Double) {
        self.watchMode = watchMode
        self.capabilities = capabilities
        self.downgrades = []
        self.sessionCeiling = .helper
        let selected = ChangeDetectionLadder.select(watchMode: watchMode, capabilities: capabilities)
        self.tier = selected
        self.note = ChangeDetectionLadder.note(tier: selected, watchMode: watchMode, capabilities: capabilities)
    }

    // MARK: Selection

    /// Section 6.4's ladder. `auto` walks down from the top and takes the first tier that
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

    /// A tier that failed while running: `find` is missing after all, the helper's stream
    /// died with something that is not a network error, the shell's output was unusable.
    ///
    /// The drop lasts for the rest of the session, because a tier that failed once on this
    /// server will fail again on the next cycle and re-trying it every minute would turn
    /// one broken server into a stream of failures instead of a working `poll`. Returns
    /// true when the tier actually moved; at `poll` there is nowhere to go, so the reason
    /// is kept for `status` and the answer is false.
    @discardableResult
    public mutating func recordRuntimeFailure(reason: String, now: Double) -> Bool {
        guard let lower = tier.oneLower else {
            note = "poll failed: \(reason)"
            return false
        }
        let from = tier
        downgrades.append(Downgrade(from: from, to: lower, reason: reason, at: now))
        tier = lower
        sessionCeiling = lower
        note = "\(from.rawValue) failed: \(reason)"
        return true
    }

    // MARK: A new probe

    /// Re-evaluated when a reconnect brings a different server, or when the user changes
    /// `watchMode`. The ladder is recomputed from the new capabilities, but never above
    /// what a runtime failure this session already ruled out: the drop of section 6.4 is
    /// "for the rest of the session", and a reconnect is not a new session.
    public mutating func applyCapabilities(_ capabilities: ServerCapabilities, watchMode: WatchMode, now: Double) {
        self.capabilities = capabilities
        self.watchMode = watchMode
        let selected = ChangeDetectionLadder.select(watchMode: watchMode, capabilities: capabilities)
        if selected <= sessionCeiling {
            tier = selected
            note = ChangeDetectionLadder.note(tier: selected, watchMode: watchMode, capabilities: capabilities)
        } else {
            // The ceiling is what is binding, so the failure note still says why and is
            // left alone.
            tier = sessionCeiling
            if note == nil {
                note = ChangeDetectionLadder.note(
                    tier: sessionCeiling, watchMode: watchMode, capabilities: capabilities)
            }
        }
    }

    // MARK: Reporting

    /// True when the sweep runs `-mmin` rather than `-cmin` and therefore misses `chmod`,
    /// `chown` and preserved-mtime writes (`rsync -t`, `cp -p`, `touch -r`).
    ///
    /// Section 6.4: that fallback "is the ordinary path for every busybox server, a NAS
    /// included, rather than a legacy fringe, so that note is a normal `status` line and
    /// not an alarm."
    ///
    /// It is gated on the tier because a location at `poll` runs no sweep at all, and a
    /// note about a sweep's blind spot on a location that has no sweep would be noise. The
    /// helper tier is not excluded: section 6.4 still runs a sweep there every 30 minutes
    /// as insurance, and that sweep has the same blind spot.
    public var sweepUsesMmin: Bool { tier != .poll && !capabilities.takesCmin }

    /// One line for `sshdrive status`.
    public var description: String {
        guard let note else { return tier.rawValue }
        return "\(tier.rawValue) (\(note))"
    }
}
