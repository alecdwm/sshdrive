import FileProvider
import Foundation
import XPCProtocols
import Logging

/// A container enumerator: one folder's listing, and the per-folder refresh Finder asks
/// for when it shows the folder (DESIGN.md sections 5.1, 6.5).
///
/// Both calls go to the agent, which lists over the transport and diffs against the
/// index. A container enumerator hands out the index's current sequence number and its
/// `enumerateChanges` never expires it: a folder refresh is a fresh listing diffed
/// against the index, whatever anchor the system holds (section 5.3).
final class ContainerEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let extensionInstance: FileProviderExtension

    init(container: NSFileProviderItemIdentifier, extensionInstance: FileProviderExtension) {
        self.container = container
        self.extensionInstance = extensionInstance
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        let identifier = SSHDriveItemIdentifiers.agentIdentifier(for: container)
        // Section 5.2: directory listings are paged for directories with tens of
        // thousands of entries. The system hands back the page it was given, and the two
        // constants it uses to ask for a first page are not tokens of ours.
        let token = ContainerEnumerator.token(from: page)
        // s3-3 records which of section 6.5's two fallbacks the `viewed` reason gets, and
        // that needs to know whether Finder re-listing a folder arrives as a fresh
        // enumerator or as enumerateChanges on the old one.
        Log.extensionLog.notice(
            "enumerateItems container=\(identifier, privacy: .public) page=\(token ?? "first", privacy: .public)")
        guard let proxy = extensionInstance.agentProxy(observer.finishEnumeratingWithError) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }
        proxy.enumerateItems(
            domainIdentifier: extensionInstance.domainIdentifier,
            containerIdentifier: identifier,
            pageToken: token
        ) { [weak self] page, error in
            guard let self else { return }
            if let error {
                Log.extensionLog.notice(
                    "enumerateItems container=\(identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                observer.finishEnumeratingWithError(AgentConnection.fileProviderError(from: error))
                return
            }
            Log.extensionLog.notice(
                "enumerateItems container=\(identifier, privacy: .public) -> \(page?.items.count ?? 0, privacy: .public) item(s)"
            )
            observer.didEnumerate(
                (page?.items ?? []).map {
                    Item(snapshot: $0, rootDisplayName: self.extensionInstance.displayName)
                })
            observer.finishEnumerating(
                upTo: (page?.nextPageToken).map { NSFileProviderPage(Data($0.utf8)) })
        }
    }

    /// The system's two well-known first-page constants are not tokens of ours; anything
    /// else is a token we handed out.
    static func token(from page: NSFileProviderPage) -> String? {
        if page.rawValue == NSFileProviderPage.initialPageSortedByName as Data { return nil }
        if page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data { return nil }
        let text = String(decoding: page.rawValue, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        let identifier = SSHDriveItemIdentifiers.agentIdentifier(for: container)
        Log.extensionLog.notice(
            "enumerateChanges container=\(identifier, privacy: .public)")
        guard let proxy = extensionInstance.agentProxy(observer.finishEnumeratingWithError) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }
        proxy.enumerateChanges(
            domainIdentifier: extensionInstance.domainIdentifier,
            containerIdentifier: identifier,
            anchor: String(decoding: anchor.rawValue, as: UTF8.self)
        ) { [weak self] page, error in
            guard let self else { return }
            if let error {
                Log.extensionLog.notice(
                    "enumerateChanges container=\(identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                observer.finishEnumeratingWithError(AgentConnection.fileProviderError(from: error))
                return
            }
            Log.extensionLog.notice(
                "enumerateChanges container=\(identifier, privacy: .public) -> \(page?.items.count ?? 0, privacy: .public) changed, \(page?.deletedIdentifiers.count ?? 0, privacy: .public) deleted"
            )
            observer.didUpdate(
                (page?.items ?? []).map {
                    Item(snapshot: $0, rootDisplayName: self.extensionInstance.displayName)
                })
            observer.didDeleteItems(
                withIdentifiers: (page?.deletedIdentifiers ?? []).map {
                    NSFileProviderItemIdentifier($0)
                })
            let anchorValue = page?.anchor ?? "0"
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(Data(anchorValue.utf8)), moreComing: false)
        }
    }

    /// The reader when it can answer, the agent when it cannot. Handing the system a 0
    /// because a readiness round trip has not come back is not free: 0 is an expired
    /// anchor as soon as the oldest surviving row is past it.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        extensionInstance.currentAnchor { anchor in
            completionHandler(NSFileProviderSyncAnchor(Data(anchor.utf8)))
        }
    }
}

