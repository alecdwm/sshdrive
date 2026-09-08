import Foundation

/// Whether the File Provider extension's read-only index reader may be used, as a value
/// (DESIGN.md section 5.2).
///
/// It is a type of its own, and clock-injected, because the rule it encodes is the one
/// that failed on 2026-09-08: readiness used to be a `Bool` set once, in the extension
/// instance's `init`, from one `indexReady` round trip. The agent answers no for any
/// location whose runtime is not up yet - a domain restart, an upgrade handover, an index
/// mid-restore - and a `false` then held for the whole life of that instance, with nothing
/// anywhere that would ask again. The working set is the one enumeration the extension
/// answers from the reader, so that instance answered every working-set change enumeration
/// `.serverUnreachable`; fileproviderd throttles a change enumeration that keeps failing,
/// and a run of them takes the domain's event stream out to tens of minutes. The mount
/// then takes no server-side change at all while every other path - listings, `item(for:)`,
/// uploads - keeps working, which is exactly what makes it hard to see.
///
/// So: "not ready" is a window, not a verdict. Every read that meets one asks again, no
/// more often than `retryInterval`, and the caller has somewhere else to go meanwhile.
public struct IndexReaderReadiness: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// No answer yet. Reads go to the agent and one is asked for.
        case unknown
        /// Usable.
        case ready
        /// The agent said no. Re-asked; never permanent.
        case notReady = "not-ready"
        /// A schema newer than this build understands. Permanent for this instance, and
        /// correctly so: nothing about waiting makes an unknown schema readable.
        case schemaTooNew = "schema-too-new"
        /// Shut for the truncate window of a restore, until the agent says to reopen.
        case closed
        /// Opened or read and failed. Re-asked like `notReady`, because a transient
        /// failure - a file being replaced under us - is the common case.
        case failed
    }

    public private(set) var state: State = .unknown
    public private(set) var lastAskedAt: Double?
    public private(set) var lastError: String?
    /// How often an instance holding a non-ready answer asks the agent again. Short: the
    /// window it covers is a domain restart and the cost is one XPC message.
    public var retryInterval: Double

    public init(retryInterval: Double = 2) {
        self.retryInterval = retryInterval
    }

    /// True while the reader may be opened and read.
    public var canRead: Bool { state == .ready }

    /// The states that are worth another `indexReady` round trip. `schemaTooNew` is not
    /// one of them, and neither is `closed`: the agent lifts that one itself.
    public var isRetryable: Bool {
        state == .unknown || state == .notReady || state == .failed
    }

    /// Whether to ask the agent now. Records the attempt, so two reads arriving together
    /// produce one round trip.
    public mutating func shouldAsk(at now: Double) -> Bool {
        guard isRetryable else { return false }
        if let last = lastAskedAt, now - last < retryInterval { return false }
        lastAskedAt = now
        return true
    }

    /// The agent's answer. `nil` means it could not be reached at all, which leaves the
    /// instance free to open the reader: a missing agent is the case the direct reader
    /// exists for.
    public mutating func answered(_ ready: Bool?, at now: Double) {
        lastAskedAt = now
        guard state != .schemaTooNew else { return }
        switch ready {
        case .some(true), .none:
            // A reader shut for a restore stays shut until the reopen callback; the
            // agent's `indexReady` is not what lifts that.
            if state != .closed {
                state = .ready
                lastError = nil
            }
        case .some(false):
            state = .notReady
        }
    }

    public mutating func failed(_ description: String, at now: Double) {
        guard state != .schemaTooNew else { return }
        state = .failed
        lastError = description
        // A failure is evidence the answer we hold is stale, so the next read may ask
        // even if one was asked a moment ago.
        lastAskedAt = nil
    }

    public mutating func foundSchemaTooNew(_ description: String) {
        state = .schemaTooNew
        lastError = description
    }

    public mutating func close() {
        if state == .ready { state = .closed }
    }

    public mutating func reopen() {
        if state == .closed { state = .ready }
    }
}
