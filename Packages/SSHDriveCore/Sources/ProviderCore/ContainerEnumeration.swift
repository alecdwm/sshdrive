import Foundation
import Logging

/// A container enumerator: one folder's listing, and the per-folder refresh Finder asks for
/// when it shows the folder (docs/design/extension.md, docs/design/root-set.md).
///
/// Both calls go to the agent, which lists over the transport and diffs against the index.
/// A container enumerator hands out the index's current sequence number and its
/// `enumerateChanges` never expires it: a folder refresh is a fresh listing diffed against
/// the index, whatever anchor the system holds (docs/design/item-index.md).
///
/// In practice the second call never comes: a folder is enumerated **once, ever**
/// (`MQ-001`), which is why the working set is the only route a server-side change has.
public final class ContainerEnumeration: ProviderEnumerating {
    private let container: ProviderItemIdentifier
    private unowned let service: ProviderService

    public init(container: ProviderItemIdentifier, service: ProviderService) {
        self.container = container
        self.service = service
    }

    public func invalidate() {}

    public func enumerateItems(
        for observer: EnumerationObserving, startingAt page: ProviderPageToken?
    ) {
        // Directory listings are paged, for directories with tens of thousands of entries.
        // The system hands back the page it was given, and its two well-known first-page
        // constants are not tokens of ours - the adapter has already turned those into nil.
        Log.extensionLog.notice(
            "enumerateItems container=\(self.container.rawValue, privacy: .public) page=\(page ?? "first", privacy: .public)"
        )
        service.agent.enumerateItems(container: container, pageToken: page) { [container] result in
            switch result {
            case .failure(let failure):
                Log.extensionLog.notice(
                    "enumerateItems container=\(container.rawValue, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                observer.finishEnumerating(with: failure)
            case .success(let page):
                Log.extensionLog.notice(
                    "enumerateItems container=\(container.rawValue, privacy: .public) -> \(page.items.count, privacy: .public) item(s)"
                )
                observer.didEnumerate(page.items)
                observer.finishEnumerating(upTo: page.nextPageToken)
            }
        }
    }

    public func enumerateChanges(
        for observer: ChangeObserving, from anchor: ProviderSyncAnchor
    ) {
        Log.extensionLog.notice(
            "enumerateChanges container=\(self.container.rawValue, privacy: .public)")
        service.agent.enumerateChanges(container: container, anchor: anchor) {
            [container] result in
            switch result {
            case .failure(let failure):
                Log.extensionLog.notice(
                    "enumerateChanges container=\(container.rawValue, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                observer.finishEnumerating(with: failure)
            case .success(let page):
                Log.extensionLog.notice(
                    "enumerateChanges container=\(container.rawValue, privacy: .public) -> \(page.items.count, privacy: .public) changed, \(page.deletedIdentifiers.count, privacy: .public) deleted"
                )
                observer.didUpdate(page.items)
                observer.didDeleteItems(page.deletedIdentifiers)
                observer.finishEnumeratingChanges(
                    upTo: ProviderSyncAnchor(page.anchor.isEmpty ? "0" : page.anchor),
                    moreComing: false)
            }
        }
    }

    /// The reader when it can answer, the agent when it cannot. Handing the system a 0
    /// because a readiness round trip has not come back is not free: 0 is an expired
    /// anchor as soon as the oldest surviving row is past it.
    public func currentSyncAnchor(_ completion: @escaping (ProviderSyncAnchor?) -> Void) {
        service.currentAnchor { completion($0) }
    }
}
