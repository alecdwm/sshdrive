import Foundation
import AgentCore
import Config
import Index
import SFTP
import SSHProcess
import XPCProtocols
import Logging
import ProviderCore

/// Owns the File Provider domain lifecycle and the per-location runtimes.
///
/// The agent is, with one exception, the only process that changes domain state through
/// NSFileProviderManager: the extension calls `disconnect(reason:)` and `reconnect()` on
/// its own domain when the agent cannot be reached (docs/design/extension.md).
public actor DomainManager {
    /// The process-wide one, set by `AgentRuntimeBootstrap.install` from `main.swift`. It exists
    /// because the XPC command layer is reached from an object per connection and has
    /// nothing else to hold; every runtime, detector, evictor and gate carries the
    /// environment it was made with instead, which is what lets a scenario run two agents
    /// in one process.
    nonisolated(unsafe) public static var shared = DomainManager(
        environment: AgentEnvironment.unconfigured)

    /// Every seam this agent was built with (docs/design/testing.md).
    public let environment: AgentEnvironment
    /// The keychain and the askpass broker (docs/design/secrets.md).
    public let secrets: AgentSecrets

    /// config.json, reached through a serial queue of its own. Nothing that blocks on a
    /// file ever runs on this actor's executor: see `ConfigAccess`.
    private let config: ConfigAccess?
    private var runtimes: [String: LocationRuntime] = [:]
    /// The circuit breaker and reconnection, one per `.sftp` location. Held here rather
    /// than inside the runtime because sleep, wake, a path change and a screen unlock all
    /// arrive for every location at once and none of them wants the index actor.
    private var gates: [String: ConnectionGate] = [:]
    /// Change detection, one per location. Held here rather than inside the runtime
    /// because a cycle must never queue behind an `item(for:)` fallback or a three-minute
    /// sweep of a large tree.
    private var detectors: [String: ChangeDetector] = [:]
    /// The TTL eviction loop, one per location. Held here for the same reason as the
    /// detector: an eviction pass makes a File Provider call per file and must never queue
    /// behind the index.
    private var evictors: [String: CacheEvictor] = [:]
    private var started = false

    public init(
        environment: AgentEnvironment, secrets: AgentSecrets? = nil,
        config: ConfigAccess? = nil
    ) {
        self.environment = environment
        self.secrets = secrets
            ?? AgentSecrets(
                store: environment.secrets,
                askpassPath: AskpassEnvironment.askpassPath(
                    forExecutableAt: environment.bundle.executableURL))
        self.config = config ?? (try? ConfigAccess())
    }

    /// Loads config.json and brings up a runtime, and a domain, for every mounted
    /// location. Called once, when the launchd-started agent comes up.
    public func start() async {
        guard !started else { return }
        started = true
        guard let config else {
            Log.agent.error("no app group container; the agent cannot serve any location")
            return
        }
        // Sleep and wake, the network path gate, and the screen-unlock re-arm. Started
        // before any location, so a wake landing during the first connect is not missed.
        installSystemObservers()

        // Orphans are not adopted. A master left behind by a crashed agent still owns
        // its socket, and `ControlMaster=yes` against an existing socket disables
        // multiplexing, so later mux clients would attach to the orphan.
        let swept = ControlSocket.sweepOrphans(environment: await AgentSSHEnvironment.shared.environment())
        if !swept.isEmpty {
            Log.ssh.notice("swept \(swept.count, privacy: .public) orphaned control socket(s)")
        }
        // A master whose socket is already gone leaves the sweep above nothing to iterate
        // over, so the command line is the other way in. Nothing of ours is connected yet.
        let strays = ControlSocket.killStrayMasters()
        if !strays.isEmpty {
            Log.ssh.notice("killed \(strays.count, privacy: .public) stray ssh master(s) at start")
        }
        do {
            let file = try await config.load()
            await removeStrandedDomains(keeping: file.locations)
            for location in file.locations where location.mounted {
                do {
                    let started = try await runtime(for: location)
                    try await addDomain(for: location)
                    // A domain whose working set answered `.serverUnreachable` often
                    // enough is left throttled by fileproviderd, and a signalled
                    // enumerator is re-scheduled rather than un-throttled: only
                    // `signalErrorResolved` clears it. The agent starting is the one
                    // moment it can be cleared for a domain whose extension has not been
                    // able to run a successful enumeration to clear it itself.
                    await signalErrorResolved(locationID: location.id)
                    // The replica walk needs the domain to exist before
                    // `getUserVisibleURL` and `getIdentifierForUserVisibleFile(at:)` can
                    // answer, so it runs here rather than inside `start()`. It clears
                    // `meta.reconciling`, which lifts the extension's stall.
                    if let report = await started.finishReconcileIfOwed() {
                        Log.agent.notice(
                            "\(location.id, privacy: .public): reconciled against the replica: \(String(describing: report), privacy: .public)"
                        )
                        await signalWorkingSet(locationID: location.id)
                    }
                } catch {
                    Log.agent.error(
                        "cannot start location \(location.id, privacy: .public): \(error, privacy: .public)")
                }
            }
            Log.agent.notice("agent ready with \(file.locations.count) location(s)")
        } catch {
            Log.agent.error("cannot read config.json: \(error, privacy: .public)")
            // No config at all - a `brew zap` deleted the group container, or this is a
            // reinstall over a removal that never ran `sshdrive remove --all`. The app on
            // its first launch removes every domain of ours when the container is gone
            // too, because nothing else can. A domain we cannot serve shows in the sidebar
            // as unavailable for ever otherwise.
            await removeStrandedDomains(keeping: [])
        }
    }

    /// On its first launch the app removes every domain whose identifier is not in
    /// `config.json`, and every domain of ours when the container is gone too.
    ///
    /// `zap` runs after Homebrew has already deleted the app, so by then there is no
    /// `sshdrive` and no provider left to call `NSFileProviderManager.remove(domain)`, and
    /// domain removal cannot be automated from the cask at all. This is where that debt is
    /// paid: the next install's first start clears whatever the last uninstall stranded.
    ///
    /// `NSFileProviderManager.domains()` only ever returns our own provider's domains, so
    /// nothing here can reach another app's.
    private func removeStrandedDomains(keeping locations: [Location]) async {
        let known = Set(locations.map(\.id))
        let replica = environment.replica
        guard let domains = try? await Deadline.run("listing the File Provider domains", {
            try await replica.domains()
        }) else { return }
        for domain in domains where !known.contains(domain.identifier) {
            do {
                try await Deadline.run("removing a stranded File Provider domain") {
                    _ = try await replica.removeDomain(domain, mode: .removeAll)
                }
                Log.agent.notice(
                    "removed stranded domain \(domain.identifier, privacy: .public) (\(domain.displayName, privacy: .public)): no such location in config.json"
                )
            } catch {
                Log.agent.error(
                    "could not remove stranded domain \(domain.identifier, privacy: .public): \(error, privacy: .public)"
                )
            }
        }
    }

    /// Sleep and wake, the network path gate, and the screen-unlock re-arm, all pointed
    /// at this agent.
    ///
    /// Named and separate because it is the whole of the wiring between the three system
    /// observers and the three handlers, and because a harness installs it without paying
    /// for the rest of `start()` - the login-shell snapshot, the orphan sweep and the
    /// config walk (docs/design/testing.md).
    public func installSystemObservers() {
        environment.power.start(
            willSleep: { [weak self] in await self?.willSleep() },
            didWake: { [weak self] in await self?.didWake(trigger: "wake from sleep") })
        environment.network.start(
            changed: { [weak self] available in
                await self?.networkPathChanged(available: available)
            })
        environment.screenLock.start(
            unlocked: { [weak self] in await self?.screenUnlocked() },
            locked: {})
    }

    public func configuration() async throws -> ConfigFile {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.load()
    }

    public func location(named name: String) async throws -> Location {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        let location = try await config.location(named: name)
        // A touch, for the change-detection cadence: a File Provider request that was not
        // a system request, **or a CLI command naming it**. Every user-facing command
        // resolves through here, so this is the one place that rule needs to live. It
        // matters more than it looks: a folder is enumerated once ever, so a user watching
        // a mount from a terminal produces no File Provider traffic at all, and without
        // this the location would sit at the ten-minute cadence while someone was plainly
        // working on it.
        await detectors[location.id]?.noteTouch()
        return location
    }

    @discardableResult
    public func mutateConfiguration(_ body: @escaping (inout ConfigFile) throws -> Void) async throws
        -> ConfigFile
    {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.mutate(body)
    }

    /// The runtime for a location, started on first use.
    public func runtime(for location: Location) async throws -> LocationRuntime {
        if let existing = runtimes[location.id] { return existing }
        try GroupContainer.createDomainDirectory(locationID: location.id)
        let transport: any SFTPTransport
        // The `<mac8>` in an upload temp file's name: the first eight hex digits of the
        // identifier minted once per install, so every temp file says which Mac made it.
        let macID = String(((try? await config?.load())??.macID ?? "00000000").prefix(8))
        switch location.backend {
        case .fake:
            transport = FakeTransport(root: location.remotePath ?? "/srv/fake")
        case .sftp:
            // The breaker, not the connection, is what a location is made of. The gate
            // holds the `SSHBackedTransport` when there is one and answers every call
            // while there is not, so a location whose server is down still mounts, still
            // serves the replica and still queues writes (docs/design/offline.md).
            let gate = ConnectionGate(
                location: location,
                askpassPath: secrets.askpassPath,
                askpass: secrets.broker,
                uploadTag: macID,
                environment: environment)
            gates[location.id] = gate
            await gate.setOnConnected { [weak self] id, connected in
                await self?.connectionCameUp(locationID: id, connected: connected)
            }
            await gate.setOnDisconnected { [weak self] id, reason in
                Log.agent.notice(
                    "\(id, privacy: .public) is offline: \(reason, privacy: .public)")
                // The helper's exec channel went with the master. Letting the stream find
                // out for itself leaves a dead channel held until its next read or ping,
                // and `status` claiming a tier that is not running.
                await self?.connectionWentAway(locationID: id, reason: reason)
            }
            transport = ReconnectingTransport(gate: gate, locationID: location.id)
        }
        let runtime = try LocationRuntime(
            location: location,
            transport: transport,
            indexURL: try GroupContainer.indexURL(locationID: location.id),
            backupURL: try GroupContainer.indexBackupURL(locationID: location.id),
            macID: macID,
            environment: environment)
        try await runtime.start()
        runtimes[location.id] = runtime

        // Change detection starts with the location and runs whether or not the server is
        // reachable: the first cycle after a reconnect is the full sweep that catches
        // everything done while we were away.
        let detector = ChangeDetector(
            locationID: location.id, runtime: runtime, location: location,
            capabilities: await DomainManager.capabilities(of: runtime, location: location),
            environment: environment)
        detectors[location.id] = detector
        await runtime.setWatchTier(await detector.currentTier().rawValue)
        await detector.start()

        // The eviction loop runs on a timer of its own, from the moment the location is
        // up. A `cacheTTL` of `never` still starts it; the pass then decides nothing and
        // costs one enumeration every five minutes, which is what makes
        // `sshdrive set <name> cache-ttl` take effect without a restart.
        let evictor = CacheEvictor(
            locationID: location.id, runtime: runtime, ttl: location.cacheTTL,
            environment: environment)
        evictors[location.id] = evictor
        await evictor.start()
        return runtime
    }

    public func evictor(locationID: String) -> CacheEvictor? { evictors[locationID] }

    /// `sshdrive set <name> cache-ttl <value>`, applied to the running eviction loop.
    public func applyCacheTTL(locationID: String, ttl: CacheTTL) async {
        await evictors[locationID]?.setTTL(ttl)
    }

    /// What the change-detection ladder decides on: whether there is an exec channel at
    /// all, what `find` the probe found there, and whether the server looks able to run
    /// the helper.
    ///
    /// "Looks able" is the honest word. `auto` "tries the tiers from the top", so the
    /// helper is offered whenever the probe leaves it possible - a supported `uname`, a
    /// writable executable directory, a channel that can be held open, a binary in this
    /// build - and the deployment is what refutes it, with the real sentence, on the first
    /// cycle. Deciding it here from the probe alone would either refuse servers that work
    /// or claim the tier before anything had been uploaded.
    public static func capabilities(of runtime: LocationRuntime, location: Location) async
        -> ChangeDetectionLadder.ServerCapabilities
    {
        let probe = await runtime.probeForSweep()
        let exec = await runtime.allowsExecChannel() && (probe?.hasShellAccess ?? false)
        var capabilities = ChangeDetectionLadder.ServerCapabilities(
            hasExecChannel: exec,
            hasFind: exec && !(probe?.findFlavour ?? "").isEmpty,
            takesCmin: probe?.findTakesCmin ?? false,
            takesPrintf: probe?.findTakesPrintf ?? false,
            helperAvailable: false,
            helperEnabledForLocation: location.helper)
        guard exec, let probe else { return capabilities }
        let persistent = await runtime.allowsPersistentExecChannel()
        guard persistent else {
            capabilities.helperBlockReason =
                "the server will not give the helper a channel of its own (MaxSessions 2)"
            return capabilities
        }
        guard !probe.cacheDirectory.isEmpty else {
            capabilities.helperBlockReason =
                probe.cacheNote.isEmpty ? "no writable directory for helper" : probe.cacheNote
            return capabilities
        }
        guard let manifest = HelperDeployer.manifest() else {
            capabilities.helperBlockReason = "this build ships no helper binaries"
            return capabilities
        }
        guard manifest.binary(forUname: probe.uname) != nil else {
            capabilities.helperBlockReason =
                "helper unsupported: \(probe.uname.isEmpty ? "unknown" : probe.uname)"
            return capabilities
        }
        capabilities.helperAvailable = true
        return capabilities
    }

    public func detector(locationID: String) -> ChangeDetector? { detectors[locationID] }

    public func runtime(domainIdentifier: String) async throws -> LocationRuntime {
        if let existing = runtimes[domainIdentifier] { return existing }
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        let file = try await config.load()
        guard let location = file.locations.first(where: { $0.id == domainIdentifier }) else {
            throw SSHDriveAgentError.unknownDomain.asNSError("No location \(domainIdentifier).")
        }
        return try await runtime(for: location)
    }

    /// Every runtime that is already up. A cancel goes to all of them
    /// (docs/design/extension.md) and must never be the thing that connects a location.
    public func startedRuntimes() -> [LocationRuntime] { Array(runtimes.values) }

    /// The runtime for a location **only if it is already up**. `list`, `show` and
    /// `status` use this rather than `runtime(for:)`: a status command that dialled every
    /// server would take a minute on a laptop with no network, and `status --probe` is
    /// the way to ask for a connection on purpose.
    public func startedRuntime(locationID: String) -> LocationRuntime? { runtimes[locationID] }

    public func gate(locationID: String) -> ConnectionGate? { gates[locationID] }

    /// Every gate that is up, for a caller that has to ask all of them something -
    /// whether any location is still running the reconnect sequence, say.
    public func startedGates() -> [ConnectionGate] { Array(gates.values) }

    public func dropRuntime(locationID: String) async {
        if let detector = detectors.removeValue(forKey: locationID) { await detector.stop() }
        if let evictor = evictors.removeValue(forKey: locationID) { await evictor.stop() }
        if let gate = gates.removeValue(forKey: locationID) { await gate.shutdown() }
        guard let runtime = runtimes.removeValue(forKey: locationID) else { return }
        // `-O exit` on the master and the channel with it, so removing a location does
        // not leave an `ssh` behind.
        await runtime.shutdownTransport()
    }

    /// Everything this agent started on a server, shut down, before the process exits.
    ///
    /// `sshdrive agent stop` must not reply and exit while a location's `ssh -N` master
    /// is still running: the next start's orphan sweep unlinks the stale socket but has no
    /// pid to kill, so the old `ssh` would hold a connection open for ever against a
    /// socket nothing can reach. `remove` does the same for one location through
    /// `dropRuntime`. The sweep's kill (`ControlSocket.sweepOrphans`) is the other half -
    /// this is the clean exit, that is the crash.
    ///
    /// Runs the locations concurrently, and each `-O exit` is bounded by `Spawn`'s own
    /// timeout, so a server that has stopped answering cannot hold the exit open.
    ///
    /// - Returns: what it took down, so `P4` can assert from the agent's side that the
    ///   shutdown reached **every** location and then ran the argv sweep - `SQ-043`'s
    ///   second master, the one with no socket at all, is invisible to anything else, and
    ///   `SQ-044`'s master whose socket was already unlinked cannot be reached by
    ///   `-O exit`. Counting is all a caller may do with it: the kill itself is
    ///   `ControlSocket`'s, and `K5`/`K6` are where it is defended.
    @discardableResult
    public func shutdownAll() async -> ShutdownSummary {
        let detectors = Array(self.detectors.values)
        let evictors = Array(self.evictors.values)
        let gates = Array(self.gates.values)
        let runtimes = Array(self.runtimes.values)
        self.detectors.removeAll()
        self.evictors.removeAll()
        self.gates.removeAll()
        self.runtimes.removeAll()

        await withTaskGroup(of: Void.self) { group in
            for detector in detectors { group.addTask { await detector.stop() } }
            for evictor in evictors { group.addTask { await evictor.stop() } }
        }
        await withTaskGroup(of: Void.self) { group in
            for gate in gates { group.addTask { await gate.shutdown() } }
            for runtime in runtimes { group.addTask { await runtime.shutdownTransport() } }
        }
        // And whatever is left. `SSHMaster.shutdown()` kills the child it spawned, so this
        // finds only masters the agent had lost track of - a restarted location can hold
        // two, and the second has no socket for the sweep to find on the next start. Safe
        // here and only here, because every transport above is down.
        let strays = ControlSocket.killStrayMasters()
        if !strays.isEmpty {
            Log.ssh.notice("killed \(strays.count, privacy: .public) stray ssh master(s) on exit")
        }
        Log.agent.notice(
            "shut down \(runtimes.count, privacy: .public) location(s) before exiting")
        return ShutdownSummary(
            locations: runtimes.count, gates: gates.count, detectors: detectors.count,
            evictors: evictors.count, straySweepRan: true, strayMastersKilled: strays.count)
    }

    /// What one shutdown took down (`P4`).
    public struct ShutdownSummary: Sendable, Equatable {
        public var locations: Int
        public var gates: Int
        public var detectors: Int
        public var evictors: Int
        /// Whether the argv sweep for stray masters ran at all. It is unconditional and
        /// runs **after** every transport is down, which is the only place it is safe: a
        /// master this agent still means to use looks exactly like a stray one
        /// (`SQ-043`).
        public var straySweepRan: Bool
        public var strayMastersKilled: Int
    }

    // MARK: Sleep and wake, the network path gate, the deadline re-arm

    /// `kIOMessageSystemWillSleep`: `-O exit` on every master before the Mac abandons the
    /// connection. Runs them together, because the acknowledgement the system is waiting
    /// for cannot be serialised behind eight `ssh` shutdowns.
    public func willSleep() async {
        let all = Array(gates.values)
        await withTaskGroup(of: Void.self) { group in
            for gate in all { group.addTask { await gate.willSleep() } }
        }
    }

    /// `kIOMessageSystemHasPoweredOn`. The same path a returning network path takes,
    /// because the masters were already dropped at the will-sleep message.
    public func didWake(trigger: String) async {
        for gate in gates.values { await gate.didWake(trigger: trigger) }
        // A full sweep on the way back from any outage, so changes made while the Mac was
        // asleep are caught rather than waiting for a file to be touched.
        for detector in detectors.values { await detector.requestFullSweep(reason: "wake") }
    }

    public func networkPathChanged(available: Bool) async {
        for gate in gates.values { await gate.setNetworkPath(available) }
        guard available else { return }
        // The poll schedule runs a cycle immediately on network-up.
        for detector in detectors.values {
            await detector.requestFullSweep(reason: "network up")
            await detector.noteTouch()
        }
    }

    /// `com.apple.screenIsUnlocked`: one re-armed attempt per location stopped by the
    /// authentication deadline (docs/design/secrets.md).
    public func screenUnlocked() async {
        for gate in gates.values { await gate.screenUnlocked() }
    }

    /// Every File Provider request that reaches the agent for this domain. The second
    /// re-arm trigger for the authentication deadline, behind the presence test and its
    /// once-a-minute rule, so this is cheap enough to sit on the hot path.
    @discardableResult
    public nonisolated func noteFileProviderRequest(
        domainIdentifier: String, method: String = "request", subject: String = "",
        isSystemRequest: Bool = false
    ) -> CallTiming {
        Task { [self] in await fileProviderRequestArrived(domainIdentifier) }
        // The change-detection cadence rides on the same call: a request that is not the
        // system's own is a touch, and a touched domain is polled every 60 s rather than
        // every 10 minutes.
        noteDomainTouched(domainIdentifier, isSystemRequest: isSystemRequest)
        return CallTiming(domain: domainIdentifier, method: method, subject: subject)
    }

    private func fileProviderRequestArrived(_ domainIdentifier: String) async {
        guard let gate = gates[domainIdentifier] else { return }
        await gate.fileProviderRequestArrived()
    }

    /// The change-detection cadence: every 60 s while the user has touched the domain in
    /// the last 10 minutes (a File Provider request for it that was not a system request,
    /// or a CLI command naming it), every 10 min otherwise. A system request - the eager
    /// download of a pinned subtree, a Spotlight pass - is deliberately not a touch, or a
    /// background index of a large mount would hold every location at the fast cadence.
    public nonisolated func noteDomainTouched(
        _ domainIdentifier: String, isSystemRequest: Bool = false
    ) {
        guard !isSystemRequest else { return }
        Task { [self] in await touch(domainIdentifier) }
    }

    private func touch(_ domainIdentifier: String) async {
        await detectors[domainIdentifier]?.noteTouch()
    }

    /// The extension told us the system's materialized set moved - and it is also the
    /// re-assert net for pins, because a kept file turning dataless without our handler
    /// having run arrives here and nowhere else.
    ///
    /// The enumeration is made once and handed to both: it is the system's own replica
    /// walk and there is no reason to pay for it twice.
    public func materializedItemsChanged(locationID: String) async {
        let identifiers = await environment.replica.materializedIdentifiers(
            locationID: locationID)
        await detectors[locationID]?.materializedChanged(identifiers: identifiers)
        guard let runtime = runtimes[locationID] else { return }
        // A location with no detector still publishes it: `status` is the third reader of
        // this set and the one that must not walk the replica for itself.
        runtime.materialized.record(identifiers, at: environment.clock.now())
        let reasserted =
            (try? await runtime.reassertKeptItems(materializedIdentifiers: identifiers)) ?? []
        guard !reasserted.isEmpty else { return }
        // The pin is re-asserted, not read as an unpin: the metadata versions have moved,
        // so one working-set signal is what makes the system re-apply the eager policy and
        // fetch the content again (docs/design/pinning.md).
        await signalWorkingSet(locationID: locationID)
    }

    /// The extension handed out a fresh working-set anchor, or a connection came back:
    /// either way one full sweep at once (docs/design/change-detection.md).
    private func connectionWentAway(locationID: String, reason: String) async {
        await detectors[locationID]?.connectionWentAway(reason: reason)
    }

    public func requestFullSweep(locationID: String, reason: String) async {
        await detectors[locationID]?.requestFullSweep(reason: reason)
    }

    /// What happens when the network returns, and the only place it lives.
    ///
    /// On success: re-derive the location's identity, channel budget and root row from the
    /// connection that just came up, then tell the system its error is resolved - which is
    /// the cue to retry pending uploads and fetches - and signal the working set.
    /// `signalErrorResolved` is the call that wakes the flush; `signalEnumerator` is sent
    /// either way, since it costs one call and the working set needs it regardless.
    private func connectionCameUp(locationID: String, connected: ConnectionGate.Connected) async {
        let suppressed = await gates[locationID]?.suppressRecoverySignals ?? false
        if suppressed {
            Log.agent.notice(
                "\(locationID, privacy: .public): recovery signals suppressed by a debug hook")
        }
        // `ReconnectSequence` in `AgentCore` owns the order, and the order is load-bearing:
        // the helper stream runs on an exec channel opened against the master the SFTP
        // channels sit on, so it is re-opened *after* `applyConnection`, and it is
        // re-opened *here* rather than left to the next poll cycle. Left to the poll cycle
        // it costs a reconnected location up to ten minutes with no push detection.
        for step in ReconnectSequence.steps {
            switch step {
            case .applyConnection:
                guard let runtime = runtimes[locationID] else { continue }
                do {
                    try await runtime.applyConnection(
                        budget: connected.budget, probe: connected.probe,
                        sharesMetadataChannel: connected.sharesMetadataChannel)
                } catch {
                    Log.agent.error(
                        "\(locationID, privacy: .public): could not apply the new connection: \(error, privacy: .public)"
                    )
                }
            case .applyCapabilities:
                guard let runtime = runtimes[locationID], let detector = detectors[locationID]
                else { continue }
                // A server can come back as a different one - a NAS whose busybox replaced
                // a GNU find - so the ladder is re-evaluated from the new probe first.
                await detector.applyCapabilities(
                    await DomainManager.capabilities(of: runtime, location: runtime.location),
                    watchMode: runtime.location.watchMode)
            case .reopenHelperStream:
                guard let detector = detectors[locationID] else { continue }
                // On reconnect after any outage every tier first runs one full sweep so
                // changes made while disconnected are caught, then resumes streaming.
                // Both halves live in `connectionCameUp`.
                await detector.connectionCameUp()
                await runtimes[locationID]?.setWatchTier(await detector.currentTier().rawValue)
            case .signalErrorResolved:
                guard !suppressed else { continue }
                await signalErrorResolved(locationID: locationID)
            case .signalWorkingSet:
                guard !suppressed else { continue }
                await signalWorkingSet(locationID: locationID)
            }
        }
    }

    /// `NSFileProviderManager.signalErrorResolved(.serverUnreachable)`: the system's cue to
    /// retry the uploads and fetches it queued while we were failing fast.
    public nonisolated func signalErrorResolved(locationID: String) async {
        let replica = environment.replica
        do {
            try await Deadline.run("signalling that serverUnreachable is resolved") {
                try await replica.signalErrorResolved(locationID: locationID)
            }
            Log.agent.notice(
                "signalled errorResolved(serverUnreachable) for \(locationID, privacy: .public)")
        } catch {
            Log.agent.error("signalErrorResolved failed: \(error, privacy: .public)")
        }
    }

    // MARK: Domains

    /// One domain per location, identified by the location's UUID (docs/design/locations.md).
    ///
    /// The display name is the bare nickname. The system prepends the app name to the
    /// mount directory and to the sidebar label itself, so passing "SSH Drive - nas" would
    /// read as "SSH Drive - SSH Drive - nas".
    public nonisolated func addDomain(
        for location: Location, testingModes: [String] = []
    ) async throws {
        // `testingModes` is only ever set by `sshdrive debug fake add --testing-modes`:
        // `always` skips the user's approval, `interactive` hands the scheduler to
        // `listAvailableTestingOperations`, and the appex's
        // com.apple.developer.fileprovider.testing-mode entitlement is what allows either.
        // A real location never asks for them.
        //
        // The adapter also clears `supportsSyncingTrash`, which defaults to YES: with it
        // the system draws a `.Trash` in the mount, syncs it to the extension, and loops
        // on materializing a container we do not serve; anything that stats `.Trash`, such
        // as `ls -la`, waits on that loop (`MQ-008`/`MQ-009`).
        let domain = ReplicaDomain(identifier: location.id, displayName: location.displayName)
        let replica = environment.replica
        do {
            try await Deadline.run("adding the File Provider domain") {
                try await replica.addDomain(domain, testingModes: testingModes)
            }
        } catch {
            // `add(domain)` on an identifier the system already holds is how a location is
            // renamed, and it is also what runs on every start. Both reach fileproviderd
            // while it is re-reading its domain list, and the reply can be lost even though
            // the call landed: `NSCocoaErrorDomain 4099, "The connection to service named
            // com.apple.FileProvider was invalidated"`. Seen during `set nickname` and
            // again on the first location start after an upgrade (2026-09-05). The domain
            // list is the authority, so ask it before believing the error; only a domain
            // that really is not there is a failure.
            let domains = (try? await replica.domains()) ?? []
            guard domains.contains(where: {
                $0.identifier == location.id && $0.displayName == location.displayName
            }) else { throw error }
            Log.agent.notice(
                "add(domain) for \(location.id, privacy: .public) reported \(error.localizedDescription, privacy: .public), but the domain is present as \(location.displayName, privacy: .public)"
            )
            return
        }
        Log.agent.notice(
            "added domain \(location.id, privacy: .public) as \(location.displayName, privacy: .public)")
    }

    /// Removes the location's domain. Under `.preserveDownloadedUserData` the answer is
    /// the folder the system moved the downloaded files to, or nil if it kept none.
    @discardableResult
    public nonisolated func removeDomain(
        for location: Location, mode: DomainRemovalMode = .removeAll
    ) async throws -> String? {
        let domain = ReplicaDomain(identifier: location.id, displayName: location.displayName)
        let replica = environment.replica
        let preserved = try await Deadline.run("removing the File Provider domain") {
            try await replica.removeDomain(domain, mode: mode)
        }
        if let preserved {
            Log.agent.notice(
                "removed domain \(location.id, privacy: .public); downloaded files kept at \(preserved, privacy: .public)"
            )
        } else {
            Log.agent.notice("removed domain \(location.id, privacy: .public)")
        }
        return preserved
    }

    /// Tells the system to re-ask for the working set, which is how every change the
    /// agent found reaches Finder (docs/design/change-detection.md).
    public nonisolated func signalWorkingSet(locationID: String) async {
        await signalEnumerator(locationID: locationID, container: .workingSet)
    }

    /// The same call for one container. Reporting a new row through the working set is not
    /// enough to make the system ingest an item whose parent it has never enumerated: a
    /// pin on such a path sits idle until something looks the chain up. Signalling each
    /// new ancestor's own enumerator is how the agent asks for that listing.
    public nonisolated func signalEnumerator(
        locationID: String, container: ProviderItemIdentifier
    ) async {
        let replica = environment.replica
        do {
            try await Deadline.run("signalling an enumerator") {
                try await replica.signalEnumerator(locationID: locationID, container: container)
            }
            // At the default level, and not `debug`: this is the last thing the agent
            // does with a change it found, and when nothing reaches Finder the question
            // is always whether the signal went out at all.
            Log.agent.notice(
                "\(locationID, privacy: .public): signalled \(container.rawValue, privacy: .public)"
            )
        } catch {
            Log.agent.error("signalEnumerator failed: \(error, privacy: .public)")
        }
    }

    /// Every domain the system currently has for our provider, as "<name> (<id>)".
    ///
    /// The descriptions rather than the domains themselves, because the whole call runs
    /// under a deadline and `NSFileProviderDomain` is not `Sendable`.
    public func existingDomainDescriptions() async throws -> [String] {
        let replica = environment.replica
        return try await Deadline.run("listing the File Provider domains") {
            try await replica.domains().map { "\($0.displayName) (\($0.identifier))" }
        }
    }
}
