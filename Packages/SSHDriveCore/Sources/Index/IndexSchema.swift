import Foundation

/// The per-domain index schema (docs/design/item-index.md). The agent is the only writer;
/// the extension opens the same file read-only in WAL mode.
public enum IndexSchema {
    /// Bumped whenever a column changes, or whenever the *meaning* of one does. At version
    /// 2 the `xattrs` blob holds a `LocalAttributes` object (extended attributes plus the
    /// Finder `tagData` that never arrives as an xattr,
    /// docs/design/names-and-attributes.md) rather than a bare dictionary. Version 3 adds
    /// `roots.last_listed`, the round-robin key of the tier 0 rotation, `held.checks` and
    /// `held.reason` for the mass-deletion guard, and the server's own clock from the last
    /// applied sweep in `meta`. An extension that finds a version newer than it understands
    /// falls back to asking the agent for items.
    public static let version = 3

    /// Keys in the `meta` table. The reader checks all three on every call.
    public enum MetaKey {
        public static let schemaVersion = "schema_version"
        /// Set for the whole reconcile walk. While it is set the extension answers
        /// item(for:) and the working-set enumerator with serverUnreachable rather than
        /// reading rows that are still being rebuilt.
        public static let reconciling = "reconciling"
        /// Bumped whenever the agent has replaced the database's contents wholesale. The
        /// reader reads it with the other two keys in the check it makes on every call, and
        /// hands it to the extension's state file. It is not what invalidates the statement
        /// cache: a `sqlite3_prepare_v2` statement re-prepares itself after a schema
        /// change, and the restore purges the cache anyway.
        public static let generation = "generation"
        /// The canonical absolute remote root this index was built against
        /// (docs/design/security.md).
        public static let remoteRoot = "remote_root"
        /// The server's own `date +%s` from the last sweep whose results were *applied*
        /// (docs/design/change-detection.md). Stored only after the apply, never before: a
        /// stamp written ahead of the results would, if the sweep or the agent died between
        /// the two, claim we had seen everything up to a moment whose changes were never
        /// recorded, and the next sweep would ask for changes since then and never find
        /// them.
        public static let sweepServerTime = "sweep_server_time"
        /// Our own clock at the last full sweep of the root set, which is what the
        /// 30-minute insurance pass times from (docs/design/change-detection.md). It is
        /// deliberately not the server's: the interval between our own passes is ours to
        /// measure, and the two clocks need not agree.
        public static let lastFullSweep = "last_full_sweep"
        /// The change-detection tier actually in use (docs/design/change-detection.md), so
        /// `status` can answer for a location whose agent has just restarted and not yet
        /// re-probed.
        public static let watchTier = "watch_tier"
    }

