import Foundation
import AgentCore
import Config
import Logging
import ProviderCore
import SFTP
import SSHProcess
import Secrets
import XPCProtocols

// The agent's seams (docs/testing-architecture.md section 2.3).
//
// Everything under `Apps/Agent` that names an Apple framework is one of these protocols.
// The Darwin implementation stays in `Apps/Agent` as an adapter with no branch worth
// testing; the Linux implementation is a fake in `AgentRuntimeTestSupport`, so every
// decision above the seam runs on this box.
//
// Two deviations from the document's table, both forced and both deliberate:
//
// - the presence seam is `PresenceReporting`, not `PresenceReading`: `AgentCore` already
//   owns a *value* called `PresenceReading` (section 4.2's two readings), and a protocol
//   of the same name in a module that imports it would be ambiguous at every use;
// - `ProcessAncestryReading` is `Secrets.ProcessAncestry`, which was already a protocol
//   with a `/proc` implementation off Darwin (step 1.2), so nothing is redefined here.

// MARK: The replica

/// Every call the agent makes into its own File Provider domains: the domain list, the
/// signals, the replica enumerators, eviction, and the two lookups that turn an
/// identifier into a file on disk (DESIGN.md sections 5.3, 6.5, 7, 7.1).
///
/// The Darwin implementation is `NSFileProviderManager` in `Apps/Agent`; the failures it
/// reports are dictionaries rather than typed errors on purpose - S4 measured that the
/// codes say nothing about why (`MQ-017`, `MQ-018`, `MQ-019`), so nothing above this seam
/// may branch on one.
public protocol ReplicaControlling: Sendable {
    /// Every domain the system holds for our provider, as `(identifier, displayName)`.
    func domains() async throws -> [ReplicaDomain]
    /// `add(domain)`. The same identifier with a new display name renames in place (S9).
    func addDomain(_ domain: ReplicaDomain, testingModes: [String]) async throws
    func removeDomain(_ domain: ReplicaDomain) async throws

    func signalEnumerator(locationID: String, container: ProviderItemIdentifier) async throws
    func signalErrorResolved(locationID: String) async throws

    /// `enumeratorForMaterializedItems()`, drained. Nil means there is no manager for the
    /// domain, which is "no news" and never "the user evicted everything" (section 6.5).
    func materializedIdentifiers(locationID: String) async -> [String]?
    /// `enumeratorForPendingItems()`, drained.
    func pendingIdentifiers(locationID: String) async -> [String]?

    /// `evictItem`. The report carries `evicted` and, on a refusal, the error fields.
    func evict(locationID: String, identifier: String) async -> [String: Any]

    func userVisibleURL(locationID: String, identifier: String) async throws -> URL
    /// `getIdentifierForUserVisibleFile(at:)`, filtered to this domain.
    func identifierForUserVisibleFile(at url: URL, locationID: String) async -> String?

    /// `lstat` of a replica path: the atime and mtime section 7's TTL rule reads before
    /// anything is evicted, since an eviction moves atime (S4).
    func replicaTimes(url: URL) -> (atime: Double, mtime: Double)?
    /// The same `lstat` as a report, for `sshdrive debug replica`.
    func statReport(url: URL, readFirst: Bool) -> [String: Any]

    /// `NSFileProviderManager.waitForStabilization`, and the testing-operation hooks. Both
    /// are spike scaffolding and both answer a dictionary, so a model can say "not here".
    func stabilize(locationID: String) async throws -> [String: Any]
    func testingOperations(locationID: String, run: Bool) async throws -> [String: Any]

    /// An error, field by field, the way `ReplicaAccess.describe` reports one.
    func describe(error: Error) -> [String: Any]
}

/// One File Provider domain, as the agent needs to name it.
public struct ReplicaDomain: Sendable, Hashable {
    public var identifier: String
    public var displayName: String
    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

extension ReplicaControlling {
    /// The working set, which is how every change the agent found reaches Finder.
    public func signalWorkingSet(locationID: String) async {
        do {
            try await signalEnumerator(locationID: locationID, container: .workingSet)
        } catch {
            Log.agent.error("signalEnumerator failed: \(error, privacy: .public)")
        }
    }

    /// The same call for one container, with the failure logged rather than thrown: a
    /// signal that did not go out is never a reason to fail the work that produced it.
    public func signal(locationID: String, container: ProviderItemIdentifier) async {
        do {
            try await signalEnumerator(locationID: locationID, container: container)
            Log.agent.notice(
                "\(locationID, privacy: .public): signalled \(container.rawValue, privacy: .public)")
        } catch {
            Log.agent.error("signalEnumerator failed: \(error, privacy: .public)")
        }
    }

