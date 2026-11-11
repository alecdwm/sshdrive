import XCTest
import SSHProcess
@testable import AgentCore

/// The breaker (docs/design/offline.md), rule by rule. The clock is an argument and the
/// jitter is injected, so every number here is exact and nothing sleeps.
final class CircuitBreakerTests: XCTestCase {

    private func breaker() -> CircuitBreaker { CircuitBreaker(jitter: { $0 }) }

    // MARK: Rule 1 - no path at all

    func testNoNetworkPathFailsFastWithoutTouchingAnything() {
        var breaker = self.breaker()
        breaker.setNetworkPath(false)
        XCTAssertEqual(breaker.admit(now: 0), .failFast(.noNetworkPath))
        // And it stays that way; nothing about the path opens a connection.
        XCTAssertEqual(breaker.admit(now: 1000), .failFast(.noNetworkPath))
    }

    func testAPathComingBackResetsTheBackoff() {
        var breaker = self.breaker()
        XCTAssertEqual(breaker.admit(now: 0), .connect)
        breaker.attemptFailed(.transient, now: 0)
        XCTAssertEqual(breaker.admit(now: 1), .failFast(.backingOff(remaining: 1)))
        breaker.setNetworkPath(false)
        breaker.setNetworkPath(true)
        // A path change or wake from sleep resets the breaker
        // (docs/design/offline.md), so the next call connects rather than waiting out
        // the 2 s.
        XCTAssertEqual(breaker.admit(now: 1), .connect)
        XCTAssertEqual(breaker.consecutiveFailures, 0)
    }

    // MARK: Rule 2 - the backoff

    func testBackoffDoublesFromTwoSecondsAndCapsAtSixty() {
        var breaker = self.breaker()
        var expected: [TimeInterval] = []
        var now: TimeInterval = 0
        for _ in 0..<10 {
            XCTAssertEqual(breaker.admit(now: now), .connect)
            breaker.attemptFailed(.transient, now: now)
            guard case let .backingOff(until) = breaker.state else {
                return XCTFail("expected a backoff")
            }
            expected.append(until - now)
            now = until
        }
        XCTAssertEqual(expected, [2, 4, 8, 16, 32, 60, 60, 60, 60, 60])
    }

    func testTheKeyAgentCapIsFiveMinutes() {
        var breaker = self.breaker()
        var now: TimeInterval = 0
        var last: TimeInterval = 0
        for _ in 0..<12 {
            XCTAssertEqual(breaker.admit(now: now), .connect)
            // A locked key agent stays locked for hours, so the cap is raised from 60 s
            // to 5 minutes for this one classification (docs/design/ssh.md).
            breaker.attemptFailed(.keyAgentNotReady, now: now)
            guard case let .backingOff(until) = breaker.state else {
                return XCTFail("expected a backoff")
            }
            last = until - now
            now = until
        }
        XCTAssertEqual(last, 300)
    }

    func testAnOpenBreakerFailsFastAndThenLetsOneProbeOut() {
        var breaker = self.breaker()
        XCTAssertEqual(breaker.admit(now: 0), .connect)
        breaker.attemptFailed(.transient, now: 0)
        XCTAssertEqual(breaker.admit(now: 0.5), .failFast(.backingOff(remaining: 1.5)))
        // Binary floating point: 2 - 1.9 is not exactly 0.1, so the remaining time is
        // checked with a tolerance rather than for equality.
        guard case let .failFast(.backingOff(remaining)) = breaker.admit(now: 1.9) else {
            return XCTFail("expected a fail-fast")
        }
        XCTAssertEqual(remaining, 0.1, accuracy: 0.0001)
        // Half open, at the boundary.
        XCTAssertEqual(breaker.admit(now: 2), .connect)
        // And that probe is the only one: everything else waits on it.
        guard case .wait = breaker.admit(now: 2) else { return XCTFail("expected a wait") }
    }

