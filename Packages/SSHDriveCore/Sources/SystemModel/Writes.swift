import Foundation
import ProviderCore

/// What the system is holding for us, and how it re-offers it.
///
/// Offline writes just queue (docs/design/offline.md), and this is the queue: the user's
/// write lands in the replica at once, the provider is asked afterwards, and a
/// failure is re-offered **for ever** on the measured backoff (`MQ-035`), each retry on a
/// freshly launched instance (`MQ-003`).
public struct PendingWrite: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case create
        case modify
        case delete
    }

    public var sequence: Int
    public var kind: Kind
    public var identifier: ProviderItemIdentifier
    public var filename: String
    public var changedFields: ProviderItemFields
    public var changes: ItemChanges
    public var template: ItemTemplate?
    public var attempts = 0
    public var nextAttemptAt: Double = 0
    public var lastFailure: ProviderFailure?
    /// `MQ-014`: a create being retried because the name is taken is **not** in the set
    /// `enumeratorForPendingItems` lists. The caller was told it succeeded and there is no
    /// alert anywhere; the only trace is the retry.
    public var isCollisionRetry = false
}

/// One offer, as the model saw it go out and come back. A scenario reads the retry
/// schedule off this rather than off a timer.
public struct WriteOffer: Equatable, Sendable {
    public var sequence: Int
    public var attempt: Int
    public var at: Double
    public var kind: PendingWrite.Kind
    public var filename: String
    public var instance: Int
    public var failure: ProviderFailure?
}

extension ModelDomain {

    // MARK: What a scenario reads

    /// The set the system's own pending-items enumerator lists. `MQ-014` keeps a
    /// collision-retried create out of it, which is why a standing `.filenameCollision`
    /// is invisible to everything except the retry counter.
    public var pendingIdentifiers: [ProviderItemIdentifier] {
        queued.filter { !$0.isCollisionRetry }.map(\.identifier)
    }

    public var hasPendingWrites: Bool { !queued.isEmpty }

    public func offers(ofSequence sequence: Int) -> [WriteOffer] {
        writeOffers.filter { $0.sequence == sequence }
    }

    /// The intervals between successive offers of one write, which is the measured
    /// schedule of `MQ-035` (or `MQ-014`) and nothing else.
    public func retryIntervals(ofSequence sequence: Int) -> [Double] {
        let times = offers(ofSequence: sequence).map(\.at)
        return zip(times.dropFirst(), times).map { ($0 - $1) }
    }

    // MARK: Enqueueing

    @discardableResult
    func enqueue(_ write: PendingWrite) -> Int {
        var write = write
        nextWriteSequence += 1
        write.sequence = nextWriteSequence
        write.nextAttemptAt = clock.now()
        queued.append(write)
        clock.schedule(after: 0) { [weak self] in self?.offer(sequence: write.sequence) }
        clock.drain()
        return write.sequence
    }

    func mintLocalIdentifier() -> ProviderItemIdentifier {
        nextLocalIdentifier += 1
        return ProviderItemIdentifier("system-local-\(identifier)-\(nextLocalIdentifier)")
    }

    // MARK: Offering

    /// One offer of one queued write.
    ///
    /// `MQ-003`: every retry arrives on a **freshly launched instance**, which is why an
    /// extension may not carry anything it learned into the next attempt.
    func offer(sequence: Int) {
        guard let index = queued.firstIndex(where: { $0.sequence == sequence }) else { return }
        var write = queued[index]
        write.attempts += 1
        queued[index] = write
        let service = launchInstance()
        let attempt = write.attempts
        switch write.kind {
        case .create:
            guard let template = write.template else { return }
            calls.append(.createItem(filename: template.filename, attempt: attempt))
            service.createItem(template: template, contents: nil, transferID: "t-\(sequence)-\(attempt)") {
                [weak self] result in
                self?.finish(sequence: sequence, attempt: attempt, result: result)
            }
        case .modify:
            calls.append(
                .modifyItem(
                    identifier: write.identifier.rawValue,
                    changedFields: write.changedFields.rawValue, attempt: attempt))
            service.modifyItem(
                identifier: write.identifier, baseVersion: replica.item(write.identifier)?.contentVersion,
                changedFields: write.changedFields, changes: write.changes, contents: nil,
                transferID: "t-\(sequence)-\(attempt)"
            ) { [weak self] result in
                self?.finish(sequence: sequence, attempt: attempt, result: result)
            }
        case .delete:
            calls.append(.deleteItem(identifier: write.identifier.rawValue))
            service.deleteItem(
                identifier: write.identifier,
                baseVersion: replica.item(write.identifier)?.contentVersion, recursive: true
            ) { [weak self] failure in
                guard let self else { return }
                if let failure {
                    self.finish(sequence: sequence, attempt: attempt, result: .failure(failure))
                } else {
                    self.replica.remove(write.identifier)
                    self.record(sequence: sequence, attempt: attempt, failure: nil)
                    self.queued.removeAll { $0.sequence == sequence }
                }
            }
        }
        clock.drain()
    }

    private func record(sequence: Int, attempt: Int, failure: ProviderFailure?) {
        guard let write = queued.first(where: { $0.sequence == sequence }) else { return }
        writeOffers.append(
            WriteOffer(
                sequence: sequence, attempt: attempt, at: clock.now(), kind: write.kind,
                filename: write.filename, instance: instancesLaunched, failure: failure))
    }

