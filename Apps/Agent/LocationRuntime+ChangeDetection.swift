import Foundation
import AgentCore
import Config
import Index
import Logging
import SFTP
import SSHProcess
import XPCProtocols

/// The half of a location that watches the server (DESIGN.md sections 6.4 and 6.5).
///
/// `ChangeDetector` decides *when* a cycle runs and *which tier* runs it; everything here
/// is what a cycle does to the index, and it lives on `LocationRuntime` because the agent
/// is the index's only writer (section 3) and because a listing and its anchors are one
/// transaction (section 5.3).
extension LocationRuntime {

    /// What one cycle, or one command, did.
    struct ChangeApplication: Sendable {
        var changed = 0
        var deleted = 0
        var held = 0
        var released = 0
        var listedDirectories = 0
        var errors: [String] = []

        var isEmpty: Bool { changed == 0 && deleted == 0 && held == 0 && released == 0 }

        mutating func absorb(_ result: LocationRuntime.ReconcileResult) {
            changed += result.changed.count
            deleted += result.deleted.count
            held += result.held.count
            released += result.released.count
            listedDirectories += 1
        }
    }

    // MARK: The mass-deletion guard (section 6.4)

    /// The paths the system currently lists in `enumeratorForPendingItems()`, refreshed at
    /// the start of every cycle. A deletion of one of these is held whatever the counts
    /// say: the system re-offers a pending edit on an item we report deleted as a
    /// `createItem`, that create collides with the path still on the server, and the
    /// system retries a collided create for ever with no alert - the save is stranded and
    /// the identifier is lost (S5, 2026-09-04).
    func setPendingPaths(_ pending: Set<Data>) {
        pendingPaths = pending
    }

    func pendingPathCount() -> Int { pendingPaths.count }

    /// Section 6.4, applied to the deletions one listing inferred. Runs inside the
    /// listing's own transaction (section 5.3), so a held path and its `held` row are
    /// written with the same atomicity as a deletion and its anchor.
    func applyGuardedDeletions(
        directory: RelativePath,
        missing: [(path: Data, identifier: String)],
        knownNonHidden: Int,
        seenPaths: Set<Data>,
        into result: inout ReconcileResult
    ) throws {
        // A path that was held and has come back is not a deletion at all: "if they
        // reappear, the hold is cleared and nothing was ever reported."
        for existing in try index.heldRows(dir: directory.bytes) where seenPaths.contains(existing.path) {
            try index.releaseHold(path: existing.path)
            result.released.append(existing.path)
        }

        guard !missing.isEmpty else { return }

        var alreadyHeld: [Data: Double] = [:]
        var checksDone: [Data: Int64] = [:]
        for row in try index.heldRows(dir: directory.bytes) {
            alreadyHeld[row.path] = row.firstMissing
            checksDone[row.path] = row.checks
        }

        let now = Date().timeIntervalSince1970
        let decision = MassDeletionGuard.evaluate(
            MassDeletionGuard.Input(
                directory: directory.bytes,
                isLocationRoot: directory.isRoot,
                knownNonHiddenCount: knownNonHidden,
                missing: missing.map(\.path),
                pending: pendingPaths,
                alreadyHeld: alreadyHeld,
                now: now))

        let identifiers = Dictionary(missing.map { ($0.path, $0.identifier) }) { first, _ in first }

        for path in decision.apply {
            guard let identifier = identifiers[path] else { continue }
            // Everything beneath a deleted directory goes with it: those paths are gone
            // whatever now sits at the name (section 5.3).
            let deleted = try RelativePath.fromIndexBytes(path)
            for descendant in try index.allItems()
            where descendant.path != path
                && (try? RelativePath.fromIndexBytes(descendant.path))?.isUnder(deleted) == true
            {
                try index.delete(identifier: descendant.identifier)
                result.deleted.append(descendant.identifier)
            }
            try index.delete(identifier: identifier)
            try index.releaseHolds(under: path)
            result.deleted.append(identifier)
        }

        for path in decision.hold {
            let first = alreadyHeld[path] ?? now
            let done = Int(checksDone[path] ?? 0)
            // Both re-checks done and the items still missing: `recheckTime` answers nil,
            // and the row is left due so the next cycle applies it rather than holding it
            // for another half hour.
            let next = MassDeletionGuard.recheckTime(firstMissing: first, checksDone: done)
                ?? (first + MassDeletionGuard.secondRecheck)
            try index.hold(
                path: path, dir: directory.bytes, firstMissing: first, recheckAt: next,
                reason: decision.reason ?? "held by the mass-deletion guard")
            result.held.append(path)
        }

        if let reason = decision.reason, !decision.hold.isEmpty {
            Log.agent.notice(
                "\(self.location.id, privacy: .public): \(reason, privacy: .public); `sshdrive accept-deletions` applies them now"
            )
        }
    }

