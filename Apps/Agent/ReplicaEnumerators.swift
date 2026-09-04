import Foundation
import FileProvider
import Logging

/// The two enumerators the *system* keeps for us, driven from the agent.
///
/// DESIGN.md section 6.5 sources the `materialized` reason of the root set from
/// `enumeratorForMaterializedItems()`, refreshed on `materializedItemsDidChange`, and
/// section 6.4's mass-deletion guard needs `enumeratorForPendingItems()` to know which
/// items carry a local edit the system has not managed to upload yet. Both live on
/// `NSFileProviderManager`, which only an unsandboxed process may usefully drive, so both
/// are the agent's (section 3).
///
/// Neither is a listing of ours: the system answers from its replica, with
/// `NSFileProviderItem`s whose `itemIdentifier` is the identifier we minted. The caller
/// maps those back to paths through the index.
enum ReplicaEnumerators {

    /// Every identifier the system currently holds materialized content for.
    ///
    /// Empty when there is no manager for the domain, which is the case while a domain is
    /// being added or removed - and an empty answer must therefore never be read as "the
    /// user evicted everything". The caller treats it as "no news" (section 6.5).
    static func materializedIdentifiers(locationID: String, timeout: TimeInterval = 30) async
        -> [String]?
    {
        guard let manager = manager(locationID: locationID) else { return nil }
        return await drain(manager.enumeratorForMaterializedItems(), timeout: timeout)
    }

    /// Every identifier the system lists as pending: a local create or edit it has not
    /// been able to hand us yet. Section 6.4 holds a deletion of any of these whatever the
    /// counts say, because the system re-offers a pending edit on a deleted item as a
    /// `createItem` that then collides for ever with no alert (S5, 2026-09-04).
    static func pendingIdentifiers(locationID: String, timeout: TimeInterval = 30) async
        -> [String]?
    {
        guard let manager = manager(locationID: locationID) else { return nil }
        return await drain(manager.enumeratorForPendingItems(), timeout: timeout)
    }

    private static func manager(locationID: String) -> NSFileProviderManager? {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        return NSFileProviderManager(for: domain)
    }

    /// Pages an enumerator to its end and returns the identifiers.
    ///
    /// Under a deadline of its own, like every other call the agent makes into the File
    /// Provider system (section 6.3): the enumerator is the system's, it is answered from
    /// the replica, and a wedged one must never stall a change-detection cycle.
    private static func drain(
        _ enumerator: NSFileProviderEnumerator, timeout: TimeInterval
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var identifiers: [String] = []
        var page = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
        while Date() < deadline {
            let observer = CollectingObserver()
            enumerator.enumerateItems(for: observer, startingAt: page)
            guard let outcome = await observer.wait(until: deadline) else { break }
            identifiers.append(contentsOf: observer.collected)
            switch outcome {
            case .finished(let next):
                guard let next else { return identifiers }
                page = next
            case .failed(let error):
                Log.agent.error(
                    "replica enumeration failed: \(error.localizedDescription, privacy: .public)")
                return identifiers
            }
        }
        return identifiers
    }

    private enum Outcome: Sendable {
        case finished(NSFileProviderPage?)
        case failed(Error)
    }

    /// One page of one enumeration. `didEnumerate` may arrive several times before
    /// `finishEnumerating`, and either finish method may arrive on any queue, so the
    /// waiting continuation is resumed exactly once behind a lock - by the observer or by
    /// the deadline, whichever comes first.
    private final class CollectingObserver: NSObject, NSFileProviderEnumerationObserver,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var identifiers: [String] = []
        private var outcome: Outcome?
        private var waiter: CheckedContinuation<Outcome?, Never>?

        var collected: [String] {
            lock.lock(); defer { lock.unlock() }
            return identifiers
        }

        func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
            let new = updatedItems.map { $0.itemIdentifier.rawValue }
            lock.lock()
            identifiers.append(contentsOf: new)
            lock.unlock()
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            settle(.finished(nextPage))
        }

        func finishEnumeratingWithError(_ error: Error) {
            settle(.failed(error))
        }

        private func settle(_ value: Outcome) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = value
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: value)
        }

        private func expire() {
            lock.lock()
            guard outcome == nil, let waiter else { lock.unlock(); return }
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: nil)
        }

        /// Nil means the deadline passed with no answer. The timer is a plain
        /// `asyncAfter` rather than a second child task: a task group waits for every
        /// child it started, so a losing child parked on a continuation nobody will
        /// resume would hang the group for ever.
        func wait(until deadline: Date) async -> Outcome? {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            return await withCheckedContinuation {
                (continuation: CheckedContinuation<Outcome?, Never>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                waiter = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.expire()
                }
            }
        }
    }
}
