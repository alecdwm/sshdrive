import XCTest
@testable import AgentCore

/// DESIGN.md sections 5.6 and 6.4: what a reconnect does, in what order.
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

    /// Section 5.6: `signalErrorResolved` is what flushes a queued write, and it is sent
    /// after the location is actually able to serve one.
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
}
