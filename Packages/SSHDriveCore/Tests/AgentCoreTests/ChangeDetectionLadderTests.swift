import Config
import XCTest
@testable import AgentCore

/// DESIGN.md section 6.4's selection and its runtime ladder, with the clock as an argument.
final class ChangeDetectionLadderTests: XCTestCase {

    private typealias Capabilities = ChangeDetectionLadder.ServerCapabilities

    /// An ordinary Linux server: shell and GNU find. `helperAvailable` defaults to false
    /// here because most of these cases are about what happens without tier 2; the tier 2
    /// rung has its own section at the end.
    private func gnuServer(helperAvailable: Bool = false, helperEnabled: Bool = true,
                           takesCmin: Bool = true) -> Capabilities {
        Capabilities(hasExecChannel: true, hasFind: true, takesCmin: takesCmin, takesPrintf: true,
                     helperAvailable: helperAvailable, helperEnabledForLocation: helperEnabled)
    }

    /// A chrooted `internal-sftp` account: no exec channel at all.
    private func sftpOnlyServer() -> Capabilities {
        Capabilities(hasExecChannel: false, hasFind: false)
    }

    // MARK: auto

    func testAutoWithNoShellSettlesAtPoll() {
        let ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: sftpOnlyServer(), now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note, "the account has no shell access")
        XCTAssertTrue(ladder.downgrades.isEmpty)
    }

    func testAutoWithShellAndFindSettlesAtSweepAndSaysWhyItIsNotHigher() {
        let ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        // Section 8.1's note: line, on a server whose probe left the helper out.
        XCTAssertEqual(ladder.note, "the server cannot run the remote helper")
    }

    func testAutoWithShellButNoFindSettlesAtPoll() {
        let capabilities = Capabilities(hasExecChannel: true, hasFind: false)
        let ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: capabilities, now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note, "the server cannot run the remote helper; the server has no usable find")
    }

    func testAutoTakesTheHelperWhenItIsAvailableAndHasNoNote() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        // Nil at the best tier: there is nothing to explain.
        XCTAssertNil(ladder.note)
    }

    func testHelperOffForTheLocationIsSaidPlainly() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true, helperEnabled: false), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "the helper is off for this location")
    }

    // MARK: A specific watchMode disables the ladder except to poll

    func testWatchModeSweepOnAServerWithNoShellFallsAllTheWayToPoll() {
        // Section 6.4: "Setting watchMode to a specific tier disables the fallback ladder
        // except to poll, which always works."
        let ladder = ChangeDetectionLadder(watchMode: .sweep, capabilities: sftpOnlyServer(), now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note, "watchMode is set to sweep, but the account has no shell access")
    }

    func testWatchModeSweepOnAServerThatCanSweep() {
        let ladder = ChangeDetectionLadder(watchMode: .sweep, capabilities: gnuServer(), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "watchMode is set to sweep")
    }

    func testWatchModeSweepIsNotRaisedToTheHelperEvenWhereItWouldRun() {
        let ladder = ChangeDetectionLadder(
            watchMode: .sweep, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
    }

    func testWatchModeHelperFallsStraightToPollAndNotToSweep() {
        // The ladder is disabled except to poll, so asking for the helper and silently
        // getting a sweep is not what a specific watchMode means.
        let ladder = ChangeDetectionLadder(watchMode: .helper, capabilities: gnuServer(), now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note,
                       "watchMode is set to helper, but the server cannot run the remote helper")
    }

    func testWatchModePollStaysPollOnTheBestServerThereIs() {
        let ladder = ChangeDetectionLadder(
            watchMode: .poll, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note, "watchMode is set to poll")
    }

    // MARK: Runtime failures

    func testAFailureAtSweepDropsToPollForTheSessionAndIsRecorded() {
        var ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertTrue(ladder.recordRuntimeFailure(reason: "find is missing", now: 120))
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.downgrades,
                       [ChangeDetectionLadder.Downgrade(from: .sweep, to: .poll,
                                                        reason: "find is missing", at: 120)])
        XCTAssertEqual(ladder.note, "sweep failed: find is missing")
    }

    func testASecondFailureDoesNotDropBelowPoll() {
        var ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(), now: 0)
        ladder.recordRuntimeFailure(reason: "find is missing", now: 120)
        XCTAssertFalse(ladder.recordRuntimeFailure(reason: "readdir failed", now: 200))
        XCTAssertEqual(ladder.tier, .poll)
        // Nothing moved, so nothing is recorded as a downgrade, but the reason is kept.
        XCTAssertEqual(ladder.downgrades.count, 1)
        XCTAssertEqual(ladder.note, "poll failed: readdir failed")
    }

    func testTheHelperDropsOneTierAtATime() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertTrue(ladder.recordRuntimeFailure(reason: "the stream died", now: 10))
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertTrue(ladder.recordRuntimeFailure(reason: "find is missing", now: 20))
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.downgrades.map(\.from), [.helper, .sweep])
    }

    // MARK: A new probe

    func testANewProbeIsNeverRaisedBackOverAFailureThisSessionSaw() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        ladder.recordRuntimeFailure(reason: "the stream died", now: 10)
        XCTAssertEqual(ladder.tier, .sweep)
        // A reconnect re-probes and finds the same capable server. Section 6.4's drop is
        // "for the rest of the session", and a reconnect is not a new session.
        ladder.applyCapabilities(gnuServer(helperAvailable: true), watchMode: .auto, now: 100)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "helper failed: the stream died")
    }

    func testANewProbeCanStillLowerTheTier() {
        var ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        // The reconnect landed on a different host behind the same name, without a shell.
        ladder.applyCapabilities(sftpOnlyServer(), watchMode: .auto, now: 100)
        XCTAssertEqual(ladder.tier, .poll)
    }

    func testChangingWatchModeGoesThroughTheSamePath() {
        var ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(), now: 0)
        ladder.applyCapabilities(gnuServer(), watchMode: .poll, now: 50)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note, "watchMode is set to poll")
    }

    // MARK: The find flavour

    func testSweepUsesMminFollowsTakesCmin() {
        let cmin = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(takesCmin: true), now: 0)
        XCTAssertFalse(cmin.sweepUsesMmin)
        // A busybox NAS: section 6.4 calls this "a normal status line and not an alarm".
        let busybox = ChangeDetectionLadder(watchMode: .auto, capabilities: gnuServer(takesCmin: false), now: 0)
        XCTAssertEqual(busybox.tier, .sweep)
        XCTAssertTrue(busybox.sweepUsesMmin)
    }

    func testALocationAtPollRunsNoSweepAndSoHasNoMminNote() {
        let ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: sftpOnlyServer(), now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertFalse(ladder.sweepUsesMmin)
    }

    // MARK: The tier order

    func testTheTiersAreOrderedPollSweepHelper() {
        XCTAssertLessThan(ChangeDetectionLadder.Tier.poll, .sweep)
        XCTAssertLessThan(ChangeDetectionLadder.Tier.sweep, .helper)
        XCTAssertEqual(ChangeDetectionLadder.Tier.allCases, [.poll, .sweep, .helper])
        XCTAssertNil(ChangeDetectionLadder.Tier.poll.oneLower)
    }

    // MARK: The tier 2 rung (milestone 9)

    /// `auto` "tries the tiers from the top: helper first". On a server that can run it,
    /// that is where a location settles, with no note at all - the best level has nothing
    /// to explain.
    func testAutoClimbsToHelperWhereTheServerCanRunIt() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertNil(ladder.note)
    }

    /// The location's own `helper off` (section 8). Named first in the note, because it is
    /// the one thing the user changed.
    func testHelperOffKeepsTheLocationAtSweepAndSaysSo() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto,
            capabilities: gnuServer(helperAvailable: true, helperEnabled: false), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "the helper is off for this location")
    }

    /// Section 8.1: the note has to name the real reason - `cache directory is noexec`,
    /// `helper unsupported: <os>/<arch>`, `helper upload failed: …` - not a category.
    func testTheDeploymentsOwnReasonIsWhatStatusPrints() {
        for reason in [
            "cache directory is noexec",
            "helper unsupported: Linux mips64",
            "helper upload failed: the copy on the server does not match this build",
            "the server will not give the helper a channel of its own (MaxSessions 2)",
        ] {
            var capabilities = gnuServer()
            capabilities.helperBlockReason = reason
            let ladder = ChangeDetectionLadder(watchMode: .auto, capabilities: capabilities, now: 0)
            XCTAssertEqual(ladder.tier, .sweep)
            XCTAssertEqual(ladder.note, reason)
        }
    }

    /// "A tier that fails at runtime (the helper's stream dies with a non-network error)
    /// drops the location one tier down for the rest of the session and records why."
    func testAHelperStreamThatDiesDropsToSweepForTheSession() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertTrue(ladder.recordRuntimeFailure(reason: "the helper exited", now: 100))
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.downgrades.count, 1)
        XCTAssertEqual(ladder.downgrades[0].from, .helper)
        XCTAssertEqual(ladder.downgrades[0].to, .sweep)
        XCTAssertEqual(ladder.note, "helper failed: the helper exited")

        // "for the rest of the session": a later probe that still says the helper is
        // available must not put the location back on the tier that just failed.
        ladder.applyCapabilities(gnuServer(helperAvailable: true), watchMode: .auto, now: 200)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "helper failed: the helper exited")
    }

    /// Two failures walk the location all the way to the floor, and the floor holds.
    func testHelperThenSweepEndsAtPollAndStaysThere() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertTrue(ladder.recordRuntimeFailure(reason: "the helper exited", now: 1))
        XCTAssertTrue(ladder.recordRuntimeFailure(reason: "find is missing", now: 2))
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertFalse(ladder.recordRuntimeFailure(reason: "readdir failed", now: 3))
        XCTAssertEqual(ladder.tier, .poll)
    }

    /// "Setting `watchMode` to a specific tier disables the fallback ladder except to
    /// `poll`": `watch-mode helper` on a server that cannot run it goes to poll, not to
    /// sweep, because asking for the helper and silently getting a sweep is not what that
    /// setting means.
    func testWatchModeHelperOnAServerWithoutOneFallsStraightToPoll() {
        var capabilities = gnuServer()
        capabilities.helperBlockReason = "cache directory is noexec"
        let ladder = ChangeDetectionLadder(watchMode: .helper, capabilities: capabilities, now: 0)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertEqual(ladder.note, "watchMode is set to helper, but cache directory is noexec")
    }

    func testWatchModeHelperOnAServerWithOneRunsIt() {
        let ladder = ChangeDetectionLadder(
            watchMode: .helper, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertNil(ladder.note)
    }

    /// `watch-mode sweep` on a server that could run the helper is the user's choice, and
    /// section 8.1 says it shows a note and *no* `upgrade:` line.
    func testWatchModeSweepIsRecordedAsTheUsersChoiceEvenWithAHelperAvailable() {
        let ladder = ChangeDetectionLadder(
            watchMode: .sweep, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "watchMode is set to sweep")
    }

    /// Section 6.4 still runs a sweep every 30 minutes at tier 2, so the busybox `-mmin`
    /// note belongs on a helper location too: that sweep has the same blind spot.
    func testTheMminNoteSurvivesAtTierTwoBecauseTheInsuranceSweepStillRuns() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto,
            capabilities: gnuServer(helperAvailable: true, takesCmin: false), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertTrue(ladder.sweepUsesMmin)
    }
}
