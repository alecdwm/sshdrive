import XCTest
import Config
import Index
import ProviderCore
import SystemModel

/// **Suite A - the working set, anchors and enumeration**
/// (`docs/testing-architecture.md` section 5).
///
/// Nine scenarios, all of them on Linux with nothing attached: a real index, the shipping
/// `ProviderCore`, and a fileproviderd built out of `docs/quirks/macos.md`. `A2` is the
/// 0.1.2 regression and is the reason the whole harness exists.
///
/// Ids are stable for ever; a scenario is never renumbered, only retired with a reason.
final class WorkingSetScenarios: XCTestCase {

    // MARK: A1 - Empty change set at the held anchor

    /// A domain with rows and a reader deliberately not usable; a file is deleted on the
    /// server and the deletion is applied to the index; the working set is signalled.
    ///
    /// The provider must **never** answer `finishEnumeratingChanges(upTo: theSameAnchor)`
    /// with nothing (`MQ-004`), and the deletion must reach the replica within one signal.
    func testA1_EmptyChangeSetAtTheHeldAnchorIsNeverAnswered() throws {
        let harness = try ScenarioHarness()
        let doomed = try harness.serverCreates("gone.txt")
        try harness.serverCreates("stays.txt")
        // The agent answers no for a location whose runtime is not up yet, which is the
        // window the whole defect lived in.
        harness.agent.indexReadyAnswer = false
        let domain = try harness.addDomain()
        domain.openFolder()
        XCTAssertEqual(harness.finderListing(), ["gone.txt", "stays.txt"])

        let held = try XCTUnwrap(domain.heldWorkingSetAnchor)
        try harness.serverDeletes(doomed)
        domain.signalWorkingSet()

        XCTAssertEqual(domain.emptyChangeSetsAtHeldAnchor, 0)
        XCTAssertEqual(harness.finderListing(), ["stays.txt"], "one signal has to be enough")
        XCTAssertNotEqual(domain.heldWorkingSetAnchor, held, "the anchor must move with it")
        XCTAssertEqual(domain.throttleState, .none)
    }

    // MARK: A2 - The `.serverUnreachable` storm (the 0.1.2 regression)

    /// A healthy agent, the reader not ready on the first instance of each signal, and
    /// forty working-set signals in a row.
    ///
    /// The system launches a fresh instance for every signal (`MQ-003`), so every one of
    /// those forty enumerations meets a reader that has just been told "no" and has not
    /// been told anything else yet. Fewer than the throttle threshold (`MQ-005`: 27)
    /// consecutive failures, `throttleState` stays `.none`, and every change lands.
    func testA2_TheServerUnreachableStormDoesNotHappen() throws {
        let harness = try ScenarioHarness()
        harness.agent.indexReadyAnswer = false
        let domain = try harness.addDomain()
        domain.openFolder()

        for index in 0..<40 {
            try harness.serverCreates("file-\(index).txt")
            // Past any backoff a failure would have set, so that a run of failures really
            // would reach the threshold rather than being dropped by the throttle itself.
            harness.system.advance(60 * 60)
            domain.signalWorkingSet()
        }

        XCTAssertEqual(domain.throttleState, .none, "MQ-005: no throttle on a healthy domain")
        XCTAssertEqual(domain.consecutiveErrors, 0)
        XCTAssertEqual(domain.errorGeneration, 0)
        XCTAssertEqual(domain.emptyChangeSetsAtHeldAnchor, 0)
        XCTAssertEqual(domain.instancesLaunched, 41, "MQ-003: one fresh instance per signal")
        XCTAssertEqual(harness.finderListing().count, 40, "every change lands")
        XCTAssertFalse(
            domain.calls.contains(.signalDroppedByThrottle),
            "nothing may be dropped: the throttle never engages")
        // The rows were answered by the agent, not by the reader, which is the fallback
        // that did not exist in 0.1.2.
        XCTAssertEqual(
            harness.agent.calls.filter { $0.hasPrefix("enumerateWorkingSetChanges") }.count, 40)
    }

