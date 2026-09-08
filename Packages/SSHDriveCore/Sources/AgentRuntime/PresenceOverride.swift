import Foundation
import AgentCore
import Config

/// The spike's presence override (DESIGN.md section 4.2).
///
/// A headless VM's console session reports an input-idle time that only grows and a screen
/// that can never be locked, so the real readings there are meaningless and S5's re-arm
/// questions could not otherwise be asked. The override is `idle=<seconds>,locked=<0|1>`,
/// read from `<group container>/presence-override` and, failing that, from the
/// `SSHDRIVE_PRESENCE_OVERRIDE` environment variable.
///
/// The file is the one that works. `launchctl setenv` does **not** reach a launchd agent
/// on macOS 26 (`MQ-067`, measured 2026-09-04): the value is set in the user's session but
/// the job started from the bundle's `LaunchAgents` plist does not inherit it. The
/// environment spelling is kept because it costs one line and is the right shape for a
/// harness that spawns the agent itself.
///
/// It is read on every call, so writing the file is enough - no restart.
public enum PresenceOverride {

    public static var fileURL: URL? {
        try? GroupContainer.requireURL().appendingPathComponent("presence-override")
    }

    /// The override reading, or nil when none is set.
    public static func reading(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PresenceReading? {
        var text: String? = environment["SSHDRIVE_PRESENCE_OVERRIDE"]
        if let url = fileURL, let fromFile = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = fromFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { text = trimmed }
        }
        guard let raw = text, !raw.isEmpty else { return nil }
        return parse(raw)
    }

    /// `idle=12,locked=1`. Unparseable fields are skipped rather than failing the whole
    /// reading: the file is written by a runbook step, not by us.
    public static func parse(_ raw: String) -> PresenceReading {
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

    /// `sshdrive doctor` and `debug presence`.
    public static func report(_ presence: any PresenceReporting) -> [String: Any] {
        let reading = presence.read()
        return [
            "secondsSinceLastInputEvent": reading.secondsSinceLastInputEvent.rounded(toPlaces: 2),
            "screenLocked": reading.screenLocked,
            "userIsPresent": reading.userIsPresent,
            "overridden": presence.isOverridden,
            "idleLimitSeconds": DeadlineRearmState.presenceIdleLimitSeconds,
        ]
    }
}
