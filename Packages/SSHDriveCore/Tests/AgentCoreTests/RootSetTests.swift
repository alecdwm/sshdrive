import Foundation
import XCTest
@testable import AgentCore

/// DESIGN.md section 6.5, rule by rule. Times are arguments, so the rotation and the cap
/// are exact and nothing sleeps.
final class RootSetTests: XCTestCase {

    private func path(_ text: String) -> Data { Data(text.utf8) }

    private func entry(_ text: String, _ reasons: Set<RootReason>,
                       lastSeen: Double = 0, lastListed: Double = 0) -> RootSet.Entry {
        RootSet.Entry(path: path(text), reasons: reasons, lastSeen: lastSeen, lastListed: lastListed)
    }

    // MARK: The tier 0 rotation

    func testACycleTakesAtMostSixtyFourMaterializedOnlyRoots() {
        let entries = (0..<200).map { entry("m/\($0)", [.materialized], lastListed: Double($0)) }
        let set = RootSet(entries: entries)
        let cycle = set.tier0Cycle()
        XCTAssertEqual(cycle.count, RootSet.materializedPerCycle)
        // Round-robin "in order of least recent listing": the sixty-four oldest.
        XCTAssertEqual(cycle, (0..<64).map { path("m/\($0)") })
    }

    func testTheRotationPicksTheLeastRecentlyListedAndNotTheOrderOfTheTable() {
        let set = RootSet(entries: [
            entry("a", [.materialized], lastListed: 300),
            entry("b", [.materialized], lastListed: 100),
            entry("c", [.materialized], lastListed: 200),
        ])
        XCTAssertEqual(set.tier0Cycle(perCycle: 2), [path("b"), path("c")])
    }

    func testViewedAndPinnedRootsAreAlwaysInTheCycle() {
        var entries = (0..<100).map { entry("m/\($0)", [.materialized], lastListed: Double($0)) }
        entries.append(entry("Photos", [.pinned]))
        entries.append(entry("Docs", [.viewed], lastSeen: 5))
        // A directory that holds cached files *and* has been enumerated is not rotated:
        // it is in every cycle for its `viewed` reason and takes no rotation slot.
        entries.append(entry("Both", [.materialized, .viewed], lastSeen: 5))
        let set = RootSet(entries: entries)
        let cycle = set.tier0Cycle(perCycle: 4)
        XCTAssertEqual(Array(cycle.prefix(3)), [path("Photos"), path("Docs"), path("Both")])
        XCTAssertEqual(cycle.count, 3 + 4)
        XCTAssertTrue(cycle.contains(path("m/0")))
        XCTAssertFalse(cycle.contains(path("m/50")))
    }

    func testAFullSweepSuspendsTheRotationForThatOneCycle() {
        let entries = (0..<200).map { entry("m/\($0)", [.materialized], lastListed: Double($0)) }
        let set = RootSet(entries: entries)
        // Section 6.4: "at tier 0 a readdir of every root with the rotation of section 6.5
        // suspended for that one cycle".
        XCTAssertEqual(set.tier0Cycle(fullSweep: true).count, 200)
        XCTAssertEqual(set.tier0Cycle(fullSweep: false).count, 64)
    }

    func testRotationPeriodIsCeilingOfMOverSixtyFour() {
        func period(_ count: Int) -> Int {
            RootSet(entries: (0..<count).map { entry("m/\($0)", [.materialized]) }).rotationPeriod()
        }
        XCTAssertEqual(period(0), 0)
        XCTAssertEqual(period(1), 1)
        XCTAssertEqual(period(64), 1)
        XCTAssertEqual(period(65), 2)
        XCTAssertEqual(period(128), 2)
        XCTAssertEqual(period(129), 3)
        // Only materialized-only roots rotate, so a viewed one does not lengthen it.
        let mixed = RootSet(entries: (0..<64).map { entry("m/\($0)", [.materialized]) }
            + [entry("v", [.viewed])])
        XCTAssertEqual(mixed.rotationPeriod(), 1)
    }

    // MARK: The 256-entry viewed cap

    func testTheViewedCapEvictsTheLeastRecentlyEnumerated() {
        // 260 enumerated directories, `lastSeen` ascending with the index.
        let entries = (0..<260).map { entry("v/\($0)", [.viewed], lastSeen: Double($0)) }
        let set = RootSet(entries: entries)
        let evicted = set.viewedEvictions()
        XCTAssertEqual(evicted.count, 4)
        // Least recently enumerated first.
        XCTAssertEqual(evicted, (0..<4).map { path("v/\($0)") })
    }