    private func finish(
        sequence: Int, attempt: Int, result: Result<ItemView, ProviderFailure>
    ) {
        guard let index = queued.firstIndex(where: { $0.sequence == sequence }) else { return }
        let write = queued[index]
        switch result {
        case .success(let view):
            record(sequence: sequence, attempt: attempt, failure: nil)
            queued.remove(at: index)
            apply(reply: view, to: write)
        case .failure(let failure):
            record(sequence: sequence, attempt: attempt, failure: failure)
            apply(failure: failure, to: write)
        }
    }

    /// `MQ-013`: the system **believes whatever version the reply carries**. It records
    /// it, marks the item most-recent-version-downloaded, sets no conflict flag, never
    /// re-fetches and never re-offers - so a reply that names the remote version leaves
    /// the replica holding the *local* bytes under it until something evicts.
    private func apply(reply view: ItemView, to write: PendingWrite) {
        if write.kind == .create {
            replica.reidentify(from: write.identifier, to: view.identifier)
        }
        let hadBytes = replica.item(view.identifier)?.isDownloaded ?? false
        replica.ingest(view)
        replica.mutate(view.identifier) { item in
            item.isDownloaded = hadBytes || item.isDownloaded
            item.uploadingErrorCode = nil
        }
        if write.kind == .modify {
            // `MQ-017`: an `evictItem` issued straight after this reply is refused -2008,
            // because the system is still finishing the modification it has just been
            // told about. The first retry has always been enough.
            settlingAfterModify.insert(view.identifier)
        }
    }

    private func apply(failure: ProviderFailure, to write: PendingWrite) {
        guard let index = queued.firstIndex(where: { $0.sequence == write.sequence }) else { return }
        var write = queued[index]
        write.lastFailure = failure
        switch failure {
        case .filenameCollision:
            // `MQ-014`: retried for ever with no alert, on the measured backoff, and the
            // pending-items enumerator stays empty. Nothing tells the user; nothing gives
            // up. That is why a standing `.filenameCollision` is forbidden by `D3`.
            write.isCollisionRetry = true
            queued[index] = write
            reschedule(write, schedule: quirks.durations(.filenameCollisionRetrySchedule))
        case .noSuchItem where write.kind == .modify:
            // `MQ-080`: the system does not lose a pending edit on an item we
            // report deleted - it re-offers it as a **createItem** of the same name,
            // which then collides with the path that is still there, for ever. `D5`'s
            // mass-deletion guard exists because of this.
            queued.remove(at: index)
            let local = replica.item(write.identifier)
            let parent = local?.parentIdentifier ?? .rootContainer
            enqueue(
                PendingWrite(
                    sequence: 0, kind: .create, identifier: write.identifier,
                    filename: write.filename, changedFields: [], changes: ItemChanges(),
                    template: ItemTemplate(
                        parentIdentifier: parent, filename: write.filename,
                        isDirectory: false, isSymlink: false)))
        case .serverUnreachable, .notAuthenticated, .insufficientQuota:
            // `MQ-035`: re-offered for ever on the doubling backoff, no ceiling in sight.
            replica.mutate(write.identifier) { $0.uploadingErrorCode = failure.appleErrorCode }
            queued[index] = write
            reschedule(write, schedule: quirks.durations(.queuedWriteRetrySchedule))
        default:
            // Everything else leaves the item where it is and surfaces as the item's
            // `uploadingError` and nowhere else (`MQ-078`): `ln -s` exited 0, the file is
            // in the mount, and only `sshdrive status` can say why it is not on the
            // server. confidence: the retry schedule above was measured against
            // `.serverUnreachable`; that a `.cannotSynchronize` is *not* re-offered is
            // what a refused link showed, and is modelled as terminal here.
            replica.mutate(write.identifier) { $0.uploadingErrorCode = failure.appleErrorCode }
            queued.remove(at: index)
        }
    }

    private func reschedule(_ write: PendingWrite, schedule: [Double]) {
        let step = max(write.attempts - 1, 0)
        var delay: Double
        if step < schedule.count {
            delay = schedule[step]
        } else {
            // Past the last measured interval the model doubles, which is what "still
            // climbing ten minutes in, with no ceiling seen" means.
            delay = (schedule.last ?? 1) * pow(2, Double(step - schedule.count + 1))
        }
        if let index = queued.firstIndex(where: { $0.sequence == write.sequence }) {
            queued[index].nextAttemptAt = clock.now() + delay
        }
        clock.schedule(after: delay) { [weak self] in self?.offer(sequence: write.sequence) }
    }

    /// `MQ-037`: `signalErrorResolved(.serverUnreachable)` is the only thing that flushes
    /// the queue - the `modifyItem` arrived 20 ms after it. `signalEnumerator` alone did
    /// nothing in 60 s and a plain reconnect nothing in 75 s.
    func flushQueuedWritesAfterErrorResolved() {
        let sequences = queued.map(\.sequence)
        for sequence in sequences {
            clock.schedule(after: 0.02) { [weak self] in self?.offer(sequence: sequence) }
        }
        clock.drain()
    }
}
