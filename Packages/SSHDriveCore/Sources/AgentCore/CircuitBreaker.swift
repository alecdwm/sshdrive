import Foundation
import SSHProcess

/// The per-location circuit breaker (docs/design/offline.md), as a pure state machine.
///
/// It is a `struct` and it takes the time as an argument rather than reading a clock, so
/// every rule - the 2 s doubling to 60 s, the bounded wait during an attempt, the
/// fail-fast for everything else, the stop on an auth or host-key failure with its slow
/// retry, and the one re-armed attempt after a deadline stop - is a unit test with no
/// sleeping in it. `ConnectionGate` is what owns one, runs the attempts and does the
/// waiting.
///
/// The four rules, in the order docs/design/offline.md states them:
///
/// 1. **No path at all is `.serverUnreachable` immediately.** `NWPathMonitor` says so and
///    nothing else needs to be consulted; `setNetworkPath(false)` is that gate.
/// 2. **A failed attempt marks the location down for a backoff interval** - 2 s, doubling
///    to 60 s - during which every call fails fast without touching the network. A path
///    change or wake from sleep resets it.
/// 3. **While an attempt is in progress, calls wait for it,** bounded by the attempt's own
///    remaining deadline: at most the 60 s authentication deadline (docs/design/secrets.md),
///    measured from the spawn of `ssh`, which already contains the 15 s `ConnectTimeout`.
///    Waiting rather than failing is deliberate: the first enumeration after login or
///    wake arrives during the connect, and the system never retries an enumeration on its
///    own, so failing it fast would leave Finder showing the folder as unavailable until
///    the user clicked again.
/// 4. **Auth and host-key failures do not go through the backoff:** they stop it. A
///    refused key or host key is then retried on a slow schedule of its own - 5 minutes,
///    doubling to 30 - and at most once early in each interval, on wake, a path change or
///    a screen unlock (`retryStopNow`). A refused password is retried by nothing at all
///    until the user acts. A deadline stop gets no schedule, only the screen-unlock or
///    present-user re-arm (`DeadlineRearmState`, docs/design/secrets.md).
public struct CircuitBreaker: Sendable {

    /// After a failed connection attempt the location is marked down for a backoff
    /// interval: 2 s, doubling to 60 s.
    public static let firstBackoffSeconds: TimeInterval = 2
    /// The authentication deadline, measured from the spawn, is the longest a call may be
    /// held during an attempt.
    public static let authenticationDeadlineSeconds: TimeInterval = 60
    /// The slow retry of a refused key or host key: 5 minutes, doubling to 30, jittered
    /// down to 4 minutes at the least. Each interval also allows one early attempt on
    /// wake, a path change or an unlock, never within `earlyRetryDebounceSeconds` of the
    /// attempt before it. The worst case is two attempts per interval: four in any ten
    /// minutes, ten in the first hour and six an hour after that. A refused password is
    /// not on this schedule at all (`SSHExitClassification.passwordRefused`), because
    /// `pam_faillock` counts password failures and a `deny=3` locks the account; a refused
    /// key costs the server a log line, and four in ten minutes stays under `fail2ban`'s
    /// default of five. A home directory that mounts late is back within one interval.
    public static let firstStopRetrySeconds: TimeInterval = 300
    public static let stopRetryCapSeconds: TimeInterval = 1800
    /// Wake, the network path coming back and the unlock arrive seconds apart when a lid
    /// opens. An early retry asked for within this long of the last attempt is merged into
    /// that attempt: it makes none of its own and does not use the interval's allowance.
    public static let earlyRetryDebounceSeconds: TimeInterval = 60

    /// What a caller should do with the call it is holding.
    public enum Decision: Sendable, Equatable {
        /// The connection is up; make the call.
        case proceed
        /// Nothing is connected and nothing is trying. The caller runs one attempt and
        /// reports the outcome back through `attemptSucceeded` or `attemptFailed`.
        case connect
        /// An attempt is already in flight. Wait for it, but never longer than this.
        case wait(seconds: TimeInterval)
        /// Fail now, without touching the network.
        case failFast(Reason)
    }

