import Foundation
import Logging
import ProviderCore

/// What the model saw itself do. The journal is one of the assertions a scenario has: not
/// only "did the row reach the replica" but "how many times was the extension asked", which
/// is how `MQ-001` and `MQ-003` are tested at all.
public enum ModelCall: Equatable, Sendable {
    case instanceLaunched(Int)
    case instanceInvalidated
    case enumerateItems(container: String, page: String?)
    case enumerateContainerChanges(container: String, anchor: String)
    case enumerateWorkingSetItems
    case enumerateWorkingSetChanges(anchor: String)
    case currentSyncAnchor(enumerator: String)
    case itemFor(String)
    case enumerationFailed(String)
    case trashEnumeratorRefused(String)
    /// The system was told the error is resolved and lifted the backoff (`MQ-037`).
    case signalErrorResolved
    case disconnect
    case reconnect
    /// A working-set signal that never reached the extension because the domain's
    /// fetch-event stream was throttled (`MQ-005`). This is the shipped symptom.
    case signalDroppedByThrottle
    /// One offer of a queued write, on the fresh instance `MQ-003` gives it.
    case createItem(filename: String, attempt: Int)
    case modifyItem(identifier: String, changedFields: UInt, attempt: Int)
    case deleteItem(identifier: String)
    /// One `fetchContents`. `MQ-036`: a failed one is never re-issued, so the count of
    /// these per identifier is an assertion in itself.
    case fetchContents(identifier: String, foreground: Bool)
    case evictItem(identifier: String)
    /// The trash node the system made for itself, and each time it asked us about it
    /// (`MQ-075`, `MQ-009`, `MQ-010`).
    case trashNodeCreated
    case trashRemovedFromMount
    /// `add(domain)` with an identifier the system already holds (`MQ-051`).
    case domainRenamedInPlace(from: String, to: String)
}

/// The simulated fileproviderd (docs/design/testing.md).
///
/// It owns the domains and their replicas and drives `ProviderCore` through exactly the
/// protocols `Apps/FileProvider` implements, so a scenario exercises the shipping decision
/// and not a paraphrase of it. Every rule below cites the quirk id in
/// `docs/quirks/macos.md` it comes from; a version whose table says otherwise gets the
/// other behaviour.
public final class FileProviderD {
    public let clock: VirtualClock
    public let quirks: QuirkTable
    public let version: MacOSVersion
    public private(set) var domains: [String: ModelDomain] = [:]
    /// launchd, the login item and LaunchServices, which is where `MQ-061`, `MQ-062` and
    /// `MQ-063` live. It is on fileproviderd because the appex it can or cannot find is
    /// what decides whether a domain comes up at all.
    public let launchd: Launchd

    public init(macOS version: MacOSVersion = .v26_4, clock: VirtualClock = VirtualClock()) {
        self.clock = clock
        self.version = version
        self.quirks = QuirkTable(for: version)
        self.launchd = Launchd(clock: clock, quirks: self.quirks)
    }

    /// What `add(domain)` can answer with. `MQ-052`'s 4099 is the case where the call
    /// reports a failure the domain list contradicts.
    public struct DomainError: Error, Equatable {
        public let domain: String
        public let code: Int
        public let message: String
        /// True when the domain is there despite the error, which is what makes re-reading
        /// the domain list before believing it the only safe response.
        public let landedAnyway: Bool

        public init(domain: String, code: Int, message: String, landedAnyway: Bool) {
            self.domain = domain
            self.code = code
            self.message = message
            self.landedAnyway = landedAnyway
        }
    }

    /// Staged by a scenario: the next `addDomain` reports this even though it worked
    /// (`MQ-052`).
    public var nextAddReportsError: DomainError?

