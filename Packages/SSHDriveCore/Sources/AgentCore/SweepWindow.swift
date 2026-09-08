import Foundation

/// How far back one tier 1 sweep looks (DESIGN.md section 6.4).
///
/// The whole of this type exists to keep one rule: the window is computed from the
/// **server's** clock and never the Mac's. Section 6.4: "every sweep script prints
/// `date +%s` first, the agent stores it once the sweep's results have been applied to the
/// index, never before, and the next sweep's `N` is the minutes between the stored value
/// and the new one, rounded up, plus one minute of overlap. Measured on the Mac's clock, a
/// server running a few minutes behind would silently miss every change until the
/// 30-minute insurance sweep."
public struct SweepWindow: Equatable, Sendable {

    /// `N` for `-cmin -N`. Nil is unbounded: the `-cmin`/`-mmin` test is dropped entirely
    /// and every file under the roots is reported.
    public var minutes: Int?

    /// The stored stamp was in the future, so either the server's clock or ours went
    /// backwards. The window is clamped rather than negative, and this says so, because
    /// the honest thing for `status` to print is that the sweep is running on a clock that
    /// moved and not that everything is fine.
    public var clockWentBackwards: Bool

    public init(minutes: Int?, clockWentBackwards: Bool = false) {
        self.minutes = minutes
        self.clockWentBackwards = clockWentBackwards
    }

    /// The unbounded window: a fresh or rebuilt index has no stamp to open back to, so the
    /// sweep reports everything under the roots. That is section 6.4's full sweep "with its
    /// window opened back to the last server timestamp the index recorded, unbounded when
    /// there is none".
    public static let unbounded = SweepWindow(minutes: nil)

    /// Section 6.4's arithmetic.
    ///
    /// `full` is taken and recorded by the caller rather than changing the answer: a full
    /// sweep differs in *which* stamp is passed here (the last one the index recorded
    /// rather than the last applied sweep's) and in the tier 0 rotation being suspended,
    /// not in how minutes are counted. It is a parameter so the call site reads as what
    /// section 6.4 describes, and so a later rule that does depend on it has somewhere to
    /// go.
    ///
    /// Duplicates are harmless - "the result is diffed anyway" - so the extra minute of
    /// overlap costs nothing and covers the rounding at both ends.
    public static func compute(lastAppliedServerTime: Int64?, serverNow: Int64, full: Bool) -> SweepWindow {
        guard let stored = lastAppliedServerTime else { return .unbounded }
        let elapsed = serverNow - stored
        guard elapsed >= 0 else {
            // Never a negative or zero `N`: `-cmin -0` matches only what changed in this
            // very minute, so a clock that jumped backwards would turn the sweep into a
            // no-op for as long as the jump lasted.
            return SweepWindow(minutes: 1, clockWentBackwards: true)
        }
        let rounded = Int((elapsed + 59) / 60)
        return SweepWindow(minutes: max(1, rounded + 1))
    }

    /// One cycle's window, as the agent computes it: **elapsed time on our own clock,
    /// applied to the server's own stamp**.
    ///
    /// This is the rule `H4` is about, and it is the whole reason `compute` takes two
    /// server timestamps rather than one server timestamp and a `Date`. The stored stamp
    /// is the server's `date +%s` from the last sweep whose results were applied; the only
    /// thing our clock is used for is *how long ago that was*, which both clocks agree on
    /// however far apart they are set. `serverNow` is therefore reconstructed as
    /// `stored + elapsed` rather than read off either clock's absolute value, and
    ///
    ///     N = ceil((now - takenAt) / 60) + 1
    ///
    /// comes out identical on a server five minutes behind, five minutes ahead, and in
    /// step with us. Measuring a server timestamp against our own wall clock instead folds
    /// the entire skew into the window: a server running ahead is swept with a window of
    /// nothing until the 30-minute insurance pass, and one running behind is swept with a
    /// window twice as wide as it needs (section 6.4).
    ///
    /// `clockSkewSeconds` is `sshdrive debug`'s deliberate offset of the stored stamp and
    /// is zero everywhere else; it is applied to the stamp, never to the elapsed time.
    ///
    /// Confidence: the arithmetic is DESIGN.md section 6.4's, and the ordinary path is
    /// measured (milestone 6 ran real sweeps against `deb` and `alp`). What has never been
    /// measured against a real server is the skew itself - Docker has no time namespace
    /// (`SQ-054`) - so a clock-skewed server is modelled and will only ever be modelled.
    public static func forCycle(
        lastAppliedServerTime: Int64?,
        takenAt: TimeInterval?,
        now: TimeInterval,
        clockSkewSeconds: Int64 = 0,
        full: Bool
    ) -> SweepWindow {
        guard let stored = lastAppliedServerTime else { return .unbounded }
        // Never negative: our own clock stepping backwards between two cycles must not
        // widen the window into the future, which `compute` would read as a clock that
        // went backwards on the *server*.
        let elapsed = max(0, now - (takenAt ?? now))
        let serverNow = stored + Int64(elapsed.rounded(.up))
        return compute(
            lastAppliedServerTime: stored + clockSkewSeconds, serverNow: serverNow, full: full)
    }
}
