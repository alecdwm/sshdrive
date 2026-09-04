import Foundation
import CoreGraphics
import AgentCore
import Config
import Logging

/// Is a human at this Mac? (DESIGN.md section 4.2.)
///
/// Two readings, both of which a launchd agent may take without any permission and
/// without an `NSApplication`:
///
/// - **`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .any)`**
///   - the time since the last keyboard, mouse or trackpad event. Section 4.2 requires it
///   to be under 30 s.
/// - **`CGSSessionScreenIsLocked` from `CGSessionCopyCurrentDictionary()`** - the screen
///   must be unlocked. The key is absent, rather than false, on an unlocked session.
///
/// Why this and not "a File Provider request arrived": Spotlight, Quick Look, Finder's
/// background refreshes and the working-set enumerator issue requests on an unattended Mac
/// all day. Each would re-arm an attempt, block for 60 s on a key agent's prompt with
/// nobody there, time out, and hand the trigger to the next request - the exact loop
/// section 4.2's rule exists to prevent.
///
/// The **presence override** exists for the spike: a headless VM's console session reports
/// an input-idle time that only grows and a screen that can never be locked, so the real
/// readings there are meaningless and S5's re-arm questions could not otherwise be asked.
/// It is `idle=<seconds>,locked=<0|1>`, read from
/// `<group container>/presence-override` and, failing that, from the
/// `SSHDRIVE_PRESENCE_OVERRIDE` environment variable.
///
/// The file is the one that works. `launchctl setenv` does **not** reach a launchd agent
/// on macOS 26 - the value is set in the user's session but the job started from the
/// bundle's `LaunchAgents` plist does not inherit it, even across `sshdrive agent restart`,
/// and `debug presence` then reports `overridden: false` with the machine's real idle time
/// (measured 2026-09-04). The environment spelling is kept because it costs one line and is
/// the right shape for a test harness that spawns the agent itself.
///
/// It is read on every call, so writing the file is enough - no restart.
enum AgentPresence {

    /// What the last read said, for `sshdrive doctor` and `debug presence`.
    static func read() -> PresenceReading {
        if let override = overrideReading() { return override }
        return PresenceReading(
            secondsSinceLastInputEvent: secondsSinceLastInputEvent(),
            screenLocked: screenIsLocked())
    }

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

    /// Whether the reading is a real one or the spike override, so the runbook can never
    /// mistake one for the other.
    static var isOverridden: Bool { overrideReading() != nil }

    /// `<group container>/presence-override`, which is the spelling that works.
    static var overrideFileURL: URL? {
        try? GroupContainer.requireURL().appendingPathComponent("presence-override")
    }

    private static func overrideReading() -> PresenceReading? {
        var text: String? = ProcessInfo.processInfo.environment["SSHDRIVE_PRESENCE_OVERRIDE"]
        if let url = overrideFileURL, let fromFile = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = fromFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { text = trimmed }
        }
        guard let raw = text, !raw.isEmpty else { return nil }
        var idle: TimeInterval = 0
        var locked = false
        for field in raw.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "idle": idle = TimeInterval(parts[1]) ?? 0
            case "locked": locked = parts[1] == "1" || parts[1] == "true"
            default: break
            }
        }
        return PresenceReading(secondsSinceLastInputEvent: idle, screenLocked: locked)
    }

    static func report() -> [String: Any] {
        let reading = read()
        return [
            "secondsSinceLastInputEvent": reading.secondsSinceLastInputEvent.rounded(toPlaces: 2),
            "screenLocked": reading.screenLocked,
            "userIsPresent": reading.userIsPresent,
            "overridden": isOverridden,
            "idleLimitSeconds": DeadlineRearmState.presenceIdleLimitSeconds,
        ]
    }
}

/// The two distributed notifications the screen lock posts, and the one thing the agent
/// does with them (section 4.2).
///
/// `com.apple.screenIsUnlocked` re-arms one attempt on every location stopped by the
/// authentication deadline. `com.apple.screenIsLocked` is observed only so the log can
/// say why an `agentDependent` location is making no attempt.
final class ScreenLockObserver {
    static let shared = ScreenLockObserver()
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")

    private var observers: [NSObjectProtocol] = []
    private(set) var unlocks = 0
    private(set) var locks = 0

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(
            center.addObserver(
                forName: Self.unlockedNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.unlocks += 1
                Log.agent.notice("screen unlocked")
                Task { await DomainManager.shared.screenUnlocked() }
            })
        observers.append(
            center.addObserver(
                forName: Self.lockedNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.locks += 1
                Log.agent.notice("screen locked")
            })
    }

    /// `sshdrive debug rearm --unlock` drives the same path a real unlock does, because a
    /// headless VM cannot lock or unlock a screen.
    func simulateUnlock() async {
        unlocks += 1
        Log.agent.notice("screen unlock simulated by a debug hook")
        await DomainManager.shared.screenUnlocked()
    }

    var report: [String: Any] { ["unlocks": unlocks, "locks": locks] }
}