    /// `add(domain)`. The system creates the domain, launches a provider instance and asks
    /// the working-set enumerator for the anchor it should start from, and it creates the
    /// trash node and asks about it (`MQ-075`, `MQ-009`, `MQ-010`).
    @discardableResult
    public func addDomain(
        identifier: String, displayName: String, supportsSyncingTrash: Bool? = nil,
        makeProvider: @escaping (ModelDomain) -> ProviderService
    ) throws -> ModelDomain {
        // `MQ-061`: with no plugin registered the appex does not exist as far as
        // fileproviderd is concerned, and the domain is refused before anything of ours
        // is asked anything.
        guard launchd.providerPluginIsRegistered else {
            throw DomainError(
                domain: "NSFileProviderErrorDomain", code: -2001,
                message: "The File Provider extension could not be found (underlying FP -2014).",
                landedAnyway: false)
        }
        // `MQ-051`: the same identifier with a new display name renames the domain in
        // place. Nothing about the replica moves - not the materialized set, not the
        // pending writes, not one byte on disk.
        if let existing = domains[identifier] {
            if existing.displayName != displayName {
                existing.rename(to: displayName)
            }
            if let staged = nextAddReportsError {
                nextAddReportsError = nil
                throw staged
            }
            return existing
        }
        let domain = ModelDomain(
            identifier: identifier, displayName: displayName, clock: clock, quirks: quirks,
            supportsSyncingTrash: supportsSyncingTrash
                ?? quirks.bool(.supportsSyncingTrashDefaultsYes),
            makeProvider: makeProvider)
        domains[identifier] = domain
        domain.start()
        if let staged = nextAddReportsError {
            nextAddReportsError = nil
            throw staged
        }
        return domain
    }

    /// Re-reading the domain list, which is the only way to tell a 4099 that landed from
    /// one that did not (`MQ-052`).
    public func domainList() -> [String] { domains.keys.sorted() }

    public func domain(_ identifier: String) -> ModelDomain {
        guard let domain = domains[identifier] else {
            fatalError("no domain \(identifier) in the model")
        }
        return domain
    }

    public func advance(_ duration: Double) { clock.advance(duration) }
}

/// One domain: its replica, its provider instances, its anchors and its throttle.
public final class ModelDomain: ProviderDomainSignalling {
    public let identifier: String
    /// `MQ-050`: the bare nickname. The mount directory and the sidebar label are derived
    /// from it and nowhere else, which is why a nickname that repeats the app name
    /// stutters. `MQ-051` moves it in place.
    public private(set) var displayName: String
    public let replica = Replica()
    let clock: VirtualClock
    let quirks: QuirkTable
    private let makeProvider: (ModelDomain) -> ProviderService

    /// What the domain was added with. `MQ-008`: it defaults to YES, and `B2` is the
    /// finding that setting it to NO changes nothing the model can see - the trash node
    /// is created and asked about either way.
    public let supportsSyncingTrash: Bool

    /// Finder, the user.
    public private(set) lazy var finder = Finder(domain: self)

    // MARK: The write queue (`MQ-035`, `MQ-014`, `MQ-003`)

    public internal(set) var queued: [PendingWrite] = []
    var nextWriteSequence = 0
    var nextLocalIdentifier = 0
    /// Every offer of every write, in order, for a scenario to read the schedule off.
    public internal(set) var writeOffers: [WriteOffer] = []

    // MARK: Downloads (`MQ-031`, `MQ-032`, `MQ-036`)

    public internal(set) var fetchesInFlight = 0
    public var peakFetchesInFlight = 0
    /// Every batch boundary the eager pass produced, so `G8` can assert "strict batches of
    /// six, never seven".
    public internal(set) var fetchBatchSizes: [Int] = []
    public internal(set) var fetchesIssued: [ProviderItemIdentifier] = []
    public internal(set) var fetchFailures: [ProviderItemIdentifier] = []
    var eagerQueue: [ProviderItemIdentifier] = []
    var eagerBatchOutstanding = 0

    // MARK: Eviction (`MQ-017`-`MQ-021`, `MQ-033`, `MQ-034`)

    /// The identifiers whose `modifyItem` reply the system is still finishing, which is
    /// what refuses the eviction issued straight after one (`MQ-017`).
    var settlingAfterModify: Set<ProviderItemIdentifier> = []
    /// When the last pin was removed, for the 5-10 s window in which the system has not
    /// re-read the rows whose policy changed (`MQ-034`).
    public internal(set) var lastUnpinAt: Double?
    public internal(set) var evictionAttempts: [(identifier: ProviderItemIdentifier, outcome: EvictionOutcome)] = []

