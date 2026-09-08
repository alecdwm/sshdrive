import Foundation
import ProviderCore

/// What an `evictItem` answered. `MQ-018` is the whole reason this is a value and not a
/// boolean: `-2008` comes back for a pending upload and for a kept item alike, so the
/// caller cannot read a reason out of it, and `MQ-019` is a different error again.
public enum EvictionOutcome: Equatable, Sendable {
    case evicted(count: Int)
    case refused(domain: String, code: Int, message: String)

    public var didEvict: Bool {
        if case .evicted = self { return true }
        return false
    }

    public var code: Int? {
        if case .refused(_, let code, _) = self { return code }
        return nil
    }
}

extension ModelDomain {

    // MARK: Fetching content

    /// One `fetchContents`.
    ///
    /// `MQ-032`: a foreground open is admitted whatever else is in flight - eight files
    /// opened at once from a shell arrived as eight simultaneous calls. `MQ-031`'s
    /// ceiling of six is the *eager* pass's and is applied in `runEagerPass` below.
    ///
    /// `MQ-036`: a failure is **never re-issued**. There is no interval to model and no
    /// timer to advance; a second read produces a second call and nothing else does.
    public func fetchContents(
        _ identifier: ProviderItemIdentifier, foreground: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        let service = liveProvider()
        calls.append(.fetchContents(identifier: identifier.rawValue, foreground: foreground))
        fetchesIssued.append(identifier)
        fetchesInFlight += 1
        peakFetchesInFlight = max(peakFetchesInFlight, fetchesInFlight)
        let sink = FileHandle(forWritingAtPath: "/dev/null")
        service.fetchContents(
            identifier: identifier, requestedVersion: nil, isFileViewerRequest: foreground,
            isSystemRequest: !foreground, into: sink ?? FileHandle.nullDevice,
            transferID: "f-\(identifier.rawValue)"
        ) { [weak self] result in
            guard let self else { return }
            self.fetchesInFlight -= 1
            switch result {
            case .success(let view):
                self.materialize(view)
            case .failure:
                self.fetchFailures.append(identifier)
            }
            completion?()
        }
        clock.drain()
    }

    /// The bytes landed. This is the one place tags are rebuilt, and the one place they
    /// are lost.
    ///
    /// `MQ-043`: the system rebuilds the tags xattr from the item's own `tagData` on every
    /// re-download, so an item that returns none comes back **without the user's tags**;
    /// `MQ-045`: ordinary extended attributes are metadata, not content, and survive.
    private func materialize(_ view: ItemView) {
        replica.ingest(view)
        replica.mutate(view.identifier) { item in
            item.isDownloaded = true
            item.lastFetch = self.clock.now()
            item.tagData = view.tagData
            if let tagData = view.tagData {
                item.extendedAttributes[Self.tagsXattrName] = tagData
            } else {
                item.extendedAttributes.removeValue(forKey: Self.tagsXattrName)
            }
        }
        // `MQ-022`: something in the system advances a materialized file's atime minutes
        // after the fetch, with no read of ours near it. The one measurement is a file
        // fetched 280 s earlier whose atime was 23 s old, so the model schedules exactly
        // one deferred advance at that gap. confidence: one file, one reading.
        let deferral = quirks.duration(.atimeIsAdvancedDeferred)
        let identifier = view.identifier
        clock.schedule(after: deferral) { [weak self] in
            guard let self else { return }
            // `MQ-023`: relatime - the advance only happens while the file is still there
            // and still materialized.
            guard self.replica.item(identifier)?.isDownloaded == true else { return }
            self.replica.mutate(identifier) { $0.atime = self.clock.now() }
        }
    }

    /// The xattr name Finder tags live under in the replica. They never reach the
    /// extension as one (`MQ-042`, `MQ-044`).
    public static let tagsXattrName = "com.apple.metadata:_kMDItemUserTags"

    // MARK: The eager pass (`MQ-028`, `MQ-030`, `MQ-031`, `MQ-027`)