    /// Section 6.4's re-check schedule: 5 minutes, then 30, then the deletions are
    /// applied. One re-`readdir` per directory that holds anything.
    func recheckHeldDeletions(now: Double = Date().timeIntervalSince1970) async -> ChangeApplication {
        var application = ChangeApplication()
        let rows: [IndexWriter.HeldRow]
        do { rows = try index.heldRows() } catch {
            application.errors.append("\(error)")
            return application
        }
        let due = rows.filter { $0.recheckAt <= now }
        guard !due.isEmpty else { return application }
        var directories = Set(due.map(\.dir))
        // A re-check bumps the counter first, so a directory the server refuses to list
        // cannot hold its items for ever.
        for row in due {
            let next = MassDeletionGuard.recheckTime(
                firstMissing: row.firstMissing, checksDone: Int(row.checks) + 1)
                ?? (row.firstMissing + MassDeletionGuard.secondRecheck)
            try? index.noteHoldChecked(path: row.path, nextRecheckAt: next)
        }
        if directories.isEmpty { directories.insert(Data()) }
        for directory in directories.sorted(by: { $0.count < $1.count }) {
            application.absorb(await listOne(directory))
        }
        return application
    }

    /// `sshdrive accept-deletions <name> [path]` (section 8): apply what the guard is
    /// holding, now. With no path, everything; with one, that path and its subtree.
    func acceptDeletions(pathString: String?) async throws -> Int {
        let scope: Data?
        if let pathString, pathString != "/" && pathString != "." {
            scope = try RelativePath(string: pathString).bytes
        } else {
            scope = nil
        }
        let rows = try index.heldRows()
        var applied = 0
        try index.batch {
            for row in rows {
                if let scope {
                    let rowPath = try RelativePath.fromIndexBytes(row.path)
                    guard rowPath.isUnder(try RelativePath.fromIndexBytes(scope)) else { continue }
                }
                if let item = try index.item(path: row.path) {
                    let path = try RelativePath.fromIndexBytes(row.path)
                    for descendant in try index.allItems()
                    where descendant.path != row.path
                        && (try? RelativePath.fromIndexBytes(descendant.path))?.isUnder(path) == true
                    {
                        try index.delete(identifier: descendant.identifier)
                    }
                    try index.delete(identifier: item.identifier)
                    applied += 1
                }
                try index.releaseHold(path: row.path)
            }
        }
        Log.agent.notice(
            "\(self.location.id, privacy: .public): accept-deletions applied \(applied, privacy: .public) held deletion(s)"
        )
        return applied
    }

    /// Section 8's `status` line: "14 deletions held in Photos, re-check at 14:32".
    func heldReport() throws -> [[String: Any]] {
        try index.heldRows().map { row in
            [
                "path": String(decoding: row.path, as: UTF8.self),
                "directory": String(decoding: row.dir, as: UTF8.self),
                "firstMissing": row.firstMissing,
                "recheckAt": row.recheckAt,
                "checks": row.checks,
                "reason": row.reason,
            ]
        }
    }

    // MARK: The root set (section 6.5)

