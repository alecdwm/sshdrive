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
public actor ChangeDetector {
    /// How often `settleHelper` looks again while `add` is waiting. On the injected
    /// clock, so the wait is bounded in model time and costs a scenario nothing (`P9`).
    public static let settlePollSeconds: Double = 0.1

    public let locationID: String
    private let runtime: LocationRuntime
    private let environment: AgentEnvironment
    private var ladder: ChangeDetectionLadder
    private var watchMode: WatchMode

    private var loop: Task<Void, Never>?
    /// The loop's current sleep, so a transient hold can end it early (`nudge`).
    private var sleeper: Task<Void, Never>?
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
    /// How long the last cycle took. A cycle that consumed most of its own interval backs
    /// the schedule off (section 6.4, 2026-09-05).
    private var lastCycleSeconds: Double = 0
    /// Set by an `overflow` event: section 6.4 answers one with a sweep.
    private var helperOverflowPending = false
    /// Serialises `ensureHelper` against itself, since a cycle and a reconnect can both
    /// ask for it.
    private var helperStarting = false

    public init(locationID: String, runtime: LocationRuntime, location: Location,
         capabilities: ChangeDetectionLadder.ServerCapabilities,
         environment: AgentEnvironment = .unconfigured,
         now: Double = Date().timeIntervalSince1970) {
        self.locationID = locationID
        self.runtime = runtime
        self.environment = environment
        self.watchMode = location.watchMode
        self.ladder = ChangeDetectionLadder(
            watchMode: location.watchMode, capabilities: capabilities, now: now)
    }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.secondsUntilNextCycle()
                if wait > 0 {
                    await self.sleepBeforeNextCycle(seconds: min(wait, 60))
                    continue
                }
                _ = await self.runCycle()
            }
        }
        Log.agent.notice(
            "\(self.locationID, privacy: .public): change detection started at tier \(self.ladder.tier.rawValue, privacy: .public)"
        )
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
        let stream = helper
        helper = nil
        Task { await stream?.stop() }
    }

    /// The loop's sleep, held where `nudge()` can cancel it.
    private func sleepBeforeNextCycle(seconds: Double) async {
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        sleeper = task
        await task.value
        sleeper = nil
    }

    /// Ends the loop's current sleep so the schedule is re-read now.
    ///
    /// A transient tier hold is two seconds, and the loop is normally asleep for the rest
    /// of a 60 s (or 10 min) poll interval when one is recorded. Without this the climb
    /// back to tier 2 was measured at 21 s after a 2 s hold - the backoff was right and
    /// nothing was awake to act on it (2026-09-08).
    private func nudge() {
        sleeper?.cancel()
        sleeper = nil
    }

    private func secondsUntilNextCycle(now: Double = Date().timeIntervalSince1970) -> Double {
        guard !paused else { return 5 }
        var due = PollSchedule.nextFire(
            lastCycle: lastCycle, lastTouch: lastTouch, now: now,
            lastCycleSeconds: lastCycleSeconds)
        // A transient downgrade is held for seconds, not for a poll interval, so the loop
        // wakes when the hold expires rather than at the next 60 s (or 10 min) boundary.
        // Without this the 2 s backoff would be read as "some time in the next ten
        // minutes", which is the delay the fix exists to remove (2026-09-08).
        if let expires = ladder.transientHoldExpiresAt { due = min(due, expires) }
        return max(0, due - now)
    }

    // MARK: Triggers

    /// Section 4.2's touch, reused here for section 6.4's cadence.
    public func noteTouch(now: Double = Date().timeIntervalSince1970) { lastTouch = now }

    /// A reconnect, a returning network path, or the extension handing out a fresh
    /// working-set anchor. Every one of them is "run one full sweep at once" (sections
    /// 6.4, 5.3).
    public func requestFullSweep(reason: String) {
        fullSweepPending = true
        fullSweepReason = reason
    }

    /// The connection came up. Called by `DomainManager` from the gate's connected hook,
    /// **after** `LocationRuntime.applyConnection` has re-derived the identity, the channel
    /// budget and the SFTP channels, because the helper's exec channel is opened on the
    /// same master those channels sit on and a stream started before them would be started
    /// on the connection that is going away.
    ///
    /// Section 6.4 says the helper's stream is per connection, so a reconnect is exactly
    /// when it has to be re-opened. It used to be left to the next poll cycle, which is up
    /// to 60 s away on a touched location and up to 10 min on an idle one - and on a
    /// location a transient failure had dropped to sweep, never (2026-09-08).
    public func connectionCameUp() async {
        let now = Date().timeIntervalSince1970
        if ladder.noteConnected(now: now) {
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the connection is back; climbing to \(self.ladder.tier.rawValue, privacy: .public)"
            )
            await runtime.setWatchTier(ladder.tier.rawValue)
        }
        // The stream that died with the old connection is not reusable, whatever it still
        // says about itself.
        if let helper {
            self.helper = nil
            await helper.stop()
        }
        requestFullSweep(reason: "reconnect")
        guard ladder.tier == .helper else { return }
        // Started on this actor but not awaited by the caller: `DomainManager` is the
        // agent's serialisation point and every File Provider request passes through it,
        // while a deployment plus the helper's `ready` handshake is seconds of remote work
        // with a 20 s deadline behind it. The detector is an actor, so this still runs
        // after everything above, and `helperStarting` keeps it single.
        Task { [weak self] in await self?.ensureHelper() }
    }

    /// The connection went away. The stream went with it; nothing is a tier failure here,
    /// because the reconnect of section 6.3 is what answers an outage.
    public func connectionWentAway(reason: String) async {
        guard let helper else { return }
        self.helper = nil
        await helper.stop()
        helperNote = "the connection went away (\(reason)); the stream restarts on reconnect"
    }

    /// A new connection may be a different server: a NAS that came back with a busybox
    /// `find` where there was GNU, or an account that lost its shell.
    public func applyCapabilities(
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
    public func materializedChanged() async {
        let identifiers = await environment.replica.materializedIdentifiers(
            locationID: locationID)
        await materializedChanged(identifiers: identifiers)
    }

    /// The same, with the enumeration already made. `DomainManager` walks the replica once
    /// and gives the answer to the root set and to section 7.2's safety net together.
    public func materializedChanged(identifiers: [String]?) async {
        // Published for `sshdrive status`, which needs the same set for its Cache and Pins
        // lines and has no business draining the replica a third time (section 8.1).
        runtime.materialized.record(identifiers, at: environment.clock.now())
        _ = try? await runtime.refreshRootSet(materializedIdentifiers: identifiers)
    }

    public func setClockSkew(seconds: Int64) { clockSkewSeconds = seconds }
    public func setPaused(_ value: Bool) { paused = value }

    // MARK: One cycle

    @discardableResult
    public func runCycle(forceFull: Bool = false, now: Double = Date().timeIntervalSince1970) async
        -> LocationRuntime.ChangeApplication
    {
        guard !cycleInProgress else { return LocationRuntime.ChangeApplication() }
        cycleInProgress = true
        defer { cycleInProgress = false; lastCycle = Date().timeIntervalSince1970 }

        // A transient failure holds the tier down for a bounded backoff and no longer; the
        // cycle is where the hold is noticed to have expired (section 6.4, 2026-09-08).
        if ladder.climbBack(now: now) {
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the transient failure has expired; climbing back to \(self.ladder.tier.rawValue, privacy: .public)"
            )
            await runtime.setWatchTier(ladder.tier.rawValue)
        }
        // A tier that has been running long enough to be believed forgets the failures
        // that preceded it, so the next backoff starts at 2 s again.
        if let started = await helper?.startedAt,
            now - started >= ChangeDetectionLadder.stabilitySeconds
        {
            ladder.noteTierHealthy(now: now)
        }

        var full = forceFull || fullSweepPending
        var reason = full ? fullSweepReason : "cycle"
        // "a sweep still runs every 30 min as insurance against missed events."
        if !full, PollSchedule.insuranceDue(lastFullSweep: await runtime.lastFullSweep(), now: now) {
            full = true
            reason = "30-minute insurance sweep"
        }
        // The cycle's own stopwatch. `environment.clock` rather than `Date()` because a
        // cycle's duration is what paces the next interval (section 6.4), and a scenario
        // that asserts the pacing has to be able to make a cycle take 56.8 s without
        // taking 56.8 s (`H10`). `SystemAgentClock.now()` *is* `Date().timeIntervalSince1970`,
        // so nothing about a shipping agent changes.
        let started = environment.clock.now()

        // Section 6.4's guard needs the pending set, and section 6.5's root set needs the
        // materialized one. Both are the system's answers, taken before anything is listed.
        let pendingIdentifiers = await environment.replica.pendingIdentifiers(
            locationID: locationID)
        let materialized = await environment.replica.materializedIdentifiers(
            locationID: locationID)
        runtime.materialized.record(materialized, at: environment.clock.now())
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
                    // `find` missing or unusable is about the server, not about the link.
                    ladder.recordRuntimeFailure(reason: text, permanence: .permanent, now: now)
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
            await environment.replica.signalWorkingSet(locationID: locationID)
        }

        var outcome: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "tier": tierUsed.rawValue,
            "full": full,
            "reason": reason,
            "seconds": environment.clock.now() - started,
            "changed": application.changed,
            "deleted": application.deleted,
            "held": application.held,
            "released": application.released,
            "directoriesListed": application.listedDirectories,
        ]
        if let sweepNote { outcome["note"] = sweepNote }
        if !application.errors.isEmpty { outcome["errors"] = application.errors }
        lastOutcome = outcome
        // Only a cycle that actually went to the server paces the schedule; a tier-2 cycle
        // that did nothing but refresh the root set is not evidence of a slow server.
        if PollSchedule.paces(handledByHelper: handledByHelper, ranFullSweep: full) {
            lastCycleSeconds = environment.clock.now() - started
        }
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
            let now = Date().timeIntervalSince1970
            guard ChangeDetector.permanence(of: error) == .permanent else {
                // A deployment that met a dying connection says nothing about the server,
                // and writing it into the capabilities would keep the helper refused on
                // every later connect until something re-probed (2026-09-08). Hold the
                // tier for the backoff instead and try again.
                ladder.recordRuntimeFailure(reason: reason, permanence: .transient, now: now)
                await runtime.setWatchTier(ladder.tier.rawValue)
                nudge()
                Log.agent.notice(
                    "\(self.locationID, privacy: .public): the helper could not be deployed this time - \(reason, privacy: .public); retrying in \(Int(self.ladder.retryBackoffSeconds), privacy: .public) s"
                )
                return
            }
            var capabilities = ladder.capabilities
            capabilities.helperAvailable = false
            capabilities.helperBlockReason = reason
            ladder.applyCapabilities(capabilities, watchMode: watchMode, now: now)
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
            guard let master = connection.execMaster else {
                throw RemoteSweep.Failure.noExecChannel("the location has no exec channel")
            }
            try await stream.start(master: master, roots: await currentHelperRoots())
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
            // of the tier. Whether it costs the location the tier for the session or only
            // for a bounded backoff is section 6.4's permanent list, not the fact that it
            // failed: a `ready` line that never arrived because the channel died is an
            // outage, and an outage is not a verdict (2026-09-08).
            let permanence = ChangeDetector.permanence(of: error)
            if ladder.recordRuntimeFailure(
                reason: reason, permanence: permanence, now: Date().timeIntervalSince1970)
            {
                await runtime.setWatchTier(ladder.tier.rawValue)
                if permanence == .transient { nudge() }
                Log.agent.notice(
                    "\(self.locationID, privacy: .public): the helper would not start (\(reason, privacy: .public)); dropping to \(self.ladder.tier.rawValue, privacy: .public) \(permanence == .permanent ? "for this session" : "for \(Int(self.ladder.retryBackoffSeconds)) s", privacy: .public)"
                )
            }
        }
    }

    /// What `sshdrive add` waits for: the first deployment attempt, settled.
    ///
    /// `add` prints one capability report and the user reads it as the truth about this
    /// server (section 8.1), so it must not be written in the window between the ladder
    /// choosing tier 2 and the binary arriving. Bounded by `HelperSettle`: a server that
    /// never answers costs `add` a few seconds, and the report then says `deploying`
    /// rather than blaming the server (2026-09-05).
    ///
    /// The elapsed time and the poll interval are both the injected clock's (`P9`), so
    /// the bound is a value a scenario can drive rather than six real seconds in a test
    /// suite: `SQ-077` says the deployment and its stream end with the connection, which
    /// is precisely the case where nothing settles and this has to give up.
    @discardableResult
    public func settleHelper(timeout: TimeInterval = HelperSettle.addSeconds) async -> Bool {
        let clock = environment.clock
        let started = clock.now()
        while true {
            var running = false
            if let helper { running = await helper.state == .running }
            let step = HelperSettle.step(
                tierIsHelper: ladder.tier == .helper, streamRunning: running,
                refusal: helperNote, elapsed: clock.now() - started,
                timeout: timeout)
            switch step {
            case .done: return running
            case .giveUp: return false
            case .wait:
                if !helperStarting { await ensureHelper() }
                await clock.sleep(seconds: ChangeDetector.settlePollSeconds)
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
        // At the default level, so `log show` still has it hours later. A mount that
        // takes no server-side change is diagnosed by two facts - did the events arrive,
        // and did applying them change anything - and neither used to be recorded at all
        // (2026-09-08).
        let kinds = Dictionary(grouping: events, by: { $0.kind.rawValue })
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: " ")
        // The 15-second heartbeat is the one kind that carries nothing. Logging it at the
        // default level would put four lines a minute per location into everyone's log
        // for ever, and drown the lines that matter.
        let worthLogging = events.contains { $0.kind != .heartbeat }
        let application = await runtime.applyHelperEvents(events)
        if worthLogging {
            Log.agent.notice(
                "\(self.locationID, privacy: .public): applied \(events.count, privacy: .public) helper event(s) [\(kinds, privacy: .public)] -> \(application.changed, privacy: .public) changed, \(application.deleted, privacy: .public) deleted, \(application.held, privacy: .public) held, \(application.listedDirectories, privacy: .public) listed"
            )
        }
        guard !application.isEmpty else { return }
        await environment.replica.signalWorkingSet(locationID: locationID)
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
            // The connection is what took it. The gate is already reconnecting on section
            // 6.3's schedule, and `connectionCameUp` starts a new stream the moment it
            // does, so the tier is left where it is.
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the helper stream ended with the connection; it restarts on the reconnect"
            )
            return
        }
        // A stream that died while the connection is still up is a runtime failure of the
        // tier - but a transient one. Section 6.4's permanent list is about the server, and
        // a channel that was killed, a helper that was reaped or a wrapper whose heartbeat
        // lapsed says nothing about whether the server can run one. Before 2026-09-08 this
        // was always permanent, which is how a 90-second network stall left a location at
        // sweep until the agent was restarted.
        let now = Date().timeIntervalSince1970
        if ladder.recordRuntimeFailure(reason: reason, permanence: .transient, now: now) {
            await runtime.setWatchTier(ladder.tier.rawValue)
            requestFullSweep(reason: "the helper stream died")
            nudge()
            Log.agent.notice(
                "\(self.locationID, privacy: .public): dropping to \(self.ladder.tier.rawValue, privacy: .public) for \(Int(self.ladder.retryBackoffSeconds), privacy: .public) s (\(reason, privacy: .public))"
            )
        }
    }

    /// Section 6.4's permanent list, applied to whatever the deployment or the stream
    /// threw. Everything that is not on it - and every transport error, which is an outage
    /// by definition - is transient and is retried on the ladder's bounded backoff.
    public static func permanence(of error: Error) -> ChangeDetectionLadder.Permanence {
        if error is SFTPError { return .transient }
        if let failure = error as? HelperDeployer.Failure {
            return failure.isPermanent ? .permanent : .transient
        }
        return .permanent
    }

    /// `sshdrive set <name> helper off`, and `sshdrive remove`: stop the stream and take
    /// the binary off the server (sections 6.4, 8).
    public func shutDownHelper(removeFromServer: Bool) async -> [String] {
        let stream = helper
        helper = nil
        await stream?.stop()
        guard removeFromServer, let connection = await runtime.liveConnection() else { return [] }
        return await HelperDeployer.remove(connection: connection, locationID: locationID)
    }

    public func helperReport() async -> [String: Any]? {
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
        // `SweepPlan.partitionRoots` is the rule itself (`SQ-055`, `SQ-007`), so the sweep
        // scenarios and the agent make the same split of the same roots.
        let partition = SweepPlan.partitionRoots(
            shallow: split.shallow, recursive: split.recursive)
        let shallow = partition.shallow
        let recursive = partition.recursive
        let awkward = partition.tierZero

        // The window is elapsed time on **our** clock applied to the **server's** stamp,
        // never the Mac's wall clock measured against a server timestamp: the second form
        // folds the whole clock difference into the window, and a server a few minutes
        // behind would then be swept with a window of nothing (section 6.4). The
        // arithmetic is `SweepWindow.forCycle`'s, where `H4` exercises it.
        let stored = await runtime.sweepServerTime()
        let takenAt = await runtime.sweepServerTimeTakenAt()
        let window = SweepWindow.forCycle(
            lastAppliedServerTime: stored, takenAt: takenAt,
            now: Date().timeIntervalSince1970,
            clockSkewSeconds: clockSkewSeconds, full: full)

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

    /// `now` is a parameter so a scenario can ask what the schedule says at a moment of
    /// its choosing - eleven minutes after the last touch, say - rather than living
    /// through it (`H9`, `H10`). Every caller in the agent takes the default.
    public func status(now: Double = Date().timeIntervalSince1970) async -> [String: Any] {
        var out: [String: Any] = [
            "tier": ladder.tier.rawValue,
            "watchMode": watchMode.rawValue,
            "cycles": cycles,
            "intervalSeconds": PollSchedule.interval(
                lastTouch: lastTouch, now: now,
                lastCycleSeconds: lastCycleSeconds),
            "active": PollSchedule.isActive(lastTouch: lastTouch, now: now),
            "sweepUsesMmin": ladder.sweepUsesMmin,
            "paused": paused,
        ]
        if let backoff = PollSchedule.backoffNote(
            lastTouch: lastTouch, now: now,
            lastCycleSeconds: lastCycleSeconds)
        {
            out["intervalNote"] = backoff
        }
        if let note = ladder.note { out["note"] = note }
        if let note = helperNote, ladder.note == nil { out["note"] = note }
        // Section 6.4's climb-back, so `status` says a downgrade is temporary and when it
        // ends rather than reading as a verdict (2026-09-08).
        if let expires = ladder.transientHoldExpiresAt {
            let remaining = max(0, (expires - now).rounded(.up))
            out["retryingHigherTierInSeconds"] = remaining
            // The note the failure wrote counted down from the moment it happened; what a
            // reader wants is the countdown from now.
            if let note = ladder.note, let cut = note.range(of: "; retrying in") {
                out["note"] = String(note[..<cut.lowerBound]) + "; retrying in \(Int(remaining)) s"
            }
        }
        if clockSkewSeconds != 0 { out["clockSkewSeconds"] = clockSkewSeconds }
        if !ladder.downgrades.isEmpty {
            out["downgrades"] = ladder.downgrades.map {
                [
                    "from": $0.from.rawValue, "to": $0.to.rawValue, "reason": $0.reason,
                    "at": $0.at, "permanence": $0.permanence.rawValue,
                ] as [String: Any]
            }
        }
        if !lastOutcome.isEmpty { out["lastCycle"] = lastOutcome }
        if let helper = await helperReport() { out["helper"] = helper }
        return out
    }

    public func currentTier() -> ChangeDetectionLadder.Tier { ladder.tier }
}