    // MARK: The trash (`MQ-075`, `MQ-009`, `MQ-010`)

    public internal(set) var trash = TrashNode()
    /// Answers the trash question with this instead of asking the provider. A model seam
    /// for `B1`'s bite-proof and nothing else.
    public var trashAnswerOverride: ProviderFailure?

    /// The live extension instance, or nil between a teardown and the next call.
    public private(set) var provider: ProviderService?
    public private(set) var instancesLaunched = 0
    public internal(set) var calls: [ModelCall] = []

    /// Sync anchors, one per enumerator: `workingSet`, and one per container the system
    /// has an enumerator for. They are the system's, not ours, and the system never
    /// invents one - every value here came out of the provider.
    public private(set) var anchors: [String: ProviderSyncAnchor] = [:]

    /// `MQ-001`: a folder is enumerated once, ever. This is the set that makes it so.
    public internal(set) var enumeratedContainers: Set<ProviderItemIdentifier> = []

    public private(set) var throttle: ErrorThrottle
    private var throttledUntil: Double?

    /// How many times the provider has answered "nothing has changed since the anchor you
    /// hold" (`MQ-004`). It must stay at zero: that answer is read as "up to date" and the
    /// change is dropped.
    public private(set) var emptyChangeSetsAtHeldAnchor = 0

    /// Whether the domain is disconnected (`MQ-040`); the extension can put it here
    /// itself and only a reconnect or a re-launch lifts it (`MQ-074`).
    public private(set) var isDisconnected = false
    public private(set) var disconnectReason: String?

    /// A test seam of the **model**, not of the product: it lets a scenario hand
    /// fileproviderd a working-set enumerator other than the shipping one, which is how
    /// `A2` proves it bites by driving the 0.1.2 logic through the same model.
    public var workingSetEnumeratorOverride: ((ProviderService) -> ProviderEnumerating)?

    public static let workingSetEnumeratorKey = "workingSet"

    init(
        identifier: String, displayName: String, clock: VirtualClock, quirks: QuirkTable,
        supportsSyncingTrash: Bool = true,
        makeProvider: @escaping (ModelDomain) -> ProviderService
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.clock = clock
        self.quirks = quirks
        self.supportsSyncingTrash = supportsSyncingTrash
        self.makeProvider = makeProvider
        self.throttle = ErrorThrottle(
            threshold: quirks.int(.changeEnumerationThrottleThreshold),
            ceiling: quirks.duration(.changeEnumerationThrottleCeiling))
    }

    // MARK: Instances

    /// `MQ-003`: the system launches a **fresh** extension instance for every working-set
    /// signal, and an `indexReady` lands in the same millisecond as each call. Modelling
    /// this is what makes the readiness race real rather than theoretical: an instance
    /// never gets to learn anything from the one before it.
    @discardableResult
    public func launchInstance() -> ProviderService {
        if let existing = provider {
            existing.invalidate()
            calls.append(.instanceInvalidated)
        }
        instancesLaunched += 1
        let service = makeProvider(self)
        provider = service
        calls.append(.instanceLaunched(instancesLaunched))
        service.start()
        clock.drain()
        return service
    }

    /// `MQ-073`: the system kills an idle instance, and the XPC connection invalidates as
    /// part of that teardown - which an invalidation handler must not read as "the agent
    /// has gone".
    public func killIdleInstance() {
        provider?.invalidate()
        provider = nil
        calls.append(.instanceInvalidated)
    }

    func liveProvider() -> ProviderService {
        if let provider { return provider }
        return launchInstance()
    }

    // MARK: Start

    /// `MQ-051`: a rename in place. The mount directory moves and nothing else does.
    func rename(to newName: String) {
        calls.append(.domainRenamedInPlace(from: displayName, to: newName))
        displayName = newName
    }

    /// Where the domain is mounted, derived from the display name and nothing else
    /// (`MQ-050`).
    public var mountDirectoryName: String {
        "SSHDrive-" + displayName.replacingOccurrences(of: " ", with: "")
    }