    /// Why a call failed fast, so the log and `sshdrive status` can say which of section
    /// 6.3's rules answered.
    public enum Reason: Sendable, Equatable {
        /// Rule 1: `NWPathMonitor` reports no path at all.
        case noNetworkPath
        /// Rule 2: the breaker is open and the backoff has this long left to run.
        case backingOff(remaining: TimeInterval)
        /// Rule 4: the backoff has stopped; `nextStopRetry` says whether a slow retry is
        /// due and when.
        case stopped(SSHExitClassification)

        public var sentence: String {
            switch self {
            case .noNetworkPath:
                return "this Mac has no network connection"
            case let .backingOff(remaining):
                return "the last connection attempt failed; retrying in \(Int(remaining.rounded(.up))) s"
            case let .stopped(classification):
                switch classification {
                case .authenticationFailed:
                    return "authentication failed; retried every few minutes, or at once with `sshdrive debug breaker <name> --connect`"
                case .passwordRefused:
                    return "the server refused the password; not retried until `sshdrive debug breaker <name> --connect`, a `set` or `sshdrive agent restart`"
                case .hostKeyFailed:
                    return "the server's host key did not match `known_hosts`; retried every few minutes against `known_hosts`"
                case .authenticationDeadline:
                    return
                        "authentication did not complete within 60 s; a key agent may be waiting for a touch or approval"
                default:
                    return "reconnection has stopped (\(classification.rawValue))"
                }
            }
        }
    }

    public enum State: Sendable, Equatable {
        /// Nothing connected, nothing in flight, no backoff owed: the next call connects.
        case idle
        /// An attempt is running; `since` is when `ssh` was spawned.
        case connecting(since: TimeInterval)
        case up
        /// Open. Every call fails fast until `until`, then one half-open probe is let out.
        case backingOff(until: TimeInterval)
        /// The backoff has stopped. An auth or host-key stop is retried on the slow
        /// schedule (`stopRetryAt`); a deadline stop waits for the re-arm
        /// (docs/design/secrets.md).
        case stopped(SSHExitClassification)
    }

    public private(set) var state: State = .idle
    /// How many attempts have failed in a row. The backoff doubles with it, and a success
    /// or a reset clears it.
    public private(set) var consecutiveFailures = 0
    /// Rule 1's gate, held separately from the state: a path that comes back does not on
    /// its own connect anything, it only stops the immediate refusal and resets rule 2.
    public private(set) var hasNetworkPath = true
    /// The cap the last failure asked for: 60 s normally, 300 s for a key agent that is
    /// not ready, since a locked key agent stays locked for hours (docs/design/ssh.md).
    public private(set) var backoffCapSeconds: TimeInterval = 60
    /// When a stop that `retriesSlowly` lets its next attempt out. Nil for every other
    /// state, and for a deadline stop.
    public private(set) var stopRetryAt: TimeInterval?
    /// How many slow retries in a row have failed again. The interval doubles with it; an
    /// attempt let out early by wake, a path change or an unlock does not move it, so a
    /// user who keeps opening the lid does not push the next unattended try further away.
    public private(set) var stopRetryLevel = 0
    /// Whether this stop interval's one early attempt has been made. Cleared when the
    /// scheduled retry is let out, by a success, and by `clearStop`.
    public private(set) var earlyRetryUsed = false
    /// When the last attempt of any kind was let out, for the debounce.
    public private(set) var lastAttemptAt: TimeInterval?

    /// What let the attempt in flight out.
    private enum AttemptKind { case ordinary, scheduledStopRetry, earlyStopRetry }
    private var attemptKind = AttemptKind.ordinary
    /// Set by `retryStopNow` for the attempt it lets out.
    private var earlyRetryPending = false
    /// The slow retry that was due when an early attempt was let out. A refused early
    /// attempt goes back to it rather than starting the interval again.
    private var stopRetryAtBeforeEarly: TimeInterval?

    /// Multiplies the computed backoff, which is jittered. A test injects `{ _ in 1 }`
    /// and gets exact numbers.
    private let jitter: @Sendable (TimeInterval) -> TimeInterval

    public init(jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = CircuitBreaker.defaultJitter) {
        self.jitter = jitter
    }

