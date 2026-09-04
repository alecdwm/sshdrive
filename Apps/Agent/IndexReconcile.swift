import Foundation
import FileProvider
import AgentCore
import Config
import Index
import SFTP
import Logging

/// DESIGN.md section 5.3's index recovery: the health check the agent runs before it
/// serves a location, the restore from `index.sqlite.bak`, and the reconcile walk against
/// the system's replica that runs after either one.
///
/// Everything here is called from `LocationRuntime.start()`, before anything is served.
/// The order section 5.3 fixes is: judge the index, put it back if a backup can, empty it
/// if nothing can, and then walk the replica so that every path the user can still see
/// keeps the identifier the system already holds. The walk is what stops a rebuild from
/// looking like a mass deletion followed by a mass create: the identifiers are the only
/// thing the index held that the server cannot re-supply, and the replica is the only
/// other copy of them.
///
/// **The `meta.reconciling` flag is the contract between the two halves.** `recoverIfNeeded`
/// leaves it set whenever a walk is owed - after any restore, after any rebuild, and after
/// a crash that left it set - and `reconcileAgainstReplica` is the only thing that clears
/// it. So the wiring is: call `recoverIfNeeded`, and then, while the returned writer
/// reports `isReconciling`, call `reconcileAgainstReplica`. Nothing may be enumerated,
/// fetched or answered from the index in between: the extension is stalled on the same
/// flag (section 5.2) and the agent answers `.serverUnreachable` for the domain, because
/// an agent serving an empty index would answer `.noSuchItem` and the system would delete
/// the user's files.
enum IndexReconcile {

    // MARK: The three states of an index at start

    /// Which of section 5.3's three cases a location's index is in.
    enum IndexHealth: String, Sendable {
        /// Opened, and `PRAGMA integrity_check` said "ok".
        case healthy
        /// Opened, but `PRAGMA integrity_check` did not say "ok". The live connection is
        /// usable, so the backup goes in through the online backup API and the file keeps
        /// its inode (section 5.3).
        case corrupt
        /// `IndexWriter(path:)` itself threw: a truncated header, a not-a-database file,
        /// a disk that will not give us the page. There is no connection to restore into,
        /// so the file and its sidecars are truncated first.
        case unopenable
    }

    /// The health of an index the caller has already opened. A nil writer is the
    /// "cannot open at all" case, which only the caller can observe, since it is
    /// `IndexWriter(path:)` that throws.
    static func health(of writer: IndexWriter?) -> IndexHealth {
        guard let writer else { return .unopenable }
        do {
            return try writer.integrityCheck() ? .healthy : .corrupt
        } catch {
            // A connection that cannot even run `PRAGMA integrity_check` is corrupt for
            // our purposes: it opened, so the truncate path is not needed, but nothing it
            // answers can be trusted.
            return .corrupt
        }
    }

    /// Opens the index and judges it in one step, for a caller that does not already hold
    /// a writer - `sshdrive doctor` and the debug hook.
    static func probe(indexURL: URL) -> (health: IndexHealth, writer: IndexWriter?) {
        do {
            let writer = try IndexWriter(path: indexURL.path)
            return (health(of: writer), writer)
        } catch {
            Log.agent.error(
                "the index at \(indexURL.path, privacy: .public) cannot be opened at all: \(error.localizedDescription, privacy: .public)"
            )
            return (.unopenable, nil)
        }
    }

    // MARK: The report

    /// What one recovery did, for the log line, for `sshdrive status` and for
    /// `sshdrive debug reconcile --json`.
    struct Report: Sendable {
        /// "healthy" | "restored" | "rebuilt" | "reconciled" | "failed".
        var state: String = "failed"
        var restoredFromBackup: Bool = false
        /// Replica entries visited.
        var walked: Int = 0
        var rowsCreated: Int = 0
        /// Rows whose identifier the replica overruled (section 5.3: the item was deleted
        /// and re-created after the backup was taken).
        var identifiersAdopted: Int = 0
        var pendingLeftUnversioned: Int = 0
        var pinsRestored: Int = 0
        var seconds: Double = 0
        /// "deadline" | "item cap" | nil.
        var hitLimit: String?
        var errors: [String] = []