    /// Rebuilds the `materialized` reason from the system's own
    /// `enumeratorForMaterializedItems()`, applies the 256-entry cap to `viewed`, and
    /// drops both reasons for directories that sit under a pin root, whose recursive
    /// watch already covers them.
    ///
    /// `materialized` is nil when the system had no manager for the domain, which happens
    /// while a domain is being added or removed. That is "no news", never "the user
    /// evicted everything": rebuilding the reason from an empty answer would silently
    /// stop watching every cached directory.
    @discardableResult
    func refreshRootSet(
        materializedIdentifiers: [String]?, now: Double = Date().timeIntervalSince1970
    ) throws -> RootSet {
        var rows = try index.rootRows()
        let pinned = Set(rows.filter { $0.reason == RootReason.pinned.rawValue }.map(\.path))

        func underPin(_ path: Data) -> Bool {
            for root in pinned where root != path {
                if root.isEmpty { return true }
                if path.count > root.count && path.starts(with: root + Data([0x2F])) { return true }
            }
            return false
        }

        if let materializedIdentifiers, !suppressMaterializedRefresh {
            // "every directory that contains at least one materialized file": the system
            // reports the files, so the root is each file's parent directory.
            var wanted: Set<Data> = []
            for identifier in materializedIdentifiers {
                guard let row = try index.item(identifier: identifier) else { continue }
                let path = try RelativePath.fromIndexBytes(row.path)
                let directory = row.type == "directory" ? path : (path.parent ?? .root)
                guard !underPin(directory.bytes) else { continue }
                wanted.insert(directory.bytes)
            }
            let existing = Set(
                rows.filter { $0.reason == RootReason.materialized.rawValue }.map(\.path))
            for gone in existing.subtracting(wanted) {
                try index.removeRoot(path: gone, reason: RootReason.materialized.rawValue)
            }
            for fresh in wanted.subtracting(existing) {
                try index.addRoot(path: fresh, reason: RootReason.materialized.rawValue)
            }
            if wanted != existing { rows = try index.rootRows() }
        }

        // A directory under a recursive pin root is never *kept* in the viewed set either:
        // the pin already covers it, and it would only cost a readdir per cycle.
        var dropped = false
        for row in rows where row.reason != RootReason.pinned.rawValue && underPin(row.path) {
            try index.removeRoot(path: row.path, reason: row.reason)
            dropped = true
        }
        if dropped { rows = try index.rootRows() }

        var set = LocationRuntime.rootSet(from: rows)
        let evictions = set.viewedEvictions()
        if !evictions.isEmpty {
            for path in evictions {
                try index.removeRoot(path: path, reason: RootReason.viewed.rawValue)
            }
            set = LocationRuntime.rootSet(from: try index.rootRows())
        }
        return set
    }

    func currentRootSet() throws -> RootSet {
        LocationRuntime.rootSet(from: try index.rootRows())
    }

    /// One `roots` row per (path, reason); the set groups them by path, which is what
    /// "one directory may carry several reasons and leaves the set only when the last one
    /// goes" means (section 6.5).
    static func rootSet(from rows: [IndexWriter.RootRow]) -> RootSet {
        var byPath: [Data: RootSet.Entry] = [:]
        for row in rows {
            guard let reason = RootReason(rawValue: row.reason) else { continue }
            if var entry = byPath[row.path] {
                entry.reasons.insert(reason)
                entry.lastSeen = max(entry.lastSeen, row.lastSeen)
                entry.lastListed = max(entry.lastListed, row.lastListed)
                byPath[row.path] = entry
            } else {
                byPath[row.path] = RootSet.Entry(
                    path: row.path, reasons: [reason],
                    lastSeen: row.lastSeen, lastListed: row.lastListed)
            }
        }
        return RootSet(entries: byPath.values.sorted { $0.path.lexicographicallyPrecedes($1.path) })
    }

    // MARK: Tier 0 - the SFTP poll (section 6.4)

