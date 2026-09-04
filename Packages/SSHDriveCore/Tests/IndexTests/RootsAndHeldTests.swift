import XCTest
@testable import Index

/// The change-detection root set (DESIGN.md section 6.5), the mass-deletion guard's held
/// table (section 6.4), and the restore-into-the-live-database half of section 5.3.
final class RootsAndHeldTests: XCTestCase {

    private var directory: URL!
    private var indexPath: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-roots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexPath = directory.appendingPathComponent("index.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func bytes(_ string: String) -> Data { Data(string.utf8) }

    // MARK: migration

    /// Writes the version 2 shape by hand: the tables as they were before milestone 6,
    /// with rows in them, and `meta.schema_version` at 2. The connection is local so it is
    /// closed by the time the writer opens the same file.
    private func makeVersion2Database() throws {
        let connection = try SQLiteConnection(path: indexPath, mode: .readWrite)
        try connection.execute("""
            CREATE TABLE roots (
                path BLOB NOT NULL,
                reason TEXT NOT NULL,
                last_seen REAL NOT NULL,
                PRIMARY KEY (path, reason)
            );
            CREATE TABLE held (
                path BLOB PRIMARY KEY,
                dir BLOB NOT NULL,
                first_missing REAL NOT NULL,
                recheck_at REAL NOT NULL
            );
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO meta (key, value) VALUES ('schema_version', '2');
            """)

        let root = try connection.prepare("INSERT INTO roots (path, reason, last_seen) VALUES (?1, ?2, ?3)")
        root.bind(1, bytes("Documents"))
        root.bind(2, "viewed")
        root.bind(3, 100.0)
        try root.run()

        let held = try connection.prepare(
            "INSERT INTO held (path, dir, first_missing, recheck_at) VALUES (?1, ?2, ?3, ?4)")
        held.bind(1, bytes("Documents/a.txt"))
        held.bind(2, bytes("Documents"))
        held.bind(3, 50.0)
        held.bind(4, 350.0)
        try held.run()
    }

    /// `CREATE TABLE IF NOT EXISTS` does not alter a table that is already there, so the
    /// added columns have to be applied explicitly - and the rows have to survive, since
    /// the index is the only copy of the identifiers we hold (section 5.3).
    func testAVersion2DatabaseIsMigratedInPlaceAndKeepsItsRows() throws {
        try makeVersion2Database()

        let writer = try IndexWriter(path: indexPath)
        XCTAssertEqual(try writer.meta(IndexSchema.MetaKey.schemaVersion), "3")

        let roots = try writer.rootRows()
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.path, bytes("Documents"))
        XCTAssertEqual(roots.first?.reason, "viewed")
        XCTAssertEqual(roots.first?.lastSeen, 100.0)
        // The new column arrives with its default: nothing has been listed yet.
        XCTAssertEqual(roots.first?.lastListed, 0)

        let held = try writer.heldRow(path: bytes("Documents/a.txt"))
        XCTAssertEqual(held?.dir, bytes("Documents"))
        XCTAssertEqual(held?.firstMissing, 50.0)
        XCTAssertEqual(held?.checks, 0)
        XCTAssertEqual(held?.reason, "")
    }

    /// Opening twice must be a no-op the second time: the migration is guarded by
    /// `PRAGMA table_info`, and a second `ALTER TABLE` for a column that is there is an
    /// error that would take the whole open with it.
    func testMigratingTwiceIsHarmless() throws {
        try makeVersion2Database()
        _ = try IndexWriter(path: indexPath)
        let second = try IndexWriter(path: indexPath)
        XCTAssertEqual(try second.meta(IndexSchema.MetaKey.schemaVersion), "3")
        XCTAssertEqual(try second.rootRows().count, 1)
    }

    // MARK: roots

    func testOneDirectoryCarriesSeveralReasonsAndLeavesWhenTheLastGoes() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.addRoot(path: bytes("Photos"), reason: "viewed")
        try writer.addRoot(path: bytes("Photos"), reason: "materialized")
        XCTAssertEqual(try writer.rootRows().count, 2)
        XCTAssertEqual(Set(try writer.rootRows().map(\.path)), [bytes("Photos")])

