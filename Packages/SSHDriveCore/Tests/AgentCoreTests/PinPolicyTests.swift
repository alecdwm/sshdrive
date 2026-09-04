import Foundation
import XCTest
@testable import AgentCore

/// DESIGN.md section 7.1.1's one rule, its three invariants and its five-situation table.
/// No index, no clock, no File Provider: the markers are a value and the answers are exact.
final class PinPolicyTests: XCTestCase {

    private func path(_ text: String) -> Data { Data(text.utf8) }

    private func set(_ pairs: [(String, PinPolicy.Marker)]) -> PinMarkerSet {
        PinMarkerSet(markers: Dictionary(uniqueKeysWithValues: pairs.map { (path($0.0), $0.1) }))
    }

    // MARK: The effective state: "the nearest explicit state at or above it"

    func testNothingExplicitAnywhereIsNotKept() {
        XCTAssertFalse(PinPolicy.kept(markersNearestFirst: [.inherit, .inherit, .inherit]))
    }

    func testTheNearestExplicitStateWinsOverEveryOneAboveIt() {
        // Exclusion under a pin: not kept. Pin under that exclusion: kept again.
        XCTAssertFalse(PinPolicy.kept(markersNearestFirst: [.inherit, .excluded, .pinned]))
        XCTAssertTrue(PinPolicy.kept(markersNearestFirst: [.pinned, .excluded, .pinned]))
    }

    func testInheritanceDownAChain() {
        let markers = set([("Projects", .pinned), ("Projects/archive", .excluded)])
        XCTAssertTrue(markers.isKept(path("Projects")))
        XCTAssertTrue(markers.isKept(path("Projects/src")))
        XCTAssertTrue(markers.isKept(path("Projects/src/deep/deeper")))
        XCTAssertFalse(markers.isKept(path("Projects/archive")))
        XCTAssertFalse(markers.isKept(path("Projects/archive/2025/jan")))
        // A sibling of the pin root inherits nothing.
        XCTAssertFalse(markers.isKept(path("Photos")))
    }

    func testExclusionsNest() {
        // Section 7.1.1: "pin Projects, exclude Projects/archive, re-pin
        // Projects/archive/2026. Each level wins over the one above it."
        let markers = set([
            ("Projects", .pinned),
            ("Projects/archive", .excluded),
            ("Projects/archive/2026", .pinned),
        ])
        XCTAssertTrue(markers.isKept(path("Projects/archive/2026")))
        XCTAssertTrue(markers.isKept(path("Projects/archive/2026/q1/notes.txt")))
        XCTAssertFalse(markers.isKept(path("Projects/archive/2025")))
    }

    func testAPinnedRootKeepsTheWholeLocation() {
        // Section 7.1.2: the root is an item like any other, and everything below it is
        // then situation C.
        let markers = set([("", .pinned)])
        XCTAssertTrue(markers.isKept(path("")))
        XCTAssertTrue(markers.isKept(path("Videos/big.mov")))
        XCTAssertEqual(markers.situation(of: path("Videos")), .inheritingPin)
        XCTAssertEqual(markers.situation(of: path("")), .pinRoot)
    }

    func testContainmentIsByteWiseAndSeparatorAware() {
        let markers = set([("Photos", .pinned)])
        XCTAssertTrue(markers.isKept(path("Photos/2026")))
        // "Photos2" is not under "Photos".
        XCTAssertFalse(markers.isKept(path("Photos2")))
        // A name that is not valid UTF-8 is still a distinct path.
        var awkward = Data("Ph".utf8)
        awkward.append(0xFF)
        let byteSet = PinMarkerSet(markers: [awkward: .pinned])
        XCTAssertTrue(byteSet.isKept(awkward + Data("/inside".utf8)))
        XCTAssertFalse(byteSet.isKept(path("Photos")))
    }

