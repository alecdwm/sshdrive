import AgentCore
import AgentRuntime
import Config
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Logging
import Network
import Security
import Secrets
import ServiceManagement
import XPCProtocols

// The Darwin half of every seam that is not the replica or the transport
// (docs/design/testing.md). One adapter each, and no branch worth testing: every decision
// sits above them in `AgentRuntime`.

// MARK: Sleep and wake (docs/design/ssh.md)

/// **Sleep and wake come from IOKit**, `IORegisterForSystemPower` with
/// `kIOMessageSystemWillSleep` and `kIOMessageSystemHasPoweredOn`, and not from
/// `NSWorkspace`: the agent runs no `NSApplication`.
///
/// The will-sleep message must be **acknowledged**, and the sleep does not proceed until
/// it is or until the system's own timeout (about 30 s) expires. `-O exit` on a handful of
/// masters is a few hundred milliseconds, so the acknowledgement is sent after the drop
/// rather than before it, with a hard 5 s cap so a wedged `ssh` can never delay a lid
/// close. Everything the drop itself does is `DomainManager.willSleep`.
final class IOKitPowerEvents: PowerObserving, @unchecked Sendable {
    static let shared = IOKitPowerEvents()

    /// The three `IOMessage.h` constants this needs. They are C macros
    /// (`iokit_common_msg(0x280)`), not enum cases, so Swift does not import them and they
    /// are spelled out here with the arithmetic that produces them:
    /// `sys_iokit | sub_iokit_common | code`, which is `0xE0000000 | code`.
    private static let systemWillSleep: UInt32 = 0xE000_0280  // iokit_common_msg(0x280)
    private static let canSystemSleep: UInt32 = 0xE000_0270  // iokit_common_msg(0x270)
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300  // iokit_common_msg(0x300)

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private(set) var willSleepCount = 0
    private(set) var didWakeCount = 0
    private var onWillSleep: (@Sendable () async -> Void)?
    private var onDidWake: (@Sendable () async -> Void)?

    /// How long the will-sleep handler may spend dropping masters before it acknowledges
    /// anyway. The system's own limit is around 30 s; nothing here should need one.
    static let willSleepGraceSeconds: Double = 5

    func start(
        willSleep: @escaping @Sendable () async -> Void,
        didWake: @escaping @Sendable () async -> Void
    ) {
        onWillSleep = willSleep
        onDidWake = didWake

        var notificationPort: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let reference = Unmanaged.passUnretained(self).toOpaque()

        let connect = IORegisterForSystemPower(
            reference, &notificationPort,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let events = Unmanaged<IOKitPowerEvents>.fromOpaque(context)
                    .takeUnretainedValue()
                events.handle(messageType: messageType, argument: messageArgument)
            }, &notifierObject)

        guard connect != 0, let notificationPort else {
            Log.agent.error("IORegisterForSystemPower failed; sleep and wake will not be seen")
            return
        }
        rootPort = connect
        port = notificationPort
        notifier = notifierObject
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
            .defaultMode)
        Log.agent.notice("registered for system power notifications")
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.systemWillSleep:
            willSleepCount += 1
            Log.agent.notice("system will sleep: dropping every master")
            let rootPort = self.rootPort
            let token = intptr_t(bitPattern: argument)
            let acknowledged = Acknowledgement()
            let hook = onWillSleep
            Task {
                await hook?()
                if acknowledged.claim() { IOAllowPowerChange(rootPort, token) }
            }
            // The cap. Whatever happens to the drop, the Mac sleeps.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.willSleepGraceSeconds) {
                if acknowledged.claim() {
                    Log.agent.error("will-sleep drop did not finish in time; acknowledging anyway")
                    IOAllowPowerChange(rootPort, token)
                }
            }

        case Self.canSystemSleep:
            // Idle sleep. Nothing to object to; refusing would keep a laptop awake.
            IOAllowPowerChange(rootPort, intptr_t(bitPattern: argument))

        case Self.systemHasPoweredOn:
            didWakeCount += 1
            Log.agent.notice("system has powered on: reconnecting every location")
            let hook = onDidWake
            Task { await hook?() }

        default:
            break
        }
    }

    /// `IOAllowPowerChange` must be called exactly once per will-sleep message.
    private final class Acknowledgement: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    var report: [String: Any] {
        ["willSleep": willSleepCount, "didWake": didWakeCount, "registered": port != nil]
    }
}

