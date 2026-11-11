import AgentCore
import AgentRuntime
import Config
import Foundation
import Index
import Logging
import SFTP
import SSHProcess
import ServerModel

/// One agent, one location, one `FakeRemoteHost`, and a driven clock that only moves when
/// the scenario says so (docs/design/testing.md).
///
/// The agent is wired the way `DomainManager.start()` wires it - the system observers, the
/// runtime, the domain, the change detector and the eviction loop - except that the
/// launcher connects through `FakeHostLauncher`, so every connect runs the real
/// `SSHBackedTransport.establish` against the fake server, and the helper's binaries come
/// from a fixture the fake server knows how to run.
///
/// Time is virtual throughout. `run(for:)` advances the clock to each next deadline in
/// turn, never more than `maxStep` at once, and lets everything that woke run to a
/// standstill before the next step. Real time is only a hang guard: a run that does not
/// finish inside its real-time budget throws `Stuck` with the state it stopped in.
///
/// The group container is process-wide (`AgentHarness`), so scenarios using this are
/// serialized, and `tearDown()` must be called at the end of each.
public final class ResilienceHarness: @unchecked Sendable {

    /// A run that did not reach its virtual end inside its real-time budget.
    public struct Stuck: Error, CustomStringConvertible {
        public let description: String
    }

    public let base: AgentHarness
    public let host: FakeRemoteHost
    public let launcher: FakeHostLauncher
    public var clock: VirtualAgentClock { base.clock }
    public var replica: FakeReplica { base.replica }
    public var network: ScriptedNetwork { base.network }
    public var power: ScriptedPower { base.power }
    /// Where the fixture helper lives, or nil for a build that ships none.
    public let helperResources: URL?
    /// The fixture helper's manifest entry, when one ships.
    public let helperBinary: HelperManifest.Binary?

    private let lock = NSLock()
    private var _manager: DomainManager
    private var _location: Location?
    private var _unsettledSteps = 0
    private var probeCounter = 0
    /// Journal entries at or past this index are the scenario's; the ones before are the
    /// seeding, and the C3 probes are taken out by name.
    private var journalStart = 0

    /// The longest single advance. Every parked timer fires at its own deadline whatever
    /// this is; the step only bounds how late a timer can fire whose task had not parked
    /// yet when the step was taken, which `settle()` makes rare.
    public var maxStep: Double = 5
    /// Consecutive quiet windows (`quietWindowNanoseconds` of real time each, with
    /// scheduler turns between) that count as "everything that woke has finished".
    public var quietWindows = 3
    public var quietWindowNanoseconds: UInt64 = 1_000_000
    /// How long one settle may take in real time before the step is taken anyway and
    /// counted in `unsettledSteps`. A step that never settles is a hot loop.
    public var settleTimeoutSeconds: Double = 2

    /// Every line the agent logs while this harness is up, kept out of stderr. A line is
    /// activity for `settle()`, and a failing scenario prints the tail.
    public let log = LogCapture()
    private let statements = Counter()

    /// The prefix of the files `converged()` writes for C3.
    public static let probePrefix = ".resilience-c3-"

    public var manager: DomainManager { lock.withLock { _manager } }
    public var location: Location {
        guard let location = lock.withLock({ _location }) else {
            preconditionFailure("ResilienceHarness.start() has not run")
        }
        return location
    }
    /// Steps that were taken without the system settling first.
    public var unsettledSteps: Int { lock.withLock { _unsettledSteps } }

