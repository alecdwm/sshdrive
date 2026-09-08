import AgentCore
import AgentRuntime
import Config
import Foundation
import Index
import Logging
import SFTP
import Secrets
import XPCProtocols

/// One agent, wired to the in-memory seams, with a group container of its own.
///
/// This is what a scenario in `Tests/AgentRuntimeTests` starts from: an `AgentEnvironment`
/// whose every member is a fake it can drive, a `DomainManager` built on it, and a
/// temporary directory standing in for
/// `~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/`. Nothing here reaches
/// macOS, the network, a keychain or a real clock.
///
/// The container is per-harness because `Config.GroupContainer` is process-wide: the
/// locator is installed on `setUp` and put back on `tearDown`, so the suites that use this
/// are `.serialized`.
public final class AgentHarness: @unchecked Sendable {
    public let container: URL
    public let replica: FakeReplica
    public let secretsStore: InMemorySecretsStore
    public let loginItem: FakeLoginItem
    public let launchd: FakeLaunchd
    public let power: ScriptedPower
    public let network: ScriptedNetwork
    public let presence: ScriptedPresence
    public let screenLock: ScriptedScreenLock
    public let readerPeers: RecordingReaderPeers
    public let bundle: FakeBundle
    public let launcher: FakeTransportLauncher
    public let endpoint: RecordingEndpoint
    public let clock: VirtualAgentClock
    public let environment: AgentEnvironment
    public let manager: DomainManager

    public init(
        clock: VirtualAgentClock = VirtualAgentClock(),
        launchdProbesBeforeGone: Int = 0,
        secrets: AgentSecrets? = nil,
        configure: (inout AgentEnvironment) -> Void = { _ in }
    ) throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdrive-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        GroupContainer.locator = FixedGroupContainerLocator(container)

        replica = FakeReplica(mountRoot: container.appendingPathComponent("CloudStorage"))
        secretsStore = InMemorySecretsStore()
        loginItem = FakeLoginItem()
        launchd = FakeLaunchd(probesBeforeGone: launchdProbesBeforeGone)
        power = ScriptedPower()
        network = ScriptedNetwork()
        presence = ScriptedPresence()
        screenLock = ScriptedScreenLock()
        readerPeers = RecordingReaderPeers()
        bundle = FakeBundle()
        launcher = FakeTransportLauncher()
        endpoint = RecordingEndpoint()
        self.clock = clock

