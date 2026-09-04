import Foundation
import AgentCore
import Config
import Index
import Logging
import SFTP
import SSHProcess

/// One location's change detection: the poll cadence, the tier ladder, and the cycle that
/// tiers 0 and 1 share (DESIGN.md section 6.4).
///
/// Separate from `LocationRuntime` because the runtime is the index's writer and every
/// call on it serialises behind the index; a detector that lived there would put a
/// three-minute sweep of a large tree in front of every `item(for:)` fallback and every
/// fetch. This actor holds the schedule and the tier, calls into the runtime for the parts
/// that touch the index, and holds nothing while it waits.
actor ChangeDetector {
    let locationID: String
    private let runtime: LocationRuntime
    private var ladder: ChangeDetectionLadder
    private var watchMode: WatchMode

    private var loop: Task<Void, Never>?
    /// Section 6.4: "every 60 s while the user has touched the domain in the last 10
    /// minutes ... every 10 min otherwise". A touch is a File Provider request that was
    /// not a system request, or a CLI command naming the location.
    private var lastTouch: Double?
    private var lastCycle: Double = 0
    private var cycles = 0
    /// Set by a reconnect, a returning network path, a fresh working-set anchor, and the
    /// 30-minute insurance pass. "On reconnect after any outage every tier first runs one
    /// full sweep so changes made while disconnected are caught" (section 6.4).
    private var fullSweepPending = true
    private var fullSweepReason = "first cycle"
    private var lastOutcome: [String: Any] = [:]
    private var cycleInProgress = false

    /// `sshdrive debug watch --clock-skew <seconds>`: shifts the sweep's own reference,
    /// which is the only way to exercise section 6.4's server-clock window from a
    /// container that shares the host's clock (testbed/README.md). Applied to the stored
    /// timestamp, never to what the server said, so what is under test is the window the
    /// agent computes rather than the value it reads.
    private var clockSkewSeconds: Int64 = 0
    /// `sshdrive debug watch --pause`: stops the loop without stopping the location, so a
    /// spike can drive single cycles by hand.
    private var paused = false

    // MARK: Tier 2 (section 6.4)

    /// The live stream, or nil while the location is not at tier 2. Owned here rather than
    /// by `LocationRuntime` for the same reason the detector is: the runtime serialises
    /// behind the index, and a stream that lived there would hold it open.
    private var helper: HelperStream?
    /// What the last deployment did, for `status`.
    private var helperDeployment: HelperDeployer.Deployment?
    /// Why the helper is not running, when the ladder needs to say so.
    private var helperNote: String?
    /// Set by an `overflow` event: section 6.4 answers one with a sweep.
    private var helperOverflowPending = false
    /// Serialises `ensureHelper` against itself, since a cycle and a reconnect can both
    /// ask for it.
    private var helperStarting = false

    init(locationID: String, runtime: LocationRuntime, location: Location,
         capabilities: ChangeDetectionLadder.ServerCapabilities,
         now: Double = Date().timeIntervalSince1970) {
        self.locationID = locationID
        self.runtime = runtime
        self.watchMode = location.watchMode
        self.ladder = ChangeDetectionLadder(
            watchMode: location.watchMode, capabilities: capabilities, now: now)
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.secondsUntilNextCycle()
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(min(wait, 60) * 1_000_000_000))
                    continue
                }
                _ = await self.runCycle()
            }
        }
        Log.agent.notice(
            "\(self.locationID, privacy: .public): change detection started at tier \(self.ladder.tier.rawValue, privacy: .public)"
        )
    }

    func stop() {
        loop?.cancel()
        loop = nil
        let stream = helper
        helper = nil
        Task { await stream?.stop() }
    }

    private func secondsUntilNextCycle(now: Double = Date().timeIntervalSince1970) -> Double {
        guard !paused else { return 5 }
        let due = PollSchedule.nextFire(lastCycle: lastCycle, lastTouch: lastTouch, now: now)
        return max(0, due - now)
    }

    // MARK: Triggers

    /// Section 4.2's touch, reused here for section 6.4's cadence.
    func noteTouch(now: Double = Date().timeIntervalSince1970) { lastTouch = now }

    /// A reconnect, a returning network path, or the extension handing out a fresh
    /// working-set anchor. Every one of them is "run one full sweep at once" (sections
    /// 6.4, 5.3).
    func requestFullSweep(reason: String) {
        fullSweepPending = true
        fullSweepReason = reason
    }

    /// A new connection may be a different server: a NAS that came back with a busybox
    /// `find` where there was GNU, or an account that lost its shell.
    func applyCapabilities(
        _ capabilities: ChangeDetectionLadder.ServerCapabilities, watchMode: WatchMode,
        now: Double = Date().timeIntervalSince1970
    ) {
        self.watchMode = watchMode
        ladder.applyCapabilities(capabilities, watchMode: watchMode, now: now)
    }

    /// `materializedItemsDidChange` from the extension: section 6.5 sources the
    /// `materialized` reason from `enumeratorForMaterializedItems()` "refreshed on
    /// materializedItemsDidChange", so the root set is rebuilt at once rather than at the
    /// next cycle - a file that was just downloaded should be watched from now, not from
    /// up to ten minutes from now.
    func materializedChanged() async {
        let identifiers = await ReplicaEnumerators.materializedIdentifiers(locationID: locationID)
        await materializedChanged(identifiers: identifiers)
    }

    /// The same, with the enumeration already made. `DomainManager` walks the replica once
    /// and gives the answer to the root set and to section 7.2's safety net together.
    func materializedChanged(identifiers: [String]?) async {
        _ = try? await runtime.refreshRootSet(materializedIdentifiers: identifiers)
    }

    func setClockSkew(seconds: Int64) { clockSkewSeconds = seconds }
    func setPaused(_ value: Bool) { paused = value }

    // MARK: One cycle

    @discardableResult
    func runCycle(forceFull: Bool = false, now: Double = Date().timeIntervalSince1970) async
        -> LocationRuntime.ChangeApplication
    {
        guard !cycleInProgress else { return LocationRuntime.ChangeApplication() }
        cycleInProgress = true
        defer { cycleInProgress = false; lastCycle = Date().timeIntervalSince1970 }

        var full = forceFull || fullSweepPending
        var reason = full ? fullSweepReason : "cycle"
        // "a sweep still runs every 30 min as insurance against missed events."
        if !full, PollSchedule.insuranceDue(lastFullSweep: await runtime.lastFullSweep(), now: now) {
            full = true
            reason = "30-minute insurance sweep"
        }
        let started = Date()

        // Section 6.4's guard needs the pending set, and section 6.5's root set needs the
        // materialized one. Both are the system's answers, taken before anything is listed.
        let pendingIdentifiers = await ReplicaEnumerators.pendingIdentifiers(locationID: locationID)
        let materialized = await ReplicaEnumerators.materializedIdentifiers(locationID: locationID)
        await runtime.setPendingPaths(await runtime.paths(forIdentifiers: pendingIdentifiers ?? []))
        _ = try? await runtime.refreshRootSet(materializedIdentifiers: materialized, now: now)

        var application = LocationRuntime.ChangeApplication()
        var tierUsed = ladder.tier
        var sweepNote: String?

        var handledByHelper = false
        if ladder.tier == .helper {
            await ensureHelper()
            // Section 6.4: "The helper replaces the schedule with events; a sweep still
            // runs every 30 min as insurance against missed events." So an ordinary cycle
            // at tier 2 costs one root-set refresh and nothing on the wire; only a full
            // pass - reconnect, a fresh anchor, the insurance timer, or an `overflow` the
            // helper reported - runs a sweep.
            if helperOverflowPending {
                helperOverflowPending = false
                full = true
                reason = "the helper reported an overflow"
            }
            if let helper, await helper.state == .running {
                await pushRootsToHelper()
                if full {
                    do {
                        application = try await runSweep(full: true)
                    } catch {
                        sweepNote = "the insurance sweep could not run: \(error)"
                        application = await runtime.runPollCycle(fullSweep: true, now: now)
                    }
                }
                tierUsed = .helper
                handledByHelper = true
            }
        }

        // A location whose tier is `helper` but whose stream is not up right now - the
        // connection dropped a moment ago, or the deployment is being retried - still gets
        // a cycle. Without this the minute between the stream dying and the next cycle
        // starting it is a minute with no change detection at all, which is worse than the
        // tier it is nominally running (2026-09-05).
        if !handledByHelper, ladder.tier >= .sweep, ladder.capabilities.hasFind {
            do {
                application = try await runSweep(full: full)
            } catch {
                // "A tier that fails at runtime (the helper's stream dies with a
                // non-network error, `find` is missing) drops the location one tier down
                // for the rest of the session and records why" (section 6.4).
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if isTransportOutage(error) {
                    sweepNote = "the sweep could not run this cycle: \(text)"
                    Log.agent.notice(
                        "\(self.locationID, privacy: .public): \(sweepNote!, privacy: .public)")
                } else {
                    ladder.recordRuntimeFailure(reason: text, now: now)
                    await runtime.setWatchTier(ladder.tier.rawValue)
                    Log.agent.error(
                        "\(self.locationID, privacy: .public): the sweep failed (\(text, privacy: .public)); dropping to \(self.ladder.tier.rawValue, privacy: .public) for this session"
                    )
                }
                application = await runtime.runPollCycle(fullSweep: full, now: now)
                tierUsed = .poll
            }
        } else if !handledByHelper {
            application = await runtime.runPollCycle(fullSweep: full, now: now)
            tierUsed = .poll
        }

        // Section 6.4's re-check schedule for anything the guard is holding.
        let rechecks = await runtime.recheckHeldDeletions(now: now)
        application.changed += rechecks.changed
        application.deleted += rechecks.deleted
        application.held += rechecks.held
        application.released += rechecks.released
        application.listedDirectories += rechecks.listedDirectories

        if full { await runtime.setLastFullSweep(now) }
        fullSweepPending = false
        cycles += 1

        if !application.isEmpty {
            // Every difference became an anchor as it was written; this is what makes the
            // system come and read them (sections 5.3, 6.4).
            await DomainManager.shared.signalWorkingSet(locationID: locationID)
        }

        var outcome: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "tier": tierUsed.rawValue,
            "full": full,
            "reason": reason,
            "seconds": Date().timeIntervalSince(started),
            "changed": application.changed,
            "deleted": application.deleted,
            "held": application.held,
            "released": application.released,
            "directoriesListed": application.listedDirectories,
        ]
        if let sweepNote { outcome["note"] = sweepNote }
        if !application.errors.isEmpty { outcome["errors"] = application.errors }
        lastOutcome = outcome
        await runtime.recordWatchCycle(outcome)
        return application
    }

    // MARK: Tier 2

    /// Deploys the helper if it is not there, and starts the stream if it is not running.
    ///
    /// Called from every cycle rather than once, because the stream dies with the
    /// connection and section 6.3 brings the connection back on its own schedule: the
    /// cheapest correct rule is "if the tier is helper and nothing is streaming, start
    /// one", and it costs a comparison on a cycle where it is already up.
    private func ensureHelper() async {
        if let helper, await helper.state == .running { return }
        guard !helperStarting else { return }
        guard await runtime.allowsExecChannel(), let connection = await runtime.liveConnection()
        else { return }
        helperStarting = true
        defer { helperStarting = false }

        let deployment: HelperDeployer.Deployment
        do {
            deployment = try await HelperDeployer.ensureDeployed(
                connection: connection, locationID: locationID)
        } catch {
            // "Deployment failures are never fatal: the location silently continues at the
            // next tier and the status report says why the helper is not running."
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            helperNote = reason
            var capabilities = ladder.capabilities
            capabilities.helperAvailable = false
            capabilities.helperBlockReason = reason
            ladder.applyCapabilities(capabilities, watchMode: watchMode, now: Date().timeIntervalSince1970)
            await runtime.setWatchTier(ladder.tier.rawValue)
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the helper is not available - \(reason, privacy: .public)"
            )
            return
        }
        helperDeployment = deployment
        helperNote = nil

        guard let root = try? await runtime.canonicalRoot() else { return }
        let stream = HelperStream(
            locationID: locationID, helperPath: deployment.path, canonicalRoot: root,
            directory: deployment.directory,
            onEvents: { [weak self] events in await self?.handleHelperEvents(events) },
            onDeath: { [weak self] reason in await self?.helperDied(reason) })
        do {
            try await stream.start(master: connection.master, roots: await currentHelperRoots())
            helper = stream
            await runtime.setWatchTier(ladder.tier.rawValue)
            // The stream starts watching *now*, and everything that changed on the server
            // before it did is invisible to it. That is exactly the case section 6.4's
            // reconnect sweep exists for, so one is asked for here rather than assumed.
            requestFullSweep(reason: "the helper stream started")
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            helperNote = reason
            // A stream that would not start on a shell that answered is a runtime failure
            // of the tier, and section 6.4 drops the location one tier down for the rest of
            // the session when that happens.
            if ladder.recordRuntimeFailure(reason: reason, now: Date().timeIntervalSince1970) {
                await runtime.setWatchTier(ladder.tier.rawValue)
                Log.agent.error(
                    "\(self.locationID, privacy: .public): the helper would not start (\(reason, privacy: .public)); dropping to \(self.ladder.tier.rawValue, privacy: .public) for this session"
                )
            }
        }
    }

    private func currentHelperRoots() async -> HelperStream.Roots {
        guard let set = try? await runtime.currentRootSet() else { return HelperStream.Roots() }
        let split = set.sweepRoots()
        let excluded = (try? await runtime.excludedSweepPaths()) ?? []
        return HelperStream.Roots(
            shallow: split.shallow, recursive: split.recursive,
            excluded: excluded.map { Data($0.utf8) })
    }

    private func pushRootsToHelper() async {
        guard let helper else { return }
        await helper.updateRoots(await currentHelperRoots())
    }

    /// One batch of NDJSON events, applied to the index and signalled to the system.
    private func handleHelperEvents(_ events: [HelperEvent]) async {
        if events.contains(where: { $0.kind == .overflow }) {
            helperOverflowPending = true
            // An overflow means events were lost, and waiting up to a minute for the next
            // cycle to notice is exactly the window the sweep exists to close.
            requestFullSweep(reason: "the helper reported an overflow")
        }
        let application = await runtime.applyHelperEvents(events)
        guard !application.isEmpty else { return }
        await DomainManager.shared.signalWorkingSet(locationID: locationID)
        var outcome: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "tier": "helper",
            "full": false,
            "reason": "helper events",
            "seconds": 0,
            "changed": application.changed,
            "deleted": application.deleted,
            "held": application.held,
            "released": application.released,
            "directoriesListed": application.listedDirectories,
        ]
        if !application.errors.isEmpty { outcome["errors"] = application.errors }
        lastOutcome = outcome
        await runtime.recordWatchCycle(outcome)
    }

    /// The stream ended. A connection that simply went is not a tier failure - the breaker
    /// brings it back and the next cycle starts a new stream - but a helper that died with
    /// the connection up is, and section 6.4 costs the location a tier for the session.
    private func helperDied(_ reason: String) async {
        helper = nil
        helperNote = reason
        let connected = await runtime.isConnected()
        guard connected else {
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the helper stream ended with the connection; it restarts on the next cycle"
            )
            return
        }
        if ladder.recordRuntimeFailure(reason: reason, now: Date().timeIntervalSince1970) {
            await runtime.setWatchTier(ladder.tier.rawValue)
            requestFullSweep(reason: "the helper stream died")
            Log.agent.error(
                "\(self.locationID, privacy: .public): dropping to \(self.ladder.tier.rawValue, privacy: .public) for this session"
            )
        }
    }

    /// `sshdrive set <name> helper off`, and `sshdrive remove`: stop the stream and take
    /// the binary off the server (sections 6.4, 8).
    func shutDownHelper(removeFromServer: Bool) async -> [String] {
        let stream = helper
        helper = nil
        await stream?.stop()
        guard removeFromServer, let connection = await runtime.liveConnection() else { return [] }
        return await HelperDeployer.remove(connection: connection, locationID: locationID)
    }

    func helperReport() async -> [String: Any]? {
        guard let helper else {
            guard let note = helperNote else { return nil }
            return ["state": "not running", "reason": note]
        }
        var out = await helper.report()
        if let deployment = helperDeployment {
            out["verifiedBy"] = deployment.verifiedBy
            out["uploadedThisConnection"] = deployment.uploaded
            if !deployment.removedStale.isEmpty { out["removedStale"] = deployment.removedStale }
        }
        return out
    }

    /// A connection that is simply down is not a tier failure: the breaker will bring it
    /// back and the reconnect runs a full sweep of its own (section 6.3). Only a shell
    /// that answered and could not do the job drops the tier.
    private func isTransportOutage(_ error: Error) -> Bool {
        if let failure = error as? RemoteSweep.Failure, case .noExecChannel = failure { return true }
        if error is SFTPError { return true }
        return false
    }

    private func runSweep(full: Bool) async throws -> LocationRuntime.ChangeApplication {
        guard await runtime.allowsExecChannel(), let master = await runtime.execMaster() else {
            throw RemoteSweep.Failure.noExecChannel("the location is offline")
        }
        let probe = await runtime.probeForSweep()
        let set = try await runtime.currentRootSet()
        let split = set.sweepRoots()

        // A root whose bytes are not valid UTF-8 cannot travel through `set --`, which is
        // a String pipeline end to end (section 9.2). It is listed at tier 0 in the same
        // cycle instead, so it is watched rather than dropped; nothing about the sweep is
        // weakened for the rest of the tree (2026-09-04, section 13).
        let shallow = split.shallow.compactMap(LocationRuntime.utf8Root)
        let recursive = split.recursive.compactMap(LocationRuntime.utf8Root)
        let awkward = (split.shallow + split.recursive).filter { LocationRuntime.utf8Root($0) == nil }

        // The window is elapsed time on **our** clock applied to the **server's** stamp,
        // never the Mac's wall clock measured against a server timestamp: the second form
        // folds the whole clock difference into the window, and a server a few minutes
        // behind would then be swept with a window of nothing (section 6.4).
        let stored = await runtime.sweepServerTime()
        let takenAt = await runtime.sweepServerTimeTakenAt() ?? Date().timeIntervalSince1970
        let elapsed = max(0, Date().timeIntervalSince1970 - takenAt)
        let serverNow = (stored ?? 0) + Int64(elapsed.rounded(.up))
        let window = SweepWindow.compute(
            lastAppliedServerTime: stored.map { $0 + clockSkewSeconds },
            serverNow: serverNow, full: full)

        let flavour: FindFlavour
        switch probe?.findFlavour {
        case "gnu": flavour = .gnu
        case "busybox": flavour = .busybox
        default: flavour = .bsd
        }
        // Section 7.1.1: "the recursive watch of kept subtrees skips excluded subtrees",
        // which at tier 1 is `find`'s own `-path <glob> -prune`. Only exclusions that
        // really sit inside a pinned subtree are sent: one outside a pin prunes nothing
        // and would only lengthen the argv.
        let excluded = (try? await runtime.excludedSweepPaths()) ?? []
        let plan = SweepPlan(
            shallowRoots: shallow, recursiveRoots: recursive, excluded: excluded,
            flavour: flavour,
            takesCmin: probe?.findTakesCmin ?? false,
            takesPrintf: probe?.findTakesPrintf ?? false,
            windowMinutes: full && stored == nil ? nil : window.minutes)

        let root = try await runtime.canonicalRoot()
        let outcome = try await RemoteSweep.run(
            master: master, canonicalRoot: root, plan: plan,
            timeout: full ? 900 : 300)

        var application = await runtime.applySweepHits(outcome.hits)
        // "the agent stores it once the sweep's results have been applied to the index,
        // never before" (section 6.4). A truncated sweep stores nothing, so the next
        // window still covers what this one missed.
        if let serverTime = outcome.serverTime, !outcome.truncated {
            await runtime.setSweepServerTime(serverTime)
        }
        for path in awkward {
            application.absorb(await runtime.listOne(path))
        }
        return application
    }

    // MARK: Status (section 8.1)

    func status() async -> [String: Any] {
        var out: [String: Any] = [
            "tier": ladder.tier.rawValue,
            "watchMode": watchMode.rawValue,
            "cycles": cycles,
            "intervalSeconds": PollSchedule.interval(
                lastTouch: lastTouch, now: Date().timeIntervalSince1970),
            "active": PollSchedule.isActive(lastTouch: lastTouch, now: Date().timeIntervalSince1970),
            "sweepUsesMmin": ladder.sweepUsesMmin,
            "paused": paused,
        ]
        if let note = ladder.note { out["note"] = note }
        if let note = helperNote, ladder.note == nil { out["note"] = note }
        if clockSkewSeconds != 0 { out["clockSkewSeconds"] = clockSkewSeconds }
        if !ladder.downgrades.isEmpty {
            out["downgrades"] = ladder.downgrades.map {
                ["from": $0.from.rawValue, "to": $0.to.rawValue, "reason": $0.reason, "at": $0.at]
                    as [String: Any]
            }
        }
        if !lastOutcome.isEmpty { out["lastCycle"] = lastOutcome }
        if let helper = await helperReport() { out["helper"] = helper }
        return out
    }

    func currentTier() -> ChangeDetectionLadder.Tier { ladder.tier }
}
