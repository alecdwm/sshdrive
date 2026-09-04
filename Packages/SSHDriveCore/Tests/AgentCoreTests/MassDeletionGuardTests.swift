import Foundation
import XCTest
@testable import AgentCore

/// DESIGN.md section 6.4's mass-deletion guard, both halves of it.
final class MassDeletionGuardTests: XCTestCase {

    private func path(_ text: String) -> Data { Data(text.utf8) }
    private func paths(_ count: Int) -> [Data] { (0..<count).map { path("item\($0)") } }

    private func input(directory: String = "Photos", isLocationRoot: Bool = false,
                       known: Int, missing: [Data], pending: Set<Data> = [],
                       alreadyHeld: [Data: Double] = [:], now: Double = 1000) -> MassDeletionGuard.Input {
        MassDeletionGuard.Input(directory: path(directory), isLocationRoot: isLocationRoot,
                                knownNonHiddenCount: known, missing: missing, pending: pending,
                                alreadyHeld: alreadyHeld, now: now)
    }

    // MARK: The size test

    func testNineteenOfFortyIsApplied() {
        // "at least half of a directory's known, non-hidden items and at least 20 of them":
        // nineteen fails the count even though it is nearly half.
        let missing = paths(19)
        let decision = MassDeletionGuard.evaluate(input(known: 40, missing: missing))
        XCTAssertEqual(decision.apply, missing)
        XCTAssertTrue(decision.hold.isEmpty)
        XCTAssertNil(decision.reason)
    }

    func testTwentyOfFortyIsHeld() {
        let missing = paths(20)
        let decision = MassDeletionGuard.evaluate(input(known: 40, missing: missing))
        XCTAssertTrue(decision.apply.isEmpty)
        XCTAssertEqual(decision.hold, missing)
        XCTAssertEqual(decision.reason, "20 deletions held in Photos")
    }

    func testTwentyOfSixtyIsAppliedBecauseItIsNotHalf() {
        let missing = paths(20)
        let decision = MassDeletionGuard.evaluate(input(known: 60, missing: missing))
        XCTAssertEqual(decision.apply, missing)
        XCTAssertTrue(decision.hold.isEmpty)
    }

    func testThirtyOfSixtyIsExactlyHalfAndIsHeld() {
        let missing = paths(30)
        let decision = MassDeletionGuard.evaluate(input(known: 60, missing: missing))
        XCTAssertEqual(decision.hold, missing)
    }

    func testAWholeSmallDirectoryVanishingIsStillApplied() {
        // Five of five is all of it, but five is not twenty, and a five-item directory
        // that was emptied is an ordinary `rm`, not an unmounted dataset.
        let missing = paths(5)
        let decision = MassDeletionGuard.evaluate(input(known: 5, missing: missing))
        XCTAssertEqual(decision.apply, missing)
    }

    // MARK: The location root

    func testEmptyingAPreviouslyNonEmptyRootIsHeldWhateverTheCount() {
        // "or would empty the root when the root previously held anything at all". This is
        // the unmounted-dataset case the guard was written for, and it can be three items.
        let missing = paths(3)
        let decision = MassDeletionGuard.evaluate(
            input(directory: "", isLocationRoot: true, known: 3, missing: missing))
        XCTAssertEqual(decision.hold, missing)
        XCTAssertEqual(decision.reason, "3 deletions held in the location root")
    }

    func testARootThatHeldNothingIsNotProtected() {
        let decision = MassDeletionGuard.evaluate(
            input(directory: "", isLocationRoot: true, known: 0, missing: []))
        XCTAssertTrue(decision.hold.isEmpty)
        XCTAssertNil(decision.reason)
    }

    func testOneItemGoingFromARootOfManyIsAppliedLikeAnyOtherDeletion() {
        let decision = MassDeletionGuard.evaluate(
            input(directory: "", isLocationRoot: true, known: 40, missing: paths(1)))
        XCTAssertEqual(decision.apply.count, 1)
        XCTAssertTrue(decision.hold.isEmpty)
    }

    // MARK: Pending items

    func testASinglePendingItemIsHeldOnItsOwn() {
        // S5, 2026-09-04: a pending edit on an item reported deleted comes back as a
        // createItem, is answered .filenameCollision because the path is still there, and
        // the system retries a collided create for ever with no alert. So the size test is
        // not consulted at all for a pending item.
        let missing = paths(1)
        let decision = MassDeletionGuard.evaluate(
            input(known: 100, missing: missing, pending: Set(missing)))
        XCTAssertEqual(decision.hold, missing)
        XCTAssertTrue(decision.apply.isEmpty)
        XCTAssertEqual(decision.reason, "1 deletion held in Photos")
    }

    func testOnlyThePendingItemIsHeldOutOfAnOtherwiseOrdinaryDiff() {
        let missing = paths(5)
        let decision = MassDeletionGuard.evaluate(
            input(known: 100, missing: missing, pending: [missing[2]]))
        XCTAssertEqual(decision.hold, [missing[2]])
        XCTAssertEqual(decision.apply, [missing[0], missing[1], missing[3], missing[4]])
    }

    func testAPendingItemStaysHeldEvenAfterBothRecheksHavePassed() {
        // It is held until the pending edit resolves, not until the clock says so: the
        // collision the hold prevents does not go away with time.
        let missing = paths(1)
        let decision = MassDeletionGuard.evaluate(
            input(known: 100, missing: missing, pending: Set(missing),
                  alreadyHeld: [missing[0]: 0], now: 100_000))
        XCTAssertEqual(decision.hold, missing)
        XCTAssertTrue(decision.apply.isEmpty)
    }

    // MARK: The two re-checks

