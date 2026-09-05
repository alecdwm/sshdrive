import Foundation

/// The rule `sshdrive add` waits by, so the one capability report it prints agrees with
/// the `sshdrive status` the user runs a moment later (DESIGN.md sections 8, 8.1, 6.4).
///
/// The helper is deployed by the first change-detection cycle, which starts with the
/// location: at `add` time the ladder has already chosen tier 2 from the probe, and the
/// binary is still going up the wire. A report written in that window described a sweep
/// and blamed the server for it. So `add` waits - bounded, because a slow or refusing
/// server must not hold the command open - and whatever is not settled by then is
/// reported as `deploying`, never as "cannot run" (2026-09-05).
public enum HelperSettle {

    /// How long `add` waits. Milestone 9 measured a deployment at well under a second on
    /// a live connection (upload, `chmod`, `--version`, the `ready` handshake); this is
    /// that with room for a slow link, and short enough that a server which will never
    /// answer costs the command a few seconds and nothing more.
    public static let addSeconds: TimeInterval = 6

    public enum Step: Equatable {
        /// The state is knowable now: the stream is up, the deployment was refused with a
        /// reason, or there is no tier 2 on this server to wait for.
        case done
        /// Nothing has settled and there is time left.
        case wait
        /// The deadline passed with the deployment still in flight. The report says
        /// `deploying`; `status` will say what happened.
        case giveUp
    }

    /// - Parameters:
    ///   - tierIsHelper: the ladder is offering tier 2, which is the only case where
    ///     there is anything to wait for.
    ///   - streamRunning: the helper stream has finished its `ready` handshake.
    ///   - refusal: the concrete reason the deployment or the stream failed, if it has.
    public static func step(
        tierIsHelper: Bool, streamRunning: Bool, refusal: String?,
        elapsed: TimeInterval, timeout: TimeInterval = addSeconds
    ) -> Step {
        guard tierIsHelper else { return .done }
        if streamRunning { return .done }
        if let refusal, !refusal.isEmpty { return .done }
        return elapsed >= timeout ? .giveUp : .wait
    }
}
