import Foundation
import FileProvider
import AgentCore
import Config
import Index
import SFTP
import XPCProtocols
import Logging

/// DESIGN.md sections 7.1, 7.1.1 and 7.1.2: the pin half of the runtime.
///
/// The index is the only authority for markers (`pin_state`), and the agent is its only
/// writer, so every pin change - from the CLI or from Finder's context menu - lands here.
/// `PinPolicy` decides *what* to write; this file writes it, rewrites the rows the change
/// moves, and does the two things that make the system act on it: the working-set anchors
/// and the replica lookup.
extension LocationRuntime {

    /// The `allowsEvicting` bit, which is the only part of `capabilities` the kept state
    /// decides (`ItemDerivation.capabilities`). Flipping it is therefore the whole
    /// re-derivation a pin change needs, and a rewrite of a subtree costs no `lstat`s.
    ///
    /// The bit is not what refuses an eviction - the eager `contentPolicy` is, and
    /// `allowsEvicting` is deprecated since macOS 13 and reported by the system from
    /// `isDownloaded` rather than from us (S6, 2026-09-04, section 7.2). It is served
    /// truthfully anyway, because it costs nothing and the header still documents it.
    static let evictingBit = Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)

    // MARK: Reading the markers

    /// Every explicit marker in this location, as the value section 7.1.1's rules are
    /// written against.
    func pinMarkers() throws -> PinMarkerSet {
        PinMarkerSet(rows: try index.pinMarkerRows())
    }

    /// `sshdrive pins`: the marker tree with what each subtree costs.
    ///
    /// Section 7.1 renders exclusions indented under the pin they sit in, with the cached
    /// size and file count, "so the user can see what they've signed up for".
    /// `materialized` is the system's own set; without it the report still shows what is on
    /// the server and says nothing about what is downloaded.
    func pinsReport(materialized: Set<String>? = nil) throws -> [[String: Any]] {
        let markers = try pinMarkers()
        var out: [[String: Any]] = []
        for (path, marker) in markers.markers.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            var rows = try index.items(under: path)
            if let own = try index.item(path: path) { rows.append(own) }
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
            out.append(entry)
        }
        return out
    }

    /// `sshdrive pins --export`: the markers as JSON, for anyone who rebuilds an index or
    /// moves to a new Mac (section 7.1).
    func exportPins() throws -> [[String: Any]] {
        try index.pinMarkerRows().map {
            ["path": String(decoding: $0.path, as: UTF8.self), "state": $0.marker == 1 ? "pinned" : "excluded"]
        }
    }

    /// `pins.json` beside the index: "a write-only copy for recovery, never read while the
    /// index is healthy" (section 7.1). Rewritten after every marker change.
    func writePinsSidecar() {
        guard let url = try? GroupContainer.pinsURL(locationID: location.id),
            let rows = try? exportPins()
        else { return }
        let payload: [String: Any] = [
            "location": location.id,
            "writtenAt": Date().timeIntervalSince1970,
            "pins": rows,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: The pin change itself (section 7.1 steps 1, 2, 4)

    /// One `pin` or `unpin`, on exactly the path named (invariant 1).
    ///
    /// The five steps of section 7.1, in order:
    ///
    /// 1. **Store the pin.** From Finder the row always exists. From the CLI the path may
    ///    never have been enumerated, so each missing ancestor is `readdir`ed into the
    ///    index from the nearest known one; a path that is not on the server, or is a
    ///    symlink, is refused (section 5.7 - a link is never followed, so "keep the folder
    ///    it points at" is not a thing a pin can mean).
    /// 2. **Declare the policy.** The marker is written, every explicit state beneath it is
    ///    deleted (invariant 2), and the row *and every known descendant row* get their
    ///    `kept`, `capabilities` and metadata version rewritten in one transaction with an
    ///    anchor each. The descendants are not optional: `contentPolicy` is inherited by
    ///    the system, but `userInfo.kept`, the badge and the capabilities are per item and
    ///    cached until that item's own metadata version moves.
    /// 3. **Keep it current** is the root set (section 6.5): a pin root joins it, watched
    ///    recursively, and leaves it when the pin goes.
    /// 4. The working-set signal and the **replica lookup** are the caller's, because both
    ///    are File Provider calls and nothing that talks to the system should run while
    ///    this actor holds the index.
    func applyPin(pathString: String, request: PinPolicy.Request) async throws -> [String: Any] {
        try refuseWhileReconciling()
        let path = try LocationRuntime.pinPath(pathString)

        // Step 1. A row we already have answers the "is it there, is it a link" question
        // without a round trip, which is also what lets a pin be changed while the server
        // is unreachable.
        var existing = try index.item(path: path.bytes)
        var createdAncestors: [String] = []
        if existing == nil {
            createdAncestors = try await materializeAncestors(of: path)
            existing = try index.item(path: path.bytes)
        }
        guard let row = existing else {
            throw SSHDriveAgentError.noSuchItem.asNSError(
                "\(path.description) is not in this location.")
        }
        guard row.type != "symlink" else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "\(path.description) is a symbolic link. Links are never followed, so pin "
                    + "what the link points at instead (section 5.7).")
        }

        var markers = try pinMarkers()
        let change = markers.plan(request, at: path.bytes)
        var report: [String: Any] = [
            "path": path.description.isEmpty ? "/" : path.description,
            "identifier": row.identifier,
            "situation": change.situation.rawValue,
            "note": change.note,
            "kept": change.keptAfter,
            "changed": !change.isNoOp,
            "ancestorRowsCreated": createdAncestors.count,
            "isDirectory": row.type == "directory",
        ]
        if let covering = markers.nearestAncestorMarker(of: path.bytes) {
            report["coveredBy"] = String(decoding: covering.path, as: UTF8.self)
        }
        guard !change.isNoOp, let marker = change.newMarker else {
            report["clearedPins"] = 0
            report["clearedExclusions"] = 0
            report["rowsRewritten"] = 0
            return report
        }

        let outcome = try commit(change, at: path.bytes, row: row, markers: &markers)
        let clearedPins = outcome.clearedPins
        let clearedExclusions = outcome.clearedExclusions
        let rewritten = outcome.rewritten

        report["clearedPins"] = clearedPins.count
        report["clearedExclusions"] = clearedExclusions.count
        report["rowsRewritten"] = rewritten
        report["marker"] = marker.rawValue
        Log.agent.notice(
            "\(self.location.id, privacy: .public): \(request.rawValue, privacy: .public) \(path.description, privacy: .public) -> \(change.note, privacy: .public); \(rewritten, privacy: .public) row(s) rewritten"
        )
        return report
    }

    /// The write half of a marker change, shared by `pin`/`unpin`, by Finder's two
    /// entries and by the `debug policy` hook that spike S6 is written against.
    ///
    /// Invariant 2 first: every explicit state beneath the path is deleted, which is what
    /// makes the rewrite below a single value rather than a per-row ancestor walk - after
    /// the clearing, every known descendant inherits exactly what the changed path says.
    private func commit(
        _ change: PinPolicy.Change, at pathBytes: Data, row: IndexItem,
        markers: inout PinMarkerSet
    ) throws -> (clearedPins: [Data], clearedExclusions: [Data], rewritten: Int) {
        guard let marker = change.newMarker else { return ([], [], 0) }
        let clearedPaths = markers.explicitStatesBelow(pathBytes)
        let clearedPins = clearedPaths.filter { markers.marker(at: $0) == .pinned }
        let clearedExclusions = clearedPaths.filter { markers.marker(at: $0) == .excluded }
        markers.apply(change, at: pathBytes)

        var rewritten = 0
        try index.batch {
            var changed = row
            changed.pinState = marker.rawValue
            try applyKept(&changed, kept: change.keptAfter)
            rewritten += 1

            for var descendant in try index.items(under: pathBytes) {
                let hadMarker = descendant.pinState != 0
                descendant.pinState = 0
                if !hadMarker && descendant.kept == change.keptAfter { continue }
                try applyKept(&descendant, kept: change.keptAfter)
                rewritten += 1
            }

            // Section 6.5: a pin root is in the root set, watched recursively; a path that
            // has stopped being one leaves, and so does every pin the change cleared.
            for cleared in clearedPins {
                try index.removeRoot(path: cleared, reason: RootReason.pinned.rawValue)
            }
            if marker == .pinned {
                try index.addRoot(path: pathBytes, reason: RootReason.pinned.rawValue)
            } else {
                try index.removeRoot(path: pathBytes, reason: RootReason.pinned.rawValue)
            }
        }

        // Directories under a pin root take neither the `viewed` nor the `materialized`
        // reason: the recursive watch already covers them (section 6.5).
        _ = try? refreshRootSet(materializedIdentifiers: nil)
        writePinsSidecar()
        return (clearedPins, clearedExclusions, rewritten)
    }

    /// `sshdrive debug policy <name> <path> eager-keep|lazy|inherit`: the raw marker, which
    /// spike S6 drives the content policy with. `pin` and `unpin` are the user-facing pair
    /// (section 7.1.1's invariant 3); this writes whichever of the three states is named and
    /// then does exactly what they do to the subtree.
    @discardableResult
    func setPinState(pathString: String, marker rawMarker: Int64) async throws -> [String: Any] {
        let path = try LocationRuntime.pinPath(pathString)
        let createdAncestors = try await materializeAncestors(of: path)
        guard let row = try index.item(path: path.bytes) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(pathString).")
        }
        var markers = try pinMarkers()
        let marker = PinPolicy.Marker(rawMarker: rawMarker)
        var after = markers
        after.apply(
            PinPolicy.Change(
                situation: markers.situation(of: path.bytes), isNoOp: false, newMarker: marker,
                clearsDescendants: true, keptAfter: false, note: ""),
            at: path.bytes)
        let keptAfter = after.isKept(path.bytes)
        let change = PinPolicy.Change(
            situation: markers.situation(of: path.bytes), isNoOp: false, newMarker: marker,
            clearsDescendants: true, keptAfter: keptAfter, note: "debug policy")
        let outcome = try commit(change, at: path.bytes, row: row, markers: &markers)
        return [
            "identifier": row.identifier,
            "kept": keptAfter,
            "capabilities": (try index.item(path: path.bytes)?.capabilities) ?? 0,
            "metadataVersion": (try index.item(path: path.bytes)?.metadataVersion) ?? "",
            "ancestorRowsCreated": createdAncestors.count,
            "rowsRewritten": outcome.rewritten,
        ]
    }

    /// The kept state and everything derived from it, on one row, with its anchor.
    ///
    /// Only `allowsEvicting` and the metadata version move: every other derived field is a
    /// function of the mode and the parent's mode, which a pin does not touch. The metadata
    /// version has to move or the system will not re-read the item at all (section 5.3).
    private func applyKept(_ row: inout IndexItem, kept: Bool) throws {
        row.kept = kept
        row.capabilities =
            kept
            ? row.capabilities & ~LocationRuntime.evictingBit
            : row.capabilities | LocationRuntime.evictingBit
        row.metadataVersion = ItemDerivation.metadataVersion(
            contentVersion: row.contentVersion,
            mode: row.mode, uid: row.uid, gid: row.gid,
            capabilities: row.capabilities, fileSystemFlags: row.fileSystemFlags,
            kept: row.kept, xattrs: row.xattrs)
        try index.upsert(row)
        try index.appendAnchor(identifier: row.identifier, kind: .modified)
    }

    /// `/` and `.` both name the location root (section 7.1.2); everything else is an
    /// ordinary relative path through the one chokepoint (section 9.1).
    static func pinPath(_ text: String) throws -> RelativePath {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" || trimmed == "." { return .root }
        return try RelativePath(string: trimmed)
    }

    // MARK: What the pin costs the watcher (sections 6.5, 7.1.1)

    /// Every known directory inside a kept subtree, which is what tier 0 lists on top of
    /// the root set: "a pinned root puts the whole location into the recursive part of the
    /// root set ... at tier 0 that is a `readdir` of every directory in the location per
    /// cycle" (section 7.1.2). Excluded subtrees are skipped, since the recursive watch of
    /// a kept subtree skips them (section 7.1.1).
    ///
    /// Tier 1 needs none of this: the pin roots go to `find` as recursive roots and the
    /// exclusions go with them as `-path ... -prune` globs.
    func pinnedSubtreeDirectories() throws -> [Data] {
        let markers = try pinMarkers()
        guard !markers.pinRoots.isEmpty else { return [] }
        var out: [Data] = []
        for pin in markers.pinRoots {
            for row in try index.items(under: pin) where row.type == "directory" {
                if markers.isKept(row.path) { out.append(row.path) }
            }
        }
        return out
    }

    /// The `-path <glob> -prune` list one sweep takes: every exclusion that really sits
    /// inside a pinned subtree, spelled the way the sweep spells a root (`./name`).
    func excludedSweepPaths() throws -> [String] {
        try pinMarkers().prunedExclusions().compactMap(LocationRuntime.utf8Root)
    }

    // MARK: Section 7.2's safety net

    /// A kept file that turned dataless without our handler having run is **re-asserted**,
    /// not read as an unpin: the agent bumps its metadata version and signals the working
    /// set so the system re-applies the eager policy and fetches it again.
    ///
    /// "Turning" is the operative word. A freshly pinned tree is full of kept files that
    /// are dataless because their eager download has not reached them yet, so only a file
    /// the agent had *seen* materialized in an earlier pass counts - which is what
    /// `keptAndMaterialized` remembers.
    ///
    /// Returns the paths re-asserted, which `status` reports ("3 kept files were evicted
    /// outside SSH Drive and re-downloaded").
    @discardableResult
    func reassertKeptItems(materializedIdentifiers: [String]?) throws -> [String] {
        guard let materializedIdentifiers else { return [] }
        let now = Set(materializedIdentifiers)
        let gone = keptAndMaterialized.subtracting(now)
        var reasserted: [String] = []
        if !gone.isEmpty {
            try index.batch {
                for identifier in gone.sorted() {
                    guard var row = try index.item(identifier: identifier), row.kept,
                        row.type != "directory"
                    else { continue }
                    // The version has to move for the system to re-read the item at all;
                    // the generation is untouched, since the *content* did not change.
                    try applyKept(&row, kept: true)
                    reasserted.append(String(decoding: row.path, as: UTF8.self))
                }
            }
        }
        // Remember only the kept ones: an unkept file going dataless is the TTL loop or
        // Finder's own "Remove Download" doing exactly what they should.
        var stillKept: Set<String> = []
        for identifier in now {
            if let row = try index.item(identifier: identifier), row.kept, row.type != "directory" {
                stillKept.insert(identifier)
            }
        }
        keptAndMaterialized = stillKept
        if !reasserted.isEmpty {
            keptEvictedOutside += reasserted.count
            Log.agent.error(
                "\(self.location.id, privacy: .public): \(reasserted.count, privacy: .public) kept file(s) were evicted outside SSH Drive; the pin was re-asserted and they will be downloaded again"
            )
        }
        return reasserted
    }

    // MARK: What the eviction loop reads (section 7)

    /// The index's half of one TTL pass: the rows behind the identifiers the system says
    /// it holds content for. The replica `stat` and the `evictItem` are the loop's, made
    /// outside this actor, so a slow File Provider call never sits in front of an
    /// `item(for:)` fallback or a fetch.
    func evictionRows(identifiers: [String]) throws -> [EvictionPlan.Candidate] {
        var out: [EvictionPlan.Candidate] = []
        for identifier in identifiers {
            guard let row = try index.item(identifier: identifier) else { continue }
            out.append(
                EvictionPlan.Candidate(
                    identifier: identifier,
                    path: String(decoding: row.path, as: UTF8.self),
                    isDirectory: row.type == "directory",
                    // Section 5.4's local-only row: there is nothing on the server to
                    // fetch back, so evicting it would take the user's file.
                    isLocalOnly: row.hidden == 3,
                    kept: row.kept,
                    size: row.size,
                    lastFetch: row.lastFetch,
                    mtime: Double(row.mtime),
                    atime: nil))
        }
        return out
    }

    /// After an eviction the row has no local content any more, so its `last_fetch` is a
    /// lie the next pass would trip over: cleared here, in the one place that knows the
    /// eviction succeeded.
    func noteEvicted(identifiers: [String]) throws {
        try index.batch {
            for identifier in identifiers {
                guard var row = try index.item(identifier: identifier), row.lastFetch != nil
                else { continue }
                row.lastFetch = nil
                try index.upsert(row)
            }
        }
    }

    /// Section 8.1's Cache line, and what `evict --all` needs to know before it runs.
    func cacheReport(candidates: [EvictionPlan.Candidate]) -> [String: Any] {
        let totals = EvictionPlan.totals(candidates)
        return [
            "files": totals.files,
            "bytes": totals.bytes,
            "keptFiles": totals.keptFiles,
            "keptBytes": totals.keptBytes,
            "ttl": location.cacheTTL.rawValue,
            "keptEvictedOutside": keptEvictedOutside,
        ]
    }
}
