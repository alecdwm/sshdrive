import Foundation
import FileProvider
import AgentCore
import Config
import Index
import SFTP
import XPCProtocols
import Logging

/// Everything the agent holds for one location: the index it is the only writer of, and
/// the transport it talks to. In milestone 1 the transport is always `FakeTransport`
/// (DESIGN.md section 12); milestone 2 puts the real SFTP client behind the same
/// protocol and nothing here changes.
///
/// An actor because the index has a single writer by design (section 3) and because the
/// transport is one too.
actor LocationRuntime {
    let location: Location
    /// Internal rather than private: the change-detection half of this actor lives in
    /// `LocationRuntime+ChangeDetection.swift` (section 6.4), and `private` in Swift is
    /// file-scoped even for an extension of the same type in the same module.
    var index: IndexWriter
    let transport: any SFTPTransport
    let indexURL: URL
    let backupURL: URL

    /// The identity the capability probe found. Milestone 3 runs the probe; the fake
    /// backend reports its own uid and gid so the derivation in section 5.4 has
    /// something real to work from from milestone 1 on.
    private var identity: ServerIdentity

    /// Every derived field of a row, in one place (sections 5.2, 5.4, 5.7). Rebuilt when
    /// the identity or the root spellings change, since both feed the derivation.
    private var rows: RowBuilder

    /// The server half of section 5.5: the temp-file-plus-rename upload protocol, the
    /// conflict check, the conflict copy, the stale-temp rule and the delete rules. It
    /// owns the transport and the in-flight set; this actor stays the only writer of the
    /// index.
    var writer: RemoteWriter

    /// The two spellings of the location root a symlink target is measured against
    /// (section 5.7): the canonical one `realpath` returned, and the one the user typed -
    /// or `$HOME` for a default root.
    private var symlinkRoots: SymlinkPolicy.Roots

    /// This install's `<mac8>` (section 5.5), for the upload temp names.
    private let macID: String

    /// The catch-up sweep the agent runs when the extension hands out a fresh working-set
    /// anchor (section 5.3). S3 needs it off, so the system's own behaviour after
    /// `.syncAnchorExpired` is visible; `sshdrive debug sweep off` is that switch.
    var catchUpSweepEnabled = true

    /// Section 6.2's transfer scheduler: four transfers at once on the bulk channel,
    /// foreground before background, the pipelined window split between them, and the
    /// backlog bounded by the six-fetch ceiling S6 measured. It is also what a cancel
    /// reaches: cancelling the extension's `Progress` cancels the transfer's Task and
    /// every SFTP request it has not sent yet (section 5.2).
    let scheduler: TransferScheduler

    /// What the server let us hold at once (section 6.1), and the sentence `status`
    /// shows for it. `.unrestricted` for a fake location, which has no channels at all.
    private(set) var channelBudget: ChannelBudget = .unrestricted

    /// Names in the tree that are recorded but never shown, with the reason, for
    /// `status`'s "not shown" list (section 5.4). Keyed by the path bytes.
    var hiddenReasons: [Data: String] = [:]

    /// The paths the system lists in `enumeratorForPendingItems()`, refreshed at the
    /// start of every change-detection cycle. The mass-deletion guard holds a deletion of
    /// any of them whatever the counts say (section 6.4, S5).
    var pendingPaths: Set<Data> = []

    /// `sshdrive debug roots <name> --seed N` sets this, and nothing else does: the
    /// system reports none of the seeded directories as materialized, so the ordinary
    /// refresh would undo the seeding on the next cycle (section 6.5).
    var suppressMaterializedRefresh = false

    /// Section 7.2's safety net: the kept files the agent has *seen* materialized in an
    /// earlier `enumeratorForMaterializedItems` pass. A kept file that leaves this set has
    /// turned dataless without our handler having run, and the pin is re-asserted rather
    /// than read as an unpin. Kept files that are dataless because their eager download has
    /// not reached them yet were never in it, which is what "turning" means.
    var keptAndMaterialized: Set<String> = []
    /// How many times that has happened, for `status` ("3 kept files were evicted outside
    /// SSH Drive and re-downloaded").
    var keptEvictedOutside = 0

    /// Section 6.4's tier ladder for this location, owned by `ChangeDetector` and kept
    /// here so `status` can answer for a location whose detector is not running.
    var watchState: ChangeDetectionLadder?
    /// The last cycle's outcome, for `status`: when, which tier, how long, what it found.
    var lastWatchCycle: [String: Any] = [:]

    // MARK: Spike faults and transfer accounting (S4, S6)

    /// `sshdrive debug fault <name> --writes on`: every create/modify fails
    /// `.serverUnreachable`, so an edit made in the mount stays in the system's pending
    /// set. S4 needs an item with pending changes to try to evict.
    private var writesFail = false

    /// `sshdrive debug fault <name> --fetch-delay MS`: hold each `fetchContents` open for
    /// this long. A fake-backed fetch is a memory copy and finishes before the next one
    /// starts, so without a delay the concurrency S6 wants to count is always 1.
    private var fetchDelayMilliseconds = 0

    /// `sshdrive debug fault <name> --version-mismatch on`: `modifyItem` returns an item
    /// whose content and metadata versions are not the ones just written, which is the
    /// case section 5.5's conflict path rests on (s3-7). The index keeps the true
    /// versions; only the reply to the system is wrong.
    private var versionMismatch = false

    /// `sshdrive debug fault <name> --collisions on`: every `createItem` fails
    /// `.filenameCollision`, which is the error section 5.5's `lstat`-after-`FAILURE`
    /// check will raise for real in milestone 4. s3-4 needs it to see what Finder draws.
    private var createsCollide = false

    /// `sshdrive debug fault <name> --upload-delay MS`: holds every upload between the
    /// bytes landing in the temp file and the destination `lstat`, which is section 5.5's
    /// conflict window. A spike changes the file on the server inside that window and
    /// gets a **real** conflict rather than a simulated one (S8/S10 runbook).
    private var uploadDelayMilliseconds = 0

    /// `sshdrive debug fault <name> --frozen-metadata on`: `modifyItem` replies with the
    /// metadata version the item had *before* the change. That is S10's second question -
    /// what happens when the version is deliberately left unchanged - and it is the case
    /// the xattr hash in the metadata version exists to prevent.
    private var frozenMetadata = false

    /// `sshdrive debug fault <name> --fetch-error noSuchItem|cannotSynchronize|none`: what
    /// every `fetchContents` answers instead of reading bytes. S5's eighth question is what
    /// the system does with each, since the mass-deletion guard (section 6.4) needs
    /// `.cannotSynchronize` to leave the item in place where `.noSuchItem` would delete it.
    private var fetchError: String?

    /// Section 8.1's probe as the last connection found it. Kept on the runtime rather
    /// than read off the transport, because since milestone 5 there may be no transport:
    /// `status` on an offline location still has to print what the server was (section 6.3).
    var serverProbeResult: ServerProbe.Result?

    /// The last transport error, for `show` and `status` (section 8).
    var lastTransportError: String?

    /// Section 5.3's recovery: what `IndexReconcile` found and did at start, and whether
    /// the replica walk is still owed. The walk needs the File Provider domain to exist,
    /// so it runs after `add(domain)` rather than inside `start()`.
    private(set) var recoveryReport: [String: Any] = [:]
    private var reconcileOwed = false

    private var concurrentFetches = 0
    private var peakConcurrentFetches = 0
    private var totalFetches = 0
    /// One entry per fetch: start, end (0 while running) and the path, as seconds since
    /// the reference date, so S6 can see the overlap rather than infer it from a peak.
    private var fetchTimeline: [(path: String, start: Double, end: Double)] = []

    init(
        location: Location, transport: any SFTPTransport, indexURL: URL, backupURL: URL,
        macID: String = "00000000"
    ) throws {
        self.location = location
        self.transport = transport
        self.indexURL = indexURL
        self.backupURL = backupURL
        self.index = try IndexWriter(path: indexURL.path)
        self.identity = .unknown
        self.macID = macID
        self.scheduler = TransferScheduler(locationID: location.id)
        // Provisional until `start()` has asked the server where its root really is; a
        // location that never starts never writes, so nothing is judged against it.
        self.symlinkRoots = SymlinkPolicy.Roots(canonical: location.remotePath ?? "/")
        self.rows = RowBuilder(
            permissions: location.permissions, identity: .unknown, roots: self.symlinkRoots)
        self.writer = RemoteWriter(
            transport: transport,
            options: RemoteWriter.Options(
                macID: macID,
                localHostName: LocationRuntime.localHostName,
                createCheck: location.createCheck))
    }

    /// This Mac's `LocalHostName`, which is what names a conflict copy (section 5.5): it
    /// is the Mac's content that is being set aside, so it is the Mac that signs it.
    /// `ProcessInfo.hostName` is `<LocalHostName>.local` on a Mac with no domain, so the
    /// suffix comes off rather than pulling in SystemConfiguration for one string.
    static var localHostName: String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(6) }
        return name.isEmpty ? "this Mac" : name
    }

    func start() async throws {
        if let fake = transport as? FakeTransport {
            identity = ServerIdentity(
                uid: await fake.serverUID, gid: await fake.serverGID, supplementaryGroups: [])
        }
        // Section 5.3's recovery, before anything is served: an index that fails its
        // integrity check is restored from `index.sqlite.bak` **into** the live database
        // through the online backup API, and one SQLite cannot open at all is truncated
        // under its own inode after the extension's reader has been asked to close. Either
        // way the flag is left set and the replica walk below is owed. The flag also
        // outlives a crash: an agent that starts and finds it set redoes the walk, since
        // the extension is stalled on that flag and nothing else will clear it.
        let wasReconciling = index.isReconciling
        let indexPath = indexURL.path
        let recovery = await IndexReconcile.recoverIfNeeded(
            locationID: location.id,
            indexURL: indexURL,
            backupURL: backupURL,
            writer: index,
            wasReconciling: wasReconciling,
            closeReader: { await ExtensionPeers.shared.closeReaders() },
            reopenReader: { ExtensionPeers.shared.reopenReaders() },
            reopen: { try IndexWriter(path: indexPath) })
        if let restored = recovery.writer { index = restored }
        recoveryReport = recovery.report.asJSON
        // `recoverIfNeeded` never clears the flag; the walk is the only thing that does,
        // and the walk needs the domain to exist so the replica can be read. So it runs
        // from `DomainManager` after `add(domain)`, through `finishReconcileIfOwed`.
        reconcileOwed = index.isReconciling
        if reconcileOwed {
            Log.agent.notice(
                "\(self.location.id, privacy: .public): a reconcile against the replica is owed (\(recovery.report.state, privacy: .public))"
            )
        }
        do {
            try await applyConnection()
        } catch {
            // Section 5.6: a location whose server is down still mounts. The domain is
            // added, `item(for:)` and the replica keep working, a save is queued, and the
            // breaker answers every remote call `.serverUnreachable` until it connects -
            // at which point `applyConnection` runs again from the gate's hook. Failing
            // `start()` here instead would leave the location with no domain at all, so a
            // laptop booted on a train would come back with nothing in Finder.
            Log.agent.notice(
                "\(self.location.id, privacy: .public): starting offline (\(error.localizedDescription, privacy: .public)); the domain is served from the replica until the breaker connects"
            )
        }
    }

    /// Everything about a location that can only be known from a live connection: the
    /// identity behind section 5.4's capability mapping, section 6.1's channel budget,
    /// section 5.7's two spellings of the root, and the root row itself.
    ///
    /// Called from `start()` and again from `ConnectionGate`'s connected hook on every
    /// reconnect, because a server can come back with a different `MaxSessions`, a
    /// different `id`, or a root that has moved (section 9.1). Explicit values come from
    /// the hook; without them it reads whatever the transport is holding now.
    func applyConnection(
        budget: ChannelBudget? = nil, probe: ServerProbe.Result? = nil,
        sharesMetadataChannel: Bool? = nil
    ) async throws {
        // Section 5.7: both spellings of the root, because on a host where `/home` is a
        // symlink the canonical root is `/var/home/alec` while every absolute link the
        // user ever made says `/home/alec/…`, and checked against the canonical spelling
        // alone all of them would be hidden.
        //
        // This is also the first remote call of the location, so on the `start()` path it
        // is what makes the breaker open its first connection.
        let canonical = try await transport.realpath(.root)

        var live = probe
        if live == nil || budget == nil, let reconnecting = transport as? ReconnectingTransport,
            let connection = await reconnecting.gate.currentConnection()
        {
            if live == nil { live = connection.probe }
            channelBudget = budget ?? connection.budget
            await scheduler.setSharesMetadataChannel(
                sharesMetadataChannel ?? connection.transfersShareMetadataChannel)
        } else {
            if let budget { channelBudget = budget }
            if let sharesMetadataChannel {
                await scheduler.setSharesMetadataChannel(sharesMetadataChannel)
            }
        }
        // Section 5.4: the identity comes from one `id` exec channel at connect, and an
        // SFTP-only account - no shell, or no channel to spare for one - keeps `.unknown`,
        // which is what gives every item full capabilities.
        if let live {
            identity = live.identity
            serverProbeResult = live
        }

        var alternate: String? = nil
        if let typed = location.remotePath, typed.hasPrefix("/") {
            alternate = typed
        } else if let live, !live.home.isEmpty {
            alternate = live.home
        }
        symlinkRoots = SymlinkPolicy.Roots(canonical: canonical, alternate: alternate)
        rows = RowBuilder(
            permissions: location.permissions, identity: identity, roots: symlinkRoots)
        await writer.setOptions(
            RemoteWriter.Options(
                macID: macID,
                localHostName: LocationRuntime.localHostName,
                createCheck: location.createCheck))

        let rootAttributes = try await transport.lstat(.root)
        try index.ensureRoot(
            mode: Int64(rootAttributes.mode),
            uid: Int64(rootAttributes.uid),
            gid: Int64(rootAttributes.gid))
        try refreshRootRow(rootAttributes)
        lastTransportError = nil

        // Section 5.5: "the probe tests this once, in the location root". Off the start
        // path, because it is five round trips and nothing before the first write needs
        // its answer - `needsPreflight` assumes OpenSSH's refusal until it lands.
        let writer = self.writer
        Task.detached { await writer.probeRenameSemantics() }
    }

    /// Whether this server's plain `rename` refuses an existing name, as the probe found
    /// it, for `status` and the debug hooks. Nil until the probe has answered.
    func renameRefusesExistingNames() async -> Bool? { await writer.renameSemantics() }

    /// Runs section 5.5's rename-semantics probe now, or reports the answer it already
    /// has. `sshdrive debug transport rename-check` is this.
    func probeRenameSemantics() async -> Bool { await writer.probeRenameSemantics() }

    /// The canonical root the transport resolved, for the debug hooks and, in
    /// milestone 3, for `sshdrive show`.
    func rootDescription() async throws -> String {
        try await transport.realpath(.root)
    }

    /// The live `SSHBackedTransport`, when there is one. Since milestone 5 a location's
    /// transport is a `ReconnectingTransport` and the connection behind it comes and goes
    /// (section 6.3), so everything that used to cast the transport asks here instead and
    /// answers for "offline" as well as for "fake".
    func liveConnection() async -> SSHBackedTransport? {
        if let ssh = transport as? SSHBackedTransport { return ssh }
        if let reconnecting = transport as? ReconnectingTransport {
            return await reconnecting.gate.currentConnection()
        }
        return nil
    }

    private var isRemoteBacked: Bool {
        transport is SSHBackedTransport || transport is ReconnectingTransport
    }

    /// `-O exit` on the master and the SFTP channel with it, for a location that is
    /// being unmounted or removed. A fake-backed location has nothing to shut down.
    func shutdownTransport() async {
        if let reconnecting = transport as? ReconnectingTransport {
            await reconnecting.gate.shutdown()
            return
        }
        if let ssh = transport as? SSHBackedTransport { await ssh.shutdown() }
    }

    // MARK: Reading

    /// The path an identifier maps to, or nil when there is no row.
    private func path(for identifier: String) throws -> RelativePath? {
        guard let row = try index.item(identifier: identifier) else { return nil }
        return try RelativePath.fromIndexBytes(row.path)
    }

    func snapshot(identifier: String) throws -> SSHDriveItemSnapshot {
        guard let row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        return LocationRuntime.snapshot(from: row)
    }

    /// Section 5.2: "directory listings travel as XPC values, paged for directories with
    /// tens of thousands of entries". One `readdir` and one reconcile produce the whole
    /// listing; the pages are cut from it, so a page token is an offset into a listing the
    /// agent already holds and a second page never re-lists the directory.
    static let enumerationPageSize = 2_000

    private struct PendingListing {
        let items: [SSHDriveItemSnapshot]
        var deliveredThrough: Int
        let takenAt: Date
    }

    /// Cut listings, by token. Dropped as soon as their last page is handed over, and
    /// after five minutes in case the system abandons an enumeration half way.
    private var pendingListings: [String: PendingListing] = [:]

    /// readdir the mapped path, reconcile with the index, return items (section 5.1).
    /// Records the folder as recently viewed (section 6.5).
    func enumerateItems(container identifier: String, pageToken: String?) async throws
        -> (items: [SSHDriveItemSnapshot], nextPageToken: String?)
    {
        try refuseWhileReconciling()
        if let pageToken {
            return continueListing(token: pageToken)
        }
        guard let containerRow = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(containerRow.path)
        try index.addRoot(path: path.bytes, reason: "viewed")
        let items = try await reconcile(directory: path, containerRow: containerRow).items
        guard items.count > LocationRuntime.enumerationPageSize else { return (items, nil) }

        let token = UUID().uuidString
        expireStaleListings()
        pendingListings[token] = PendingListing(
            items: items, deliveredThrough: 0, takenAt: Date())
        Log.agent.notice(
            "paging \(items.count, privacy: .public) entries of \(path.description, privacy: .public) in \(LocationRuntime.enumerationPageSize, privacy: .public)s"
        )
        return continueListing(token: token)
    }

    private func continueListing(token: String) -> (items: [SSHDriveItemSnapshot], nextPageToken: String?) {
        guard var listing = pendingListings[token] else { return ([], nil) }
        let start = listing.deliveredThrough
        let end = min(start + LocationRuntime.enumerationPageSize, listing.items.count)
        let page = Array(listing.items[start..<end])
        listing.deliveredThrough = end
        if end >= listing.items.count {
            pendingListings.removeValue(forKey: token)
            return (page, nil)
        }
        pendingListings[token] = listing
        return (page, token)
    }

    private func expireStaleListings() {
        let cutoff = Date().addingTimeInterval(-300)
        pendingListings = pendingListings.filter { $0.value.takenAt > cutoff }
    }

    /// The same listing, diffed against the index, which is how a folder refreshes when
    /// Finder shows it (section 5.1).
    func enumerateChanges(container identifier: String) async throws
        -> (items: [SSHDriveItemSnapshot], deleted: [String])
    {
        try refuseWhileReconciling()
        guard let containerRow = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(containerRow.path)
        let result = try await reconcile(directory: path, containerRow: containerRow)
        return (result.changed, result.deleted)
    }

    struct ReconcileResult {
        var items: [SSHDriveItemSnapshot] = []
        var changed: [SSHDriveItemSnapshot] = []
        var deleted: [String] = []
        /// Deletions the mass-deletion guard held rather than reported (section 6.4).
        var held: [Data] = []
        /// Holds cleared because the items came back.
        var released: [Data] = []
    }

    /// One listing, diffed against the index. Every difference becomes a row change and
    /// an anchor, so the working set carries it to the system whatever else happens
    /// (section 5.3).
    func reconcile(directory: RelativePath, containerRow: IndexItem) async throws
        -> ReconcileResult
    {
        // Section 9.1, "never descend through a link": the container is re-`lstat`ed
        // before anything is done inside it, because SFTP `opendir` **follows** a symlink.
        // Without this, a directory replaced on the server by a link to `/etc` after it
        // was enumerated is read straight through and every name under it gets a row -
        // measured against the testbed on 2026-09-04, which is what the deferred half of
        // S3 was for. `lstat` semantics are what keep the index free of any path with a
        // link as an intermediate component.
        let entries: [SFTPDirectoryEntry]
        do {
            if !directory.isRoot {
                let attributes = try await transport.lstat(directory)
                guard attributes.type == .directory else {
                    Log.agent.error(
                        "\(directory.description, privacy: .public) is no longer a directory (\(attributes.type.rawValue, privacy: .public)); refusing to descend"
                    )
                    try replaceDirectoryRow(
                        directory, attributes: attributes, containerRow: containerRow)
                    throw SSHDriveAgentError.noSuchItem.asNSError(
                        "\(directory.description) is no longer a directory on the server.")
                }
            }
            entries = try await transport.readdir(directory)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }

        // Section 5.5's stale temp files: one carrying this Mac's `<mac8>` that is not
        // in the in-flight set died with a connection or an agent and is removed as soon
        // as the agent lists its directory, however new it is; another Mac's is left for
        // 30 days. This runs before the rows are built, so a temp file never gets one.
        await writer.sweepTemporaries(in: directory, entries: entries)

        // Section 5.5's in-flight set: the differ skips paths with an upload in flight,
        // or our own writes come back as remote changes and the system re-fetches the
        // file it just wrote.
        let dirty = await writer.inFlightPaths()

        // SFTP v3's `readdir` carries attributes but no link target, so every link in the
        // listing costs one `readlink`. Section 5.7 wants the lexical check "done once per
        // link at enumeration time", and this is that once: the answer is stored on the
        // row and the extension never repeats it.
        var targets: [Data: String] = [:]
        for entry in entries where entry.attributes.type == .symlink
            && entry.attributes.symlinkTarget == nil
        {
            guard let childPath = try? directory.appending(component: entry.name) else { continue }
            if let target = try? await transport.readlink(childPath) {
                targets[childPath.bytes] = target
            }
        }

        var result = ReconcileResult()
        var seenPaths: Set<Data> = []

        // Section 5.4's name rules. "The one already visible in the index keeps its slot",
        // so the incumbents go in first: without them the shown name would flip every time
        // a hash-ordered readdir came back in a different order.
        var visibleNames: Set<Data> = []
        for child in try index.children(ofParent: containerRow.identifier) where child.hidden == 0 {
            if let last = (try? RelativePath.fromIndexBytes(child.path))?.lastComponent {
                visibleNames.insert(last)
            }
        }
        let classified = NameVisibility.classify(entries: entries, visibleNames: visibleNames)
        for skipped in classified.skipped {
            Log.agent.debug(
                "not enumerated: \(String(decoding: skipped.name, as: UTF8.self), privacy: .public) - \(skipped.reason, privacy: .public)"
            )
        }

        // One transaction for the whole listing: a directory with 10,000 entries is
        // 10,000 autocommits otherwise, and that, not the wire, is what a large
        // enumeration spends its time on (section 5.3).
        try index.batch {
        for classifiedEntry in classified.entries {
            let entry = classifiedEntry.entry
            guard let childPath = try? directory.appending(component: entry.name) else { continue }
            seenPaths.insert(childPath.bytes)
            // A path the agent is uploading to right now is skipped whole: its row is
            // written by the upload's own post-upload `lstat` (section 5.5).
            if dirty.contains(childPath.bytes) { continue }

            if classifiedEntry.hidden == 0 {
                hiddenReasons.removeValue(forKey: childPath.bytes)
            } else {
                hiddenReasons[childPath.bytes] = classifiedEntry.reason
            }

            let existing = try index.item(path: childPath.bytes)
            var attributes = entry.attributes
            if attributes.type == .symlink, attributes.symlinkTarget == nil {
                attributes.symlinkTarget = targets[childPath.bytes]
            }
            let row = try makeRow(
                path: childPath,
                attributes: attributes,
                parent: containerRow,
                existing: existing,
                hidden: classifiedEntry.hidden)
            try index.upsert(row)

            // A hidden row holds its name and nothing else: it is never enumerated, and a
            // create or rename onto it fails `.filenameCollision` (sections 5.4, 5.7).
            // The row's own `hidden`, not the name rules': a link whose target leaves the
            // share is judged by `RowBuilder`, after the names have been sorted out.
            guard row.hidden == 0 else {
                // A name that was shown and is now hidden - a newcomer took the slot, or
                // the incumbent was renamed away - has to reach the system as a deletion,
                // or the replica keeps a file no enumeration will ever mention again.
                if let existing, existing.hidden == 0 {
                    try index.appendAnchor(identifier: row.identifier, kind: .deleted)
                    result.deleted.append(row.identifier)
                }
                continue
            }

            let snapshot = LocationRuntime.snapshot(from: row)
            result.items.append(snapshot)
            if existing == nil || existing?.metadataVersion != row.metadataVersion
                || existing?.hidden != row.hidden
            {
                try index.appendAnchor(identifier: row.identifier, kind: .modified)
                result.changed.append(snapshot)
            }
        }

        // Deleted rows are deleted: no tombstones (section 5.3) - but a deletion inferred
        // from a **listing** goes through the mass-deletion guard of section 6.4 first,
        // which holds a diff that is implausibly large and any deletion of an item the
        // system lists as pending. A local-only row (`hidden = 3`, a `.DS_Store` Finder
        // wrote) is outside both rules: it has no remote content by definition, so a
        // listing that does not mention it is not evidence that it went (section 5.4).
        var missing: [(path: Data, identifier: String)] = []
        var knownNonHidden = 0
        for child in try index.children(ofParent: containerRow.identifier)
        where child.hidden != RowBuilder.hiddenLocalOnly {
            if child.hidden == 0 { knownNonHidden += 1 }
            guard !seenPaths.contains(child.path) else { continue }
            if child.hidden == 0 {
                missing.append((child.path, child.identifier))
            } else {
                // A hidden row holds a name and nothing else; the user never saw it, so
                // there is no half-applied deletion for the guard to prevent.
                try index.delete(identifier: child.identifier)
            }
        }
        try applyGuardedDeletions(
            directory: directory, missing: missing, knownNonHidden: knownNonHidden,
            seenPaths: seenPaths, into: &result)
        }

        return result
    }

    /// A directory that is no longer a directory. Every row beneath it is deleted - those
    /// paths are gone, whatever now sits at the name - and the row itself is rewritten
    /// from the fresh `lstat`, so the item the system next asks about is the link (or the
    /// file) that is really there. Section 5.7 decides whether that link is shown at all;
    /// until milestone 4 it is recorded and the enumeration of it fails.
    private func replaceDirectoryRow(
        _ directory: RelativePath, attributes: SFTPFileAttributes, containerRow: IndexItem
    ) throws {
        for row in try index.allItems()
        where row.path != directory.bytes
            && (try? RelativePath.fromIndexBytes(row.path))?.isUnder(directory) == true
        {
            try index.delete(identifier: row.identifier)
        }
        guard let parentIdentifier = containerRow.parent,
            let parentRow = try index.item(identifier: parentIdentifier)
        else { return }
        var replaced = try makeRow(
            path: directory, attributes: attributes, parent: parentRow, existing: containerRow)
        replaced.identifier = containerRow.identifier
        try index.upsert(replaced)
        try index.appendAnchor(identifier: replaced.identifier, kind: .modified)
    }

    /// Builds a finished row. Every derived field - the version formula, the generation
    /// bump, the two bitmasks, the section 5.7 symlink check - is `RowBuilder`'s, in the
    /// package, so that none of it lives in the extension (section 5.2) and all of it is
    /// unit-testable without an app bundle.
    func makeRow(
        path: RelativePath,
        attributes: SFTPFileAttributes,
        parent: IndexItem,
        existing: IndexItem?,
        hidden: Int64? = nil,
        localAttributes: LocalAttributes? = nil
    ) throws -> IndexItem {
        let built = rows.build(
            path: path, attributes: attributes, parent: parent, existing: existing,
            hidden: hidden, localAttributes: localAttributes)
        if built.hiddenReason.isEmpty {
            if built.row.hidden == 0 { hiddenReasons.removeValue(forKey: path.bytes) }
        } else {
            hiddenReasons[path.bytes] = built.hiddenReason
        }
        return built.row
    }

    private func refreshRootRow(_ attributes: SFTPFileAttributes) throws {
        guard var root = try index.item(identifier: IndexWriter.rootIdentifier) else { return }
        let capabilities = ItemDerivation.capabilities(
            type: .directory,
            mode: attributes.mode, uid: attributes.uid, gid: attributes.gid,
            parentMode: attributes.mode, parentUID: attributes.uid, parentGID: attributes.gid,
            permissions: location.permissions,
            identity: identity,
            kept: root.pinState == 1)
        let flags = ItemDerivation.fileSystemFlags(
            type: .directory,
            mode: attributes.mode, uid: attributes.uid, gid: attributes.gid,
            permissions: location.permissions,
            identity: identity,
            capabilities: capabilities,
            filename: location.displayName)
        root.mode = Int64(attributes.mode)
        root.uid = Int64(attributes.uid)
        root.gid = Int64(attributes.gid)
        root.capabilities = Int64(capabilities.rawValue)
        root.fileSystemFlags = Int64(flags.rawValue)
        root.contentVersion = IndexItem.contentVersion(
            size: 0, mtime: attributes.mtime, generation: root.generation)
        root.metadataVersion = ItemDerivation.metadataVersion(
            contentVersion: root.contentVersion,
            mode: root.mode, uid: root.uid, gid: root.gid,
            capabilities: root.capabilities, fileSystemFlags: root.fileSystemFlags,
            kept: root.kept, xattrs: root.xattrs)
        try index.upsert(root)
    }

    // MARK: Transfers

    /// Download through the file handle the extension opened on its temp file
    /// (section 5.2), on the bulk channel, under the transfer scheduler of section 6.2.
    ///
    /// The agent `lstat`s before and after the download; if size or mtime moved in
    /// between, the file changed under the transfer and the download is made again, once,
    /// after which a still-moving file fails the fetch as `.serverUnreachable` so the
    /// system retries later rather than keeping a torn copy (section 5.1). The item
    /// returned carries the version the final `lstat` read.
    func fetchContents(
        identifier: String, into handle: FileHandle, transferID: String,
        kind: TransferScheduler.Kind = .foreground,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SSHDriveItemSnapshot {
        try await fetch(
            identifier: identifier, into: handle, transferID: transferID, kind: kind,
            range: nil, progress: progress)
    }

    /// `fetchPartialContents`: a range request, for large media (section 5.1). Always a
    /// foreground transfer (section 6.2), and never re-tried on a moving file: the caller
    /// asked for a window of a file it is streaming, and a fresh window is one call away.
    func fetchPartialContents(
        identifier: String, offset: Int64, length: Int64, into handle: FileHandle,
        transferID: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SSHDriveItemSnapshot {
        try await fetch(
            identifier: identifier, into: handle, transferID: transferID, kind: .foreground,
            range: (UInt64(max(0, offset)), UInt64(max(0, length))), progress: progress)
    }

    private func fetch(
        identifier: String, into handle: FileHandle, transferID: String,
        kind: TransferScheduler.Kind,
        range: (offset: UInt64, length: UInt64)?,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> SSHDriveItemSnapshot {
        try refuseWhileReconciling()
        guard let row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(row.path)

        // S5's `.noSuchItem` versus `.cannotSynchronize` question, which decides whether
        // the mass-deletion guard of section 6.4 also has to hold deletions of pending
        // items. The refusal is raised before anything is read, exactly as the guard
        // would raise it.
        switch fetchError {
        case "noSuchItem":
            throw SSHDriveAgentError.noSuchItem.asNSError(
                "debug fault --fetch-error noSuchItem")
        case "cannotSynchronize":
            throw SSHDriveAgentError.cannotSynchronize.asNSError(
                "debug fault --fetch-error cannotSynchronize: the item is held by the mass-deletion guard.")
        default:
            break
        }

        // Section 6.4: "While held, opening one of the items fetches from the server and
        // fails. The failure is reported as `.cannotSynchronize` carrying the ENOENT,
        // never as `.noSuchItem`" - that error tells the system the item does not exist
        // and it would remove the item locally while the row, the pin and the hold
        // remain, which is the half-applied deletion the guard exists to avoid.
        if (try? index.heldRow(path: row.path)) ?? nil != nil {
            throw SSHDriveAgentError.cannotSynchronize.asNSError(
                "\"\(path.description)\" is missing on the server. SSH Drive is holding the deletion "
                    + "until it can confirm it; `sshdrive accept-deletions` applies it now.")
        }

        // Section 5.4: a local-only item has no remote content, so a `fetchContents` for
        // one - after Finder's "Remove Download", or a system-side eviction - returns the
        // bytes the row kept rather than an empty file that would reset the folder's view
        // settings.
        if row.hidden == RowBuilder.hiddenLocalOnly {
            let sink = HandleSink(handle: handle)
            try sink.truncate()
            let bytes = row.localContent ?? Data()
            if !bytes.isEmpty {
                let slice = range.map { window -> Data in
                    let start = Int(min(window.offset, UInt64(bytes.count)))
                    let end = min(start + Int(window.length), bytes.count)
                    return start < end ? bytes.subdata(in: start..<end) : Data()
                } ?? bytes
                sink.write(at: 0, data: slice)
            }
            try sink.finish()
            progress(Int64(bytes.count), max(Int64(bytes.count), 1))
            return LocationRuntime.snapshot(from: row)
        }

        let slot = noteFetchStarted(path: path.description)
        defer { noteFetchFinished(slot) }

        let transport = self.transport
        let delay = fetchDelayMilliseconds
        do {
            // Section 6.2: the transfer waits here, with its XPC call open, until one of
            // the four slots is free, and is handed its share of the pipelined window.
            let after = try await scheduler.run(transferID: transferID, kind: kind) { window in
                var attempt = 0
                while true {
                    attempt += 1
                    let before = try await transport.lstat(path)
                    let total = range.map { Int64($0.length) } ?? before.size
                    let sink = HandleSink(handle: handle)
                    try sink.truncate()
                    progress(0, max(total, 1))
                    _ = try await transport.readStreaming(
                        path, offset: range?.offset ?? 0,
                        length: range.map { $0.length },
                        window: window
                    ) { chunkOffset, data in
                        sink.write(at: chunkOffset - (range?.offset ?? 0), data: data)
                        progress(sink.written, max(total, 1))
                    }
                    if delay > 0 {
                        // The await is the point: the actor lets every other fetch in
                        // while this one waits, so the count is the system's concurrency
                        // rather than ours (S6).
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    }
                    try sink.finish()
                    let after = try await transport.lstat(path)
                    if before.size == after.size, before.mtime == after.mtime { return after }
                    if range != nil { return after }
                    Log.agent.notice(
                        "file moved under a fetch: \(path.description, privacy: .public) (attempt \(attempt, privacy: .public))"
                    )
                    // Once, then give up: a still-moving file fails as serverUnreachable
                    // so the system retries later rather than keeping a torn copy.
                    if attempt >= 2 { throw SFTPError.connectionLost }
                }
            }

            var updated = try makeRow(
                path: path,
                attributes: after,
                parent: try index.item(identifier: row.parent ?? IndexWriter.rootIdentifier)
                    ?? index.ensureRoot(),
                existing: row)
            updated.lastFetch = Date().timeIntervalSince1970
            try index.upsert(updated)
            return LocationRuntime.snapshot(from: updated)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }
    }

    /// Cancelling the extension's `Progress`, or its connection invalidating (section
    /// 5.2). A queued transfer is dropped; a running one's Task is cancelled, and every
    /// SFTP request it has not sent yet throws `.cancelled`.
    func cancel(transferID: String) async {
        await scheduler.cancel(transferID: transferID)
    }

    func schedulerStatistics() async -> TransferScheduler.Statistics {
        await scheduler.stats()
    }

    // MARK: Writing

    /// What a mutation produced, and whether the agent still owes the system an
    /// eviction. The system **believes whatever version a `modifyItem` reply carries** -
    /// it records it, never re-fetches and never re-offers (S3, 2026-09-04) - so
    /// returning the remote item after a conflict copy would leave the replica holding
    /// the *local* bytes under the *remote* version for ever. The eviction is what makes
    /// the next open download the remote content, and it has to happen after the reply
    /// has gone, which is why it travels back to the caller rather than being done here
    /// (section 5.5).
    struct MutationResult {
        var snapshot: SSHDriveItemSnapshot
        var evictAfterReply = false
    }

    /// `mkdir`, `symlink`, `.DS_Store`, or the section 5.5 upload: bytes into
    /// `.sshdrive-upload-<mac8>-<uuid>` beside the destination and then a plain,
    /// non-overwriting `rename` into place, with the mode and the modification date set
    /// back afterwards and the row built from the `lstat` that follows.
    func createItem(
        parentIdentifier: String,
        filename: String,
        isDirectory: Bool,
        symlinkTarget: String?,
        fileSystemFlags: UInt64? = nil,
        modificationDate: Int64? = nil,
        extendedAttributes: [String: Data]? = nil,
        tagData: Data? = nil,
        contents: FileHandle?,
        transferID: String = UUID().uuidString,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SSHDriveItemSnapshot {
        try refuseWhileReconciling()
        try failWritesIfFaulted()
        if createsCollide {
            Log.agent.notice(
                "debug fault --collisions: refusing createItem \(filename, privacy: .public) with .filenameCollision"
            )
            throw SSHDriveAgentError.filenameCollision.asNSError(
                "debug fault --collisions on: the name is already taken on the server.")
        }
        let parentRow = try index.item(identifier: parentIdentifier) ?? index.ensureRoot()
        let parentPath = try RelativePath.fromIndexBytes(parentRow.path)
        // Filenames arriving from the system pass through the RelativePath constructor
        // before anything else sees them (section 9.1).
        let path = try parentPath.appending(component: filename)
        try refuseHiddenName(at: path)

        let local = LocalAttributes(xattrs: extendedAttributes ?? [:], tagData: tagData)

        // Section 5.4: a `.DS_Store` succeeds locally and is never uploaded. Finder keeps
        // working, the server stays clean.
        if NameVisibility.isDSStore(Data(filename.utf8)) {
            return try swallowLocalOnly(
                at: path, parent: parentRow, contents: contents, localAttributes: local)
        }

        do {
            let attributes: SFTPFileAttributes
            if isDirectory {
                try await writer.makeDirectory(path, mode: 0o755)
                attributes = try await writer.stat(path)
            } else if let symlinkTarget {
                // Section 5.7: `ln -s` inside the mount arrives here, and an absolute or
                // escaping target is refused, because the link would be hidden the moment
                // it was created.
                _ = try await writer.makeSymlink(
                    target: symlinkTarget, at: path, roots: symlinkRoots)
                attributes = try await writer.stat(path)
            } else {
                // Section 5.5: 0644 for an ordinary file, 0755 when the local one is
                // executable, as `sftp put` does; the server's umask still applies, which
                // is why the mode is set back after the rename.
                let mode = LocationRuntime.uploadMode(fileSystemFlags: fileSystemFlags)
                // A create with no contents is an empty file, which is what Finder's
                // "New Document" and a shell `touch` both send.
                let source = contents.map { HandleSource(handle: $0) }
                let outcome = try await scheduler.run(
                    transferID: transferID, kind: .foreground
                ) { [writer] window in
                    try await writer.upload(
                        to: path, mode: mode, modificationDate: modificationDate,
                        replacingExisting: false, base: nil, currentGeneration: 0,
                        window: window, source: { try source?.next() ?? Data() }
                    ) { written in progress(written, max(written, 1)) }
                }
                guard case let .landed(landed) = outcome else {
                    // A create has no base version, so the conflict branch is unreachable.
                    throw SFTPError.failure("Unexpected conflict on a create")
                }
                attributes = landed
            }
            var row = try makeRow(
                path: path, attributes: attributes, parent: parentRow, existing: nil,
                localAttributes: local)
            // Section 5.3: the inode and ns-mtime a rename gave the path cannot be read
            // back over SFTP, so they are reset to null after every upload of ours and
            // the next helper event or GNU sweep records whatever it finds.
            row.inode = nil
            row.mtimeNanoseconds = nil
            try index.upsert(row)
            try index.appendAnchor(identifier: row.identifier, kind: .modified)
            return LocationRuntime.snapshot(from: row)
        } catch let error as RemoteWriteError {
            throw LocationRuntime.mapped(error)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }
    }

    /// Section 5.5: "0644 for an ordinary file, 0755 when the local file is executable".
    static func uploadMode(fileSystemFlags: UInt64?) -> UInt32 {
        guard let fileSystemFlags else { return 0o644 }
        let flags = NSFileProviderFileSystemFlags(rawValue: UInt(truncatingIfNeeded: fileSystemFlags))
        return flags.contains(.userExecutable) ? 0o755 : 0o644
    }

    /// Section 5.4's `.DS_Store`: a row the agent records as local-only (`hidden = 3`)
    /// and never uploads, with its bytes in `local_content` so that a `fetchContents` for
    /// one - after Finder's "Remove Download", or a system-side eviction - returns what
    /// Finder wrote rather than an empty file that would reset the folder's view settings.
    private func swallowLocalOnly(
        at path: RelativePath, parent: IndexItem, contents: FileHandle?,
        localAttributes: LocalAttributes
    ) throws -> SSHDriveItemSnapshot {
        let bytes = (try? contents?.readToEnd()) ?? nil ?? Data()
        let existing = try index.item(path: path.bytes)
        let now = Int64(Date().timeIntervalSince1970)
        let attributes = SFTPFileAttributes(
            type: .file, size: Int64(bytes.count), mtime: now, mode: 0o644,
            uid: UInt32(truncatingIfNeeded: parent.uid ?? 0),
            gid: UInt32(truncatingIfNeeded: parent.gid ?? 0),
            mtimeNanoseconds: nil, inode: nil, symlinkTarget: nil)
        var row = try makeRow(
            path: path, attributes: attributes, parent: parent, existing: existing,
            hidden: RowBuilder.hiddenLocalOnly, localAttributes: localAttributes)
        row.localContent = bytes
        try index.upsert(row)
        try index.appendAnchor(identifier: row.identifier, kind: .modified)
        Log.agent.notice(
            "kept \(path.description, privacy: .public) on this Mac only (\(bytes.count, privacy: .public) bytes); nothing was uploaded"
        )
        return LocationRuntime.snapshot(from: row)
    }

    /// Rename/move, content, mode, extended attributes and Finder tags (section 5.1).
    ///
    /// The content path is section 5.5 end to end: the bytes go to a temp file beside the
    /// destination, the destination is `lstat`ed immediately before the rename, and a
    /// size, mtime or generation that moved since the `baseVersion` the system passed us
    /// makes the temp file - which already holds the local content - a conflict copy
    /// instead.
    func modifyItem(
        identifier: String,
        changedFields: NSFileProviderItemFields,
        baseVersion: String? = nil,
        newParentIdentifier: String?,
        newFilename: String?,
        newFileSystemFlags: UInt64? = nil,
        newModificationDate: Int64? = nil,
        newExtendedAttributes: [String: Data]?,
        newTagData: Data? = nil,
        newSymlinkTarget: String? = nil,
        contents: FileHandle?,
        transferID: String = UUID().uuidString,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> MutationResult {
        try refuseWhileReconciling()
        try failWritesIfFaulted()
        guard var row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        var path = try RelativePath.fromIndexBytes(row.path)
        Log.agent.notice(
            """
            modifyItem \(path.description, privacy: .public) \
            changedFields=0x\(String(changedFields.rawValue, radix: 16), privacy: .public) \
            xattrKeys=\(newExtendedAttributes?.keys.sorted().joined(separator: ",") ?? "-", privacy: .public) \
            tagData=\(newTagData.map { "\($0.count) bytes" } ?? "-", privacy: .public)
            """)

        // The local half first: it is the only half a local-only item has (section 5.4).
        var local = LocalAttributes.decode(row.xattrs)
        if changedFields.contains(.extendedAttributes), let newExtendedAttributes {
            local.xattrs = newExtendedAttributes
        }
        if changedFields.contains(.tagData) {
            // Section 5.4: tags reach a provider as `tagData`, not as an xattr, and the
            // system rebuilds the tags xattr from it on every update. Storing nil when the
            // user clears every tag is the difference between "no tags" and "we forgot".
            local.tagData = newTagData
        }

        if row.hidden == RowBuilder.hiddenLocalOnly {
            return MutationResult(
                snapshot: try modifyLocalOnly(
                    row: row, path: path, contents: contents, localAttributes: local))
        }

        do {
            var evictAfterReply = false

            if changedFields.contains(.parentItemIdentifier) || changedFields.contains(.filename) {
                let parentRow =
                    try index.item(identifier: newParentIdentifier ?? row.parent ?? "")
                    ?? index.ensureRoot()
                let parentPath = try RelativePath.fromIndexBytes(parentRow.path)
                let name = newFilename ?? row.filename
                let destination = try parentPath.appending(component: name)
                try refuseHiddenName(at: destination)
                // Section 5.7: a link's target is re-checked from the destination
                // directory before the move. Allowing the move and then hiding the result
                // would be a way to plant an escaping link on the server through the mount.
                if row.type == "symlink" {
                    let target = try await writer.stat(path).symlinkTarget ?? ""
                    do {
                        _ = try SymlinkPolicy.targetForMove(
                            target, to: destination.parent ?? .root, roots: symlinkRoots)
                    } catch {
                        throw RemoteWriteError.escapingSymlinkTarget
                    }
                }
                // A plain, non-overwriting rename, with the case-only exception of
                // section 5.5 (section 5.5's `move`).
                try await writer.move(path, to: destination)
                try index.rewritePaths(from: path.bytes, to: destination.bytes)
                row.parent = parentRow.identifier
                try index.upsert(row)
                path = destination
            }

            if changedFields.contains(.contents) {
                let mode = UInt32(row.mode ?? 0o644)
                let source = contents.map { HandleSource(handle: $0) }
                let base = baseVersion.flatMap { RemoteWriter.BaseVersion(contentVersion: $0) }
                let generation = row.generation
                let outcome = try await scheduler.run(
                    transferID: transferID, kind: .foreground
                ) { [writer] window in
                    try await writer.upload(
                        to: path, mode: mode, modificationDate: newModificationDate,
                        replacingExisting: true, base: base, currentGeneration: generation,
                        window: window, source: { try source?.next() ?? Data() }
                    ) { written in progress(written, max(written, 1)) }
                }
                if case let .conflicted(copy, copyAttributes, _) = outcome {
                    // Section 5.5: the conflict copy is a sibling, and it gets a
                    // working-set anchor of its own so Finder shows it at once.
                    let parentRow =
                        try index.item(identifier: row.parent ?? IndexWriter.rootIdentifier)
                        ?? index.ensureRoot()
                    let copyRow = try makeRow(
                        path: copy, attributes: copyAttributes, parent: parentRow,
                        existing: nil)
                    try index.upsert(copyRow)
                    try index.appendAnchor(identifier: copyRow.identifier, kind: .modified)
                    evictAfterReply = true
                    Log.agent.error(
                        "\(path.description, privacy: .public) changed on the server; the local content is in \(copy.description, privacy: .public) and the remote item was returned"
                    )
                }
            }

            // Section 5.4: a `modifyItem` whose changedFields carries `.fileSystemFlags`
            // - a `chmod +x` inside the mount - sets or clears the execute bits and
            // re-records the mode. The read and write bits are never changed that way.
            if changedFields.contains(.fileSystemFlags), let newFileSystemFlags,
                row.type != "symlink"
            {
                let flags = NSFileProviderFileSystemFlags(
                    rawValue: UInt(truncatingIfNeeded: newFileSystemFlags))
                let mode = RemoteWriter.modeAfterExecutableChange(
                    current: UInt32(row.mode ?? 0o644),
                    userExecutable: flags.contains(.userExecutable))
                if mode != UInt32(row.mode ?? 0o644) {
                    _ = try await writer.setMode(path, mode: mode)
                }
            }

            let attributes = try await writer.stat(path)
            let parentRow =
                try index.item(identifier: row.parent ?? IndexWriter.rootIdentifier)
                ?? index.ensureRoot()
            var updated = try makeRow(
                path: path, attributes: attributes, parent: parentRow, existing: row,
                localAttributes: local)
            if changedFields.contains(.contents) {
                // Section 5.3: reset after every upload of ours, conflict or not - the
                // rename gave the path a new inode either way.
                updated.inode = nil
                updated.mtimeNanoseconds = nil
            }
            try index.upsert(updated)
            try index.appendAnchor(identifier: updated.identifier, kind: .modified)
            if frozenMetadata {
                // S10's control case: reply with the metadata version the item had before
                // the change. Section 5.3's xattr hash exists so this never happens by
                // accident, and this fault is how the runbook sees what it costs.
                var frozen = updated
                frozen.metadataVersion = row.metadataVersion
                Log.agent.notice(
                    "debug fault --frozen-metadata: replying with the old metadata version \(row.metadataVersion, privacy: .public)"
                )
                return MutationResult(snapshot: LocationRuntime.snapshot(from: frozen))
            }
            if versionMismatch {
                var lying = updated
                lying.contentVersion = updated.contentVersion + "-fault"
                lying.metadataVersion = updated.metadataVersion + "-fault"
                Log.agent.notice(
                    "debug fault --version-mismatch: replying with \(lying.contentVersion, privacy: .public) instead of \(updated.contentVersion, privacy: .public)"
                )
                return MutationResult(snapshot: LocationRuntime.snapshot(from: lying))
            }
            return MutationResult(
                snapshot: LocationRuntime.snapshot(from: updated),
                evictAfterReply: evictAfterReply)
        } catch let error as RemoteWriteError {
            throw LocationRuntime.mapped(error)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }
    }

    /// A `.DS_Store` that Finder rewrote. Nothing reaches the server; only the row's
    /// bytes and its versions move (section 5.4).
    private func modifyLocalOnly(
        row: IndexItem, path: RelativePath, contents: FileHandle?,
        localAttributes: LocalAttributes
    ) throws -> SSHDriveItemSnapshot {
        var updated = row
        if let contents, let bytes = try? contents.readToEnd() {
            updated.localContent = bytes
            updated.size = Int64(bytes.count)
            updated.mtime = Int64(Date().timeIntervalSince1970)
            updated.contentVersion = IndexItem.contentVersion(
                size: updated.size, mtime: updated.mtime, generation: updated.generation)
        }
        updated.xattrs = localAttributes.encoded()
        RowBuilder.restamp(&updated)
        try index.upsert(updated)
        try index.appendAnchor(identifier: updated.identifier, kind: .modified)
        return LocationRuntime.snapshot(from: updated)
    }

    /// "Hidden names hold their slot: a create or rename to one of them fails with
    /// `.filenameCollision`" (section 5.4). Without this the create would succeed on the
    /// server and the next listing would hide one of the two names again, which reads to
    /// the user as a file that saved and then vanished.
    private func refuseHiddenName(at path: RelativePath) throws {
        guard let existing = try index.item(path: path.bytes), existing.hidden != 0 else { return }
        throw SSHDriveAgentError.filenameCollision.asNSError(
            hiddenReasons[path.bytes]
                ?? "That name already exists on the server under a spelling macOS cannot tell apart.")
    }

    /// Section 5.4: "`sshdrive status` lists hidden names under \"not shown\" with the
    /// reason, so the user can rename them server-side."
    func notShown() throws -> [(path: String, reason: String)] {
        try index.allItems().filter { $0.hidden != 0 }.map { row in
            (
                path: String(decoding: row.path, as: UTF8.self),
                reason: hiddenReasons[row.path]
                    ?? {
                        switch row.hidden {
                        case RowBuilder.hiddenEscapingLink:
                            return "a symbolic link whose target is outside this location"
                        case RowBuilder.hiddenLocalOnly:
                            return "kept on this Mac only"
                        default:
                            return "a name macOS cannot tell from another here"
                        }
                    }()
            )
        }
    }

    /// What the server let us hold at once, and what it cost (section 6.1). `status`
    /// shows the note.
    func channelReport() -> [String: Any] { channelBudget.asJSON }

    func channelBudgetValue() -> ChannelBudget { channelBudget }

    /// Section 8.1's probe as the live connection found it, plus the SFTP `extensions`
    /// list from the init reply. Nil for a fake location, which has no server to probe.
    func serverProbe() async -> (probe: ServerProbe.Result, extensions: SFTPServerExtensions)? {
        if let ssh = await liveConnection() { return (ssh.probe, await ssh.extensions) }
        guard isRemoteBacked, let cached = serverProbeResult else { return nil }
        return (cached, SFTPServerExtensions())
    }

    /// `status --probe`: "re-runs the server probe instead of using the cached result"
    /// (section 8). The channel budget's own cache is left alone - that is what
    /// `debug transport reprobe` invalidates, and section 6.1 gives it different rules.
    func reprobeServer() async {
        guard let ssh = await liveConnection() else { return }
        let probe = await ServerProbe.run(master: ssh.master)
        CapabilityCache.storeProbe(
            probe, extensions: await ssh.extensions, locationID: location.id)
        if probe.identity.isKnown, location.permissions == .mode { identity = probe.identity }
        serverProbeResult = probe
    }

    /// `-O check` on our own child. False for a location whose master has gone, which is
    /// what `list` and `status` print as "offline".
    func isConnected() async -> Bool {
        guard isRemoteBacked else { return true }
        guard let ssh = await liveConnection() else { return false }
        return await ssh.isMasterAlive()
    }

    /// The last error this location saw, for `show` and `status`'s "last error" line, and
    /// the input to section 4.3's `ssh-keygen -R` advice.
    ///
    /// `ssh`'s own stderr comes first when there is any: a changed host key, a refused
    /// password and a dead key agent are all reported there and nowhere else, and the
    /// classifier has already read it (section 6.1).
    func lastErrorText() async -> String? {
        if let ssh = await liveConnection() {
            let stderr = await ssh.master.lastStderr
            if !stderr.isEmpty { return stderr }
        }
        return lastTransportError
    }

    /// Recorded wherever a transport error is turned into an `NSError` for the extension,
    /// so `status` can name the last thing that went wrong without keeping a log.
    func recordTransportError(_ text: String) { lastTransportError = text }

    /// Uploads the agent has in flight. `remove` and a domain-recreating `set` refuse
    /// while this is non-zero unless `--force` (section 8).
    func pendingUploadCount() async -> Int {
        await scheduler.stats().running
    }

    /// `statvfs@openssh.com`, shown in `status` as "server free space" (section 8.1). Not
    /// a capability level: Finder has no way to display it for a third-party domain.
    func freeSpaceDescription() async -> String? {
        guard isRemoteBacked else { return nil }
        guard let stats = try? await transport.statvfs(.root) else { return nil }
        let free = stats.availableBlocks &* stats.blockSize
        let total = stats.totalBlocks &* stats.blockSize
        guard total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)
            + " of " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    /// The identity section 5.4 maps modes against, and how it was found. Nil for a fake
    /// location, which has no server to ask.
    func identityReport() -> [String: Any]? {
        guard isRemoteBacked, let probe = serverProbeResult else { return nil }
        return [
            "known": probe.identity.isKnown,
            "description": probe.description,
            "failure": probe.failure,
            "shellPrefix": probe.shellPrefix,
            "permissionsSetting": location.permissions.rawValue,
        ]
    }

    /// Section 5.5's deletes. A non-empty directory is refused with `.deletionRejected`
    /// unless the system passed the recursive option; a delete of something already gone
    /// succeeds; and the recursive walk comes from the server rather than the index,
    /// because folders Finder never opened have no rows.
    func deleteItem(identifier: String, recursive: Bool) async throws {
        try refuseWhileReconciling()
        guard let row = try index.item(identifier: identifier) else { return }
        let path = try RelativePath.fromIndexBytes(row.path)

        // A local-only item (`hidden = 3`) has no remote content: the row and its bytes
        // are the whole item (section 5.4).
        if row.hidden == RowBuilder.hiddenLocalOnly {
            try index.delete(identifier: identifier)
            return
        }

        do {
            try await writer.delete(
                path, isDirectory: row.type == "directory", recursive: recursive)
        } catch let error as RemoteWriteError {
            throw LocationRuntime.mapped(error)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }

        // Deleted rows are deleted, and so is everything beneath them: no tombstones
        // (section 5.3). Each `delete` writes its own deletion anchor in the same
        // transaction as the row, and the whole subtree is one outer transaction.
        try index.batch {
            for descendant in try index.allItems()
            where descendant.path != path.bytes
                && (try? RelativePath.fromIndexBytes(descendant.path))?.isUnder(path) == true
            {
                try index.delete(identifier: descendant.identifier)
            }
            try index.delete(identifier: identifier)
        }
    }

    // MARK: Signals and maintenance

    func currentSequence() throws -> Int64 { try index.currentSequence() }

    /// Section 5.3's reconcile against the system's replica, run after the domain exists
    /// so `getUserVisibleURL` and `getIdentifierForUserVisibleFile(at:)` can answer. It
    /// clears `meta.reconciling`, which is what lifts the extension's stall.
    @discardableResult
    func finishReconcileIfOwed() async -> [String: Any]? {
        guard reconcileOwed else { return nil }
        reconcileOwed = false
        let report = await IndexReconcile.reconcileAgainstReplica(
            locationID: location.id, writer: index,
            permissions: location.permissions, identity: identity)
        recoveryReport = report.asJSON
        return report.asJSON
    }

    /// `sshdrive debug reconcile --force`: sets the flag so the whole of section 5.3's
    /// recovery path can be exercised on a healthy index.
    func markReconciling() throws {
        try index.setReconciling(true)
        reconcileOwed = true
    }

    /// "While a reconcile runs, every enumeration and fetch for that domain is answered
    /// with `.serverUnreachable` by the agent" (section 5.3). Reading a directory the
    /// system considers stale triggers `enumerateItems`, and an agent with a half-built
    /// index would mint fresh identifiers for everything in it before the walk arrived.
    func refuseWhileReconciling() throws {
        guard index.isReconciling else { return }
        throw SSHDriveAgentError.serverUnreachable.asNSError(
            "SSH Drive is rebuilding this location's index. It will be back in a moment.")
    }

    /// The agent treats handing out a fresh working-set anchor exactly as it treats a
    /// reconnect: one full sweep of the root set at once, every difference becoming an
    /// anchor after the fresh one (section 5.3).
    func runCatchUpSweep() async throws -> Int {
        guard catchUpSweepEnabled else {
            Log.agent.notice("catch-up sweep is disabled by a debug hook; skipping")
            return 0
        }
        var changes = 0
        let roots = try index.roots()
        var paths = Set(roots.map(\.path))
        paths.insert(Data())
        for pathBytes in paths.sorted(by: { $0.count < $1.count }) {
            guard let containerRow = try index.item(path: pathBytes) else { continue }
            let path = try RelativePath.fromIndexBytes(pathBytes)
            let result = try await reconcile(directory: path, containerRow: containerRow)
            changes += result.changed.count + result.deleted.count
        }
        return changes
    }

    func expireAnchors() throws {
        try index.expireAnchors()
    }

    func setCatchUpSweep(enabled: Bool) {
        catchUpSweepEnabled = enabled
    }

    /// Walks the chain to `path`, listing each directory whose child is missing, so every
    /// ancestor has a row before the pinned one is signalled (section 7.1 step 1). Returns
    /// the paths of the rows this call created.
    @discardableResult
    func materializeAncestors(of path: RelativePath) async throws -> [String] {
        var created: [String] = []
        var current = RelativePath.root
        var containerRow = try index.ensureRoot()
        for component in path.components {
            let child = try current.appending(component: component)
            if try index.item(path: child.bytes) == nil {
                let result = try await reconcile(directory: current, containerRow: containerRow)
                created.append(
                    contentsOf: result.changed.map {
                        String(decoding: $0.pathBytes, as: UTF8.self)
                    })
            }
            guard let childRow = try index.item(path: child.bytes) else {
                throw SSHDriveAgentError.noSuchItem.asNSError(
                    "\(child.description) is not on the server.")
            }
            current = child
            containerRow = childRow
        }
        return created
    }

    // MARK: Spike hooks (S4, S6)

    /// The identifier the system knows an item by, given its path. Every File Provider
    /// call the spikes make (`evictItem`, `getUserVisibleURL`) needs one.
    func identifier(forPath pathString: String) throws -> (identifier: String, row: IndexItem) {
        let path = try RelativePath(string: pathString)
        guard let row = try index.item(path: path.bytes) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(pathString).")
        }
        return (row.identifier, row)
    }

    func row(identifier: String) throws -> IndexItem? { try index.item(identifier: identifier) }

    /// The xattrs the index serves for a row (section 5.4). S4 compares these with what
    /// `xattr -l` shows in the mount before and after an eviction.
    func servedExtendedAttributes(pathString: String) throws -> [String: String] {
        let (_, row) = try identifier(forPath: pathString)
        var out: [String: String] = [:]
        for (key, value) in row.snapshot.extendedAttributes {
            let text = String(data: value, encoding: .utf8)
            out[key] = text ?? value.map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    func setFault(
        writes: Bool?, fetchDelayMilliseconds delay: Int?, versionMismatch mismatch: Bool?,
        collisions: Bool?, uploadDelayMilliseconds uploadDelay: Int? = nil,
        frozenMetadata frozen: Bool? = nil, fetchError: String? = nil
    ) async {
        if let fetchError { self.fetchError = fetchError == "none" ? nil : fetchError }
        if let writes { writesFail = writes }
        if let delay { fetchDelayMilliseconds = delay }
        if let mismatch { versionMismatch = mismatch }
        if let collisions { createsCollide = collisions }
        if let frozen { frozenMetadata = frozen }
        if let uploadDelay {
            uploadDelayMilliseconds = uploadDelay
            await writer.setOptions(
                RemoteWriter.Options(
                    macID: macID,
                    localHostName: LocationRuntime.localHostName,
                    createCheck: location.createCheck,
                    conflictWindowHoldMilliseconds: uploadDelay))
        }
    }

    private func failWritesIfFaulted() throws {
        guard writesFail else { return }
        throw SSHDriveAgentError.serverUnreachable.asNSError(
            "debug fault --writes on: the agent is refusing every upload.")
    }

    private func noteFetchStarted(path: String) -> Int {
        concurrentFetches += 1
        totalFetches += 1
        peakConcurrentFetches = max(peakConcurrentFetches, concurrentFetches)
        fetchTimeline.append(
            (path: path, start: Date().timeIntervalSinceReferenceDate, end: 0))
        return fetchTimeline.count - 1
    }

    private func noteFetchFinished(_ slot: Int) {
        concurrentFetches -= 1
        if fetchTimeline.indices.contains(slot) {
            fetchTimeline[slot].end = Date().timeIntervalSinceReferenceDate
        }
    }

    /// What S6 counts: how many `fetchContents` calls the system keeps open at once,
    /// which bounds the transfer scheduler's backlog (section 6.2).
    func transferStats(reset: Bool) -> [String: Any] {
        let origin = fetchTimeline.first?.start ?? 0
        let report: [String: Any] = [
            "writesFail": writesFail,
            "fetchDelayMilliseconds": fetchDelayMilliseconds,
            "versionMismatch": versionMismatch,
            "createsCollide": createsCollide,
            "uploadDelayMilliseconds": uploadDelayMilliseconds,
            "frozenMetadata": frozenMetadata,
            "inFlight": concurrentFetches,
            "peakConcurrent": peakConcurrentFetches,
            "total": totalFetches,
            "timeline": fetchTimeline.suffix(200).map {
                [
                    "path": $0.path,
                    "start": ($0.start - origin).rounded(toPlaces: 3),
                    "end": $0.end == 0 ? -1 : ($0.end - origin).rounded(toPlaces: 3),
                ] as [String: Any]
            },
        ]
        if reset {
            peakConcurrentFetches = concurrentFetches
            totalFetches = 0
            fetchTimeline.removeAll()
        }
        return report
    }

    /// S5's seventh question, in two halves. `forget` deletes the row with its deletion
    /// anchor, which is exactly what the extension reports through the working set when a
    /// listing says an item has gone (section 5.3, no tombstones); `contentVersion` gives
    /// the row a version the system cannot match, which is what the reconcile walk produces
    /// for an item with a pending local edit. Neither touches the server: the point is what
    /// the **system** does with a pending edit when the index says one of those two things.
    func rewriteRowForSpike(pathString: String, forget: Bool, contentVersion: String?) async throws
        -> [String: Any]
    {
        let path = try RelativePath(string: pathString)
        guard var row = try index.item(path: path.bytes) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(pathString).")
        }
        var report: [String: Any] = ["path": pathString, "identifier": row.identifier]
        if forget {
            try index.batch {
                for descendant in try index.allItems()
                where descendant.path != path.bytes
                    && (try? RelativePath.fromIndexBytes(descendant.path))?.isUnder(path) == true
                {
                    try index.delete(identifier: descendant.identifier)
                }
                try index.delete(identifier: row.identifier)
            }
            report["forgotten"] = true
        } else if let contentVersion {
            row.contentVersion = contentVersion
            row.metadataVersion = contentVersion + "-spike"
            try index.upsert(row)
            _ = try index.appendAnchor(identifier: row.identifier, kind: .modified)
            report["contentVersion"] = contentVersion
        }
        report["sequence"] = try index.currentSequence()
        return report
    }

    func dumpIndex() throws -> [IndexItem] { try index.allItems() }
    func dumpAnchors(limit: Int) throws -> [IndexAnchorEntry] { try index.anchors(limit: limit) }
    func dumpRoots() throws -> [(path: Data, reason: String, lastSeen: Double)] { try index.roots() }

    func backupIndex() throws {
        try index.backup(to: backupURL)
    }

    /// Applies a change to the fake tree as if it had happened on the server, then runs
    /// the sweep so the change reaches the system through the working set, exactly as a
    /// real remote change would (section 12).
    func applyFakeMutation(_ mutation: FakeMutation) async throws -> Int {
        guard let fake = transport as? FakeTransport else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "This location does not run on the fake backend.")
        }
        do {
            try await fake.apply(mutation)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }
        return try await runCatchUpSweep()
    }

    func dumpFakeTree() async throws -> [(path: String, type: String, size: Int64, mode: UInt32)] {
        guard let fake = transport as? FakeTransport else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "This location does not run on the fake backend.")
        }
        return try await fake.dump().map {
            (path: $0.path.description, type: $0.attributes.type.rawValue,
             size: $0.attributes.size, mode: $0.attributes.mode)
        }
    }

    func seedFakeTree(fileCount: Int) async throws {
        guard let fake = transport as? FakeTransport else { return }
        try await fake.seedSample(fileCount: fileCount)
    }

    // MARK: Mapping

    /// Every SFTP failure classified as network-related becomes serverUnreachable so the
    /// system queues and retries (section 5.1).
    static func mapped(_ error: SFTPError) -> NSError {
        switch error {
        case .noSuchFile:
            return SSHDriveAgentError.noSuchItem.asNSError("No such file.")
        case .permissionDenied:
            return SSHDriveAgentError.permissionDenied.asNSError("Permission denied.")
        case .noConnection, .connectionLost, .deadlineExceeded, .eof:
            return SSHDriveAgentError.serverUnreachable.asNSError("The server is unreachable.")
        case .cancelled:
            // The system cancelled its own `Progress`, so nothing is wrong with the
            // server; anything but a retryable error here would show the user an alert
            // for a transfer they abandoned themselves.
            return SSHDriveAgentError.serverUnreachable.asNSError("The transfer was cancelled.")
        case .operationUnsupported:
            return SSHDriveAgentError.notImplemented.asNSError("The server does not support that.")
        case .badMessage:
            return SSHDriveAgentError.cannotSynchronize.asNSError("Bad message.")
        case let .failure(message):
            // The wire carries no errno: a collision is confirmed with an lstat and a
            // full disk with statvfs, both by the caller (section 6.2).
            return SSHDriveAgentError.cannotSynchronize.asNSError(message)
        }
    }

    /// The writer's own refusals (section 5.5, section 5.7). None of these came off the
    /// wire: each is the answer to a second question the writer asked.
    static func mapped(_ error: RemoteWriteError) -> NSError {
        switch error {
        case let .filenameCollision(name):
            return SSHDriveAgentError.filenameCollision.asNSError(
                "\"\(name)\" already exists on the server.")
        case let .deletionRejected(name):
            return SSHDriveAgentError.deletionRejected.asNSError(
                "\"\(name)\" is not empty. Delete what is inside it first.")
        case .escapingSymlinkTarget:
            return SSHDriveAgentError.permissionDenied.asNSError(
                SymlinkPolicy.escapingTargetMessage)
        }
    }

    static func snapshot(from row: IndexItem) -> SSHDriveItemSnapshot {
        // The conversion lives on IndexItem so the agent and the extension's own reader
        // cannot drift apart (section 5.2).
        row.snapshot
    }
}

extension Double {
    /// Timeline entries are printed as JSON and read by a person; three decimals is
    /// plenty and keeps the output readable.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
