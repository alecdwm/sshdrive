import XCTest

@testable import AgentCore

/// The ordering rule `sshdrive add` follows before it prints section 8.1's report.
///
/// The first real install (2026-09-05) printed a report built in the window between the
/// ladder choosing tier 2 and the helper arriving: "change detection: sweep … note: the
/// server cannot run the remote helper", and `sshdrive status` said `helper 0.1.0` ten
/// seconds later. `add` now waits for that first attempt, bounded, and anything still in
/// flight is reported as `deploying` rather than as a server that cannot.
final class HelperSettleTests: XCTestCase {

    func testAServerWithNoTierTwoIsNotWaitedFor() {
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: false, streamRunning: false, refusal: nil, elapsed: 0),
            .done)
    }

    func testARunningStreamSettlesAtOnce() {
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: true, refusal: nil, elapsed: 0.2),
            .done)
    }

    func testARefusalWithAReasonSettlesAtOnce() {
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: false,
                refusal: "the server will not give the helper a channel of its own",
                elapsed: 0.4),
            .done)
    }

    /// The window the bug lived in: the tier is chosen, nothing has failed, and the
    /// report must not be written yet.
    func testTheDeployingWindowIsWaitedThrough() {
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: false, refusal: nil, elapsed: 0),
            .wait)
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: false, refusal: nil,
                elapsed: HelperSettle.addSeconds - 0.1),
            .wait)
    }

    /// A server that never answers costs `add` the deadline and no more, and the report
    /// then says `deploying` - never that the server cannot run it.
    func testTheWaitIsBounded() {
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: false, refusal: nil,
                elapsed: HelperSettle.addSeconds),
            .giveUp)
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: false, refusal: nil, elapsed: 3,
                timeout: 2),
            .giveUp)
        XCTAssertLessThanOrEqual(
            HelperSettle.addSeconds, 10,
            "`add` is interactive; the bound has to stay in the few seconds section 8 allows")
    }

    /// An empty reason is not a reason: it used to be what "the helper is not running"
    /// looked like before anything had been tried.
    func testAnEmptyRefusalIsNotSettled() {
        XCTAssertEqual(
            HelperSettle.step(
                tierIsHelper: true, streamRunning: false, refusal: "", elapsed: 1),
            .wait)
    }
}
