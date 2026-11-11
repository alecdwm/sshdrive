import Foundation

/// Which of our `ssh` processes exited. The role decides some classifications outright,
/// so it is an input and not a label (docs/design/ssh.md).
public enum SSHRole: String, Sendable, Equatable {
    /// The `-N` ControlMaster.
    case master
    /// A mux client: an SFTP channel or an exec channel.
    case muxClient
    /// `-O check` / `-O exit`.
    case controlCommand
    /// The two-pass verification connection `add` makes
    /// (docs/design/secrets.md).
    case collect
}

/// What the agent does about an `ssh` that exited (docs/design/ssh.md).
public enum SSHExitClassification: String, Sendable, Equatable {
    /// Exit 0, nothing to do.
    case clean
    /// The master is gone, or a mux client could not open its channel. The agent runs
    /// `-O check`; a failing check drops the master and reconnects through the breaker,
    /// a passing one retries the channel once.
    case masterLost
    /// The server refused every key, and no password or keyboard-interactive answer was
    /// sent (that is `passwordRefused`). The fast backoff stops and a slow retry takes its
    /// place: 5 minutes, doubling to 30, plus at most one early attempt per interval on
    /// wake, a network path change or a screen unlock. A home directory that is not
    /// mounted yet refuses every key in it, and the mount must come up once it is
    /// (docs/design/offline.md).
    case authenticationFailed
    /// The server refused a password or a keyboard-interactive answer this connection
    /// sent. Reconnection stops and nothing retries it on its own - not the slow timer,
    /// not wake, a path change or an unlock - until `sshdrive debug breaker <name>
    /// --connect`, a `set` that changes the location, or `sshdrive agent restart`. Every
    /// retry would send the same stale password again, and `pam_faillock` or `fail2ban`
    /// counts each one towards locking the account or banning the Mac
    /// (docs/design/offline.md).
    case passwordRefused
    /// `known_hosts` said no. The same slow retry; each one is a fresh `ssh` that checks
    /// `known_hosts` as always, so a changed key is never accepted (docs/design/secrets.md).
    case hostKeyFailed
    /// The 60 s authentication deadline for an `agentDependent` location. Stops, but is
    /// re-armed for exactly one attempt on screen unlock or a request with the user
    /// present (docs/design/secrets.md).
    case authenticationDeadline
    /// A key agent that is not ready: `agent refused operation`, or a socket that is not
    /// there yet. Transient, but with the backoff cap raised, because a locked key agent
    /// stays locked for hours (docs/design/ssh.md).
    case keyAgentNotReady
    /// The server refused another channel: `MaxSessions`. The probe reads the limit off
    /// this; a running location drops a channel rather than reconnecting.
    case channelLimitReached
    /// Everything else: retried with jittered backoff through the breaker
    /// (docs/design/offline.md).
    case transient

    /// Whether the fast backoff stops. What replaces it is `retriesSlowly`, or for a
    /// deadline the presence-gated re-arm and nothing unattended.
    public var stopsReconnection: Bool {
        switch self {
        case .authenticationFailed, .passwordRefused, .hostKeyFailed, .authenticationDeadline:
            return true
        default: return false
        }
    }

    /// Whether a stop is retried on the slow schedule and on wake, a path change and a
    /// screen unlock. Not a deadline stop: an unattended attempt there can make a security
    /// key blink or a phone prompt fire with nobody to answer it. Not a refused password
    /// either: each retry is one more failed login on the server's count.
    public var retriesSlowly: Bool { self == .authenticationFailed || self == .hostKeyFailed }

    /// Whether one attempt is re-armed on screen unlock or a present-user request.
    /// Refusals are never re-armed; only a deadline stop is (docs/design/secrets.md).
    public var isReArmable: Bool { self == .authenticationDeadline }

    /// The breaker's ceiling for this failure. 60 s normally; 5 minutes for a key agent
    /// that is not ready, since a socket probe every minute buys nothing
    /// (docs/design/ssh.md).
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
    ///     is really the missing socket (docs/design/ssh.md).
    ///   - deadlineExpired: the 60 s authentication deadline fired before the control
    ///     socket appeared (docs/design/secrets.md).
    ///   - agentDependent: only an `agentDependent` location can be held up by a key
    ///     agent, so only for one of those is a deadline an authentication stop; for a
    ///     first-pass location the same timeout is transient.
    ///   - keyAgentSocketFailed: the key agent's socket was missing or refused a
    ///     connection when it was checked (`IdentityAgentCheck`). stderr cannot tell a
    ///     missing or dead agent from a key the server refused - both end in a bare
    ///     `Permission denied (publickey)` (gotcha 40) - so only with this set is that line
    ///     a key agent that is not ready. Without it the line is a refusal.
    ///   - sentPassword: the askpass broker served this connection a password or
    ///     keyboard-interactive prompt, so the server saw an answer (an empty one, when
    ///     nothing was stored). A refusal is then `passwordRefused`. The method list in
    ///     stderr cannot say this: it is what the server allows, not what was tried.
    public static func classify(
        role: SSHRole,
        exitStatus: Int32,
        terminationSignal: Int32? = nil,
        stderr: String,
        channelOpened: Bool = true,
        deadlineExpired: Bool = false,
        agentDependent: Bool = false,
        keyAgentSocketFailed: Bool = false,
        sentPassword: Bool = false
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
        if agentDependent, keyAgentSocketFailed, role == .master, isBarePublickeyDenial(text) {
            return .keyAgentNotReady
        }
        if contains(text, authenticationMarkers) {
            return sentPassword ? .passwordRefused : .authenticationFailed
        }

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

    /// Every line of stderr is `[user@host: ]Permission denied (publickey).` and nothing
    /// else: no password or keyboard-interactive method on offer, no other complaint.
    static func isBarePublickeyDenial(_ lowercased: String) -> Bool {
        let lines = lowercased.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let range = line.range(of: "permission denied (publickey)") else { return false }
            let before = line[line.startIndex ..< range.lowerBound]
            let after = line[range.upperBound...]
            return (before.isEmpty || before.hasSuffix(": ")) && (after.isEmpty || after == ".")
        }
    }

    static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