    /// **The bite-proof.** The identical scenario driven through a copy of the 0.1.2
    /// working-set enumerator (`LegacyWorkingSetEnumeration`), which had one answer for a
    /// reader it could not use.
    ///
    /// Everything `A2` asserts is false here: the throttle engages, it climbs to the
    /// measured schedule, and not one of the forty rows reaches the replica. If this test
    /// ever passes, `A2` above has stopped testing anything.
    func testA2_TheOldEnumeratorFailsTheSameScenario() throws {
        let harness = try ScenarioHarness()
        harness.workingSetEnumeratorOverride = { LegacyWorkingSetEnumeration(service: $0) }
        harness.agent.indexReadyAnswer = false
        let domain = try harness.addDomain()
        domain.openFolder()

        for index in 0..<40 {
            try harness.serverCreates("file-\(index).txt")
            harness.system.advance(60 * 60)
            domain.signalWorkingSet()
        }

        XCTAssertNotEqual(domain.throttleState, .none, "the throttle is exactly what shipped")
        XCTAssertGreaterThanOrEqual(
            domain.consecutiveErrors, 27, "MQ-005: the measured threshold is reached")
        XCTAssertEqual(domain.errorGeneration, 40)
        XCTAssertEqual(
            domain.throttleState, .backingOff(nextRetryIn: 47 * 60),
            "MQ-005: 27 errors took the fetch-event stream to a 47-minute retry")
        XCTAssertEqual(harness.finderListing(), [], "nothing from the server reaches Finder")
        XCTAssertTrue(
            harness.agent.calls.filter { $0.hasPrefix("enumerateWorkingSetChanges") }.isEmpty,
            "0.1.2 had no fallback to ask")
    }

    /// The other half of the fix: a backoff is lifted only by
    /// `signalErrorResolved(.serverUnreachable)` - a signalled enumerator is re-scheduled,
    /// not un-throttled (`MQ-037`) - and the extension makes that call on its first
    /// success after a failure.
    ///
    /// The failure here is the one case where `.serverUnreachable` is honest and neither
    /// source can answer: the agent is mid-reconcile, so it answers `indexReady` no *and*
    /// refuses the change stream itself (section 5.3). The recovery is on the same
    /// instance, which is the only life in which the extension can see both.
    func testA2_TheThrottleIsClearedOnTheFirstSuccessAfterAFailure() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()
        try harness.serverCreates("late.txt")

        harness.agent.indexReadyAnswer = false
        try harness.writer.setReconciling(true)
        domain.signalWorkingSet()
        XCTAssertNotEqual(domain.throttleState, .none)
        XCTAssertEqual(domain.consecutiveErrors, 1)
        XCTAssertEqual(domain.errorGeneration, 1)
        XCTAssertEqual(harness.finderListing(), [])

        // A signal while the stream is backing off never reaches the extension at all -
        // which is what `sshdrive debug signal` did on the field machine, and why the log
        // showed no extension line.
        domain.signalWorkingSet()
        XCTAssertTrue(domain.calls.contains(.signalDroppedByThrottle), "MQ-005/MQ-037")

        // The reconcile finishes. The live instance re-asks readiness, gets a yes, answers
        // from its own reader, notices it is recovering and makes the one call that lifts
        // the backoff.
        try harness.writer.setReconciling(false)
        harness.agent.indexReadyAnswer = true
        harness.system.advance(60 * 60)
        domain.retryWorkingSetOnLiveInstance()

