import Foundation

/// The per-domain index schema, exactly as DESIGN.md section 5.3 sets it out. The agent
/// is the only writer; the extension opens the same file read-only in WAL mode.
public enum IndexSchema {
    /// Bumped whenever a column changes, or whenever the *meaning* of one does. Version 2
    /// is milestone 4: the `xattrs` blob now holds a `LocalAttributes` object (extended
    /// attributes plus the Finder `tagData` that never arrives as an xattr, section 5.4)
    /// rather than a bare dictionary. Version 3 is milestone 6: `roots` carries
    /// `last_listed`, the round-robin key of section 6.5's tier 0 rotation, `held` carries
    /// the re-check count and the reason section 6.4's guard reports, and `meta` carries
    /// the server's own clock from the last applied sweep. An extension that finds a
    /// version newer than it understands falls back to asking the agent for items
    /// (section 5.2).
    public static let version = 3

    /// Keys in the `meta` table. The reader checks all three on every call.
    public enum MetaKey {
        public static let schemaVersion = "schema_version"
        /// Set for the whole reconcile walk. While it is set the extension answers
        /// item(for:) and the working-set enumerator with serverUnreachable rather than
        /// reading rows that are still being rebuilt (section 5.2).
        public static let reconciling = "reconciling"
        /// Bumped whenever the agent has replaced the database's contents wholesale.
        /// The reader re-reads its cached prepared statements and schema on a change.
        public static let generation = "generation"
        /// The canonical absolute remote root this index was built against (section 9.1).
        public static let remoteRoot = "remote_root"
        /// The server's own `date +%s` from the last sweep whose results were *applied*
        /// (section 6.4). Stored only after the apply, never before: a stamp written
        /// ahead of the results would, if the sweep or the agent died between the two,
        /// claim we had seen everything up to a moment whose changes were never recorded,
        /// and the next sweep would ask for changes since then and never find them.
        public static let sweepServerTime = "sweep_server_time"
        /// Our own clock at the last full sweep of the root set, which is what the
        /// 30-minute insurance pass times from (section 6.4). It is deliberately not the
        /// server's: the interval between our own passes is ours to measure, and the two
        /// clocks need not agree.
        public static let lastFullSweep = "last_full_sweep"
        /// The change-detection tier actually in use (section 6.4), so `status` can answer
        /// for a location whose agent has just restarted and not yet re-probed.
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

        -- The change-detection root set (section 6.5). These two tables gained columns in
        -- schema version 3, and `CREATE TABLE IF NOT EXISTS` will not put them on a
        -- database that already has the table: it sees the name, does nothing, and leaves
        -- the old shape in place. IndexWriter.migrate() adds them explicitly.
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
            checks INTEGER NOT NULL DEFAULT 0,  -- the re-checks at 5 and 30 minutes (section 6.4)
            reason TEXT NOT NULL DEFAULT ''     -- why the deletion was held, for `status`
        );

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
}

/// One row of `items`, which is one finished item (DESIGN.md section 5.2).
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
    /// that is not valid UTF-8 never reaches here: it is hidden (section 5.4).
    public var filename: String {
        guard let last = path.split(separator: 0x2F).last else { return "" }
        return String(decoding: last, as: UTF8.self)
    }

    /// "size-mtime-generation" at every tier (section 5.3).
    public static func contentVersion(size: Int64, mtime: Int64, generation: Int64) -> String {
        "\(size)-\(mtime)-\(generation)"
    }
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
    /// The system presented an anchor the index no longer knows: pruned, or rebuilt
    /// (section 5.3). Those are the only two sources.
    case syncAnchorExpired
    /// A reconcile is running. Answer serverUnreachable, never noSuchItem.
    case reconciling
    /// The schema is newer than this build understands. Fall back to the agent.
    case schemaTooNew(found: Int)
    case noSuchItem
    /// The reader is closed for the truncate window of a restore (section 5.3).
    case closed
}