    /// What the Finder sidebar reads (`MQ-050`).
    public var sidebarLabel: String { "SSH Drive - " + displayName }

    func start() {
        let service = launchInstance()
        // The system asks the working-set enumerator where to start. Whatever it answers
        // is what the system holds from here on; it never makes one up.
        let enumerator = workingSetEnumerator(of: service)
        calls.append(.currentSyncAnchor(enumerator: Self.workingSetEnumeratorKey))
        enumerator.currentSyncAnchor { [weak self] anchor in
            self?.anchors[Self.workingSetEnumeratorKey] = anchor ?? ProviderSyncAnchor("0")
        }
        clock.drain()
        // `MQ-075`: the system makes the trash node itself at `add(domain)` time and then
        // asks the extension for its children - whatever `supportsSyncingTrash` said
        // (`MQ-008`, and `B2` is that the flag alone changes nothing).
        createTrashNodeAndAsk()
    }

    private func workingSetEnumerator(of service: ProviderService) -> ProviderEnumerating {
        if let override = workingSetEnumeratorOverride { return override(service) }
        // swiftlint:disable:next force_try - the working set is never the trash
        return try! service.enumerator(for: .workingSet)
    }

    // MARK: Enumeration

    /// Finder showing a folder. `MQ-001`: the first view is one `enumerateItems`; every
    /// later view, and a remote change landing while the window is open, is served from
    /// the replica and reaches the extension not at all (`MQ-039`).
    public func openFolder(_ container: ProviderItemIdentifier = .rootContainer) {
        guard !enumeratedContainers.contains(container) else { return }
        enumeratedContainers.insert(container)
        let service = liveProvider()
        guard let enumerator = try? service.enumerator(for: container) else {
            calls.append(.trashEnumeratorRefused(container.rawValue))
            return
        }
        enumeratePages(enumerator, container: container, page: nil)
    }

    private func enumeratePages(
        _ enumerator: ProviderEnumerating, container: ProviderItemIdentifier,
        page: ProviderPageToken?
    ) {
        calls.append(.enumerateItems(container: container.rawValue, page: page))
        let observer = ModelEnumerationObserver(
            onItems: { [weak self] items in items.forEach { self?.replica.ingest($0) } },
            onFinished: { [weak self] next in
                guard let self else { return }
                if let next {
                    self.enumeratePages(enumerator, container: container, page: next)
                    return
                }
                // The container enumerator is given an anchor of its own, which the system
                // holds and, in practice, never comes back with (`MQ-001`).
                self.calls.append(.currentSyncAnchor(enumerator: container.rawValue))
                enumerator.currentSyncAnchor { anchor in
                    self.anchors[container.rawValue] = anchor ?? ProviderSyncAnchor("0")
                }
            },
            onFailure: { [weak self] failure in
                self?.calls.append(.enumerationFailed(String(describing: failure)))
            })
        // `MQ-007`: the system does not time out an enumerateItems held the full 60 s, it
        // takes the answer, and it leaves the extension process running. The model has no
        // timeout at all and never tears the instance down for a slow call - which is the
        // assertion, not a tolerance.
        enumerator.enumerateItems(for: observer, startingAt: page)
        clock.drain()
    }

    /// What one `enumerateItems` answered, for a scenario to assert on.
    public struct Listing: Equatable {
        public var items: [ItemView]
        public var didFinish: Bool
        public var finishedUpTo: ProviderPageToken?
    }

    /// `enumerateItems` on the working set. `MQ-002`: it is only a change stream, so this
    /// returns nothing and the system ingests nothing from it - the model deliberately
    /// does not put what it sees into the replica, because the system does not either.
    public func enumerateWorkingSetItems() -> Listing {
        let service = liveProvider()
        let enumerator = workingSetEnumerator(of: service)
        calls.append(.enumerateWorkingSetItems)
        var listing = Listing(items: [], didFinish: false, finishedUpTo: nil)
        let observer = ModelEnumerationObserver(
            onItems: { listing.items.append(contentsOf: $0) },
            onFinished: { token in
                listing.didFinish = true
                listing.finishedUpTo = token
            },
            onFailure: { [weak self] failure in
                self?.calls.append(.enumerationFailed(String(describing: failure)))
            })
        enumerator.enumerateItems(for: observer, startingAt: nil)
        clock.drain()
        return listing
    }

