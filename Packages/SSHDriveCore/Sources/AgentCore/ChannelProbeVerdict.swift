import Foundation

/// Why a channel did not open, when the answer decides whether a `MaxSessions` budget may
/// be recorded (docs/design/ssh.md).
///
/// The `MaxSessions` probe opens channels until one is refused and turns the count into
/// the location's whole channel budget - two SFTP channels or one, an exec channel or
/// none, a *held* exec channel for tier 2 or not - and caches it in `capabilities.json`.
///
/// That is sound only while a channel that did not open means the **server** said no. It
/// does not: `ssh` fails a channel open just as readily because the master it was speaking
/// to has gone, and a measurement taken in that moment is cached as a fact about the
/// server. Killing `ssh` under a running agent brings the location up reporting "the
/// server allows one channel at a time (MaxSessions 1) … SFTP-only", with no helper and no
/// shell, against a server whose sshd is healthy. A handshake that stalls on a live master
/// does the same, and so does any wording nobody here has seen. So the probe tells three
/// answers apart, and only the first is ever cached.
public enum ChannelProbeVerdict: String, Sendable, Equatable {
    /// The server granted no more sessions, in the words `ssh` uses for exactly that:
    /// `mux_client_request_session: session request failed`, or an `administratively
    /// prohibited` open. A fact about the server, and the only verdict that may be cached.
    case sessionRefused
    /// The connection went while the channel was being opened. This is a fact about the
    /// moment and must not be cached; the connect attempt fails instead and the breaker
    /// tries again (docs/design/offline.md).
    case connectionDied
    /// Anything else on a master that is still running: a handshake that missed its
    /// deadline, an empty stderr, wording that is neither a refusal nor a death. The
    /// connection runs on the channels it did get, and nothing is cached, so the next
    /// connect - or the re-check on this one - asks again.
    case inconclusive

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

    /// A refusal is only a refusal while the master is still there to have relayed it, and
    /// only when `ssh` says so in its own words.
    ///
    /// - Parameters:
    ///   - diagnostics: `ssh`'s own stderr from the mux client, which is the only
    ///     explanation a refused session ever gives, or the error the handshake failed
    ///     with when stderr was empty.
    ///   - masterIsRunning: whether the `-N` master process is still alive.
    public static func classify(diagnostics: String, masterIsRunning: Bool) -> ChannelProbeVerdict {
        guard masterIsRunning else { return .connectionDied }
        let text = diagnostics.lowercased()
        if refusalMarkers.contains(where: { text.contains($0) }) { return .sessionRefused }
        if deathMarkers.contains(where: { text.contains($0) }) { return .connectionDied }
        return .inconclusive
    }

    /// The two ways `ssh` reports a session the server would not grant.
    static let refusalMarkers = ["session request failed", "administratively prohibited"]
}
