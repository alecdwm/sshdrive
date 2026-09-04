import Foundation
import SSHProcess

/// DESIGN.md section 6.3's per-location circuit breaker, as a pure state machine.
///
/// It is a `struct` and it takes the time as an argument rather than reading a clock, so
/// every rule in section 6.3 - the 2 s doubling to 60 s, the bounded wait during an
/// attempt, the fail-fast for everything else, the stop on an auth or host-key failure
/// and the one re-armed attempt after a deadline stop - is a unit test with no sleeping
/// in it. `ConnectionGate` is what owns one, runs the attempts and does the waiting.
///
/// The four rules of section 6.3, in the order the section states them:
///
/// 1. **No path at all is `.serverUnreachable` immediately.** `NWPathMonitor` says so and
///    nothing else needs to be consulted; `setNetworkPath(false)` is that gate.
/// 2. **A failed attempt marks the location down for a backoff interval** - 2 s, doubling
///    to 60 s - during which every call fails fast without touching the network. A path
///    change, wake from sleep or `sshdrive test` resets it.
/// 3. **While an attempt is in progress, calls wait for it,** bounded by the attempt's own
///    remaining deadline: at most the 60 s authentication deadline of section 4.2,
///    measured from the spawn of `ssh`, which already contains the 15 s `ConnectTimeout`.
///    Waiting rather than failing is deliberate: the first enumeration after login or
///    wake arrives during the connect, and the system never retries an enumeration on its
///    own, so failing it fast would leave Finder showing the folder as unavailable until
///    the user clicked again.
/// 4. **Auth and host-key failures do not go through the breaker at all:** they stop
///    reconnection until the user acts, or - for a deadline stop only - until the
///    screen-unlock or present-user re-arm of section 4.2 (`DeadlineRearmState`).
public struct CircuitBreaker: Sendable {

    /// Section 6.3: "after a failed connection attempt the location is marked down for a
    /// backoff interval (2 s, doubling to 60 s)".
    public static let firstBackoffSeconds: TimeInterval = 2
    /// Section 4.2 and 6.3: the authentication deadline, measured from the spawn, is the
    /// longest a call may be held during an attempt.
    public static let authenticationDeadlineSeconds: TimeInterval = 60

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
        /// Rule 4: reconnection has stopped until the user acts.
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
                    return "authentication failed; run `sshdrive test` after fixing it"
                case .hostKeyFailed:
                    return "the server's host key did not match `known_hosts`"
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
        /// Section 6.1: reconnection has stopped until the user acts, or until the
        /// re-arm of section 4.2 for a deadline stop.
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
    /// not ready, since a locked key agent stays locked for hours (section 6.1).
    public private(set) var backoffCapSeconds: TimeInterval = 60

    /// Multiplies the computed backoff. Section 6.1 says "jittered backoff"; a test
    /// injects `{ _ in 1 }` and gets exact numbers.
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
                return .connect
            }
            return .failFast(.backingOff(remaining: until - now))
        case let .stopped(classification):
            return .failFast(.stopped(classification))
        }
    }

    // MARK: Outcomes

    public mutating func attemptSucceeded() {
        state = .up
        consecutiveFailures = 0
        backoffCapSeconds = 60
    }

    /// Reports the attempt's outcome. The classification decides between rule 2 and rule
    /// 4; it is the same `SSHExitClassifier` answer the master's exit produced, so there
    /// is one definition of "does this stop reconnection" and not two (section 6.1).
    public mutating func attemptFailed(_ classification: SSHExitClassification, now: TimeInterval) {
        if classification.stopsReconnection {
            state = .stopped(classification)
            return
        }
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

    /// A connection that was up has gone (the master exited, or a request hit its
    /// deadline twice). The next call connects straight away with no backoff owed: the
    /// connection worked a moment ago, so a fresh attempt is the right answer and a 2 s
    /// wait would only add latency to the first request after a laptop lid opens.
    public mutating func connectionLost() {
        guard case .up = state else { return }
        state = .idle
    }

    /// A path change, wake from sleep, or `sshdrive test` (section 6.3). Clears a backoff
    /// but never a stop: an auth failure is still an auth failure after a Wi-Fi hop.
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

    /// Section 4.2's re-arm: exactly one attempt after a deadline stop. Refusals are
    /// never re-armed, so a `stopped(.authenticationFailed)` is left alone.
    @discardableResult
    public mutating func rearmOneAttempt() -> Bool {
        guard case let .stopped(classification) = state, classification.isReArmable else {
            return false
        }
        state = .idle
        consecutiveFailures = 0
        return true
    }

    /// `sshdrive test`, `passwd`, or a change to the location's settings: the only things
    /// that clear a refusal (section 6.1).
    public mutating func clearStop() {
        if case .stopped = state { state = .idle }
        consecutiveFailures = 0
        backoffCapSeconds = 60
    }

    /// Rule 1. Losing the path does not disturb an attempt that is running - it will fail
    /// on its own - but it does make every later call refuse at once. Gaining one resets
    /// the backoff, which is section 6.3's "a path change … resets the breaker".
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
            return "stopped: \(classification.rawValue)"
        }
    }

    public var isStopped: Bool { if case .stopped = state { return true }; return false }
    public var isUp: Bool { if case .up = state { return true }; return false }
}