    public func signalResolved(locationID: String) async {
        do {
            try await signalErrorResolved(locationID: locationID)
            Log.agent.notice(
                "signalled errorResolved(serverUnreachable) for \(locationID, privacy: .public)")
        } catch {
            Log.agent.error("signalErrorResolved failed: \(error, privacy: .public)")
        }
    }

    /// Section 5.5's conflict path: the eviction that has to follow the reply, which
    /// cannot be done once. Without it the replica keeps the *local* bytes under the
    /// *remote* version for ever, which is the whole reason the eviction is there.
    public func evictAfterConflict(
        locationID: String, identifier: String, attempts: Int = 7, sleeper: any AgentClock
    ) async {
        // The conflict path waits *before* its first attempt: the modification it is
        // racing has only just been replied to (`MQ-017`).
        await sleeper.sleep(seconds: 0.25)
        let report = await evictWithRetry(
            locationID: locationID, identifier: identifier, attempts: attempts, sleeper: sleeper)
        if report["evicted"] as? Bool == true {
            Log.agent.notice(
                "evicted \(identifier, privacy: .public) after a conflict copy on attempt \(report["attempts"] as? Int ?? 0, privacy: .public)"
            )
        } else {
            Log.agent.error(
                "could not evict \(identifier, privacy: .public) after a conflict copy; the replica still holds the local bytes under the remote version"
            )
        }
    }

    /// Section 7.1 step 1's last step: **a lookup of the pinned path in the replica**.
    ///
    /// S6 measured (2026-09-04) that reporting the ancestor rows through the working set
    /// does not make the system ingest them, and neither does `signalEnumerator` on each
    /// new ancestor's container. What starts it is this: `getUserVisibleURL` for the
    /// pinned identifier followed by one `lstat` of the returned path.
    @discardableResult
    public func lookUpInReplica(locationID: String, identifier: String) async -> [String: Any] {
        do {
            let url = try await userVisibleURL(locationID: locationID, identifier: identifier)
            var report = statReport(url: url, readFirst: false)
            report["lstat"] = replicaTimes(url: url) != nil
            Log.agent.notice(
                "looked \(url.path, privacy: .public) up in the replica so the system ingests the pinned chain"
            )
            return report
        } catch {
            Log.agent.error(
                "could not look the pinned item up in the replica: \(error, privacy: .public)")
            return describe(error: error)
        }
    }

