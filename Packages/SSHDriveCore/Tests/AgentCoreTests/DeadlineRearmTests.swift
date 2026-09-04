import XCTest
import SSHProcess
@testable import AgentCore

/// DESIGN.md section 4.2's re-arm after an authentication-deadline stop. The clock is an
/// argument and the presence reading is a closure, so the once-a-minute rule is provable
/// by counting the closure's calls rather than by waiting a minute.
final class DeadlineRearmTests: XCTestCase {

    private let present = PresenceReading(secondsSinceLastInputEvent: 3, screenLocked: false)
    private let idle = PresenceReading(secondsSinceLastInputEvent: 45, screenLocked: false)
    private let locked = PresenceReading(secondsSinceLastInputEvent: 1, screenLocked: true)

    func testPresenceNeedsBothUnderThirtySecondsAndAnUnlockedScreen() {
        XCTAssertTrue(present.userIsPresent)
        XCTAssertFalse(idle.userIsPresent)
        XCTAssertFalse(locked.userIsPresent)
        // The boundary is "under 30 s", not "at most".
        XCTAssertFalse(
            PresenceReading(secondsSinceLastInputEvent: 30, screenLocked: false).userIsPresent)
        XCTAssertTrue(
            PresenceReading(secondsSinceLastInputEvent: 29.9, screenLocked: false).userIsPresent)
    }

    func testNothingFiresUntilADeadlineStop() {
        var state = DeadlineRearmState()
        XCTAssertFalse(state.screenUnlocked())
        XCTAssertFalse(state.requestArrived(now: 0, presence: { self.present }))
        XCTAssertEqual(state.presenceEvaluations, 0)
    }

    func testEachTriggerFiresExactlyOncePerStop() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)

        XCTAssertTrue(state.screenUnlocked())
        XCTAssertFalse(state.screenUnlocked())
        XCTAssertFalse(state.screenUnlocked())

        XCTAssertTrue(state.requestArrived(now: 0, presence: { self.present }))
        // Even a minute later, and even with the user right there.
        XCTAssertFalse(state.requestArrived(now: 600, presence: { self.present }))

        // A second deadline stop arms both again.
        state.noteStop(.authenticationDeadline)
        XCTAssertTrue(state.screenUnlocked())
        XCTAssertTrue(state.requestArrived(now: 700, presence: { self.present }))
    }

    func testARequestWithInputIdleOverThirtySecondsDoesNotFireIt() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)
        XCTAssertFalse(state.requestArrived(now: 0, presence: { self.idle }))
        // The trigger is still available: it was not consumed by a failed test.
        XCTAssertTrue(state.requestArrived(now: 120, presence: { self.present }))
    }

    func testARequestAtALockedScreenDoesNotFireIt() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)
        XCTAssertFalse(state.requestArrived(now: 0, presence: { self.locked }))
        XCTAssertFalse(state.requestTriggerUsed)
    }

    /// Section 4.2: "evaluated at most once a minute so the test itself costs nothing".
    /// Spotlight, Quick Look and the working-set enumerator issue requests all day; this
    /// is the number that proves the test is not on all of them.
    func testThePresenceTestIsReadAtMostOnceAMinute() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)
        var now: TimeInterval = 0
        var reads = 0
        // Four hundred requests over ten minutes, all with the user idle so nothing fires.
        for step in 0..<400 {
            now = Double(step) * 1.5
            _ = state.requestArrived(
                now: now,
                presence: {
                    reads += 1
                    return self.idle
                })
        }
        XCTAssertEqual(reads, state.presenceEvaluations)
        // 600 s of requests, one reading a minute: ten, or eleven counting the one at t=0.
        XCTAssertLessThanOrEqual(reads, 11)
        XCTAssertGreaterThanOrEqual(reads, 10)
    }

    func testTheUnlockTriggerDoesNotConsultPresenceAtAll() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)
        XCTAssertTrue(state.screenUnlocked())
        // An unlock is itself the evidence; it is the trigger the 1Password and Secretive
        // case exists for, and there is nobody to have moved a mouse yet.
        XCTAssertEqual(state.presenceEvaluations, 0)
    }

    func testARefusalIsNeverReArmed() {
        for classification in [
            SSHExitClassification.authenticationFailed, .hostKeyFailed, .transient,
        ] {
            var state = DeadlineRearmState()
            state.noteStop(classification)
            XCTAssertFalse(state.isArmed, "\(classification) must not arm the re-arm")
            XCTAssertFalse(state.screenUnlocked())
            XCTAssertFalse(state.requestArrived(now: 0, presence: { self.present }))
        }
    }

    func testASuccessfulConnectionClearsEverything() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)
        state.clear()
        XCTAssertFalse(state.isArmed)
        XCTAssertFalse(state.screenUnlocked())
    }

    /// A stop, an unlock that re-arms, a second stop, and then a request that re-arms
    /// again: the morning-after sequence section 4.2 is written for. The point is that the
    /// user gets a second chance without running `sshdrive test`, and that an unattended
    /// Mac between the two stops retries nothing.
    func testTheMorningSequence() {
        var state = DeadlineRearmState()
        state.noteStop(.authenticationDeadline)          // overnight reconnect timed out
        // Nothing happens all night: requests arrive, the Mac is idle, nothing re-arms.
        for step in 0..<200 {
            XCTAssertFalse(
                state.requestArrived(now: Double(step) * 90, presence: { self.idle }))
        }
        XCTAssertTrue(state.screenUnlocked())            // the user sits down
        state.noteStop(.authenticationDeadline)          // and the key agent is still locked
        XCTAssertTrue(                                    // they click the mount
            state.requestArrived(now: 20_000, presence: { self.present }))
        // And that is the second chance spent.
        XCTAssertFalse(state.requestArrived(now: 30_000, presence: { self.present }))
    }
}