    func testAncestorsAreNearestFirstAndEndAtTheRoot() {
        XCTAssertEqual(
            PinPolicy.ancestors(of: path("a/b/c")),
            [path("a/b"), path("a"), Data()])
        XCTAssertEqual(PinPolicy.ancestors(of: path("a")), [Data()])
        XCTAssertEqual(PinPolicy.ancestors(of: Data()), [])
    }

    // MARK: The five situations

    func testEverySituationIsRecognised() {
        let markers = set([
            ("Projects", .pinned),
            ("Projects/archive", .excluded),
        ])
        XCTAssertEqual(markers.situation(of: path("Photos")), .plain)                       // A
        XCTAssertEqual(markers.situation(of: path("Projects")), .pinRoot)                   // B
        XCTAssertEqual(markers.situation(of: path("Projects/src")), .inheritingPin)         // C
        XCTAssertEqual(markers.situation(of: path("Projects/archive")), .exclusionRoot)     // D
        XCTAssertEqual(markers.situation(of: path("Projects/archive/x")), .inheritingExclusion)  // E
    }

    // MARK: Invariant 3, minimal markers - the table's two columns

    func testSituationAPinWritesAPinAndUnpinIsANoOp() {
        let markers = set([])
        let pin = markers.plan(.keep, at: path("Docs"))
        XCTAssertEqual(pin.newMarker, .pinned)
        XCTAssertTrue(pin.clearsDescendants)
        XCTAssertTrue(pin.keptAfter)
        XCTAssertTrue(markers.plan(.dontKeep, at: path("Docs")).isNoOp)
    }

    func testSituationBUnpinRemovesThePinRatherThanAddingAnExclusion() {
        let markers = set([("Docs", .pinned)])
        let change = markers.plan(.dontKeep, at: path("Docs"))
        XCTAssertEqual(change.newMarker, .inherit)
        XCTAssertTrue(change.clearsDescendants)
        XCTAssertFalse(change.keptAfter)
    }

    func testSituationBPinReAssertsAndResetsTheSubtree() {
        // "Toggling the top folder off and on is the way to reset a complicated
        // pin/exclusion structure"; the pin half of that is a re-assert, not a no-op.
        let markers = set([("Docs", .pinned), ("Docs/raw", .excluded)])
        let change = markers.plan(.keep, at: path("Docs"))
        XCTAssertFalse(change.isNoOp)
        XCTAssertEqual(change.newMarker, .pinned)
        XCTAssertTrue(change.clearsDescendants)
        XCTAssertEqual(markers.explicitStatesBelow(path("Docs")), [path("Docs/raw")])
    }

    func testSituationCPinIsANoOpAndUnpinWritesAnExclusion() {
        let markers = set([("Docs", .pinned)])
        XCTAssertTrue(markers.plan(.keep, at: path("Docs/raw")).isNoOp)
        let change = markers.plan(.dontKeep, at: path("Docs/raw"))
        XCTAssertEqual(change.newMarker, .excluded)
        XCTAssertFalse(change.keptAfter)
    }

    func testSituationDPinRemovesTheExclusionWhenAPinIsStillAbove() {
        let markers = set([("Docs", .pinned), ("Docs/raw", .excluded)])
        let change = markers.plan(.keep, at: path("Docs/raw"))
        // Invariant 3: remove the exclusion rather than add a nested pin.
        XCTAssertEqual(change.newMarker, .inherit)
        XCTAssertTrue(change.keptAfter)
    }

    func testSituationDPinWritesAPinWhenTheExclusionHasNoPinAboveIt() {
        // "markers move with their paths, so an exclusion can end up with no pin above it."
        let markers = set([("moved", .excluded)])
        let change = markers.plan(.keep, at: path("moved"))
        XCTAssertEqual(change.newMarker, .pinned)
        XCTAssertTrue(change.keptAfter)
    }

