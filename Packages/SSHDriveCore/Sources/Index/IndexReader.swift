import Foundation
import Logging

/// The extension's read-only view of a domain's index (docs/design/extension.md).
///
/// `item(for:)` is issued in bulk by the system and must be answered from local state, so
/// the extension opens `domains/<id>/index.sqlite` read-only in WAL mode from the group
/// container and answers `item(for:)` and the working-set change enumerator from it with
/// no agent involved. The agent remains the only writer, and that is what makes this
/// safe: WAL readers never block the writer and always see a consistent snapshot.
public final class IndexReader {
    private var connection: SQLiteConnection?
    private let path: String
    /// Re-read when `meta.generation` moves, since the agent has replaced the contents
    /// wholesale.
    private var cachedGeneration: Int64 = -1

    public init(path: String) throws {
        self.path = path
        self.connection = try SQLiteConnection(path: path, mode: .readOnly)
    }

    /// The open connection, or `.closed` while the agent is rebuilding the file.
    private func database() throws -> SQLiteConnection {
        guard let connection else { throw IndexError.closed }
        return connection
    }

    /// Any SQLite error, a corrupt page, a not-a-database header during the truncate
    /// window, a missing table, is answered by the caller as serverUnreachable, never as
    /// noSuchItem, so a rebuild in progress can never look like a deletion.
    ///
    /// The three keys are read in **one** statement: a `SELECT value FROM meta WHERE key =
    /// ?1` each, with the row read and the generation the caller wants after it, makes an
    /// `item(for:)` five statements where two will do, and the system issues `item(for:)`
    /// in bulk. A key that is missing, or whose value is not a number, reads as 0.
    @discardableResult
    private func checkMeta() throws -> Int64 {
        let statement = try database().prepare(
            "SELECT key, value FROM meta WHERE key IN (?1, ?2, ?3)")
        statement.bind(1, IndexSchema.MetaKey.schemaVersion)
        statement.bind(2, IndexSchema.MetaKey.reconciling)
        statement.bind(3, IndexSchema.MetaKey.generation)
        defer { statement.reset() }
        var version: Int64 = 0
        var reconciling: Int64 = 0
        var generation: Int64 = 0
        while try statement.step() {
            let value = statement.string(1).flatMap(Int64.init) ?? 0
            switch statement.string(0) {
            case IndexSchema.MetaKey.schemaVersion: version = value
            case IndexSchema.MetaKey.reconciling: reconciling = value
            case IndexSchema.MetaKey.generation: generation = value
            default: break
            }
        }
        return try judge(version: version, reconciling: reconciling, generation: generation)
    }

    /// The three answers the meta check produces, whichever statement read them.
    ///
    /// A schema newer than this build is the extension's cue to fall back to the agent; a
    /// database being reconciled answers nothing at all; anything else hands back the
    /// generation the caller wants for the state file. A key that is missing, or whose
    /// value is not a number, reads as 0.
    private func judge(version: Int64, reconciling: Int64, generation: Int64) throws -> Int64 {
        guard version <= IndexSchema.version else {
            throw IndexError.schemaTooNew(found: Int(version))
        }
        if reconciling != 0 {
            throw IndexError.reconciling
        }
        if generation != cachedGeneration {
            cachedGeneration = generation
        }
        return generation
    }

    private func metaInt(_ key: String) throws -> Int64? {
        let statement = try database().prepare("SELECT value FROM meta WHERE key = ?1")
        statement.bind(1, key)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return statement.string(0).flatMap(Int64.init)
    }

    /// `meta.generation`, the wholesale-replacement counter, for the extension's state
    /// file.
    public func generation() throws -> Int64 {
        try metaInt(IndexSchema.MetaKey.generation) ?? 0
    }

