import XCTest
@testable import Index
import Config
import XPCProtocols

/// Working-set readiness and its fallback (docs/design/extension.md,
/// docs/design/item-index.md).
///
/// The working set is the only enumeration the extension answers from its own read-only
/// reader, and it has exactly one answer for a reader it cannot use:
/// `.serverUnreachable`. Readiness is a window, not a one-time verdict: latching an
/// `indexReady` "no" for the life of the extension instance would hold it there for as
/// long as a domain restart takes, and fileproviderd throttles a change enumeration that
/// keeps failing, backing the domain's event stream off to tens of minutes while every
/// other path keeps working. So readiness is a window with a retry behind it, and there
/// is a second source for the same change stream; both are covered here.
final class WorkingSetFallbackTests: XCTestCase {

    private var directory: URL!
    private var indexPath: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexPath = directory.appendingPathComponent("index.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A row and its anchor, the way every caller in the agent writes one: `upsert` does
    /// not write an anchor of its own, the caller does (docs/design/item-index.md).
    private func write(_ writer: IndexWriter, _ identifier: String, _ path: String) throws {
        try writer.upsert(item(identifier, path))
        try writer.appendAnchor(identifier: identifier, kind: .modified)
    }

    private func item(_ identifier: String, _ path: String) -> IndexItem {
        IndexItem(
            identifier: identifier,
            path: Data(path.utf8),
            parent: IndexWriter.rootIdentifier,
            type: "file",
            size: 10,
            mtime: 1_700_000_000,
            contentVersion: IndexItem.contentVersion(size: 10, mtime: 1_700_000_000, generation: 0))
    }

    // MARK: Readiness is a window, not a verdict

    /// A "no" answer does not latch: the next read past the retry interval asks again,
    /// and a later "yes" makes the reader usable.
    func testANoAnswerDoesNotLatchForTheInstancesLife() {
        var readiness = IndexReaderReadiness(retryInterval: 2)
        XCTAssertTrue(readiness.shouldAsk(at: 0))
        readiness.answered(false, at: 0)
        XCTAssertFalse(readiness.canRead)

        // Straight after, no second round trip: two reads arriving together cost one.
        XCTAssertFalse(readiness.shouldAsk(at: 0.5))
        // Past the interval, ask again. This is the whole fix: before it, nothing did.
        XCTAssertTrue(readiness.shouldAsk(at: 2.0))
        readiness.answered(true, at: 2.0)
        XCTAssertTrue(readiness.canRead)
        // And a ready reader stops asking.
        XCTAssertFalse(readiness.shouldAsk(at: 10))
    }

    /// An agent that cannot be reached at all is not a "no": a missing agent is the case
    /// the direct reader exists for (docs/design/extension.md).
    func testAnUnreachableAgentLeavesTheReaderUsable() {
        var readiness = IndexReaderReadiness()
        readiness.answered(nil, at: 0)
        XCTAssertTrue(readiness.canRead)
    }

    /// A schema newer than this build understands is the one permanent answer, and it
    /// must survive a later "yes": waiting does not make an unknown schema readable.
    func testSchemaTooNewIsPermanentAndStopsTheRetries() {
        var readiness = IndexReaderReadiness()
        readiness.answered(true, at: 0)
        readiness.foundSchemaTooNew("schema 9")
        XCTAssertFalse(readiness.canRead)
        XCTAssertFalse(readiness.isRetryable)
        XCTAssertFalse(readiness.shouldAsk(at: 100))
        readiness.answered(true, at: 100)
        XCTAssertFalse(readiness.canRead)
    }

    /// A read that failed re-asks at once rather than waiting out the interval: the usual
    /// cause is the file being replaced under the reader, which the agent knows about.
    func testAFailedReadAsksAgainImmediately() {
        var readiness = IndexReaderReadiness(retryInterval: 60)
        readiness.answered(true, at: 0)
        readiness.failed("disk I/O error", at: 1)
        XCTAssertFalse(readiness.canRead)
        XCTAssertTrue(readiness.shouldAsk(at: 1))
        XCTAssertEqual(readiness.lastError, "disk I/O error")
    }

    /// The restore's close-and-reopen protocol is the agent's to lift, not `indexReady`'s.
    func testACloseIsLiftedOnlyByTheReopenCallback() {
        var readiness = IndexReaderReadiness()
        readiness.answered(true, at: 0)
        readiness.close()
        XCTAssertFalse(readiness.canRead)
        readiness.answered(true, at: 1)
        XCTAssertFalse(readiness.canRead, "indexReady must not reopen a reader shut for a truncate")
        readiness.reopen()
        XCTAssertTrue(readiness.canRead)
    }

    /// An instance the system tears down reports `exited`, which is its own state and not
    /// the restore's `closed`, and nothing after it brings the reader back.
    func testAShutdownIsFinalForTheInstance() {
        var readiness = IndexReaderReadiness()
        readiness.answered(true, at: 0)
        readiness.shutdown()
        XCTAssertEqual(readiness.state, .exited)
        XCTAssertFalse(readiness.canRead)
        XCTAssertFalse(readiness.isRetryable)
        XCTAssertFalse(readiness.shouldAsk(at: 100))

        // A late `indexReady` reply, a reopen, a failure or a schema finding arriving
        // after the teardown all leave it where it is.
        readiness.answered(true, at: 100)
        readiness.reopen()
        readiness.close()
        readiness.failed("disk I/O error", at: 101)
        readiness.foundSchemaTooNew("schema 9")
        XCTAssertEqual(readiness.state, .exited)
        XCTAssertFalse(readiness.canRead)
        XCTAssertNil(readiness.lastError)

        // From any other state it is `exited` too, except a schema too new, which
        // describes the index rather than the instance.
        var failed = IndexReaderReadiness()
        failed.failed("disk I/O error", at: 0)
        failed.shutdown()
        XCTAssertEqual(failed.state, .exited)
        XCTAssertEqual(failed.lastError, "disk I/O error")

        var closed = IndexReaderReadiness()
        closed.answered(true, at: 0)
        closed.close()
        closed.shutdown()
        XCTAssertEqual(closed.state, .exited)

        var tooNew = IndexReaderReadiness()
        tooNew.foundSchemaTooNew("schema 9")
        tooNew.shutdown()
        XCTAssertEqual(tooNew.state, .schemaTooNew)

        XCTAssertEqual(IndexReaderReadiness.State.exited.rawValue, "exited")
    }

    // MARK: The two sources agree

    /// The fallback is only safe if the agent answers the same question the reader does.
    /// Both run `IndexChangeStream`, and this is what says so.
    func testTheWriterAndTheReaderAnswerTheSameChangeStream() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try write(writer, "id-1", "a.txt")
        try write(writer, "id-2", "b.txt")
        let middle = try writer.currentSequence()
        try write(writer, "id-3", "c.txt")
        try writer.delete(identifier: "id-1")

        let reader = try IndexReader(path: indexPath)
        for anchor in [Int64(0), middle, try writer.currentSequence()] {
            let fromReader = try reader.changes(since: anchor)
            let fromWriter = try writer.changes(since: anchor)
            XCTAssertEqual(fromReader.entries, fromWriter.entries, "anchor \(anchor)")
            XCTAssertEqual(fromReader.newAnchor, fromWriter.newAnchor, "anchor \(anchor)")
            XCTAssertEqual(fromReader.hasMore, fromWriter.hasMore, "anchor \(anchor)")
        }

        // The one that matters for the mount: everything since the middle anchor is the
        // new file and the deletion, and nothing else.
        let tail = try writer.changes(since: middle)
        XCTAssertEqual(
            tail.entries.map(\.identifier).sorted(), ["id-1", "id-3"])
        XCTAssertEqual(
            tail.entries.first(where: { $0.identifier == "id-1" })?.kind, .deleted)
    }