    /// One tier 0 cycle: `readdir` every `viewed` and `pinned` root and at most 64
    /// `materialized`-only roots, round-robin by least recent listing. `fullSweep`
    /// suspends the rotation for that one cycle, which is what a reconnect and a fresh
    /// working-set anchor both ask for (sections 6.4, 5.3).
    func runPollCycle(fullSweep: Bool, now: Double = Date().timeIntervalSince1970) async
        -> ChangeApplication
    {
        var application = ChangeApplication()
        var paths: [Data]
        do {
            paths = try currentRootSet().tier0Cycle(fullSweep: fullSweep)
            // A pin root is watched *recursively* (section 6.5), and at tier 0 that means
            // what section 7.1.2 says it means: "a `readdir` of every directory in the
            // location per cycle", which `pin` warns about along with the size. The root
            // set holds the pin root itself; the directories under it are expanded here,
            // with excluded subtrees skipped (section 7.1.1). Tier 1 needs none of this -
            // the pin roots go to `find` as recursive roots.
            let pinned = try pinnedSubtreeDirectories()
            if !pinned.isEmpty {
                var seen = Set(paths)
                for path in pinned where seen.insert(path).inserted { paths.append(path) }
            }
        } catch {
            application.errors.append("\(error)")
            return application
        }
        for path in paths.sorted(by: { $0.count < $1.count }) {
            application.absorb(await listOne(path))
            try? index.markRootListed(path: path, at: now)
        }
        return application
    }

    /// One directory, listed and diffed. Every failure is contained: one unreadable
    /// directory must not abandon the rest of a cycle.
    func listOne(_ pathBytes: Data) async -> ReconcileResult {
        do {
            let path = try RelativePath.fromIndexBytes(pathBytes)
            guard let containerRow = try index.item(path: pathBytes) else { return ReconcileResult() }
            return try await reconcile(directory: path, containerRow: containerRow)
        } catch {
            Log.agent.debug(
                "\(self.location.id, privacy: .public): could not list \(String(decoding: pathBytes, as: UTF8.self), privacy: .public): \(error, privacy: .public)"
            )
            return ReconcileResult()
        }
    }

    // MARK: Tier 1 - the remote sweep (section 6.4)

    /// Turns the sweep's hits into index changes.
    ///
    /// Section 6.4: "All tiers produce the same thing: a set of dirty remote paths that
    /// the agent re-`stat`s over SFTP (re-`readdir`s, for a directory, since a deletion is
    /// only visible as an absence in its parent's listing), diffs against the index, and
    /// turns into working-set anchors."
    ///
    /// A GNU sweep carries type, size, ns-mtime, inode, mode and owner with every hit, so
    /// a file that already has a row needs no follow-up `stat` at all; elsewhere the file
    /// is `lstat`ed, one round trip each.
    func applySweepHits(_ hits: [SweepHit], now: Double = Date().timeIntervalSince1970) async
        -> ChangeApplication
    {
        var application = ChangeApplication()
        var dirty: Set<Data> = []
        var files: [(path: RelativePath, hit: SweepHit)] = []
        let inFlight = await writerInFlightPaths()

        for hit in hits {
            let trimmed = LocationRuntime.stripLeadingDot(hit.path)
            guard let path = try? RelativePath.fromIndexBytes(trimmed) else { continue }
            if path.isRoot { dirty.insert(Data()); continue }
            // Our own uploads come back as remote changes without this (section 5.5).
            if inFlight.contains(path.bytes) { continue }
            let row = try? index.item(path: path.bytes)
            let isDirectory = hit.type == "d" || (hit.type == nil && row?.type == "directory")
            if isDirectory {
                dirty.insert(path.bytes)
            } else if row != nil {
                files.append((path, hit))
            } else {
                // A path with no row is new; its parent's listing is what mints it.
                dirty.insert((path.parent ?? .root).bytes)
            }
        }

        // A file whose row we already have and whose evidence the sweep carried needs no
        // listing: the row is rewritten from the hit.
        for entry in files {
            do {
                let attributes = try await attributesFor(entry.path, hit: entry.hit)
                guard let row = try index.item(path: entry.path.bytes),
                    let parentRow = try index.item(identifier: row.parent ?? IndexWriter.rootIdentifier)
                else {
                    dirty.insert((entry.path.parent ?? .root).bytes)
                    continue
                }
                let updated = try makeRow(
                    path: entry.path, attributes: attributes, parent: parentRow, existing: row,
                    hidden: row.hidden,
                    localAttributes: LocalAttributes.decode(row.xattrs))
                if updated.metadataVersion != row.metadataVersion {
                    try index.upsert(updated)
                    try index.appendAnchor(identifier: updated.identifier, kind: .modified)
                    application.changed += 1
                }
            } catch {
                dirty.insert((entry.path.parent ?? .root).bytes)
            }
        }

        for path in dirty.sorted(by: { $0.count < $1.count }) {
            application.absorb(await listOne(path))
        }
        return application
    }

