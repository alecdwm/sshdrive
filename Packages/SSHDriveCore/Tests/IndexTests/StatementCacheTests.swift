import XCTest
@testable import Index

/// The prepared-statement cache (docs/design/extension.md), and the one-statement meta
/// check that sits on top of it.
///
/// The index runs a very small, fixed set of statements over and over: a 10,000-entry
/// listing is three of them ten thousand times, and the `item(for:)` storm the system
/// issues after one is two. Compiling one per execution is most of what both cost -
/// 8,006 compilations for a 2,000-entry listing, five per `item(for:)` - so what these
/// tests pin is that the count is a *constant*: they fail the moment a compilation
/// becomes per row.
final class StatementCacheTests: XCTestCase {

    private var directory: URL!
    private var indexPath: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexPath = directory.appendingPathComponent("index.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A counter a `@Sendable` observer can write to.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private(set) var total = 0

        func record(_ sql: String) {
            lock.lock()
            counts[sql, default: 0] += 1
            total += 1
            lock.unlock()
        }

        var distinct: Int {
            lock.lock(); defer { lock.unlock() }
            return counts.count
        }
    }

    private func populate(_ writer: IndexWriter, rows: Int) throws {
        try writer.batch {
            for index in 0 ..< rows {
                try writer.upsert(
                    IndexItem(
                        identifier: "id-\(index)",
                        path: Data("f\(index).txt".utf8),
                        parent: IndexWriter.rootIdentifier,
                        type: "file", size: 3, mtime: 1_700_000_000,
                        contentVersion: IndexItem.contentVersion(
                            size: 3, mtime: 1_700_000_000, generation: 0)))
            }
        }
    }

    /// The `item(for:)` storm. **One** statement per call - the row, carrying the meta
    /// check as three scalar subqueries - and a constant number of compilations for the
    /// whole storm, however long it runs (docs/design/extension.md).
    func testTheStormCostsOneStatementPerItemAndCompilesTwoInAll() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try populate(writer, rows: 1000)

        let reader = try IndexReader(path: indexPath)
        let compiled = Tally()
        let executed = Tally()
        reader.observeCompilations { sql, _ in compiled.record(sql) }
        reader.observeStatements { sql, _ in executed.record(sql) }

        for index in 0 ..< 1000 {
            let (row, generation) = try reader.itemAndGeneration(identifier: "id-\(index)")
            XCTAssertEqual(row.identifier, "id-\(index)")
            XCTAssertEqual(generation, 0)
        }

