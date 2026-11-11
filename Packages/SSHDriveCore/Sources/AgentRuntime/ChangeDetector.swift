import Foundation
import AgentCore
import Config
import Index
import Logging
import SFTP
import SSHProcess

/// One location's change detection: the poll cadence, the tier ladder, and the cycle that
/// tiers 0 and 1 share (docs/design/change-detection.md).
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
    /// The cadence: every 60 s while the user has touched the domain in the last 10
    /// minutes, every 10 min otherwise. A touch is a File Provider request that was not a
    /// system request, or a CLI command naming the location.
    private var lastTouch: Double?
    private var lastCycle: Double = 0
    private var cycles = 0
    /// Set by a reconnect, a returning network path, a fresh working-set anchor, and the
    /// 30-minute insurance pass. On reconnect after any outage every tier first runs one
    /// full sweep, so changes made while disconnected are caught.
    private var fullSweepPending = true
    private var fullSweepReason = "first cycle"
    private var lastOutcome: [String: Any] = [:]
    private var cycleInProgress = false
    /// Set by `requestCycleNow`: the next loop turn runs a cycle at once.
    private var cycleRequested = false

    /// `sshdrive debug watch --clock-skew <seconds>`: shifts the sweep's own reference,
    /// which is the only way to exercise the sweep's server-clock window from a
    /// container that shares the host's clock (testbed/README.md). Applied to the stored
    /// timestamp, never to what the server said, so what is under test is the window the
    /// agent computes rather than the value it reads.
    private var clockSkewSeconds: Int64 = 0
    /// `sshdrive debug watch --pause`: stops the loop without stopping the location, so
    /// single cycles can be driven by hand.
    private var paused = false

    // MARK: Tier 2

    /// The live stream, or nil while the location is not at tier 2. Owned here rather than
    /// by `LocationRuntime` for the same reason the detector is: the runtime serialises
    /// behind the index, and a stream that lived there would hold it open.
    private var helper: HelperStream?
    /// What the last deployment did, for `status`.
    private var helperDeployment: HelperDeployer.Deployment?
    /// Why the helper is not running, when the ladder needs to say so.
    private var helperNote: String?
    /// How long the last cycle took. A cycle that consumed most of its own interval backs
    /// the schedule off.
    private var lastCycleSeconds: Double = 0
    /// Consecutive sweep timeouts, and the cycles that poll instead while they last.
    private var sweepBackoff = SweepTimeoutBackoff()
    /// Set by an `overflow` event, which is answered with a sweep.
    private var helperOverflowPending = false
    /// Serialises `ensureHelper` against itself, since a cycle, a reconnect and `add`'s
    /// settle can all ask for it. Set before the first suspension, so two callers can
    /// never both get past it: one stream per connection.
    private var helperStarting = false
    /// A reconnect asked for a stream while an attempt was already in flight. That
    /// attempt may be running on the connection that just went, so `ensureHelper` makes
    /// one more pass when it finishes.
    private var helperRestartRequested = false
    /// The stream `ensureHelper` is starting, so a reconnect or `stop()` can end its wait
    /// for `ready` on a connection that is no longer the one that matters.
    private var startingStream: HelperStream?
    /// Which stream `helper` is, so a death reported by one that has since been replaced
    /// is not taken for the running one's.
    private var streamSerial = 0
    private var helperSerial = 0
    /// Bumped by `stop()`. An attempt that was in flight when the detector stopped
    /// stops its stream rather than installing it; a scenario that stops the loop and
    /// then drives cycles by hand still starts streams of its own.
    private var stopCount = 0

    public init(locationID: String, runtime: LocationRuntime, location: Location,
         capabilities: ChangeDetectionLadder.ServerCapabilities,
         environment: AgentEnvironment = .unconfigured,
         now: Double? = nil) {
        self.locationID = locationID
        self.runtime = runtime
        self.environment = environment
        self.watchMode = location.watchMode
        self.ladder = ChangeDetectionLadder(
            watchMode: location.watchMode, capabilities: capabilities,
            now: now ?? environment.clock.now())
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

    /// Cancels the loop and returns when the cycle it was running has finished.
    ///
    /// The wait is the point. `Task.cancel()` only asks, and a cycle already inside
    /// `runCycle` keeps listing, keeps writing rows and keeps calling the transport -
    /// which `DomainManager.dropRuntime` shuts down on the next line, and which a
    /// scenario has often just dropped. A cycle that outlives the call re-connects a gate
    /// a scenario has put into its backoff, and the stray attempt takes the one the
    /// scenario is measuring.
    public func stop() async {
        stopCount += 1
        let running = loop
        loop = nil
        running?.cancel()
        sleeper?.cancel()
        sleeper = nil
        let stream = helper
        let starting = startingStream
        helper = nil
        startingStream = nil
        Task {
            await stream?.stop()
            await starting?.stop()
        }
        await running?.value
    }

    /// The loop's sleep, held where `nudge()` can cancel it. A cancelled sleep on the
    /// agent's clock returns at once.
    private func sleepBeforeNextCycle(seconds: Double) async {
        let clock = environment.clock
        let task = Task<Void, Never> {
            await clock.sleep(seconds: seconds)
        }
        sleeper = task
        await task.value
        sleeper = nil
    }

    /// Ends the loop's current sleep so the schedule is re-read now.
    ///
    /// A transient tier hold is two seconds, and the loop is normally asleep for the rest
    /// of a 60 s (or 10 min) poll interval when one is recorded. Without this the backoff
    /// is right and nothing is awake to act on it: a 2 s hold measured 21 s of climb back
    /// to tier 2.
    private func nudge() {
        sleeper?.cancel()
        sleeper = nil
    }

    /// Makes the loop run a cycle as soon as it is awake, whatever the schedule says.
    private func requestCycleNow() {
        cycleRequested = true
        nudge()
    }

    private func secondsUntilNextCycle(now: Double? = nil) -> Double {
        guard !paused else { return 5 }
        if cycleRequested { return 0 }
        let now = now ?? environment.clock.now()
        var due = PollSchedule.nextFire(
            lastCycle: lastCycle, lastTouch: lastTouch, now: now,
            lastCycleSeconds: lastCycleSeconds)
        // A transient downgrade is held for seconds, not for a poll interval, so the loop
        // wakes when the hold expires rather than at the next 60 s (or 10 min) boundary.
        // Without this the 2 s backoff would be read as "some time in the next ten
        // minutes". A permanent one is decided again after 30 minutes, on the same rule.
        if let expires = ladder.nextClimbBackAt { due = min(due, expires) }
        return max(0, due - now)
    }

    // MARK: Triggers

    /// Records a touch, which is what paces the poll cadence.
    public func noteTouch(now: Double? = nil) { lastTouch = now ?? environment.clock.now() }

    /// A reconnect, a returning network path, or the extension handing out a fresh
    /// working-set anchor. Every one of them means "run one full sweep at once".
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
    /// The helper's stream is per connection, so the reconnect is exactly when it has to
    /// be re-opened. Leaving it to the next poll cycle would be up to 60 s away on a
    /// touched location and up to 10 min on an idle one, and on a location a transient
    /// failure had dropped to sweep, never.
    public func connectionCameUp() async {
        let now = environment.clock.now()
        if ladder.noteConnected(now: now) {
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the connection is back; climbing to \(self.ladder.tier.rawValue, privacy: .public)"
            )
            await runtime.setWatchTier(ladder.tier.rawValue)
        }
        // The stream that died with the old connection is not reusable, whatever it still
        // says about itself, and an attempt still waiting for `ready` on it is ended now
        // rather than at its deadline.
        await dropStreams()
        requestFullSweep(reason: "reconnect")
        guard ladder.tier == .helper else { return }
        // Started on this actor but not awaited by the caller: `DomainManager` is the
        // agent's serialisation point and every File Provider request passes through it,
        // while a deployment plus the helper's `ready` handshake is seconds of remote work
        // with a 120 s deadline behind it. `helperStarting` keeps it single; an attempt
        // already in flight sees `helperRestartRequested` and makes one more pass on this
        // connection when it finishes.
        helperRestartRequested = true
        Task { [weak self] in await self?.ensureHelper() }
    }

    /// The connection went away. The stream went with it; nothing is a tier failure here,
    /// because the reconnect is what answers an outage.
    public func connectionWentAway(reason: String) async {
        let hadStream = helper != nil || startingStream != nil
        await dropStreams()
        guard hadStream else { return }
        helperNote = "the connection went away (\(reason)); the stream restarts on reconnect"
    }

    /// Stops the running stream and any attempt to start one.
    private func dropStreams() async {
        let running = helper
        let starting = startingStream
        helper = nil
        startingStream = nil
        await running?.stop()
        await starting?.stop()
    }

    /// A new connection may be a different server: a NAS that came back with a busybox
    /// `find` where there was GNU, or an account that lost its shell.
    public func applyCapabilities(
        _ capabilities: ChangeDetectionLadder.ServerCapabilities, watchMode: WatchMode,
        now: Double? = nil
    ) {
        self.watchMode = watchMode
        ladder.applyCapabilities(
            capabilities, watchMode: watchMode, now: now ?? environment.clock.now())
    }

    /// `materializedItemsDidChange` from the extension. The root set's `materialized`
    /// reason comes from `enumeratorForMaterializedItems()`, refreshed on this call, so the
    /// set is rebuilt at once rather than at the next cycle: a file that was just
    /// downloaded should be watched from now, not from up to ten minutes from now.
    public func materializedChanged() async {
        let identifiers = await environment.replica.materializedIdentifiers(
            locationID: locationID)
        await materializedChanged(identifiers: identifiers)
    }

    /// The same, with the enumeration already made. `DomainManager` walks the replica once
    /// and gives the answer to the root set and to the pin re-assert safety net together.
    public func materializedChanged(identifiers: [String]?) async {
        // Published for `sshdrive status`, which needs the same set for its Cache and Pins
        // lines and has no business draining the replica a third time.
        runtime.materialized.record(identifiers, at: environment.clock.now())
        _ = try? await runtime.refreshRootSet(materializedIdentifiers: identifiers)
    }

    public func setClockSkew(seconds: Int64) { clockSkewSeconds = seconds }
    public func setPaused(_ value: Bool) { paused = value }

    // MARK: One cycle

    @discardableResult
    public func runCycle(forceFull: Bool = false, now: Double? = nil) async
        -> LocationRuntime.ChangeApplication
    {
        guard !cycleInProgress else { return LocationRuntime.ChangeApplication() }
        cycleInProgress = true
        cycleRequested = false
        let clock = environment.clock
        defer { cycleInProgress = false; lastCycle = clock.now() }
        let now = now ?? clock.now()

        // A transient failure holds the tier down for a bounded backoff and not beyond
        // it; the cycle is where the hold is noticed to have expired.
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
        // The cycle's own stopwatch, on the agent's clock like every other time here: a
        // cycle's duration is what paces the next interval, and a scenario that asserts
        // the pacing has to be able to make a cycle take 56.8 s without taking 56.8 s
        // (`H10`). Monotonic, so a Mac that slept through a cycle does not read the sleep
        // as a slow server and stretch the interval to the 30-minute cap.
        let started = environment.clock.uptime()

        // The mass-deletion guard needs the pending set, and the root set needs the
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
            // The helper replaces the schedule with events; a sweep still runs every
            // 30 min as insurance against missed events. So an ordinary cycle
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
        // tier it is nominally running.
        if !handledByHelper, ladder.tier >= .sweep, ladder.capabilities.hasFind,
            sweepBackoff.skipsSweep(now: now)
        {
            let until = Int(((sweepBackoff.skipUntil ?? now) - now).rounded(.up))
            sweepNote =
                "\(sweepBackoff.consecutiveTimeouts) sweep(s) in a row timed out; polling for another \(until) s"
            application = await runtime.runPollCycle(fullSweep: full, now: now)
            tierUsed = .poll
        } else if !handledByHelper, ladder.tier >= .sweep, ladder.capabilities.hasFind {
            let standingIn = ladder.tier == .helper
            do {
                application = try await runSweep(full: full)
                sweepBackoff.sweepCompleted()
            } catch {
                if case RemoteSweep.Failure.timedOut = error {
                    sweepBackoff.sweepTimedOut(
                        now: environment.clock.now(),
                        interval: PollSchedule.interval(
                            lastTouch: lastTouch, now: now,
                            lastCycleSeconds: environment.clock.uptime() - started))
                }
                let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if !standingIn, ChangeDetector.permanence(of: error) == .permanent {
                    // The account has no shell after all: a fact about the server, held for
                    // this connection.
                    ladder.recordRuntimeFailure(reason: text, permanence: .permanent, now: now)
                    await runtime.setWatchTier(ladder.tier.rawValue)
                    Log.agent.error(
                        "\(self.locationID, privacy: .public): the sweep failed (\(text, privacy: .public)); dropping to \(self.ladder.tier.rawValue, privacy: .public) for this connection"
                    )
                } else {
                    // Everything else costs this cycle and nothing more: the cycle falls
                    // back to a poll and the next one sweeps again, on a schedule the
                    // cycle's own duration paces. A sweep standing in for a helper that
                    // is being restarted never costs the helper tier, whatever it met.
                    sweepNote = "the sweep could not run this cycle: \(text)"
                    Log.agent.notice(
                        "\(self.locationID, privacy: .public): \(sweepNote!, privacy: .public)")
                }
                application = await runtime.runPollCycle(fullSweep: full, now: now)
                tierUsed = .poll
            }
        } else if !handledByHelper {
            application = await runtime.runPollCycle(fullSweep: full, now: now)
            tierUsed = .poll
        }

        // The re-check schedule for anything the mass-deletion guard is holding.
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
            // system come and read them.
            await environment.replica.signalWorkingSet(locationID: locationID)
        }

        var outcome: [String: Any] = [
            "at": environment.clock.now(),
            "tier": tierUsed.rawValue,
            "full": full,
            "reason": reason,
            "seconds": environment.clock.uptime() - started,
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
            lastCycleSeconds = environment.clock.uptime() - started
        }
        await runtime.recordWatchCycle(outcome)
        return application
    }

    // MARK: Tier 2

    /// Deploys the helper if it is not there, and starts the stream if it is not running.
    ///
    /// Called from every cycle rather than once, because the stream dies with the
    /// connection and the breaker brings the connection back on its own schedule: the
    /// cheapest correct rule is "if the tier is helper and nothing is streaming, start
    /// one", and it costs a comparison on a cycle where it is already up.
    ///
    /// Single by construction: `helperStarting` is taken before anything here waits, so a
    /// cycle, a reconnect and `add`'s settle cannot each start a stream. A reconnect that
    /// lands while an attempt is in flight sets `helperRestartRequested`, and the attempt
    /// makes one more pass when it finishes, on whatever connection is current then.
    private func ensureHelper() async {
        guard !helperStarting else { return }
        helperStarting = true
        defer { helperStarting = false }
        let stops = stopCount
        repeat {
            helperRestartRequested = false
            await startHelperIfNeeded()
        } while helperRestartRequested && stops == stopCount && ladder.tier == .helper
    }

    /// One attempt: deploy, start, and install the stream if the connection it was started
    /// on is still the location's connection.
    private func startHelperIfNeeded() async {
        guard ladder.tier == .helper else { return }
        let stops = stopCount
        if let stale = helper {
            if await stale.state == .running { return }
            // A stream that is not running any more is stopped before the next one starts,
            // so nothing of it is left on the connection: one helper per connection.
            if helper === stale { helper = nil }
            await stale.stop()
        }
        // Offline. Not a tier failure and nothing to hold: `connectionCameUp` starts the
        // stream the moment the gate has a connection again.
        guard let connection = await runtime.liveConnection() else { return }
        guard await runtime.allowsExecChannel() else {
            // The ladder offered the helper on capabilities that said there was an exec
            // channel, and the budget says otherwise right now. A retry on the backoff
            // finds out which is true; waiting for the next idle cycle could take ten
            // minutes.
            await holdHelper(reason: "the connection has no exec channel to spare right now")
            return
        }
        // Resolved before the deployment, so a root that is missing for a while (an
        // autofs mount, a locked dataset) costs a retry rather than an upload each time.
        let root: String
        do {
            root = try await runtime.canonicalRoot()
        } catch {
            guard await isCurrent(connection) else { return }
            await holdHelper(reason: "the location root could not be resolved: \(Self.describe(error))")
            return
        }

        let deployment: HelperDeployer.Deployment
        do {
            deployment = try await HelperDeployer.ensureDeployed(
                connection: connection, locationID: locationID, clock: environment.clock)
        } catch {
            // Deployment failures are never fatal: the location continues at the next
            // tier and the status report says why the helper is not running.
            await helperFailed(error, on: connection, what: "deployed")
            return
        }
        helperDeployment = deployment
        helperNote = nil

        streamSerial += 1
        let serial = streamSerial
        let stream = HelperStream(
            locationID: locationID, helperPath: deployment.path, canonicalRoot: root,
            directory: deployment.directory, clock: environment.clock,
            onEvents: { [weak self] events in await self?.handleHelperEvents(events) },
            onDeath: { [weak self] reason in await self?.helperDied(reason, serial: serial) })
        startingStream = stream
        do {
            guard let master = connection.execMaster else {
                throw RemoteSweep.Failure.noExecChannel("the location has no exec channel")
            }
            try await stream.start(master: master, roots: await currentHelperRoots())
        } catch {
            // `dropStreams` or `stop()` ended the wait. That is not a failure of the
            // tier: the connection it was on has gone, and the reconnect asks for the
            // next attempt.
            guard startingStream === stream else { return }
            startingStream = nil
            await helperFailed(error, on: connection, what: "started")
            return
        }
        guard startingStream === stream else {
            await stream.stop()
            return
        }
        startingStream = nil
        // The connection may have been replaced while the helper walked its roots: a
        // stream on a connection that is no longer the location's is stopped, never
        // installed, and the reconnect (or the pass it asked for) starts the real one.
        guard stops == stopCount, await isCurrent(connection) else {
            await stream.stop()
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the helper started on a connection that has since been replaced; stopped it"
            )
            return
        }
        let previous = helper
        helper = stream
        helperSerial = serial
        await previous?.stop()
        await runtime.setWatchTier(ladder.tier.rawValue)
        // The stream starts watching *now*, and everything that changed on the server
        // before it did is invisible to it. That is exactly the case the reconnect
        // sweep exists for, so one is asked for here rather than assumed.
        requestFullSweep(reason: "the helper stream started")
    }

    /// The deployment or the stream failed. On a connection that is no longer current it
    /// says nothing about the server or the tier; otherwise the permanent list decides
    /// what it costs.
    private func helperFailed(_ error: Error, on connection: any LiveConnection, what: String) async {
        let reason = Self.describe(error)
        guard await isCurrent(connection) else {
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the helper could not be \(what, privacy: .public) on a connection that has since gone - \(reason, privacy: .public)"
            )
            return
        }
        guard ChangeDetector.permanence(of: error) == .permanent else {
            await holdHelper(reason: reason)
            return
        }
        helperNote = reason
        ladder.recordRuntimeFailure(
            reason: reason, permanence: .permanent, now: environment.clock.now())
        await runtime.setWatchTier(ladder.tier.rawValue)
        // The loop has to be awake when the 30 minutes are up.
        nudge()
        Log.agent.notice(
            "\(self.locationID, privacy: .public): the helper could not be \(what, privacy: .public) - \(reason, privacy: .public); \(self.ladder.tier.rawValue, privacy: .public) for this connection"
        )
    }

    /// A transient failure of tier 2: the tier is held for the ladder's backoff and the
    /// loop is woken so the retry happens when the hold ends.
    private func holdHelper(reason: String) async {
        helperNote = reason
        if ladder.recordRuntimeFailure(
            reason: reason, permanence: .transient, now: environment.clock.now())
        {
            await runtime.setWatchTier(ladder.tier.rawValue)
        }
        nudge()
        Log.agent.notice(
            "\(self.locationID, privacy: .public): the helper is not running - \(reason, privacy: .public); retrying in \(Int(self.ladder.retryBackoffSeconds), privacy: .public) s"
        )
    }

    /// Whether `connection` is still the location's connection.
    private func isCurrent(_ connection: any LiveConnection) async -> Bool {
        guard let current = await runtime.liveConnection() else { return false }
        return current === connection
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// What `sshdrive add` waits for: the first deployment attempt, settled.
    ///
    /// `add` prints one capability report and the user reads it as the truth about this
    /// server, so it must not be written in the window between the ladder choosing tier 2
    /// and the binary arriving. Bounded by `HelperSettle`: a server that never answers
    /// costs `add` a few seconds, and the report then says `deploying` rather than blaming
    /// the server.
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
        // takes no server-side change is diagnosed by two facts: did the events arrive,
        // and did applying them change anything.
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
            "at": environment.clock.now(),
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
    /// brings it back and the reconnect starts a new stream - but a helper that died with
    /// the connection up is a transient one, held for the ladder's backoff.
    private func helperDied(_ reason: String, serial: Int) async {
        guard serial == helperSerial, helper != nil else { return }
        helper = nil
        helperNote = reason
        let connected = await runtime.isConnected()
        guard connected else {
            // The connection is what took it, so the tier is left where it is and
            // `connectionCameUp` starts a new stream. A master killed abruptly says so to
            // nobody but the channels on it, though, and while the gate still holds it the
            // gate learns of it from the next call that goes through the transport; a
            // cycle now is that call, where waiting for the schedule could leave the
            // location with no detection at all for up to ten minutes. A gate that holds
            // no connection dropped it itself - the will-sleep message, a lost network
            // path, a failed call - and has already decided when to reconnect: a cycle
            // then would only connect against that decision.
            requestFullSweep(reason: "the helper stream ended with the connection")
            if await runtime.liveConnection() != nil { requestCycleNow() }
            Log.agent.notice(
                "\(self.locationID, privacy: .public): the helper stream ended with the connection; it restarts on the reconnect"
            )
            return
        }
        // A stream that died while the connection is still up is a runtime failure of the
        // tier - but a transient one. The permanent list is about the server, and a
        // channel that was killed, a helper that was reaped, a stream that went silent or
        // a wrapper whose heartbeat lapsed says nothing about whether the server can run
        // one.
        let now = environment.clock.now()
        if ladder.recordRuntimeFailure(reason: reason, permanence: .transient, now: now) {
            await runtime.setWatchTier(ladder.tier.rawValue)
            requestFullSweep(reason: "the helper stream died")
            nudge()
            Log.agent.notice(
                "\(self.locationID, privacy: .public): dropping to \(self.ladder.tier.rawValue, privacy: .public) for \(Int(self.ladder.retryBackoffSeconds), privacy: .public) s (\(reason, privacy: .public))"
            )
        }
    }

    /// The permanent list, applied to whatever the deployment, the stream or the sweep
    /// threw. Permanent is a typed fact about the server and nothing else: a deployment
    /// refusal marked permanent, an account with no shell, a sweep failure that says the
    /// same. Everything else - a channel that failed, output that was unusable this time,
    /// a timeout, a stream error, an SFTP error, an error nobody anticipated - is
    /// transient and is retried on the ladder's bounded backoff. A permanent verdict holds
    /// for the connection it was made on (`ChangeDetectionLadder.noteConnected`), and at
    /// most `ChangeDetectionLadder.permanentRecheckSeconds` on one that stays up.
    public static func permanence(of error: Error) -> ChangeDetectionLadder.Permanence {
        if let failure = error as? HelperDeployer.Failure {
            return failure.isPermanent ? .permanent : .transient
        }
        if let failure = error as? SSHProcessError, case .noShellAccess = failure {
            return .permanent
        }
        if let failure = error as? RemoteSweep.Failure, failure.isServerVerdict {
            return .permanent
        }
        return .transient
    }

    /// `sshdrive set <name> helper off`, and `sshdrive remove`: stop the stream and take
    /// the binary off the server.
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

    private func runSweep(full: Bool) async throws -> LocationRuntime.ChangeApplication {
        guard await runtime.allowsExecChannel(), let master = await runtime.execMaster() else {
            throw RemoteSweep.Failure.noExecChannel("the location is offline")
        }
        let probe = await runtime.probeForSweep()
        let set = try await runtime.currentRootSet()
        let split = set.sweepRoots()

        // A root whose bytes are not valid UTF-8 cannot travel through `set --`, which is
        // a String pipeline end to end (docs/design/security.md). It is listed at tier 0
        // in the same cycle instead, so it is watched rather than dropped; nothing about
        // the sweep is weakened for the rest of the tree.
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
        // behind would then be swept with a window of nothing. The
        // arithmetic is `SweepWindow.forCycle`'s, where `H4` exercises it.
        let stored = await runtime.sweepServerTime()
        let takenAt = await runtime.sweepServerTimeTakenAt()
        let window = SweepWindow.forCycle(
            lastAppliedServerTime: stored, takenAt: takenAt,
            now: environment.clock.now(),
            clockSkewSeconds: clockSkewSeconds, full: full)

        let flavour: FindFlavour
        switch probe?.findFlavour {
        case "gnu": flavour = .gnu
        case "busybox": flavour = .busybox
        default: flavour = .bsd
        }
        // The recursive watch of kept subtrees skips excluded subtrees, which at tier 1
        // is `find`'s own `-path <glob> -prune`. Only exclusions that
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
            timeout: full ? 900 : 300, clock: environment.clock)

        var application = await runtime.applySweepHits(outcome.hits)
        // The server time is stored once the sweep's results have been applied to the
        // index, never before. A truncated sweep stores nothing, so the next window still
        // covers what this one missed.
        if let serverTime = outcome.serverTime, !outcome.truncated {
            await runtime.setSweepServerTime(serverTime)
        }
        for path in awkward {
            application.absorb(await runtime.listOne(path))
        }
        return application
    }

    // MARK: Status

    /// `now` is a parameter so a scenario can ask what the schedule says at a moment of
    /// its choosing - eleven minutes after the last touch, say - rather than living
    /// through it (`H9`, `H10`). Every caller in the agent takes the default.
    public func status(now: Double? = nil) async -> [String: Any] {
        let now = now ?? environment.clock.now()
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
        // The climb-back, so `status` says a downgrade is temporary and when it ends
        // rather than reading as a verdict.
        if let expires = ladder.transientHoldExpiresAt {
            let remaining = max(0, (expires - now).rounded(.up))
            out["retryingHigherTierInSeconds"] = remaining
            // The note the failure wrote counted down from the moment it happened; what a
            // reader wants is the countdown from now.
            if let note = ladder.note, let cut = note.range(of: "; retrying in") {
                out["note"] = String(note[..<cut.lowerBound]) + "; retrying in \(Int(remaining)) s"
            }
        }
        // A permanent verdict is decided again when it expires or the next connection
        // comes up, whichever is first; `status` says when the first of those is due.
        if let expires = ladder.permanentHoldExpiresAt {
            out["permanentRecheckInSeconds"] = max(0, (expires - now).rounded(.up))
        }
        if clockSkewSeconds != 0 { out["clockSkewSeconds"] = clockSkewSeconds }
        if !ladder.downgrades.isEmpty {
            // A permanent downgrade that a connection or its 30 minutes have lifted is
            // history, like a transient one, and says so: `lifted` rather than
            // `permanent`, so nothing reads it as a verdict still in force.
            out["downgrades"] = ladder.downgrades.map {
                var entry: [String: Any] = [
                    "from": $0.from.rawValue, "to": $0.to.rawValue, "reason": $0.reason,
                    "at": $0.at,
                    "permanence": $0.liftedAt == nil ? $0.permanence.rawValue : "lifted",
                ]
                if let lifted = $0.liftedAt { entry["liftedAt"] = lifted }
                return entry
            }
        }
        if !lastOutcome.isEmpty { out["lastCycle"] = lastOutcome }
        if let helper = await helperReport() { out["helper"] = helper }
        return out
    }

    public func currentTier() -> ChangeDetectionLadder.Tier { ladder.tier }
}