    /// `evictItem` with the doubling backoff section 5.5's conflict path needs and
    /// `sshdrive evict <name> <path>` reuses (S3: an eviction issued straight after a
    /// `modifyItem` reply is refused -2008 because the system is still finishing it).
    @discardableResult
    public func evictWithRetry(
        locationID: String, identifier: String, attempts: Int = 7, subject: String = "",
        sleeper: any AgentClock
    ) async -> [String: Any] {
        var delay: Double = 0.25
        var last: [String: Any] = [:]
        for attempt in 1...max(1, attempts) {
            last = await evict(locationID: locationID, identifier: identifier)
            if last["evicted"] as? Bool == true {
                last["attempts"] = attempt
                return last
            }
            await sleeper.sleep(seconds: delay)
            delay = min(delay * 2, 8)
        }
        last["attempts"] = attempts
        Log.agent.notice(
            "gave up evicting \(subject.isEmpty ? identifier : subject, privacy: .public) after \(attempts, privacy: .public) attempts"
        )
        return last
    }
}

// MARK: The login item and launchd

/// `SMAppService.agent(plistName:)` (DESIGN.md section 10). Registration is idempotent and
/// is done on every launch; only `unregister()` clears a record whose bundle was replaced
/// (`MQ-062`).
public protocol LoginItemControlling: Sendable {
    func register() throws
    func unregister() throws
    /// `enabled`, `requiresApproval`, `notRegistered`, `notFound` or `unknown`.
    func status() -> String
}

/// `launchctl print gui/<uid>/<label>`, which is the only thing that can see the window
/// `unregister()` returns inside (`MQ-063`).
public protocol LaunchdControlling: Sendable {
    /// True while launchd still holds the job.
    func serviceIsLoaded(label: String) async -> Bool
}

extension LaunchdControlling {
    /// Section 10's upgrade handover: `unregister()` returns, and `status` reports
    /// `notRegistered`, *before* launchd has dropped the job, and a `register()` inside
    /// that window leaves the job carrying the previous bundle's launch constraint and
    /// dying on a 10 s throttle for ever. So the unregister role waits for the job to go.
    public func waitUntilGone(
        label: String, attempts: Int = 150, clock: any AgentClock
    ) async -> Bool {
        for _ in 0 ..< max(1, attempts) {
            if await !serviceIsLoaded(label: label) { return true }
            await clock.sleep(seconds: 0.2)
        }
        return false
    }
}

// MARK: Power, network, presence and the screen lock

/// `IORegisterForSystemPower` (section 6.1). The will-sleep message must be acknowledged,
/// and the adapter does that; what crosses the seam is only "the Mac is going to sleep,
/// tell me when you are done" and "the Mac woke up".
public protocol PowerObserving: Sendable {
    func start(
        willSleep: @escaping @Sendable () async -> Void,
        didWake: @escaping @Sendable () async -> Void)
    var report: [String: Any] { get }
}

/// `NWPathMonitor` (section 6.3's first rule).
public protocol NetworkPathObserving: Sendable {
    func start(changed: @escaping @Sendable (Bool) async -> Void)
    var report: [String: Any] { get }
}

/// `CGEventSource.secondsSinceLastEventType` and `CGSSessionScreenIsLocked` (section 4.2).
///
/// Named `PresenceReporting` rather than the document's `PresenceReading` because
/// `AgentCore.PresenceReading` is the value it returns.
public protocol PresenceReporting: Sendable {
    func read() -> PresenceReading
    /// Whether the reading is a real one or the spike override, so a runbook can never
    /// mistake one for the other.
    var isOverridden: Bool { get }
}

/// `com.apple.screenIsUnlocked` / `com.apple.screenIsLocked` (section 4.2's first
/// re-arm trigger).
public protocol ScreenLockObserving: Sendable {
    func start(
        unlocked: @escaping @Sendable () async -> Void,
        locked: @escaping @Sendable () async -> Void)
    var report: [String: Any] { get }
}

// MARK: Peers

/// Which of our four executables a peer is (section 5.2). The code requirement is the
/// security boundary and is applied before this; this only says *which*.
public protocol PeerIdentifying: Sendable {
    func executablePath(pid: Int32) -> String?
    func isCLI(pid: Int32) -> Bool
}

/// Every live File Provider extension connection, so section 5.3's restore can ask the
/// readers to close before the sidecars are truncated under them.
public protocol IndexReaderPeering: Sendable {
    func closeReaders() async
    func reopenReaders()
    var peerCount: Int { get }
}

// MARK: The bundle

/// What the agent can learn about the bundle it is running from: the quarantine xattr, the
/// paths, the shipped helper binaries, and PlugInKit's view of the extension (section 10).
public protocol BundleInspecting: Sendable {
    var bundleURL: URL { get }
    var executableURL: URL { get }
    /// `Contents/Resources/helper/`, where the tier-2 binaries ship (section 6.4).
    var helperResourcesURL: URL? { get }
    /// `com.apple.quarantine`'s value, or nil.
    func quarantineValue(atPath path: String) -> String?
    /// `pluginkit -m -A -i <id>`'s line, or nil when it printed nothing.
    func plugInRegistration(bundleID: String) -> String?
    /// The running OS, for `doctor`'s minimum-version check.
    var operatingSystemVersion: (major: Int, minor: Int, patch: Int) { get }
    /// Whether a bundle at a path is a complete, readable replacement carrying our own
    /// identifier - section 10.1's upgrade handover test.
    func inode(ofPath path: String) -> UInt64?
    func bundleIdentifier(atPath path: String) -> String?
    /// "readable" in section 10.1's sense: the file is there and this process can open it,
    /// which is half of what stops a handover to a half-copied bundle.
    func isReadable(path: String) -> Bool
}

// MARK: The transport

/// One location's live connection, as everything above the transport sees it.
///
/// `SSHBackedTransport` is the only implementation that ships; a test hands out a double
/// over the same `SFTPTransport` surface, and `execMaster` is nil there, which is exactly
/// what "no exec channel" already means everywhere in section 6.4.
public protocol LiveConnection: SFTPTransport, Sendable {
    var budget: ChannelBudget { get }
    var probe: ServerProbe.Result { get }
    var transfersShareMetadataChannel: Bool { get }
    var uploadTag: String { get }
    /// Every extension name the handshake recorded (section 8.1).
    var extensionNames: [String] { get async }
    /// The master an exec channel is opened on: the tier-1 sweep, the `id` probe and the
    /// helper's stream. Nil where there is no real `ssh`, which reads as "no exec channel".
    var execMaster: SSHMaster? { get }
    /// The metadata channel's client, for the one caller that addresses a path outside
    /// every location root: the helper's deployment (section 6.4 tier 2).
    var metadataTransport: RealSFTPTransport? { get }
    func shutdown() async
    func isMasterAlive() async -> Bool
}

/// What spawns `/usr/bin/ssh` (section 6.1). `SSHTransportLauncher` in `Apps/Agent` is the
/// real one; `ServerModel.FakeSSH` and the in-process doubles stand in on Linux.
public protocol TransportLauncher: Sendable {
    func connect(
        location: Location, askpassPath: String?, askpass: (any AskpassTokenProviding)?,
        uploadTag: String, reprobeChannels: Bool
    ) async throws -> any LiveConnection
}

// MARK: The terminal

/// The CLI, as the agent sees it (section 4.2): a line for the terminal while a long
/// command runs, and one prompt answered on it. Nothing the extension or a timer does can
/// reach a terminal, so this only ever exists while a CLI command of the user's own making
/// is in flight.
public protocol TerminalRelaying: AnyObject, Sendable {
    func note(_ text: String)
    func prompt(kind: String, prompt text: String, detail: String, secret: Bool) -> String?
}

// MARK: The endpoint

/// The agent's XPC listener, as the parts above it need it. `Apps/Agent` holds the
/// `NSXPCListener`; a Linux harness holds an in-process loopback.
public protocol AgentEndpoint: Sendable {
    /// Stop serving and exit with this status. The real one calls `exit`; a harness
    /// records the status, which is why this does not return `Never` - `P4` asserts that
    /// SIGTERM exits **0**, and an assertion cannot be made about a process that is gone.
    func terminate(status: Int32)
}

// MARK: The clock

/// Time, injected, as `AgentCore`'s clock-taking types already take it. `now()` is seconds
/// since the reference the caller chose - the agent uses `timeIntervalSince1970` for
/// schedules and `systemUptime` for the breaker, and both are answered here so a scenario
/// can drive them together.
public protocol AgentClock: Sendable {
    /// Wall clock, seconds since 1970.
    func now() -> Double
    /// Monotonic seconds, which is what the breaker's backoff is measured in.
    func uptime() -> Double
    func sleep(seconds: Double) async
}

/// The system clock, and the only implementation that ships.
public struct SystemAgentClock: AgentClock {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
    public func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: The environment

/// Every seam in one value, handed down from `main.swift` to the runtimes.
///
/// It is a struct of protocol existentials rather than a set of singletons because the
/// scenarios need two agents in one process: `DomainManager` is constructed with one of
/// these, and everything it makes carries it.
public struct AgentEnvironment: Sendable {
    public var replica: any ReplicaControlling
    public var secrets: any SecretsStore
    public var loginItem: any LoginItemControlling
    public var launchd: any LaunchdControlling
    public var power: any PowerObserving
    public var network: any NetworkPathObserving
    public var presence: any PresenceReporting
    public var screenLock: any ScreenLockObserving
    public var peers: any PeerIdentifying
    public var readerPeers: any IndexReaderPeering
    public var bundle: any BundleInspecting
    public var keychain: any KeychainDiagnosing
    public var launcher: any TransportLauncher
    public var endpoint: any AgentEndpoint
    public var clock: any AgentClock

