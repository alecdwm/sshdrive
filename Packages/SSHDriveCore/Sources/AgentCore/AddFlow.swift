import Foundation
import Config
import Secrets
import SSHProcess

/// The state machine behind `sshdrive add` and `sshdrive passwd` (DESIGN.md sections 4.2,
/// 4.3, 8).
///
/// It is here, in the package, rather than in `Apps/Agent` for the same reason
/// `ItemDerivation` and `TransferScheduler` are: the decisions are the part that has to be
/// right, and they can be driven against a stub runner and the `AskpassHarness` without an
/// `ssh`, a keychain or an app bundle anywhere. What the agent supplies is the runner: one
/// real collect connection per attempt.
///
/// The order the section fixes:
///
/// 1. **First pass, `IdentityAgent=none`.** `ssh` can use only key files, passphrases
///    Apple's `UseKeychain` finds, and passwords, so every passphrase it needs is seen and
///    stored. A location that passes here runs `IdentityAgent=none` for good.
/// 2. **A stale stored secret is masked and the pass repeated.** A second location on a
///    host whose password has since changed finds the shared
///    `password:<user>@<hostname>:<port>` item, `ssh` spends its single prompt on it and is
///    refused; the retry masks it so every prompt reaches the terminal.
/// 3. **Second pass, with the key agent.** Only if the first pass could not authenticate.
///    A location that passes only here is `agentDependent`.
///
/// And the three things that stop it dead, before any of that matters: a key that asked
/// for a touch, a host key the user declined, and a prompt that needs a human every time.
public enum AddFlow {

    /// One collect connection the agent is being asked to make.
    public struct Attempt: Sendable, Equatable {
        /// 1 for the `IdentityAgent=none` pass, 2 for the key-agent pass.
        public var pass: Int
        public var identityAgentNone: Bool
        /// Keychain accounts the broker must not answer from for this attempt.
        public var maskedAccounts: Set<String>
        /// `ask`, or `accept-new` under `--trust-first` (section 4.3).
        public var hostKeyChecking: String

        public init(
            pass: Int, identityAgentNone: Bool, maskedAccounts: Set<String> = [],
            hostKeyChecking: String = "ask"
        ) {
            self.pass = pass
            self.identityAgentNone = identityAgentNone
            self.maskedAccounts = maskedAccounts
            self.hostKeyChecking = hostKeyChecking
        }
    }

    /// What one attempt did. Everything here is observable from the broker's session and
    /// the `ssh` exit; nothing is inferred.
    public struct AttemptResult: Sendable {
        public var authenticated: Bool
        public var classification: SSHExitClassification
        public var stderr: String
        /// From the broker: `Confirm user presence for key …` descriptions.
        public var touchRequiredKeys: [String]
        /// The broker's refusal, if it refused a prompt outright.
        public var refusalReason: String?
        /// True when the user answered the host-key question with anything but yes, or
        /// when `ssh` reported host key verification failure.
        public var hostKeyDeclined: Bool
        /// Accounts this attempt answered **from the keychain** rather than from the
        /// terminal. If it then failed to authenticate, one of them is stale.
        public var accountsAnsweredFromStore: [String]
        /// Whether the connection reached a password prompt at all, which is what tells
        /// "your key files did not authenticate and the server accepts passwords" apart
        /// from a server that never offered passwords.
        public var sawPasswordPrompt: Bool
        /// Prompt texts the broker could not answer, for `status` and for the message
        /// `add` prints when it gives up.
        public var unansweredPrompts: [String]

        public init(
            authenticated: Bool,
            classification: SSHExitClassification = .clean,
            stderr: String = "",
            touchRequiredKeys: [String] = [],
            refusalReason: String? = nil,
            hostKeyDeclined: Bool = false,
            accountsAnsweredFromStore: [String] = [],
            sawPasswordPrompt: Bool = false,
            unansweredPrompts: [String] = []
        ) {
            self.authenticated = authenticated
            self.classification = classification
            self.stderr = stderr
            self.touchRequiredKeys = touchRequiredKeys
            self.refusalReason = refusalReason
            self.hostKeyDeclined = hostKeyDeclined
            self.accountsAnsweredFromStore = accountsAnsweredFromStore
            self.sawPasswordPrompt = sawPasswordPrompt
            self.unansweredPrompts = unansweredPrompts
        }
    }