        XCTAssertTrue(domain.calls.contains(.signalErrorResolved), "MQ-037")
        XCTAssertEqual(domain.throttleState, .none)
        XCTAssertEqual(harness.finderListing(), ["late.txt"])
        // The generation does not fall: fileproviderd counts errors for ever and only the
        // retry schedule is reset.
        XCTAssertEqual(domain.errorGeneration, 1)
    }

    // MARK: A3 - Reader-not-ready on a fresh instance

    /// `indexReady` delayed past the first `enumerateChanges`; one working-set signal.
    ///
    /// The provider asks the agent over `AgentChannel` instead of failing, and the change
    /// is delivered from the agent's identical query - both sides run `IndexChangeStream`.
    func testA3_AFreshInstanceWithANotReadyReaderAsksTheAgent() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()
        // The first ask of the instance the signal launches answers no; a later one would
        // answer yes, which is what "a window, not a verdict" means.
        harness.agent.indexReadyAnswerForAsk = { ask in ask == 1 ? true : (ask == 2 ? false : true) }
        try harness.serverCreates("note.txt")
        domain.signalWorkingSet()

        XCTAssertEqual(harness.finderListing(), ["note.txt"])
        XCTAssertTrue(
            harness.agent.calls.contains { $0.hasPrefix("enumerateWorkingSetChanges") },
            "the fallback is the answer, not an error")
        XCTAssertEqual(domain.throttleState, .none)
        XCTAssertFalse(domain.calls.contains(.enumerationFailed("serverUnreachable")))
    }

    // MARK: A4 - `currentSyncAnchor` must not invent 0

    /// The reader not usable, rows past sequence 0, and the system asking for the current
    /// anchor. The answer comes from the agent, not `0`, and no `syncAnchorExpired` is
    /// provoked.
    func testA4_CurrentSyncAnchorComesFromTheAgentAndNotZero() throws {
        let harness = try ScenarioHarness()
        for index in 0..<5 { try harness.serverCreates("f\(index).txt") }
        try harness.writer.pruneAnchors(maximumRows: 2)
        harness.agent.indexReadyAnswer = false
        let domain = try harness.addDomain()

        let anchor = try XCTUnwrap(domain.askWorkingSetAnchor())
        XCTAssertNotEqual(anchor.rawValue, "0", "a 0 is an expired anchor as soon as rows are past it")
        XCTAssertEqual(anchor.sequence, try harness.writer.currentSequence())
        XCTAssertTrue(harness.agent.calls.contains("currentAnchor"))

        // And enumerating from it provokes nothing.
        domain.signalWorkingSet()
        XCTAssertEqual(domain.throttleState, .none)
        XCTAssertEqual(harness.agent.anchorExpiryReports, [])

        // The old answer would have been 0, and from 0 the same index is expired.
        XCTAssertThrowsError(try harness.writer.changes(since: 0)) {
            XCTAssertEqual($0 as? IndexError, .syncAnchorExpired)
        }
    }

    // MARK: A5 - Anchor expiry reports once and sweeps once

    /// Rows trimmed past the system's anchor, then `enumerateChanges` from the stale
    /// anchor. `.syncAnchorExpired` is answered, `reportAnchorExpired` is called exactly
    /// once, and exactly one full sweep runs (`MQ-006`).
    func testA5_AnchorExpiryReportsOnceAndSweepsOnce() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()
        XCTAssertEqual(domain.heldWorkingSetAnchor?.sequence, 0)

        for index in 0..<5 { try harness.serverCreates("f\(index).txt") }
        try harness.writer.pruneAnchors(maximumRows: 2)

        domain.signalWorkingSet()

        XCTAssertEqual(harness.agent.anchorExpiryReports.count, 1)
        XCTAssertEqual(harness.agent.fullSweeps, 1, "one expiry, one full sweep of the root set")
        XCTAssertTrue(
            domain.calls.contains(.enumerationFailed("syncAnchorExpired")),
            "the system has to be told, or it keeps the dead anchor")
        // MQ-006: the system re-asks from a fresh anchor rather than giving up, and an
        // expiry is not something the fetch-event stream is throttled for.
        XCTAssertEqual(domain.throttleState, .none)
        XCTAssertEqual(
            domain.heldWorkingSetAnchor?.sequence, try harness.writer.currentSequence())
    }

    // MARK: A6 - A folder is enumerated once, ever

    /// A listed folder, revisited, changed on the server, revisited again. Exactly one
    /// `enumerateItems`, no `enumerateChanges` on the container, and the change arrives
    /// through the working set (`MQ-001`).
    func testA6_AFolderIsEnumeratedOnceEver() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("a.txt")
        let domain = try harness.addDomain()

        domain.openFolder()
        domain.openFolder()
        try harness.serverCreates("b.txt")
        domain.openFolder()

        let enumerations = domain.callCount {
            if case .enumerateItems(let container, _) = $0 {
                return container == ProviderItemIdentifier.rootContainer.rawValue
            }
            return false
        }
        XCTAssertEqual(enumerations, 1, "MQ-001")
        XCTAssertEqual(
            domain.callCount {
                if case .enumerateContainerChanges = $0 { return true }
                return false
            }, 0, "the system never asks a container for changes")
        XCTAssertEqual(harness.finderListing(), ["a.txt"], "the new file is not there yet")

        domain.signalWorkingSet()
        XCTAssertEqual(harness.finderListing(), ["a.txt", "b.txt"])
    }

    // MARK: A7 - A new sibling needs a working-set signal

    /// A folder already listed; the agent creates a conflict copy in it. Without the
    /// signal Finder never shows it; with it, it appears.
    func testA7_ANewSiblingNeedsAWorkingSetSignal() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("report.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        XCTAssertEqual(harness.finderListing(), ["report.txt"])

        // The conflict copy of section 5.5, written by the agent into a folder the system
        // has already enumerated and will never enumerate again.
        try harness.serverCreates("report (conflicted copy).txt")
        domain.openFolder()
        harness.system.advance(10 * 60)
        XCTAssertEqual(
            harness.finderListing(), ["report.txt"],
            "ten minutes of nothing is what the field report described")

        domain.signalWorkingSet()
        XCTAssertEqual(
            harness.finderListing(), ["report (conflicted copy).txt", "report.txt"])
    }

    // MARK: A8 - A 60 s `enumerateItems` is not taken away

    /// A transport hang of 60 s under one `enumerateItems`. The call completes at ~60 s,
    /// the answer is taken, and the provider instance survives (`MQ-007`, measured at
    /// 60.19 s).
    func testA8_ASixtySecondEnumerateItemsIsNotTakenAway() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("slow.txt")
        let domain = try harness.addDomain()
        let instancesBefore = domain.instancesLaunched
        harness.agent.enumerateItemsDelay = 60

        domain.openFolder()
        XCTAssertEqual(harness.finderListing(), [], "still in flight")
        XCTAssertNotNil(domain.provider, "the instance is not torn down under it")

        harness.system.advance(60)
        XCTAssertEqual(harness.finderListing(), ["slow.txt"], "the answer is taken")
        XCTAssertEqual(domain.instancesLaunched, instancesBefore, "the same instance answered")
        XCTAssertFalse(domain.calls.contains(.enumerationFailed("serverUnreachable")))
    }

    // MARK: A9 - The working set enumerates no items

    /// `enumerateItems` on the working set: zero items, `finishEnumerating(upTo: nil)`
    /// (`MQ-002`).
    func testA9_TheWorkingSetEnumeratesNoItems() throws {
        let harness = try ScenarioHarness()
        for index in 0..<3 { try harness.serverCreates("f\(index).txt") }
        let domain = try harness.addDomain()

        let listing = domain.enumerateWorkingSetItems()
        XCTAssertTrue(listing.items.isEmpty)
        XCTAssertTrue(listing.didFinish)
        XCTAssertNil(listing.finishedUpTo)
        XCTAssertEqual(domain.replica.count, 0, "and the system ingests nothing from it")
    }
}
