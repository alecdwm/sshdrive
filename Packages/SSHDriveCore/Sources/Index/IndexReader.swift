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

    private func oldestSequence() throws -> Int64 {
        let statement = try database().prepare("SELECT COALESCE(MIN(seq), 0) FROM anchors")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// The working-set change stream. Throws `.syncAnchorExpired` when the anchor is
    /// older than the oldest row we still hold; the caller then hands out a fresh anchor
    /// and tells the agent, whose response is one full sweep of the root set (section 5.3).
    public func changes(since anchor: Int64, limit: Int = 500) throws
        -> (entries: [IndexAnchorEntry], newAnchor: Int64, hasMore: Bool)
    {
        try checkMeta()
        let oldest = try oldestSequence()
        let newest = try currentSequence()
        if anchor < oldest - 1 && oldest > 0 {
            throw IndexError.syncAnchorExpired
        }
        let statement = try database().prepare(
            "SELECT seq, changed_identifier, change_kind FROM anchors "
                + "WHERE seq > ?1 ORDER BY seq LIMIT ?2")
        statement.bind(1, anchor)
        statement.bind(2, Int64(limit + 1))
        defer { statement.reset() }
        var entries: [IndexAnchorEntry] = []
        while try statement.step() {
            let kind = IndexAnchorEntry.Kind(rawValue: statement.string(2) ?? "modified") ?? .modified
            entries.append(
                IndexAnchorEntry(
                    sequence: statement.int(0),
                    identifier: statement.string(1) ?? "",
                    kind: kind))
        }
        let hasMore = entries.count > limit
        if hasMore { entries.removeLast(entries.count - limit) }
        return (entries, entries.last?.sequence ?? max(anchor, newest), hasMore)
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
