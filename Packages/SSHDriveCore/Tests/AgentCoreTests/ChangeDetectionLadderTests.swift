import Config
import XCTest
@testable import AgentCore

/// The change-detection tier selection and its runtime ladder (docs/design/change-detection.md),
/// with the clock as an argument.
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
        // The capability report's `note:` line (docs/design/cli.md), on a server whose
        // probe left the helper out.
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
        // docs/design/change-detection.md: "Setting watchMode to a specific tier disables
        // the fallback ladder except to poll, which always works."
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
        // A reconnect re-probes and finds the same capable server. The runtime-failure
        // drop holds "for the rest of the session" (docs/design/change-detection.md), and
        // a reconnect is not a new session.
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
        // A busybox NAS: the change-detection design page calls this "a normal status
        // line and not an alarm" (docs/design/change-detection.md).
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

    // MARK: The tier 2 rung

    /// `auto` "tries the tiers from the top: helper first". On a server that can run it,
    /// that is where a location settles, with no note at all - the best level has nothing
    /// to explain.
    func testAutoClimbsToHelperWhereTheServerCanRunIt() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertNil(ladder.note)
    }

    /// The location's own `helper off` (docs/design/cli.md). Named first in the note,
    /// because it is the one thing the user changed.
    func testHelperOffKeepsTheLocationAtSweepAndSaysSo() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto,
            capabilities: gnuServer(helperAvailable: true, helperEnabled: false), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "the helper is off for this location")
    }

    /// The capability report's note names the real reason - `cache directory is noexec`,
    /// `helper unsupported: <os>/<arch>`, `helper upload failed: …` - not a category
    /// (docs/design/cli.md).
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
    /// the capability report shows a note and *no* `upgrade:` line for it (docs/design/cli.md).
    func testWatchModeSweepIsRecordedAsTheUsersChoiceEvenWithAHelperAvailable() {
        let ladder = ChangeDetectionLadder(
            watchMode: .sweep, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "watchMode is set to sweep")
    }

    /// The 30-minute insurance sweep still runs at tier 2 (docs/design/change-detection.md),
    /// so the busybox `-mmin` note belongs on a helper location too: that sweep has the
    /// same blind spot.
    func testTheMminNoteSurvivesAtTierTwoBecauseTheInsuranceSweepStillRuns() {
        let ladder = ChangeDetectionLadder(
            watchMode: .auto,
            capabilities: gnuServer(helperAvailable: true, takesCmin: false), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertTrue(ladder.sweepUsesMmin)
    }

    // MARK: Transient failures and the climb back

    /// A network outage kills the helper's stream. Without a bounded transient hold, the
    /// location would stay at sweep until the agent is restarted.
    func testATransientFailureHoldsTheTierOnlyForItsBackoff() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertTrue(
            ladder.recordRuntimeFailure(
                reason: "the helper exited", permanence: .transient, now: 100))
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertTrue(ladder.isHeldByTransientFailure)
        XCTAssertEqual(ladder.transientHoldExpiresAt, 102)
        XCTAssertEqual(ladder.note, "helper failed: the helper exited; retrying in 2 s")

        // Not yet.
        XCTAssertFalse(ladder.climbBack(now: 101))
        XCTAssertEqual(ladder.tier, .sweep)
        // And now.
        XCTAssertTrue(ladder.climbBack(now: 102))
        XCTAssertEqual(ladder.tier, .helper)
        XCTAssertNil(ladder.note)
        XCTAssertFalse(ladder.isHeldByTransientFailure)
    }

    /// 2 s, 4 s, 8 s … and never past the cap, so a server whose helper dies the moment it
    /// starts is retried on a bounded schedule rather than every cycle for ever.
    func testTheTransientBackoffDoublesAndIsCapped() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        var seen: [Double] = []
        var now: Double = 0
        for _ in 0..<8 {
            ladder.recordRuntimeFailure(
                reason: "the helper exited", permanence: .transient, now: now)
            seen.append(ladder.retryBackoffSeconds)
            now += ladder.retryBackoffSeconds
            ladder.climbBack(now: now)
        }
        XCTAssertEqual(seen, [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertLessThanOrEqual(seen.max() ?? 0, ChangeDetectionLadder.retryCapSeconds)
    }

    /// The offline-handling breaker (docs/design/offline.md) brings the connection back
    /// on its own schedule, and that is the evidence the outage is over: the hold goes
    /// and the backoff starts again at 2 s. This is what makes repeated down/up cycles
    /// converge on the helper within one cycle of the link being stable rather than one
    /// per doubling.
    func testAConnectionComingUpClearsTheHoldAndTheBackoff() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        for round in 0..<4 {
            let at = Double(round) * 120
            ladder.recordRuntimeFailure(
                reason: "connectionLost", permanence: .transient, now: at)
            XCTAssertEqual(ladder.tier, .sweep)
            XCTAssertTrue(ladder.noteConnected(now: at + 1))
            XCTAssertEqual(ladder.tier, .helper, "round \(round)")
            XCTAssertEqual(ladder.retryBackoffSeconds, 2, "round \(round)")
        }
    }

    /// A permanent failure is still permanent, and a reconnect does not lift it: the
    /// permanent reasons (docs/design/change-detection.md) are no shell, no exec channel,
    /// an unsupported architecture, a `noexec` directory and a hash that did not match
    /// after a redeploy.
    func testAPermanentFailureSurvivesAConnectionAndAClimbBack() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        ladder.recordRuntimeFailure(
            reason: "helper unsupported: Linux mips", permanence: .permanent, now: 10)
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertFalse(ladder.isHeldByTransientFailure)
        XCTAssertFalse(ladder.climbBack(now: 10_000))
        XCTAssertFalse(ladder.noteConnected(now: 10_000))
        XCTAssertEqual(ladder.tier, .sweep)
        XCTAssertEqual(ladder.note, "helper failed: helper unsupported: Linux mips")
    }

    /// A transient failure below a permanent one climbs back only to the permanent ceiling.
    func testAClimbBackNeverPassesAPermanentCeiling() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        ladder.recordRuntimeFailure(reason: "no helper for this arch", permanence: .permanent, now: 1)
        XCTAssertEqual(ladder.tier, .sweep)
        ladder.recordRuntimeFailure(reason: "the sweep was cut off", permanence: .transient, now: 2)
        XCTAssertEqual(ladder.tier, .poll)
        XCTAssertTrue(ladder.climbBack(now: 100))
        XCTAssertEqual(ladder.tier, .sweep)
    }

    /// A tier that has run for `stabilitySeconds` forgets the failures before it, so a
    /// server that is well again does not carry a 60 s hold for the rest of the session.
    func testAHealthyTierResetsTheBackoff() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        for i in 0..<5 {
            ladder.recordRuntimeFailure(reason: "flap", permanence: .transient, now: Double(i))
            ladder.climbBack(now: Double(i) + 100)
        }
        XCTAssertEqual(ladder.retryBackoffSeconds, 32)
        ladder.noteTierHealthy(now: 1_000)
        ladder.recordRuntimeFailure(reason: "flap", permanence: .transient, now: 1_001)
        XCTAssertEqual(ladder.retryBackoffSeconds, 2)
    }

    /// `status` has to say a downgrade is temporary and when it ends, or it reads as a
    /// verdict about the server.
    func testTheNoteCountsTheHoldDownFromWhereItIsRead() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        ladder.recordRuntimeFailure(reason: "connectionLost", permanence: .transient, now: 0)
        ladder.recordRuntimeFailure(reason: "connectionLost", permanence: .transient, now: 0)
        XCTAssertEqual(ladder.retryBackoffSeconds, 4)
        ladder.applyCapabilities(gnuServer(helperAvailable: true), watchMode: .auto, now: 1)
        XCTAssertEqual(ladder.note, "helper failed: connectionLost; retrying in 3 s")
    }

    /// A transient downgrade is kept in the history marked as one, so `status` can say the
    /// location has already climbed out of it.
    func testTheHistoryRecordsWhichKindOfDowngradeItWas() {
        var ladder = ChangeDetectionLadder(
            watchMode: .auto, capabilities: gnuServer(helperAvailable: true), now: 0)
        ladder.recordRuntimeFailure(reason: "the stream died", permanence: .transient, now: 1)
        ladder.climbBack(now: 100)
        ladder.recordRuntimeFailure(reason: "find is missing", permanence: .permanent, now: 200)
        XCTAssertEqual(ladder.downgrades.map(\.permanence), [.transient, .permanent])
        XCTAssertEqual(ladder.tier, .sweep)
    }
}