        var asJSON: [String: Any] {
            var out: [String: Any] = [
                "state": state,
                "restoredFromBackup": restoredFromBackup,
                "walked": walked,
                "rowsCreated": rowsCreated,
                "identifiersAdopted": identifiersAdopted,
                "pendingLeftUnversioned": pendingLeftUnversioned,
                "pinsRestored": pinsRestored,
                "seconds": seconds,
            ]
            if let hitLimit { out["hitLimit"] = hitLimit }
            if !errors.isEmpty { out["errors"] = errors }
            return out
        }
    }

    /// How long the agent waits for the extension to close its reader before truncating.
    /// It must not wait for ever: an extension that is not running cannot be waiting on
    /// anything, and there is no reply from a process that does not exist (section 5.3).
    static let readerCloseSeconds: Double = 20

    // MARK: 1 and 2 - the health check and the restore

    /// Called from `LocationRuntime.start()`, before anything is served.
    ///
    /// `writer` may be nil when the database could not be opened at all; in that case
    /// `reopen` is called to get a fresh one after the truncate.
    ///
    /// Returns the writer the caller should go on using - the same one on the restore
    /// path, since a restore never replaces the file, and a fresh one on the truncate
    /// path - and a report. **The caller must then run `reconcileAgainstReplica` while
    /// the returned writer reports `isReconciling`**: this call sets that flag whenever a
    /// walk is owed and never clears it.
    static func recoverIfNeeded(
        locationID: String,
        indexURL: URL,
        backupURL: URL,
        writer: IndexWriter?,
        wasReconciling: Bool,
        closeReader: @escaping @Sendable () async -> Void,
        reopenReader: @Sendable () -> Void,
        reopen: @Sendable () throws -> IndexWriter
    ) async -> (writer: IndexWriter?, report: Report) {
        let began = Date()
        var report = Report()
        var live = writer
        let files = FileManager.default
        let haveBackup = files.fileExists(atPath: backupURL.path)
        let state = health(of: live)

        if state == .healthy {
            report.state = "healthy"
            if wasReconciling {
                // The flag outlives a crash (section 5.3): an agent that starts and finds
                // it set redoes the walk before serving anything, because the extension is
                // stalled on that flag and nothing else will clear it. The index itself is
                // sound, so there is nothing to restore - only the walk to finish.
                Log.agent.notice(
                    "\(locationID, privacy: .public): the index is sound but a reconcile was left unfinished; the walk runs again before anything is served"
                )
                owe(theWalkOn: live, locationID: locationID, report: &report)
            }
            report.seconds = Date().timeIntervalSince(began)
            return (live, report)
        }

        Log.agent.error(
            "\(locationID, privacy: .public): the index is \(state.rawValue, privacy: .public); recovering from \(haveBackup ? "the backup" : "nothing", privacy: .public) (section 5.3)"
        )

        // Openable and corrupt: the backup goes in through SQLite's online backup API,
        // into the live database and never over the file, so the inode is stable and the
        // extension's reader (section 5.2) keeps reading the file it already has open.
        // No close-and-reopen is needed on this path, which is the whole reason it is a
        // separate one.
        if state == .corrupt, haveBackup, let openable = live {
            if restore(backupAt: backupURL, into: openable, locationID: locationID, report: &report)
            {
                report.state = "restored"
                report.restoredFromBackup = true
                // Section 5.3: "Then, and also when there is no backup at all, the index
                // is reconciled against the replica before anything is re-enumerated." A
                // backup is a point in the past, so even a clean restore owes the walk.
                owe(theWalkOn: live, locationID: locationID, report: &report)
                report.seconds = Date().timeIntervalSince(began)
                return (live, report)
            }
        }

        // Everything else empties the file: unopenable, or corrupt with no backup, or
        // corrupt with a backup that did not take. The close comes FIRST and the order is
        // not negotiable - the reader holds the `-shm` mapped, and truncating a mapped
        // file under a live process faults it on its next access (section 5.3).
        await closeReaderBeforeTruncate(closeReader, locationID: locationID)
        // Our own connection goes too, for the same reason: a handle on a file that has
        // been truncated under it reads an empty database through a stale page cache.
        // `IndexWriter` closes its connection when the last reference goes.
        live = nil

        do {
            try IndexWriter.truncateDatabaseFiles(at: indexURL.path)
            live = try reopen()
        } catch {
            report.errors.append(
                "the index could not be emptied and reopened: \(error.localizedDescription)")
            Log.agent.error(
                "\(locationID, privacy: .public): the index could not be emptied and reopened: \(error.localizedDescription, privacy: .public)"
            )
            reopenReader()
            report.state = "failed"
            report.seconds = Date().timeIntervalSince(began)
            return (live, report)
        }

        if haveBackup, let fresh = live {
            if restore(backupAt: backupURL, into: fresh, locationID: locationID, report: &report) {
                report.restoredFromBackup = true
            } else {
                // The backup itself is no good. Empty the file a second time rather than
                // leaving half a restored database behind, and let the walk start from
                // nothing (section 5.3).
                live = nil
                do {
                    try IndexWriter.truncateDatabaseFiles(at: indexURL.path)
                    live = try reopen()
                } catch {
                    report.errors.append(
                        "the index could not be emptied after a bad backup: \(error.localizedDescription)"
                    )
                    reopenReader()
                    report.state = "failed"
                    report.seconds = Date().timeIntervalSince(began)
                    return (live, report)
                }
            }
        }

        report.state = "rebuilt"
        // Set before the reader is let back in, so that the first thing it reads off the
        // rebuilt database is the flag that tells it to answer `.serverUnreachable`
        // rather than rows that are not there yet (section 5.2).
        owe(theWalkOn: live, locationID: locationID, report: &report)
        reopenReader()
        report.seconds = Date().timeIntervalSince(began)
        return (live, report)
    }