        // One reason at a time leaves the directory in the set (section 6.5).
        try writer.removeRoot(path: bytes("Photos"), reason: "viewed")
        XCTAssertEqual(try writer.rootRows().map(\.reason), ["materialized"])

        try writer.addRoot(path: bytes("Photos"), reason: "viewed")
        try writer.removeRoot(path: bytes("Photos"))
        XCTAssertTrue(try writer.rootRows().isEmpty)
    }

    /// The listing is of the directory, not of one reason for watching it, so the rotation
    /// key moves on every row - and the LRU key does not move at all, or a rotated
    /// `materialized` root would keep itself in the capped `viewed` set for ever.
    func testMarkRootListedMovesEveryReasonAndLeavesLastSeenAlone() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.addRoot(path: bytes("Photos"), reason: "viewed")
        try writer.addRoot(path: bytes("Photos"), reason: "materialized")
        let lastSeen = try writer.rootRows().map(\.lastSeen)

        try writer.markRootListed(path: bytes("Photos"), at: 1_700_000_500)

        let rows = try writer.rootRows()
        XCTAssertEqual(rows.map(\.lastListed), [1_700_000_500, 1_700_000_500])
        XCTAssertEqual(rows.map(\.lastSeen), lastSeen)
    }

    /// `status` reports the rotation period from the `materialized` count, which is
    /// `ceil(M / 64)` cycles (section 6.5).
    func testRootCountCountsOneReasonOnly() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.addRoot(path: bytes("a"), reason: "materialized")
        try writer.addRoot(path: bytes("b"), reason: "materialized")
        try writer.addRoot(path: bytes("a"), reason: "viewed")
        XCTAssertEqual(try writer.rootCount(reason: "materialized"), 2)
        XCTAssertEqual(try writer.rootCount(reason: "viewed"), 1)
        XCTAssertEqual(try writer.rootCount(reason: "pinned"), 0)
    }

    /// Least recently listed first, which is the order the rotation consumes the set in.
    func testRootRowsComeBackInRotationOrder() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.addRoot(path: bytes("old"), reason: "materialized")
        try writer.addRoot(path: bytes("new"), reason: "materialized")
        try writer.markRootListed(path: bytes("old"), at: 10)
        try writer.markRootListed(path: bytes("new"), at: 20)
        XCTAssertEqual(try writer.rootRows().map(\.path), [bytes("old"), bytes("new")])
    }

    /// A directory move rewrites `path` on the matching rows of `roots` and `held` in one
    /// transaction (section 5.3), and must carry the version 3 columns across with them.
    func testMovingADirectoryKeepsTheRotationKeyAndTheHoldsClock() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(
            IndexItem(
                identifier: "dir", path: bytes("Documents"),
                parent: IndexWriter.rootIdentifier, type: "directory"))
        try writer.addRoot(path: bytes("Documents"), reason: "materialized")
        try writer.markRootListed(path: bytes("Documents"), at: 111)
        try writer.hold(
            path: bytes("Documents/a.txt"), dir: bytes("Documents"),
            firstMissing: 50, recheckAt: 350, reason: "half of Documents went missing")
        try writer.noteHoldChecked(path: bytes("Documents/a.txt"), nextRecheckAt: 1_850)

        try writer.rewritePaths(from: bytes("Documents"), to: bytes("Papers"))

        let root = try writer.rootRows().first
        XCTAssertEqual(root?.path, bytes("Papers"))
        XCTAssertEqual(root?.lastListed, 111)

        let held = try writer.heldRow(path: bytes("Papers/a.txt"))
        XCTAssertEqual(held?.firstMissing, 50)
        XCTAssertEqual(held?.checks, 1)
        XCTAssertEqual(held?.reason, "half of Documents went missing")
        XCTAssertNil(try writer.heldRow(path: bytes("Documents/a.txt")))
    }

    // MARK: held

    func testHoldingAndReleasingOneDeletion() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.hold(
            path: bytes("Photos/a.jpg"), dir: bytes("Photos"),
            firstMissing: 100, recheckAt: 400, reason: "Photos emptied")

        let row = try writer.heldRow(path: bytes("Photos/a.jpg"))
        XCTAssertEqual(row?.dir, bytes("Photos"))
        XCTAssertEqual(row?.firstMissing, 100)
        XCTAssertEqual(row?.recheckAt, 400)
        XCTAssertEqual(row?.checks, 0)
        XCTAssertEqual(row?.reason, "Photos emptied")
        XCTAssertEqual(try writer.heldCount(), 1)

        // It reappeared, so nothing was ever reported (section 6.4).
        try writer.releaseHold(path: bytes("Photos/a.jpg"))
        XCTAssertNil(try writer.heldRow(path: bytes("Photos/a.jpg")))
        XCTAssertEqual(try writer.heldCount(), 0)
    }

    /// The deletions are applied after the second re-check counted from when the item was
    /// *first* seen missing. A re-list that finds it missing again must not restart that
    /// clock, or the hold would renew itself for ever, 5 minutes at a time.
    func testHoldingAnAlreadyHeldPathKeepsItsFirstMissingAndItsChecks() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.hold(
            path: bytes("Photos/a.jpg"), dir: bytes("Photos"),
            firstMissing: 100, recheckAt: 400, reason: "Photos emptied")
        try writer.noteHoldChecked(path: bytes("Photos/a.jpg"), nextRecheckAt: 1_900)
        XCTAssertEqual(try writer.heldRow(path: bytes("Photos/a.jpg"))?.checks, 1)

        try writer.hold(
            path: bytes("Photos/a.jpg"), dir: bytes("Photos"),
            firstMissing: 999, recheckAt: 2_500, reason: "still missing")

        let row = try writer.heldRow(path: bytes("Photos/a.jpg"))
        XCTAssertEqual(row?.firstMissing, 100)
        XCTAssertEqual(row?.checks, 1)
        // What the second hold does refresh: when to look again, and what to tell the user.
        XCTAssertEqual(row?.recheckAt, 2_500)
        XCTAssertEqual(row?.reason, "still missing")
    }

    func testNoteHoldCheckedCountsTheTwoRechecks() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.hold(
            path: bytes("Photos/a.jpg"), dir: bytes("Photos"),
            firstMissing: 0, recheckAt: 300, reason: "")
        try writer.noteHoldChecked(path: bytes("Photos/a.jpg"), nextRecheckAt: 1_800)
        XCTAssertEqual(try writer.heldRow(path: bytes("Photos/a.jpg"))?.checks, 1)
        XCTAssertEqual(try writer.heldRow(path: bytes("Photos/a.jpg"))?.recheckAt, 1_800)
        try writer.noteHoldChecked(path: bytes("Photos/a.jpg"), nextRecheckAt: 3_600)
        XCTAssertEqual(try writer.heldRow(path: bytes("Photos/a.jpg"))?.checks, 2)
    }

    /// The re-check works one directory at a time: one `readdir` answers for every item
    /// that went missing from it.
    func testHeldRowsByDirectory() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.hold(path: bytes("Photos/a.jpg"), dir: bytes("Photos"), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: bytes("Photos/b.jpg"), dir: bytes("Photos"), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: bytes("Docs/c.txt"), dir: bytes("Docs"), firstMissing: 0, recheckAt: 300, reason: "")

        XCTAssertEqual(try writer.heldRows(dir: bytes("Photos")).map(\.path),
                       [bytes("Photos/a.jpg"), bytes("Photos/b.jpg")])
        XCTAssertEqual(try writer.heldRows(dir: bytes("Docs")).count, 1)
        XCTAssertEqual(try writer.heldRows().count, 3)
    }

    /// Containment is decided on bytes: server names need not be UTF-8 (section 5.4), and
    /// the separator is required, so "photos2" is not under "photos".
    func testReleasingASubtreeTakesNonUTF8NamesAndSparesAPrefixSibling() throws {
        let writer = try IndexWriter(path: indexPath)
        let invalid = bytes("photos/") + Data([0xFF, 0xFE, 0x80])
        try writer.hold(path: bytes("photos"), dir: bytes(""), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: bytes("photos/a.jpg"), dir: bytes("photos"), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: invalid, dir: bytes("photos"), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: bytes("photos2/a.jpg"), dir: bytes("photos2"), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: bytes("photosaurus"), dir: bytes(""), firstMissing: 0, recheckAt: 300, reason: "")

        try writer.releaseHolds(under: bytes("photos"))

        XCTAssertEqual(
            try writer.heldRows().map(\.path),
            [bytes("photos2/a.jpg"), bytes("photosaurus")])
    }

    /// The location root is the empty path, and it contains everything (section 5.3).
    func testTheEmptyRootContainsEveryHeldPath() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.hold(path: bytes("a"), dir: bytes(""), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.hold(path: bytes("b/c"), dir: bytes("b"), firstMissing: 0, recheckAt: 300, reason: "")
        try writer.releaseHolds(under: Data())
        XCTAssertEqual(try writer.heldCount(), 0)
    }

    // MARK: restore

    /// The restore goes **into** the live database (section 5.3): the same `IndexWriter`
    /// instance, holding the same connection, sees the restored rows, and the file keeps
    /// its inode. A replace of the file at the path would satisfy neither, and the
    /// extension's reader - which holds the database open across calls - would go on
    /// reading the unlinked one.
    func testRestoreGoesIntoTheLiveConnectionAndBumpsTheGeneration() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(
            IndexItem(
                identifier: "id-1", path: bytes("a.txt"),
                parent: IndexWriter.rootIdentifier, type: "file"))
        let backup = directory.appendingPathComponent("index.sqlite.bak")
        try writer.backup(to: backup)

        // Diverge from the backup: one row gone, one row that the backup never had.
        try writer.delete(identifier: "id-1")
        try writer.upsert(
            IndexItem(
                identifier: "id-2", path: bytes("b.txt"),
                parent: IndexWriter.rootIdentifier, type: "file"))

        let generationBefore = try writer.meta(IndexSchema.MetaKey.generation)
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: indexPath)[.systemFileNumber] as? NSNumber

        try writer.restore(fromBackupAt: backup)

        XCTAssertNotNil(try writer.item(identifier: "id-1"))
        XCTAssertNil(try writer.item(identifier: "id-2"))
        XCTAssertNotEqual(try writer.meta(IndexSchema.MetaKey.generation), generationBefore)

        let inodeAfter = try FileManager.default.attributesOfItem(atPath: indexPath)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(inodeBefore, inodeAfter)
    }

    /// A reader opened before the restore sees the restored rows too, since the file it
    /// has open is still the file that was restored into.
    func testAReaderOpenedBeforeTheRestoreSeesTheRestoredRows() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try writer.upsert(
            IndexItem(
                identifier: "id-1", path: bytes("a.txt"),
                parent: IndexWriter.rootIdentifier, type: "file"))
        let backup = directory.appendingPathComponent("index.sqlite.bak")
        try writer.backup(to: backup)

        let reader = try IndexReader(path: indexPath)
        try writer.delete(identifier: "id-1")
        XCTAssertThrowsError(try reader.item(identifier: "id-1"))

        try writer.restore(fromBackupAt: backup)
        XCTAssertNoThrow(try reader.item(identifier: "id-1"))
    }

    func testIntegrityCheckPassesOnAHealthyDatabase() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        XCTAssertTrue(try writer.integrityCheck())
    }

    /// The sidecars go with the database, because a zero-length database with a surviving
    /// WAL would have that WAL replayed into it on the next open (section 5.3), and each
    /// is truncated under its own inode. Run against plain files rather than a live index:
    /// the whole point of the close-first rule is that truncating the `-shm` under a
    /// process that has it mapped faults that process, and a test that did it to its own
    /// connection would be testing the crash.
    func testTruncateDatabaseFilesEmptiesTheDatabaseAndItsSidecars() throws {
        let base = directory.appendingPathComponent("corrupt.sqlite").path
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: base + suffix, contents: Data(repeating: 0x41, count: 4096)))
        }

        try IndexWriter.truncateDatabaseFiles(at: base)

        for suffix in ["", "-wal", "-shm"] {
            let file = base + suffix
            // Truncated, not unlinked: the inode is what a surviving handle still points at.
            XCTAssertTrue(FileManager.default.fileExists(atPath: file), "\(file) should still be there")
            let size = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.intValue
            XCTAssertEqual(size, 0, "\(file) should be empty")
        }

        // A database with no sidecars at all is the ordinary case after a clean close.
        let lonely = directory.appendingPathComponent("lonely.sqlite").path
        XCTAssertTrue(FileManager.default.createFile(atPath: lonely, contents: Data([0x41])))
        XCTAssertNoThrow(try IndexWriter.truncateDatabaseFiles(at: lonely))
    }
}

