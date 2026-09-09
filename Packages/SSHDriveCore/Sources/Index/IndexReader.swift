import Foundation
import Logging

/// The extension's read-only view of a domain's index (DESIGN.md section 5.2).
///
/// `item(for:)` is issued in bulk by the system and must be answered from local state, so
/// the extension opens `domains/<id>/index.sqlite` read-only in WAL mode from the group
/// container and answers `item(for:)` and the working-set change enumerator from it with
/// no agent involved. The agent remains the only writer, and that is what makes this
/// safe: WAL readers never block the writer and always see a consistent snapshot.
///
/// Whether this class survives is S3's call: if the XPC path serves 50,000 item(for:)
/// calls within twice the reader's time and under two seconds in all, the reader goes and
/// `meta.reconciling`, `meta.generation`, the ready check and the close-and-reopen
/// protocol go with it.
public final class IndexReader {
    private var connection: SQLiteConnection?
    private let path: String
    /// Re-read when `meta.generation` moves, since the agent has replaced the contents
    /// wholesale (section 5.3).
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
    /// noSuchItem, so a rebuild in progress can never look like a deletion (section 5.3).
    private func checkMeta() throws {
        let version = try metaInt(IndexSchema.MetaKey.schemaVersion) ?? 0
        guard version <= IndexSchema.version else {
            throw IndexError.schemaTooNew(found: Int(version))
        }
        if (try metaInt(IndexSchema.MetaKey.reconciling) ?? 0) != 0 {
            throw IndexError.reconciling
        }
        let generation = try metaInt(IndexSchema.MetaKey.generation) ?? 0
        if generation != cachedGeneration {
            cachedGeneration = generation
        }
    }

    private func metaInt(_ key: String) throws -> Int64? {
        let statement = try database().prepare("SELECT value FROM meta WHERE key = ?1")
        statement.bind(1, key)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return statement.string(0).flatMap(Int64.init)
    }

    /// `meta.generation`, the wholesale-replacement counter, for the extension's state
    /// file (section 5.2).
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

    /// One row read and a field-by-field copy, with no ancestor walk (section 5.2).
    public func item(identifier: String) throws -> IndexItem {
        try checkMeta()
        let statement = try database().prepare(
            "SELECT \(Self.itemColumns) FROM items WHERE identifier = ?1")
        statement.bind(1, identifier)
        defer { statement.reset() }
        guard try statement.step() else { throw IndexError.noSuchItem }
        return Self.decodeItem(statement)
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

    /// The newest sequence number. `enumerateItems` on the working set returns no items
    /// and this as the anchor: the working set is only ever a change stream (section 5.3).
    public func currentSequence() throws -> Int64 {
        try checkMeta()
        let statement = try database().prepare("SELECT COALESCE(MAX(seq), 0) FROM anchors")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// The working-set change stream. Throws `.syncAnchorExpired` when the anchor is
    /// older than the oldest row we still hold; the caller then hands out a fresh anchor
    /// and tells the agent, whose response is one full sweep of the root set (section 5.3).
    ///
    /// The query itself is `IndexChangeStream`, shared with the writer, so the extension's
    /// direct read and the agent's XPC fallback answer the same question (section 5.2).
    public func changes(since anchor: Int64, limit: Int = 500) throws
        -> (entries: [IndexAnchorEntry], newAnchor: Int64, hasMore: Bool)
    {
        try checkMeta()
        let page = try IndexChangeStream.changes(try database(), since: anchor, limit: limit)
        return (page.entries, page.newAnchor, page.hasMore)
    }

    // MARK: The agent's own read-only view (section 8)

    /// The queries below are not the extension's. They are what `sshdrive status` reads,
    /// and they are here rather than on `IndexWriter` for the reason section 5.2 gives the
    /// extension one at all: `LocationRuntime` is an actor, a directory listing writes its
    /// rows in one synchronous transaction on it (section 5.3), and every hop `status`
    /// made onto that actor therefore waited for a whole listing to finish. A WAL reader
    /// never blocks the writer and never delays it, so the report is taken from a
    /// connection of its own (2026-09-09, section 8).
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

    /// Every row, which is what section 5.4's "not shown" list is filtered out of.
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

    /// Every explicit pin marker (section 7.1), which is the whole of `sshdrive pins`.
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

    /// The mass-deletion guard's held rows (section 6.4), for section 8's
    /// "0 held deletions" line.
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

    /// The change-detection root set (section 6.5), least recently listed first.
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
    /// rebuild rather than failing on it (section 5.3).
    public func isReconciling() throws -> Bool {
        (try metaInt(IndexSchema.MetaKey.reconciling) ?? 0) != 0
    }

    /// Closes the reader for the truncate window of a restore (section 5.3). The reader
    /// holds the -shm file mapped, and truncating a mapped file under a live process
    /// faults it on its next access.
    public func close() {
        connection = nil
    }

    /// Reopens after the agent's `reopenIndexReader` callback.
    public func reopen() throws {
        connection = try SQLiteConnection(path: path, mode: .readOnly)
        cachedGeneration = -1
    }
}
