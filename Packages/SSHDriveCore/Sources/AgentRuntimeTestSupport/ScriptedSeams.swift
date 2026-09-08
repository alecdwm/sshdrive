import AgentCore
import AgentRuntime
import Config
import Foundation
import SFTP
import SSHProcess
import Secrets
import XPCProtocols

// The rest of `docs/testing-architecture.md` section 2.3's table, in memory: a fake login
// item and launchd, scriptable power, network path, presence and screen lock, scripted
// peers, a recording reader table, a fake bundle and a fake transport launcher.

// MARK: The login item and launchd (section 10)

/// Records `register`/`unregister` and answers a status a scenario set.
///
/// It reproduces `MQ-062` on request: `register()` alone does **not** repair a
/// registration whose bundle was replaced, so with `bundleWasReplaced` set the status
/// stays `enabled` while the job is broken, and only `unregister()` clears it.
public final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    public enum Call: Equatable, Sendable { case register, unregister }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _status = "not registered"
    private var _bundleWasReplaced = false
    private var _registerError: Error?
    private var _unregisterError: Error?

    public init(status: String = "not registered") { self._status = status }

    public var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    /// The state `MQ-062` describes: the record names a bundle that is gone, every spawn
    /// fails, and `SMAppService` still says `enabled`.
    public func markBundleReplaced() {
        lock.lock(); _bundleWasReplaced = true; _status = "enabled"; lock.unlock()
    }

    /// Whether launchd's record still names the bundle that was replaced.
    public var isBroken: Bool { lock.lock(); defer { lock.unlock() }; return _bundleWasReplaced }

    public func failNextUnregister(with error: Error) {
        lock.lock(); _unregisterError = error; lock.unlock()
    }

    public func register() throws {
        lock.lock()
        _calls.append(.register)
        let error = _registerError
        _registerError = nil
        // `register()` is idempotent and not self-repairing: it returns success and leaves
        // the stale record exactly where it was.
        if !_bundleWasReplaced { _status = "enabled" }
        lock.unlock()
        if let error { throw error }
    }

    public func unregister() throws {
        lock.lock()
        _calls.append(.unregister)
        let error = _unregisterError
        _unregisterError = nil
        if error == nil {
            _bundleWasReplaced = false
            // `unregister()` returns, and `status` reports `notRegistered`, *before*
            // launchd has dropped the job. That gap is `FakeLaunchd`'s.
            _status = "not registered"
        }
        lock.unlock()
        if let error { throw error }
    }

    public func status() -> String { lock.lock(); defer { lock.unlock() }; return _status }
}

/// `launchctl print`, as a countdown: the job is still loaded for the first
/// `probesBeforeGone` answers and gone after that.
///
/// That countdown **is** `MQ-063`. A `register()` inside the window leaves the job
/// carrying the previous bundle's launch constraint and dying on a 10 s throttle for ever,
/// so what `P2` asserts is that the unregister role kept asking until this said no.
public final class FakeLaunchd: LaunchdControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    public private(set) var probes = 0

    public init(probesBeforeGone: Int = 0) { self.remaining = probesBeforeGone }

    public func serviceIsLoaded(label: String) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        probes += 1
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

// MARK: Power, the network path, presence and the screen lock

/// `IORegisterForSystemPower`, driven by hand. `willSleep()` and `didWake()` run the same
/// handlers the IOKit callback runs, and `await` them, so a scenario can assert on what
/// they did rather than on when.
public final class ScriptedPower: PowerObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var onWillSleep: (@Sendable () async -> Void)?
    private var onDidWake: (@Sendable () async -> Void)?
    public private(set) var willSleepCount = 0
    public private(set) var didWakeCount = 0

    public init() {}

    public func start(
        willSleep: @escaping @Sendable () async -> Void,
        didWake: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        onWillSleep = willSleep
        onDidWake = didWake
        lock.unlock()
    }

    public func sleepNow() async {
        lock.lock()
        willSleepCount += 1
        let hook = onWillSleep
        lock.unlock()
        await hook?()
    }

    public func wake() async {
        lock.lock()
        didWakeCount += 1
        let hook = onDidWake
        lock.unlock()
        await hook?()
    }

    public var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["willSleep": willSleepCount, "didWake": didWakeCount, "registered": true]
    }
}

/// `NWPathMonitor`, driven by hand.
public final class ScriptedNetwork: NetworkPathObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable (Bool) async -> Void)?
    public private(set) var available = true
    public private(set) var changes = 0

    public init() {}

    public func start(changed: @escaping @Sendable (Bool) async -> Void) {
        lock.lock(); onChange = changed; lock.unlock()
    }

    public func setAvailable(_ value: Bool) async {
        lock.lock()
        guard value != available else { lock.unlock(); return }
        available = value
        changes += 1
        let hook = onChange
        lock.unlock()
        await hook?(value)
    }

    public var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["status": available ? "satisfied" : "unsatisfied", "changes": changes]
    }
}

/// Section 4.2's two readings, set by a scenario. The default is the honest one for a
/// machine nobody is at: idle for ever, screen locked.
public final class ScriptedPresence: PresenceReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: PresenceReading

    public init(
        reading: PresenceReading = PresenceReading(
            secondsSinceLastInputEvent: 3600, screenLocked: true)
    ) {
        self.reading = reading
    }

    public func set(idleSeconds: TimeInterval, screenLocked: Bool) {
        lock.lock()
        reading = PresenceReading(
            secondsSinceLastInputEvent: idleSeconds, screenLocked: screenLocked)
        lock.unlock()
    }

    /// The reading section 4.2 calls "a human is demonstrably present".
    public func setPresent() { set(idleSeconds: 1, screenLocked: false) }

    public func read() -> PresenceReading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    public var isOverridden: Bool { true }
}

