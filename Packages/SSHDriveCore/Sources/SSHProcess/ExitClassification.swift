import Foundation

/// Which of our `ssh` processes exited. The role decides some classifications outright,
/// so it is an input and not a label (DESIGN.md section 6.1).
public enum SSHRole: String, Sendable, Equatable {
    /// The `-N` ControlMaster.
    case master
    /// A mux client: an SFTP channel or an exec channel.
    case muxClient
    /// `-O check` / `-O exit`.
    case controlCommand
    /// The two-pass verification connection `add` and `passwd` make (section 4.2).
    case collect
}

/// What the agent does about an `ssh` that exited (DESIGN.md section 6.1).
public enum SSHExitClassification: String, Sendable, Equatable {
    /// Exit 0, nothing to do.
    case clean
    /// The master is gone, or a mux client could not open its channel. The agent runs
    /// `-O check`; a failing check drops the master and reconnects through the breaker,
    /// a passing one retries the channel once.
    case masterLost
    /// Reconnection stops until `sshdrive test`, `passwd`, or a settings change: a stale
    /// password retried every minute is a `fail2ban` ban within the hour.
    case authenticationFailed
    /// `known_hosts` said no. Stops reconnection the same way (section 4.3).
    case hostKeyFailed
    /// The 60 s authentication deadline for an `agentDependent` location. Stops, but is
    /// re-armed for exactly one attempt on screen unlock or a request with the user
    /// present (section 4.2).
    case authenticationDeadline
    /// A key agent that is not ready: `agent refused operation`, or a socket that is not
    /// there yet. Transient, but with the backoff cap raised, because a locked key agent
    /// stays locked for hours (section 6.1).
    case keyAgentNotReady
    /// The server refused another channel: `MaxSessions`. The probe reads the limit off
    /// this; a running location drops a channel rather than reconnecting.
    case channelLimitReached
    /// Everything else: retried with jittered backoff through the breaker (section 6.3).
    case transient

    /// Whether the agent stops reconnecting until the user acts.
    public var stopsReconnection: Bool {
        switch self {
        case .authenticationFailed, .hostKeyFailed, .authenticationDeadline: return true
        default: return false
        }
    }

    /// Whether one attempt is re-armed on screen unlock or a present-user request.
    /// Refusals are never re-armed; only a deadline stop is (section 4.2).
    public var isReArmable: Bool { self == .authenticationDeadline }

    /// The breaker's ceiling for this failure. 60 s normally; 5 minutes for a key agent
    /// that is not ready, since a socket probe every minute buys nothing (section 6.1).
    public var backoffCapSeconds: Int { self == .keyAgentNotReady ? 300 : 60 }
}

/// Reads an `ssh` exit and its stderr and says what it was.
///
/// stderr is kept for `sshdrive status` in every case, whatever this returns.
public enum SSHExitClassifier {

    /// - Parameters:
    ///   - channelOpened: whether the mux client's channel ever opened. A mux client that
    ///     exits before that is always master lost, never an authentication failure: it
    ///     runs `BatchMode=yes` with no askpass token, so anything that looks like auth
    ///     is really the missing socket (section 6.1).
    ///   - deadlineExpired: the 60 s authentication deadline fired before the control
    ///     socket appeared (section 4.2).
    ///   - agentDependent: only an `agentDependent` location can be held up by a key
    ///     agent, so only for one of those is a deadline an authentication stop; for a
    ///     first-pass location the same timeout is transient.
    public static func classify(
        role: SSHRole,
        exitStatus: Int32,
        terminationSignal: Int32? = nil,
        stderr: String,
        channelOpened: Bool = true,
        deadlineExpired: Bool = false,
        agentDependent: Bool = false
    ) -> SSHExitClassification {
        let text = stderr.lowercased()

        if deadlineExpired {
            return agentDependent ? .authenticationDeadline : .transient
        }
        // Before the mux rule: a refused channel on a MaxSessions-limited server is also a
        // mux client that never opened its channel, and it must not read as master lost —
        // dropping and rebuilding the master would refuse the same channel again.
        if contains(text, channelLimitMarkers) { return .channelLimitReached }

        if role == .muxClient, !channelOpened { return .masterLost }

        if contains(text, [
            "agent refused operation",
            "error connecting to agent",
            "could not open a connection to your authentication agent",
        ]) { return .keyAgentNotReady }

        if contains(text, hostKeyMarkers) { return .hostKeyFailed }
        if contains(text, authenticationMarkers) { return .authenticationFailed }

        if exitStatus == 0, terminationSignal == nil { return .clean }
        return .transient
    }

    static let channelLimitMarkers = [
        "session request failed",              // mux_client_request_session
        "administratively prohibited: open failed",
        "channel open failed",
        "open failed: connect failed: too many",
    ]

    static let hostKeyMarkers = [
        "host key verification failed",
        "remote host identification has changed",
        "no matching host key type found",
        "key_verify failed",
    ]

    static let authenticationMarkers = [
        "permission denied",
        "too many authentication failures",
        "no supported authentication methods available",
        "authentication failed",
    ]

    static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