    /// The background-download scheduler doing what an eager `contentPolicy` asks for.
    ///
    /// `MQ-028`: it pulls a whole subtree **including subfolders nothing has ever listed** -
    /// a folder with no index row at all was asked for and its eight files came down in the
    /// same pass - so the model enumerates an unvisited eager directory rather than
    /// skipping it. `MQ-030`: the root container is not a special case. `MQ-027`: an
    /// explicit `.downloadLazily` beats an eager ancestor, which `Replica.effectivePolicy`
    /// resolves by nearness.
    ///
    /// Latency is deliberately not modelled: `MQ-071` says the scheduler takes 8-90 s to
    /// start on an idle headless Mac, and a latency claim needs a Mac somebody is using.
    public func runEagerPass() {
        var progressed = true
        var rounds = 0
        while progressed, rounds < 64 {
            rounds += 1
            progressed = false
            for item in eagerCandidates() {
                guard replica.effectivePolicy(of: item.identifier)
                    == .downloadEagerlyAndKeepDownloaded
                else { continue }
                if item.isDirectory, !enumeratedContainers.contains(item.identifier) {
                    openFolder(item.identifier)
                    progressed = true
                }
            }
            if drainEagerQueue() { progressed = true }
        }
    }

    private func eagerCandidates() -> [ReplicaItem] {
        var targets = replica.descendants(of: .rootContainer)
        if let root = replica.item(.rootContainer) { targets.insert(root, at: 0) }
        return targets
    }