    /// - Parameters:
    ///   - profile: the server. `.debian` by default: OpenSSH 9.2, GNU `find`,
    ///     `sha256sum`, `Linux aarch64`.
    ///   - shipsHelper: whether this build carries a helper for the server's `uname`.
    ///   - deadlineTick: how often each SFTP client looks for requests past their
    ///     deadline. Five seconds keeps a 20 s request deadline within five seconds of its
    ///     value and lets the clock take five-second steps while a connection is up.
    public init(
        profile: ServerProfile = .debian, shipsHelper: Bool = true,
        clock: VirtualAgentClock = VirtualAgentClock(), deadlineTick: Duration = .seconds(5)
    ) throws {
        let host = FakeRemoteHost(profile: profile, clock: clock)
        let launcher = FakeHostLauncher(host: host, clock: clock, deadlineTick: deadlineTick)
        self.host = host
        self.launcher = launcher
        base = try AgentHarness(clock: clock, containerParent: Self.scratchDirectory) {
            environment in
            environment.launcher = launcher
        }
        base.replica.clock = clock
        _manager = base.manager

        if shipsHelper, let target = HelperTarget(uname: profile.unameSM) {
            let fixture = try Self.helperFixture(target: target)
            helperResources = fixture.directory
            helperBinary = fixture.binary
            host.registerHelperBinary(
                fixture.bytes, version: fixture.version, os: target.os, arch: target.arch)
            base.bundle.helperResourcesURL = fixture.directory
        } else {
            helperResources = nil
            helperBinary = nil
            base.bundle.helperResourcesURL = nil
        }
        // `HelperDeployer` reads the manifest from a process-wide directory that only the
        // bootstrap sets. `tearDown()` puts it back.
        AgentRuntimeBootstrap.install(environment: base.environment)
        log.install()
    }

    // MARK: Bringing the agent up

    /// A small tree on the server (`README.txt`, `notes.txt`, `old.txt` and `docs/` with two
    /// files in it), the location in `config.json`, and the agent brought up
    /// the way `sshdrive add` brings one up: the runtime (which connects), the domain, the
    /// root enumerated as Finder does when the mount opens, and one file opened so the
    /// root is in the root set for the life of the location - a `viewed` root does not
    /// survive an agent restart and a `materialized` one does. Then it runs until the
    /// location is at the best tier the server supports - the helper's stream up, where
    /// it can be - or `within` virtual seconds pass, and answers which.
    @discardableResult
    public func start(
        nickname: String = "nas", agentDependent: Bool = false, within: Double = 120
    ) async throws -> Bool {
        host.makeDirectory("docs")
        host.writeFile("README.txt", text: "hello\n")
        host.writeFile("notes.txt", text: "first draft\n")
        host.writeFile("old.txt", text: "to be deleted\n")
        host.writeFile("docs/a.txt", text: "alpha\n")
        host.writeFile("docs/b.txt", text: "bravo\n")
        journalStart = host.journal.count
        // `add` is made by someone at the Mac. A location that depends on a key agent
        // attempts nothing while the screen is locked, and the harness's default reading
        // is a Mac nobody is at.
        if agentDependent { base.presence.setPresent() }

        let location = try await base.addLocation(
            nickname: nickname, backend: .sftp, host: host.hostName, remotePath: host.root,
            watchMode: .auto, agentDependent: agentDependent)
        lock.withLock { _location = location }
        try await bringUp(enumerate: true)

        let runtime = try await currentRuntime()
        let readme = try await runtime.identifier(forPath: "README.txt").identifier
        replica.setMaterialized([readme], locationID: location.id)
        await manager.materializedItemsChanged(locationID: location.id)
        let wanted = expectedTier
        return try await run(
            until: { [self] in
                if wanted == .helper { return await self.helperIsRunning() }
                return await self.detectorStatus()["tier"] as? String == wanted.rawValue
            },
            within: within)
    }

    /// `DomainManager.start()`'s per-location body, plus the observers. With `enumerate`
    /// the root is listed as Finder lists it when the mount first opens; a restarted agent
    /// gets no such listing, because a folder is enumerated once ever.
    private func bringUp(enumerate: Bool) async throws {
        let manager = self.manager
        let location = self.location
        await manager.installSystemObservers()
        try await perform("bringing the location up") {
            let runtime = try await manager.runtime(for: location)
            if enumerate {
                manager.noteFileProviderRequest(
                    domainIdentifier: location.id, method: "enumerateItems")
                _ = try await runtime.enumerateItems(
                    container: IndexWriter.rootIdentifier, pageToken: nil)
            }
            // The index's statements are work `settle()` cannot otherwise see.
            let statements = self.statements
            await runtime.observeStatements { _, _ in statements.bump() }
            try await manager.addDomain(for: location)
            await manager.signalErrorResolved(locationID: location.id)
            if await runtime.finishReconcileIfOwed() != nil {
                await manager.signalWorkingSet(locationID: location.id)
            }
        }
    }