    /// The system asking the working-set enumerator for the anchor it should hold. It
    /// does this when it creates the enumerator, and `A4` is about what comes back when
    /// the extension's reader cannot answer: a `0` is an expired anchor as soon as the
    /// oldest surviving row is past it.
    @discardableResult
    public func askWorkingSetAnchor() -> ProviderSyncAnchor? {
        let service = liveProvider()
        let enumerator = workingSetEnumerator(of: service)
        calls.append(.currentSyncAnchor(enumerator: Self.workingSetEnumeratorKey))
        var answer: ProviderSyncAnchor?
        enumerator.currentSyncAnchor { answer = $0 }
        clock.drain()
        if let answer { anchors[Self.workingSetEnumeratorKey] = answer }
        return answer
    }

    /// `signalEnumerator(.workingSet)` - the agent telling the system there is something
    /// new. Everything server-side comes this way, because a folder is enumerated once,
    /// ever (`MQ-001`).
    ///
    /// `MQ-037`: a signalled enumerator is re-**scheduled**, not un-throttled, and it
    /// flushes no queued write. So while the fetch-event stream is backing off (`MQ-005`)
    /// this call reaches the extension not at all, which is precisely the shipped symptom:
    /// `sshdrive debug signal` did nothing and the log showed no extension line.
    public func signalWorkingSet() {
        if let until = throttledUntil, clock.now() < until {
            calls.append(.signalDroppedByThrottle)
            return
        }
        // `MQ-003`: a fresh instance for every signal.
        let service = launchInstance()
        runWorkingSetChanges(on: service, allowExpiryRetry: true)
    }

    /// The system re-attempting a change enumeration on the instance it already has,
    /// which is what the backoff schedules and what was measured on 2026-09-08: one
    /// instance answered `reader=not-ready` from the agent, then answered from its own
    /// reader once the window closed, with no restart and no signal from anyone.
    ///
    /// It is the only path on which the extension can see a failure and a success in one
    /// life, and therefore the only path on which it can make the `signalErrorResolved`
    /// call that lifts the backoff (`MQ-037`). A backoff left behind by a *previous
    /// version* is not reachable from here at all, which is why the agent makes the same
    /// call once per mounted location at start.
    public func retryWorkingSetOnLiveInstance() {
        let service = liveProvider()
        runWorkingSetChanges(on: service, allowExpiryRetry: true)
    }

    private func runWorkingSetChanges(on service: ProviderService, allowExpiryRetry: Bool) {
        let held = anchors[Self.workingSetEnumeratorKey] ?? ProviderSyncAnchor("0")
        let enumerator = workingSetEnumerator(of: service)
        calls.append(.enumerateWorkingSetChanges(anchor: held.rawValue))
        var carried = 0
        let observer = ModelChangeObserver(
            onUpdate: { [weak self] items in
                carried += items.count
                items.forEach { self?.ingestFromWorkingSet($0) }
            },
            onDelete: { [weak self] ids in
                carried += ids.count
                ids.forEach { self?.replica.remove($0) }
            },
            onFinished: { [weak self] anchor, moreComing in
                guard let self else { return }
                // `MQ-004`: an empty change set at the anchor the system already holds is
                // read as "up to date", and the change is dropped until something else
                // signals - which is exactly how a deletion sat in Finder for ten minutes.
                // The model counts them rather than pretending otherwise, and `A1` asserts
                // the count stays at zero.
                if carried == 0 && anchor == held {
                    self.emptyChangeSetsAtHeldAnchor += 1
                }
                self.anchors[Self.workingSetEnumeratorKey] = anchor
                self.throttle.recordSuccess()
                if moreComing {
                    self.runWorkingSetChanges(on: service, allowExpiryRetry: allowExpiryRetry)
                }
            },
            onFailure: { [weak self] failure in
                guard let self else { return }
                self.calls.append(.enumerationFailed(String(describing: failure)))
                if failure == .syncAnchorExpired, allowExpiryRetry {
                    // `MQ-006`: the system re-asks from a fresh anchor rather than giving
                    // up, and an expiry is not an error the stream is throttled for.
                    self.anchors[Self.workingSetEnumeratorKey] = nil
                    let fresh = self.workingSetEnumerator(of: service)
                    self.calls.append(
                        .currentSyncAnchor(enumerator: ModelDomain.workingSetEnumeratorKey))
                    fresh.currentSyncAnchor { anchor in
                        self.anchors[ModelDomain.workingSetEnumeratorKey] =
                            anchor ?? ProviderSyncAnchor("0")
                    }
                    self.clock.drain()
                    self.runWorkingSetChanges(on: service, allowExpiryRetry: false)
                    return
                }
                // `MQ-005`: every other failure counts against the domain's fetch-event
                // stream, and the backoff grows to the measured 47 minutes at 27 errors.
                self.throttle.recordError()
                self.throttledUntil = self.clock.now() + self.throttle.nextRetryIn
            })
        enumerator.enumerateChanges(for: observer, from: held)
        clock.drain()
    }

