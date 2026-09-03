import Foundation
import FileProvider
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

    /// Transfers in flight, by transfer id, so `cancelTransfer` can reach them
    /// (section 5.2). Milestone 1 transfers are memory copies and finish at once; the
    /// table exists so the cancel path is wired from the start.
    private var cancelledTransfers: Set<String> = []

    init(location: Location, transport: any SFTPTransport, indexURL: URL, backupURL: URL) throws {
        self.location = location
        self.transport = transport
        self.indexURL = indexURL
        self.backupURL = backupURL
        self.index = try IndexWriter(path: indexURL.path)
        self.identity = .unknown
    }

    func start() async throws {
        if let fake = transport as? FakeTransport {
            identity = ServerIdentity(
                uid: await fake.serverUID, gid: await fake.serverGID, supplementaryGroups: [])
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

    /// readdir the mapped path, reconcile with the index, return items (section 5.1).
    /// Records the folder as recently viewed (section 6.5).
    func enumerateItems(container identifier: String) async throws -> [SSHDriveItemSnapshot] {
        guard let containerRow = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(containerRow.path)
        try index.addRoot(path: path.bytes, reason: "viewed")
        return try await reconcile(directory: path, containerRow: containerRow).items
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
        let entries: [SFTPDirectoryEntry]
        do {
            entries = try await transport.readdir(directory)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        }

        var result = ReconcileResult()
        var seenPaths: Set<Data> = []

        // Case and normalisation collisions (section 5.4) are milestone 3; milestone 1
        // hides nothing and records the reason it would have.
        for entry in entries {
            guard entry.attributes.type != .other else { continue }
            guard let name = String(data: entry.name, encoding: .utf8), !name.isEmpty else {
                // Names that are not valid UTF-8 are hidden the same way collisions are.
                continue
            }
            guard let childPath = try? directory.appending(component: entry.name) else { continue }
            seenPaths.insert(childPath.bytes)

            let existing = try index.item(path: childPath.bytes)
            let row = try makeRow(
                path: childPath,
                attributes: entry.attributes,
                parent: containerRow,
                existing: existing)
            try index.upsert(row)

            let snapshot = LocationRuntime.snapshot(from: row)
            result.items.append(snapshot)
            if existing == nil || existing?.metadataVersion != row.metadataVersion {
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

        return result
    }

    /// Builds a finished row: every derived field computed here, none in the extension
    /// (section 5.2).
    private func makeRow(
        path: RelativePath,
        attributes: SFTPFileAttributes,
        parent: IndexItem,
        existing: IndexItem?
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
            hidden: existing?.hidden ?? 0,
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
    /// (section 5.2). The agent lstats before and after; if size or mtime moved in
    /// between, the file changed under the transfer.
    func fetchContents(
        identifier: String, into handle: FileHandle, transferID: String
    ) async throws -> SSHDriveItemSnapshot {
        guard let row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        let path = try RelativePath.fromIndexBytes(row.path)

        do {
            let before = try await transport.lstat(path)
            let bytes = try await transport.read(path, offset: 0, length: nil)
            guard !cancelledTransfers.contains(transferID) else {
                cancelledTransfers.remove(transferID)
                throw SSHDriveAgentError.serverUnreachable.asNSError("Transfer cancelled.")
            }
            let after = try await transport.lstat(path)
            // TODO milestone 3: retry once, then fail as serverUnreachable, when size or
            // mtime moved under the transfer (section 5.1). Milestone 1's fetch is a
            // memory copy and cannot be torn.
            if before.size != after.size || before.mtime != after.mtime {
                Log.agent.notice("file moved under a fetch: \(path.description, privacy: .public)")
            }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: bytes)
            try handle.synchronize()

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
        }
    }

    func cancel(transferID: String) {
        cancelledTransfers.insert(transferID)
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
        contents: FileHandle?
    ) async throws -> SSHDriveItemSnapshot {
        let parentRow = try index.item(identifier: parentIdentifier) ?? index.ensureRoot()
        let parentPath = try RelativePath.fromIndexBytes(parentRow.path)
        // Filenames arriving from the system pass through the RelativePath constructor
        // before anything else sees them (section 9.1).
        let path = try parentPath.appending(component: filename)

        do {
            if isDirectory {
                try await transport.mkdir(path, mode: 0o755)
            } else if let symlinkTarget {
                // TODO milestone 4: refuse a target that escapes the root (section 5.7).
                try await transport.symlink(target: symlinkTarget, at: path)
            } else {
                let data = contents.map { $0.readDataToEndOfFile() } ?? Data()
                try await transport.write(path, contents: data, mode: 0o644)
            }
            let attributes = try await transport.lstat(path)
            let row = try makeRow(
                path: path, attributes: attributes, parent: parentRow, existing: nil)
            try index.upsert(row)
            try index.appendAnchor(identifier: row.identifier, kind: .modified)
            return LocationRuntime.snapshot(from: row)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        }
    }

    /// Rename/move, content, attributes, extended attributes (section 5.1).
    func modifyItem(
        identifier: String,
        changedFields: NSFileProviderItemFields,
        newParentIdentifier: String?,
        newFilename: String?,
        newExtendedAttributes: [String: Data]?,
        contents: FileHandle?
    ) async throws -> SSHDriveItemSnapshot {
        guard var row = try index.item(identifier: identifier) else {
            throw SSHDriveAgentError.noSuchItem.asNSError("No row for \(identifier).")
        }
        var path = try RelativePath.fromIndexBytes(row.path)

        do {
            if changedFields.contains(.parentItemIdentifier) || changedFields.contains(.filename) {
                let parentRow =
                    try index.item(identifier: newParentIdentifier ?? row.parent ?? "")
                    ?? index.ensureRoot()
                let parentPath = try RelativePath.fromIndexBytes(parentRow.path)
                let name = newFilename ?? row.filename
                let destination = try parentPath.appending(component: name)
                // A plain, non-overwriting rename (section 5.5).
                try await transport.rename(path, to: destination)
                try index.rewritePaths(from: path.bytes, to: destination.bytes)
                row.parent = parentRow.identifier
                try index.upsert(row)
                path = destination
            }

            if changedFields.contains(.contents), let contents {
                let data = contents.readDataToEndOfFile()
                // TODO milestone 4: the conflict check compares size, mtime and
                // generation before the write, and a conflict copy is named after this
                // Mac (section 5.5).
                try await transport.write(path, contents: data, mode: UInt32(row.mode ?? 0o644))
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
            return LocationRuntime.snapshot(from: updated)
        } catch let error as SFTPError {
            throw LocationRuntime.mapped(error)
        }
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
    func setPinState(pathString: String, marker: Int64) async throws {
        let path = try RelativePath(string: pathString)
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
