import Foundation
import AgentCore
import Config
import Logging
import ProviderCore
import SFTP
import SSHProcess
import Secrets
import XPCProtocols

/// The seams before `bootstrap` has installed the real ones.
///
/// `DomainManager.shared` has to exist from the first line of `main.swift`, and a static
/// that is optional would put a `!` on every use of it. So the unconfigured environment is
/// a set of implementations that do nothing and say so once: no domain is added, no master
/// is spawned, nobody is present. Nothing reaches them in a running agent - `bootstrap` is
/// the second statement of every role - and a test that forgets to configure gets a loud,
/// harmless failure rather than a crash.
struct UnconfiguredReplica: ReplicaControlling {
    private func complain(_ what: String) {
        Log.agent.error("\(what, privacy: .public) before the agent was configured")
    }
    func domains() async throws -> [ReplicaDomain] { complain("domains()"); return [] }
    func addDomain(_ domain: ReplicaDomain, testingModes: [String]) async throws {
        complain("addDomain")
    }
    func removeDomain(_ domain: ReplicaDomain) async throws { complain("removeDomain") }
    func signalEnumerator(locationID: String, container: ProviderItemIdentifier) async throws {
        complain("signalEnumerator")
    }
    func signalErrorResolved(locationID: String) async throws { complain("signalErrorResolved") }
    func materializedIdentifiers(locationID: String) async -> [String]? { nil }
    func pendingIdentifiers(locationID: String) async -> [String]? { nil }
    func evict(locationID: String, identifier: String) async -> [String: Any] {
        ["evicted": false, "errorDescription": "the agent is not configured"]
    }
    func userVisibleURL(locationID: String, identifier: String) async throws -> URL {
        throw SSHDriveAgentError.unknownDomain.asNSError("The agent is not configured.")
    }
    func identifierForUserVisibleFile(at url: URL, locationID: String) async -> String? { nil }
    func replicaTimes(url: URL) -> (atime: Double, mtime: Double)? { nil }
    func statReport(url: URL, readFirst: Bool) -> [String: Any] { ["path": url.path] }
    func stabilize(locationID: String) async throws -> [String: Any] { [:] }
    func testingOperations(locationID: String, run: Bool) async throws -> [String: Any] { [:] }
    func describe(error: Error) -> [String: Any] {
        ["errorDescription": error.localizedDescription]
    }
}

struct UnconfiguredLoginItem: LoginItemControlling {
    func register() throws {}
    func unregister() throws {}
    func status() -> String { "not registered" }
}

struct UnconfiguredLaunchd: LaunchdControlling {
    func serviceIsLoaded(label: String) async -> Bool { false }
}

struct UnconfiguredPower: PowerObserving {
    func start(
        willSleep: @escaping @Sendable () async -> Void,
        didWake: @escaping @Sendable () async -> Void
    ) {}
    var report: [String: Any] { ["registered": false] }
}

struct UnconfiguredNetwork: NetworkPathObserving {
    func start(changed: @escaping @Sendable (Bool) async -> Void) {}
    var report: [String: Any] { ["status": "unknown"] }
}

/// Nobody at the keyboard, and the screen locked: the reading that makes the deadline
/// re-arm refuse rather than fire.
struct UnconfiguredPresence: PresenceReporting {
    func read() -> PresenceReading {
        PresenceReading(secondsSinceLastInputEvent: .greatestFiniteMagnitude, screenLocked: true)
    }
    var isOverridden: Bool { false }
}

struct UnconfiguredScreenLock: ScreenLockObserving {
    func start(
        unlocked: @escaping @Sendable () async -> Void,
        locked: @escaping @Sendable () async -> Void
    ) {}
    var report: [String: Any] { ["unlocks": 0, "locks": 0] }
}

struct UnconfiguredPeers: PeerIdentifying {
    func executablePath(pid: Int32) -> String? { nil }
    func isCLI(pid: Int32) -> Bool { false }
}

struct UnconfiguredReaderPeers: IndexReaderPeering {
    func closeReaders() async {}
    func reopenReaders() {}
    var peerCount: Int { 0 }
}