    /// Copies the backup in and expires the anchors it brought with it. False when the
    /// restore threw or when the result still fails `PRAGMA integrity_check`, which
    /// section 5.3 answers the same way as no backup at all: the reconcile walk, with an
    /// empty index.
    private static func restore(
        backupAt backupURL: URL, into writer: IndexWriter, locationID: String,
        report: inout Report
    ) -> Bool {
        do {
            // `restore(fromBackupAt:)` bumps `meta.generation` itself - that is the
            // signal the reader re-reads its cached prepared statements on (section 5.2) -
            // so the generation is deliberately not bumped a second time here.
            try writer.restore(fromBackupAt: backupURL)
            // The anchors that came back are the backup's, and the system may hold one
            // newer than any of them. Expiring them makes the extension answer
            // `.syncAnchorExpired`, which the agent answers with one full sweep
            // (section 5.3).
            try writer.expireAnchors()
            guard try writer.integrityCheck() else {
                report.errors.append(
                    "the backup was copied in but the index still fails PRAGMA integrity_check")
                return false
            }
            Log.agent.notice(
                "\(locationID, privacy: .public): restored the index from its backup and expired the anchors"
            )
            return true
        } catch {
            report.errors.append(
                "restoring \(backupURL.lastPathComponent) failed: \(error.localizedDescription)")
            Log.agent.error(
                "\(locationID, privacy: .public): restoring the index backup failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Asks the extension to close its reader, and gives up waiting rather than blocking
    /// the location's start for ever. An extension that is not running cannot be waiting
    /// on anything, and an instance the system launches between this and the truncate is
    /// covered by the ready check on the agent (section 5.3): a mid-restore agent answers
    /// `indexReady` no, and the instance opens nothing.
    private static func closeReaderBeforeTruncate(
        _ closeReader: @escaping @Sendable () async -> Void, locationID: String
    ) async {
        do {
            try await Deadline.run(
                "asking the extension to close its index reader", seconds: readerCloseSeconds
            ) {
                await closeReader()
            }
        } catch {
            Log.agent.notice(
                "\(locationID, privacy: .public): the extension did not answer the close within \(Int(readerCloseSeconds), privacy: .public) s; truncating anyway, since an extension that is not running cannot be waiting on anything"
            )
        }
    }

    /// Sets `meta.reconciling`, which is how this file tells the caller a walk is owed and
    /// how the extension is told to stall (sections 5.2, 5.3).
    private static func owe(
        theWalkOn writer: IndexWriter?, locationID: String, report: inout Report
    ) {
        guard let writer else { return }
        do {
            try writer.setReconciling(true)
        } catch {
            report.errors.append(
                "meta.reconciling could not be set: \(error.localizedDescription)")
            Log.agent.error(
                "\(locationID, privacy: .public): meta.reconciling could not be set, so the extension will not stall: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: 3 - the reconcile walk

    /// Section 5.3's walk, on its own, for `sshdrive debug reconcile` and for the
    /// crash-recovery path where the index is fine but the flag was left set.
    ///
    /// `meta.reconciling` is set for the whole walk and cleared only at the end, so the
    /// extension's own `item(for:)` and working-set reads stall too: the agent-side stall
    /// alone would leave the extension answering from a half-built index, and a row that
    /// is not there yet reads as `.noSuchItem`, which deletes the file.
    ///
    /// The mount is walked with `readdir` and `lstat` only. Nothing is ever opened: an
    /// open would materialize a dataless file, and a walk of a large location would pull
    /// the whole share down.
    static func reconcileAgainstReplica(
        locationID: String,
        writer: IndexWriter,
        permissions: PermissionsMode,
        identity: ServerIdentity,
        deadline: TimeInterval = 300,
        itemCap: Int = 500_000
    ) async -> Report {
        let began = Date()
        let expiry = began.addingTimeInterval(deadline)
        var report = Report()

        // Set first and cleared last. On the recovery path it is already set; on
        // `sshdrive debug reconcile` it is not, and the walk must not run without it.
        do {
            try writer.setReconciling(true)
        } catch {
            report.errors.append(
                "meta.reconciling could not be set: \(error.localizedDescription)")
        }

        guard let mount = await mountURL(locationID: locationID) else {
            // The flag is deliberately left SET. There is no safe way to serve an index
            // that may be empty while the replica still holds the user's files: every
            // missing row would be answered `.noSuchItem` and the file would go. A
            // location in this state stays stalled until a later start, when the domain
            // is registered and the mount can be resolved, redoes the walk.
            report.errors.append(
                "the mount under ~/Library/CloudStorage could not be resolved, so the walk did not run; the domain stays stalled on meta.reconciling"
            )
            Log.agent.error(
                "\(locationID, privacy: .public): no user-visible URL for the domain root, so the reconcile walk cannot run (section 5.3)"
            )
            report.seconds = Date().timeIntervalSince(began)
            return report
        }

        // Section 5.3's exception. An item the system lists here holds a pending edit in
        // its replica file, so its size and mtime are the edit's and not the server's:
        // its content version is left empty and comes back through its own `modifyItem`.
        // A nil answer means there was no manager to ask, which is "no news", never "no
        // pending items" (section 6.5), and the safe reading of no news here is to treat
        // nothing as pending rather than to leave every version empty.
        let pending = Set(await ReplicaEnumerators.pendingIdentifiers(locationID: locationID) ?? [])

        let rootRow: IndexItem
        do {
            // The root's real mode, owner and identity come from the first connection
            // (`applyConnection` refreshes the row); the replica cannot report the
            // server's, so the defaults stand until then.
            rootRow = try writer.ensureRoot()
        } catch {
            report.errors.append("the root row could not be created: \(error.localizedDescription)")
            report.seconds = Date().timeIntervalSince(began)
            return report
        }

        // Every derived field goes through `RowBuilder`, exactly as `LocationRuntime.makeRow`
        // does, so that no rule of sections 5.2, 5.4 or 5.7 is written twice. There is no
        // server on this path and therefore no root spelling to measure a symlink against:
        // the target read from the replica is already the Mac-side one section 5.7 wrote,
        // and "/" makes the lexical check judge it on its own merits.
        let rows = RowBuilder(
            permissions: permissions, identity: identity,
            roots: SymlinkPolicy.Roots(canonical: "/"))

        var stack: [(url: URL, path: RelativePath, parent: IndexItem)] = [
            (mount, .root, rootRow)
        ]

        while let directory = stack.popLast() {
            if Date() >= expiry {
                report.hitLimit = "deadline"
                break
            }

            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory.url,
                    // `.isSymbolicLinkKey` is the "do not descend" guard: a walk that
                    // followed a link would leave the mount, and a link to an ancestor
                    // would not terminate. `.skipsHiddenFiles` is deliberately NOT set -
                    // a dotfile has a row like anything else.
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: [])
            } catch {
                report.errors.append(
                    "listing \(directory.path.description) failed: \(error.localizedDescription)")
                continue
            }

            // Pass one, off the database: one `lstat` and one question to the system per
            // entry. Both are slow enough that holding a write transaction across them
            // would keep the index locked for the whole directory.
            var resolved: [ResolvedEntry] = []
            for entry in entries {
                if Date() >= expiry {
                    report.hitLimit = "deadline"
                    break
                }
                if report.walked >= itemCap {
                    report.hitLimit = "item cap"
                    break
                }
                report.walked += 1

                let name = entry.lastPathComponent
                let nameBytes = Data(name.utf8)
                guard let childPath = try? directory.path.appending(component: nameBytes) else {
                    // Section 9.1's chokepoint has the last word on what can be a path
                    // component. A name it rejects can never be addressed, so it gets no row.
                    continue
                }
                if NameVisibility.isUploadTemporary(nameBytes) { continue }

                // `Foundation.stat`, because the bare name is also the function.
                var buffer = Foundation.stat()
                guard lstat(entry.path, &buffer) == 0 else {
                    report.errors.append(
                        "lstat \(childPath.description) failed: \(String(cString: strerror(errno)))")
                    continue
                }
                let type = fileType(of: buffer)
                // Sockets, FIFOs and device nodes are never enumerated and never get a
                // row (section 5.4). Nothing in the replica should be one.
                guard type != .other else { continue }

                let isSymbolicLink = type == .symlink
                guard
                    let identifier = await replicaIdentifier(
                        at: entry, locationID: locationID, expiry: expiry)
                else {
                    report.errors.append(
                        "the system has no identifier for \(childPath.description)")
                    continue
                }

                // `readlink`, not `open`: reading a link's target never materializes
                // anything, and the target the replica holds is the Mac-side string
                // section 5.7 already rewrote. `link_target` is set from the replica only
                // when the entry really is a link.
                var target: String?
                if isSymbolicLink {
                    target = try? FileManager.default.destinationOfSymbolicLink(
                        atPath: entry.path)
                }

                resolved.append(
                    ResolvedEntry(
                        url: entry,
                        path: childPath,
                        identifier: identifier,
                        attributes: attributes(
                            from: buffer, type: type, identity: identity, symlinkTarget: target),
                        isDSStore: NameVisibility.isDSStore(nameBytes)))
            }

            // Pass two: one transaction for the directory, as section 5.3 requires of
            // every multi-row change.
            do {
                let descend: [(url: URL, path: RelativePath, parent: IndexItem)] =
                    try writer.batch {
                        var next: [(url: URL, path: RelativePath, parent: IndexItem)] = []
                        for item in resolved {
                            let existing = try writer.item(path: item.path.bytes)
                            if let existing, existing.identifier == item.identifier {
                                // The row is already keyed by the identifier the system
                                // holds. Section 5.3 creates rows only "for every path
                                // without a row": rewriting this one would throw away the
                                // xattrs and the pin marker only the index has, and move
                                // its versions for nothing.
                                if item.attributes.type == .directory {
                                    next.append((item.url, item.path, existing))
                                }
                                continue
                            }
                            if let existing {
                                // A different identifier means the item was deleted and
                                // re-created after the backup was taken. The replica's
                                // identifier wins, since that is what the user's file is
                                // keyed by, and the old row's pin marker and xattrs go
                                // with the old identifier as they would for any deletion -
                                // which is exactly what `delete` does, deletion anchor
                                // included.
                                try writer.delete(identifier: existing.identifier)
                                report.identifiersAdopted += 1
                            }

                            // `existing: nil` is what gives the row generation 0, and
                            // with it the content version `"\(size)-\(mtime)-0"` the
                            // system already holds for an item whose generation never
                            // moved. That item is therefore not re-fetched.
                            var row = rows.build(
                                path: item.path,
                                attributes: item.attributes,
                                parent: directory.parent,
                                existing: nil,
                                hidden: item.isDSStore ? RowBuilder.hiddenLocalOnly : nil
                            ).row
                            row.identifier = item.identifier

                            if pending.contains(item.identifier) {
                                // The pending exception (section 5.3): the replica file
                                // holds the edit, so its size and mtime are the edit's,
                                // not the server's. An empty version comes back through
                                // the item's own `modifyItem`, whose post-upload `lstat`
                                // sets it.
                                row.contentVersion = ""
                                RowBuilder.restamp(&row)
                                report.pendingLeftUnversioned += 1
                            }

                            try writer.upsert(row)
                            // The walk's rows travel through the working set once the
                            // flag is cleared and the caller signals the enumerator.
                            try writer.appendAnchor(identifier: row.identifier, kind: .modified)
                            report.rowsCreated += 1

                            if item.attributes.type == .directory {
                                next.append((item.url, item.path, row))
                            }
                        }
                        return next
                    }
                stack.append(contentsOf: descend)
            } catch {
                report.errors.append(
                    "writing the rows for \(directory.path.description) failed: \(error.localizedDescription)"
                )
            }

            if report.hitLimit != nil { break }
        }

        restorePins(locationID: locationID, writer: writer, report: &report)

        if let limit = report.hitLimit {
            // A walk that stopped early has left paths without rows, and those will be
            // minted fresh on the next enumeration - a delete plus a create for each, as
            // far as the system is concerned. That is bad, but a domain stalled for ever
            // on `meta.reconciling` is worse: nothing else would ever clear it. So the
            // flag comes off and the limit is reported loudly instead.
            Log.agent.error(
                "\(locationID, privacy: .public): the reconcile walk hit its \(limit, privacy: .public) after \(report.walked, privacy: .public) entries; paths it never reached will be re-identified on their next enumeration"
            )
        }

        do {
            try writer.setReconciling(false)
            report.state = "reconciled"
        } catch {
            report.errors.append(
                "meta.reconciling could not be cleared: \(error.localizedDescription)")
            Log.agent.error(
                "\(locationID, privacy: .public): meta.reconciling could not be cleared, so the domain stays stalled: \(error.localizedDescription, privacy: .public)"
            )
        }

        report.seconds = Date().timeIntervalSince(began)
        Log.agent.notice(
            "\(locationID, privacy: .public): reconcile walked \(report.walked, privacy: .public) replica entries, created \(report.rowsCreated, privacy: .public) rows, adopted \(report.identifiersAdopted, privacy: .public) identifiers, left \(report.pendingLeftUnversioned, privacy: .public) pending items unversioned, restored \(report.pinsRestored, privacy: .public) pin markers in \(Int(report.seconds), privacy: .public) s"
        )
        return report
    }

    /// One replica entry, resolved off the database.
    private struct ResolvedEntry {
        var url: URL
        var path: RelativePath
        var identifier: String
        var attributes: SFTPFileAttributes
        var isDSStore: Bool
    }

    // MARK: The replica

    /// The mount under `~/Library/CloudStorage`, which is the only place the walk reads.
    private static func mountURL(locationID: String) async -> URL? {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        return try? await Deadline.run("asking for the domain's user-visible URL") {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL, Error>) in
                manager.getUserVisibleURL(for: .rootContainer) { url, error in
                    if let url {
                        continuation.resume(returning: url)
                    } else {
                        let failure: Error = error ?? NSFileProviderError(.noSuchItem)
                        continuation.resume(throwing: failure)
                    }
                }
            }
        }
    }

    /// The identifier the system already knows for one replica path, which is the whole
    /// point of the walk. Under a deadline of its own, like every other call the agent
    /// makes into File Provider (section 6.3), and never longer than the walk's own.
    private static func replicaIdentifier(at url: URL, locationID: String, expiry: Date) async
        -> String?
    {
        let remaining = min(Deadline.fileProviderSeconds, max(1, expiry.timeIntervalSinceNow))
        let outcome: Found?? = try? await Deadline.run(
            "asking the system for an identifier", seconds: remaining
        ) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Found?, Never>) in
                NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                    identifier, domain, _ in
                    guard let identifier, let domain else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(
                        returning: Found(identifier: identifier.rawValue, domain: domain.rawValue))
                }
            }
        }
        guard let found = outcome ?? nil else { return nil }
        // A path that answers for another domain is not ours to write a row for. It
        // should not be possible under our own mount, but the answer is the system's.
        guard found.domain == locationID else { return nil }
        return found.identifier
    }

    private struct Found: Sendable {
        var identifier: String
        var domain: String
    }

    // MARK: The lstat

    /// Widened to `UInt32` on both sides, because `st_mode` is a 16-bit `mode_t` while
    /// the `S_IF*` macros arrive from the importer as plain integers.
    private static func fileType(of buffer: Foundation.stat) -> SFTPFileType {
        let format = UInt32(buffer.st_mode) & UInt32(S_IFMT)
        if format == UInt32(S_IFDIR) { return .directory }
        if format == UInt32(S_IFREG) { return .file }
        if format == UInt32(S_IFLNK) { return .symlink }
        return .other
    }

    /// The row's attributes, rebuilt from the replica's `lstat`.
    ///
    /// Size and second-mtime are the values the system was given for the item, dataless
    /// or not, so they are taken verbatim: that is what makes the rebuilt content version
    /// match the one the system holds (section 5.3).
    ///
    /// Everything else is deliberately not the replica's:
    ///
    /// - `mtimeNanoseconds` and `inode` are nil. The columns hold the *server's* values,
    ///   and section 6.4 bumps the generation when either moves while size and mtime do
    ///   not. Writing the Mac's would make the first real `lstat` look like a change and
    ///   re-fetch every file. Nil means "record whatever comes next without comparing".
    /// - mode and owner are the connecting account's, not the replica's. Section 5.3 says
    ///   plainly that "mode, owner and the xattr hash are not in the replica" and accepts
    ///   the metadata version moving for it; the replica's own mode and uid are the Mac's
    ///   and would derive the wrong capabilities, so the item is given the generous
    ///   reading until the first real `lstat` arrives - the same stance section 5.4 takes
    ///   for an unknown identity.
    private static func attributes(
        from buffer: Foundation.stat, type: SFTPFileType, identity: ServerIdentity,
        symlinkTarget: String?
    ) -> SFTPFileAttributes {
        let mode: UInt32
        switch type {
        case .directory: mode = 0o755
        case .symlink: mode = 0o777
        default: mode = 0o644
        }
        return SFTPFileAttributes(
            type: type,
            size: Int64(buffer.st_size),
            mtime: Int64(buffer.st_mtimespec.tv_sec),
            mode: mode,
            uid: identity.uid ?? 0,
            gid: identity.gid ?? 0,
            mtimeNanoseconds: nil,
            inode: nil,
            symlinkTarget: symlinkTarget)
    }

    // MARK: pins.json

    /// Pin markers are one of the two things the walk cannot recover from the replica,
    /// and `pins.json` beside the index is the copy that brings them back (section 5.3).
    /// Milestone 8 writes it on every pin change (`LocationRuntime.writePinsSidecar`);
    /// this reads it defensively and does nothing at all if it is missing or unparseable,
    /// because an index rebuilt on an older install may have no sidecar at all.
    private static func restorePins(
        locationID: String, writer: IndexWriter, report: inout Report
    ) {
        guard let url = try? GroupContainer.pinsURL(locationID: locationID),
            let data = try? Data(contentsOf: url)
        else { return }
        guard let markers = parsePins(data), !markers.isEmpty else {
            Log.agent.notice(
                "\(locationID, privacy: .public): pins.json is present but says nothing this build understands; the walk leaves every marker clear"
            )
            return
        }
        for (pathString, marker) in markers {
            guard marker != 0, let path = try? LocationRuntime.pinPath(pathString) else { continue }
            do {
                guard var row = try writer.item(path: path.bytes) else {
                    // A marker on a path that is no longer there vanishes with it
                    // (section 7.1).
                    continue
                }
                row.pinState = marker
                row.kept = marker == 1
                // The same bit `setPinState` moves: it is the eager content policy, not
                // the capability, that refuses an eviction, but the bit is part of the
                // metadata version and has to agree with the marker (section 7.1).
                row.capabilities =
                    row.kept
                    ? row.capabilities & ~Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)
                    : row.capabilities | Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)
                RowBuilder.restamp(&row)
                try writer.upsert(row)
                try writer.appendAnchor(identifier: row.identifier, kind: .modified)
                if marker == 1 {
                    try writer.addRoot(path: path.bytes, reason: "pinned")
                }
                report.pinsRestored += 1
            } catch {
                report.errors.append(
                    "restoring the pin marker on \(pathString) failed: \(error.localizedDescription)")
            }
        }
        // The markers are back; the *effect* of them is not. Every row under a restored
        // pin inherits its kept state (section 7.1.1), and a rebuilt row was written
        // before the marker above it existed, so the whole tree is re-derived here rather
        // than left disagreeing with the markers it now carries.
        reapplyKept(writer: writer, report: &report)
    }

    /// Recomputes `kept` (and the `allowsEvicting` bit and metadata version that follow
    /// from it) on every row, from the markers the index now holds. Cheap: no `lstat`, no
    /// network, one pass over the table, and only the rows that disagree are written.
    private static func reapplyKept(writer: IndexWriter, report: inout Report) {
        guard let markerRows = try? writer.pinMarkerRows(), !markerRows.isEmpty else { return }
        let markers = PinMarkerSet(rows: markerRows)
        do {
            try writer.batch {
                for var row in try writer.allItems() {
                    let kept = markers.isKept(row.path)
                    guard kept != row.kept else { continue }
                    row.kept = kept
                    row.capabilities =
                        kept
                        ? row.capabilities & ~Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)
                        : row.capabilities | Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)
                    RowBuilder.restamp(&row)
                    try writer.upsert(row)
                    try writer.appendAnchor(identifier: row.identifier, kind: .modified)
                }
            }
        } catch {
            report.errors.append("re-deriving the kept state failed: \(error.localizedDescription)")
        }
    }

    /// Reads whatever shape `pins.json` turns out to have, since milestone 8 has not
    /// written one yet. Three are accepted and anything else is ignored: a list of
    /// objects, an object with that list under `pins`, and a plain path-to-marker map.
    /// A marker is `1` pinned, `-1` excluded, `0` inherit, as the `pin_state` column
    /// spells them, or the words themselves.
    private static func parsePins(_ data: Data) -> [(path: String, marker: Int64)]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var out: [(path: String, marker: Int64)] = []

        func marker(_ value: Any) -> Int64? {
            if let number = value as? NSNumber { return number.int64Value }
            guard let text = value as? String else { return nil }
            switch text {
            case "pinned", "pin", "keep": return 1
            case "excluded", "exclude": return -1
            case "inherit", "none", "unset": return 0
            default: return Int64(text)
            }
        }

        func absorb(_ entry: [String: Any]) {
            guard
                let path = ["path", "remotePath", "remote_path"]
                    .compactMap({ entry[$0] as? String }).first
            else { return }
            guard
                let value = ["state", "pinState", "pin_state", "marker"]
                    .compactMap({ entry[$0] }).first, let found = marker(value)
            else { return }
            out.append((path, found))
        }

        if let array = json as? [[String: Any]] {
            for entry in array { absorb(entry) }
        } else if let object = json as? [String: Any] {
            if let array = (object["pins"] ?? object["markers"]) as? [[String: Any]] {
                for entry in array { absorb(entry) }
            } else {
                for (path, value) in object {
                    if let found = marker(value) { out.append((path, found)) }
                }
            }
        } else {
            return nil
        }
        return out
    }
}