    /// Paging agrees too, and `hasMore` is what becomes `moreComing:`.
    func testPagingAgreesAndReportsMoreComing() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        for index in 0..<10 { try write(writer, "id-\(index)", "f\(index).txt") }

        let reader = try IndexReader(path: indexPath)
        let readerPage = try reader.changes(since: 0, limit: 4)
        let writerPage = try writer.changes(since: 0, limit: 4)
        XCTAssertEqual(readerPage.entries.count, 4)
        XCTAssertTrue(readerPage.hasMore)
        XCTAssertEqual(readerPage.entries, writerPage.entries)
        XCTAssertEqual(readerPage.newAnchor, writerPage.newAnchor)
        XCTAssertTrue(writerPage.hasMore)

        let rest = try writer.changes(since: writerPage.newAnchor, limit: 100)
        XCTAssertFalse(rest.hasMore)
    }

    /// Expiry has to reach the system as `.syncAnchorExpired` from either source, or the
    /// fresh anchor is never handed out and the agent never runs its catch-up sweep.
    func testBothSourcesExpireTheSameAnchor() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        for index in 0..<5 { try write(writer, "id-\(index)", "f\(index).txt") }
        try writer.pruneAnchors(maximumRows: 2)

        let reader = try IndexReader(path: indexPath)
        XCTAssertThrowsError(try reader.changes(since: 0)) {
            XCTAssertEqual($0 as? IndexError, .syncAnchorExpired)
        }
        XCTAssertThrowsError(try writer.changes(since: 0)) {
            XCTAssertEqual($0 as? IndexError, .syncAnchorExpired)
        }
    }

    /// While a reconcile runs neither source answers with rows: the stall is the point
    /// (docs/design/item-index.md), and the fallback must not be a way around it.
    func testTheFallbackStallsWithTheReaderDuringAReconcile() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try write(writer, "id-1", "a.txt")
        try writer.setReconciling(true)

        let reader = try IndexReader(path: indexPath)
        XCTAssertThrowsError(try reader.changes(since: 0)) {
            XCTAssertEqual($0 as? IndexError, .reconciling)
        }
        XCTAssertThrowsError(try writer.changes(since: 0)) {
            XCTAssertEqual($0 as? IndexError, .reconciling)
        }

        try writer.setReconciling(false)
        XCTAssertEqual(try writer.changes(since: 0).entries.count, try reader.changes(since: 0).entries.count)
    }

    /// The page the fallback travels in has to carry `moreComing` across XPC, or a change
    /// stream longer than one page silently stops at the first.
    func testItemPageCarriesMoreComingThroughSecureCoding() throws {
        let page = SSHDriveItemPage(
            items: [], deletedIdentifiers: ["gone"], anchor: "42", moreComing: true)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: page, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: SSHDriveItemPage.self, from: data))
        XCTAssertEqual(decoded.anchor, "42")
        XCTAssertEqual(decoded.deletedIdentifiers, ["gone"])
        XCTAssertTrue(decoded.moreComing)
    }

    /// `doctor` reads the extension's state from a file the extension writes, so the path
    /// is part of the contract between two processes that never meet.
    func testTheReaderStateFileSitsBesideTheIndex() throws {
        guard let index = try? GroupContainer.indexURL(locationID: "abc"),
            let state = try? GroupContainer.readerStateURL(locationID: "abc")
        else {
            throw XCTSkip("no app group container in this test environment")
        }
        XCTAssertEqual(state.deletingLastPathComponent(), index.deletingLastPathComponent())
        XCTAssertEqual(state.lastPathComponent, "reader-state.json")
    }
}
