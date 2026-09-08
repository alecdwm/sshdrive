import Foundation
import Index
import ProviderCore

/// The agent, as the extension sees it, over a **real index database**.
///
/// It is the scripted `AgentChannel` of `docs/testing-architecture.md` section 2.2, and it
/// is deliberately not a mock of the answers: it runs `IndexChangeStream` on a real
/// SQLite file through `IndexWriter`, exactly as `AgentService.enumerateWorkingSetChanges`
/// does on the writer's own connection. The extension's reader reads the same file. So
/// when a scenario says "an index with rows the replica lacks", the rows are real rows and
/// the two sources are the two real sources; the only thing scripted is whether the agent
/// is reachable and what it answers to `indexReady`.
///
/// Step 8 replaces this with an in-process loopback onto `AgentRuntime`; until then it is
/// the half of the mount the model owns.
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
    /// Directory paging: how many rows one page carries (section 5.2).
    public var pageSize = 500

    /// What the agent was asked, in order.
    public private(set) var calls: [String] = []
    /// `workingSetAnchorExpired` is answered by one full sweep of the root set
    /// (section 5.3), and this is the count of them.
    public private(set) var fullSweeps = 0
    public private(set) var anchorExpiryReports: [String] = []

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
            // serverUnreachable and the fresh anchor would never be handed out
            // (section 5.3).
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

    // MARK: Transfers and mutations - not exercised by suite A

    public func fetchContents(
        identifier: ProviderItemIdentifier, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool, into destination: FileHandle,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("fetchContents(\(identifier.rawValue))")
        item(identifier: identifier, completion)
    }

    public func fetchPartialContents(
        identifier: ProviderItemIdentifier, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("fetchPartialContents(\(identifier.rawValue),\(offset),\(length))")
        item(identifier: identifier, completion)
    }

    public func createItem(
        template: ItemTemplate, contents: FileHandle?, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("createItem(\(template.filename))")
        completion(.failure(.cannotSynchronize))
    }

    public func modifyItem(
        identifier: ProviderItemIdentifier, baseVersion: String?,
        changedFields: ProviderItemFields, changes: ItemChanges, contents: FileHandle?,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        calls.append("modifyItem(\(identifier.rawValue),0x\(String(changedFields.rawValue, radix: 16)))")
        item(identifier: identifier, completion)
    }

    public func deleteItem(
        identifier: ProviderItemIdentifier, baseVersion: String?, recursive: Bool,
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        calls.append("deleteItem(\(identifier.rawValue))")
        completion(nil)
    }

    public func cancelTransfer(transferID: String) {
        calls.append("cancelTransfer")
    }

    // MARK: Signals

    public func materializedItemsDidChange() {
        calls.append("materializedItemsDidChange")
    }

    /// One report, one full sweep of the root set (section 5.3). `A5` counts both.
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
    /// an anchor, which is what every caller in the agent does (section 5.3).
    @discardableResult
    public func indexRow(
        identifier: String, name: String, parent: String = IndexWriter.rootIdentifier,
        size: Int64 = 10, mtime: Int64 = 1_700_000_000
    ) throws -> IndexItem {
        let row = IndexItem(
            identifier: identifier,
            path: Data(name.utf8),
            parent: parent,
            type: "file",
            size: size,
            mtime: mtime,
            contentVersion: IndexItem.contentVersion(size: size, mtime: mtime, generation: 0))
        try writer.upsert(row)
        _ = try writer.appendAnchor(identifier: identifier, kind: .modified)
        return row
    }

    /// A row leaving the index, which is the only thing that removes one (section 5.3).
    public func removeIndexRow(identifier: String) throws {
        try writer.delete(identifier: identifier)
    }
}
