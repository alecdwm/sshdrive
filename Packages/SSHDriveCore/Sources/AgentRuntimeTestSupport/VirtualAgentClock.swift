import AgentRuntime
import Foundation

/// A driven clock for the agent's seams: there is no real sleeping anywhere in the suite
/// (docs/design/testing.md).
///
/// `now()` is wall clock, `uptime()` is monotonic, and both move only when a test calls
/// `advance`. A `sleep` parks until the clock has passed its deadline, so the eviction
/// loop's doubling backoff, the breaker's reconnect backoff and the ladder's climb-back
/// hold are all exercised at their real numbers and none of them costs a second.
///
/// A sleep whose task is cancelled returns at once and leaves nothing parked, as
/// `SystemAgentClock`'s `try? await Task.sleep` does: `ChangeDetector.nudge()` and
/// `stop()` end the detector's sleep that way.
///
/// `autoAdvance` is the escape hatch for a scenario that cares about the *order* of
/// sleeps and not about their length: every sleep moves the clock to its own deadline and
/// returns. It is off by default, because a retry loop under it would run at the speed of
/// the CPU.
public final class VirtualAgentClock: AgentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Double
    private var monotonic: Double
    private var waiters: [(id: Int, deadline: Double, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0
    /// Every sleep asked for, in order, for a test that wants to assert the schedule
    /// rather than live through it.
    public private(set) var requestedSleeps: [Double] = []
    private var auto: Bool
    private var _activity = 0

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
        _activity += 1
        let deadline = monotonic + seconds
        let automatic = auto
        nextID += 1
        let id = nextID
        lock.unlock()
        if automatic {
            advanceNow(seconds)
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                // A task cancelled before it got here has already run its handler, which
                // found nothing to resume; checking under the lock closes that window.
                if monotonic >= deadline || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append((id, deadline, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let waiter = waiters.remove(at: index)
            _activity += 1
            lock.unlock()
            waiter.continuation.resume()
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
        _activity += due.count
        lock.unlock()
        for waiter in due { waiter.continuation.resume() }
    }

    /// `advance`, then a handful of scheduler turns, which is what "and returns when
    /// everything queued has run" means for a suite with no real time in it.
    public func advanceAndSettle(_ seconds: Double, settleTurns: Int = 20) async {
        advanceNow(seconds)
        for _ in 0 ..< settleTurns { await Task.yield() }
    }

    /// Moves the wall clock alone, as an NTP correction or a time-zone-agnostic jump after
    /// a wake does. The monotonic clock and every parked sleeper are untouched.
    public func jumpWallClock(by seconds: Double) {
        lock.lock(); wall += seconds; _activity += 1; lock.unlock()
    }

    /// Bumped by every sleep asked for, every sleeper released and every cancellation, so
    /// a harness can tell whether anything has been scheduled since it last looked.
    public var activity: Int {
        lock.lock(); defer { lock.unlock() }
        return _activity
    }

    /// How many sleepers are parked. A scenario asserts on this when what it is checking
    /// is that something *is* waiting rather than that it finished.
    public var sleeperCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// The earliest parked sleeper's deadline, on the monotonic clock (`uptime()`), or nil
    /// when nothing is parked. A harness loops "advance to the next thing that is due"
    /// on this.
    public var nextDeadline: Double? {
        lock.lock(); defer { lock.unlock() }
        return waiters.map(\.deadline).min()
    }

    /// Advances exactly to `nextDeadline` and settles. Returns false, and moves nothing,
    /// when nothing is parked.
    @discardableResult
    public func advanceToNextDeadline(settleTurns: Int = 20) async -> Bool {
        let (target, current) = lock.withLock { (waiters.map(\.deadline).min(), monotonic) }
        guard let target else { return false }
        await advanceAndSettle(max(0, target - current), settleTurns: settleTurns)
        return true
    }
}