struct UnconfiguredBundle: BundleInspecting {
    var bundleURL: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
    var executableURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "/dev/null")
    }
    var helperResourcesURL: URL? { nil }
    func quarantineValue(atPath path: String) -> String? { nil }
    func plugInRegistration(bundleID: String) -> String? { nil }
    var operatingSystemVersion: (major: Int, minor: Int, patch: Int) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return (version.majorVersion, version.minorVersion, version.patchVersion)
    }
    func inode(ofPath path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
    func isReadable(path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }
    func bundleIdentifier(atPath path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return parsed["CFBundleIdentifier"] as? String
    }
}

/// The in-memory store's answer: reachable, because it always is, and a round trip that
/// really does write, read and delete - which is the whole of what the check asserts off
/// Darwin.
public struct InMemoryKeychainDiagnostics: KeychainDiagnosing {
    private let store: any SecretsStore
    public init(store: any SecretsStore) { self.store = store }

    public func reachability() -> (ok: Bool, detail: String) {
        let count = (try? store.accounts().count) ?? 0
        return (true, "in-memory store: reachable, \(count) item(s)")
    }

    public func roundTrip(account: String, value: String) -> [String: Any] {
        try? store.removeSecret(forKey: account)
        let added = (try? store.setSecret(value, forKey: account)) != nil
        let readBack = (try? store.secret(forKey: account)) ?? nil
        try? store.removeSecret(forKey: account)
        return [
            "accessGroup": "in-memory",
            "account": account,
            "wrote": value,
            "readBack": readBack ?? "",
            "matched": readBack == value,
            "addStatus": added ? 0 : -1,
            "readStatus": readBack == nil ? -25300 : 0,
            "deleteStatus": 0,
            "addStatusText": "",
            "readStatusText": "",
        ]
    }
}

struct UnconfiguredLauncher: TransportLauncher {
    func connect(
        location: Location, askpassPath: String?, askpass: (any AskpassTokenProviding)?,
        uploadTag: String, reprobeChannels: Bool
    ) async throws -> any LiveConnection {
        throw SSHProcessError.connectionFailed(
            classification: .transient, stderr: "the agent is not configured")
    }
}

struct UnconfiguredEndpoint: AgentEndpoint {
    func terminate(status: Int32) { exit(status) }
}

extension AgentEnvironment {
    /// What `DomainManager.shared` holds until `bootstrap` replaces it.
    public static let unconfigured = AgentEnvironment(
        replica: UnconfiguredReplica(),
        secrets: InMemorySecretsStore(),
        loginItem: UnconfiguredLoginItem(),
        launchd: UnconfiguredLaunchd(),
        power: UnconfiguredPower(),
        network: UnconfiguredNetwork(),
        presence: UnconfiguredPresence(),
        screenLock: UnconfiguredScreenLock(),
        peers: UnconfiguredPeers(),
        readerPeers: UnconfiguredReaderPeers(),
        bundle: UnconfiguredBundle(),
        keychain: InMemoryKeychainDiagnostics(store: InMemorySecretsStore()),
        launcher: UnconfiguredLauncher(),
        endpoint: UnconfiguredEndpoint())
}

/// What `main.swift` calls once, before the role switch and whatever the role: the
/// `unregister` role needs the login item and launchd seams and the `app` role needs the
/// login item, so all three are configured the same way.
public enum AgentRuntimeBootstrap {
    /// Installs the process-wide agent: the seams, the secrets store and the broker the
    /// askpass listener answers from.
    @discardableResult
    public static func install(environment: AgentEnvironment) -> DomainManager {
        let secrets = AgentSecrets(
            store: environment.secrets,
            askpassPath: AskpassEnvironment.askpassPath(
                forExecutableAt: environment.bundle.executableURL))
        AgentSecrets.shared = secrets
        HelperDeployer.resourcesDirectory = environment.bundle.helperResourcesURL
        let manager = DomainManager(environment: environment, secrets: secrets)
        DomainManager.shared = manager
        return manager
    }
}
