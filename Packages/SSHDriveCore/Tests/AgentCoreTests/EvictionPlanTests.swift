import Foundation
import XCTest
@testable import AgentCore
import Config

/// DESIGN.md section 7's TTL rule, with the clock as an argument. Nothing here sleeps and
/// nothing touches a replica: the five-minute timer and the `evictItem` call are the
/// agent's, and everything they decide is decided here.
final class EvictionPlanTests: XCTestCase {

    private let now: Double = 1_800_000_000

    private func candidate(
        _ name: String, kept: Bool = false, directory: Bool = false, localOnly: Bool = false,
        lastFetch: Double? = nil, mtime: Double = 0, atime: Double? = nil, size: Int64 = 100
    ) -> EvictionPlan.Candidate {
        EvictionPlan.Candidate(
            identifier: "id-\(name)", path: name, isDirectory: directory,
            isLocalOnly: localOnly, kept: kept, size: size, lastFetch: lastFetch,
            mtime: mtime, atime: atime)
    }

    private func decision(
        _ candidate: EvictionPlan.Candidate, ttl: TimeInterval?
    ) -> EvictionPlan.Decision {
        EvictionPlan.decide([candidate], ttl: ttl, now: now)[0]
    }

    // MARK: "last use = the later of the fetch and the save"

    func testLastUseIsTheLaterOfTheFetchAndTheSave() {
        XCTAssertEqual(
            EvictionPlan.lastUse(candidate("a", lastFetch: now - 100, mtime: now - 500)),
            now - 100)
        XCTAssertEqual(
            EvictionPlan.lastUse(candidate("b", lastFetch: now - 900, mtime: now - 100)),
            now - 100)
    }

    func testAFreshAtimeDoesNotSaveAStaleFile() {
        // 2026-09-05: something in the system advances a materialized file's atime minutes
        // after the fetch, with no read of ours near it, so atime is reported and not
        // decided on. With it in the `max` a file fetched 280 s earlier survived a 60 s
        // TTL because its atime was 23 s old.
        let item = candidate("a", lastFetch: now - 5000, mtime: now - 5000, atime: now - 5)
        XCTAssertEqual(EvictionPlan.lastUse(item), now - 5000)
        XCTAssertTrue(decision(item, ttl: 900).evict)
    }

    func testAFailedStatChangesNothing() {
        // atime is nil when the `lstat` failed, and the answer is the same either way.
        let item = candidate("a", lastFetch: now - 100, mtime: now - 500, atime: nil)
        XCTAssertEqual(EvictionPlan.lastUse(item), now - 100)
        XCTAssertFalse(decision(item, ttl: 900).evict)
    }

    // MARK: The TTL itself

    func testAFileOlderThanTheTTLIsEvicted() {
        let item = candidate("old", lastFetch: now - 1000, mtime: now - 1000, atime: now - 1000)
        let outcome = decision(item, ttl: 900)
        XCTAssertTrue(outcome.evict)
        XCTAssertNil(outcome.skip)
        XCTAssertEqual(outcome.ageSeconds, 1000)
    }

    func testAFileTouchedSinceTheTTLIsKept() {
        let item = candidate("fresh", lastFetch: now - 1000, mtime: now - 10, atime: now - 1000)
        let outcome = decision(item, ttl: 900)
        XCTAssertFalse(outcome.evict)
        XCTAssertEqual(outcome.skip, .withinTTL)
    }

    func testTheBoundaryIsStrictlyGreater() {
        // Section 7 step 3: "if now - lastUse > TTL".
        let exactly = candidate("edge", lastFetch: now - 900, mtime: 0, atime: nil)
        XCTAssertFalse(decision(exactly, ttl: 900).evict)
        let justPast = candidate("edge", lastFetch: now - 901, mtime: 0, atime: nil)
        XCTAssertTrue(decision(justPast, ttl: 900).evict)
    }

    func testASaveCountsAsUseEvenWithNoFetchAndNoRead() {
        // "mtime counts because a file the user saved but never re-read was used."
        let saved = candidate("saved", lastFetch: nil, mtime: now - 10, atime: nil)
        XCTAssertFalse(decision(saved, ttl: 900).evict)
    }

    func testNeverEvictsNothing() {
        let ancient = candidate("ancient", lastFetch: 0, mtime: 0, atime: 0)
        let outcome = decision(ancient, ttl: CacheTTL.never.seconds)
        XCTAssertFalse(outcome.evict)
        XCTAssertEqual(outcome.skip, .ttlNever)
    }

    func testEveryTTLValueMapsToTheSecondsSectionSevenLists() {
        XCTAssertEqual(CacheTTL.fifteenMinutes.seconds, 900)
        XCTAssertEqual(CacheTTL.oneHour.seconds, 3600)
        XCTAssertEqual(CacheTTL.twelveHours.seconds, 43200)
        XCTAssertEqual(CacheTTL.oneDay.seconds, 86400)
        XCTAssertEqual(CacheTTL.oneWeek.seconds, 604_800)
        XCTAssertEqual(CacheTTL.oneMonth.seconds, 2_592_000)
        XCTAssertNil(CacheTTL.never.seconds)
    }

    // MARK: What the loop skips whatever the clock says

    func testAKeptItemIsNeverEvicted() {
        let item = candidate("pinned", kept: true, lastFetch: 0, mtime: 0, atime: 0)
        let outcome = decision(item, ttl: 900)
        XCTAssertFalse(outcome.evict)
        XCTAssertEqual(outcome.skip, .kept)
    }

    func testADirectoryIsSkippedBecauseATTLIsPerFile() {
        // Not because a directory cannot be evicted: `evictItem` on one is recursive
        // (S4, 2026-09-04), which is what `evict --all` uses on the root container.
        let item = candidate("Docs", directory: true, lastFetch: 0, mtime: 0, atime: 0)
        XCTAssertEqual(decision(item, ttl: 900).skip, .directory)
    }

    func testALocalOnlyRowIsSkipped() {
        // Section 5.4: there is nothing on the server to fetch back.
        let item = candidate(".DS_Store", localOnly: true, lastFetch: 0, mtime: 0, atime: 0)
        XCTAssertEqual(decision(item, ttl: 900).skip, .localOnly)
    }

    // MARK: A whole pass

    func testAPassEvictsTheStalestFirstAndSkipsTheRest() {
        let candidates = [
            candidate("fresh", lastFetch: now - 60),
            candidate("stale", lastFetch: now - 5000),
            candidate("staler", lastFetch: now - 9000),
            candidate("kept", kept: true, lastFetch: 0),
            candidate("dir", directory: true, lastFetch: 0),
        ]
        XCTAssertEqual(
            EvictionPlan.identifiersToEvict(candidates, ttl: 900, now: now),
            ["id-staler", "id-stale"])
    }

    func testTotalsCountFilesOnlyAndSplitOutTheKept() {
        let totals = EvictionPlan.totals([
            candidate("a", size: 100),
            candidate("b", kept: true, size: 250),
            candidate("Docs", directory: true, size: 4096),
        ])
        XCTAssertEqual(totals.files, 2)
        XCTAssertEqual(totals.bytes, 350)
        XCTAssertEqual(totals.keptFiles, 1)
        XCTAssertEqual(totals.keptBytes, 250)
    }
}
