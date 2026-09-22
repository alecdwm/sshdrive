import AgentCore
import Foundation
import Index
import ProviderCore
import SFTP
import XPCProtocols

/// The agent, as the extension sees it, over a **real index database**.
///
/// It is the scripted `AgentChannel` (docs/design/testing.md), and it is deliberately not
/// a mock of the answers: it runs `IndexChangeStream` on a real
/// SQLite file through `IndexWriter`, exactly as `AgentService.enumerateWorkingSetChanges`
/// does on the writer's own connection. The extension's reader reads the same file. So
/// when a scenario says "an index with rows the replica lacks", the rows are real rows and
/// the two sources are the two real sources; the only thing scripted is whether the agent
/// is reachable and what it answers to `indexReady`.
public final class ModelAgent: AgentChannel {
    public let writer: IndexWriter
    public let displayName: String
    private let clock: VirtualClock

    /// What `indexReady` answers: true ready, false not ready, nil the agent could not be
    /// reached at all.
    public var indexReadyAnswer: Bool? = true
    /// A script keyed on the ask's 1-based ordinal, for scenarios that need the answer to
    /// change under the extension.
    public var indexReadyAnswerForAsk: ((Int) -> Bool?)?
    public private(set) var indexReadyAsks = 0

    /// False makes every call fail the way a dead XPC connection does, which is the one
    /// case `.serverUnreachable` is the honest answer to.
    public var isReachable = true

    /// Model seconds an enumeration takes to answer. `A8` sets it to 60 to hold the call
    /// open for the measured `MQ-007` duration.
    public var enumerateItemsDelay: Double = 0
    /// Directory paging: how many rows one page carries.
    public var pageSize = 500

    /// What the agent was asked, in order.
    public private(set) var calls: [String] = []
    /// `workingSetAnchorExpired` is answered by one full sweep of the root set, and this
    /// is the count of them.
    public private(set) var fullSweeps = 0
    public private(set) var anchorExpiryReports: [String] = []

    /// For a scenario that wants to count what happened *after* a point.
    public func resetCalls() { calls.removeAll() }

    public init(writer: IndexWriter, displayName: String, clock: VirtualClock) {
        self.writer = writer
        self.displayName = displayName
        self.clock = clock
    }

    private func view(_ row: IndexItem) -> ItemView {
        ItemView(snapshot: row.snapshot, rootDisplayName: displayName)
    }

    // MARK: Handshake

    public func indexReady(_ completion: @escaping (Bool?) -> Void) {
        indexReadyAsks += 1
        calls.append("indexReady")
        guard isReachable else { return completion(nil) }
        if let script = indexReadyAnswerForAsk {
            return completion(script(indexReadyAsks))
        }
        completion(indexReadyAnswer)
    }

    // MARK: Enumeration

    public func enumerateItems(
        container: ProviderItemIdentifier, pageToken: ProviderPageToken?,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) {
        calls.append("enumerateItems(\(container.rawValue),\(pageToken ?? "first"))")
        let answer: () -> Void = { [self] in
            guard isReachable else { return completion(.failure(.serverUnreachable)) }
            do {
                let rows = try writer.children(ofParent: container.rawValue)
                let offset = Int(pageToken ?? "0") ?? 0
                let slice = Array(rows.dropFirst(offset).prefix(pageSize))
                let next = offset + slice.count < rows.count ? String(offset + slice.count) : nil
                let anchor = try writer.currentSequence()
                completion(
                    .success(
                        ProviderItemPage(
                            items: slice.map(view), nextPageToken: next, anchor: String(anchor))))
            } catch {
                completion(.failure(.serverUnreachable))
            }
        }
        if enumerateItemsDelay > 0 {
            clock.schedule(after: enumerateItemsDelay, answer)
        } else {
            answer()
        }
    }