    func testAHeldItemStillMissingAfterBothRecheksIsApplied() {
        let missing = paths(20)
        var held: [Data: Double] = [:]
        for path in missing { held[path] = 0 }
        // Five minutes in: the first re-check, still held.
        let atFive = MassDeletionGuard.evaluate(input(known: 40, missing: missing, alreadyHeld: held, now: 300))
        XCTAssertEqual(atFive.hold, missing)
        // Just under thirty minutes: still held.
        let atTwentyNine = MassDeletionGuard.evaluate(
            input(known: 40, missing: missing, alreadyHeld: held, now: 1799))
        XCTAssertEqual(atTwentyNine.hold, missing)
        // Thirty minutes: the deletions are applied, even though the size test would hold
        // them all over again.
        let atThirty = MassDeletionGuard.evaluate(
            input(known: 40, missing: missing, alreadyHeld: held, now: 1800))
        XCTAssertEqual(atThirty.apply, missing)
        XCTAssertTrue(atThirty.hold.isEmpty)
        XCTAssertNil(atThirty.reason)
    }

    func testAHeldItemThatReappearsIsNeitherAppliedNorHeld() {
        // "If they reappear, the hold is cleared and nothing was ever reported." The
        // listing mentioned it, so it is not in `missing` at all.
        let gone = path("item0")
        let back = path("item1")
        let decision = MassDeletionGuard.evaluate(
            input(known: 40, missing: [gone], alreadyHeld: [gone: 0, back: 0], now: 100))
        XCTAssertFalse(decision.apply.contains(back))
        XCTAssertFalse(decision.hold.contains(back))
        XCTAssertEqual(decision.hold, [gone])
    }

    func testRecheckTimesAreFiveMinutesThenThirty() {
        XCTAssertEqual(MassDeletionGuard.recheckTime(firstMissing: 1000, checksDone: 0), 1300)
        XCTAssertEqual(MassDeletionGuard.recheckTime(firstMissing: 1000, checksDone: 1), 2800)
        // Both done: there is nothing left to wait for.
        XCTAssertNil(MassDeletionGuard.recheckTime(firstMissing: 1000, checksDone: 2))
    }

    func testIsDueAgreesWhetherTheCallerCountedOrTheClockDid() {
        XCTAssertFalse(MassDeletionGuard.isDue(firstMissing: 0, now: 1799, checksDone: 0))
        XCTAssertTrue(MassDeletionGuard.isDue(firstMissing: 0, now: 1800, checksDone: 0))
        XCTAssertFalse(MassDeletionGuard.isDue(firstMissing: 0, now: 10, checksDone: 1))
        XCTAssertTrue(MassDeletionGuard.isDue(firstMissing: 0, now: 10, checksDone: 2))
    }

    // MARK: The status line

    func testTheReasonTakesTheDirectorysLastComponent() {
        // Fourteen pending edits under a deep path: the count is below the bulk test's
        // twenty, so this is the pending half of the guard holding them.
        let missing = paths(14)
        let decision = MassDeletionGuard.evaluate(
            input(directory: "Pictures/2024/Photos", known: 200, missing: missing,
                  pending: Set(missing)))
        // Section 8: "14 deletions held in Photos".
        XCTAssertEqual(decision.reason, "14 deletions held in Photos")
        XCTAssertEqual(decision.hold.count, 14)
    }

    func testTheConstantsAreTheOnesSectionSixFourStates() {
        XCTAssertEqual(MassDeletionGuard.minimumCount, 20)
        XCTAssertEqual(MassDeletionGuard.fractionNumerator, 1)
        XCTAssertEqual(MassDeletionGuard.fractionDenominator, 2)
        XCTAssertEqual(MassDeletionGuard.firstRecheck, 300)
        XCTAssertEqual(MassDeletionGuard.secondRecheck, 1800)
    }

    /// A listing infers the deletion of a directory, not of the file inside it. An
    /// `rm -rf Photos` on the server is one missing path, `Photos`, while the pending edit
    /// is on `Photos/2026/note.txt`; matching exactly would let the directory through and
    /// strand the save inside it, which is the case S5 measured (2026-09-04).
    func testADirectoryWhoseDescendantIsPendingIsHeld() {
        let decision = MassDeletionGuard.evaluate(
            MassDeletionGuard.Input(
                directory: Data(),
                isLocationRoot: true,
                knownNonHiddenCount: 40,
                missing: [Data("Photos".utf8)],
                pending: [Data("Photos/2026/note.txt".utf8)],
                now: 1_000))
        XCTAssertEqual(decision.hold, [Data("Photos".utf8)])
        XCTAssertTrue(decision.apply.isEmpty)
    }

    /// And a sibling that merely shares a prefix is not an ancestor.
    func testAPrefixSiblingIsNotAnAncestorOfAPendingPath() {
        let expanded = MassDeletionGuard.withAncestors([Data("photos/a/b.txt".utf8)])
        XCTAssertTrue(expanded.contains(Data("photos".utf8)))
        XCTAssertTrue(expanded.contains(Data("photos/a".utf8)))
        XCTAssertFalse(expanded.contains(Data("photos2".utf8)))
        XCTAssertFalse(expanded.contains(Data()), "the location root is never added")
    }

    /// A non-UTF-8 name is a path like any other: the expansion is byte-level.
    func testAncestorsOfANonUTF8Path() {
        var directory = Data("caf".utf8); directory.append(0xFF)
        var full = directory; full.append(contentsOf: Data("/inside.txt".utf8))
        let expanded = MassDeletionGuard.withAncestors([full])
        XCTAssertTrue(expanded.contains(directory))
    }
}