// MARK: The network path (docs/design/offline.md)

/// The first rule of failing fast: `NWPathMonitor` says there is no path at all, and every
/// call is `.serverUnreachable` immediately without a socket being opened. It covers
/// Wi-Fi off and a cable pulled, and deliberately not a powered-down NAS or a tailnet that
/// is down while the Mac is online - that is what the breaker is for.
final class NWPathNetworkGate: NetworkPathObserving, @unchecked Sendable {
    static let shared = NWPathNetworkGate()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.shirls.sshdrive.path")
    private(set) var lastStatus: NWPath.Status = .satisfied
    private(set) var changes = 0

    func start(changed: @escaping @Sendable (Bool) async -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let moved = path.status != self.lastStatus
            self.lastStatus = path.status
            guard moved else { return }
            self.changes += 1
            Log.agent.notice(
                "network path is now \(String(describing: path.status), privacy: .public)")
            Task { await changed(satisfied) }
        }
        monitor.start(queue: queue)
    }

    var report: [String: Any] {
        ["status": String(describing: lastStatus), "changes": changes]
    }
}

// MARK: Presence (docs/design/secrets.md)

/// Is a human at this Mac? Two readings, both of which a launchd agent may take without
/// any permission and without an `NSApplication`:
///
/// - **`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .any)`**
///   - the time since the last keyboard, mouse or trackpad event. It must be under 30 s
///   for the deadline to re-arm.
/// - **`CGSSessionScreenIsLocked` from `CGSessionCopyCurrentDictionary()`** - the screen
///   must be unlocked. The key is absent, rather than false, on an unlocked session.
///
/// Why this and not "a File Provider request arrived": Spotlight, Quick Look, Finder's
/// background refreshes and the working-set enumerator issue requests on an unattended Mac
/// all day, and each would re-arm an attempt with nobody there.
///
/// The override (`PresenceOverride`, in the package) is read first, because a headless
/// VM's console session reports an idle time that only grows and a screen that can never
/// be locked.
struct CoreGraphicsPresence: PresenceReporting {
    func read() -> PresenceReading {
        if let override = PresenceOverride.reading() { return override }
        return PresenceReading(
            secondsSinceLastInputEvent: Self.secondsSinceLastInputEvent(),
            screenLocked: Self.screenIsLocked())
    }

    var isOverridden: Bool { PresenceOverride.reading() != nil }

    static func secondsSinceLastInputEvent() -> TimeInterval {
        // `.combinedSessionState` is the one that sees events from every process in the
        // session, which is what "the user touched this Mac" means; `.hidSystemState`
        // misses anything synthesised.
        //
        // "any input event" is `kCGAnyInputEventType`, which is `0xFFFFFFFF` and has no
        // Swift case on `CGEventType`: `.any` does not compile. Asking for one concrete
        // type instead - a key down, say - would miss a user who only moved the mouse.
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
    }

    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No console session at all - a headless VM over ssh, or the login window
            // before anyone has logged in. Neither is "a human is present", so it counts
            // as locked.
            return true
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// The two distributed notifications the screen lock posts (docs/design/secrets.md).
///
/// `com.apple.screenIsUnlocked` re-arms one attempt on every location stopped by the
/// authentication deadline. `com.apple.screenIsLocked` is observed only so the log can say
/// why an `agentDependent` location is making no attempt.
final class DistributedScreenLockObserver: ScreenLockObserving, @unchecked Sendable {
    static let shared = DistributedScreenLockObserver()
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")