    func testTheViewedCapEvictsNothingUnderIt() {
        let entries = (0..<RootSet.viewedCap).map { entry("v/\($0)", [.viewed], lastSeen: Double($0)) }
        XCTAssertEqual(RootSet(entries: entries).viewedEvictions(), [])
    }

    func testOnlyTheViewedReasonIsCounted() {
        // A thousand materialized roots do not push a single viewed one out: section 6.5
        // caps the viewed set, and "the materialized reason is not capped, since dropping
        // a directory from it would leave cached files in it unwatched".
        let entries = (0..<1000).map { entry("m/\($0)", [.materialized]) } + [entry("v", [.viewed])]
        XCTAssertEqual(RootSet(entries: entries).viewedEvictions(cap: 4), [])
    }

    // MARK: Pin roots

    func testADirectoryUnderAPinRootIsExcludedFromViewedAndMaterialized() {
        let set = RootSet(entries: [entry("Photos", [.pinned])])
        // Section 6.5: "a directory under a recursive pin root is never added to it, since
        // the pin's recursive watch already covers it", and the same for materialized.
        XCTAssertTrue(set.isUnderPinRoot(path("Photos/2024")))
        XCTAssertTrue(set.isUnderPinRoot(path("Photos/2024/June")))
        // The pin root itself is in the set on its own account, not under itself.
        XCTAssertFalse(set.isUnderPinRoot(path("Photos")))
        // The separator test: a sibling that shares a prefix is not under it.
        XCTAssertFalse(set.isUnderPinRoot(path("Photos2")))
        XCTAssertFalse(set.isUnderPinRoot(path("Photos2/2024")))
        XCTAssertFalse(set.isUnderPinRoot(path("Docs")))
    }

    func testTheLocationRootAsAPinRootContainsEverythingButItself() {
        let set = RootSet(entries: [entry("", [.pinned])])
        XCTAssertTrue(set.isUnderPinRoot(path("anything")))
        XCTAssertTrue(set.isUnderPinRoot(path("a/b/c")))
        XCTAssertFalse(set.isUnderPinRoot(Data()))
    }

    func testContainmentIsByteWiseAndSurvivesANameThatIsNotUTF8() {
        // 0xFF is not valid UTF-8, and neither is 0xFE. Decoded lossily both become U+FFFD
        // and the two directories would compare equal, so a String comparison here would
        // put one directory's children under the other's pin.
        let pin = Data([0x70, 0xFF])
        let child = Data([0x70, 0xFF, 0x2F, 0x78])
        let other = Data([0x70, 0xFE, 0x2F, 0x78])
        let set = RootSet(entries: [RootSet.Entry(path: pin, reasons: [.pinned])])
        XCTAssertTrue(set.isUnderPinRoot(child))
        XCTAssertFalse(set.isUnderPinRoot(other))
        XCTAssertEqual(String(decoding: Data([0x70, 0xFF]), as: UTF8.self),
                       String(decoding: Data([0x70, 0xFE]), as: UTF8.self))
    }

    func testContainmentOnASliceThatDoesNotStartAtZero() {
        // Data slices keep their parent's indices, so a comparison written with integer
        // subscripts would read the wrong bytes here.
        let backing = Data("xxxxPhotos/2024".utf8)
        let sliced = backing.dropFirst(4)
        XCTAssertTrue(RootSet.isStrictlyUnder(sliced, root: path("Photos")))
        XCTAssertFalse(RootSet.isStrictlyUnder(sliced, root: path("Docs")))
    }

    // MARK: Tier 1

    func testSweepRootsSplitsShallowFromRecursive() {
        let set = RootSet(entries: [
            entry("Docs", [.viewed]),
            entry("Cache", [.materialized]),
            entry("Photos", [.pinned]),
            entry("Mixed", [.materialized, .viewed]),
            entry("Pinned2", [.pinned, .materialized]),
        ])
        let roots = set.sweepRoots()
        // Shallow roots take -maxdepth 1; the pin roots are the recursive ones.
        XCTAssertEqual(roots.shallow, [path("Docs"), path("Cache"), path("Mixed")])
        XCTAssertEqual(roots.recursive, [path("Photos"), path("Pinned2")])
    }

    func testAShallowRootUnderAPinRootIsNotSentTwice() {
        // The pin-root exclusion of section 6.5 should have kept it out of the set at all;
        // if it slipped in, the recursive find already walks it.
        let set = RootSet(entries: [
            entry("Photos", [.pinned]),
            entry("Photos/2024", [.materialized]),
            entry("Docs", [.materialized]),
        ])
        let roots = set.sweepRoots()
        XCTAssertEqual(roots.shallow, [path("Docs")])
        XCTAssertEqual(roots.recursive, [path("Photos")])
    }
}