    func testJitterIsAppliedAndStaysWithinTwentyPercent() {
        for _ in 0..<200 {
            var breaker = CircuitBreaker()
            _ = breaker.admit(now: 0)
            breaker.attemptFailed(.transient, now: 0)
            guard case let .backingOff(until) = breaker.state else {
                return XCTFail("expected a backoff")
            }
            XCTAssertGreaterThanOrEqual(until, 1.6)
            XCTAssertLessThanOrEqual(until, 2.4)
        }
    }

    // MARK: Rule 3 - the bounded wait

    func testCallsWaitForAnAttemptBoundedByItsOwnRemainingDeadline() {
        var breaker = self.breaker()
        XCTAssertEqual(breaker.admit(now: 100), .connect)
        // 60 s from the spawn, not 60 s from now: a call that arrives 50 s in waits 10.
        XCTAssertEqual(breaker.admit(now: 110), .wait(seconds: 50))
        XCTAssertEqual(breaker.admit(now: 150), .wait(seconds: 10))
        XCTAssertEqual(breaker.admit(now: 160), .wait(seconds: 0))
        XCTAssertEqual(breaker.admit(now: 200), .wait(seconds: 0))
    }

    func testWaitersProceedOnceTheAttemptSucceeds() {
        var breaker = self.breaker()
        XCTAssertEqual(breaker.admit(now: 0), .connect)
        guard case .wait = breaker.admit(now: 1) else { return XCTFail("expected a wait") }
        breaker.attemptSucceeded()
        XCTAssertEqual(breaker.admit(now: 1), .proceed)
    }

    func testWaitersAllFailAtOnceWhenTheAttemptFails() {
        var breaker = self.breaker()
        XCTAssertEqual(breaker.admit(now: 0), .connect)
        breaker.attemptFailed(.transient, now: 5)
        XCTAssertEqual(breaker.admit(now: 5), .failFast(.backingOff(remaining: 2)))
    }

    // MARK: A connection that was up and went