    private var observers: [NSObjectProtocol] = []
    private(set) var unlocks = 0
    private(set) var locks = 0

    func start(
        unlocked: @escaping @Sendable () async -> Void,
        locked: @escaping @Sendable () async -> Void
    ) {
        let center = DistributedNotificationCenter.default()
        observers.append(
            center.addObserver(
                forName: Self.unlockedNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.unlocks += 1
                Log.agent.notice("screen unlocked")
                Task { await unlocked() }
            })
        observers.append(
            center.addObserver(
                forName: Self.lockedNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.locks += 1
                Log.agent.notice("screen locked")
                Task { await locked() }
            })
    }

    var report: [String: Any] { ["unlocks": unlocks, "locks": locks] }
}

// MARK: The login item and launchd (docs/design/packaging.md)

/// `SMAppService.agent(plistName:)`. Registration is idempotent and is done on every
/// launch rather than checking `status` first; it is not self-repairing, which is why the
/// `unregister` role exists (`MQ-062`, `MQ-063`).
struct SMAppServiceLoginItem: LoginItemControlling {
    private var service: SMAppService {
        SMAppService.agent(plistName: "\(SSHDriveIdentifiers.agentLabel).plist")
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }

    func status() -> String { Self.name(of: service.status) }

    /// Split out so the macOS-only `MirroredAgentConstantsTests` can assert the mapping
    /// against Apple's own cases; `doctor` prints the string and only `enabled` is a pass.
    static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return MirroredAgentConstants.loginItemEnabled
        case .requiresApproval: return MirroredAgentConstants.loginItemRequiresApproval
        case .notRegistered: return MirroredAgentConstants.loginItemNotRegistered
        case .notFound: return MirroredAgentConstants.loginItemNotFound
        @unknown default: return MirroredAgentConstants.loginItemUnknown
        }
    }
}

/// `launchctl print gui/<uid>/<label>`, which is the only thing that can see the window
/// `SMAppService.unregister()` returns inside: it answers non-zero once the service is
/// gone from the GUI domain, while `SMAppService.status` already says `notRegistered`.
struct LaunchctlControl: LaunchdControlling {
    func serviceIsLoaded(label: String) async -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        probe.arguments = ["print", label]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }
}

// MARK: The bundle (docs/design/packaging.md)

/// Everything the agent can learn about the bundle it runs from: the paths, the shipped
/// helper binaries, `com.apple.quarantine`, PlugInKit's view of the extension, and the
/// `stat` and `Info.plist` reads the upgrade handover compares.
struct RunningBundle: BundleInspecting {
    var bundleURL: URL { Bundle.main.bundleURL }

    var executableURL: URL {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                .resolvingSymlinksInPath()
    }

