import Foundation

/// Why a channel did not open, when the answer decides whether a `MaxSessions` budget may
/// be recorded (DESIGN.md section 6.1).
///
/// The probe of section 6.1 opens channels until one is refused and turns the count into
/// the location's whole channel budget - two SFTP channels or one, an exec channel or
/// none, a *held* exec channel for tier 2 or not - and caches it in
/// `capabilities.json`, where "an explicit re-probe is its only invalidation".
///
/// That is sound only while a channel that did not open means the **server** said no. It
/// does not: `ssh` fails a channel open just as readily because the master it was speaking
/// to has gone, and a measurement taken in that moment is cached as a fact about the
/// server. Measured on a real install (2026-09-08): after `ssh` was killed under a running
/// agent the location came up reporting "the server allows one channel at a time
/// (MaxSessions 1) … SFTP-only", with no helper and no shell, against a `deb` whose sshd
/// was healthy - and it stayed that way across restarts and reconnects, because nothing
/// re-probes. So the probe has to tell the two apart, and record nothing when the
/// connection is what failed.
///
/// The default is `sessionRefused`, deliberately: an unfamiliar sshd that refuses a
/// session with wording we have never seen must still produce a budget, or the location
/// would retry for ever instead of settling at the tier it can actually run.
public enum ChannelProbeVerdict: String, Sendable, Equatable {
    /// The server granted no more sessions. This is a fact about the server and may be
    /// cached: `mux_client_request_session: session request failed`.
    case sessionRefused
    /// The connection went while the channel was being opened. This is a fact about the
    /// moment and must not be cached; the connect attempt fails instead and section 6.3's
    /// breaker tries again.
    case connectionDied

    /// Phrases `ssh` prints when the master, the mux socket or the TCP connection is what
    /// failed, rather than the server refusing a session. Matched case-insensitively on
    /// `ssh`'s own stderr.
    static let deathMarkers = [
        "control socket connect",
        "controlsocket",
        "mux_client_hello_exchange",
        "mux_client_forward",
        "broken pipe",
        "connection closed",
        "connection reset",
        "connection to",
        "no such file or directory",
        "connection refused",
        "socket is not connected",
        "operation timed out",
        "network is unreachable",
        "host is down",
        "no route to host",
        "connectionlost",
        "noconnection",
        "the connection was lost",
    ]

    /// A refusal is only a refusal while the master is still there to have relayed it.
    ///
    /// - Parameters:
    ///   - diagnostics: `ssh`'s own stderr from the mux client, which is the only
    ///     explanation a refused session ever gives.
    ///   - masterIsRunning: whether the `-N` master process is still alive.
    public static func classify(diagnostics: String, masterIsRunning: Bool) -> ChannelProbeVerdict {
        guard masterIsRunning else { return .connectionDied }
        let text = diagnostics.lowercased()
        if text.contains("session request failed") { return .sessionRefused }
        if text.contains("administratively prohibited") { return .sessionRefused }
        if deathMarkers.contains(where: { text.contains($0) }) { return .connectionDied }
        return .sessionRefused
    }
}
