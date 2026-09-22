import Foundation

/// The TTL selection of docs/design/eviction.md, as a pure value: given what the agent
/// knows about each materialized item and the clock, which ones may be evicted now.
///
/// The whole of that decision-making and none of its I/O. The loop that surrounds
/// it (`CacheEvictor`) enumerates the system's materialized set, `lstat`s each replica file
/// and calls `evictItem`; this type decides, so that the rule can be tested against an
/// injected clock rather than against a five-minute timer.
///
/// **What the TTL means.** atime follows the `relatime` rule, so a read of an
/// already-materialized file never moves it (measured on macOS 26.4, 2026-09-04), and the
/// TTL is therefore **time since the last fetch or save**, which `last_fetch` and mtime
/// carry between them.
///
/// atime is read and reported but **is not part of the decision**. Something in the system
/// advances the atime of a materialized replica file minutes after the fetch, with no read
/// of ours anywhere near it, and it lands *deferred* - the `stat` immediately after a
/// materialization still shows the old value (measured on macOS 26.4, 2026-09-05). With
/// atime in the `max` the TTL silently becomes "time since whatever last touched the
/// replica", which is neither what docs/design/eviction.md promises nor anything the user
/// can observe: a file fetched 280 s earlier survives a 60 s TTL because its atime is 23 s
/// old. `last_fetch` and mtime are the whole rule.
public enum EvictionPlan {

    /// One materialized item, as the loop sees it just before it decides.
    public struct Candidate: Equatable, Sendable {
        public var identifier: String
        /// Index path bytes rendered for the log; never used for a comparison.
        public var path: String
        public var isDirectory: Bool
        /// The local-only row of docs/design/names-and-attributes.md (`hidden = 3`):
        /// there is nothing on the server to fetch back, so evicting it would take the
        /// user's file.
        public var isLocalOnly: Bool
        /// The effective kept state (docs/design/pinning.md), from the row's `kept`
        /// column.
        public var kept: Bool
        /// Bytes, for the report `status` prints.
        public var size: Int64
        /// `items.last_fetch`, our own record of when the content was downloaded.
        public var lastFetch: Double?
        /// The row's mtime: "a file the user saved but never re-read was used".
        public var mtime: Double
        /// The replica's atime, read with `AT_SYMLINK_NOFOLLOW` **before** the eviction,
        /// since an eviction moves it. Nil when the `stat` failed. Evidence for the log
        /// and for a future spike; not part of the decision (see above).
        public var atime: Double?

        public init(
            identifier: String, path: String, isDirectory: Bool = false,
            isLocalOnly: Bool = false, kept: Bool = false, size: Int64 = 0,
            lastFetch: Double? = nil, mtime: Double = 0, atime: Double? = nil
        ) {
            self.identifier = identifier
            self.path = path
            self.isDirectory = isDirectory
            self.isLocalOnly = isLocalOnly
            self.kept = kept
            self.size = size
            self.lastFetch = lastFetch
            self.mtime = mtime
            self.atime = atime
        }
    }

    /// Why an item was passed over. Every one of these is a decision of ours; the refusals
    /// the *system* makes (a pending upload, an item whose eager policy forbids it) arrive
    /// later as `NSFileProviderErrorNonEvictable` and are not modelled here, because
    /// the error code says nothing about which of the two it was (measured on macOS 26.4,
    /// 2026-09-04).
    public enum Skip: String, Sendable {
        /// `cacheTTL = never`.
        case ttlNever
        /// The loop works file by file because a TTL is per file, not because a directory
        /// cannot be evicted: `evictItem` on a directory is recursive, which is what
        /// `evict --all` uses.
        case directory
        case localOnly
        /// Kept items are never evicted (docs/design/eviction.md).
        case kept
        case withinTTL
    }

    public struct Decision: Equatable, Sendable {
        public var candidate: Candidate
        public var evict: Bool
        public var skip: Skip?
        /// The later of the fetch and the save: "last use" (docs/design/eviction.md).
        public var lastUse: Double
        /// `now - lastUse`, for the log line and for `status`.
        public var ageSeconds: Double
    }

    /// Last use: the later of the file's mtime and the index's `last_fetch`, a fetch or a
    /// save and nothing else (docs/design/eviction.md; see above for why atime is not in
    /// it).
    public static func lastUse(_ candidate: Candidate) -> Double {
        max(candidate.mtime, candidate.lastFetch ?? 0)
    }

    /// One pass, decided. `ttl` is nil for `cacheTTL = never`, which evicts nothing.
    public static func decide(
        _ candidates: [Candidate], ttl: TimeInterval?, now: Double
    ) -> [Decision] {
        candidates.map { candidate in
            let use = lastUse(candidate)
            let age = now - use
            func decision(_ evict: Bool, _ skip: Skip?) -> Decision {
                Decision(
                    candidate: candidate, evict: evict, skip: skip, lastUse: use,
                    ageSeconds: age)
            }
            guard let ttl else { return decision(false, .ttlNever) }
            if candidate.isDirectory { return decision(false, .directory) }
            if candidate.isLocalOnly { return decision(false, .localOnly) }
            if candidate.kept { return decision(false, .kept) }
            // Strictly greater, as docs/design/eviction.md writes it: `now - lastUse > TTL`.
            guard age > ttl else { return decision(false, .withinTTL) }
            return decision(true, nil)
        }
    }

    /// The identifiers one pass evicts, oldest first so a pass cut short by a shutdown has
    /// still taken the stalest content.
    public static func identifiersToEvict(
        _ candidates: [Candidate], ttl: TimeInterval?, now: Double
    ) -> [String] {
        decide(candidates, ttl: ttl, now: now)
            .filter(\.evict)
            .sorted { $0.lastUse < $1.lastUse }
            .map(\.candidate.identifier)
    }

    /// What `sshdrive status` prints on its Cache line (docs/design/cli.md): how much the
    /// system holds and how much of it is kept.
    public struct CacheTotals: Equatable, Sendable {
        public var files: Int
        public var bytes: Int64
        public var keptFiles: Int
        public var keptBytes: Int64

        public init(files: Int = 0, bytes: Int64 = 0, keptFiles: Int = 0, keptBytes: Int64 = 0) {
            self.files = files
            self.bytes = bytes
            self.keptFiles = keptFiles
            self.keptBytes = keptBytes
        }
    }

    /// Directories carry no content, so they are counted in neither total.
    public static func totals(_ candidates: [Candidate]) -> CacheTotals {
        var totals = CacheTotals()
        for candidate in candidates where !candidate.isDirectory {
            totals.files += 1
            totals.bytes += candidate.size
            if candidate.kept {
                totals.keptFiles += 1
                totals.keptBytes += candidate.size
            }
        }
        return totals
    }
}
