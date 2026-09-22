import Foundation
import Logging

/// The working set: only ever a change stream, never a listing (docs/design/item-index.md,
/// `MQ-002`).
///
/// The extension answers this from the index itself where it can, which is what keeps it
/// working while the agent is restarting - but where it cannot, it asks the agent rather
/// than failing. `.serverUnreachable` here is not cheap: fileproviderd throttles a change
/// enumeration that keeps returning it, and 27 consecutive failures on one real domain took
/// the event stream out to a 47-minute retry, after which no server-side change reached
/// Finder at all (`MQ-005`, 2026-09-08). So it is reserved for an agent that genuinely
/// cannot be reached, which is the one case where there is nothing to say.
public final class WorkingSetEnumeration: ProviderEnumerating {
    private unowned let service: ProviderService

    public init(service: ProviderService) {
        self.service = service
    }

    public func invalidate() {}

    /// Returns no items: the working set is only a change stream and the system ingests
    /// nothing from a listing of it (`MQ-002`).
    public func enumerateItems(
        for observer: EnumerationObserving, startingAt page: ProviderPageToken?
    ) {
        Log.extensionLog.notice("workingSet enumerateItems -> 0 items")
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    public func enumerateChanges(for observer: ChangeObserving, from anchor: ProviderSyncAnchor) {
        let anchorValue = anchor.sequence
        let readerState = service.reader.stateName
        Log.extensionLog.notice(
            "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) reader=\(readerState, privacy: .public)"
        )
        do {
            guard let result = try service.reader.changes(since: anchorValue) else {
                // The reader is not usable: the `indexReady` round trip has not come back,
                // the agent answered no, the schema is newer than this build understands,
                // or the file could not be opened. None of those is a reason to fail the
                // enumeration - the agent has the same rows and can answer over the
                // channel, and an error here is what fileproviderd throttles on
                // (`MQ-005`).
                //
                // What must never happen is an empty change set at the anchor the system
                // already holds: that tells it that it is up to date and the change is
                // dropped until something else signals (`MQ-004`), which for a deletion
                // means a file gone from both the server and the index sitting in Finder
                // indefinitely.
                askAgent(anchor: anchorValue, readerState: readerState, observer: observer)
                return
            }
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> \(result.items.count, privacy: .public) changed, \(result.deleted.count, privacy: .public) deleted, newAnchor=\(result.newAnchor, privacy: .public), moreComing=\(result.hasMore, privacy: .public), source=reader"
            )
            service.noteWorkingSetSucceeded()
            observer.didUpdate(result.items)
            observer.didDeleteItems(result.deleted)
            observer.finishEnumeratingChanges(
                upTo: ProviderSyncAnchor(sequence: result.newAnchor), moreComing: result.hasMore)
        } catch ProviderFailure.syncAnchorExpired {
            // The reader hands out a fresh anchor and tells the agent so, one call per
            // expiry; the agent's response is one full sweep of the root set
            // (docs/design/item-index.md, `MQ-006`).
            let fresh = service.reader.currentSequence() ?? 0
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> syncAnchorExpired, fresh=\(fresh, privacy: .public)"
            )
            service.reportAnchorExpired(freshAnchor: String(fresh))
            service.noteWorkingSetFailed()
            observer.finishEnumerating(with: .syncAnchorExpired)
        } catch let failure as ProviderFailure {
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> error \(String(describing: failure), privacy: .public)"
            )
            service.noteWorkingSetFailed()
            observer.finishEnumerating(with: failure)
        } catch {
            Log.extensionLog.notice(
                "workingSet enumerateChanges anchor=\(anchorValue, privacy: .public) -> error \(String(describing: error), privacy: .public)"
            )
            service.noteWorkingSetFailed()
            observer.finishEnumerating(with: .cannotSynchronize)
        }
    }

    /// The channel half of the same change stream. The agent runs the identical query on
    /// the writer's connection (`IndexChangeStream`), so the two answers cannot drift.
    private func askAgent(
        anchor: Int64, readerState: String, observer: ChangeObserving
    ) {
        service.agent.enumerateWorkingSetChanges(anchor: ProviderSyncAnchor(sequence: anchor)) {
            [service] result in
            switch result {
            case .failure(let failure):
                if failure == .syncAnchorExpired {
                    Log.extensionLog.notice(
                        "workingSet enumerateChanges anchor=\(anchor, privacy: .public) -> syncAnchorExpired, source=agent"
                    )
                    service.reportAnchorExpired(freshAnchor: String(anchor))
                }
                Log.extensionLog.notice(
                    "workingSet enumerateChanges anchor=\(anchor, privacy: .public) reader=\(readerState, privacy: .public) -> \(String(describing: failure), privacy: .public), source=agent"
                )
                service.noteWorkingSetFailed()
                observer.finishEnumerating(with: failure)
            case .success(let page):
                let newAnchor = page.anchor.isEmpty ? String(anchor) : page.anchor
                Log.extensionLog.notice(
                    "workingSet enumerateChanges anchor=\(anchor, privacy: .public) reader=\(readerState, privacy: .public) -> \(page.items.count, privacy: .public) changed, \(page.deletedIdentifiers.count, privacy: .public) deleted, newAnchor=\(newAnchor, privacy: .public), moreComing=\(page.moreComing, privacy: .public), source=agent"
                )
                service.noteWorkingSetSucceeded()
                observer.didUpdate(page.items)
                observer.didDeleteItems(page.deletedIdentifiers)
                observer.finishEnumeratingChanges(
                    upTo: ProviderSyncAnchor(newAnchor), moreComing: page.moreComing)
            }
        }
    }

    public func currentSyncAnchor(_ completion: @escaping (ProviderSyncAnchor?) -> Void) {
        service.currentAnchor { completion($0) }
    }
}
