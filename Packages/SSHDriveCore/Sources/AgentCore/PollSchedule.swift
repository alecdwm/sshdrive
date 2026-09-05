import Foundation

/// DESIGN.md section 6.4's "Schedule for tiers 0 and 1".
///
/// "Every 60 s while the user has touched the domain in the last 10 minutes (a File
/// Provider request for it that was not a system request, or a CLI command naming it),
/// every 10 min otherwise, and immediately on network-up. The helper replaces the schedule
/// with events; a sweep still runs every 30 min as insurance against missed events."
///
/// What counts as a touch is the caller's classification - only it can see whether an
/// `NSFileProviderRequest` was a system request - and this type only ever takes the
/// timestamp of the last one.
public struct PollSchedule: Sendable, Equatable {

    // Every rule here is a static answer about a schedule, so there is nothing to hold.
    // It stays a `struct` rather than an `enum` because that is what the agent's timer
    // wiring names.
    private init() {}

    /// The cycle while the domain is being used.
    public static let activeInterval: TimeInterval = 60
    /// The cycle while it is not.
    public static let idleInterval: TimeInterval = 600
    /// How long a touch keeps the domain active.
    public static let touchWindow: TimeInterval = 600
    /// The insurance full sweep, and the same 30 minutes at tiers 0 and 1.
    public static let insuranceInterval: TimeInterval = 1800

    /// True while the last touch is within the 10-minute window. A domain that has never
    /// been touched this session is idle: nothing is looking at it, and the insurance pass
    /// still covers it.
    ///
    /// The boundary is inclusive, so a touch exactly 10 minutes old still counts. The
    /// alternative buys nothing and makes the rule depend on which side of a float
    /// comparison a timer landed.
    public static func isActive(lastTouch: Double?, now: Double) -> Bool {
        guard let lastTouch else { return false }
        return now - lastTouch <= touchWindow
    }

    /// The largest multiple of its own duration a cycle may take of the interval before
    /// the schedule backs off: a cycle that runs for 57 s of a 60 s interval leaves the
    /// server sweeping almost continuously and the exec channel never free.
    public static let cycleShare: Double = 3
    /// The slowest the backoff may make it. A location still gets the insurance full
    /// sweep at its own cadence, so nothing goes unwatched for longer than that.
    public static let maximumInterval: TimeInterval = insuranceInterval

    /// The cycle length, backed off when the last one consumed most of it.
    ///
    /// Measured on a real 26.6.2 install (2026-09-05): a home directory whose sweep took
    /// 56.8 s against a 60 s interval, so the location swept without pause. The rule is
    /// "a cycle may have a third of its own interval", capped, and `sshdrive status` says
    /// when it is in force (section 6.4).
    public static func interval(
        lastTouch: Double?, now: Double, lastCycleSeconds: Double = 0
    ) -> TimeInterval {
        let base = isActive(lastTouch: lastTouch, now: now) ? activeInterval : idleInterval
        guard lastCycleSeconds > 0 else { return base }
        return min(max(base, lastCycleSeconds * cycleShare), maximumInterval)
    }

    /// The sentence `status` prints when the backoff above is in force, or nil when the
    /// location is on its ordinary cadence.
    public static func backoffNote(
        lastTouch: Double?, now: Double, lastCycleSeconds: Double
    ) -> String? {
        let base = isActive(lastTouch: lastTouch, now: now) ? activeInterval : idleInterval
        let backed = interval(lastTouch: lastTouch, now: now, lastCycleSeconds: lastCycleSeconds)
        guard backed > base else { return nil }
        return String(
            format: "the last cycle took %.1fs, so the interval is %.0fs rather than %.0fs",
            lastCycleSeconds, backed, base)
    }

    /// The next cycle's due time, measured from the last cycle rather than from now, so a
    /// cycle that ran long does not push the schedule out by its own duration. A caller
    /// that is already late gets a time in the past, which means fire now.
    public static func nextFire(
        lastCycle: Double, lastTouch: Double?, now: Double, lastCycleSeconds: Double = 0
    ) -> Double {
        lastCycle
            + interval(lastTouch: lastTouch, now: now, lastCycleSeconds: lastCycleSeconds)
    }

    /// True when the 30-minute insurance full sweep is due. It runs whatever the tier: at
    /// tier 2 it is what catches the changes no facility reported - a directory that is
    /// itself an NFS or FUSE mount on the server produces no events at all (section 6.4).
    public static func insuranceDue(lastFullSweep: Double, now: Double) -> Bool {
        now - lastFullSweep >= insuranceInterval
    }
}