    public func enumerateChanges(
        container: ProviderItemIdentifier, anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) {
        calls.append("enumerateChanges(\(container.rawValue))")
        guard isReachable else { return completion(.failure(.serverUnreachable)) }
        do {
            let rows = try writer.children(ofParent: container.rawValue)
            let sequence = try writer.currentSequence()
            completion(
                .success(ProviderItemPage(items: rows.map(view), anchor: String(sequence))))
        } catch {
            completion(.failure(.serverUnreachable))
        }
    }

    /// The fallback the working set uses whenever the extension's reader is not usable.
    /// Same query, same expiry rule, same paging as the reader's - that is the point of
    /// `IndexChangeStream` living in `Index` and being run from both sides.
    public func enumerateWorkingSetChanges(
        anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) {
        calls.append("enumerateWorkingSetChanges(\(anchor.rawValue))")
        guard isReachable else { return completion(.failure(.serverUnreachable)) }
        do {
            let page = try writer.changes(since: anchor.sequence)
            var items: [ItemView] = []
            var deleted: [ProviderItemIdentifier] = []
            for entry in page.entries {
                switch entry.kind {
                case .deleted:
                    deleted.append(ProviderItemIdentifier(entry.identifier))
                case .modified:
                    if let row = try writer.item(identifier: entry.identifier) {
                        items.append(view(row))
                    } else {
                        deleted.append(ProviderItemIdentifier(entry.identifier))
                    }
                }
            }
            completion(
                .success(
                    ProviderItemPage(
                        items: items, deletedIdentifiers: deleted,
                        anchor: String(page.newAnchor), moreComing: page.hasMore)))
        } catch IndexError.syncAnchorExpired {
            // It has to cross as the system's own error or the extension would map it to
            // serverUnreachable and the fresh anchor would never be handed out.
            completion(.failure(.syncAnchorExpired))
        } catch {
            completion(.failure(.serverUnreachable))
        }
    }

    public func currentAnchor(_ completion: @escaping (String?) -> Void) {
        calls.append("currentAnchor")
        guard isReachable else { return completion(nil) }
        completion((try? writer.currentSequence()).map(String.init))
    }

    public func item(
        identifier: ProviderItemIdentifier,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("item(\(identifier.rawValue))")
        guard isReachable else { return completion(.failure(.serverUnreachable)) }
        guard let row = try? writer.item(identifier: identifier.rawValue) else {
            return completion(.failure(.noSuchItem))
        }
        completion(.success(view(row)))
    }

    // MARK: Transfers

    /// Model seconds a `fetchContents` is held open. `G8` sets it to the 5 s each of the
    /// 38 measured transfers was held for, which is what makes the batching visible.
    public var fetchDelay: Double = 0
    /// What a fetch of this identifier answers, if anything but the row.
    public var fetchFailures: [String: ProviderFailure] = [:]
    public private(set) var fetchCount: [String: Int] = [:]

    public func fetchContents(
        identifier: ProviderItemIdentifier, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool, into destination: FileHandle,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("fetchContents(\(identifier.rawValue))")
        fetchCount[identifier.rawValue, default: 0] += 1
        let answer: () -> Void = { [self] in
            if let failure = fetchFailures[identifier.rawValue] {
                return completion(.failure(failure))
            }
            item(identifier: identifier, completion)
        }
        if fetchDelay > 0 {
            clock.schedule(after: fetchDelay, answer)
        } else {
            answer()
        }
    }

    public func fetchPartialContents(
        identifier: ProviderItemIdentifier, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("fetchPartialContents(\(identifier.rawValue),\(offset),\(length))")
        item(identifier: identifier, completion)
    }

    // MARK: Mutations

    /// Scripted answers, for the scenarios that are about *which* answer the agent gives.
    /// Returning nil takes the default below, which is a real row written to the real
    /// index.
    public var onCreate: ((ItemTemplate) -> Result<ItemView, ProviderFailure>?)?
    public var onModify:
        ((ProviderItemIdentifier, ProviderItemFields, ItemChanges) -> Result<ItemView, ProviderFailure>?)?

