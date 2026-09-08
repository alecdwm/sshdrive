import FileProvider
import Foundation
import ProviderCore

/// The `NSFileProviderEnumerator` adapters (DESIGN.md sections 5.1, 5.3).
///
/// Both the container enumerator and the working set live in `ProviderCore` -
/// `ContainerEnumeration` and `WorkingSetEnumeration` - because every branch in them is a
/// decision: which source answers the change stream, which error a reader that cannot
/// answer deserves, and what an anchor is when nobody can supply one. What is left here
/// is the wrapper that puts the system's observer behind `EnumerationObserving` /
/// `ChangeObserving` and forwards.

/// One enumerator, whatever the container. The system asks for a fresh one per container
/// and the working set gets its own; the difference is decided in
/// `ProviderService.enumerator(for:)`.
final class EnumeratorAdapter: NSObject, NSFileProviderEnumerator {
    private let core: ProviderEnumerating

    init(core: ProviderEnumerating) {
        self.core = core
    }

    func invalidate() { core.invalidate() }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
    ) {
        core.enumerateItems(
            for: EnumerationObserverAdapter(observer), startingAt: AppleMapping.token(from: page))
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
    ) {
        core.enumerateChanges(for: ChangeObserverAdapter(observer), from: AppleMapping.anchor(anchor))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        core.currentSyncAnchor { completionHandler($0.map(AppleMapping.anchor)) }
    }
}

/// `NSFileProviderEnumerationObserver` behind `EnumerationObserving`.
final class EnumerationObserverAdapter: EnumerationObserving {
    private let observer: NSFileProviderEnumerationObserver

    init(_ observer: NSFileProviderEnumerationObserver) {
        self.observer = observer
    }

    func didEnumerate(_ items: [ItemView]) {
        observer.didEnumerate(items.map { Item(view: $0) })
    }

    func finishEnumerating(upTo token: ProviderPageToken?) {
        observer.finishEnumerating(upTo: AppleMapping.page(from: token))
    }

    func finishEnumerating(with failure: ProviderFailure) {
        observer.finishEnumeratingWithError(AppleMapping.nsError(failure))
    }
}

/// `NSFileProviderChangeObserver` behind `ChangeObserving`.
final class ChangeObserverAdapter: ChangeObserving {
    private let observer: NSFileProviderChangeObserver

    init(_ observer: NSFileProviderChangeObserver) {
        self.observer = observer
    }

    func didUpdate(_ items: [ItemView]) {
        observer.didUpdate(items.map { Item(view: $0) })
    }

    func didDeleteItems(_ identifiers: [ProviderItemIdentifier]) {
        observer.didDeleteItems(withIdentifiers: identifiers.map(AppleMapping.identifier))
    }

    func finishEnumeratingChanges(upTo anchor: ProviderSyncAnchor, moreComing: Bool) {
        observer.finishEnumeratingChanges(
            upTo: AppleMapping.anchor(anchor), moreComing: moreComing)
    }

    func finishEnumerating(with failure: ProviderFailure) {
        observer.finishEnumeratingWithError(AppleMapping.nsError(failure))
    }
}