    /// Why the flow stopped without a location.
    public enum Failure: Sendable, Equatable {
        /// A FIDO key asked for a touch, or a PIN or one-time code was seen. The location
        /// is not created: mounting it would succeed once and then fail into
        /// `.notAuthenticated` on the first unattended reconnect (section 4.2).
        case needsAHumanEveryTime(prompt: String, keys: [String])
        /// The user answered the fingerprint question with anything but yes (section 4.3).
        case hostKeyDeclined
        case authenticationFailed(String)
        case transport(String)

        /// The sentence `add` prints. `identityHint` is the `--identity` line that skips a
        /// touch key, which only the caller can spell because it knows the location's name.
        public func message(identityHint: String?) -> String {
            switch self {
            case let .needsAHumanEveryTime(prompt, keys):
                var text = "This location would need a human on every connection: \(prompt)"
                if !keys.isEmpty {
                    text += "\n\(keys.joined(separator: ", ")) asked for a touch."
                }
                text += "\nWhat works unattended: a key held by a key agent (1Password, "
                    + "Secretive, ssh-agent), a FIDO key generated with no-touch-required, "
                    + "or a password."
                if let identityHint { text += "\n\(identityHint)" }
                return text
            case .hostKeyDeclined:
                return "The server's host key was not accepted, so nothing was added. "
                    + "Nothing was written to ~/.ssh/known_hosts."
            case .authenticationFailed(let stderr):
                return "Could not authenticate."
                    + (stderr.isEmpty ? "" : "\nssh said: \(stderr)")
            case .transport(let text):
                return text
            }
        }
    }

    public struct Result: Sendable {
        public var authenticated: Bool
        /// Set when only the key agent could authenticate (section 4.2). The location
        /// keeps the config's `IdentityAgent` and `show` says so.
        public var agentDependent: Bool
        public var attempts: [Attempt]
        public var failure: Failure?
        /// Lines `add` prints as it goes.
        public var notes: [String]

        public init(
            authenticated: Bool, agentDependent: Bool, attempts: [Attempt],
            failure: Failure? = nil, notes: [String] = []
        ) {
            self.authenticated = authenticated
            self.agentDependent = agentDependent
            self.attempts = attempts
            self.failure = failure
            self.notes = notes
        }
    }

    /// The agent's side: one real collect connection per attempt.
    public protocol AttemptRunning: Sendable {
        func run(_ attempt: Attempt) async -> AttemptResult
    }