// MARK: the pin queries (DESIGN.md section 7.1)

/// `pin_state` is the sole authority for markers, and the two queries the pin machinery
/// asks of it: which paths carry a marker, and which rows a marker change has to rewrite.
final class PinQueryTests: XCTestCase {

    private var directory: URL!
    private var writer: IndexWriter!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-pinq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer = try IndexWriter(path: directory.appendingPathComponent("index.sqlite").path)
        _ = try writer.ensureRoot()
    }

    override func tearDownWithError() throws {
        writer = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func add(_ path: String, pinState: Int64 = 0, type: String = "file") throws {
        try writer.upsert(
            IndexItem(
                identifier: "id-\(path)", path: Data(path.utf8),
                parent: IndexWriter.rootIdentifier, type: type, pinState: pinState))
    }

    func testOnlyExplicitMarkersAreReturned() throws {
        try add("Projects", pinState: 1, type: "directory")
        try add("Projects/archive", pinState: -1, type: "directory")
        try add("Projects/src/main.swift")
        let rows = try writer.pinMarkerRows()
        XCTAssertEqual(rows.map { String(decoding: $0.path, as: UTF8.self) },
                       ["Projects", "Projects/archive"])
        XCTAssertEqual(rows.map(\.marker), [1, -1])
    }

    func testItemsUnderIsAByteRangeAndRespectsTheSeparator() throws {
        try add("Photos", type: "directory")
        try add("Photos/2026/a.jpg")
        try add("Photos/2026/b.jpg")
        // Shares the prefix but is not under it: the separator is what tells them apart.
        try add("Photos2/c.jpg")
        let under = try writer.items(under: Data("Photos".utf8))
        XCTAssertEqual(under.map { String(decoding: $0.path, as: UTF8.self) },
                       ["Photos/2026/a.jpg", "Photos/2026/b.jpg"])
    }

    func testEverythingIsUnderTheLocationRootExceptTheRootRow() throws {
        try add("a")
        try add("a/b")
        let under = try writer.items(under: Data())
        XCTAssertEqual(under.map { String(decoding: $0.path, as: UTF8.self) }, ["a", "a/b"])
        XCTAssertFalse(under.contains { $0.identifier == IndexWriter.rootIdentifier })
    }

    func testANameThatIsNotUTF8StaysDistinct() throws {
        // Two directories that decode alike but are different bytes: a `LIKE` on a decoded
        // string would put one's children under the other.
        let pin = Data([0x70, 0xFF])
        let other = Data([0x70, 0xFE])
        try writer.upsert(
            IndexItem(identifier: "p", path: pin, parent: IndexWriter.rootIdentifier,
                      type: "directory", pinState: 1))
        try writer.upsert(
            IndexItem(identifier: "pc", path: pin + Data([0x2F, 0x78]),
                      parent: "p", type: "file"))
        try writer.upsert(
            IndexItem(identifier: "oc", path: other + Data([0x2F, 0x78]),
                      parent: IndexWriter.rootIdentifier, type: "file"))
        let under = try writer.items(under: pin)
        XCTAssertEqual(under.map(\.identifier), ["pc"])
    }
}