    /// The hit's own evidence where the sweep carried it (GNU `-printf`), and one `lstat`
    /// where it did not (`-print0` on busybox and BSD).
    private func attributesFor(_ path: RelativePath, hit: SweepHit) async throws
        -> SFTPFileAttributes
    {
        guard let size = hit.size, let mtime = hit.mtime, let mode = hit.mode else {
            return try await transport.lstat(path)
        }
        return SFTPFileAttributes(
            type: hit.type == "d" ? .directory : .file,
            size: size,
            mtime: mtime,
            mode: UInt32(truncatingIfNeeded: mode),
            uid: UInt32(truncatingIfNeeded: hit.uid ?? 0),
            gid: UInt32(truncatingIfNeeded: hit.gid ?? 0),
            mtimeNanoseconds: hit.mtimeNanoseconds,
            inode: hit.inode.map { UInt64(bitPattern: $0) })
    }

    /// `find` run from the location root prints `./x` for a root of `.`; the index stores
    /// `x`.
    static func stripLeadingDot(_ path: Data) -> Data {
        if path == Data(".".utf8) { return Data() }
        if path.starts(with: Data("./".utf8)) { return path.dropFirst(2) }
        return path
    }

    func writerInFlightPaths() async -> Set<Data> { await writer.inFlightPaths() }

    // MARK: Bookkeeping the sweep and the tier need

    /// Section 6.4: the server's own `date +%s`, "stored once the sweep's results have
    /// been applied to the index, never before". Measured on the Mac's clock, a server
    /// running a few minutes behind would silently miss every change until the 30-minute
    /// insurance sweep.
    func sweepServerTime() -> Int64? {
        (try? index.meta(IndexSchema.MetaKey.sweepServerTime)).flatMap { $0 }.flatMap(Int64.init)
    }

    func setSweepServerTime(_ value: Int64, localNow: Double = Date().timeIntervalSince1970) {
        try? index.setMeta(IndexSchema.MetaKey.sweepServerTime, String(value))
        // Our own clock at the moment that server stamp was stored. The next window is
        // the *elapsed* time since then, measured here and applied to the server's value,
        // which is what section 6.4's "the minutes between the stored value and the new
        // one" means without either clock's absolute value entering into it. Subtracting a
        // server timestamp from the Mac's wall clock instead would fold the whole skew
        // into the window, which is precisely what the rule exists to avoid.
        try? index.setMeta(
            IndexSchema.MetaKey.sweepServerTime + "_local", String(localNow))
    }

    /// Our own clock when the stored server stamp was written, or nil when there is none.
    func sweepServerTimeTakenAt() -> Double? {
        Double((try? index.meta(IndexSchema.MetaKey.sweepServerTime + "_local")).flatMap { $0 } ?? "")
    }

    func lastFullSweep() -> Double {
        Double((try? index.meta(IndexSchema.MetaKey.lastFullSweep)).flatMap { $0 } ?? "") ?? 0
    }

    func setLastFullSweep(_ value: Double) {
        try? index.setMeta(IndexSchema.MetaKey.lastFullSweep, String(value))
    }

