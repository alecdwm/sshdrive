import Foundation
import FileProvider
import AgentCore
import Config
import Index
import SFTP
import SSHProcess
import XPCProtocols
import Logging

/// Owns the File Provider domain lifecycle and the per-location runtimes.
///
/// The agent is, with one exception, the only process that changes domain state through
/// NSFileProviderManager: the extension calls `disconnect(reason:)` and `reconnect()` on
/// its own domain when the agent cannot be reached (DESIGN.md sections 3, 5.2).
actor DomainManager {
    static let shared = DomainManager()

    /// config.json, reached through a serial queue of its own. Nothing that blocks on a
    /// file ever runs on this actor's executor: see `ConfigAccess`.
    private let config: ConfigAccess?
    private var runtimes: [String: LocationRuntime] = [:]
    /// Section 6.3's breaker and reconnection, one per `.sftp` location. Held here rather
    /// than inside the runtime because sleep, wake, a path change and a screen unlock all
    /// arrive for every location at once and none of them wants the index actor.
    private var gates: [String: ConnectionGate] = [:]
    /// Section 6.4's change detection, one per location. Held here rather than inside the
    /// runtime because a cycle must never queue behind an `item(for:)` fallback or a
    /// three-minute sweep of a large tree.
    private var detectors: [String: ChangeDetector] = [:]
    /// Section 6.6's other timer: section 7's TTL loop, one per location. Held here for
    /// the same reason as the detector - an eviction pass makes a File Provider call per
    /// file and must never queue behind the index.
    private var evictors: [String: CacheEvictor] = [:]
    private var started = false

    init() {
        self.config = try? ConfigAccess()
    }

    /// Loads config.json and brings up a runtime, and a domain, for every mounted
    /// location. Called once, when the launchd-started agent comes up.
    func start() async {
        guard !started else { return }
        started = true
        guard let config else {
            Log.agent.error("no app group container; the agent cannot serve any location")
            return
        }
        // Section 6.1's sleep and wake, section 6.3's path gate, and section 4.2's
        // screen-unlock re-arm. Started before any location, so a wake that lands during
        // the first connect is not missed.
        PowerEvents.shared.start()
        NetworkPathGate.shared.start()
        ScreenLockObserver.shared.start()

        // Section 6.1: orphans are not adopted. A master left behind by a crashed agent
        // still owns its socket, and `ControlMaster=yes` against an existing socket
        // disables multiplexing, so later mux clients would attach to the orphan.
        let swept = ControlSocket.sweepOrphans(environment: await AgentSSHEnvironment.shared.environment())
        if !swept.isEmpty {
            Log.ssh.notice("swept \(swept.count, privacy: .public) orphaned control socket(s)")
        }
        do {
            let file = try await config.load()
            for location in file.locations where location.mounted {
                do {
                    let started = try await runtime(for: location)
                    try await addDomain(for: location)
                    // Section 5.3's replica walk needs the domain to exist before
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
        }
    }

    func configuration() async throws -> ConfigFile {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.load()
    }

    func location(named name: String) async throws -> Location {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        let location = try await config.location(named: name)
        // Section 6.4's cadence: "a File Provider request for it that was not a system
        // request, **or a CLI command naming it**". Every user-facing command resolves
        // through here, so this is the one place that rule needs to live. It matters more
        // than it looks: a folder is enumerated once ever (section 6.5), so a user
        // watching a mount from a terminal produces no File Provider traffic at all, and
        // without this the location would sit at the ten-minute cadence while someone was
        // plainly working on it.
        await detectors[location.id]?.noteTouch()
        return location
    }

    @discardableResult
    func mutateConfiguration(_ body: @escaping (inout ConfigFile) throws -> Void) async throws
        -> ConfigFile
    {
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        return try await config.mutate(body)
    }

    /// The runtime for a location, started on first use.
    func runtime(for location: Location) async throws -> LocationRuntime {
        if let existing = runtimes[location.id] { return existing }
        try GroupContainer.createDomainDirectory(locationID: location.id)
        let transport: any SFTPTransport
        // Section 5.5's `<mac8>`: the first eight hex digits of the identifier minted
        // once per install, which names our upload temp files so every one of them says
        // which Mac made it.
        let macID = String(((try? await config?.load())??.macID ?? "00000000").prefix(8))
        switch location.backend {
        case .fake:
            transport = FakeTransport(root: location.remotePath ?? "/srv/fake")
        case .sftp:
            // Section 6.3: the breaker, not the connection, is what a location is made of
            // now. The gate holds the `SSHBackedTransport` when there is one and answers
            // every call while there is not, so a location whose server is down still
            // mounts, still serves the replica and still queues writes (section 5.6).
            let gate = ConnectionGate(
                location: location,
                askpassPath: AgentSecrets.askpassPath,
                askpass: AgentSecrets.broker,
                uploadTag: macID)
            gates[location.id] = gate
            await gate.setOnConnected { [weak self] id, connected in
                await self?.connectionCameUp(locationID: id, connected: connected)
            }
            await gate.setOnDisconnected { id, reason in
                Log.agent.notice(
                    "\(id, privacy: .public) is offline: \(reason, privacy: .public)")
            }
            transport = ReconnectingTransport(gate: gate, locationID: location.id)
        }
        let runtime = try LocationRuntime(
            location: location,
            transport: transport,
            indexURL: try GroupContainer.indexURL(locationID: location.id),
            backupURL: try GroupContainer.indexBackupURL(locationID: location.id),
            macID: macID)
        try await runtime.start()
        runtimes[location.id] = runtime

        // Section 6.4: change detection starts with the location and runs whether or not
        // the server is reachable - the first cycle after a reconnect is the full sweep
        // that catches everything done while we were away.
        let detector = ChangeDetector(
            locationID: location.id, runtime: runtime, location: location,
            capabilities: await DomainManager.capabilities(of: runtime, location: location))
        detectors[location.id] = detector
        await runtime.setWatchTier(await detector.currentTier().rawValue)
        await detector.start()

        // Section 6.6: the eviction loop runs on a timer of its own, from the moment the
        // location is up. A `cacheTTL` of `never` still starts it; the pass then decides
        // nothing and costs one enumeration every five minutes, which is what makes
        // `sshdrive set <name> cache-ttl` take effect without a restart.
        let evictor = CacheEvictor(
            locationID: location.id, runtime: runtime, ttl: location.cacheTTL)
        evictors[location.id] = evictor
        await evictor.start()
        return runtime
    }

    func evictor(locationID: String) -> CacheEvictor? { evictors[locationID] }

    /// `sshdrive set <name> cache-ttl <value>`, applied to the running loop (section 7).
    func applyCacheTTL(locationID: String, ttl: CacheTTL) async {
        await evictors[locationID]?.setTTL(ttl)
    }

    /// What the ladder of section 6.4 decides on: whether there is an exec channel at all,
    /// what `find` the probe found there, and whether the server looks able to run the
    /// helper.
    ///
    /// "Looks able" is the honest word. `auto` "tries the tiers from the top", so the
    /// helper is offered whenever the probe leaves it possible - a supported `uname`, a
    /// writable executable directory, a channel that can be held open, a binary in this
    /// build - and the deployment is what refutes it, with the real sentence, on the first
    /// cycle. Deciding it here from the probe alone would either refuse servers that work
    /// or claim the tier before anything had been uploaded.
    static func capabilities(of runtime: LocationRuntime, location: Location) async
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

    func detector(locationID: String) -> ChangeDetector? { detectors[locationID] }

    func runtime(domainIdentifier: String) async throws -> LocationRuntime {
        if let existing = runtimes[domainIdentifier] { return existing }
        guard let config else { throw GroupContainer.ContainerError.unavailable }
        let file = try await config.load()
        guard let location = file.locations.first(where: { $0.id == domainIdentifier }) else {
            throw SSHDriveAgentError.unknownDomain.asNSError("No location \(domainIdentifier).")
        }
        return try await runtime(for: location)
    }

    /// Every runtime that is already up. A cancel goes to all of them (section 5.2) and
    /// must never be the thing that connects a location.
    func startedRuntimes() -> [LocationRuntime] { Array(runtimes.values) }

    /// The runtime for a location **only if it is already up**. `list`, `show` and
    /// `status` use this rather than `runtime(for:)`: a status command that dialled every
    /// server would take a minute on a laptop with no network, and section 8 gives
    /// `status --probe` as the way to ask for a connection on purpose.
    func startedRuntime(locationID: String) -> LocationRuntime? { runtimes[locationID] }

    func gate(locationID: String) -> ConnectionGate? { gates[locationID] }

    func dropRuntime(locationID: String) async {
        if let detector = detectors.removeValue(forKey: locationID) { await detector.stop() }
        if let evictor = evictors.removeValue(forKey: locationID) { await evictor.stop() }
        if let gate = gates.removeValue(forKey: locationID) { await gate.shutdown() }
        guard let runtime = runtimes.removeValue(forKey: locationID) else { return }
        // `-O exit` on the master and the channel with it, so removing a location does
        // not leave an `ssh` behind (section 6.1).
        await runtime.shutdownTransport()
    }

    // MARK: Section 6.1's sleep and wake, section 6.3's path gate, section 4.2's re-arm

    /// `kIOMessageSystemWillSleep`: `-O exit` on every master before the Mac abandons the
    /// connection (section 6.1). Runs them together, because the acknowledgement the
    /// system is waiting for cannot be serialised behind eight `ssh` shutdowns.
    func willSleep() async {
        let all = Array(gates.values)
        await withTaskGroup(of: Void.self) { group in
            for gate in all { group.addTask { await gate.willSleep() } }
        }
    }

    /// `kIOMessageSystemHasPoweredOn`. Section 5.6: the same path a returning network path
    /// takes, because the masters were already dropped at the will-sleep message.
    func didWake(trigger: String) async {
        for gate in gates.values { await gate.didWake(trigger: trigger) }
        // Section 6.4: a full sweep on the way back from any outage, so changes made while
        // the Mac was asleep are caught rather than waiting for a file to be touched.
        for detector in detectors.values { await detector.requestFullSweep(reason: "wake") }
    }

    func networkPathChanged(available: Bool) async {
        for gate in gates.values { await gate.setNetworkPath(available) }
        guard available else { return }
        // "and immediately on network-up" (section 6.4's schedule).
        for detector in detectors.values {
            await detector.requestFullSweep(reason: "network up")
            await detector.noteTouch()
        }
    }

    /// `com.apple.screenIsUnlocked`: one re-armed attempt per location stopped by the
    /// authentication deadline (section 4.2).
    func screenUnlocked() async {
        for gate in gates.values { await gate.screenUnlocked() }
    }

    /// Every File Provider request that reaches the agent for this domain. Section 4.2's
    /// second re-arm trigger, behind the presence test and its once-a-minute rule, so this
    /// is cheap enough to sit on the hot path.
    @discardableResult
    nonisolated func noteFileProviderRequest(
        domainIdentifier: String, method: String = "request", subject: String = "",
        isSystemRequest: Bool = false
    ) -> CallTiming {
        Task { await DomainManager.shared.fileProviderRequestArrived(domainIdentifier) }
        // Section 6.4's cadence rides on the same call: a request that is not the
        // system's own is a touch, and a touched domain is polled every 60 s rather than
        // every 10 minutes.
        noteDomainTouched(domainIdentifier, isSystemRequest: isSystemRequest)
        return CallTiming(domain: domainIdentifier, method: method, subject: subject)
    }

    private func fileProviderRequestArrived(_ domainIdentifier: String) async {
        guard let gate = gates[domainIdentifier] else { return }
        await gate.fileProviderRequestArrived()
    }

    /// Section 6.4's cadence: "every 60 s while the user has touched the domain in the
    /// last 10 minutes (a File Provider request for it that was not a system request, or a
    /// CLI command naming it), every 10 min otherwise". A system request - the eager
    /// download of a pinned subtree, a Spotlight pass - is deliberately not a touch, or a
    /// background index of a large mount would hold every location at the fast cadence.
    nonisolated func noteDomainTouched(_ domainIdentifier: String, isSystemRequest: Bool = false) {
        guard !isSystemRequest else { return }
        Task { await DomainManager.shared.touch(domainIdentifier) }
    }

    private func touch(_ domainIdentifier: String) async {
        await detectors[domainIdentifier]?.noteTouch()
    }

    /// The extension told us the system's materialized set moved (section 6.5) - and it is
    /// also section 7.2's safety net, because a kept file turning dataless without our
    /// handler having run arrives here and nowhere else.
    ///
    /// The enumeration is made once and handed to both: it is the system's own replica
    /// walk and there is no reason to pay for it twice.
    func materializedItemsChanged(locationID: String) async {
        let identifiers = await ReplicaEnumerators.materializedIdentifiers(locationID: locationID)
        await detectors[locationID]?.materializedChanged(identifiers: identifiers)
        guard let runtime = runtimes[locationID] else { return }
        let reasserted =
            (try? await runtime.reassertKeptItems(materializedIdentifiers: identifiers)) ?? []
        guard !reasserted.isEmpty else { return }
        // The pin is re-asserted, not read as an unpin: the metadata versions have moved,
        // so one working-set signal is what makes the system re-apply the eager policy and
        // fetch the content again (section 7.2).
        await signalWorkingSet(locationID: locationID)
    }

    /// The extension handed out a fresh working-set anchor, or a connection came back:
    /// either way one full sweep at once (sections 5.3, 6.4).
    func requestFullSweep(locationID: String, reason: String) async {
        await detectors[locationID]?.requestFullSweep(reason: reason)
    }

    /// Section 5.6's "network returns" row, and the only place it lives.
    ///
    /// On success: re-derive the location's identity, channel budget and root row from the
    /// connection that just came up, then tell the system its error is resolved - which is
    /// the cue to retry pending uploads and fetches - and signal the working set. S5
    /// measures whether `signalErrorResolved` alone wakes the flush; `signalEnumerator` is
    /// the documented fallback and is sent either way, since it costs one call and the
    /// working set needs it regardless.
    private func connectionCameUp(locationID: String, connected: ConnectionGate.Connected) async {
        if let runtime = runtimes[locationID] {
            do {
                try await runtime.applyConnection(
                    budget: connected.budget, probe: connected.probe,
                    sharesMetadataChannel: connected.sharesMetadataChannel)
            } catch {
                Log.agent.error(
                    "\(locationID, privacy: .public): could not apply the new connection: \(error, privacy: .public)")
            }
            // Section 6.4: "On reconnect after any outage every tier first runs one full
            // sweep so changes made while disconnected are caught, then resumes streaming."
            // A server can also come back as a different one - a NAS whose busybox replaced
            // a GNU find - so the ladder is re-evaluated from the new probe first.
            if let detector = detectors[locationID] {
                await detector.applyCapabilities(
                    await DomainManager.capabilities(of: runtime, location: runtime.location),
                    watchMode: runtime.location.watchMode)
                await runtime.setWatchTier(await detector.currentTier().rawValue)
                await detector.requestFullSweep(reason: "reconnect")
            }
        }
        if let gate = gates[locationID], await gate.suppressRecoverySignals {
            Log.agent.notice(
                "\(locationID, privacy: .public): recovery signals suppressed by a debug hook")
            return
        }
        await signalErrorResolved(locationID: locationID)
        await signalWorkingSet(locationID: locationID)
    }

    /// `NSFileProviderManager.signalErrorResolved(.serverUnreachable)`: the system's cue to
    /// retry the uploads and fetches it queued while we were failing fast (section 5.6).
    nonisolated func signalErrorResolved(locationID: String) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        guard let manager = NSFileProviderManager(for: domain) else {
            Log.agent.error("no manager for domain \(locationID, privacy: .public)")
            return
        }
        do {
            try await Deadline.run("signalling that serverUnreachable is resolved") {
                try await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
            }
            Log.agent.notice(
                "signalled errorResolved(serverUnreachable) for \(locationID, privacy: .public)")
        } catch {
            Log.agent.error("signalErrorResolved failed: \(error, privacy: .public)")
        }
    }

    // MARK: Domains

    /// One domain per location, identified by the location's UUID (section 4).
    ///
    /// Whether the display name should be "SSH Drive - nas" or just "nas" is what spike
    /// S3 records, so that the sidebar does not read "SSH Drive - SSH Drive - nas"
    /// (section 2). Milestone 1 passes the bare name and S3 compares.
    nonisolated func addDomain(
        for location: Location, testingModes: NSFileProviderDomain.TestingModes = []
    ) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: location.id),
            displayName: location.displayName)
        // Only ever set by `sshdrive debug fake add --testing-modes` (spikes S4 and S6).
        // `alwaysEnabled` skips the user's approval, `interactive` hands the scheduler to
        // `listAvailableTestingOperations`; the appex's
        // com.apple.developer.fileprovider.testing-mode entitlement is what allows either.
        // A real location never asks for them, and the system does not let a domain give
        // `interactive` back once it has it.
        if !testingModes.isEmpty { domain.testingModes = testingModes }
        // No trash (section 5.4). This property defaults to YES, and with it the system
        // draws a `.Trash` in the mount, syncs it to the extension, and loops on
        // materializing a container we do not serve; anything that stats `.Trash`, such
        // as `ls -la`, waits on that loop (docs/spikes/results.md, 2026-09-04).
        domain.supportsSyncingTrash = false
        try await Deadline.run("adding the File Provider domain") {
            try await NSFileProviderManager.add(domain)
        }
        Log.agent.notice(
            "added domain \(location.id, privacy: .public) as \(location.displayName, privacy: .public)")
    }

    nonisolated func removeDomain(for location: Location) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: location.id),
            displayName: location.displayName)
        try await Deadline.run("removing the File Provider domain") {
            try await NSFileProviderManager.remove(domain)
        }
        Log.agent.notice("removed domain \(location.id, privacy: .public)")
    }

    /// Tells the system to re-ask for the working set, which is how every change the
    /// agent found reaches Finder (sections 5.3, 6.4).
    nonisolated func signalWorkingSet(locationID: String) async {
        await signalEnumerator(locationID: locationID, container: .workingSet)
    }

    /// The same call for one container. Reporting a new row through the working set is not
    /// enough to make the system ingest an item whose parent it has never enumerated: S6
    /// found that a pin on such a path sits idle until something looks the chain up
    /// (docs/spikes/results.md, 2026-09-04, s6-3). Signalling each new ancestor's own
    /// enumerator is how the agent asks for that listing.
    nonisolated func signalEnumerator(
        locationID: String, container: NSFileProviderItemIdentifier
    ) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        guard let manager = NSFileProviderManager(for: domain) else {
            Log.agent.error("no manager for domain \(locationID, privacy: .public)")
            return
        }
        do {
            try await Deadline.run("signalling an enumerator") {
                try await manager.signalEnumerator(for: container)
            }
        } catch {
            Log.agent.error("signalEnumerator failed: \(error, privacy: .public)")
        }
    }

    /// Every domain the system currently has for our provider, as "<name> (<id>)".
    ///
    /// The descriptions rather than the domains themselves, because the whole call runs
    /// under a deadline and `NSFileProviderDomain` is not `Sendable`.
    static func existingDomainDescriptions() async throws -> [String] {
        try await Deadline.run("listing the File Provider domains") {
            try await NSFileProviderManager.domains().map {
                "\($0.displayName) (\($0.identifier.rawValue))"
            }
        }
    }
}
