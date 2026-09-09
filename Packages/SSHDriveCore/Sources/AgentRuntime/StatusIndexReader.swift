import Foundation
import AgentCore
import Config
import Index
import Logging

/// The agent's own read-only view of one location's index, for `sshdrive status`
/// (DESIGN.md sections 8, 8.1, 5.2, 5.3).
///
/// `LocationRuntime` is an actor because the index has a single writer by design, and a
/// directory listing writes its rows inside one **synchronous** SQLite transaction on it
/// (section 5.3). Every hop `status` made onto that actor therefore queued behind whatever
/// listing was in flight, and `status` made eighteen of them per location: the hidden
/// names, the held deletions, the root set, the eviction rows, the pin tree. A `status`
/// run while Finder was walking a large folder waited for the walk (2026-09-09).
///
/// Section 5.2 already sanctions the answer: `index.sqlite` is opened **read-only in WAL
/// mode**, which is what the extension does for `item(for:)` and the working set. A WAL
/// reader never blocks the writer and never delays it, and it always sees a consistent
/// snapshot - the state as of the last commit, which for a listing in flight is the state
/// before it. The agent remains the sole writer; nothing here writes.
///
/// An actor rather than a bare class because `IndexReader` holds prepared statements and
/// one connection: two `status` calls for the same location must not use it at once. It is
/// not the *writer's* actor, which is the whole point.
public actor StatusIndexReader {

    /// Everything one `status` row takes from the index, in one read.
    ///
    /// A value rather than a set of calls because the caller is off the actor and the
    /// point of this type is that it is asked once: `status` builds a row from this plus
    /// one entry on `LocationRuntime` for the things only the live runtime knows.
    public struct Report {
        /// Nil when the index answered. A sentence when it could not - no index file yet,
        /// a rebuild in progress (section 5.3), a schema this build does not understand -
        /// which `status` prints in place of the index-derived lines rather than failing
        /// the whole report.
        public var unavailable: String?
        /// Section 5.4's "not shown" list.
        public var notShown: [[String: Any]] = []
        /// Section 6.4's held deletions, and how many of them.
        public var held: [[String: Any]] = []
        public var heldCount = 0
        /// Section 6.4's watch bookkeeping, as `LocationRuntime.watchReport` reported it
        /// from the writer: the stored tier, the sweep's server clock, the last full
        /// sweep, and the root set's size and rotation period.
        public var watch: [String: Any] = [:]
        /// Section 7's TTL candidates behind the identifiers the system says it holds
        /// content for.
        public var cacheCandidates: [EvictionPlan.Candidate] = []
        /// Section 7.1's marker tree.
        public var pins: [[String: Any]] = []

        public init() {}
    }

    private let locationID: String
    private let path: String
    private var reader: IndexReader?
    /// Shut for the truncate window of a restore, exactly like the extension's reader: the
    /// reader holds the `-shm` mapped and truncating a mapped file under a live process
    /// faults it on its next access (section 5.3).
    private var closedForRestore = false

    public init(locationID: String, path: String) {
        self.locationID = locationID
        self.path = path
    }

    // MARK: The connection

    /// Opened on first use and kept. A location whose index does not exist yet - one that
    /// has never started - is not an error: it is a location with nothing to report, and
    /// the next call tries again, because the writer creates the file when it starts.
    private func connection() throws -> IndexReader {
        if let reader { return reader }
        let opened = try IndexReader(path: path)
        reader = opened
        return opened
    }

    /// Drops the connection so the next call opens a fresh one. Called for any failure:
    /// a database replaced under us reads through a stale page cache otherwise
    /// (section 5.3).
    private func discard() {
        reader?.close()
        reader = nil
    }

    /// `IndexReconcile` is about to truncate the file. Same contract as the extension's
    /// reader, and for the same reason.
    public func close() {
        closedForRestore = true
        discard()
    }

    public func reopen() {
        closedForRestore = false
    }

    // MARK: The one read

    /// One report, from one connection, off the writer's actor.
    ///
    /// - Parameters:
    ///   - hiddenReasons: the sentences `LocationRuntime` recorded while it built the rows
    ///     (section 5.4). They are runtime state rather than index state, so they are
    ///     handed in with the rest of the live facts; the derived sentence is the fallback,
    ///     which is exactly what the runtime's own `notShown()` does.
    ///   - materialized: the identifiers the system says it holds content for, or nil for
    ///     an unmounted location, which has no replica to walk. Nil skips the cache and pin
    ///     download counts rather than reporting them as zero.
    public func report(
        hiddenReasons: [Data: String], materialized: [String]?
    ) -> Report {
        var report = Report()
        guard !closedForRestore else {
            report.unavailable = "the index is being rebuilt"
            return report
        }
        let index: IndexReader
        do {
            index = try connection()
        } catch {
            // No file yet is the ordinary case for a location that has never started.
            report.unavailable =
                FileManager.default.fileExists(atPath: path)
                ? "the index could not be opened: \(error.localizedDescription)"
                : "this location has no index yet"
            return report
        }
        do {
            if try index.isReconciling() {
                report.unavailable = "the index is being rebuilt against the replica"
                return report
            }
            report.notShown = try index.allItems().filter { $0.hidden != 0 }.map {
                StatusIndexReader.notShownEntry(row: $0, hiddenReasons: hiddenReasons)
            }
            let held = try index.heldRows()
            report.held = held.map(StatusIndexReader.heldEntry(row:))
            report.heldCount = held.count
            report.watch = try StatusIndexReader.watchFields(index)
            if let materialized {
                report.cacheCandidates = try materialized.compactMap {
                    try index.itemIfPresent(identifier: $0)
                }.map(StatusIndexReader.candidate(row:))
                report.pins = try StatusIndexReader.pinEntries(
                    index, materialized: Set(materialized))
            }
        } catch {
            discard()
            report.unavailable = "the index could not be read: \(error.localizedDescription)"
            Log.agent.error(
                "\(self.locationID, privacy: .public): status could not read the index: \(error.localizedDescription, privacy: .public)"
            )
        }
        return report
    }

    // MARK: The mappings, shared with the writer

    /// One "not shown" entry (section 5.4). Static and shared so the writer's own
    /// `notShown()` and this reader cannot describe the same row differently.
    public static func notShownEntry(row: IndexItem, hiddenReasons: [Data: String])
        -> [String: Any]
    {
        [
            "path": String(decoding: row.path, as: UTF8.self),
            "reason": hiddenReasons[row.path] ?? derivedHiddenReason(row.hidden),
        ]
    }

    public static func derivedHiddenReason(_ hidden: Int64) -> String {
        switch hidden {
        case RowBuilder.hiddenEscapingLink:
            return "a symbolic link whose target is outside this location"
        case RowBuilder.hiddenLocalOnly:
            return "kept on this Mac only"
        default:
            return "a name macOS cannot tell from another here"
        }
    }

    /// Section 8's "14 deletions held in Photos, re-check at 14:32".
    public static func heldEntry(row: IndexWriter.HeldRow) -> [String: Any] {
        [
            "path": String(decoding: row.path, as: UTF8.self),
            "directory": String(decoding: row.dir, as: UTF8.self),
            "firstMissing": row.firstMissing,
            "recheckAt": row.recheckAt,
            "checks": row.checks,
            "reason": row.reason,
        ]
    }

    /// One TTL candidate (section 7). The rule itself is `EvictionPlan`'s; this is only
    /// the row.
    public static func candidate(row: IndexItem) -> EvictionPlan.Candidate {
        EvictionPlan.Candidate(
            identifier: row.identifier,
            path: String(decoding: row.path, as: UTF8.self),
            isDirectory: row.type == "directory",
            // Section 5.4's local-only row: there is nothing on the server to fetch back,
            // so evicting it would take the user's file.
            isLocalOnly: row.hidden == RowBuilder.hiddenLocalOnly,
            kept: row.kept,
            size: row.size,
            lastFetch: row.lastFetch,
            mtime: Double(row.mtime),
            atime: nil)
    }

    /// Section 7.1's marker tree with what each subtree costs.
    static func pinEntries(_ index: IndexReader, materialized: Set<String>?) throws
        -> [[String: Any]]
    {
        let markers = PinMarkerSet(rows: try index.pinMarkerRows())
        var out: [[String: Any]] = []
        for (path, marker) in markers.markers.sorted(by: {
            $0.key.lexicographicallyPrecedes($1.key)
        }) {
            var rows = try index.items(under: path)
            if let own = try index.item(path: path) { rows.append(own) }
            out.append(
                pinEntry(
                    path: path, marker: marker, rows: rows, markers: markers,
                    materialized: materialized))
        }
        return out
    }

    /// One row of `sshdrive pins`, from rows either connection can produce.
    public static func pinEntry(
        path: Data, marker: PinPolicy.Marker, rows: [IndexItem], markers: PinMarkerSet,
        materialized: Set<String>?
    ) -> [String: Any] {
        var files = 0
        var bytes: Int64 = 0
        var downloadedFiles = 0
        var downloadedBytes: Int64 = 0
        for row in rows where row.type != "directory" {
            files += 1
            bytes += row.size
            let isDownloaded =
                materialized.map { $0.contains(row.identifier) } ?? (row.lastFetch != nil)
            if isDownloaded {
                downloadedFiles += 1
                downloadedBytes += row.size
            }
        }
        var entry: [String: Any] = [
            "path": String(decoding: path, as: UTF8.self),
            "state": marker == .pinned ? "pinned" : "excluded",
            "kept": marker == .pinned,
            "files": files,
            "bytes": bytes,
            "downloadedFiles": downloadedFiles,
            "downloadedBytes": downloadedBytes,
            // The depth is what the CLI indents by: an exclusion inside a pin is drawn
            // under it (section 7.1).
            "depth": markers.ancestorMarkerDepth(of: path),
        ]
        if let covering = markers.nearestAncestorMarker(of: path) {
            entry["under"] = String(decoding: covering.path, as: UTF8.self)
        }
        return entry
    }

    /// The index half of section 8's watch line. The live half - the tier the detector is
    /// actually running and the last cycle's outcome - is merged over this by the caller,
    /// exactly as `status` has always merged the detector's answer over the runtime's.
    static func watchFields(_ index: IndexReader) throws -> [String: Any] {
        var out: [String: Any] = [:]
        if let tier = try index.metaString(IndexSchema.MetaKey.watchTier) { out["tier"] = tier }
        if let stamp = (try index.metaString(IndexSchema.MetaKey.sweepServerTime)).flatMap(
            Int64.init)
        {
            out["sweepServerTime"] = stamp
        }
        out["lastFullSweep"] =
            (try index.metaString(IndexSchema.MetaKey.lastFullSweep)).flatMap(Double.init) ?? 0
        out["heldDeletions"] = try index.heldCount()
        let set = LocationRuntime.rootSet(from: try index.rootRows())
        out["roots"] = set.entries.count
        out["rotationPeriod"] = set.rotationPeriod()
        return out
    }
}
