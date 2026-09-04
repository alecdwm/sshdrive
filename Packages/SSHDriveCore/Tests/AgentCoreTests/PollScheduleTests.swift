import Foundation
import XCTest
@testable import AgentCore

/// DESIGN.md section 6.4's "Schedule for tiers 0 and 1".
final class PollScheduleTests: XCTestCase {

    func testSixtySecondsInsideTheTouchWindow() {
        // "Every 60 s while the user has touched the domain in the last 10 minutes."
        XCTAssertTrue(PollSchedule.isActive(lastTouch: 1000, now: 1000))
        XCTAssertTrue(PollSchedule.isActive(lastTouch: 1000, now: 1500))
        XCTAssertEqual(PollSchedule.interval(lastTouch: 1000, now: 1500), 60)
    }

    func testTenMinutesOutsideIt() {
        // "every 10 min otherwise".
        XCTAssertFalse(PollSchedule.isActive(lastTouch: 1000, now: 1601))
        XCTAssertEqual(PollSchedule.interval(lastTouch: 1000, now: 1601), 600)
    }

    func testTheWindowBoundaryIsInclusive() {
        XCTAssertTrue(PollSchedule.isActive(lastTouch: 1000, now: 1600))
        XCTAssertFalse(PollSchedule.isActive(lastTouch: 1000, now: 1600.001))
    }

    func testADomainNeverTouchedThisSessionIsIdle() {
        XCTAssertFalse(PollSchedule.isActive(lastTouch: nil, now: 10_000))
        XCTAssertEqual(PollSchedule.interval(lastTouch: nil, now: 10_000), 600)
    }

    func testTheNextFireIsMeasuredFromTheLastCycleAndNotFromNow() {
        // A cycle that ran long must not push the schedule out by its own duration.
        XCTAssertEqual(PollSchedule.nextFire(lastCycle: 1000, lastTouch: 990, now: 1005), 1060)
        XCTAssertEqual(PollSchedule.nextFire(lastCycle: 1000, lastTouch: nil, now: 1005), 1600)
        // A caller that is already late gets a time in the past, which means fire now.
        XCTAssertLessThan(PollSchedule.nextFire(lastCycle: 1000, lastTouch: 2000, now: 2000), 2000)
    }

    func testTheInsurancePassIsDueAtThirtyMinutes() {
        // "a sweep still runs every 30 min as insurance against missed events".
        XCTAssertFalse(PollSchedule.insuranceDue(lastFullSweep: 0, now: 1799))
        XCTAssertTrue(PollSchedule.insuranceDue(lastFullSweep: 0, now: 1800))
        XCTAssertTrue(PollSchedule.insuranceDue(lastFullSweep: 0, now: 100_000))
    }

    func testTheConstantsAreTheOnesSectionSixFourStates() {
        XCTAssertEqual(PollSchedule.activeInterval, 60)
        XCTAssertEqual(PollSchedule.idleInterval, 600)
        XCTAssertEqual(PollSchedule.touchWindow, 600)
        XCTAssertEqual(PollSchedule.insuranceInterval, 1800)
    }
}