    /// What the working set may put in the replica.
    ///
    /// `MQ-029`: **ancestors reported through the working set are not ingested.** Neither
    /// the signal nor a `signalEnumerator` on each new ancestor's container starts
    /// anything; a lookup of the path in the replica is what does. The model expresses
    /// that as: the change stream updates what the replica holds and adds items to
    /// containers it holds, but it never brings a **new container** into being - a
    /// directory enters the replica through an `enumerateItems` of its parent or through
    /// `getUserVisibleURL` plus an `lstat`, and by no other route.
    ///
    /// confidence: `MQ-029` measured the *outcome* three times (nothing downloads, and
    /// the path lookup is what starts it); that the new-directory case is the dividing
    /// line is the model's reading of it, not a separate measurement.
    func ingestFromWorkingSet(_ view: ItemView) {
        let existing = replica.item(view.identifier)
        if existing == nil, view.contentTypeHint == .folder, view.identifier != .rootContainer {
            replicaDroppedContainers += 1
            return
        }
        // `MQ-034`: a policy that stopped being eager is not re-read at once, and an
        // eviction inside the settle window fails naming no reason. The clock on that
        // window starts when the change arrives.
        if let existing, existing.kept, !view.kept { lastUnpinAt = clock.now() }
        replica.ingest(view)
    }

    /// How many new containers the working set was told about and did not create
    /// (`MQ-029`).
    public internal(set) var replicaDroppedContainers = 0

    /// A container's `enumerateChanges`. `MQ-001` says the system does not ask for one, so
    /// nothing but a scenario about that fact calls this.
    public func enumerateContainerChanges(_ container: ProviderItemIdentifier) {
        let service = liveProvider()
        guard let enumerator = try? service.enumerator(for: container) else { return }
        let held = anchors[container.rawValue] ?? ProviderSyncAnchor("0")
        calls.append(.enumerateContainerChanges(container: container.rawValue, anchor: held.rawValue))
        let observer = ModelChangeObserver(
            onUpdate: { [weak self] items in items.forEach { self?.replica.ingest($0) } },
            onDelete: { [weak self] ids in ids.forEach { self?.replica.remove($0) } },
            onFinished: { [weak self] anchor, _ in
                self?.anchors[container.rawValue] = anchor
            },
            onFailure: { [weak self] failure in
                self?.calls.append(.enumerationFailed(String(describing: failure)))
            })
        enumerator.enumerateChanges(for: observer, from: held)
        clock.drain()
    }

    /// `item(for:)`, which the system issues in bulk and which must be answered from local
    /// state (sections 2, 5.2).
    public func item(for identifier: ProviderItemIdentifier) -> Result<ItemView, ProviderFailure> {
        let service = liveProvider()
        calls.append(.itemFor(identifier.rawValue))
        var answer: Result<ItemView, ProviderFailure>?
        service.item(for: identifier) { answer = $0 }
        clock.drain()
        guard let answer else { fatalError("item(for:) never answered") }
        // `MQ-011`: `.noSuchItem` from here makes the system consider the item deleted and
        // delete it from disk. The model does the same, because that is the cost of
        // getting the error wrong.
        if case .failure(.noSuchItem) = answer { replica.remove(identifier) }
        if case .success(let view) = answer { replica.ingest(view) }
        return answer
    }