    public static let createStatements = """
        CREATE TABLE IF NOT EXISTS items (
            identifier TEXT PRIMARY KEY,
            path BLOB UNIQUE NOT NULL,      -- server names are bytes and need not be UTF-8
            parent TEXT,
            type TEXT NOT NULL,             -- file | directory | symlink
            size INTEGER NOT NULL DEFAULT 0,
            mtime INTEGER NOT NULL DEFAULT 0,
            mtime_ns INTEGER,               -- helper or GNU sweep only; null means unknown
            inode INTEGER,                  -- helper or GNU sweep only; null means unknown
            uid INTEGER,
            gid INTEGER,
            mode INTEGER,
            generation INTEGER NOT NULL DEFAULT 0,
            content_version TEXT NOT NULL DEFAULT '',
            metadata_version TEXT NOT NULL DEFAULT '',
            last_fetch REAL,
            pin_state INTEGER NOT NULL DEFAULT 0,   -- 0 inherit, 1 pinned, -1 excluded
            kept INTEGER NOT NULL DEFAULT 0,        -- effective state, derived by the agent
            capabilities INTEGER NOT NULL DEFAULT 0,
            fs_flags INTEGER NOT NULL DEFAULT 0,
            link_target BLOB,
            hidden INTEGER NOT NULL DEFAULT 0,      -- 1 symlink, 2 collision, 3 local-only
            xattrs BLOB,
            local_content BLOB
        );
        CREATE INDEX IF NOT EXISTS items_parent ON items(parent);

        CREATE TABLE IF NOT EXISTS anchors (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            changed_identifier TEXT NOT NULL,
            change_kind TEXT NOT NULL,      -- modified | deleted
            at REAL NOT NULL
        );

        -- The change-detection root set (docs/design/root-set.md). `CREATE TABLE IF NOT
        -- EXISTS` only ever creates: on a database that already carries the table it sees
        -- the name, does nothing, and leaves whatever shape is there. Columns a later
        -- schema version adds (`roots.last_listed`, `held.checks`, `held.reason`) are put
        -- on by IndexWriter.migrate() instead.
        CREATE TABLE IF NOT EXISTS roots (
            path BLOB NOT NULL,
            reason TEXT NOT NULL,           -- materialized | pinned | viewed
            last_seen REAL NOT NULL,        -- when the reason was last refreshed; the viewed LRU key
            last_listed REAL NOT NULL DEFAULT 0,  -- when tier 0 last readdir'd it; the rotation key
            PRIMARY KEY (path, reason)
        );

        CREATE TABLE IF NOT EXISTS held (
            path BLOB PRIMARY KEY,
            dir BLOB NOT NULL,
            first_missing REAL NOT NULL,
            recheck_at REAL NOT NULL,
            checks INTEGER NOT NULL DEFAULT 0,  -- the re-checks at 5 and 30 minutes
            reason TEXT NOT NULL DEFAULT ''     -- why the deletion was held, for `status`
        );

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
}

/// One row of `items`, which is one finished item (docs/design/extension.md).
public struct IndexItem: Equatable, Sendable {
    public var identifier: String
    /// Empty for the root, which is a permanent row carrying the rootContainer identifier.
    public var path: Data
    public var parent: String?
    public var type: String
    public var size: Int64
    public var mtime: Int64
    public var mtimeNanoseconds: Int64?
    public var inode: Int64?
    public var uid: Int64?
    public var gid: Int64?
    public var mode: Int64?
    public var generation: Int64
    public var contentVersion: String
    public var metadataVersion: String
    public var lastFetch: Double?
    public var pinState: Int64
    public var kept: Bool
    public var capabilities: Int64
    public var fileSystemFlags: Int64
    public var linkTarget: Data?
    public var hidden: Int64
    public var xattrs: Data?
    public var localContent: Data?

    public init(
        identifier: String,
        path: Data,
        parent: String?,
        type: String,
        size: Int64 = 0,
        mtime: Int64 = 0,
        mtimeNanoseconds: Int64? = nil,
        inode: Int64? = nil,
        uid: Int64? = nil,
        gid: Int64? = nil,
        mode: Int64? = nil,
        generation: Int64 = 0,
        contentVersion: String = "",
        metadataVersion: String = "",
        lastFetch: Double? = nil,
        pinState: Int64 = 0,
        kept: Bool = false,
        capabilities: Int64 = 0,
        fileSystemFlags: Int64 = 0,
        linkTarget: Data? = nil,
        hidden: Int64 = 0,
        xattrs: Data? = nil,
        localContent: Data? = nil
    ) {
        self.identifier = identifier
        self.path = path
        self.parent = parent
        self.type = type
        self.size = size
        self.mtime = mtime
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.generation = generation
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.lastFetch = lastFetch
        self.pinState = pinState
        self.kept = kept
        self.capabilities = capabilities
        self.fileSystemFlags = fileSystemFlags
        self.linkTarget = linkTarget
        self.hidden = hidden
        self.xattrs = xattrs
        self.localContent = localContent
    }

    /// The last path component, decoded for display and for the item's filename. A name
    /// that is not valid UTF-8 never reaches here: it is hidden
    /// (docs/design/names-and-attributes.md).
    public var filename: String {
        guard !path.isEmpty else { return "" }
        // The bytes after the last slash, without cutting the whole path into components
        // to reach them: every snapshot and every `item(for:)` asks for this.
        guard let slash = path.lastIndex(of: 0x2F) else {
            return String(decoding: path, as: UTF8.self)
        }
        return String(decoding: path[path.index(after: slash)...], as: UTF8.self)
    }

    /// "size-mtime-generation" at every tier.
    public static func contentVersion(size: Int64, mtime: Int64, generation: Int64) -> String {
        "\(size)-\(mtime)-\(generation)"
    }

    /// A fresh item identifier: a UUID minted the first time we see a path, in the same
    /// uppercase hyphenated spelling `UUID().uuidString` gives.
    ///
    /// The bytes come from a generator seeded once per process out of the system's rather
    /// than from `Foundation.UUID()`, which asks the platform for entropy on every call. A
    /// first listing of a ten-thousand-entry directory mints ten thousand identifiers, and
    /// `Foundation.UUID()` spends seventy milliseconds of that one call. What a seeded
    /// generator gives up is unpredictability - an item identifier is a local name for a
    /// row, never a secret and never a capability - and what it keeps is the shape, the
    /// spelling and 122 bits of distinctness.
    public static func mintIdentifier() -> String {
        var bytes = IdentifierSource.shared.next16()
        // Version 4, variant 1, as `uuid_generate_random` sets them.
        bytes.6 = (bytes.6 & 0x0F) | 0x40
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        // Written straight into the string's own storage. Appending 36 `Character`s to a
        // `String` instead costs more than `UUID()` does.
        return String(unsafeUninitializedCapacity: 36) { out in
            var cursor = 0
            withUnsafeBytes(of: bytes) { raw in
                for offset in 0 ..< 16 {
                    if offset == 4 || offset == 6 || offset == 8 || offset == 10 {
                        out[cursor] = 0x2D
                        cursor += 1
                    }
                    let byte = raw[offset]
                    out[cursor] = IdentifierSource.hex[Int(byte >> 4)]
                    out[cursor + 1] = IdentifierSource.hex[Int(byte & 0x0F)]
                    cursor += 2
                }
            }
            return 36
        }
    }
}

/// The identifier generator behind `IndexItem.mintIdentifier()`: xoshiro256**, seeded
/// once from `SystemRandomNumberGenerator` and shared, because the alternative is a trip
/// to the kernel for every row a listing writes.
final class IdentifierSource: @unchecked Sendable {
    static let shared = IdentifierSource()
    static let hex: [UInt8] = Array("0123456789ABCDEF".utf8)

    private let lock = NSLock()
    private var state: (UInt64, UInt64, UInt64, UInt64)

    private init() {
        var system = SystemRandomNumberGenerator()
        state = (system.next(), system.next(), system.next(), system.next())
    }

    func next16() -> (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) {
        lock.lock()
        let high = next()
        let low = next()
        lock.unlock()
        return (
            UInt8(truncatingIfNeeded: high >> 56), UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40), UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24), UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8), UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56), UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40), UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24), UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8), UInt8(truncatingIfNeeded: low)
        )
    }

    /// Called under the lock.
    private func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }
}

/// One change-stream entry.
public struct IndexAnchorEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case modified
        case deleted
    }

    public var sequence: Int64
    public var identifier: String
    public var kind: Kind

    public init(sequence: Int64, identifier: String, kind: Kind) {
        self.sequence = sequence
        self.identifier = identifier
        self.kind = kind
    }
}

/// Errors the index raises. `.syncAnchorExpired` and `.reconciling` are the two the
/// extension must translate rather than swallow.
public enum IndexError: Error, Equatable {
    /// The system presented an anchor the index does not know: pruned, or rebuilt. Those
    /// are the only two sources.
    case syncAnchorExpired
    /// A reconcile is running. Answer serverUnreachable, never noSuchItem.
    case reconciling
    /// The schema is newer than this build understands. Fall back to the agent.
    case schemaTooNew(found: Int)
    case noSuchItem
    /// The reader is closed for the truncate window of a restore.
    case closed
}

/// The working-set change stream, read identically by the extension's read-only reader and
/// by the agent's writer (docs/design/extension.md, docs/design/item-index.md).
///
/// It lives here, taking a connection rather than sitting on either class, because the
/// extension has two ways to answer the working set - its own reader, and the agent over
/// XPC when the reader is not usable - and two copies of "what is a change since this
/// anchor" would drift. One query, one expiry rule, two callers.
public enum IndexChangeStream {
    public struct Page: Equatable, Sendable {
        public var entries: [IndexAnchorEntry]
        public var newAnchor: Int64
        public var hasMore: Bool

        public init(entries: [IndexAnchorEntry], newAnchor: Int64, hasMore: Bool) {
            self.entries = entries
            self.newAnchor = newAnchor
            self.hasMore = hasMore
        }
    }

    public static func newestSequence(_ connection: SQLiteConnection) throws -> Int64 {
        let statement = try connection.prepare("SELECT COALESCE(MAX(seq), 0) FROM anchors")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    public static func oldestSequence(_ connection: SQLiteConnection) throws -> Int64 {
        let statement = try connection.prepare("SELECT COALESCE(MIN(seq), 0) FROM anchors")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    /// Throws `.syncAnchorExpired` when the anchor is older than the oldest row still held;
    /// the caller hands out a fresh anchor and tells the agent, whose response is one full
    /// sweep of the root set.
    public static func changes(_ connection: SQLiteConnection, since anchor: Int64, limit: Int)
        throws -> Page
    {
        let oldest = try oldestSequence(connection)
        let newest = try newestSequence(connection)
        if anchor < oldest - 1 && oldest > 0 {
            throw IndexError.syncAnchorExpired
        }
        let statement = try connection.prepare(
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
        return Page(
            entries: entries, newAnchor: entries.last?.sequence ?? max(anchor, newest),
            hasMore: hasMore)
    }
}