    /// +/-20 %, so a Mac with eight locations on one dead NAS does not retry all eight in
    /// the same millisecond for ever.
    public static let defaultJitter: @Sendable (TimeInterval) -> TimeInterval = { base in
        base * Double.random(in: 0.8...1.2)
    }

    // MARK: Admission

    public mutating func admit(now: TimeInterval) -> Decision {
        guard hasNetworkPath else { return .failFast(.noNetworkPath) }
        switch state {
        case .up:
            return .proceed
        case .idle:
            state = .connecting(since: now)
            attemptKind = earlyRetryPending ? .earlyStopRetry : .ordinary
            earlyRetryPending = false
            lastAttemptAt = now
            return .connect
        case let .connecting(since):
            // Rule 3. The bound is what is left of the attempt's own deadline, never the
            // deadline added to the time already spent.
            let remaining = max(0, since + Self.authenticationDeadlineSeconds - now)
            return .wait(seconds: remaining)
        case let .backingOff(until):
            if now >= until {
                // Half open: exactly one probe is let out, and everything that arrives
                // while it runs waits on it like any other attempt.
                state = .connecting(since: now)
                attemptKind = .ordinary
                earlyRetryPending = false
                lastAttemptAt = now
                return .connect
            }
            return .failFast(.backingOff(remaining: until - now))
        case let .stopped(classification):
            if let due = stopRetryAt, now >= due {
                // The slow retry: one attempt, a fresh `ssh` that checks `known_hosts` and
                // offers its keys exactly as any other connect does.
                state = .connecting(since: now)
                stopRetryAt = nil
                attemptKind = .scheduledStopRetry
                earlyRetryUsed = false
                lastAttemptAt = now
                return .connect
            }
            return .failFast(.stopped(classification))
        }
    }

    // MARK: Outcomes

    public mutating func attemptSucceeded() {
        state = .up
        consecutiveFailures = 0
        backoffCapSeconds = 60
        stopRetryAt = nil
        stopRetryLevel = 0
        earlyRetryUsed = false
        earlyRetryPending = false
        stopRetryAtBeforeEarly = nil
        attemptKind = .ordinary
    }

    /// Reports the attempt's outcome. The classification decides between rule 2 and rule
    /// 4; it is the same `SSHExitClassifier` answer the master's exit produced, so there
    /// is one definition of "does this stop reconnection" and not two (docs/design/ssh.md).
    public mutating func attemptFailed(_ classification: SSHExitClassification, now: TimeInterval) {
        let kind = attemptKind
        attemptKind = .ordinary
        let resumeAt = stopRetryAtBeforeEarly
        stopRetryAtBeforeEarly = nil
        if classification.stopsReconnection {
            state = .stopped(classification)
            guard classification.retriesSlowly else {
                stopRetryAt = nil
                return
            }
            switch kind {
            case .scheduledStopRetry:
                stopRetryLevel += 1
                stopRetryAt = now + nextStopRetryInterval()
            case .earlyStopRetry:
                // The interval the early attempt was taken from carries on: its scheduled
                // retry stays where it was, never sooner than the debounce after this
                // one, and the allowance stays spent.
                stopRetryAt = resumeAt.map { max($0, now + Self.earlyRetryDebounceSeconds) }
                    ?? now + nextStopRetryInterval()
            case .ordinary:
                stopRetryAt = now + nextStopRetryInterval()
            }
            return
        }
        stopRetryAt = nil
        consecutiveFailures += 1
        backoffCapSeconds = TimeInterval(classification.backoffCapSeconds)
        state = .backingOff(until: now + nextBackoff())
    }

    /// The interval the breaker will hold for after the failure just recorded. Public so
    /// `sshdrive status` and the debug hook can print it without provoking one.
    public func nextBackoff() -> TimeInterval {
        let exponent = max(0, consecutiveFailures - 1)
        // 2, 4, 8, … and never past the cap. `min` before the jitter so the jitter cannot
        // push a capped interval past it by 20 %.
        let base = min(
            Self.firstBackoffSeconds * pow(2, Double(exponent)), backoffCapSeconds)
        return jitter(base)
    }

    /// The slow retry's interval at the current level: 5 minutes, doubling to 30, jittered
    /// like the backoff and never past the cap.
    public func nextStopRetryInterval() -> TimeInterval {
        let base = min(
            Self.firstStopRetrySeconds * pow(2, Double(stopRetryLevel)), Self.stopRetryCapSeconds)
        return min(jitter(base), Self.stopRetryCapSeconds)
    }