    /// The symlink lexical check (docs/design/symlinks.md), as far as the model needs it:
    /// a target that is absolute-and-outside or climbs out of the share is refused, and
    /// the refusal is a `.cannotSynchronize` that reaches the user only as the item's
    /// `uploadingError` (`MQ-078`).
    public var remoteRoot = "/home/alec"

    public func createItem(
        template: ItemTemplate, contents: FileHandle?, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("createItem(\(template.filename))")
        guard isReachable else { return completion(.failure(.serverUnreachable)) }
        if let scripted = onCreate?(template) { return completion(scripted) }
        if let target = template.symlinkTarget {
            // The shipping check, not a paraphrase of it: the symlink lexical rule as
            // `createItem` applies it. An escaping or absolute target never leaves the
            // Mac, and the refusal is a `.cannotSynchronize` (`MQ-078`).
            let directory =
                (try? RelativePath(string: parentPath(of: template.parentIdentifier.rawValue)))
                ?? .root
            let roots = SymlinkPolicy.Roots(canonical: remoteRoot)
            guard (try? SymlinkPolicy.targetForCreate(target, in: directory, roots: roots)) != nil
            else { return completion(.failure(.cannotSynchronize)) }
        }
        do {
            let parent = template.parentIdentifier.rawValue
            let siblings = try writer.children(ofParent: parent)
            if siblings.contains(where: { $0.filename == template.filename }) {
                return completion(.failure(.filenameCollision))
            }
            let identifier = UUID().uuidString
            let path = try pathBytes(forChild: template.filename, of: parent)
            var row = IndexItem(
                identifier: identifier, path: path, parent: parent,
                type: template.isDirectory ? "directory" : (template.isSymlink ? "symlink" : "file"),
                size: template.isSymlink ? Int64(template.symlinkTarget?.utf8.count ?? 0) : 12,
                mtime: Int64(clock.now()),
                linkTarget: template.symlinkTarget.map { Data($0.utf8) },
                xattrs: LocalAttributes(
                    xattrs: template.extendedAttributes ?? [:], tagData: template.tagData
                ).encoded())
            row.contentVersion = IndexItem.contentVersion(
                size: row.size, mtime: row.mtime, generation: 0)
            RowBuilder.restamp(&row)
            try writer.upsert(row)
            _ = try writer.appendAnchor(identifier: identifier, kind: .modified)
            completion(.success(view(row)))
        } catch {
            completion(.failure(.cannotSynchronize))
        }
    }

    public func modifyItem(
        identifier: ProviderItemIdentifier, baseVersion: String?,
        changedFields: ProviderItemFields, changes: ItemChanges, contents: FileHandle?,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append(
            "modifyItem(\(identifier.rawValue),0x\(String(changedFields.rawValue, radix: 16)))")
        guard isReachable else { return completion(.failure(.serverUnreachable)) }
        if let scripted = onModify?(identifier, changedFields, changes) {
            return completion(scripted)
        }
        do {
            guard var row = try writer.item(identifier: identifier.rawValue) else {
                // The row is gone. `MQ-080`: the system re-offers the edit as a create.
                return completion(.failure(.noSuchItem))
            }
            if changedFields.contains(.filename), let name = changes.newFilename {
                row.path = try pathBytes(forChild: name, of: row.parent ?? IndexWriter.rootIdentifier)
            }
            if changedFields.contains(.contents) {
                row.generation += 1
                row.mtime = Int64(clock.now())
                row.contentVersion = IndexItem.contentVersion(
                    size: row.size, mtime: row.mtime, generation: row.generation)
            }
            if changedFields.contains(.fileSystemFlags), let flags = changes.newFileSystemFlags {
                row.mode = Int64(flags)
            }
            // The tags and the xattrs go into the one local blob, and its hash is what
            // moves the metadata version - which is the only thing that
            // moves it for an *agent-side* change (`MQ-079`).
            if changedFields.contains(.tagData) || changedFields.contains(.extendedAttributes) {
                var local = LocalAttributes.decode(row.xattrs)
                if changedFields.contains(.tagData) { local.tagData = changes.newTagData }
                for (name, value) in changes.newExtendedAttributes ?? [:] {
                    local.xattrs[name] = value
                }
                row.xattrs = local.encoded()
            }
            RowBuilder.restamp(&row)
            try writer.upsert(row)
            _ = try writer.appendAnchor(identifier: row.identifier, kind: .modified)
            completion(.success(view(row)))
        } catch {
            completion(.failure(.cannotSynchronize))
        }
    }

