import Foundation
import Logging

/// The agent's connection to a domain's index. The agent is the only writer
/// (DESIGN.md sections 3, 5.2), so this class holds no lock of its own beyond the one
/// serial queue the agent runs it on.
public final class IndexWriter {
    /// The permanent row for the location root: the empty path, and the identifier the
    /// system knows as `NSFileProviderItemIdentifier.rootContainer` (section 5.3).
    public static let rootIdentifier = "NSFileProviderRootContainerItemIdentifier"

    private let connection: SQLiteConnection
    public let path: String

    public init(path: String) throws {
        self.path = path
        self.connection = try SQLiteConnection(path: path, mode: .readWrite)
        try connection.execute(IndexSchema.createStatements)
        try setMetaIfAbsent(IndexSchema.MetaKey.schemaVersion, String(IndexSchema.version))
        try setMetaIfAbsent(IndexSchema.MetaKey.generation, "0")
        try setMetaIfAbsent(IndexSchema.MetaKey.reconciling, "0")
    }

    // MARK: meta

    public func setMeta(_ key: String, _ value: String) throws {
        let statement = try connection.prepare(
            "INSERT INTO meta (key, value) VALUES (?1, ?2) "
                + "ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        statement.bind(1, key)
        statement.bind(2, value)
        try statement.run()
    }

    private func setMetaIfAbsent(_ key: String, _ value: String) throws {
        let statement = try connection.prepare(
            "INSERT OR IGNORE INTO meta (key, value) VALUES (?1, ?2)")
        statement.bind(1, key)
        statement.bind(2, value)
        try statement.run()
    }

    public func meta(_ key: String) throws -> String? {
        let statement = try connection.prepare("SELECT value FROM meta WHERE key = ?1")
        statement.bind(1, key)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    /// Set for the whole reconcile walk, so the extension's own reads stall too
    /// (section 5.3). It outlives a crash: an agent that starts and finds it set redoes
    /// the walk before serving anything.
    public var isReconciling: Bool {
        get { ((try? meta(IndexSchema.MetaKey.reconciling)).flatMap { $0 } ?? "0") != "0" }
    }

    public func setReconciling(_ value: Bool) throws {
        try setMeta(IndexSchema.MetaKey.reconciling, value ? "1" : "0")
    }

    /// Bumped whenever the contents have been replaced wholesale. The reader re-reads its
    /// cached prepared statements on a change (section 5.2).
    public func bumpGeneration() throws {
        let current = Int64(try meta(IndexSchema.MetaKey.generation) ?? "0") ?? 0
        try setMeta(IndexSchema.MetaKey.generation, String(current + 1))
    }

    // MARK: items

    /// Creates the root row if it is not there. Called when the domain is.
    @discardableResult
    public func ensureRoot(mode: Int64 = 0o755, uid: Int64 = 0, gid: Int64 = 0) throws -> IndexItem {
        if let existing = try item(identifier: Self.rootIdentifier) { return existing }
        let root = IndexItem(
            identifier: Self.rootIdentifier,
            path: Data(),
            parent: nil,
            type: "directory",
            uid: uid,
            gid: gid,
            mode: mode,
            contentVersion: IndexItem.contentVersion(size: 0, mtime: 0, generation: 0))
        try upsert(root)
        return root
    }

    /// Writes a finished row. Every derived field is already computed by the caller: a
    /// row is a finished item (section 5.2).
    public func upsert(_ item: IndexItem) throws {
        let statement = try connection.prepare("""
            INSERT INTO items (
                identifier, path, parent, type, size, mtime, mtime_ns, inode, uid, gid, mode,
                generation, content_version, metadata_version, last_fetch, pin_state, kept,
                capabilities, fs_flags, link_target, hidden, xattrs, local_content)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                    ?18, ?19, ?20, ?21, ?22, ?23)
            ON CONFLICT(identifier) DO UPDATE SET
                path = excluded.path, parent = excluded.parent, type = excluded.type,
                size = excluded.size, mtime = excluded.mtime, mtime_ns = excluded.mtime_ns,
                inode = excluded.inode, uid = excluded.uid, gid = excluded.gid,
                mode = excluded.mode, generation = excluded.generation,
                content_version = excluded.content_version,
                metadata_version = excluded.metadata_version,
                last_fetch = excluded.last_fetch, pin_state = excluded.pin_state,
                kept = excluded.kept, capabilities = excluded.capabilities,
                fs_flags = excluded.fs_flags, link_target = excluded.link_target,
                hidden = excluded.hidden, xattrs = excluded.xattrs,
                local_content = excluded.local_content
            """)
        statement.bind(1, item.identifier)
        statement.bind(2, item.path)
        statement.bind(3, item.parent)
        statement.bind(4, item.type)
        statement.bind(5, item.size)
        statement.bind(6, item.mtime)
        statement.bind(7, item.mtimeNanoseconds)
        statement.bind(8, item.inode)
        statement.bind(9, item.uid)
        statement.bind(10, item.gid)
        statement.bind(11, item.mode)
        statement.bind(12, item.generation)
        statement.bind(13, item.contentVersion)
        statement.bind(14, item.metadataVersion)
        statement.bind(15, item.lastFetch)
        statement.bind(16, item.pinState)
        statement.bind(17, Int64(item.kept ? 1 : 0))
        statement.bind(18, item.capabilities)
        statement.bind(19, item.fileSystemFlags)
        statement.bind(20, item.linkTarget)
        statement.bind(21, item.hidden)
        statement.bind(22, item.xattrs)
        statement.bind(23, item.localContent)
        try statement.run()
    }

    public func item(identifier: String) throws -> IndexItem? {
        let statement = try connection.prepare(
            "SELECT \(Self.columns) FROM items WHERE identifier = ?1")
        statement.bind(1, identifier)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return IndexReader.decodeItem(statement)
    }

    public func item(path: Data) throws -> IndexItem? {
        let statement = try connection.prepare("SELECT \(Self.columns) FROM items WHERE path = ?1")
        statement.bind(1, path)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return IndexReader.decodeItem(statement)
    }

    public func children(ofParent identifier: String) throws -> [IndexItem] {
        let statement = try connection.prepare(
            "SELECT \(Self.columns) FROM items WHERE parent = ?1 ORDER BY path")
        statement.bind(1, identifier)
        defer { statement.reset() }
        var rows: [IndexItem] = []
        while try statement.step() { rows.append(IndexReader.decodeItem(statement)) }
        return rows
    }

    public func allItems() throws -> [IndexItem] {
        let statement = try connection.prepare("SELECT \(Self.columns) FROM items ORDER BY path")
        defer { statement.reset() }
        var rows: [IndexItem] = []
        while try statement.step() { rows.append(IndexReader.decodeItem(statement)) }
        return rows
    }

    /// Deleted rows are deleted: no tombstones (section 5.3). The row goes in the same
    /// transaction that writes the deletion anchor, and its pin marker and xattrs go
    /// with it.
    public func delete(identifier: String) throws {
        try connection.transaction {
            let statement = try connection.prepare("DELETE FROM items WHERE identifier = ?1")
            statement.bind(1, identifier)
            try statement.run()
            try appendAnchorLocked(identifier: identifier, kind: .deleted)
        }
    }

    /// Moving a directory rewrites `path` on every descendant row, and on the matching
    /// rows of `roots` and `held`, in one transaction (section 5.3). `parent` is kept
    /// alongside `path` so the rewrite walks by identifier rather than by string prefix.
    public func rewritePaths(from oldPath: Data, to newPath: Data) throws {
        try connection.transaction {
            let prefix = oldPath.isEmpty ? Data() : oldPath + Data([0x2F])
            let replacement = newPath.isEmpty ? Data() : newPath + Data([0x2F])

            var rewritten: [(String, Data)] = []
            let select = try connection.prepare("SELECT identifier, path FROM items")
            while try select.step() {
                let identifier = select.string(0) ?? ""
                guard let path = select.data(1) else { continue }
                if path == oldPath {
                    rewritten.append((identifier, newPath))
                } else if path.starts(with: prefix) {
                    rewritten.append((identifier, replacement + path.dropFirst(prefix.count)))
                }
            }
            select.reset()

            let update = try connection.prepare("UPDATE items SET path = ?2 WHERE identifier = ?1")
            for (identifier, path) in rewritten {
                update.bind(1, identifier)
                update.bind(2, path)
                try update.run()
                try appendAnchorLocked(identifier: identifier, kind: .modified)
            }

            for table in ["roots", "held"] {
                let rows = try connection.prepare("SELECT rowid, path FROM \(table)")
                var moves: [(Int64, Data)] = []
                while try rows.step() {
                    guard let path = rows.data(1) else { continue }
                    if path == oldPath {
                        moves.append((rows.int(0), newPath))
                    } else if path.starts(with: prefix) {
                        moves.append((rows.int(0), replacement + path.dropFirst(prefix.count)))
                    }
                }
                rows.reset()
                let move = try connection.prepare("UPDATE \(table) SET path = ?2 WHERE rowid = ?1")
                for (rowid, path) in moves {
                    move.bind(1, rowid)
                    move.bind(2, path)
                    try move.run()
                }
            }
        }
    }

    // MARK: anchors

    /// Appends one change-stream entry and returns its sequence number.
    @discardableResult
    public func appendAnchor(identifier: String, kind: IndexAnchorEntry.Kind) throws -> Int64 {
        try connection.transaction { try appendAnchorLocked(identifier: identifier, kind: kind) }
    }

    @discardableResult
    private func appendAnchorLocked(identifier: String, kind: IndexAnchorEntry.Kind) throws -> Int64 {
        let statement = try connection.prepare(
            "INSERT INTO anchors (changed_identifier, change_kind, at) VALUES (?1, ?2, ?3)")
        statement.bind(1, identifier)
        statement.bind(2, kind.rawValue)
        statement.bind(3, Date().timeIntervalSince1970)
        try statement.run()
        return sqliteLastInsertRowID()
    }

    private func sqliteLastInsertRowID() -> Int64 {
        let statement = try? connection.prepare("SELECT last_insert_rowid()")
        guard let statement, (try? statement.step()) == true else { return 0 }
        defer { statement.reset() }
        return statement.int(0)
    }

    public func currentSequence() throws -> Int64 {
        let statement = try connection.prepare("SELECT COALESCE(MAX(seq), 0) FROM anchors")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// Pruned to the newest 30 days and to the newest 1,000,000 rows, both limits
    /// applying (section 5.3). The row cap is deliberately generous: a pin change writes
    /// an anchor per known descendant.
    public func pruneAnchors(maximumRows: Int64 = 1_000_000, maximumAge: TimeInterval = 30 * 86400) throws {
        try connection.transaction {
            let byAge = try connection.prepare("DELETE FROM anchors WHERE at < ?1")
            byAge.bind(1, Date().timeIntervalSince1970 - maximumAge)
            try byAge.run()

            let byCount = try connection.prepare("""
                DELETE FROM anchors WHERE seq <= (
                    SELECT COALESCE(MAX(seq), 0) - ?1 FROM anchors)
                """)
            byCount.bind(1, maximumRows)
            try byCount.run()
        }
    }

    /// Expires every anchor the system might still hold, which is what a rebuild does
    /// (section 5.3) and what `sshdrive debug anchor expire` simulates.
    public func expireAnchors() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM anchors")
            // One fresh row keeps MIN(seq) above any anchor the system holds, so the
            // reader answers syncAnchorExpired rather than an empty change set.
            try appendAnchorLocked(identifier: Self.rootIdentifier, kind: .modified)
        }
    }

    public func anchors(limit: Int = 100) throws -> [IndexAnchorEntry] {
        let statement = try connection.prepare(
            "SELECT seq, changed_identifier, change_kind FROM anchors ORDER BY seq DESC LIMIT ?1")
        statement.bind(1, Int64(limit))
        defer { statement.reset() }
        var out: [IndexAnchorEntry] = []
        while try statement.step() {
            out.append(
                IndexAnchorEntry(
                    sequence: statement.int(0),
                    identifier: statement.string(1) ?? "",
                    kind: IndexAnchorEntry.Kind(rawValue: statement.string(2) ?? "modified") ?? .modified))
        }
        return out
    }

    // MARK: roots

    /// The change-detection root set (section 6.5). One directory may carry several
    /// reasons and leaves the set only when the last one goes.
    public func addRoot(path: Data, reason: String) throws {
        let statement = try connection.prepare("""
            INSERT INTO roots (path, reason, last_seen) VALUES (?1, ?2, ?3)
            ON CONFLICT(path, reason) DO UPDATE SET last_seen = excluded.last_seen
            """)
        statement.bind(1, path)
        statement.bind(2, reason)
        statement.bind(3, Date().timeIntervalSince1970)
        try statement.run()
    }

    public func removeRoot(path: Data, reason: String) throws {
        let statement = try connection.prepare(
            "DELETE FROM roots WHERE path = ?1 AND reason = ?2")
        statement.bind(1, path)
        statement.bind(2, reason)
        try statement.run()
    }

    public func roots() throws -> [(path: Data, reason: String, lastSeen: Double)] {
        let statement = try connection.prepare(
            "SELECT path, reason, last_seen FROM roots ORDER BY last_seen")
        defer { statement.reset() }
        var out: [(Data, String, Double)] = []
        while try statement.step() {
            out.append((statement.data(0) ?? Data(), statement.string(1) ?? "", statement.double(2)))
        }
        return out.map { (path: $0.0, reason: $0.1, lastSeen: $0.2) }
    }

    // MARK: backup

    /// `VACUUM INTO` once a day, after a reconcile, and after pin changes, debounced to
    /// at most one per minute (section 5.3). The restore direction, which goes into the
    /// live database through the online backup API, is milestone 5 and is not here yet.
    public func backup(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try connection.execute("VACUUM INTO '\(escaped)'")
    }

    private static let columns = """
        identifier, path, parent, type, size, mtime, mtime_ns, inode, uid, gid, mode, \
        generation, content_version, metadata_version, last_fetch, pin_state, kept, \
        capabilities, fs_flags, link_target, hidden, xattrs, local_content
        """
}