        var environment = AgentEnvironment(
            replica: replica,
            secrets: secretsStore,
            loginItem: loginItem,
            launchd: launchd,
            power: power,
            network: network,
            presence: presence,
            screenLock: screenLock,
            peers: ScriptedPeers(),
            readerPeers: readerPeers,
            bundle: bundle,
            keychain: InMemoryKeychainDiagnostics(store: secretsStore),
            launcher: launcher,
            endpoint: endpoint,
            clock: clock)
        configure(&environment)
        self.environment = environment
        // Section 4.2's askpass broker and keychain. The default one is built from the
        // environment's own store with no askpass program and no `ssh` to resolve with,
        // which is right for every scenario that never spawns one; a scenario that drives
        // `add` end to end hands in its own (see `AddFlowScenarios`).
        self.manager = DomainManager(environment: environment, secrets: secrets)
    }

    /// Deliberately **not** `GroupContainer.resetLocator()`.
    ///
    /// `deinit` runs whenever ARC gets round to it, and a harness released after the next
    /// test has already installed its own locator would put the default back underneath it.
    /// Removing only this harness's own directory is safe at any time; the locator is
    /// simply overwritten by the next `AgentHarness`, and the suites that use one are
    /// `.serialized` for exactly that reason.
    deinit {
        try? FileManager.default.removeItem(at: container)
    }

    /// A location in `config.json`, mounted, with whichever backend the scenario wants.
    /// `.fake` gets `SFTP.FakeTransport` straight through `LocationRuntime`; `.sftp` goes
    /// through `ReconnectingTransport` and the gate, which is what the reconnect,
    /// sleep/wake and re-arm scenarios need.
    @discardableResult
    public func addLocation(
        nickname: String, backend: LocationBackend = .sftp, host: String = "example",
        remotePath: String = "/srv/fake", cacheTTL: CacheTTL = .oneHour,
        watchMode: WatchMode = .auto, agentDependent: Bool = false
    ) async throws -> Location {
        var location = Location(
            nickname: nickname, host: host, remotePath: remotePath, cacheTTL: cacheTTL,
            mounted: true, backend: backend)
        location.watchMode = watchMode
        location.agentDependent = agentDependent
        let created = location
        try await manager.mutateConfiguration { file in
            file.locations.removeAll { $0.id == created.id }
            file.locations.append(created)
        }
        return created
    }

    /// A runtime over a transport the scenario holds, so it can change the server under
    /// the agent without going through a debug hook that also runs a sweep.
    public func makeRuntime(
        location: Location, transport: any SFTPTransport
    ) throws -> LocationRuntime {
        try GroupContainer.createDomainDirectory(locationID: location.id)
        return try LocationRuntime(
            location: location,
            transport: transport,
            indexURL: try GroupContainer.indexURL(locationID: location.id),
            backupURL: try GroupContainer.indexBackupURL(locationID: location.id),
            environment: environment)
    }

    /// The index for a location, opened directly, for a scenario that seeds rows.
    public func indexWriter(locationID: String) throws -> IndexWriter {
        try GroupContainer.createDomainDirectory(locationID: locationID)
        return try IndexWriter(path: GroupContainer.indexURL(locationID: locationID).path)
    }

    /// Runs a command through the XPC command layer against **this** agent, which is what
    /// binds `AgentCommandContext` for the duration.
    public func control(
        _ command: String, _ arguments: [String: String] = [:]
    ) async throws -> [String: Any] {
        let data = try await AgentCommandContext.with(manager) {
            try await ControlCommands.run(command: command, arguments: arguments)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The same call with a terminal attached: `add` and a re-keying `set` are the two
    /// commands that relay a prompt to the CLI (section 4.2), and `TerminalRelaying` is
    /// the seam they reach it through.
    public func control(
        _ command: String, _ arguments: [String: String], relay: any TerminalRelaying
    ) async throws -> [String: Any] {
        let data = try await AgentCommandContext.with(manager) {
            try await ControlCommands.run(
                command: command, arguments: arguments, relay: relay)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Section 6.1's sleep and wake, section 6.3's path gate and section 4.2's
    /// screen-unlock re-arm, wired to this agent the way `DomainManager.start()` wires
    /// them - without paying for the rest of `start()`, which takes a login-shell snapshot
    /// and sweeps `$TMPDIR` for orphaned control sockets.
    public func installSystemObservers() async {
        await manager.installSystemObservers()
    }

    /// Waits until the launcher has been asked for nothing new for a few scheduler
    /// windows: the two timers a mounted location carries can have a cycle in flight when
    /// a scenario stops them, and a transport call from that cycle legitimately connects.
    /// A scenario that is about what one *event* did quiesces first.
    public func quiesceConnects(windows: Int = 6) async {
        var stable = 0
        var last = launcher.attempts
        var rounds = 0
        while stable < windows, rounds < 200 {
            rounds += 1
            await settle()
            let now = launcher.attempts
            if now == last { stable += 1 } else { stable = 0; last = now }
        }
    }

    /// Lets whatever the last call started run to a standstill.
    ///
    /// The agent's own schedules are on the virtual clock, so nothing here waits for a
    /// timer; what this waits for is Swift's, which hands a detached `Task` to whichever
    /// thread it likes. It polls a millisecond at a time and gives up rather than hanging
    /// a suite.
    public func settle(
        timeoutSeconds: Double = 5, until condition: @Sendable () async -> Bool = { true }
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var settled = false
        while Date() < deadline {
            for _ in 0 ..< 5 { await Task.yield() }
            if await condition() { settled = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // One more pass either way, so a caller that passed no condition still gets the
        // few turns the default promises.
        if !settled { for _ in 0 ..< 20 { await Task.yield() } }
    }
}
