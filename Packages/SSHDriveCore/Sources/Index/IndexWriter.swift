import Foundation
import SQLite3
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
        try migrate()
    }

    // MARK: migration

    /// Brings an existing database up to `IndexSchema.version` without losing it.
    ///
    /// Every schema change so far has been an added column, and `CREATE TABLE IF NOT
    /// EXISTS` does not alter a table that is already there: it sees the name, does
    /// nothing, and leaves a version 2 database on the version 2 shape while the create
    /// statements above describe version 3. So each added column is applied explicitly,
    /// guarded by `PRAGMA table_info`, and only then does `meta.schema_version` move. The
    /// index is the only copy of the identifiers we hold (section 5.3), so an upgrade
    /// that dropped and recreated a table would cost every item its identity, its cache
    /// and its Finder tags for the sake of two columns.
    private func migrate() throws {
        try connection.transaction {
            // Version 3: the round-robin key of section 6.5's tier 0 rotation. `last_seen`
            // keeps its own meaning - when the reason was last refreshed, which is the
            // viewed set's LRU key - and the two move at different times.
            try addColumnIfAbsent(table: "roots", column: "last_listed", definition: "REAL NOT NULL DEFAULT 0")
            // Version 3: the guard re-checks at 5 and 30 minutes and applies the deletions
            // after the second, so it has to count them (section 6.4), and `status` prints
            // why a deletion is being held.
            try addColumnIfAbsent(table: "held", column: "checks", definition: "INTEGER NOT NULL DEFAULT 0")
            try addColumnIfAbsent(table: "held", column: "reason", definition: "TEXT NOT NULL DEFAULT ''")

            let stored = Int(try meta(IndexSchema.MetaKey.schemaVersion) ?? "") ?? 0
            if stored < IndexSchema.version {
                try setMeta(IndexSchema.MetaKey.schemaVersion, String(IndexSchema.version))
            }
        }
    }

    private func addColumnIfAbsent(table: String, column: String, definition: String) throws {
        if try columnExists(table: table, column: column) { return }
        // The default has to be a constant for SQLite to add a NOT NULL column in place,
        // which is why both new columns carry one.
        try connection.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let statement = try connection.prepare("PRAGMA table_info(\(table))")
        defer { statement.reset() }
        while try statement.step() {
            if statement.string(1) == column { return true }
        }
        return false
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

    /// Runs `body` inside one transaction. A directory listing writes a row per entry
    /// and an anchor per change, and a `data/many` with 10,000 entries is 10,000
    /// autocommits without this - each its own WAL frame and fsync, which is most of the
    /// time an enumeration of a large directory spends (measured against the testbed,
    /// 2026-09-04).
    public func batch<T>(_ body: () throws -> T) throws -> T {
        try connection.transaction(body)
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

            // `held` also carries the directory the deletion was inferred from, and the
            // guard's 5- and 30-minute re-checks are driven by re-listing that directory
            // (section 6.4). Left behind by a rename, every hold under the renamed
            // directory would be re-checked for ever against a name that no longer exists
            // and would never resolve.
            let dirs = try connection.prepare("SELECT rowid, dir FROM held")
            var dirMoves: [(Int64, Data)] = []
            while try dirs.step() {
                guard let dir = dirs.data(1) else { continue }
                if dir == oldPath {
                    dirMoves.append((dirs.int(0), newPath))
                } else if dir.starts(with: prefix) {
                    dirMoves.append((dirs.int(0), replacement + dir.dropFirst(prefix.count)))
                }
            }
            dirs.reset()
            let moveDir = try connection.prepare("UPDATE held SET dir = ?2 WHERE rowid = ?1")
            for (rowid, dir) in dirMoves {
                moveDir.bind(1, rowid)
                moveDir.bind(2, dir)
                try moveDir.run()
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

    /// The change stream from `sequence` forward, in order. The reader has its own
    /// version of this (`changes(since:)`, which also raises `.syncAnchorExpired`); the
    /// agent needs the plain query when it builds the working set itself (section 5.3),
    /// so this one reports what is there and leaves expiry to the reader, which is the
    /// side the system presents anchors to.
    public func anchorsSince(_ sequence: Int64, limit: Int) throws -> [IndexAnchorEntry] {
        let statement = try connection.prepare(
            "SELECT seq, changed_identifier, change_kind FROM anchors "
                + "WHERE seq > ?1 ORDER BY seq LIMIT ?2")
        statement.bind(1, sequence)
        statement.bind(2, Int64(limit))
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

    /// Drops a directory from the root set whatever its reasons, which is what a deleted
    /// directory needs: the reasons of section 6.5 are refreshed from live evidence and
    /// there is nothing left to refresh them from.
    public func removeRoot(path: Data) throws {
        let statement = try connection.prepare("DELETE FROM roots WHERE path = ?1")
        statement.bind(1, path)
        try statement.run()
    }

    /// One row of `roots`: one directory under one reason (section 6.5).
    public struct RootRow: Equatable, Sendable {
        public var path: Data
        public var reason: String
        /// When the reason was last refreshed. The `viewed` set's LRU key, which is what
        /// the 256-entry cap evicts by.
        public var lastSeen: Double
        /// When tier 0 last `readdir`'d this directory. The round-robin key: a cycle
        /// takes the 64 least recently listed `materialized`-only roots, so the cost per
        /// cycle is bounded whatever the set's size.
        public var lastListed: Double

        public init(path: Data, reason: String, lastSeen: Double, lastListed: Double) {
            self.path = path
            self.reason = reason
            self.lastSeen = lastSeen
            self.lastListed = lastListed
        }
    }

    /// The whole root set, least recently listed first, which is the order tier 0's
    /// rotation consumes it in (section 6.5).
    public func rootRows() throws -> [RootRow] {
        let statement = try connection.prepare(
            "SELECT path, reason, last_seen, last_listed FROM roots ORDER BY last_listed, path")
        defer { statement.reset() }
        var out: [RootRow] = []
        while try statement.step() {
            out.append(
                RootRow(
                    path: statement.data(0) ?? Data(),
                    reason: statement.string(1) ?? "",
                    lastSeen: statement.double(2),
                    lastListed: statement.double(3)))
        }
        return out
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

    /// Records that tier 0 has just listed this directory. It moves every reason row for
    /// the path, because the listing is of the directory and not of one reason for
    /// watching it, and it deliberately leaves `last_seen` alone: a `materialized` root
    /// that the rotation lists is not thereby a directory the user has looked at, and
    /// moving the LRU key would keep it in the capped `viewed` set for ever.
    public func markRootListed(path: Data, at: Double) throws {
        let statement = try connection.prepare("UPDATE roots SET last_listed = ?2 WHERE path = ?1")
        statement.bind(1, path)
        statement.bind(2, at)
        try statement.run()
    }

    /// How many rows carry this reason. `status` reports the rotation period from the
    /// `materialized` count, which is `ceil(M / 64)` cycles (section 6.5).
    public func rootCount(reason: String) throws -> Int {
        let statement = try connection.prepare("SELECT COUNT(*) FROM roots WHERE reason = ?1")
        statement.bind(1, reason)
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.int(0))
    }

    // MARK: held

    /// One held deletion: an item a listing said was gone, which the mass-deletion guard
    /// is not reporting yet (section 6.4).
    public struct HeldRow: Equatable, Sendable {
        public var path: Data
        /// The directory whose listing the item went missing from. The re-check re-lists
        /// this, once, for every item held under it.
        public var dir: Data
        public var firstMissing: Double
        public var recheckAt: Double
        /// How many re-checks have run. The deletions are applied after the second, at 5
        /// and then 30 minutes (section 6.4).
        public var checks: Int64
        /// Why it is held, for `sshdrive status`.
        public var reason: String

        public init(
            path: Data, dir: Data, firstMissing: Double, recheckAt: Double,
            checks: Int64 = 0, reason: String = ""
        ) {
            self.path = path
            self.dir = dir
            self.firstMissing = firstMissing
            self.recheckAt = recheckAt
            self.checks = checks
            self.reason = reason
        }
    }

    /// Holds one inferred deletion. An existing row keeps its `firstMissing` and its
    /// `checks`: the guard applies the deletions after the second re-check counted from
    /// when the item was *first* seen missing, so a re-list that finds it missing again
    /// must not restart that clock - it would hold the deletion for ever, one 5-minute
    /// re-check at a time.
    public func hold(path: Data, dir: Data, firstMissing: Double, recheckAt: Double, reason: String) throws {
        let statement = try connection.prepare("""
            INSERT INTO held (path, dir, first_missing, recheck_at, checks, reason)
            VALUES (?1, ?2, ?3, ?4, 0, ?5)
            ON CONFLICT(path) DO UPDATE SET
                dir = excluded.dir, recheck_at = excluded.recheck_at, reason = excluded.reason
            """)
        statement.bind(1, path)
        statement.bind(2, dir)
        statement.bind(3, firstMissing)
        statement.bind(4, recheckAt)
        statement.bind(5, reason)
        try statement.run()
    }

    public func heldRows() throws -> [HeldRow] {
        let statement = try connection.prepare(
            "SELECT \(Self.heldColumns) FROM held ORDER BY path")
        defer { statement.reset() }
        var out: [HeldRow] = []
        while try statement.step() { out.append(Self.decodeHeld(statement)) }
        return out
    }

    /// Everything held under one directory, which is the unit the re-check works in: one
    /// `readdir` answers for every item that went missing from it.
    public func heldRows(dir: Data) throws -> [HeldRow] {
        let statement = try connection.prepare(
            "SELECT \(Self.heldColumns) FROM held WHERE dir = ?1 ORDER BY path")
        statement.bind(1, dir)
        defer { statement.reset() }
        var out: [HeldRow] = []
        while try statement.step() { out.append(Self.decodeHeld(statement)) }
        return out
    }

    public func heldRow(path: Data) throws -> HeldRow? {
        let statement = try connection.prepare(
            "SELECT \(Self.heldColumns) FROM held WHERE path = ?1")
        statement.bind(1, path)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return Self.decodeHeld(statement)
    }

    private static func decodeHeld(_ statement: SQLiteStatement) -> HeldRow {
        HeldRow(
            path: statement.data(0) ?? Data(),
            dir: statement.data(1) ?? Data(),
            firstMissing: statement.double(2),
            recheckAt: statement.double(3),
            checks: statement.int(4),
            reason: statement.string(5) ?? "")
    }

    /// The item came back, so nothing was ever reported (section 6.4).
    public func releaseHold(path: Data) throws {
        let statement = try connection.prepare("DELETE FROM held WHERE path = ?1")
        statement.bind(1, path)
        try statement.run()
    }

    /// Releases the holds on a path and on everything beneath it, for when the directory
    /// itself comes back or is deleted outright.
    ///
    /// Containment is decided on bytes, never on a decoded `String`: server names need not
    /// be UTF-8 (section 5.4), and a lossy decode would make two different remote paths
    /// compare equal.
    public func releaseHolds(under path: Data) throws {
        try connection.transaction {
            var doomed: [Data] = []
            let select = try connection.prepare("SELECT path FROM held")
            while try select.step() {
                guard let candidate = select.data(0) else { continue }
                if Self.isPath(candidate, under: path) { doomed.append(candidate) }
            }
            select.reset()

            let delete = try connection.prepare("DELETE FROM held WHERE path = ?1")
            for candidate in doomed {
                delete.bind(1, candidate)
                try delete.run()
            }
        }
    }

    /// True when `root` is `candidate` itself or one of its ancestors. The separator is
    /// required, so "photos2" is not under "photos"; the empty root contains everything,
    /// which is the location root's own path (section 5.3).
    static func isPath(_ candidate: Data, under root: Data) -> Bool {
        if root.isEmpty { return true }
        if candidate == root { return true }
        return candidate.starts(with: root + Data([0x2F]))
    }

    /// One re-check has run and the item is still missing: count it and schedule the next
    /// (section 6.4). After the second the caller applies the deletions.
    public func noteHoldChecked(path: Data, nextRecheckAt: Double) throws {
        let statement = try connection.prepare(
            "UPDATE held SET checks = checks + 1, recheck_at = ?2 WHERE path = ?1")
        statement.bind(1, path)
        statement.bind(2, nextRecheckAt)
        try statement.run()
    }

    public func heldCount() throws -> Int {
        let statement = try connection.prepare("SELECT COUNT(*) FROM held")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.int(0))
    }

    private static let heldColumns = "path, dir, first_missing, recheck_at, checks, reason"

    // MARK: backup

    /// `VACUUM INTO` once a day, after a reconcile, and after pin changes, debounced to
    /// at most one per minute (section 5.3).
    public func backup(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try connection.execute("VACUUM INTO '\(escaped)'")
    }

    /// Restores a backup **into the live database, never over it** (section 5.3).
    ///
    /// The backup file is opened read-only and copied in with SQLite's online backup API,
    /// with this connection - the live one - as the destination, so the database keeps its
    /// inode and every handle already open on it keeps working. Replacing the file at the
    /// path was rejected twice over: the `-wal` and `-shm` sidecars belong to the old
    /// inode and a stale WAL would be replayed into the new file on first open, and the
    /// extension's reader (section 5.2), which holds the database open across calls,
    /// would go on reading the unlinked one and serve the corrupt index it was restored
    /// from.
    ///
    /// `meta.generation` is bumped afterwards because the contents have been replaced
    /// wholesale: that is the signal the reader re-reads its cached statements on. The
    /// anchors that came back are the backup's, so the caller expires them (section 5.3)
    /// and the agent answers the resulting fresh anchor with one full sweep.
    public func restore(fromBackupAt url: URL) throws {
        let source = try SQLiteConnection(path: url.path, mode: .readOnly)
        guard let backup = sqlite3_backup_init(connection.rawHandle, "main", source.rawHandle, "main")
        else {
            throw SQLiteConnection.SQLiteError(
                code: sqlite3_errcode(connection.rawHandle), message: connection.lastErrorMessage)
        }
        // -1: copy every remaining page in one step, so the whole restore is one write
        // transaction on the destination and no reader ever sees a half-restored index.
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else {
            throw SQLiteConnection.SQLiteError(code: stepResult, message: connection.lastErrorMessage)
        }
        guard finishResult == SQLITE_OK else {
            throw SQLiteConnection.SQLiteError(code: finishResult, message: connection.lastErrorMessage)
        }
        withExtendedLifetime(source) {}
        try bumpGeneration()
    }

    /// Truncates the database and its `-wal` and `-shm` sidecars to zero length **under
    /// their own inodes**, for the case where SQLite cannot open the file at all and there
    /// is no live connection to restore into (section 5.3).
    ///
    /// The extension is asked to close its reader before this runs, and that order is not
    /// negotiable: the reader holds the `-shm` mapped, and truncating a mapped file under
    /// a live process faults it on its next access. The sidecars go with the database
    /// because a zero-length database with a surviving WAL would have that WAL replayed
    /// into it on the next open. Truncating rather than unlinking is what keeps the inode,
    /// so a handle that survives anyway sees an empty file rather than a stale one.
    public static func truncateDatabaseFiles(at path: String) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = path + suffix
            guard FileManager.default.fileExists(atPath: file) else { continue }
            guard let handle = FileHandle(forWritingAtPath: file) else { continue }
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
        }
    }

    /// `PRAGMA integrity_check`. False is the agent's cue to restore from the backup and,
    /// failing that, to reconcile against the replica (section 5.3).
    public func integrityCheck() throws -> Bool {
        let statement = try connection.prepare("PRAGMA integrity_check")
        defer { statement.reset() }
        guard try statement.step() else { return false }
        return statement.string(0) == "ok"
    }

    private static let columns = """
        identifier, path, parent, type, size, mtime, mtime_ns, inode, uid, gid, mode, \
        generation, content_version, metadata_version, last_fetch, pin_state, kept, \
        capabilities, fs_flags, link_target, hidden, xattrs, local_content
        """
}