    public func deleteItem(
        identifier: ProviderItemIdentifier, baseVersion: String?, recursive: Bool,
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        calls.append("deleteItem(\(identifier.rawValue))")
        guard isReachable else { return completion(.serverUnreachable) }
        try? writer.delete(identifier: identifier.rawValue)
        completion(nil)
    }

    public func cancelTransfer(transferID: String) {
        calls.append("cancelTransfer")
    }

    private func parentPath(of parent: String) -> String {
        guard parent != IndexWriter.rootIdentifier,
            let row = try? writer.item(identifier: parent)
        else { return "" }
        return String(decoding: row.path, as: UTF8.self)
    }

    private func pathBytes(forChild name: String, of parent: String) throws -> Data {
        guard parent != IndexWriter.rootIdentifier,
            let parentRow = try writer.item(identifier: parent), !parentRow.path.isEmpty
        else { return Data(name.utf8) }
        return parentRow.path + Data("/".utf8) + Data(name.utf8)
    }

    // MARK: Signals

    public func materializedItemsDidChange() {
        calls.append("materializedItemsDidChange")
    }

    /// One report, one full sweep of the root set. `A5` counts both.
    public func workingSetAnchorExpired(freshAnchor: String) {
        calls.append("workingSetAnchorExpired(\(freshAnchor))")
        anchorExpiryReports.append(freshAnchor)
        fullSweeps += 1
    }

    public func performAction(
        actionIdentifier: String, itemIdentifiers: [ProviderItemIdentifier],
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        calls.append("performAction(\(actionIdentifier))")
        completion(nil)
    }

    // MARK: The server's side, for a scenario to drive

    /// A row appearing in the index the way the change detector writes one: an upsert and
    /// an anchor, which is what every caller in the agent does.
    @discardableResult
    public func indexRow(
        identifier: String, name: String, parent: String = IndexWriter.rootIdentifier,
        size: Int64 = 10, mtime: Int64 = 1_700_000_000, isDirectory: Bool = false
    ) throws -> IndexItem {
        var row = IndexItem(
            identifier: identifier,
            path: try pathBytes(forChild: name, of: parent),
            parent: parent,
            type: isDirectory ? "directory" : "file",
            size: isDirectory ? 0 : size,
            mtime: mtime,
            contentVersion: IndexItem.contentVersion(size: size, mtime: mtime, generation: 0))
        // `kept` is derived from the parent row's effective state, which is the whole of
        // "descendants the index has never seen need nothing" (docs/design/pinning.md).
        if let parentRow = try writer.item(identifier: parent), parentRow.kept {
            row.kept = true
        }
        RowBuilder.restamp(&row)
        try writer.upsert(row)
        _ = try writer.appendAnchor(identifier: identifier, kind: .modified)
        return row
    }

    /// A row leaving the index, which is the only thing that removes one.
    public func removeIndexRow(identifier: String) throws {
        try writer.delete(identifier: identifier)
    }

    // MARK: Pins, as the agent writes them

