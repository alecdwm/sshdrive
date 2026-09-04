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
}
