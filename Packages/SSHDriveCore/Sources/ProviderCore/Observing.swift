import Foundation

/// `NSFileProviderEnumerationObserver`, mirrored. The adapter in `Apps/FileProvider` wraps
/// the system's observer in one of these; `SystemModel.FileProviderD` implements it
/// directly, which is how a scenario sees exactly what fileproviderd would see.
public protocol EnumerationObserving: AnyObject {
    func didEnumerate(_ items: [ItemView])
    /// nil means "that was the last page".
    func finishEnumerating(upTo token: ProviderPageToken?)
    func finishEnumerating(with failure: ProviderFailure)
}

/// `NSFileProviderChangeObserver`, mirrored.
///
/// The rule that governs every use of it: **never** `finishEnumeratingChanges` with an
/// empty set at the anchor the system already holds. That tells the system it is up to
/// date and the change is dropped until something else signals (`MQ-004`), which for a
/// deletion means a file gone from both the server and the index sitting in Finder
/// indefinitely.
public protocol ChangeObserving: AnyObject {
    func didUpdate(_ items: [ItemView])
    func didDeleteItems(_ identifiers: [ProviderItemIdentifier])
    func finishEnumeratingChanges(upTo anchor: ProviderSyncAnchor, moreComing: Bool)
    func finishEnumerating(with failure: ProviderFailure)
}

/// `NSFileProviderEnumerator`, mirrored. One per container the system asks about, plus the
/// working set's.
public protocol ProviderEnumerating: AnyObject {
    func enumerateItems(for observer: EnumerationObserving, startingAt page: ProviderPageToken?)
    func enumerateChanges(for observer: ChangeObserving, from anchor: ProviderSyncAnchor)
    func currentSyncAnchor(_ completion: @escaping (ProviderSyncAnchor?) -> Void)
    func invalidate()
}

/// A clock, injected, as `AgentCore`'s clock-taking types already are. Seconds since the
/// epoch, because that is what `IndexReaderReadiness` takes.
public protocol ProviderClock: AnyObject {
    func now() -> Double
}

/// The system clock, which is what `Apps/FileProvider` passes.
public final class SystemProviderClock: ProviderClock {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
}

/// The three calls the extension makes *on its own domain* rather than on the agent
/// (`NSFileProviderManager`).
///
/// `signalErrorResolved` is the one that matters and it is not decoration: a signalled
/// enumerator is re-scheduled, not un-throttled, and only this call clears a
/// `.serverUnreachable` backoff (`MQ-037`, and `MQ-005` for what the backoff costs).
public protocol ProviderDomainSignalling: AnyObject {
    func signalErrorResolved(_ failure: ProviderFailure)
    /// The one case where the extension, not the agent, changes domain state
    /// (docs/design/components.md).
    func disconnect(reason: String)
    /// Lifts a disconnect a previous instance may have left behind (`MQ-074`).
    func reconnect()
}