/// `com.apple.screenIsUnlocked` / `com.apple.screenIsLocked`, driven by hand, because a
/// headless machine cannot lock or unlock a screen.
public final class ScriptedScreenLock: ScreenLockObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var onUnlocked: (@Sendable () async -> Void)?
    private var onLocked: (@Sendable () async -> Void)?
    public private(set) var unlocks = 0
    public private(set) var locks = 0

    public init() {}

    public func start(
        unlocked: @escaping @Sendable () async -> Void,
        locked: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        onUnlocked = unlocked
        onLocked = locked
        lock.unlock()
    }

    public func unlock() async {
        lock.lock()
        unlocks += 1
        let hook = onUnlocked
        lock.unlock()
        await hook?()
    }

    public func lockScreen() async {
        lock.lock()
        locks += 1
        let hook = onLocked
        lock.unlock()
        await hook?()
    }

    public var report: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["unlocks": unlocks, "locks": locks]
    }
}

// MARK: Peers

/// Which executable a pid is, from a table a scenario wrote (section 5.2).
public struct ScriptedPeers: PeerIdentifying {
    public var paths: [Int32: String]
    public init(paths: [Int32: String] = [:]) { self.paths = paths }
    public func executablePath(pid: Int32) -> String? { paths[pid] }
    public func isCLI(pid: Int32) -> Bool {
        guard let path = paths[pid] else { return false }
        return (path as NSString).lastPathComponent == "sshdrive"
    }
}

/// The extension readers section 5.3's restore has to ask to close before it truncates the
/// sidecars under them. Records both calls; a scenario asserts the *order* against the
/// truncate.
public final class RecordingReaderPeers: IndexReaderPeering, @unchecked Sendable {
    public enum Call: Equatable, Sendable { case close, reopen }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _count: Int

    public init(peerCount: Int = 1) { self._count = peerCount }

    public var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    public func closeReaders() async {
        lock.lock(); _calls.append(.close); lock.unlock()
    }

    public func reopenReaders() {
        lock.lock(); _calls.append(.reopen); lock.unlock()
    }

    public var peerCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

// MARK: The bundle

/// A bundle described by a scenario: where it is, whether it is quarantined, what
/// PlugInKit says, and the inode of the executable, which the upgrade handover compares.
public final class FakeBundle: BundleInspecting, @unchecked Sendable {
    private let lock = NSLock()
    public var bundleURL: URL
    public var executableURL: URL
    public var helperResourcesURL: URL?
    private var quarantine: [String: String] = [:]
    private var plugIn: String?
    private var inodes: [String: UInt64] = [:]
    private var identifiers: [String: String] = [:]
    private var readable: Set<String> = []
    public var operatingSystemVersion: (major: Int, minor: Int, patch: Int)

    public init(
        bundleURL: URL = URL(fileURLWithPath: "/Applications/SSH Drive.app"),
        executableURL: URL = URL(
            fileURLWithPath: "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"),
        version: (major: Int, minor: Int, patch: Int) = (26, 4, 0)
    ) {
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.operatingSystemVersion = version
    }

    public func setQuarantine(_ value: String?, atPath path: String) {
        lock.lock()
        if let value { quarantine[path] = value } else { quarantine.removeValue(forKey: path) }
        lock.unlock()
    }

    public func setPlugInRegistration(_ line: String?) {
        lock.lock(); plugIn = line; lock.unlock()
    }

    /// The two facts section 10.1's handover reads: the executable's inode and the
    /// bundle's `CFBundleIdentifier`. Setting them is how a scenario stages a half-copied
    /// bundle, a replaced one, and a `brew reinstall` of the same version.
    public func setInode(_ inode: UInt64?, atPath path: String) {
        lock.lock()
        if let inode { inodes[path] = inode } else { inodes.removeValue(forKey: path) }
        lock.unlock()
    }

    public func setBundleIdentifier(_ identifier: String?, atPath path: String) {
        lock.lock()
        if let identifier {
            identifiers[path] = identifier
        } else {
            identifiers.removeValue(forKey: path)
        }
        lock.unlock()
    }

    public func quarantineValue(atPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return quarantine[path]
    }

    public func plugInRegistration(bundleID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return plugIn
    }

    /// A path is readable once something has been staged at it; a half-copied bundle is
    /// one whose executable has a new inode and whose `Info.plist` is not there yet.
    public func setReadable(_ value: Bool, atPath path: String) {
        lock.lock()
        if value { readable.insert(path) } else { readable.remove(path) }
        lock.unlock()
    }

    public func isReadable(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readable.contains(path) || inodes[path] != nil
    }

    public func inode(ofPath path: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return inodes[path]
    }

    public func bundleIdentifier(atPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return identifiers[path]
    }
}

// MARK: The endpoint

/// Records the exit status instead of taking the process with it, which is what lets `P4`
/// assert that SIGTERM exits **0** - `KeepAlive`/`SuccessfulExit` reads any other status
/// as a crash and restarts the old bundle.
public final class RecordingEndpoint: AgentEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [Int32] = []

    public init() {}

    public var statuses: [Int32] { lock.lock(); defer { lock.unlock() }; return _statuses }

    public func terminate(status: Int32) {
        lock.lock(); _statuses.append(status); lock.unlock()
    }
}