    public func metaString(_ key: String) throws -> String? {
        let statement = try database().prepare("SELECT value FROM meta WHERE key = ?1")
        statement.bind(1, key)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    private static let itemColumns = """
        identifier, path, parent, type, size, mtime, mtime_ns, inode, uid, gid, mode, \
        generation, content_version, metadata_version, last_fetch, pin_state, kept, \
        capabilities, fs_flags, link_target, hidden, xattrs, local_content
        """

    static func decodeItem(_ statement: SQLiteStatement) -> IndexItem {
        IndexItem(
            identifier: statement.string(0) ?? "",
            path: statement.data(1) ?? Data(),
            parent: statement.string(2),
            type: statement.string(3) ?? "file",
            size: statement.int(4),
            mtime: statement.int(5),
            mtimeNanoseconds: statement.intOrNil(6),
            inode: statement.intOrNil(7),
            uid: statement.intOrNil(8),
            gid: statement.intOrNil(9),
            mode: statement.intOrNil(10),
            generation: statement.int(11),
            contentVersion: statement.string(12) ?? "",
            metadataVersion: statement.string(13) ?? "",
            lastFetch: statement.doubleOrNil(14),
            pinState: statement.int(15),
            kept: statement.int(16) != 0,
            capabilities: statement.int(17),
            fileSystemFlags: statement.int(18),
            linkTarget: statement.data(19),
            hidden: statement.int(20),
            xattrs: statement.data(21),
            localContent: statement.data(22))
    }

    /// One row read and a field-by-field copy, with no ancestor walk.
    public func item(identifier: String) throws -> IndexItem {
        try itemAndGeneration(identifier: identifier).item
    }

    /// The same row, with the `meta.generation` the check above already read.
    ///
    /// The extension's store wants both on every `item(for:)` - the row for the system and
    /// the generation for the state file `doctor` reads - and asking for the generation
    /// separately is a meta statement per call on top of the check.
    public func itemAndGeneration(identifier: String) throws -> (item: IndexItem, generation: Int64) {
        // The meta check rides on the row's own query as three scalar subqueries, so an
        // `item(for:)` is **one** statement rather than two: the system issues them in bulk
        // and a whole statement of overhead per call is a third of what one costs. The
        // three values are judged before the row is returned, exactly as `checkMeta()`
        // judges them for every other read here, and one query is if anything the firmer
        // answer - the row and the meta keys come from one snapshot.
        let statement = try database().prepare(
            """
            SELECT \(Self.itemColumns), \
            (SELECT value FROM meta WHERE key = ?2), \
            (SELECT value FROM meta WHERE key = ?3), \
            (SELECT value FROM meta WHERE key = ?4) \
            FROM items WHERE identifier = ?1
            """)
        statement.bind(1, identifier)
        statement.bind(2, IndexSchema.MetaKey.schemaVersion)
        statement.bind(3, IndexSchema.MetaKey.reconciling)
        statement.bind(4, IndexSchema.MetaKey.generation)
        defer { statement.reset() }
        guard try statement.step() else {
            // No row here says nothing about the database's health, and a rebuild in
            // progress must never look like a deletion: the meta check is asked in its own
            // right before the answer is given.
            try checkMeta()
            throw IndexError.noSuchItem
        }
        let generation = try judge(
            version: statement.string(23).flatMap(Int64.init) ?? 0,
            reconciling: statement.string(24).flatMap(Int64.init) ?? 0,
            generation: statement.string(25).flatMap(Int64.init) ?? 0)
        return (Self.decodeItem(statement), generation)
    }

    public func children(ofParent identifier: String) throws -> [IndexItem] {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT \(Self.itemColumns) FROM items WHERE parent = ?1 AND hidden = 0 ORDER BY path")
        statement.bind(1, identifier)
        defer { statement.reset() }
        var rows: [IndexItem] = []
        while try statement.step() { rows.append(Self.decodeItem(statement)) }
        return rows
    }

    /// The newest sequence number. `enumerateItems` on the working set returns no items and
    /// this as the anchor: the working set is only ever a change stream.
    public func currentSequence() throws -> Int64 {
        try checkMeta()
        let statement = try database().prepare("SELECT COALESCE(MAX(seq), 0) FROM anchors")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// The working-set change stream. Throws `.syncAnchorExpired` when the anchor is older
    /// than the oldest row we still hold; the caller then hands out a fresh anchor and
    /// tells the agent, whose response is one full sweep of the root set.
    ///
    /// The query itself is `IndexChangeStream`, shared with the writer, so the extension's
    /// direct read and the agent's XPC fallback answer the same question.
    public func changes(since anchor: Int64, limit: Int = 500) throws
        -> (entries: [IndexAnchorEntry], newAnchor: Int64, hasMore: Bool)
    {
        try checkMeta()
        let page = try IndexChangeStream.changes(try database(), since: anchor, limit: limit)
        return (page.entries, page.newAnchor, page.hasMore)
    }

    // MARK: The agent's own read-only view

    /// The queries below are not the extension's. They are what `sshdrive status` reads
    /// (docs/design/cli.md), and they are here rather than on `IndexWriter` for the same
    /// reason the extension has a reader at all: `LocationRuntime` is an actor, a directory
    /// listing writes its rows in one synchronous transaction on it, and a hop onto that
    /// actor waits for a whole listing to finish. A WAL reader neither blocks the writer
    /// nor waits for it, so the report is taken from a connection of its own.
    ///
    /// They are read-only, they call `checkMeta()` like every other read here, and the
    /// agent remains the sole writer.

    /// Like `item(identifier:)` but answering nil rather than throwing for a row that is
    /// not there: `status` reads the identifiers the *system* says it holds content for,
    /// and a row the index has already deleted is an ordinary outcome there, not an error.
    public func itemIfPresent(identifier: String) throws -> IndexItem? {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT \(Self.itemColumns) FROM items WHERE identifier = ?1")
        statement.bind(1, identifier)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return Self.decodeItem(statement)
    }

    public func item(path: Data) throws -> IndexItem? {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT \(Self.itemColumns) FROM items WHERE path = ?1")
        statement.bind(1, path)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return Self.decodeItem(statement)
    }

    /// Every row, which the "not shown" name rules are filtered out of
    /// (docs/design/names-and-attributes.md).
    public func allItems() throws -> [IndexItem] {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT \(Self.itemColumns) FROM items ORDER BY path")
        defer { statement.reset() }
        var rows: [IndexItem] = []
        while try statement.step() { rows.append(Self.decodeItem(statement)) }
        return rows
    }

    /// Every row strictly under `path`. The byte-range form of `IndexWriter.items(under:)`,
    /// for the same reason: paths are blobs and SQLite compares blobs with `memcmp`.
    public func items(under path: Data) throws -> [IndexItem] {
        try checkMeta()
        let statement: SQLiteStatement
        if path.isEmpty {
            statement = try database().prepare(
                "SELECT \(Self.itemColumns) FROM items WHERE length(path) > 0 ORDER BY path")
        } else {
            let lower = path + Data([0x2F])
            var upper = path
            upper.append(0x30)
            statement = try database().prepare(
                "SELECT \(Self.itemColumns) FROM items WHERE path >= ?1 AND path < ?2 ORDER BY path")
            statement.bind(1, lower)
            statement.bind(2, upper)
        }
        defer { statement.reset() }
        var rows: [IndexItem] = []
        while try statement.step() { rows.append(Self.decodeItem(statement)) }
        return rows
    }

    /// Every explicit pin marker (docs/design/pinning.md), which is the whole of `sshdrive
    /// pins`.
    public func pinMarkerRows() throws -> [(path: Data, marker: Int64)] {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT path, pin_state FROM items WHERE pin_state != 0 ORDER BY path")
        defer { statement.reset() }
        var rows: [(path: Data, marker: Int64)] = []
        while try statement.step() {
            guard let path = statement.data(0) else { continue }
            rows.append((path, statement.int(1)))
        }
        return rows
    }

    /// The mass-deletion guard's held rows (docs/design/change-detection.md), for section
    /// 8's "0 held deletions" line.
    public func heldRows() throws -> [IndexWriter.HeldRow] {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT \(IndexWriter.heldColumns) FROM held ORDER BY path")
        defer { statement.reset() }
        var out: [IndexWriter.HeldRow] = []
        while try statement.step() { out.append(IndexWriter.decodeHeld(statement)) }
        return out
    }

    public func heldCount() throws -> Int {
        try checkMeta()
        let statement = try database().prepare("SELECT COUNT(*) FROM held")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.int(0))
    }

    /// The change-detection root set (docs/design/root-set.md), least recently listed
    /// first.
    public func rootRows() throws -> [IndexWriter.RootRow] {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT path, reason, last_seen, last_listed FROM roots ORDER BY last_listed, path")
        defer { statement.reset() }
        var out: [IndexWriter.RootRow] = []
        while try statement.step() {
            out.append(
                IndexWriter.RootRow(
                    path: statement.data(0) ?? Data(),
                    reason: statement.string(1) ?? "",
                    lastSeen: statement.double(2),
                    lastListed: statement.double(3)))
        }
        return out
    }

    /// `meta.reconciling`, read without `checkMeta()` throwing on it: `status` reports the
    /// rebuild rather than failing on it.
    public func isReconciling() throws -> Bool {
        (try metaInt(IndexSchema.MetaKey.reconciling) ?? 0) != 0
    }

    /// Closes the reader for the truncate window of a restore. The reader holds the -shm
    /// file mapped, and truncating a mapped file under a live process faults it on its next
    /// access.
    public func close() {
        connection = nil
    }

    /// Reopens after the agent's `reopenIndexReader` callback.
    public func reopen() throws {
        let opened = try SQLiteConnection(path: path, mode: .readOnly)
        opened.statementObserver = statementObserver
        opened.compileObserver = compileObserver
        connection = opened
        cachedGeneration = -1
    }

    // MARK: The test seam of the statement cache

    /// Kept on the reader rather than only on the connection so that a close and reopen
    /// - the truncate window of a restore - does not silently stop a test
    /// counting. Both are nil in the shipping extension.
    private var statementObserver: (@Sendable (_ sql: String, _ depth: Int) -> Void)?
    private var compileObserver: (@Sendable (_ sql: String, _ depth: Int) -> Void)?

    /// Every statement this reader *executes*.
    public func observeStatements(_ observer: (@Sendable (_ sql: String, _ depth: Int) -> Void)?) {
        statementObserver = observer
        connection?.statementObserver = observer
    }

    /// Every statement this reader *compiles*, which is what says the cache is working: an
    /// `item(for:)` storm must compile a constant number and not five per call.
    public func observeCompilations(_ observer: (@Sendable (_ sql: String, _ depth: Int) -> Void)?) {
        compileObserver = observer
        connection?.compileObserver = observer
    }
}