    /// Asking the extension for the trash container, which the system does whether or not
    /// the domain was added with `supportsSyncingTrash = false` (`MQ-008`, `MQ-075`).
    public func askForTrashEnumerator() -> ProviderFailure? {
        let service = liveProvider()
        do {
            _ = try service.enumerator(for: .trashContainer)
            return nil
        } catch let failure as ProviderFailure {
            calls.append(.trashEnumeratorRefused(String(describing: failure)))
            return failure
        } catch {
            return .cannotSynchronize
        }
    }

    // MARK: ProviderDomainSignalling - what the extension calls on us

    /// `MQ-037`: this, and only this, lifts the backoff.
    public func signalErrorResolved(_ failure: ProviderFailure) {
        calls.append(.signalErrorResolved)
        guard failure == .serverUnreachable else { return }
        throttle.clear()
        throttledUntil = nil
        // `MQ-037`: and this is also the only thing that flushes a queued write. The
        // `modifyItem` arrived 20 ms after it; a `signalEnumerator` did nothing in 60 s.
        flushQueuedWritesAfterErrorResolved()
    }

    public func disconnect(reason: String) {
        calls.append(.disconnect)
        isDisconnected = true
        disconnectReason = reason
    }

    public func reconnect() {
        calls.append(.reconnect)
        isDisconnected = false
        disconnectReason = nil
    }

    // MARK: Assertions

    public var throttleState: ErrorThrottle.State { throttle.state }
    public var errorGeneration: Int { throttle.errorGeneration }
    public var consecutiveErrors: Int { throttle.consecutiveErrors }
    public var heldWorkingSetAnchor: ProviderSyncAnchor? {
        anchors[Self.workingSetEnumeratorKey]
    }
    public func callCount(where predicate: (ModelCall) -> Bool) -> Int {
        calls.filter(predicate).count
    }
    public func resetCalls() { calls.removeAll() }
}

// MARK: The observers the model hands the provider

final class ModelEnumerationObserver: EnumerationObserving {
    private let onItems: ([ItemView]) -> Void
    private let onFinished: (ProviderPageToken?) -> Void
    private let onFailure: (ProviderFailure) -> Void

    init(
        onItems: @escaping ([ItemView]) -> Void,
        onFinished: @escaping (ProviderPageToken?) -> Void,
        onFailure: @escaping (ProviderFailure) -> Void
    ) {
        self.onItems = onItems
        self.onFinished = onFinished
        self.onFailure = onFailure
    }

    func didEnumerate(_ items: [ItemView]) { onItems(items) }
    func finishEnumerating(upTo token: ProviderPageToken?) { onFinished(token) }
    func finishEnumerating(with failure: ProviderFailure) { onFailure(failure) }
}

final class ModelChangeObserver: ChangeObserving {
    private let onUpdate: ([ItemView]) -> Void
    private let onDelete: ([ProviderItemIdentifier]) -> Void
    private let onFinished: (ProviderSyncAnchor, Bool) -> Void
    private let onFailure: (ProviderFailure) -> Void

    init(
        onUpdate: @escaping ([ItemView]) -> Void,
        onDelete: @escaping ([ProviderItemIdentifier]) -> Void,
        onFinished: @escaping (ProviderSyncAnchor, Bool) -> Void,
        onFailure: @escaping (ProviderFailure) -> Void
    ) {
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onFinished = onFinished
        self.onFailure = onFailure
    }

    func didUpdate(_ items: [ItemView]) { onUpdate(items) }
    func didDeleteItems(_ identifiers: [ProviderItemIdentifier]) { onDelete(identifiers) }
    func finishEnumeratingChanges(upTo anchor: ProviderSyncAnchor, moreComing: Bool) {
        onFinished(anchor, moreComing)
    }
    func finishEnumerating(with failure: ProviderFailure) { onFailure(failure) }
}
