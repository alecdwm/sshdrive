import Foundation

/// fileproviderd's throttle on a change enumeration that keeps failing (`MQ-005`).
///
/// This is the mechanism the 0.1.2 field failure ran into, and the reason `A2` exists.
/// Two points were measured on the same backoff, both in `results.md` 2026-09-08:
///
/// - the field failure: **27 consecutive errors, next retry 47 minutes** (`count:27`,
///   `next:'28min45s'` with `last:'-18min9s'`), `error generation: 14`;
/// - the VM reproduction: **7 consecutive errors, next retry 1 min 34 s** (`count:7`,
///   `next:'1min34s'`), `error generation: 7`.
///
/// A geometric backoff of 30 s x 1.18^n passes through both (95 s at 7, 48.7 min at 27), so
/// that is the schedule the model applies; the value the catalogue holds at n = 27 is the
/// measured 47 minutes and the model clamps to it, so a scenario asserting the field number
/// sees exactly the field number rather than a curve fit.
///
/// Nothing here is our code: it is what the system does to us. The whole point of the model
/// is that a provider which answers `.serverUnreachable` for a reader it could merely not
/// use ends up here, and one that falls back to the agent never does.
public struct ErrorThrottle: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// No error since the last success or the last `signalErrorResolved`.
        case none
        /// The stream is backing off; nothing server-side reaches Finder until it fires.
        case backingOff(nextRetryIn: Double)
    }

    public private(set) var consecutiveErrors = 0
    /// fileproviderd's own counter, printed by `fileproviderctl dump` as
    /// `error generation:`. It rises with the errors and does not fall on a success; only
    /// the retry schedule is reset.
    public private(set) var errorGeneration = 0
    public private(set) var nextRetryIn: Double = 0

    /// The threshold the catalogue names, so the model never carries the number twice.
    public let threshold: Int
    public let ceiling: Double

    public init(threshold: Int, ceiling: Double) {
        self.threshold = threshold
        self.ceiling = ceiling
    }

    /// The measured curve: 30 s x 1.18^n, clamped at the threshold to the measured value.
    public func retryInterval(afterErrors count: Int) -> Double {
        guard count > 0 else { return 0 }
        if count >= threshold { return ceiling }
        return min(ceiling, 30 * pow(1.18, Double(count)))
    }

    public mutating func recordError() {
        consecutiveErrors += 1
        errorGeneration += 1
        nextRetryIn = retryInterval(afterErrors: consecutiveErrors)
    }

    /// A change enumeration that answered normally. It stops the count climbing, but it
    /// does **not** lift a backoff already in place: only `signalErrorResolved` does
    /// (`MQ-037`), which is why the extension makes that call on its first success after a
    /// failure.
    public mutating func recordSuccess() {
        consecutiveErrors = 0
    }

    /// `signalErrorResolved(.serverUnreachable)`. The one thing that clears the backoff
    /// (`MQ-037`).
    public mutating func clear() {
        consecutiveErrors = 0
        nextRetryIn = 0
    }

    public var state: State {
        nextRetryIn > 0 ? .backingOff(nextRetryIn: nextRetryIn) : .none
    }

    /// True once the stream is far enough into the backoff that a server-side change is
    /// stalled for tens of minutes, which is the symptom that shipped.
    public var isAtMeasuredCeiling: Bool { nextRetryIn >= ceiling }
}