    func testALostConnectionReconnectsWithNoBackoffOwed() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptSucceeded()
        XCTAssertEqual(breaker.admit(now: 10), .proceed)
        breaker.connectionLost()
        // The connection worked a moment ago, so a fresh attempt is right and a 2 s wait
        // would only add latency to the first request after a lid opens.
        XCTAssertEqual(breaker.admit(now: 10), .connect)
    }

    func testASuccessClearsTheFailureCountAndTheCap() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.keyAgentNotReady, now: 0)
        XCTAssertEqual(breaker.consecutiveFailures, 1)
        XCTAssertEqual(breaker.backoffCapSeconds, 300)
        _ = breaker.admit(now: 100)
        breaker.attemptSucceeded()
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertEqual(breaker.backoffCapSeconds, 60)
    }

    // MARK: Rule 4 - what does not go through the breaker at all

    func testAuthAndHostKeyFailuresStopRatherThanBackOff() {
        for classification in [SSHExitClassification.authenticationFailed, .hostKeyFailed] {
            var breaker = self.breaker()
            _ = breaker.admit(now: 0)
            breaker.attemptFailed(classification, now: 0)
            XCTAssertEqual(breaker.admit(now: 0), .failFast(.stopped(classification)))
            // No backoff-sized retry: four minutes later it is still stopped.
            XCTAssertEqual(breaker.admit(now: 240), .failFast(.stopped(classification)))
            // Nor does a reset on its own lift it.
            breaker.reset()
            XCTAssertEqual(breaker.admit(now: 240), .failFast(.stopped(classification)))
            XCTAssertTrue(breaker.isStopped)
        }
    }

    /// The slow retry: 5 minutes, doubling to a 30-minute cap, and never faster. A home
    /// directory that is not mounted yet refuses every key in it, and a mount that needed
    /// `debug breaker --connect` to come back after that is a mount that is "always
    /// offline" to the person who owns it.
    func testARefusalIsRetriedSlowlyAndTheIntervalDoublesToThirtyMinutes() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.authenticationFailed, now: 0)
        var intervals: [TimeInterval] = []
        var failedAt: TimeInterval = 0
        for _ in 0..<6 {
            let due = try! XCTUnwrap(breaker.stopRetryAt)
            intervals.append(due - failedAt)
            XCTAssertEqual(breaker.admit(now: due - 1), .failFast(.stopped(.authenticationFailed)))
            XCTAssertEqual(breaker.admit(now: due), .connect)
            // Everything that arrives meanwhile waits on that one attempt.
            guard case .wait = breaker.admit(now: due) else { return XCTFail("expected a wait") }
            breaker.attemptFailed(.authenticationFailed, now: due + 1)
            failedAt = due + 1
        }
        XCTAssertEqual(intervals, [300, 600, 1200, 1800, 1800, 1800])
        XCTAssertTrue(breaker.description(now: failedAt).contains("next attempt in 30 min"))
    }

    /// Wake, a path change or an unlock let one attempt out at once, and do not push the
    /// next unattended one further away.
    func testRetryStopNowLetsOneAttemptOutWithoutRaisingTheInterval() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.hostKeyFailed, now: 0)
        XCTAssertTrue(breaker.retryStopNow(now: 70))
        XCTAssertEqual(breaker.admit(now: 70), .connect)
        breaker.attemptFailed(.hostKeyFailed, now: 71)
        XCTAssertEqual(breaker.stopRetryLevel, 0)
        XCTAssertEqual(breaker.stopRetryAt, 300, "the interval's own retry stays where it was")
        // A success clears it all.
        XCTAssertEqual(breaker.admit(now: 300), .connect)
        breaker.attemptSucceeded()
        XCTAssertNil(breaker.stopRetryAt)
        XCTAssertFalse(breaker.earlyRetryUsed)
        XCTAssertEqual(breaker.admit(now: 300), .proceed)
    }

    /// A lid opening is a wake, the network path and an unlock within seconds. The first
    /// is the attempt, and the other two are merged into it.
    func testEarlyRetriesWithinTheDebounceAreMerged() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.authenticationFailed, now: 1)
        XCTAssertFalse(breaker.retryStopNow(now: 30), "30 s after the refusal: merged into it")
        XCTAssertFalse(breaker.earlyRetryUsed, "a merged event does not use the allowance")
        XCTAssertTrue(breaker.retryStopNow(now: 100))
        XCTAssertEqual(breaker.admit(now: 100), .connect)
        breaker.attemptFailed(.authenticationFailed, now: 101)
        XCTAssertFalse(breaker.retryStopNow(now: 103), "the path, 3 s after the wake")
        XCTAssertFalse(breaker.retryStopNow(now: 110), "the unlock, 10 s after it")
        XCTAssertEqual(breaker.admit(now: 110), .failFast(.stopped(.authenticationFailed)))
    }

    /// One early attempt per stop interval: a second wake, path change or unlock in the
    /// same interval waits for the scheduled retry, and the scheduled retry opens a new
    /// interval with a new allowance.
    func testOneEarlyRetryPerStopInterval() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.authenticationFailed, now: 0)
        XCTAssertTrue(breaker.retryStopNow(now: 100))
        _ = breaker.admit(now: 100)
        breaker.attemptFailed(.authenticationFailed, now: 100)
        XCTAssertFalse(breaker.retryStopNow(now: 200), "the allowance is spent")
        XCTAssertEqual(breaker.stopRetryAt, 300)
        XCTAssertEqual(breaker.admit(now: 300), .connect)
        breaker.attemptFailed(.authenticationFailed, now: 300)
        XCTAssertEqual(breaker.stopRetryAt, 900)
        XCTAssertFalse(breaker.retryStopNow(now: 330), "debounced after the scheduled retry")
        XCTAssertTrue(breaker.retryStopNow(now: 400), "a new interval, a new allowance")
    }

    /// The worst case the slow schedule allows, every early retry taken as soon as the
    /// rules let it: never more than four attempts in any ten minutes, and ten in the
    /// first hour.
    func testTheWorstCaseOfTheSlowRetry() {
        var breaker = CircuitBreaker(jitter: { $0 * 0.8 })
        var attempts: [Double] = []
        _ = breaker.admit(now: 0)
        attempts.append(0)
        breaker.attemptFailed(.authenticationFailed, now: 0)
        var now = 0.0
        while now < 4 * 3600 {
            now += 1
            if breaker.retryStopNow(now: now) {
                XCTAssertEqual(breaker.admit(now: now), .connect)
                attempts.append(now)
                breaker.attemptFailed(.authenticationFailed, now: now)
            } else if case .connect = breaker.admit(now: now) {
                attempts.append(now)
                breaker.attemptFailed(.authenticationFailed, now: now)
            }
        }
        let busiestTenMinutes = attempts.map { start in
            attempts.filter { $0 >= start && $0 < start + 600 }.count
        }.max() ?? 0
        XCTAssertEqual(busiestTenMinutes, 4, "\(attempts)")
        XCTAssertEqual(attempts.filter { $0 < 3600 }.count, 10, "\(attempts)")
        let lateHour = attempts.filter { $0 >= 3 * 3600 && $0 < 4 * 3600 }.count
        XCTAssertLessThanOrEqual(lateHour, 6, "\(attempts)")
        let gaps = zip(attempts.dropFirst(), attempts).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 60 }, "\(gaps)")
    }

    /// A refused password is retried by nothing: no slow timer, and no wake, path change
    /// or unlock. Only `clearStop` - `debug breaker --connect` - lets an attempt out.
    func testARefusedPasswordIsNeverRetriedOnItsOwn() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.passwordRefused, now: 0)
        XCTAssertTrue(breaker.isStopped)
        XCTAssertNil(breaker.stopRetryAt)
        XCTAssertFalse(breaker.retryStopNow(now: 1000))
        XCTAssertFalse(breaker.rearmOneAttempt())
        breaker.reset()
        breaker.setNetworkPath(false)
        breaker.setNetworkPath(true)
        XCTAssertEqual(breaker.admit(now: 100_000), .failFast(.stopped(.passwordRefused)))
        breaker.clearStop()
        XCTAssertEqual(breaker.admit(now: 100_001), .connect)
    }

    /// A deadline stop gets neither: no unattended timer, and wake, a path change or an
    /// unlock do not lift it on their own. Its triggers are the presence-gated re-arm's.
    func testADeadlineStopHasNoSlowRetry() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.authenticationDeadline, now: 0)
        XCTAssertNil(breaker.stopRetryAt)
        XCTAssertFalse(breaker.retryStopNow(now: 1000))
        XCTAssertEqual(breaker.admit(now: 100_000), .failFast(.stopped(.authenticationDeadline)))
    }

    func testOnlyADeadlineStopIsReArmable() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.authenticationFailed, now: 0)
        XCTAssertFalse(breaker.rearmOneAttempt())
        XCTAssertTrue(breaker.isStopped)

        var deadline = self.breaker()
        _ = deadline.admit(now: 0)
        deadline.attemptFailed(.authenticationDeadline, now: 0)
        XCTAssertTrue(deadline.isStopped)
        XCTAssertTrue(deadline.rearmOneAttempt())
        // Exactly one attempt: it connects once, and a second failure stops it again.
        XCTAssertEqual(deadline.admit(now: 1), .connect)
        deadline.attemptFailed(.authenticationDeadline, now: 2)
        XCTAssertEqual(deadline.admit(now: 2), .failFast(.stopped(.authenticationDeadline)))
    }

    func testClearStopIsWhatSshdriveTestDoes() {
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.authenticationFailed, now: 0)
        breaker.clearStop()
        XCTAssertEqual(breaker.admit(now: 0), .connect)
    }

    func testAChannelLimitIsTransientRatherThanAStop() {
        // A running location drops a channel rather than reconnecting
        // (docs/design/ssh.md), so `MaxSessions` must never stop the location.
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.channelLimitReached, now: 0)
        XCTAssertFalse(breaker.isStopped)
    }
}
