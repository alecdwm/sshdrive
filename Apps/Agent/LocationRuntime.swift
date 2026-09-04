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
    private let index: IndexWriter
    private let transport: any SFTPTransport
    private let indexURL: URL
    private let backupURL: URL

    /// The identity the capability probe found. Milestone 3 runs the probe; the fake
    /// backend reports its own uid and gid so the derivation in section 5.4 has
    /// something real to work from from milestone 1 on.
    private var identity: ServerIdentity

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
    private var hiddenReasons: [Data: String] = [:]

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

    /// The last transport error, for `show` and `status` (section 8).
    private var lastTransportError: String?

    private var concurrentFetches = 0
    private var peakConcurrentFetches = 0
    private var totalFetches = 0
    /// One entry per fetch: start, end (0 while running) and the path, as seconds since
    /// the reference date, so S6 can see the overlap rather than infer it from a peak.
    private var fetchTimeline: [(path: String, start: Double, end: Double)] = []

    init(location: Location, transport: any SFTPTransport, indexURL: URL, backupURL: URL) throws {
        self.location = location
        self.transport = transport
        self.indexURL = indexURL
        self.backupURL = backupURL
        self.index = try IndexWriter(path: indexURL.path)
        self.identity = .unknown
        self.scheduler = TransferScheduler(locationID: location.id)
    }

    func start() async throws {
        if let fake = transport as? FakeTransport {
            identity = ServerIdentity(
                uid: await fake.serverUID, gid: await fake.serverGID, supplementaryGroups: [])
        }
        if let ssh = transport as? SSHBackedTransport {
            // Section 5.4: the identity comes from one `id` exec channel at connect, and
            // an SFTP-only account - no shell, or no channel to spare for one - keeps
            // `.unknown`, which is what gives every item full capabilities.
            identity = ssh.probe.identity
            channelBudget = ssh.budget
            await scheduler.setSharesMetadataChannel(ssh.transfersShareMetadataChannel)
        }
        // An agent that starts and finds `reconciling` set redoes the walk before serving
        // anything (section 5.3). Milestone 1 has no reconcile walk to redo, so it clears
        // the flag and says so; milestone 5 replaces this with the walk itself.
        if index.isReconciling {
            Log.agent.error(
                "index for \(self.location.id, privacy: .public) was left reconciling; the reconcile walk is milestone 5, clearing the flag")
            try index.setReconciling(false)
        }
        let rootAttributes = try await transport.lstat(.root)
        try index.ensureRoot(
            mode: Int64(rootAttributes.mode),
            uid: Int64(rootAttributes.uid),
            gid: Int64(rootAttributes.gid))
        try refreshRootRow(rootAttributes)
    }

    /// The canonical root the transport resolved, for the debug hooks and, in
    /// milestone 3, for `sshdrive show`.
    func rootDescription() async throws -> String {
        try await transport.realpath(.root)
    }

    /// `-O exit` on the master and the SFTP channel with it, for a location that is
    /// being unmounted or removed. A fake-backed location has nothing to shut down.
    func shutdownTransport() async {
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
        guard let containerRow = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(containerRow.path)
        let result = try await reconcile(directory: path, containerRow: containerRow)
        return (result.changed, result.deleted)
    }

    private struct ReconcileResult {
        var items: [SSHDriveItemSnapshot] = []
        var changed: [SSHDriveItemSnapshot] = []
        var deleted: [String] = []
    }

    /// One listing, diffed against the index. Every difference becomes a row change and
    /// an anchor, so the working set carries it to the system whatever else happens
    /// (section 5.3).
    private func reconcile(directory: RelativePath, containerRow: IndexItem) async throws
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

            if classifiedEntry.hidden == 0 {
                hiddenReasons.removeValue(forKey: childPath.bytes)
            } else {
                hiddenReasons[childPath.bytes] = classifiedEntry.reason
            }

            let existing = try index.item(path: childPath.bytes)
            let row = try makeRow(
                path: childPath,
                attributes: entry.attributes,
                parent: containerRow,
                existing: existing,
                hidden: classifiedEntry.hidden)
            try index.upsert(row)

            // A hidden row holds its name and nothing else: it is never enumerated, and a
            // create or rename onto it fails `.filenameCollision` (section 5.4).
            guard classifiedEntry.hidden == 0 else {
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

        // Deleted rows are deleted: no tombstones (section 5.3).
        for child in try index.children(ofParent: containerRow.identifier)
        where !seenPaths.contains(child.path) {
            try index.delete(identifier: child.identifier)
            result.deleted.append(child.identifier)
        }
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

    /// Builds a finished row: every derived field computed here, none in the extension
    /// (section 5.2).
    private func makeRow(
        path: RelativePath,
        attributes: SFTPFileAttributes,
        parent: IndexItem,
        existing: IndexItem?,
        hidden: Int64? = nil
    ) throws -> IndexItem {
        // ns-mtime and inode feed change detection only. When either differs from the
        // stored value while size and second-mtime do not, the generation is bumped,
        // which changes the version and makes the system re-fetch (section 5.3).
        var generation = existing?.generation ?? 0
        if let existing,
            existing.size == attributes.size,
            existing.mtime == attributes.mtime
        {
            let nanosecondsMoved =
                existing.mtimeNanoseconds != nil && attributes.mtimeNanoseconds != nil
                && existing.mtimeNanoseconds != attributes.mtimeNanoseconds
            let inodeMoved =
                existing.inode != nil && attributes.inode != nil
                && existing.inode != Int64(bitPattern: attributes.inode ?? 0)
            if nanosecondsMoved || inodeMoved { generation += 1 }
        }

        let contentVersion = IndexItem.contentVersion(
            size: attributes.size, mtime: attributes.mtime, generation: generation)

        // The effective kept state is derived by the agent from the markers at and above
        // the path (sections 5.2, 7.1.1). Pinning is milestone 8; until then the marker
        // on the row is the whole answer and nothing inherits.
        let pinState = existing?.pinState ?? 0
        let kept = pinState == 1

        let capabilities = ItemDerivation.capabilities(
            type: attributes.type,
            mode: attributes.mode,
            uid: attributes.uid,
            gid: attributes.gid,
            parentMode: UInt32(parent.mode ?? 0o755),
            parentUID: UInt32(parent.uid ?? 0),
            parentGID: UInt32(parent.gid ?? 0),
            permissions: location.permissions,
            identity: identity,
            kept: kept)

        let filename = String(decoding: path.lastComponent ?? Data(), as: UTF8.self)
        let flags = ItemDerivation.fileSystemFlags(
            type: attributes.type,
            mode: attributes.mode,
            uid: attributes.uid,
            gid: attributes.gid,
            permissions: location.permissions,
            identity: identity,
            capabilities: capabilities,
            filename: filename)

        let xattrs = existing?.xattrs
        let metadataVersion = ItemDerivation.metadataVersion(
            contentVersion: contentVersion,
            mode: Int64(attributes.mode),
            uid: Int64(attributes.uid),
            gid: Int64(attributes.gid),
            capabilities: Int64(capabilities.rawValue),
            fileSystemFlags: Int64(flags.rawValue),
            kept: kept,
            xattrs: xattrs)

        return IndexItem(
            identifier: existing?.identifier ?? UUID().uuidString,
            path: path.bytes,
            parent: parent.identifier,
            type: attributes.type.rawValue,
            size: attributes.size,
            mtime: attributes.mtime,
            mtimeNanoseconds: attributes.mtimeNanoseconds,
            inode: attributes.inode.map { Int64(bitPattern: $0) },
            uid: Int64(attributes.uid),
            gid: Int64(attributes.gid),
            mode: Int64(attributes.mode),
            generation: generation,
            contentVersion: contentVersion,
            metadataVersion: metadataVersion,
            lastFetch: existing?.lastFetch,
            pinState: pinState,
            kept: kept,
            capabilities: Int64(capabilities.rawValue),
            fileSystemFlags: Int64(flags.rawValue),
            linkTarget: attributes.symlinkTarget.map { Data($0.utf8) },
            hidden: hidden ?? existing?.hidden ?? 0,
            xattrs: xattrs,
            localContent: existing?.localContent)
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
        guard let row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(row.path)

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

    /// mkdir, symlink, or upload-to-temp plus a non-overwriting rename into place
    /// (section 5.1). The temp-file dance itself is milestone 4; milestone 1 writes
    /// straight through the fake transport, which refuses to overwrite exactly as a plain
    /// SFTP rename does.
    func createItem(
        parentIdentifier: String,
        filename: String,
        isDirectory: Bool,
        symlinkTarget: String?,
        contents: FileHandle?,
        transferID: String = UUID().uuidString,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SSHDriveItemSnapshot {
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

        let transport = self.transport
        do {
            if isDirectory {
                try await transport.mkdir(path, mode: 0o755)
            } else if let symlinkTarget {
                // TODO milestone 4: refuse a target that escapes the root (section 5.7).
                try await transport.symlink(target: symlinkTarget, at: path)
            } else if let contents {
                // Section 6.2: every `createItem` and `modifyItem` upload is a foreground
                // transfer, and runs on the bulk channel under the scheduler.
                let source = HandleSource(handle: contents)
                try await scheduler.run(transferID: transferID, kind: .foreground) { window in
                    try await transport.writeStreaming(
                        path, mode: 0o644, window: window, source: { try source.next() }
                    ) { written in progress(written, max(written, 1)) }
                }
            } else {
                try await transport.write(path, contents: Data(), mode: 0o644)
            }
            let attributes = try await transport.lstat(path)
            let row = try makeRow(
                path: path, attributes: attributes, parent: parentRow, existing: nil)
            try index.upsert(row)
            try index.appendAnchor(identifier: row.identifier, kind: .modified)
            return LocationRuntime.snapshot(from: row)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }
    }

    /// Rename/move, content, attributes, extended attributes (section 5.1).
    func modifyItem(
        identifier: String,
        changedFields: NSFileProviderItemFields,
        newParentIdentifier: String?,
        newFilename: String?,
        newExtendedAttributes: [String: Data]?,
        contents: FileHandle?,
        transferID: String = UUID().uuidString,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> SSHDriveItemSnapshot {
        try failWritesIfFaulted()
        guard var row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        var path = try RelativePath.fromIndexBytes(row.path)
        Log.agent.notice(
            """
            modifyItem \(path.description, privacy: .public)             changedFields=0x\(String(changedFields.rawValue, radix: 16), privacy: .public)             xattrKeys=\(newExtendedAttributes?.keys.sorted().joined(separator: ",") ?? "-", privacy: .public)
            """)

        do {
            if changedFields.contains(.parentItemIdentifier) || changedFields.contains(.filename) {
                let parentRow =
                    try index.item(identifier: newParentIdentifier ?? row.parent ?? "")
                    ?? index.ensureRoot()
                let parentPath = try RelativePath.fromIndexBytes(parentRow.path)
                let name = newFilename ?? row.filename
                let destination = try parentPath.appending(component: name)
                try refuseHiddenName(at: destination)
                // A plain, non-overwriting rename (section 5.5).
                try await transport.rename(path, to: destination)
                try index.rewritePaths(from: path.bytes, to: destination.bytes)
                row.parent = parentRow.identifier
                try index.upsert(row)
                path = destination
            }

            if changedFields.contains(.contents), let contents {
                // TODO milestone 4: the conflict check compares size, mtime and
                // generation before the write, and a conflict copy is named after this
                // Mac (section 5.5).
                let transport = self.transport
                let mode = UInt32(row.mode ?? 0o644)
                let uploadPath = path
                let source = HandleSource(handle: contents)
                try await scheduler.run(transferID: transferID, kind: .foreground) { window in
                    try await transport.writeStreaming(
                        uploadPath, mode: mode, window: window, source: { try source.next() }
                    ) { written in progress(written, max(written, 1)) }
                }
            }

            if changedFields.contains(.extendedAttributes), let newExtendedAttributes {
                // Extended attributes stay local (section 5.4), so this only touches the
                // row, and the xattr hash in the metadata version is what stops the
                // system re-offering the change (S10).
                row.xattrs = try? JSONEncoder().encode(newExtendedAttributes)
            }

            let attributes = try await transport.lstat(path)
            let parentRow =
                try index.item(identifier: row.parent ?? IndexWriter.rootIdentifier)
                ?? index.ensureRoot()
            var updated = try makeRow(
                path: path, attributes: attributes, parent: parentRow, existing: row)
            updated.xattrs = row.xattrs
            updated.metadataVersion = ItemDerivation.metadataVersion(
                contentVersion: updated.contentVersion,
                mode: updated.mode, uid: updated.uid, gid: updated.gid,
                capabilities: updated.capabilities, fileSystemFlags: updated.fileSystemFlags,
                kept: updated.kept, xattrs: updated.xattrs)
            try index.upsert(updated)
            try index.appendAnchor(identifier: updated.identifier, kind: .modified)
            if versionMismatch {
                var lying = updated
                lying.contentVersion = updated.contentVersion + "-fault"
                lying.metadataVersion = updated.metadataVersion + "-fault"
                Log.agent.notice(
                    "debug fault --version-mismatch: replying with \(lying.contentVersion, privacy: .public) instead of \(updated.contentVersion, privacy: .public)"
                )
                return LocationRuntime.snapshot(from: lying)
            }
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
                    ?? (row.hidden == 3
                        ? "kept on this Mac only" : "a name macOS cannot tell from another here")
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
        guard let ssh = transport as? SSHBackedTransport else { return nil }
        return (ssh.probe, await ssh.extensions)
    }

    /// `status --probe`: "re-runs the server probe instead of using the cached result"
    /// (section 8). The channel budget's own cache is left alone - that is what
    /// `debug transport reprobe` invalidates, and section 6.1 gives it different rules.
    func reprobeServer() async {
        guard let ssh = transport as? SSHBackedTransport else { return }
        let probe = await ServerProbe.run(master: ssh.master)
        CapabilityCache.storeProbe(
            probe, extensions: await ssh.extensions, locationID: location.id)
        if probe.identity.isKnown, location.permissions == .mode { identity = probe.identity }
    }

    /// `-O check` on our own child. False for a location whose master has gone, which is
    /// what `list` and `status` print as "offline".
    func isConnected() async -> Bool {
        guard let ssh = transport as? SSHBackedTransport else { return true }
        return await ssh.isMasterAlive()
    }

    /// The last error this location saw, for `show` and `status`'s "last error" line, and
    /// the input to section 4.3's `ssh-keygen -R` advice.
    ///
    /// `ssh`'s own stderr comes first when there is any: a changed host key, a refused
    /// password and a dead key agent are all reported there and nowhere else, and the
    /// classifier has already read it (section 6.1).
    func lastErrorText() async -> String? {
        if let ssh = transport as? SSHBackedTransport {
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
        guard transport is SSHBackedTransport else { return nil }
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
        guard let ssh = transport as? SSHBackedTransport else { return nil }
        return [
            "known": ssh.probe.identity.isKnown,
            "description": ssh.probe.description,
            "failure": ssh.probe.failure,
            "shellPrefix": ssh.probe.shellPrefix,
            "permissionsSetting": location.permissions.rawValue,
        ]
    }

    func deleteItem(identifier: String, recursive: Bool) async throws {
        guard let row = try index.item(identifier: identifier) else { return }
        let path = try RelativePath.fromIndexBytes(row.path)
        do {
            if row.type == "directory" {
                if recursive {
                    try await removeRecursively(path)
                } else {
                    try await transport.rmdir(path)
                }
            } else {
                try await transport.remove(path)
            }
            try index.delete(identifier: identifier)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        } catch is CancellationError {
            // The transfer's own Task was cancelled (section 5.2). Reported as the
            // transport's `.cancelled` rather than Swift's error, so the extension maps
            // it like any other.
            throw LocationRuntime.mapped(.cancelled)
        }
    }

    /// Recursive operations walk the server with readdir and re-lstat each directory
    /// before descending, so a directory replaced by a symlink after it was enumerated is
    /// noticed before anything is done inside it (section 9.1).
    private func removeRecursively(_ path: RelativePath) async throws {
        let attributes = try await transport.lstat(path)
        guard attributes.type == .directory else {
            try await transport.remove(path)
            return
        }
        for entry in try await transport.readdir(path) {
            let child = try path.appending(component: entry.name)
            if entry.attributes.type == .directory {
                try await removeRecursively(child)
            } else {
                try await transport.remove(child)
            }
        }
        try await transport.rmdir(path)
    }

    // MARK: Signals and maintenance

    func currentSequence() throws -> Int64 { try index.currentSequence() }

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

    /// The debug hook behind `sshdrive debug policy` (section 12, spike S6). Milestone 8
    /// replaces it with `pin`/`unpin`, which write the same marker.
    @discardableResult
    func setPinState(pathString: String, marker: Int64) async throws -> [String: Any] {
        let path = try RelativePath(string: pathString)
        // Step 1 of section 7.1: a path the system has never enumerated has no chain of
        // ancestors, and the system cannot apply a policy to an item whose ancestors it
        // has never seen. So readdir each missing ancestor into the index from the
        // nearest known one first; every new row gets an anchor and travels through the
        // working set with the pinned one.
        let createdAncestors = try await materializeAncestors(of: path)
        guard var row = try index.item(path: path.bytes) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(pathString).")
        }
        row.pinState = marker
        row.kept = marker == 1
        // A pin change rewrites every known descendant and writes an anchor for each
        // (section 7.1). The recursive half is milestone 8; this writes the marker's own
        // row so S6 can flip one folder's policy at runtime.
        row.capabilities =
            row.kept
            ? row.capabilities & ~Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)
            : row.capabilities | Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue)
        row.metadataVersion = ItemDerivation.metadataVersion(
            contentVersion: row.contentVersion,
            mode: row.mode, uid: row.uid, gid: row.gid,
            capabilities: row.capabilities, fileSystemFlags: row.fileSystemFlags,
            kept: row.kept, xattrs: row.xattrs)
        try index.upsert(row)
        try index.appendAnchor(identifier: row.identifier, kind: .modified)
        if marker == 1 {
            try index.addRoot(path: path.bytes, reason: "pinned")
        } else {
            try index.removeRoot(path: path.bytes, reason: "pinned")
        }
        return [
            "identifier": row.identifier,
            "kept": row.kept,
            "capabilities": row.capabilities,
            "metadataVersion": row.metadataVersion,
            "ancestorRowsCreated": createdAncestors,
        ]
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
        collisions: Bool?
    ) {
        if let writes { writesFail = writes }
        if let delay { fetchDelayMilliseconds = delay }
        if let mismatch { versionMismatch = mismatch }
        if let collisions { createsCollide = collisions }
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