    /// A connection that was up has gone (the master exited, or a request hit its
    /// deadline twice). The next call connects straight away with no backoff owed: the
    /// connection worked a moment ago, so a fresh attempt is the right answer and a 2 s
    /// wait would only add latency to the first request after a laptop lid opens.
    public mutating func connectionLost() {
        guard case .up = state else { return }
        state = .idle
    }

    /// A path change or wake from sleep (docs/design/offline.md). Clears a
    /// backoff but never a stop; `retryStopNow` is what lets an auth or host-key stop make
    /// its one attempt on the same events.
    public mutating func reset() {
        consecutiveFailures = 0
        backoffCapSeconds = 60
        switch state {
        case .backingOff:
            state = .idle
        case .idle, .up, .connecting, .stopped:
            break
        }
    }

    /// Wake, a path change or a screen unlock, on a stop that `retriesSlowly`: one attempt
    /// now instead of at the scheduled time. The home directory that was not mounted, or
    /// the network whose server presented another host key, is the kind of thing those
    /// events change.
    ///
    /// At most one per stop interval, and none within `earlyRetryDebounceSeconds` of the
    /// last attempt: a lid opening is a wake, a path and an unlock seconds apart, and the
    /// first of them is the only attempt they make. A refused password and a deadline stop
    /// are left alone; the deadline's triggers are the re-arm's.
    @discardableResult
    public mutating func retryStopNow(now: TimeInterval) -> Bool {
        guard case let .stopped(classification) = state, classification.retriesSlowly,
            !earlyRetryUsed
        else { return false }
        if let last = lastAttemptAt, now - last < Self.earlyRetryDebounceSeconds { return false }
        state = .idle
        stopRetryAtBeforeEarly = stopRetryAt
        stopRetryAt = nil
        earlyRetryUsed = true
        earlyRetryPending = true
        return true
    }

    /// The re-arm (docs/design/secrets.md): exactly one attempt after a deadline stop.
    /// Refusals are
    /// never re-armed, so a `stopped(.authenticationFailed)` is left alone.
    @discardableResult
    public mutating func rearmOneAttempt() -> Bool {
        guard case let .stopped(classification) = state, classification.isReArmable else {
            return false
        }
        state = .idle
        consecutiveFailures = 0
        earlyRetryPending = false
        return true
    }

    /// The only thing that clears a refusal on a live gate (docs/design/ssh.md), called by
    /// `sshdrive debug breaker <name> --connect`.
    public mutating func clearStop() {
        if case .stopped = state { state = .idle }
        consecutiveFailures = 0
        backoffCapSeconds = 60
        stopRetryAt = nil
        stopRetryLevel = 0
        earlyRetryUsed = false
        earlyRetryPending = false
        stopRetryAtBeforeEarly = nil
    }

    /// Rule 1. Losing the path does not disturb an attempt that is running - it will fail
    /// on its own - but it does make every later call refuse at once. Gaining one resets
    /// the backoff: a path change resets the breaker.
    public mutating func setNetworkPath(_ available: Bool) {
        let had = hasNetworkPath
        hasNetworkPath = available
        if available && !had { reset() }
    }

    // MARK: Reporting

    /// One line for `sshdrive status` and the debug hook.
    public func description(now: TimeInterval) -> String {
        guard hasNetworkPath else { return "no network path" }
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .up: return "connected"
        case let .backingOff(until):
            return "backing off for \(Int(max(0, until - now).rounded(.up))) s after \(consecutiveFailures) failure(s)"
        case let .stopped(classification):
            guard let due = stopRetryAt else { return "stopped: \(classification.rawValue)" }
            return "stopped: \(classification.rawValue); next attempt in \(Self.duration(max(0, due - now)))"
        }
    }

    /// "45 s", "5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return whole < 120 ? "\(whole) s" : "\(Int((Double(whole) / 60).rounded())) min"
    }

    public var isStopped: Bool { if case .stopped = state { return true }; return false }
    public var isUp: Bool { if case .up = state { return true }; return false }
}
