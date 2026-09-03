import XCTest
@testable import Index
import XPCProtocols

final class IndexTests: XCTestCase {

    private var directory: URL!
    private var indexPath: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexPath = directory.appendingPathComponent("index.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ identifier: String, _ path: String, parent: String) -> IndexItem {
        IndexItem(
            identifier: identifier,
            path: Data(path.utf8),
            parent: parent,
            type: "file",
            size: 10,
            mtime: 1_700_000_000,
            contentVersion: IndexItem.contentVersion(size: 10, mtime: 1_700_000_000, generation: 0))
    }

    /// Section 7.1.1's three explicit states each have to reach the extension as a
    /// different `contentPolicy`, and the excluded one is the whole reason S6 can check
    /// that a lazy child overrides an eager ancestor.
    func testPinMarkerDecidesTheContentPolicy() throws {
        var row = item("id-p", "Projects", parent: IndexWriter.rootIdentifier)
        XCTAssertEqual(row.snapshot.contentPolicyRawValue, SSHDriveContentPolicy.unset.rawValue)

        row.pinState = 1
        row.kept = true
        XCTAssertEqual(
            row.snapshot.contentPolicyRawValue,
            SSHDriveContentPolicy.downloadEagerlyAndKeepDownloaded.rawValue)

        // Excluded: the marker is on the row, the effect is not kept, and the policy has
        // to be an explicit lazy rather than "no opinion", or the eager ancestor wins.
        row.pinState = -1
        row.kept = false
        XCTAssertEqual(
            row.snapshot.contentPolicyRawValue, SSHDriveContentPolicy.downloadLazily.rawValue)
    }

    func testCreatesSchemaAndRootRow() throws {
        let writer = try IndexWriter(path: indexPath)
        let root = try writer.ensureRoot()
        XCTAssertEqual(root.identifier, IndexWriter.rootIdentifier)
        XCTAssertTrue(root.path.isEmpty)
        XCTAssertEqual(try writer.meta(IndexSchema.MetaKey.schemaVersion), String(IndexSchema.version))
        // The root row is permanent, so a second call must not duplicate it.
        _ = try writer.ensureRoot()
        XCTAssertEqual(try writer.allItems().count, 1)
    }

    func testReaderSeesWhatTheWriterWrote() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(item("id-1", "a.txt", parent: IndexWriter.rootIdentifier))

        let reader = try IndexReader(path: indexPath)
        let row = try reader.item(identifier: "id-1")
        XCTAssertEqual(row.filename, "a.txt")
        XCTAssertEqual(row.contentVersion, "10-1700000000-0")
        XCTAssertEqual(try reader.children(ofParent: IndexWriter.rootIdentifier).count, 1)
    }

    func testReaderStallsWhileReconciling() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        let reader = try IndexReader(path: indexPath)
        try writer.setReconciling(true)
        XCTAssertThrowsError(try reader.item(identifier: IndexWriter.rootIdentifier)) { error in
            XCTAssertEqual(error as? IndexError, .reconciling)
        }
        try writer.setReconciling(false)
        XCTAssertNoThrow(try reader.item(identifier: IndexWriter.rootIdentifier))
    }

    func testDeletingARowWritesADeletionAnchorAndLeavesNoTombstone() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(item("id-1", "a.txt", parent: IndexWriter.rootIdentifier))
        try writer.delete(identifier: "id-1")
        XCTAssertNil(try writer.item(identifier: "id-1"))
        let anchors = try writer.anchors()
        XCTAssertEqual(anchors.first?.identifier, "id-1")
        XCTAssertEqual(anchors.first?.kind, .deleted)
    }

    func testChangeStreamAndAnchorExpiry() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        let reader = try IndexReader(path: indexPath)

        let start = try reader.currentSequence()
        try writer.upsert(item("id-1", "a.txt", parent: IndexWriter.rootIdentifier))
        try writer.appendAnchor(identifier: "id-1", kind: .modified)
        let changes = try reader.changes(since: start)
        XCTAssertEqual(changes.entries.map(\.identifier), ["id-1"])
        XCTAssertFalse(changes.hasMore)

        // A rebuild, or pruning, is the only source of an expired anchor (section 5.3).
        try writer.expireAnchors()
        XCTAssertThrowsError(try reader.changes(since: start)) { error in
            XCTAssertEqual(error as? IndexError, .syncAnchorExpired)
        }
    }

    func testMovingADirectoryRewritesEveryDescendantPath() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(
            IndexItem(
                identifier: "dir", path: Data("Documents".utf8),
                parent: IndexWriter.rootIdentifier, type: "directory"))
        try writer.upsert(item("child", "Documents/a.txt", parent: "dir"))
        try writer.addRoot(path: Data("Documents".utf8), reason: "viewed")

        try writer.rewritePaths(from: Data("Documents".utf8), to: Data("Papers".utf8))

        XCTAssertEqual(try writer.item(identifier: "dir")?.path, Data("Papers".utf8))
        // The identifier survives the move, which is the whole point of the index.
        XCTAssertEqual(try writer.item(identifier: "child")?.path, Data("Papers/a.txt".utf8))
        XCTAssertEqual(try writer.roots().first?.path, Data("Papers".utf8))
    }

    func testBackupProducesAReadableCopy() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(item("id-1", "a.txt", parent: IndexWriter.rootIdentifier))
        let backup = directory.appendingPathComponent("index.sqlite.bak")
        try writer.backup(to: backup)
        let reader = try IndexReader(path: backup.path)
        XCTAssertEqual(try reader.item(identifier: "id-1").filename, "a.txt")
    }
}
