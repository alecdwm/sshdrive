import XCTest
@testable import AgentCore

/// The reconnect sequence (docs/design/offline.md, docs/design/change-detection.md):
/// what a reconnect does, in what order.
final class ReconnectSequenceTests: XCTestCase {

    /// The helper's exec channel is opened against the master the SFTP channels sit on, so
    /// a stream re-opened before `applyConnection` would be started on the connection that
    /// is going away.
    func testTheHelperStreamIsReopenedAfterTheChannels() {
        let steps = ReconnectSequence.steps
        XCTAssertLessThan(
            ReconnectSequence.indexOf(.applyConnection),
            ReconnectSequence.indexOf(.reopenHelperStream))
        XCTAssertLessThan(
            ReconnectSequence.indexOf(.applyCapabilities),
            ReconnectSequence.indexOf(.reopenHelperStream),
            "the ladder has to have read the new probe before the tier it names is started")
        XCTAssertEqual(steps.first, .applyConnection)
    }

    /// `signalErrorResolved` is what flushes a queued write (docs/design/offline.md), and
    /// it is sent after the location is actually able to serve one.
    func testTheSignalsComeLast() {
        XCTAssertEqual(
            ReconnectSequence.steps.suffix(2), [.signalErrorResolved, .signalWorkingSet])
        XCTAssertLessThan(
            ReconnectSequence.indexOf(.reopenHelperStream),
            ReconnectSequence.indexOf(.signalErrorResolved))
    }

    /// Every step runs exactly once, and nothing has been left out of the sequence the
    /// agent drives.
    func testEveryStepAppearsExactlyOnce() {
        XCTAssertEqual(Set(ReconnectSequence.steps).count, ReconnectSequence.steps.count)
        XCTAssertEqual(Set(ReconnectSequence.steps), Set(ReconnectStep.allCases))
        XCTAssertFalse(ReconnectStep.applyConnection.needsAppliedConnection)
        XCTAssertTrue(ReconnectStep.reopenHelperStream.needsAppliedConnection)
    }

    /// A step runs only for the connection the gate holds now: a sequence whose connection
    /// went, or was replaced, does nothing more.
    func testAStepRunsOnlyForTheCurrentConnection() {
        XCTAssertTrue(ReconnectSequence.mayRun(generation: 3, current: 3))
        XCTAssertFalse(ReconnectSequence.mayRun(generation: 3, current: 4))
        XCTAssertFalse(ReconnectSequence.mayRun(generation: 3, current: nil))
    }

    /// The re-check of an unanswered probe or an inconclusive budget: 30 s, doubling to
    /// ten minutes.
    func testTheRecheckBacksOffFromThirtySecondsToTenMinutes() {
        XCTAssertEqual(
            (0..<8).map(ReconnectSequence.recheckDelay(attempt:)),
            [30, 60, 120, 240, 480, 600, 600, 600])
        XCTAssertEqual(ReconnectSequence.recheckDelay(attempt: 1000), 600)
    }

    /// A re-check that finds room for more channels reconnects to use them, except under a
    /// running transfer, which a dropped connection would lose for good.
    func testABudgetRecheckNeverDropsATransfer() {
        XCTAssertEqual(
            ReconnectSequence.budgetRecheckAction(current: 2, found: 3, transferInFlight: false),
            .reconnect)
        XCTAssertEqual(
            ReconnectSequence.budgetRecheckAction(current: 2, found: 3, transferInFlight: true),
            .deferReconnect)
        XCTAssertEqual(
            ReconnectSequence.budgetRecheckAction(current: 3, found: 3, transferInFlight: false),
            .keep)
        XCTAssertEqual(
            ReconnectSequence.budgetRecheckAction(current: 2, found: 1, transferInFlight: false),
            .keep)
    }
}