    /// Shuts this agent down the way `sshdrive agent restart` does - every master `-O exit`
    /// first - and brings a new `DomainManager` up over the same group container, index
    /// and `capabilities.json`. Nothing in memory survives: the gate, the breaker, the
    /// ladder and the `viewed` roots start again.
    public func restartAgent() async throws {
        let old = manager
        try await perform("shutting the agent down") { _ = await old.shutdownAll() }
        let fresh = DomainManager(environment: base.environment)
        lock.withLock { _manager = fresh }
        try await bringUp(enumerate: false)
    }

    /// Stops everything this harness started and puts the process-wide helper directory
    /// back. Call it at the end of every scenario.
    public func tearDown() async {
        let manager = self.manager
        let finished = Flag()
        Task {
            _ = await manager.shutdownAll()
            finished.set()
        }
        // The shutdown awaits tasks parked on the driven clock; it is given the same
        // real-time guard as everything else.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if finished.isSet { break }
            if !(await clock.advanceToNextDeadline(settleTurns: 5)) {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        host.tearDown()
        log.uninstall()
        base.bundle.helperResourcesURL = nil
        AgentRuntimeBootstrap.install(environment: base.environment)
        if let helperResources { try? FileManager.default.removeItem(at: helperResources) }
    }

    // MARK: Driving the clock

    /// Advances virtual time by `seconds`, a step at a time.
    public func run(for seconds: Double) async throws {
        let end = clock.uptime() + seconds
        _ = try await drive(until: nil, end: end, what: "run(for: \(seconds))")
    }

    /// Advances virtual time until `condition` holds or `within` seconds have passed.
    /// Answers whether the condition held.
    @discardableResult
    public func run(
        until condition: @escaping @Sendable () async -> Bool, within seconds: Double
    ) async throws -> Bool {
        let end = clock.uptime() + seconds
        return try await drive(until: condition, end: end, what: "run(until:within: \(seconds))")
    }

    /// Runs `body` on a task of its own while driving the clock, for anything that waits
    /// on model time: a bring-up, a shutdown, a command.
    @discardableResult
    public func perform<T: Sendable>(
        _ what: String, within seconds: Double = 300,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ResultBox<T>()
        let task = Task {
            do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        }
        let done = try await run(until: { box.isSet }, within: seconds)
        guard done, let result = box.value else {
            task.cancel()
            throw Stuck(description: "\(what) did not finish within \(Int(seconds)) virtual seconds")
        }
        return try result.get()
    }

    private func drive(
        until condition: (@Sendable () async -> Bool)?, end: Double, what: String
    ) async throws -> Bool {
        let virtualSpan = max(0, end - clock.uptime())
        let realBudget = 20 + virtualSpan / 4
        let realDeadline = Date().addingTimeInterval(realBudget)
        while true {
            await settle()
            if let condition, await condition() { return true }
            let now = clock.uptime()
            if now >= end { return condition == nil }
            guard Date() < realDeadline else {
                throw Stuck(description: """
                    \(what) did not reach its end within \(Int(realBudget)) s of real time: \
                    stopped \(Int(end - now)) virtual s short, \(clock.sleeperCount) sleeper(s) \
                    parked, next deadline \(clock.nextDeadline.map { String($0 - now) } ?? "none"), \
                    \(unsettledSteps) unsettled step(s)
                    """)
            }
            var target = min(end, now + maxStep)
            if let next = clock.nextDeadline, next < target { target = max(next, now) }
            clock.advance(target - now)
        }
    }

    /// Waits, in real time, until nothing the agent or the host does changes anything
    /// for `quietWindows` windows in a row.
    private func settle() async {
        var last = activity()
        var stable = 0
        let deadline = Date().addingTimeInterval(settleTimeoutSeconds)
        while Date() < deadline {
            for _ in 0 ..< 3 { await Task.yield() }
            try? await Task.sleep(nanoseconds: quietWindowNanoseconds)
            let now = activity()
            if now == last {
                stable += 1
                if stable >= quietWindows { return }
            } else {
                stable = 0
                last = now
            }
        }
        lock.withLock { _unsettledSteps += 1 }
    }

    /// Everything the harness can see the agent do: sleeps asked for and released, bytes
    /// and channels on the fake server, File Provider calls, log lines and index
    /// statements. Real work that touches none of them - a JSON file written, a long
    /// computation - is invisible, and the clock can move under it.
    private func activity() -> [Int] {
        [clock.activity, host.activity, replica.calls.count, log.count, statements.value]
    }

    // MARK: Faults the harness owns

    /// `NWPathMonitor`'s answer. Separate from the host's link: a path can be satisfied
    /// over a network that does not reach the server, and a link can die with the path
    /// still up.
    public func setNetworkPath(_ available: Bool) async throws {
        let network = self.network
        try await perform("changing the network path") { await network.setAvailable(available) }
    }

    /// The Mac goes to sleep. With `willSleep` the agent is told first and drops every
    /// master; without it the connections are simply left behind, half-open, the way a
    /// lid closed on a Mac that did not deliver the message leaves them.
    public func sleepMac(willSleep: Bool = true) async throws {
        if willSleep {
            let power = self.power
            try await perform("the will-sleep message") { await power.sleepNow() }
        } else {
            host.stallLiveConnections()
        }
    }

    /// The Mac wakes.
    public func wakeMac() async throws {
        let power = self.power
        try await perform("the wake message") { await power.wake() }
    }

    /// Time passing while the Mac is asleep: the clock jumps, nothing runs in between, and
    /// every timer that came due goes off at once on wake. Pair it with `sleepMac` and
    /// `wakeMac`.
    public func passTimeAsleep(_ seconds: Double) {
        clock.advance(seconds)
    }

    /// The Mac's wall clock jumps while the server's does not: an NTP correction after a
    /// long sleep. The monotonic clock is untouched.
    public func jumpMacWallClock(by seconds: Double) {
        clock.jumpWallClock(by: seconds)
        host.serverClockOffset -= seconds
    }

    // MARK: What a scenario reads

    public func currentRuntime() async throws -> LocationRuntime {
        try await manager.runtime(for: location)
    }

    public func detectorStatus() async -> [String: Any] {
        await manager.detector(locationID: location.id)?.status() ?? [:]
    }

    public func gateReport() async -> [String: Any] {
        await manager.gate(locationID: location.id)?.report() ?? [:]
    }

    /// When each `signalErrorResolved` for this location was made, wall clock.
    public var resolvedSignalTimes: [Double] {
        replica.timedCalls.compactMap {
            if case .signalErrorResolved = $0.call { return $0.at }
            return nil
        }
    }

    /// The index row for a path relative to the location root, or nil.
    public func indexRow(_ path: String) async -> IndexItem? {
        guard let runtime = await manager.startedRuntime(locationID: location.id) else { return nil }
        return try? await runtime.identifier(forPath: path).row
    }

    public func helperIsRunning() async -> Bool {
        let status = await detectorStatus()
        let helper = status["helper"] as? [String: Any]
        return status["tier"] as? String == "helper" && helper?["state"] as? String == "running"
            && host.runningHelperCount > 0
    }

    // MARK: The truth about the server

    /// The channel budget the server really allows.
    public var expectedBudget: ChannelBudget { .forConcurrentChannels(min(3, host.maxSessions)) }

    /// The best tier this server supports for this build.
    public var expectedTier: ChangeDetectionLadder.Tier {
        let profile = host.profile
        guard profile.hasShellAccess, host.maxSessions >= 2 else { return .poll }
        guard host.maxSessions >= 3, host.cacheDirectoryState == .exec,
            helperBinary != nil, location.helper
        else { return .sweep }
        return .helper
    }

    // MARK: Convergence

    /// Limits for `converged()`'s bounded-effort check.
    public struct Effort: Sendable {
        /// The most connect attempts any 60 virtual seconds may hold.
        public var attemptsPerMinute: Int
        /// Only attempts at or after this server time count towards the rate, for a
        /// scenario whose fault phase is judged against its own triggers and whose quiet
        /// period is held to the ordinary limit.
        public var since: Double?
        public init(attemptsPerMinute: Int = 8, since: Double? = nil) {
            self.attemptsPerMinute = attemptsPerMinute
            self.since = since
        }
    }

    /// C1-C8 of the resilience catalogue, as a list of sentences; empty means converged.
    ///
    /// C3 changes the server: it writes a probe file into a watched directory, runs up to
    /// three virtual seconds for it to reach the index through a helper event, then
    /// deletes it and waits for that too.
    public func converged(effort: Effort = Effort(), requireResolvedSignal: Bool = true) async
        -> [String]
    {
        var violations: [String] = []
        let locationID = location.id
        let status = await detectorStatus()
        let gate = await gateReport()

        // C1
        if gate["connected"] as? Bool != true {
            violations.append(
                "C1: the gate is not connected (\(gate["state"] ?? "?"); last failure: \(gate["lastFailure"] ?? "none"))")
        }
        if gate["stopped"] as? Bool == true {
            violations.append("C1: the breaker is stopped (\(gate["lastClassification"] ?? "?"))")
        }

        // C2
        let expected = expectedTier
        let tier = status["tier"] as? String ?? "?"
        if tier != expected.rawValue {
            violations.append(
                "C2: the tier is \(tier), the server supports \(expected.rawValue) (note: \(status["note"] ?? "none"))")
        }
        if expected == .helper {
            let permanent = (status["downgrades"] as? [[String: Any]] ?? []).filter {
                $0["permanence"] as? String == "permanent"
            }
            for downgrade in permanent {
                violations.append(
                    "C2: a permanent downgrade is in force against a server that can run the helper: \(downgrade["reason"] ?? "?")")
            }
        }

        // C3
        if expected == .helper {
            violations += await checkHelperDelivers(status: status)
        }

        // C4
        violations += await checkJournalInIndex()

        // C5
        // On the monotonic clock: a scenario that jumps the Mac's wall clock back would
        // otherwise put a signal sent after the connect before it.
        if requireResolvedSignal, let lastConnect = launcher.connectedUptimes.last {
            let sent = replica.monotonicCalls.compactMap { entry -> Double? in
                if case .signalErrorResolved = entry.call { return entry.uptime }
                return nil
            }
            if !sent.contains(where: { $0 >= lastConnect }) {
                violations.append(
                    "C5: no signalErrorResolved after the last connect (uptime \(lastConnect)); sent at uptimes \(sent)")
            }
        }

        // C6
        let budget = expectedBudget
        if let cached = CapabilityCache.channelBudget(locationID: locationID) {
            if cached != budget {
                violations.append(
                    "C6: the cached channel budget is \(cached.concurrentChannels) channel(s), the server allows \(budget.concurrentChannels)")
            }
        } else {
            violations.append("C6: there is no trustworthy cached channel budget (missing or suspect)")
        }
        violations += checkCachedProbe()

        // C7
        violations += checkSessions(budget: budget, tier: expected)
        let peak = host.peakHelpersOnOneConnection
        if peak.count > 1 {
            violations.append(
                "C7: at one point master \(peak.master) ran \(peak.count) helpers at once")
        }

        // C8
        violations += checkEffort(effort, connected: gate["connected"] as? Bool == true)

        if !host.unrecognisedScripts.isEmpty {
            violations.append(
                "harness: the fake host did not recognise \(host.unrecognisedScripts.count) script(s)")
        }
        return violations
    }

    private func checkHelperDelivers(status: [String: Any]) async -> [String] {
        let helper = status["helper"] as? [String: Any] ?? [:]
        guard helper["state"] as? String == "running" else {
            return ["C3: the helper stream is not running (\(helper["state"] ?? "no stream"): \(helper["reason"] ?? status["note"] ?? "no reason"))"]
        }
        guard host.runningHelperCount == 1 else {
            return ["C3: the server runs \(host.runningHelperCount) helper(s), not one (on masters \(host.helperConnections), live \(host.liveMasters.map(\.ordinal)))"]
        }
        guard let runtime = await manager.startedRuntime(locationID: location.id),
            let set = try? await runtime.currentRootSet()
        else { return ["C3: no runtime"] }
        let watched = set.sweepRoots()
        guard let directory = (watched.shallow + watched.recursive).sorted(by: { $0.count < $1.count }).first
        else { return ["C3: the root set is empty, so nothing on the server is watched"] }

        probeCounter += 1
        let prefix = String(decoding: directory, as: UTF8.self)
        let name = (prefix.isEmpty ? "" : prefix + "/") + "\(Self.probePrefix)\(probeCounter).txt"
        let contents = "probe \(probeCounter)\n"
        let sweepsBefore = host.sweepCount
        let eventsBefore = helper["events"] as? Int ?? 0
        var out: [String] = []

        host.writeFile(name, text: contents)
        let arrived = (try? await run(
            until: { [self] in await self.indexRow(name)?.size == Int64(contents.utf8.count) },
            within: 3)) ?? false
        let eventsAfter = (await detectorStatus()["helper"] as? [String: Any])?["events"] as? Int ?? 0
        if !arrived {
            out.append(
                "C3: \(name) was written on the server and was not in the index 3 s later (helper events \(eventsBefore) -> \(eventsAfter))")
        } else {
            if eventsAfter <= eventsBefore {
                out.append("C3: \(name) reached the index without a helper event")
            }
            if host.sweepCount != sweepsBefore {
                out.append("C3: \(name) reached the index through a sweep, not a helper event")
            }
        }
        host.delete(name)
        let gone = (try? await run(
            until: { [self] in await self.indexRow(name) == nil }, within: 3)) ?? false
        if arrived, !gone {
            out.append("C3: \(name) was deleted on the server and was still in the index 3 s later")
        }
        return out
    }

    /// Every path the scenario changed on the server, compared with the index wherever
    /// the agent watches the directory it is in.
    private func checkJournalInIndex() async -> [String] {
        guard let runtime = await manager.startedRuntime(locationID: location.id),
            let set = try? await runtime.currentRootSet()
        else { return ["C4: no runtime"] }
        let roots = set.sweepRoots()
        func isWatched(_ path: String) -> Bool {
            let bytes = Data(path.utf8)
            let parent = bytes.lastIndex(of: 0x2F).map { Data(bytes[bytes.startIndex ..< $0]) } ?? Data()
            if roots.shallow.contains(parent) { return true }
            return roots.recursive.contains { $0.isEmpty || bytes == $0 || RootSet.isStrictlyUnder(bytes, root: $0) }
        }
        var paths: [String] = []
        for entry in host.journal.dropFirst(journalStart) {
            for path in [entry.path] + (entry.from.map { [$0] } ?? [])
            where !path.contains(Self.probePrefix) && !path.hasPrefix("/") && !paths.contains(path) {
                paths.append(path)
            }
        }
        var out: [String] = []
        for path in paths where isWatched(path) {
            let node = host.node(path)
            let row = await indexRow(path)
            switch (node, row) {
            case (nil, nil):
                continue
            case (nil, .some):
                out.append("C4: \(path) is gone from the server and still in the index")
            case (.some, nil):
                out.append("C4: \(path) is on the server and not in the index")
            case let (.some(node), .some(row)):
                if node.type == .file,
                    row.size != Int64(node.contents.count) || row.mtime != node.mtime
                {
                    out.append(
                        "C4: \(path) is \(node.contents.count) bytes at \(node.mtime) on the server and \(row.size) bytes at \(row.mtime) in the index")
                }
            }
        }
        return out
    }

    private func checkCachedProbe() -> [String] {
        guard let cached = CapabilityCache.probe(locationID: location.id)?.probe else {
            return ["C6: capabilities.json holds no probe"]
        }
        let profile = host.profile
        var out: [String] = []
        if cached.hasShellAccess != profile.hasShellAccess {
            out.append(
                "C6: capabilities.json says shell access \(cached.hasShellAccess) (\(cached.failure)), the server says \(profile.hasShellAccess)")
        }
        guard profile.hasShellAccess, host.maxSessions >= 2 else { return out }
        if cached.uname != profile.unameSM {
            out.append("C6: capabilities.json says uname '\(cached.uname)', the server says '\(profile.unameSM)'")
        }
        let wantCache = host.cacheDirectoryState == .exec ? host.cacheDirectory : ""
        if cached.cacheDirectory != wantCache {
            out.append(
                "C6: capabilities.json says the cache directory is '\(cached.cacheDirectory)' (\(cached.cacheNote)), the server's is '\(wantCache)'")
        }
        if cached.findTakesCmin != profile.findFlavour.takesCmin {
            out.append("C6: capabilities.json says -cmin \(cached.findTakesCmin), the server's find says \(profile.findFlavour.takesCmin)")
        }
        return out
    }

    private func checkSessions(budget: ChannelBudget, tier: ChangeDetectionLadder.Tier) -> [String] {
        let live = host.liveMasters
        var out: [String] = []
        if live.count != 1 {
            out.append("C7: the server holds \(live.count) live connection(s), not one")
        }
        for master in live {
            let counts = master.sessionCounts
            let wantSFTP = budget.hasBulkChannel ? 2 : 1
            let wantExec = tier == .helper ? 1 : 0
            if counts.sftp != wantSFTP || counts.exec != wantExec {
                out.append(
                    "C7: connection \(master.ordinal) holds \(counts.sftp) SFTP and \(counts.exec) exec session(s) \(master.openExecKinds.map(\.rawValue)), not \(wantSFTP) and \(wantExec)")
            }
        }
        return out
    }

    private func checkEffort(_ effort: Effort, connected: Bool) -> [String] {
        let attempts = host.attempts
        var out: [String] = []
        let (worst, worstAt) = Self.busiestMinute(
            attempts.filter { $0.serverAt >= (effort.since ?? -.infinity) })
        if worst > effort.attemptsPerMinute {
            out.append(
                "C8: \(worst) connect attempts in the minute from \(worstAt), more than \(effort.attemptsPerMinute)")
        }
        if connected, let last = attempts.lastIndex(where: \.succeeded), last != attempts.count - 1 {
            out.append(
                "C8: \(attempts.count - 1 - last) connect attempt(s) after the connection came up")
        }
        if unsettledSteps > 0 {
            out.append("C8: \(unsettledSteps) step(s) never settled: something is busy without waiting on the clock")
        }
        return out
    }

    /// The most attempts any 60 s of server time holds, and where that minute starts.
    public static func busiestMinute(_ attempts: [FakeRemoteHost.Attempt]) -> (count: Int, at: Double) {
        let sorted = attempts.sorted { $0.serverAt < $1.serverAt }
        var worst = 0
        var worstAt = 0.0
        for (index, attempt) in sorted.enumerated() {
            let inWindow = sorted[index...].prefix { $0.serverAt < attempt.serverAt + 60 }.count
            if inWindow > worst { worst = inWindow; worstAt = attempt.serverAt }
        }
        return (worst, worstAt)
    }

    // MARK: Files

    /// Where the group container and the helper fixture live: `/dev/shm` where there is
    /// one. The agent writes `capabilities.json`, `config.json` and the index
    /// synchronously, and on a busy disk one of those writes can take 80 ms - work
    /// `settle()` cannot see, during which the clock would run on for a dozen steps and
    /// fire deadlines the agent never really missed. On tmpfs the same write takes a
    /// tenth of a millisecond.
    public static var scratchDirectory: URL {
        let shm = URL(fileURLWithPath: "/dev/shm", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: shm.path) { return shm }
        return FileManager.default.temporaryDirectory
    }

    // MARK: The helper fixture

    /// A manifest and one binary for `target`, in a directory of their own. The bytes are
    /// not a program; the fake host recognises them by their digest and runs them as the
    /// helper.
    public static func helperFixture(target: HelperTarget, version: String = "0.1.0") throws
        -> (directory: URL, binary: HelperManifest.Binary, bytes: Data, version: String)
    {
        let directory = scratchDirectory
            .appendingPathComponent("sshdrive-resilience-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data("#!fake sshdrive-helper \(version) \(target.os)/\(target.arch)\n".utf8)
        var state: UInt32 = 0x1234_5678
        for _ in 0 ..< 4096 {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        let file = "sshdrive-helper-\(version)-\(target.os)-\(target.arch)"
        try bytes.write(to: directory.appendingPathComponent(file))
        let binary = HelperManifest.Binary(
            os: target.os, arch: target.arch, file: file, sha256: SHA256Digest.hex(bytes),
            size: Int64(bytes.count))
        let manifest = HelperManifest(version: version, binaries: [binary])
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(HelperManifest.fileName))
        return (directory, binary, bytes, version)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.withLock { stored = result } }
    var value: Result<T, Error>? { lock.withLock { stored } }
    var isSet: Bool { value != nil }
}