    /// Runs the flow. At most three attempts: the pass, the pass with stale items masked,
    /// and the key-agent pass.
    ///
    /// - Parameter allowKeyAgent: false for `--no-password`-style scripted runs and for a
    ///   caller that has already decided the location may not depend on a key agent.
    /// - Parameter note: called as each note is produced, so `add` narrates itself in the
    ///   order things happen rather than printing the whole story after the fact.
    public static func run(
        hostKeyChecking: String = "ask",
        allowKeyAgent: Bool = true,
        note: (@Sendable (String) -> Void)? = nil,
        runner: some AttemptRunning
    ) async -> Result {
        var attempts: [Attempt] = []
        var collected: [String] = []
        func say(_ text: String) {
            collected.append(text)
            note?(text)
        }
        var notes: [String] { collected }

        // Pass 1: no key agent, so every passphrase `ssh` needs is seen and stored.
        let first = Attempt(
            pass: 1, identityAgentNone: true, maskedAccounts: [],
            hostKeyChecking: hostKeyChecking)
        attempts.append(first)
        var result = await runner.run(first)

        if let stop = stopFailure(result) {
            return Result(
                authenticated: false, agentDependent: false, attempts: attempts,
                failure: stop, notes: notes)
        }
        if result.authenticated {
            return Result(
                authenticated: true, agentDependent: false, attempts: attempts, notes: notes)
        }

        // A stored item this attempt used and the server refused is stale. Repeat the same
        // pass with it masked, so every prompt reaches the terminal (section 4.2).
        if result.classification == .authenticationFailed, !result.accountsAnsweredFromStore.isEmpty {
            let masked = Set(result.accountsAnsweredFromStore)
            say(
                "The stored secret for \(masked.sorted().joined(separator: ", ")) did not work; "
                    + "asking again.")
            let retry = Attempt(
                pass: 1, identityAgentNone: true, maskedAccounts: masked,
                hostKeyChecking: hostKeyChecking)
            attempts.append(retry)
            result = await runner.run(retry)
            if let stop = stopFailure(result) {
                return Result(
                    authenticated: false, agentDependent: false, attempts: attempts,
                    failure: stop, notes: notes)
            }
            if result.authenticated {
                return Result(
                    authenticated: true, agentDependent: false, attempts: attempts, notes: notes)
            }
        }

        // Pass 2: with the key agent, so agent-only keys (1Password, Secretive, a FIDO key
        // loaded into ssh-agent) still work. Only an authentication failure earns it: a
        // server that could not be reached will not be reached with a key agent either.
        guard allowKeyAgent, result.classification == .authenticationFailed else {
            return Result(
                authenticated: false, agentDependent: false, attempts: attempts,
                failure: failure(from: result), notes: notes)
        }
        say(
            "Your key files did not authenticate; trying your key agent (1Password, "
                + "Secretive, ssh-agent).")
        let second = Attempt(
            pass: 2, identityAgentNone: false, maskedAccounts: [],
            hostKeyChecking: hostKeyChecking)
        attempts.append(second)
        result = await runner.run(second)

        if let stop = stopFailure(result) {
            return Result(
                authenticated: false, agentDependent: false, attempts: attempts,
                failure: stop, notes: notes)
        }
        if result.authenticated {
            say(
                "This location authenticates through the key agent only; the mount waits "
                    + "for it after login.")
            return Result(
                authenticated: true, agentDependent: true, attempts: attempts, notes: notes)
        }
        return Result(
            authenticated: false, agentDependent: false, attempts: attempts,
            failure: failure(from: result), notes: notes)
    }

    /// The failures that end the flow whatever else happened, including on an attempt that
    /// otherwise authenticated: a location that needs a touch works once and then fails on
    /// every unattended reconnect, so it is refused up front (section 4.2).
    static func stopFailure(_ result: AttemptResult) -> Failure? {
        if !result.touchRequiredKeys.isEmpty {
            return .needsAHumanEveryTime(
                prompt: "a key asked for a user-presence touch",
                keys: result.touchRequiredKeys)
        }
        if result.hostKeyDeclined { return .hostKeyDeclined }
        if let reason = result.refusalReason, reason.contains("needs a human") {
            return .needsAHumanEveryTime(
                prompt: result.unansweredPrompts.first ?? reason, keys: [])
        }
        return nil
    }

    static func failure(from result: AttemptResult) -> Failure {
        switch result.classification {
        case .hostKeyFailed: return .hostKeyDeclined
        case .authenticationFailed: return .authenticationFailed(result.stderr)
        default: return .transport(
            result.stderr.isEmpty
                ? "The connection failed (\(result.classification.rawValue))."
                : result.stderr)
        }
    }

    /// "`~/.ssh/id_ed25519_sk` needs a touch on every connection; run
    /// `sshdrive add --identity ~/.ssh/id_nas nas` to authenticate with a different key"
    /// (section 4.2). The fingerprint in the user-presence notice is matched against the
    /// `identityfile` list the same `ssh -G` produced.
    public static func identityHint(
        touchKeys: [String], identityFiles: [String], fingerprints: [String: String],
        destination: String
    ) -> String? {
        guard !touchKeys.isEmpty else { return nil }
        let named = touchKeys.compactMap { description -> String? in
            guard let fingerprint = description.split(separator: " ").last.map(String.init)
            else { return nil }
            return fingerprints.first { $0.value == fingerprint }?.key
        }
        let alternatives = identityFiles.filter { !named.contains($0) }
        let suggestion = alternatives.first ?? "~/.ssh/id_ed25519"
        if let key = named.first {
            return "\(key) needs a touch on every connection; run "
                + "`sshdrive add --identity \(suggestion) \(destination)` to authenticate "
                + "with a different key."
        }
        return "Run `sshdrive add --identity \(suggestion) \(destination)` to authenticate "
            + "with a key that needs no touch."
    }
}