    /// `sshdrive pin`: the marker on the row, `kept` on it and on every known descendant,
    /// a restamped metadata version each, and an anchor each - which is how the change
    /// reaches the system at all, a folder being enumerated once, ever (`MQ-001`).
    public func pin(identifier: String) throws {
        try setPin(identifier: identifier, marker: 1, kept: true)
    }

    /// `sshdrive unpin` on a path inside a pin: an **exclusion**, which is the explicit
    /// `.downloadLazily` that beats an eager ancestor (`MQ-027`, docs/design/pinning.md).
    public func exclude(identifier: String) throws {
        try setPin(identifier: identifier, marker: -1, kept: false)
    }

    /// Removing the pin marker outright (situation B).
    public func unpin(identifier: String) throws {
        try setPin(identifier: identifier, marker: 0, kept: false)
    }

    private func setPin(identifier: String, marker: Int64, kept: Bool) throws {
        guard var row = try writer.item(identifier: identifier) else { return }
        row.pinState = marker
        row.kept = kept
        RowBuilder.restamp(&row)
        try writer.upsert(row)
        _ = try writer.appendAnchor(identifier: identifier, kind: .modified)
        try rewriteDescendants(of: identifier, kept: kept)
    }

    private func rewriteDescendants(of identifier: String, kept: Bool) throws {
        for var child in try writer.children(ofParent: identifier) {
            // An explicit marker of its own is left alone: invariant 2 clears the
            // markers *beneath* a change, and an exclusion under a pin is the one thing
            // that survives the walk in the model's scenarios.
            if child.pinState == -1 { continue }
            child.kept = kept
            RowBuilder.restamp(&child)
            try writer.upsert(child)
            _ = try writer.appendAnchor(identifier: child.identifier, kind: .modified)
            try rewriteDescendants(of: child.identifier, kept: kept)
        }
    }

    // MARK: The conflict copy

    /// What the next `modifyItem` does instead of writing: rename the temp file - which
    /// already holds the local content - to `<name> (conflicted copy from <Mac> <date>)`
    /// beside it, return the **remote** item as current, and leave the caller to evict and
    /// signal.
    ///
    /// Both of those are the agent's, not the system's, and both are needed: `MQ-013` says
    /// the returned version is believed and never re-fetched, so without the eviction the
    /// replica keeps the *local* bytes under the *remote* version for ever; and `MQ-001`
    /// says the new sibling is in a folder the system will never enumerate again, so
    /// without the working-set signal Finder never shows it.
    public func makeConflictCopyOnNextModify(macName: String = "mac", remoteSize: Int64 = 999) {
        onModify = { [weak self] identifier, _, _ in
            guard let self else { return nil }
            self.onModify = nil
            guard var row = try? self.writer.item(identifier: identifier.rawValue) else {
                return .failure(.cannotSynchronize)
            }
            let name = row.filename as NSString
            let ext = name.pathExtension
            let copyName =
                ext.isEmpty
                ? "\(row.filename) (conflicted copy from \(macName))"
                : "\(name.deletingPathExtension) (conflicted copy from \(macName)).\(ext)"
            self.conflictCopyIdentifier = UUID().uuidString
            try? self.indexRow(
                identifier: self.conflictCopyIdentifier!, name: copyName,
                parent: row.parent ?? IndexWriter.rootIdentifier, size: row.size)
            // The remote item as current: a bigger file with a version of its own, which
            // is what the server has and the Mac does not.
            row.size = remoteSize
            row.generation += 1
            row.mtime = Int64(self.clock.now())
            row.contentVersion = IndexItem.contentVersion(
                size: row.size, mtime: row.mtime, generation: row.generation)
            RowBuilder.restamp(&row)
            try? self.writer.upsert(row)
            _ = try? self.writer.appendAnchor(identifier: row.identifier, kind: .modified)
            return .success(self.view(row))
        }
    }

    /// The identifier of the copy the last conflict made, so a scenario can look for it.
    public private(set) var conflictCopyIdentifier: String?
}
