import Foundation

/// `doctor`'s line for one location's index reader, read from the `reader-state.json` the
/// File Provider extension writes beside the index (docs/design/extension.md).
///
/// The extension is sandboxed, short-lived and not running most of the time, so the file
/// holds the last thing an instance said about its reader. `ready` passes, and so does
/// `exited`: that is an instance the system tore down, which is the ordinary state between
/// two uses of a mount. `closed` is a reader a restore shut for its truncate window and
/// that never heard the reopen, and `unknown`, `not-ready`, `failed` and `schema-too-new`
/// are readers an instance could not use. Those warn rather than fail, because every read
/// falls back to the agent.
public struct ReaderStateReport: Equatable, Sendable {
    /// `true` passes, `nil` warns. The check never fails.
    public var ok: Bool?
    public var detail: String
    public var remedy: String?

    public init(ok: Bool?, detail: String, remedy: String?) {
        self.ok = ok
        self.detail = detail
        self.remedy = remedy
    }

    /// The line for a location whose extension has never written the file.
    public static let neverReported = ReaderStateReport(
        ok: nil, detail: "the extension has never reported its reader",
        remedy: "Open the location in Finder once. If this stays empty the "
            + "extension is not running; see the \"extension registered\" check.")

    static let fallbackRemedy =
        "Every read falls back to the agent over XPC, so the location still "
        + "works; a reader that stays unready is slower and worth reporting."

    /// The line for a decoded state file, as of `now`.
    public init(stateFile object: [String: Any], now: Date) {
        let state = (object["state"] as? String) ?? "unknown"
        let at = (object["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let age = at.map { "\(Int(now.timeIntervalSince($0))) s ago" } ?? "at an unknown time"
        let generation = (object["generation"] as? Int64) ?? -1
        let lastError = (object["lastError"] as? String) ?? ""
        let path = (object["path"] as? String) ?? ""

        var detail: String
        switch state {
        case "exited":
            detail = "last extension instance exited \(age), generation \(generation)"
        default:
            detail = "\(state), generation \(generation), reported \(age)"
        }
        if !lastError.isEmpty { detail += "; last error: \(lastError)" }
        if !path.isEmpty { detail += "; \(path)" }

        let ok: Bool? = (state == "ready" || state == "exited") ? true : nil
        self.init(ok: ok, detail: detail, remedy: ok == true ? nil : Self.fallbackRemedy)
    }
}