    public init(
        replica: any ReplicaControlling,
        secrets: any SecretsStore,
        loginItem: any LoginItemControlling,
        launchd: any LaunchdControlling,
        power: any PowerObserving,
        network: any NetworkPathObserving,
        presence: any PresenceReporting,
        screenLock: any ScreenLockObserving,
        peers: any PeerIdentifying,
        readerPeers: any IndexReaderPeering,
        bundle: any BundleInspecting,
        keychain: any KeychainDiagnosing,
        launcher: any TransportLauncher,
        endpoint: any AgentEndpoint,
        clock: any AgentClock = SystemAgentClock()
    ) {
        self.replica = replica
        self.secrets = secrets
        self.loginItem = loginItem
        self.launchd = launchd
        self.power = power
        self.network = network
        self.presence = presence
        self.screenLock = screenLock
        self.peers = peers
        self.readerPeers = readerPeers
        self.bundle = bundle
        self.keychain = keychain
        self.launcher = launcher
        self.endpoint = endpoint
        self.clock = clock
    }
}

// MARK: The keychain, as `doctor` and the spikes ask about it

/// Two questions about the keychain that are not "store this secret": can the agent reach
/// it at all, and does one `SecItemAdd`/`CopyMatching`/`Delete` round trip work under the
/// shared access group (S1 d2, DESIGN.md section 3.1)?
///
/// They are a seam of their own rather than methods on `SecretsStore` because both answer
/// `OSStatus` detail that only Darwin has, and neither is on any path that stores or reads
/// a secret; off Darwin they answer for the in-memory store instead.
public protocol KeychainDiagnosing: Sendable {
    /// `doctor`'s "keychain" line: reachability, never contents.
    func reachability() -> (ok: Bool, detail: String)
    /// `sshdrive debug keychain`: one round trip, field by field.
    func roundTrip(account: String, value: String) -> [String: Any]
}