    var helperResourcesURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helper", isDirectory: true)
    }

    func quarantineValue(atPath path: String) -> String? {
        BundleQuarantine.attributeValue(atPath: path)
    }

    func plugInRegistration(bundleID: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-A", "-i", bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `pluginkit -m -A` prints a one-character enabled flag before the identifier
        // ("+   org.shirls.sshdrive.fileprovider(0.1.0)"), which reads as noise in a
        // doctor line. The flag is not the answer to this check - a line at all is - so it
        // is trimmed off.
        var text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, "+-?!".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }

    /// Every path LaunchServices holds a record for under `bundleID`. `lsregister -dump`
    /// is the only way to ask it, and it prints every record on the machine - tens of
    /// thousands of lines - so the output is read to the end before the process is waited
    /// on, and `LaunchServicesDump` picks the paths out of it (`MQ-081`).
    func launchServicesRecordPaths(bundleID: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AgentLifecycle.lsregisterPath)
        process.arguments = ["-dump"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return LaunchServicesDump.recordPaths(
            in: String(decoding: data, as: UTF8.self), identifier: bundleID)
    }

    /// `lsregister -u <path>`, which drops the record for one bundle path without
    /// touching the bundle itself. The path may no longer exist - a record for a detached
    /// volume is the case this is here for - and the command still answers 0.
    func unregisterLaunchServicesRecord(atPath path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AgentLifecycle.lsregisterPath)
        process.arguments = ["-u", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `lsregister -f -R -trusted` on our own bundle: force, recursive, and trusting the
    /// signature already on disk. It rebuilds the bundle's LaunchServices record, which is
    /// what makes PlugInKit discover the appex once the records answering for us are gone
    /// (`MQ-081`). The binary is not on any PATH and is spelled absolutely.
    func forceLaunchServicesRegistration() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AgentLifecycle.lsregisterPath)
        process.arguments = ["-f", "-R", "-trusted", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

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

// MARK: The keychain, as `doctor` asks about it

/// The two questions about the data-protection keychain that are not "store this secret",
/// under the shared access group, from the only process that has `keychain-access-groups`
/// (docs/design/components.md).
struct KeychainDiagnostics: KeychainDiagnosing {

    /// One `SecItemCopyMatching` under our access group. An `errSecItemNotFound` is a
    /// pass: it means the query was accepted and the group is reachable.
    func reachability() -> (ok: Bool, detail: String) {
        let group = SSHDriveIdentifiers.keychainAccessGroup
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretsStore.service,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            let count = (item as? [Any])?.count ?? 0
            return (true, "\(group): reachable, \(count) item(s)")
        case errSecItemNotFound:
            return (true, "\(group): reachable, no items yet")
        default:
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return (false, "\(group): \(text)")
        }
    }

    /// One `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` round trip. The
    /// entitlement is restricted, so it only works from a bundle that embeds a
    /// provisioning profile; this is what proves it live.
    func roundTrip(account: String, value: String) -> [String: Any] {
        let group = KeychainSecretsStore().accessGroup
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretsStore.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
        ]

        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)

        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        let readBack = (item as? Data).map { String(decoding: $0, as: UTF8.self) }

        let deleteStatus = SecItemDelete(base as CFDictionary)

        return [
            "accessGroup": group,
            "account": account,
            "wrote": value,
            "readBack": readBack ?? "",
            "matched": readBack == value,
            "addStatus": Int(addStatus),
            "readStatus": Int(readStatus),
            "deleteStatus": Int(deleteStatus),
            "addStatusText": SecCopyErrorMessageString(addStatus, nil) as String? ?? "",
            "readStatusText": SecCopyErrorMessageString(readStatus, nil) as String? ?? "",
        ]
    }
}

// MARK: The endpoint

/// The listener's own exit. The agent is a launchd job with no run loop of its own beyond
/// `dispatchMain()`, so "stop serving" is `exit`.
struct ProcessAgentEndpoint: AgentEndpoint {
    func terminate(status: Int32) { exit(status) }
}

// MARK: The environment this build runs with

extension AgentEnvironment {
    /// Every Darwin adapter in one value. `main.swift` installs it before anything else.
    static var runningOnMacOS: AgentEnvironment {
        AgentEnvironment(
            replica: FileProviderReplica(),
            secrets: KeychainSecretsStore(
                accessGroup: SSHDriveIdentifiers.keychainAccessGroup),
            loginItem: SMAppServiceLoginItem(),
            launchd: LaunchctlControl(),
            power: IOKitPowerEvents.shared,
            network: NWPathNetworkGate.shared,
            presence: CoreGraphicsPresence(),
            screenLock: DistributedScreenLockObserver.shared,
            peers: PeerExecutable(),
            readerPeers: ExtensionPeers.shared,
            bundle: RunningBundle(),
            keychain: KeychainDiagnostics(),
            launcher: SSHTransportLauncher(),
            endpoint: ProcessAgentEndpoint())
    }
}
