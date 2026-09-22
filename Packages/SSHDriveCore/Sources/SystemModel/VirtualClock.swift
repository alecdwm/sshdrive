import Foundation
import ProviderCore

/// The driven clock every part of `SystemModel` reads. There is no real sleeping anywhere
/// in the suite (docs/design/testing.md): `advance` moves time,
/// releases whatever the simulated schedulers owe, and returns when everything queued has
/// run.
public final class VirtualClock: ProviderClock {
    private var seconds: Double
    private var pending: [(at: Double, body: () -> Void)] = []
    private var nextOrder = 0
    private var order: [Int] = []

    public init(startingAt seconds: Double = 1_800_000_000) {
        self.seconds = seconds
    }

    public func now() -> Double { seconds }

    /// Runs `body` once the clock has reached `at`. Work already due runs on the next
    /// `advance`, not inline, so a caller can queue several things and see them in
    /// order.
    public func schedule(after delay: Double, _ body: @escaping () -> Void) {
        pending.append((at: seconds + max(delay, 0), body: body))
        order.append(nextOrder)
        nextOrder += 1
    }

    /// Moves the clock forward, running everything that comes due in time order, and
    /// leaves it exactly `duration` later however much work ran.
    public func advance(_ duration: Double) {
        let target = seconds + duration
        while true {
            let due = pending.enumerated().filter { $0.element.at <= target }
            guard let first = due.min(by: { lhs, rhs in
                lhs.element.at == rhs.element.at
                    ? order[lhs.offset] < order[rhs.offset] : lhs.element.at < rhs.element.at
            }) else { break }
            seconds = max(seconds, first.element.at)
            let body = first.element.body
            pending.remove(at: first.offset)
            order.remove(at: first.offset)
            body()
        }
        seconds = target
    }

    /// Runs everything already due without moving the clock.
    public func drain() { advance(0) }

    /// Moves to the next thing that is owed and runs it, whenever that is. It is how the
    /// model waits for work it scheduled - a held `fetchContents`, a retry - without a
    /// scenario having to know the interval.
    @discardableResult
    public func runNextDue() -> Bool {
        guard let next = pending.map(\.at).min() else { return false }
        advance(max(next - seconds, 0))
        return true
    }

    public var scheduledCount: Int { pending.count }
}
