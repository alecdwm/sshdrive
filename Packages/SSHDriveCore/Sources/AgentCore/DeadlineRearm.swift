import Foundation
import SSHProcess

/// What the Mac says about whether a human is at it (DESIGN.md section 4.2).
///
/// `secondsSinceLastInputEvent` is
/// `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .any)`,
/// which needs no permission; `screenLocked` is `CGSSessionScreenIsLocked` from
/// `CGSessionCopyCurrentDictionary()`. `AgentPresence` in the agent reads both; a test
/// hands over whatever it likes.
public struct PresenceReading: Sendable, Equatable {
    public var secondsSinceLastInputEvent: TimeInterval
    public var screenLocked: Bool

    public init(secondsSinceLastInputEvent: TimeInterval, screenLocked: Bool) {
        self.secondsSinceLastInputEvent = secondsSinceLastInputEvent
        self.screenLocked = screenLocked
    }

    /// Section 4.2: "must be under 30 s, and the screen must be unlocked".
    public var userIsPresent: Bool {
        !screenLocked && secondsSinceLastInputEvent < DeadlineRearmState.presenceIdleLimitSeconds
    }
}

/// DESIGN.md section 4.2's re-arm after an authentication-deadline stop, as a pure state
/// machine.
///
/// A location stopped by the 60 s deadline is re-armed **for one attempt** when a human
/// is demonstrably present. Two things do it, and each fires exactly once per stop:
///
/// - the `com.apple.screenIsUnlocked` distributed notification, and
/// - a File Provider request for that domain arriving while the presence test passes.
///
/// A File Provider request on its own is not evidence of a human: Spotlight, Quick Look,
/// Finder's background refreshes and the working-set enumerator issue requests on an
/// unattended Mac all day, and each would re-arm an attempt, block for 60 s, raise the key
/// agent's prompt with nobody there and hand the trigger to the next request. So presence
/// is measured directly, and the measurement itself is taken **at most once a minute** so
/// the test costs nothing on the hot path.
///
/// Refusals - a PIN, a one-time code, a `confirm` outside `add` - are never re-armed:
/// they cannot succeed attended or unattended. That is why this takes the classification
/// rather than a bare "it stopped".
public struct DeadlineRearmState: Sendable {

    /// Section 4.2: input idle must be under 30 s.
    public static let presenceIdleLimitSeconds: TimeInterval = 30
    /// Section 4.2: "evaluated at most once a minute so the test itself costs nothing".
    public static let requestEvaluationIntervalSeconds: TimeInterval = 60

    /// Set while a deadline stop is outstanding. Nothing else arms it.
    public private(set) var isArmed = false
    /// Each trigger fires once per stop.
    public private(set) var unlockTriggerUsed = false
    public private(set) var requestTriggerUsed = false
    /// When the presence test was last actually read, so it is not read again for a
    /// minute.
    public private(set) var lastPresenceEvaluation: TimeInterval?
    /// How many times the presence test was read, for the spike and for the debug hook:
    /// this is the number section 4.2's "costs nothing" claim is about.
    public private(set) var presenceEvaluations = 0

    public init() {}

    /// The attempt stopped. Arms both triggers for a deadline stop and disarms everything
    /// for a refusal.
    public mutating func noteStop(_ classification: SSHExitClassification) {
        guard classification.isReArmable else {
            isArmed = false
            return
        }
        isArmed = true
        unlockTriggerUsed = false
        requestTriggerUsed = false
        lastPresenceEvaluation = nil
    }

    /// A connection succeeded, or the user cleared the stop by hand. Nothing is owed.
    public mutating func clear() {
        isArmed = false
        unlockTriggerUsed = false
        requestTriggerUsed = false
        lastPresenceEvaluation = nil
    }

    /// `com.apple.screenIsUnlocked` arrived. True means "re-arm one attempt now".
    ///
    /// No presence test: an unlock **is** the evidence, and it is the trigger that exists
    /// for the 1Password and Secretive case where the user has just sat down.
    public mutating func screenUnlocked() -> Bool {
        guard isArmed, !unlockTriggerUsed else { return false }
        unlockTriggerUsed = true
        return true
    }

    /// A File Provider request for this domain arrived. True means "re-arm one attempt".
    ///
    /// `presence` is a closure and not a value because the whole point of the once-a-
    /// minute rule is that the reading is not taken on most calls; a test counts the
    /// closure's invocations to prove it.
    public mutating func requestArrived(
        now: TimeInterval, presence: () -> PresenceReading
    ) -> Bool {
        guard isArmed, !requestTriggerUsed else { return false }
        if let last = lastPresenceEvaluation,
            now - last < Self.requestEvaluationIntervalSeconds
        {
            return false
        }
        lastPresenceEvaluation = now
        presenceEvaluations += 1
        guard presence().userIsPresent else { return false }
        requestTriggerUsed = true
        return true
    }
}
