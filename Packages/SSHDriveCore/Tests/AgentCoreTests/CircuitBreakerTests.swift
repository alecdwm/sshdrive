import XCTest
import SSHProcess
@testable import AgentCore

/// DESIGN.md section 6.3's breaker, rule by rule. The clock is an argument and the jitter
/// is injected, so every number here is exact and nothing sleeps.
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
        // Section 6.3: "a path change, wake from sleep, or `sshdrive test` resets the
        // breaker", so the next call connects rather than waiting out the 2 s.
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
            // Section 6.1: a locked key agent stays locked for hours, so the cap is
            // raised from 60 s to 5 minutes for this one classification.
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
            // And no amount of time changes it.
            XCTAssertEqual(breaker.admit(now: 100_000), .failFast(.stopped(classification)))
            // Nor does a path change or a wake: an auth failure is still an auth failure
            // after a Wi-Fi hop.
            breaker.reset()
            XCTAssertEqual(breaker.admit(now: 100_000), .failFast(.stopped(classification)))
        }
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
        // Section 6.1: a running location drops a channel rather than reconnecting, so
        // `MaxSessions` must never stop the location.
        var breaker = self.breaker()
        _ = breaker.admit(now: 0)
        breaker.attemptFailed(.channelLimitReached, now: 0)
        XCTAssertFalse(breaker.isStopped)
    }
}
