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
                observer.finishEnumeratingWithError(AgentConnection.fileProviderError(from: error))
                return
            }
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
                observer.finishEnumeratingWithError(AgentConnection.fileProviderError(from: error))
                return
            }
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

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(
            NSFileProviderSyncAnchor(Data(String(extensionInstance.currentSequence()).utf8)))
    }
}

/// The working set: only ever a change stream, never a listing (DESIGN.md section 5.3).
///
/// This is the one enumerator the extension answers itself, from the index, with no agent
/// involved, which also means it keeps working while the agent is restarting (section 5.2).
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
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        let anchorValue = Int64(String(decoding: anchor.rawValue, as: UTF8.self)) ?? 0
        do {
            guard let result = try extensionInstance.readerStore.changes(since: anchorValue) else {
                // No reader yet - the `indexReady` round trip of section 5.3 has not come
                // back, or the schema is newer than this build understands.
                //
                // This **must not** be answered as "no changes". The system launches a
                // fresh extension instance for every working-set signal (S5), so the very
                // first `enumerateChanges` on a signalled instance races the readiness
                // call, and reporting an empty change set at the anchor the system already
                // holds tells it that it is up to date: the change is then dropped until
                // something else signals, which for a deletion means a file that is gone
                // from the server and the index stays in Finder indefinitely. Measured on
                // a real mount, 2026-09-04. `.serverUnreachable` is the honest answer and
                // the system retries.
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                return
            }
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
            let fresh = extensionInstance.currentSequence()
            extensionInstance.reportAnchorExpired(freshAnchor: String(fresh))
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(
            NSFileProviderSyncAnchor(Data(String(extensionInstance.currentSequence()).utf8)))
    }
}