/// The working set: only ever a change stream, never a listing (DESIGN.md section 5.3).
///
/// The extension answers this from the index itself where it can, which is what keeps it
/// working while the agent is restarting (section 5.2) - but where it cannot, it asks the
/// agent rather than failing. `.serverUnreachable` here is not cheap: fileproviderd
/// throttles a change enumeration that keeps returning it, and 27 consecutive failures on
/// one real domain took the event stream out to a 47-minute retry, after which no
/// server-side change reached Finder at all (2026-09-08). So it is reserved for an agent
/// that genuinely cannot be reached, which is the one case where there is nothing to say.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let extensionInstance: FileProviderExtension

    init(extensionInstance: FileProviderExtension) {
        self.extensionInstance = extensionInstance
    }

    func invalidate() {}

    /// Returns no items and the current sequence number as the anchor.
    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        Log.extensionLog.notice("workingSet enumerateItems -> 0 items")
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        let anchorValue = Int64(String(decoding: anchor.rawValue, as: UTF8.self)) ?? 0
        let readerState = extensionInstance.readerStore.stateName
        Log.extensionLog.notice(
            "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) reader=\(readerState, privacy: .public)"
        )
        do {
            guard let result = try extensionInstance.readerStore.changes(since: anchorValue) else {
                // The reader is not usable: the `indexReady` round trip has not come back,
                // the agent answered no, the schema is newer than this build understands,
                // or the file could not be opened. None of those is a reason to fail the
                // enumeration - the agent has the same rows and can answer over XPC, and
                // an error here is what fileproviderd throttles on.
                //
                // What must never happen is an empty change set at the anchor the system
                // already holds: that tells it that it is up to date and the change is
                // dropped until something else signals, which for a deletion means a file
                // gone from both the server and the index sitting in Finder indefinitely
                // (measured on a real mount, 2026-09-04).
                askAgent(anchor: anchorValue, readerState: readerState, observer: observer)
                return
            }
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> \(result.items.count, privacy: .public) changed, \(result.deleted.count, privacy: .public) deleted, newAnchor=\(result.newAnchor, privacy: .public), moreComing=\(result.hasMore, privacy: .public), source=reader"
            )
            extensionInstance.noteWorkingSetSucceeded()
            observer.didUpdate(
                result.items.map {
                    Item(snapshot: $0, rootDisplayName: extensionInstance.displayName)
                })
            observer.didDeleteItems(
                withIdentifiers: result.deleted.map { NSFileProviderItemIdentifier($0) })
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(Data(String(result.newAnchor).utf8)),
                moreComing: result.hasMore)
        } catch let error as NSError
            where error.domain == NSFileProviderErrorDomain
                && error.code == NSFileProviderError.syncAnchorExpired.rawValue
        {
            // The reader hands out a fresh anchor and tells the agent so, one call per
            // expiry; the agent's response is one full sweep of the root set (section 5.3).
            let fresh = extensionInstance.readerStore.currentSequence() ?? 0
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> syncAnchorExpired, fresh=\(fresh, privacy: .public)"
            )
            extensionInstance.reportAnchorExpired(freshAnchor: String(fresh))
            extensionInstance.noteWorkingSetFailed()
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        } catch {
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> error \(String(describing: error), privacy: .public)"
            )
            extensionInstance.noteWorkingSetFailed()
            observer.finishEnumeratingWithError(error)
        }
    }

    /// The XPC half of the same change stream. The agent runs the identical query on the
    /// writer's connection (`IndexChangeStream`), so the two answers cannot drift.
    private func askAgent(
        anchor: Int64, readerState: String, observer: NSFileProviderChangeObserver
    ) {
        guard let proxy = extensionInstance.agentProxy({ [weak self] error in
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchor, privacy: .public) reader=\(readerState, privacy: .public) -> serverUnreachable (the agent is not reachable)"
            )
            self?.extensionInstance.noteWorkingSetFailed()
            observer.finishEnumeratingWithError(error)
        }) else {
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchor, privacy: .public) reader=\(readerState, privacy: .public) -> serverUnreachable (no agent connection)"
            )
            extensionInstance.noteWorkingSetFailed()
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }
        proxy.enumerateWorkingSetChanges(
            domainIdentifier: extensionInstance.domainIdentifier, anchor: String(anchor)
        ) { [weak self] page, error in
            guard let self else { return }
            if let error {
                let mapped = AgentConnection.fileProviderError(from: error) as NSError
                if mapped.domain == NSFileProviderErrorDomain
                    && mapped.code == NSFileProviderError.syncAnchorExpired.rawValue
                {
                    Log.extensionLog.notice(
                        "workingSet enumerateChanges anchor=\(anchor, privacy: .public) -> syncAnchorExpired, source=agent"
                    )
                    self.extensionInstance.reportAnchorExpired(freshAnchor: String(anchor))
                }
                Log.extensionLog.notice(
                    "workingSet enumerateChanges anchor=\(anchor, privacy: .public) reader=\(readerState, privacy: .public) -> \(String(describing: error), privacy: .public), source=agent"
                )
                self.extensionInstance.noteWorkingSetFailed()
                observer.finishEnumeratingWithError(mapped)
                return
            }
            let items = page?.items ?? []
            let deleted = page?.deletedIdentifiers ?? []
            let newAnchor = page?.anchor ?? String(anchor)
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchor, privacy: .public) reader=\(readerState, privacy: .public) -> \(items.count, privacy: .public) changed, \(deleted.count, privacy: .public) deleted, newAnchor=\(newAnchor, privacy: .public), moreComing=\(page?.moreComing ?? false, privacy: .public), source=agent"
            )
            self.extensionInstance.noteWorkingSetSucceeded()
            observer.didUpdate(
                items.map {
                    Item(snapshot: $0, rootDisplayName: self.extensionInstance.displayName)
                })
            observer.didDeleteItems(
                withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) })
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(Data(newAnchor.utf8)),
                moreComing: page?.moreComing ?? false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        extensionInstance.currentAnchor { anchor in
            completionHandler(NSFileProviderSyncAnchor(Data(anchor.utf8)))
        }
    }
}