    func testSituationDUnpinIsANoOpAndSoIsSituationE() {
        let markers = set([("Docs", .pinned), ("Docs/raw", .excluded)])
        XCTAssertTrue(markers.plan(.dontKeep, at: path("Docs/raw")).isNoOp)
        XCTAssertTrue(markers.plan(.dontKeep, at: path("Docs/raw/2026")).isNoOp)
    }

    func testSituationEPinReIncludesBelowTheExclusion() {
        let markers = set([("Docs", .pinned), ("Docs/raw", .excluded)])
        let change = markers.plan(.keep, at: path("Docs/raw/2026"))
        XCTAssertEqual(change.newMarker, .pinned)
        XCTAssertTrue(change.keptAfter)
    }

    func testUnpinningAPinNestedUnderAnotherPinExcludesIt() {
        // A redundant nested pin is never *created* (invariant 3), but one can arrive by a
        // move. "Don't keep" on it must not simply drop the marker, or the ancestor would
        // take it straight back.
        let markers = set([("a", .pinned), ("a/b", .pinned)])
        let change = markers.plan(.dontKeep, at: path("a/b"))
        XCTAssertEqual(change.newMarker, .excluded)
        XCTAssertFalse(change.keptAfter)
    }

    // MARK: Invariant 2, the subtree is cleared

    func testAnyChangeClearsEveryExplicitStateBeneathIt() {
        var markers = set([
            ("Projects", .pinned),
            ("Projects/archive", .excluded),
            ("Projects/archive/2026", .pinned),
            ("Photos", .pinned),
        ])
        let change = markers.plan(.dontKeep, at: path("Projects"))
        let cleared = markers.apply(change, at: path("Projects"))
        XCTAssertEqual(cleared, [path("Projects/archive"), path("Projects/archive/2026")])
        // Nothing under Projects is kept or excluded any more...
        XCTAssertFalse(markers.isKept(path("Projects/archive/2026")))
        XCTAssertEqual(markers.situation(of: path("Projects/archive")), .plain)
        // ...and a marker outside the subtree is untouched.
        XCTAssertTrue(markers.isKept(path("Photos/2026")))
    }

    func testTheOneCommandReset() {
        // "Don't Keep Downloaded" followed by "Keep Downloaded" on a pin root discards
        // every exclusion under it and starts downloading whatever they held.
        var markers = set([("Projects", .pinned), ("Projects/archive", .excluded)])
        markers.apply(markers.plan(.dontKeep, at: path("Projects")), at: path("Projects"))
        markers.apply(markers.plan(.keep, at: path("Projects")), at: path("Projects"))
        XCTAssertEqual(markers.pinRoots, [path("Projects")])
        XCTAssertTrue(markers.exclusions.isEmpty)
        XCTAssertTrue(markers.isKept(path("Projects/archive/anything")))
    }

    func testANoOpClearsNothing() {
        var markers = set([("Docs", .pinned), ("Docs/raw", .excluded)])
        let before = markers
        markers.apply(markers.plan(.keep, at: path("Docs/src")), at: path("Docs/src"))
        XCTAssertEqual(markers, before)
    }

    func testUnpinningTheRootClearsEveryMarkerInTheLocation() {
        // Section 7.1.2: "unpinning the root is situation B and, by invariant 2, clears
        // every marker in the location."
        var markers = set([("", .pinned), ("Videos", .excluded), ("a/b", .excluded)])
        let change = markers.plan(.dontKeep, at: Data())
        XCTAssertEqual(change.situation, .pinRoot)
        markers.apply(change, at: Data())
        XCTAssertTrue(markers.isEmpty)
    }

    // MARK: What the recursive watch prunes (sections 6.5, 7.1.1)

    func testPrunedExclusionsAreOnlyTheOnesInsideAPin() {
        let markers = set([
            ("Projects", .pinned),
            ("Projects/archive", .excluded),
            ("stray", .excluded),
        ])
        XCTAssertEqual(markers.prunedExclusions(), [path("Projects/archive")])
    }
}