    /// Everything eager and not yet downloaded, fetched in **strict batches of six**
    /// (`MQ-031`): six go out, and the seventh only after one of them comes back.
    private func drainEagerQueue() -> Bool {
        let ceiling = quirks.int(.concurrentFetchCeiling)
        let wanted = eagerCandidates()
            .filter {
                !$0.isDirectory && !$0.isDownloaded && !fetchFailures.contains($0.identifier)
                    && replica.effectivePolicy(of: $0.identifier) == .downloadEagerlyAndKeepDownloaded
            }
            .map(\.identifier)
        guard !wanted.isEmpty else { return false }
        var remaining = wanted
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(ceiling))
            remaining.removeFirst(batch.count)
            fetchBatchSizes.append(batch.count)
            var outstanding = batch.count
            for identifier in batch {
                fetchContents(identifier, foreground: false) { outstanding -= 1 }
            }
            // Whatever the agent's own delay is, the batch is not exceeded: the model
            // never has more than `ceiling` of them open, which is the assertion.
            while outstanding > 0, clock.runNextDue() {}
            if outstanding > 0 { break }
        }
        return true
    }

    // MARK: The replica lookup (`MQ-029`)

    /// `getUserVisibleURL` plus one `lstat` of the replica - the *only* thing that starts
    /// an unseen ancestor chain (`MQ-029`). Reporting the same ancestors through the
    /// working set ingests nothing, because the system has nowhere to put an item whose
    /// parent it does not hold; `Replica.droppedForUnknownParent` counts those.
    public func userVisibleURL(of identifier: ProviderItemIdentifier) -> String? {
        guard let path = replica.path(of: identifier) else { return nil }
        return "/Users/model/Library/CloudStorage/\(mountDirectoryName)/\(path)"
    }

    /// The `lstat` the agent does after `getUserVisibleURL`. It instantiates the item and
    /// every ancestor of it in the replica, asking the extension for each one, which is
    /// what makes the eager policy on a never-listed path take effect at all.
    @discardableResult
    public func lstatUserVisible(_ identifier: ProviderItemIdentifier) -> ReplicaItem? {
        var chain: [ItemView] = []
        var cursor = identifier
        var guardCount = 0
        while !replica.contains(cursor), guardCount < 64 {
            guardCount += 1
            guard case .success(let view) = item(for: cursor) else { return nil }
            chain.append(view)
            if view.parentIdentifier == cursor { break }
            cursor = view.parentIdentifier
        }
        // Top down, so every parent is in place before its child - which is exactly the
        // condition `Replica.ingest` refuses to work without.
        for view in chain.reversed() { replica.ingest(view) }
        return replica.item(identifier)
    }

    // MARK: Eviction

    /// `NSFileProviderManager.evictItem`.
    ///
    /// The order of the refusals is the order they were measured in, and each one names
    /// its quirk. Nothing here interprets a code, because `MQ-018` is that a code cannot
    /// be interpreted.
    @discardableResult
    public func evictItem(_ identifier: ProviderItemIdentifier) -> EvictionOutcome {
        calls.append(.evictItem(identifier: identifier.rawValue))
        let outcome = evictionOutcome(for: identifier)
        evictionAttempts.append((identifier, outcome))
        if case .evicted = outcome { applyEviction(to: identifier) }
        return outcome
    }

    private func evictionOutcome(for identifier: ProviderItemIdentifier) -> EvictionOutcome {
        let subtree = [identifier] + replica.descendants(of: identifier).map(\.identifier)

        // `MQ-017`: issued straight after a `modifyItem` reply it is refused -2008 - the
        // system is still finishing the modification. The same call seconds later
        // succeeds, and the first retry has always been enough, so the model refuses
        // exactly the first attempt after a reply. confidence: the window was never
        // measured, only its effect.
        if settlingAfterModify.contains(identifier) {
            settlingAfterModify.remove(identifier)
            return .refused(
                domain: "NSFileProviderErrorDomain", code: -2008,
                message: "The item is still being modified.")
        }

        // `MQ-034`: for 5-10 s after an unpin the system has not re-read the rows whose
        // policy changed, and the eviction fails naming no reason. The root container did
        // not become evictable within the minute that was measured (`MQ-034.root`).
        if let unpinned = lastUnpinAt {
            let window =
                identifier == .rootContainer
                ? quirks.duration(.unpinSettleWindowForTheRoot)
                : quirks.duration(.unpinSettleWindow)
            if clock.now() - unpinned < window {
                return .refused(
                    domain: "NSCocoaErrorDomain", code: 256,
                    message: "The file couldn't be opened.")
            }
        }

        // `MQ-018`: a pending upload refuses -2008. On the *parent directory* of one it is
        // a different error entirely (`MQ-019`): NSCocoaErrorDomain 4101 with an
        // underlying contentVersionMismatch, not the -2006 the header promises.
        let pending = Set(queued.map(\.identifier))
        if pending.contains(identifier) {
            return .refused(
                domain: "NSFileProviderErrorDomain", code: -2008,
                message: "The item has unsynced edits.")
        }
        if subtree.dropFirst().contains(where: { pending.contains($0) }) {
            return .refused(
                domain: "NSCocoaErrorDomain", code: quirks.int(.parentOfAPendingItemFailsOpaquely),
                message:
                    "Couldn't communicate with a helper application. "
                    + "(libfssync.VFSFileTree.ItemNotFoundReason 5 contentVersionMismatch)")
        }

        // `MQ-024`: the item's **effective** content policy, inherited from an eager
        // ancestor, is what refuses it - not `allowsEvicting`, which the system puts back
        // anyway (`MQ-025`). `MQ-018`: the code is the same -2008 as a pending upload, so
        // the loop cannot tell a pin from a queued write.
        if replica.effectivePolicy(of: identifier) == .downloadEagerlyAndKeepDownloaded {
            return .refused(
                domain: "NSFileProviderErrorDomain", code: -2008,
                message: "The item is kept downloaded.")
        }
        // `MQ-033`: on the root container the call fails **as a whole** the moment it
        // meets a kept child; it does not evict the rest.
        if identifier == .rootContainer || replica.item(identifier)?.isDirectory == true {
            if subtree.dropFirst().contains(where: {
                replica.effectivePolicy(of: $0) == .downloadEagerlyAndKeepDownloaded
            }) {
                return .refused(
                    domain: "NSFileProviderErrorDomain", code: -2008,
                    message: "A child of the container is kept downloaded.")
            }
        }

        // `MQ-020`: otherwise it evicts, and it evicts a **directory recursively** -
        // 11 materialized items to 0 from one call - and works on the root container
        // (`MQ-030`).
        let evicted = subtree.filter { replica.item($0)?.isDownloaded == true }
        return .evicted(count: evicted.count)
    }

    private func applyEviction(to identifier: ProviderItemIdentifier) {
        for target in [identifier] + replica.descendants(of: identifier).map(\.identifier) {
            replica.mutate(target) { item in
                guard item.isDownloaded else { return }
                item.isDownloaded = false
                // `MQ-021`: an eviction moves atime, which is why the TTL loop has to read
                // it *before* it evicts.
                item.atime = self.clock.now()
                // `MQ-045`: extended attributes are metadata, not content, and are
                // preserved on the dataless file.
            }
        }
    }

    /// The agent's retried eviction of DESIGN.md section 5.5: a doubling backoff from
    /// 0.25 s, given up after seven attempts. It is the agent's loop, not the system's,
    /// and it lives here so a scenario can drive it against the model's refusals - the
    /// shipping copy is `AgentRuntime`'s.
    @discardableResult
    public func evictWithBackoff(
        _ identifier: ProviderItemIdentifier, attempts: Int = 7, firstDelay: Double = 0.25
    ) -> (outcome: EvictionOutcome, tries: Int) {
        var delay = firstDelay
        var outcome = evictItem(identifier)
        var tries = 1
        while !outcome.didEvict, tries < attempts {
            clock.advance(delay)
            delay *= 2
            outcome = evictItem(identifier)
            tries += 1
        }
        return (outcome, tries)
    }
}