        XCTAssertLessThanOrEqual(
            compiled.total, 2,
            "the storm compiles a constant number of statements, not five per item(for:)")
        XCTAssertEqual(
            executed.total, 1000,
            "one statement per item(for:) - the row and the meta check together")
    }

    /// The write half. The same three statements a listing issues per entry - the
    /// incumbent read, the row, the anchor - cost the same handful of compilations
    /// whether the directory holds a hundred entries or a thousand.
    func testAListingsCompilationsDoNotGrowWithTheDirectory() throws {
        func compilations(entries: Int) throws -> Int {
            let path = directory.appendingPathComponent("index-\(entries).sqlite").path
            let writer = try IndexWriter(path: path)
            try writer.ensureRoot()
            let compiled = Tally()
            writer.observeCompilations { sql, _ in compiled.record(sql) }
            try writer.batch {
                for index in 0 ..< entries {
                    let path = Data("f\(index).txt".utf8)
                    let existing = try writer.item(path: path)
                    XCTAssertNil(existing)
                    let row = IndexItem(
                        identifier: "id-\(index)", path: path,
                        parent: IndexWriter.rootIdentifier, type: "file", size: 3,
                        mtime: 1_700_000_000,
                        contentVersion: IndexItem.contentVersion(
                            size: 3, mtime: 1_700_000_000, generation: 0))
                    try writer.upsert(row)
                    try writer.appendAnchor(identifier: row.identifier, kind: .modified)
                }
            }
            writer.observeCompilations(nil)
            return compiled.total
        }

        let small = try compilations(entries: 100)
        let large = try compilations(entries: 1000)
        XCTAssertEqual(small, large, "a listing's compilations are a constant, not a per-row cost")
        XCTAssertLessThanOrEqual(large, 12)
    }

    /// The reuse rule. A statement is taken *out* of the cache to be handed out, so a
    /// second caller asking for the same SQL while the first is still stepping gets one of
    /// its own: nothing is ever reset or rebound under a caller that is still reading.
    func testAStatementStillSteppingIsNeverHandedToASecondCaller() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try populate(writer, rows: 50)

        let connection = try SQLiteConnection(path: indexPath, mode: .readOnly)
        let compiled = Tally()
        connection.compileObserver = { sql, _ in compiled.record(sql) }
        let sql = "SELECT identifier FROM items WHERE parent = ?1 ORDER BY identifier"

        var outerRows: [String] = []
        var innerRows: [String] = []
        do {
            let outer = try connection.prepare(sql)
            outer.bind(1, IndexWriter.rootIdentifier)
            while try outer.step() {
                outerRows.append(outer.string(0) ?? "")
                // The nested read, on the same SQL, while the outer one is mid-iteration.
                if outerRows.count == 10 {
                    let inner = try connection.prepare(sql)
                    inner.bind(1, IndexWriter.rootIdentifier)
                    while try inner.step() { innerRows.append(inner.string(0) ?? "") }
                    inner.reset()
                }
            }
            outer.reset()
        }

        XCTAssertEqual(outerRows.count, 50, "the outer iteration was not restarted under it")
        XCTAssertEqual(outerRows, outerRows.sorted(), "and it stayed in order")
        XCTAssertEqual(Set(outerRows).count, 50, "with no row read twice")
        XCTAssertEqual(innerRows.count, 50, "and the nested read saw the whole table")
        XCTAssertEqual(compiled.total, 2, "the nested caller compiled a statement of its own")

        // Both are gone now, so the next caller is served from the cache.
        let after = try connection.prepare(sql)
        after.bind(1, IndexWriter.rootIdentifier)
        XCTAssertTrue(try after.step())
        after.reset()
        XCTAssertEqual(compiled.total, 2, "and the third prepare compiled nothing at all")
    }

    /// The cache belongs to the connection, so the close-and-reopen protocol of section
    /// 5.3 takes it with it: nothing compiled against the old file is kept, and the
    /// reopened reader compiles afresh and answers.
    func testCloseAndReopenTakeTheCacheWithTheConnection() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        try populate(writer, rows: 5)

        let reader = try IndexReader(path: indexPath)
        let compiled = Tally()
        reader.observeCompilations { sql, _ in compiled.record(sql) }
        XCTAssertEqual(try reader.item(identifier: "id-0").identifier, "id-0")
        let firstPass = compiled.total
        XCTAssertEqual(try reader.item(identifier: "id-1").identifier, "id-1")
        XCTAssertEqual(compiled.total, firstPass, "the second read compiled nothing")

        reader.close()
        XCTAssertThrowsError(try reader.item(identifier: "id-0")) {
            XCTAssertEqual($0 as? IndexError, .closed)
        }
        try reader.reopen()
        XCTAssertEqual(try reader.item(identifier: "id-2").identifier, "id-2")
        XCTAssertEqual(
            compiled.total, firstPass * 2,
            "the reopened connection compiles its own, and is still being watched")
    }

    /// Every check the collapsed `checkMeta` still makes, and in the order it made them:
    /// a schema newer than this build first, then a reconcile in progress. Both answer
    /// before any row is read, which is what stops a rebuild ever looking like a deletion
    /// (docs/design/item-index.md, gotchas 27 and 76).
    func testTheOneStatementMetaCheckKeepsEveryAnswerItHad() throws {
        let writer = try IndexWriter(path: indexPath)
        try writer.ensureRoot()
        let reader = try IndexReader(path: indexPath)
        XCTAssertNoThrow(try reader.item(identifier: IndexWriter.rootIdentifier))

        try writer.setReconciling(true)
        XCTAssertThrowsError(try reader.item(identifier: IndexWriter.rootIdentifier)) {
            XCTAssertEqual($0 as? IndexError, .reconciling)
        }
        XCTAssertThrowsError(try reader.children(ofParent: IndexWriter.rootIdentifier)) {
            XCTAssertEqual($0 as? IndexError, .reconciling)
        }
        try writer.setReconciling(false)
        XCTAssertNoThrow(try reader.item(identifier: IndexWriter.rootIdentifier))

        // A newer schema wins over a reconcile: the extension falls back to the agent
        // rather than waiting for a rebuild it cannot read the result of anyway.
        try writer.setMeta(IndexSchema.MetaKey.schemaVersion, String(IndexSchema.version + 1))
        try writer.setReconciling(true)
        XCTAssertThrowsError(try reader.item(identifier: IndexWriter.rootIdentifier)) {
            XCTAssertEqual($0 as? IndexError, .schemaTooNew(found: IndexSchema.version + 1))
        }

        // And the generation the check reads is the one the caller is handed.
        try writer.setMeta(IndexSchema.MetaKey.schemaVersion, String(IndexSchema.version))
        try writer.setReconciling(false)
        try writer.bumpGeneration()
        XCTAssertEqual(try reader.generation(), 1)
        XCTAssertEqual(
            try reader.itemAndGeneration(identifier: IndexWriter.rootIdentifier).generation, 1)
    }
}
