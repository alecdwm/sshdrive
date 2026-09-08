import AgentRuntime
import Foundation

/// A driven clock for the agent's seams (docs/testing-architecture.md section 3.1:
/// "there is no real sleeping anywhere in the suite").
///
/// `now()` is wall clock, `uptime()` is monotonic, and both move only when a test calls
/// `advance`. A `sleep` parks until the clock has passed its deadline, so the eviction
/// loop's doubling backoff, the breaker's reconnect backoff and the ladder's climb-back
/// hold are all exercised at their real numbers and none of them costs a second.
///
/// `autoAdvance` is the escape hatch for a scenario that cares about the *order* of
/// sleeps and not about their length: every sleep moves the clock to its own deadline and
/// returns. It is off by default, because a retry loop under it would run at the speed of
/// the CPU.
public final class VirtualAgentClock: AgentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Double
    private var monotonic: Double
    private var waiters: [(deadline: Double, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0
    /// Every sleep asked for, in order, for a test that wants to assert the schedule
    /// rather than live through it.
    public private(set) var requestedSleeps: [Double] = []
    private var auto: Bool

    public init(
        startingAt wall: Double = 1_757_000_000, uptime: Double = 1000, autoAdvance: Bool = false
    ) {
        self.wall = wall
        self.monotonic = uptime
        self.auto = autoAdvance
    }

    public func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return wall
    }

    public func uptime() -> Double {
        lock.lock(); defer { lock.unlock() }
        return monotonic
    }

    public var autoAdvance: Bool {
        get { lock.lock(); defer { lock.unlock() }; return auto }
        set { lock.lock(); auto = newValue; lock.unlock() }
    }

    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        lock.lock()
        requestedSleeps.append(seconds)
        let deadline = monotonic + seconds
        let automatic = auto
        lock.unlock()
        if automatic {
            advanceNow(seconds)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if monotonic >= deadline {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((deadline, continuation))
            nextID += 1
            lock.unlock()
        }
    }

    /// Moves both clocks and releases whatever the schedulers owe. Returns after yielding
    /// so the tasks it woke have had a turn.
    public func advance(_ seconds: Double) { advanceNow(seconds) }

    private func advanceNow(_ seconds: Double) {
        lock.lock()
        wall += seconds
        monotonic += seconds
        let due = waiters.filter { $0.deadline <= monotonic }
        waiters.removeAll { $0.deadline <= monotonic }
        lock.unlock()
        for waiter in due { waiter.continuation.resume() }
    }

    /// `advance`, then a handful of scheduler turns, which is what "and returns when
    /// everything queued has run" means for a suite with no real time in it.
    public func advanceAndSettle(_ seconds: Double, settleTurns: Int = 20) async {
        advanceNow(seconds)
        for _ in 0 ..< settleTurns { await Task.yield() }
    }

    /// How many sleepers are parked. A scenario asserts on this when what it is checking
    /// is that something *is* waiting rather than that it finished.
    public var sleeperCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }
}