    func setWatchTier(_ tier: String) {
        try? index.setMeta(IndexSchema.MetaKey.watchTier, tier)
    }

    func storedWatchTier() -> String? {
        (try? index.meta(IndexSchema.MetaKey.watchTier)).flatMap { $0 }
    }

    /// The probe the live connection made, for the sweep's `find` flavour.
    func probeForSweep() -> ServerProbe.Result? { serverProbeResult }

    /// The master an exec channel is opened on, or nil while the location is offline.
    func execMaster() async -> SSHMaster? {
        await liveConnection()?.master
    }

    /// Whether the budget leaves a channel for the sweep at all (section 6.1). At a
    /// `MaxSessions` of 2 the exec channel is the one that is kept, so this is normally
    /// true wherever there is a shell.
    func allowsExecChannel() -> Bool { channelBudget.allowsExecChannel }

    /// The canonical absolute root the sweep's `cd` uses (section 9.1). Resolved on the
    /// live connection so a root that moved is caught by the same rule as everything else.
    func canonicalRoot() async throws -> String { try await transport.realpath(.root) }

    /// Identifiers from the system's replica enumerators, mapped back to the paths the
    /// index keys everything on. An identifier with no row is one the system still holds
    /// and we have deleted; it has no path to guard.
    func paths(forIdentifiers identifiers: [String]) -> Set<Data> {
        var out: Set<Data> = []
        for identifier in identifiers {
            guard let row = try? index.item(identifier: identifier) else { continue }
            out.insert(row.path)
        }
        return out
    }

    /// A sweep root has to survive a trip through `set --`, which is a String pipeline
    /// (section 9.2). Server names need not be valid UTF-8 (section 5.4), so the ones that
    /// are not are excluded from the sweep and listed at tier 0 instead.
    /// Every root is spelled `./…` rather than bare. `find` has no portable `--`, so a
    /// top-level directory literally named `-name` would otherwise be read as an option
    /// and the whole sweep would fail; the `./` prefix is what makes a name a path. The
    /// output then carries the same prefix, which `stripLeadingDot` takes back off.
    static func utf8Root(_ path: Data) -> String? {
        if path.isEmpty { return "." }
        guard let text = String(data: path, encoding: .utf8) else { return nil }
        return "./" + text
    }

    /// `sshdrive debug roots <name> --seed N`: marks the first N directory rows as
    /// `materialized` roots, so section 6.5's rotation can be measured at a scale that
    /// would otherwise need N downloads. The directories are real and are really listed;
    /// only the reason is injected.
    func seedMaterializedRoots(limit: Int) throws -> Int {
        // The system reports nothing materialized for these directories, so the ordinary
        // refresh at the start of every cycle would take the reason straight back off
        // again. The suppression is the hook's other half and lasts until the location is
        // restarted; nothing but `debug roots --seed` ever sets it.
        suppressMaterializedRefresh = true
        var added = 0
        try index.batch {
            for row in try index.allItems() where row.type == "directory" && !row.path.isEmpty {
                guard added < limit else { break }
                try index.addRoot(path: row.path, reason: RootReason.materialized.rawValue)
                added += 1
            }
        }
        return added
    }

    func recordWatchCycle(_ outcome: [String: Any]) { lastWatchCycle = outcome }

    /// What `status` prints for change detection when the detector itself is not to hand.
    func watchReport() -> [String: Any] {
        var out: [String: Any] = [:]
        if let tier = storedWatchTier() { out["tier"] = tier }
        if !lastWatchCycle.isEmpty { out["lastCycle"] = lastWatchCycle }
        if let stamp = sweepServerTime() { out["sweepServerTime"] = stamp }
        out["lastFullSweep"] = lastFullSweep()
        out["heldDeletions"] = (try? index.heldCount()) ?? 0
        if let set = try? currentRootSet() {
            out["roots"] = set.entries.count
            out["rotationPeriod"] = set.rotationPeriod()
        }
        return out
    }
}
