import Foundation
import Logging
import XPCProtocols

/// What a token was minted for (DESIGN.md section 4.2). A `collect` token belongs to the
/// verification connection `sshdrive add` and `sshdrive passwd` make; every prompt it has
/// no stored answer for is relayed to the CLI. A `master` token belongs to a `-N` master
/// (and, through the environment it inherits, to that master's `ProxyJump` hops); nothing
/// is relayed, and a prompt with no stored answer is skipped or refused.
public enum AskpassPurpose: String, Sendable {
    case master
    case collect
}

/// What the agent tells the askpass program to do.
public enum AskpassReply: Equatable, Sendable {
    /// Print this on stdout and exit 0.
    case answer(String)
    /// Print an empty line and exit 0. For a secret this is "skip this identity":
    /// `ssh` logs "no passphrase given, try next key" and moves on (section 4.2). For a
    /// `SSH_ASKPASS_PROMPT=none` notification it is the acknowledgement.
    case empty
    /// Print nothing and exit non-zero: `ssh` fails the prompt, and with it the
    /// connection. Section 4.2's refusals.
    case refuse(reason: String)
}

/// A prompt the agent could not answer from the keychain, kept so `add`'s collect flow
/// can ask the user afterwards and so `sshdrive status` can print what the server wanted.
public struct AskpassMiss: Equatable, Sendable {
    public var prompt: AskpassPrompt
    public var promptText: String
    public var key: SecretKey?
    public var destination: SSHDestination?
    public var refused: Bool
    public var date: Date
}

/// The question the collect flow puts to the CLI, which shows it on the terminal
/// (section 4.2). An empty answer is a refusal of that prompt: nothing is stored, and the
/// attempt fails over to the second pass.
public struct AskpassCollectRequest: Sendable {
    public var locationID: String
    public var prompt: AskpassPrompt
    public var promptText: String
    public var key: SecretKey?
    public var destination: SSHDestination?
    /// Secrets are read hidden; the host-key question is read visible (section 4.3).
    public var isSecret: Bool
}

/// A read-only view of a live token, for `status` and the tests.
public struct AskpassSessionInfo: Sendable {
    public var token: String
    public var locationID: String
    public var purpose: AskpassPurpose
    public var destination: SSHDestination?
    public var sshPID: Int32?
    public var mintedAt: Date
    public var expiresAt: Date
    public var retired: Bool
    public var invocations: Int
    public var misses: [AskpassMiss]
    public var refusalReason: String?
    /// FIDO keys that asked for a touch. `add` refuses a location that saw one
    /// (section 4.2).
    public var touchRequiredKeys: [String]
}

/// The agent's half of the askpass token protocol (DESIGN.md section 4.2).
///
/// The agent mints one token per `ssh` it spawns, puts it in that process's environment,
/// and answers prompts that arrive carrying it. Everything else - a request with no
/// token, a retired one, an expired one, or one whose caller is not a descendant of the
/// `ssh` it was issued to - gets no answer.
///
/// The class is the test seam as well as the production path: `answer(...)` takes the
/// prompt as plain values, so `SSHProcess` and the tests can drive every branch without
/// an `ssh` anywhere (see `AskpassHarness`).
public final class AskpassBroker: @unchecked Sendable {

    private final class Session {
        let token: String
        let locationID: String
        let purpose: AskpassPurpose
        var resolution: SSHResolution?
        var argv: [String]
        var sshPID: Int32?
        let mintedAt: Date
        let expiresAt: Date
        var retired = false
        var invocations = 0
        var misses: [AskpassMiss] = []
        var used: [(key: SecretKey, value: String)] = []
        var maskedAccounts: Set<String>
        var refusalReason: String?
        var touchRequiredKeys: [String] = []

        init(
            token: String, locationID: String, purpose: AskpassPurpose,
            resolution: SSHResolution?, argv: [String], mintedAt: Date, expiresAt: Date,
            maskedAccounts: Set<String>
        ) {
            self.token = token
            self.locationID = locationID
            self.purpose = purpose
            self.resolution = resolution
            self.argv = argv
            self.mintedAt = mintedAt
            self.expiresAt = expiresAt
            self.maskedAccounts = maskedAccounts
        }
    }

    private let store: SecretsStore
    private let resolver: SSHResolving
    private let ancestry: ProcessAncestryChecking
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    /// Section 4.2's authentication deadline. A token cannot outlive it: after 60 s the
    /// agent has killed the `ssh` anyway, so an invocation arriving later is not ours.
    public var authenticationDeadline: TimeInterval = 60

    /// A bound on how many prompts one spawn may raise. A token is not single-*prompt* -
    /// section 4.2 has a master's `ProxyJump` hops share it, and one connection can be
    /// asked for a passphrase and then a password - but it is single-*spawn*, and a
    /// `ssh` that has raised this many prompts is not authenticating, it is grinding.
    public var maximumInvocations = 32

    /// Installed by `sshdrive add` / `passwd` for the length of the collect connection.
    /// Returns the user's answer, or nil if the CLI could not be asked.
    public var collectResponder: ((AskpassCollectRequest) -> String?)?

    public init(
        store: SecretsStore,
        resolver: SSHResolving = SSHGResolver(),
        ancestry: ProcessAncestryChecking = SysctlProcessAncestry(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.resolver = resolver
        self.ancestry = ancestry
        self.now = now
    }

    // MARK: minting and retiring

    /// Mint a token for one `ssh` the agent is about to spawn. `resolution` is what the
    /// agent already knows about the destination (it built the command line); the hops
    /// under a `ProxyCommand` are resolved from their own argv when they ask.
    @discardableResult
    public func mint(
        locationID: String,
        purpose: AskpassPurpose,
        resolution: SSHResolution? = nil,
        argv: [String] = [],
        maskedAccounts: Set<String> = []
    ) -> String {
        let token = AskpassBroker.newToken()
        let minted = now()
        let session = Session(
            token: token, locationID: locationID, purpose: purpose, resolution: resolution,
            argv: argv, mintedAt: minted,
            expiresAt: minted.addingTimeInterval(authenticationDeadline),
            maskedAccounts: maskedAccounts)
        lock.lock()
        // A token is per spawn, so a location that respawns drops what it had retired.
        let stale = sessions.filter { $0.key != token && $0.value.locationID == locationID && $0.value.retired }
            .map(\.key)
        for key in stale { sessions.removeValue(forKey: key) }
        sessions[token] = session
        lock.unlock()
        Log.ssh.notice(
            "minted an askpass token for \(locationID, privacy: .public) (\(purpose.rawValue, privacy: .public))"
        )
        return token
    }

    /// Record the pid of the `ssh` the token was issued to, once it has been spawned.
    /// Until this is set the descendant check cannot run and is skipped.
    public func attach(pid: Int32, argv: [String] = [], to token: String) {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[token] else { return }
        session.sshPID = pid
        if !argv.isEmpty { session.argv = argv }
    }

    /// Retire the token when the master exits, which ends every hop with it (section 4.2).
    public func retire(token: String) {
        lock.lock(); defer { lock.unlock() }
        sessions[token]?.retired = true
    }

    /// Drop a retired session entirely. Kept separate from `retire` so `status` can still
    /// read the misses of a connection that has just failed.
    public func forget(token: String) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeValue(forKey: token)
    }

    public func retireAll(locationID: String) {
        lock.lock(); defer { lock.unlock() }
        for session in sessions.values where session.locationID == locationID {
            session.retired = true
        }
    }

    public func info(token: String) -> AskpassSessionInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[token] else { return nil }
        return AskpassSessionInfo(
            token: session.token, locationID: session.locationID, purpose: session.purpose,
            destination: session.resolution?.destination, sshPID: session.sshPID,
            mintedAt: session.mintedAt, expiresAt: session.expiresAt, retired: session.retired,
            invocations: session.invocations, misses: session.misses,
            refusalReason: session.refusalReason, touchRequiredKeys: session.touchRequiredKeys)
    }

    public func misses(token: String) -> [AskpassMiss] {
        lock.lock(); defer { lock.unlock() }
        return sessions[token]?.misses ?? []
    }

    /// Every answer this connection actually used, in the order it used them.
    public func usedAnswers(token: String) -> [(key: SecretKey, value: String)] {
        lock.lock(); defer { lock.unlock() }
        return sessions[token]?.used ?? []
    }

    /// "When the connection succeeds, every answer that was actually used is written to
    /// the keychain; a wrong password is never stored" (section 4.2). Called by `add` and
    /// `passwd` only after the verification connection has authenticated.
    @discardableResult
    public func commit(token: String) throws -> [SecretKey] {
        let answers = usedAnswers(token: token)
        var written: [SecretKey] = []
        for answer in answers {
            guard !answer.value.isEmpty else { continue }
            try store.setSecret(answer.value, for: answer.key)
            written.append(answer.key)
        }
        return written
    }

    // MARK: answering

    /// The whole askpass path, from the token to the reply the program prints.
    ///
    /// - Parameters:
    ///   - parentArguments: the argv of the askpass's parent `ssh`, read by the askpass
    ///     with `sysctl KERN_PROCARGS2`. This is how a `ProxyJump` hop is told apart from
    ///     the master whose token it inherited (section 4.2).
    ///   - callerPID: the pid of the askpass process, from the XPC connection.
    public func answer(
        token: String,
        promptKind: String,
        prompt: String,
        parentArguments: [String] = [],
        callerPID: Int32? = nil
    ) -> AskpassReply {
        lock.lock()
        let session = sessions[token]
        lock.unlock()

        guard let session else {
            Log.ssh.error("an askpass request arrived with a token the agent never minted")
            return .refuse(reason: "unknown token")
        }

        lock.lock()
        let retired = session.retired
        let expiresAt = session.expiresAt
        let sshPID = session.sshPID
        session.invocations += 1
        let invocations = session.invocations
        lock.unlock()

        if retired {
            Log.ssh.error("an askpass request arrived with a retired token")
            return .refuse(reason: "retired token")
        }
        if now() > expiresAt {
            retire(token: token)
            Log.ssh.error("an askpass request arrived after the authentication deadline")
            return .refuse(reason: "expired token")
        }
        if invocations > maximumInvocations {
            retire(token: token)
            Log.ssh.error("an askpass token raised more prompts than a connection ever should")
            return .refuse(reason: "too many prompts for one connection")
        }
        if let callerPID, let sshPID, !ancestry.isDescendant(callerPID, of: sshPID) {
            Log.ssh.error(
                "an askpass request came from a process that is not a descendant of the ssh the token was issued to"
            )
            return .refuse(reason: "caller is not a descendant of the ssh the token was issued to")
        }

        let classified = AskpassPromptClassifier.classify(prompt: prompt, promptKind: promptKind)
        let resolution = self.resolution(for: session, parentArguments: parentArguments)
        return reply(to: classified, promptText: prompt, session: session, resolution: resolution)
    }

    // MARK: the section 4.2 table

    private func reply(
        to prompt: AskpassPrompt, promptText: String, session: Session,
        resolution: SSHResolution?
    ) -> AskpassReply {
        switch prompt {

        case .passphrase(let prefix):
            let path = AskpassBroker.identityPath(matching: prefix, in: resolution)
            let key = SecretKey.passphrase(path: path)
            return secretReply(for: key, prompt: prompt, promptText: promptText,
                               session: session, destination: resolution?.destination,
                               isSecret: true)

        case .password, .keyboardInteractivePassword:
            // Nothing is parsed out of the prompt text: the item is keyed by the
            // destination of the asking ssh, resolved with `ssh -G` (section 4.2), so a
            // HostKeyAlias in the prompt never reaches a key.
            guard let destination = resolution?.destination else {
                record(
                    miss: AskpassMiss(
                        prompt: prompt, promptText: promptText, key: nil, destination: nil,
                        refused: false, date: now()), on: session)
                Log.ssh.error("a password prompt arrived for an ssh whose destination could not be resolved")
                return .empty
            }
            let key = SecretKey.password(destination)
            return secretReply(for: key, prompt: prompt, promptText: promptText,
                               session: session, destination: destination, isSecret: true)

        case .confirmation(_, let isHostKey):
            // Section 4.3: `ask` during add, refused everywhere else - and the refusal
            // has to cover UpdateHostKeys=ask too, which is why every other connection
            // also runs UpdateHostKeys=no.
            if session.purpose == .collect, let responder = collectResponder {
                let request = AskpassCollectRequest(
                    locationID: session.locationID, prompt: prompt, promptText: promptText,
                    key: nil, destination: resolution?.destination, isSecret: false)
                if let answer = responder(request), !answer.isEmpty {
                    return .answer(answer)
                }
            }
            record(
                miss: AskpassMiss(
                    prompt: prompt, promptText: promptText, key: nil,
                    destination: resolution?.destination, refused: true, date: now()),
                on: session)
            let reason = isHostKey
                ? "the server's host key is not in known_hosts and this is not an `sshdrive add`"
                : "a confirmation prompt that needs a human"
            markRefusal(reason, on: session)
            return .refuse(reason: reason)

        case .userPresence(let description):
            // Acknowledged; ssh reads nothing back. During add this is what marks the key
            // touch-required and makes `add` refuse the location (section 4.2).
            lock.lock()
            if !session.touchRequiredKeys.contains(description) {
                session.touchRequiredKeys.append(description)
            }
            lock.unlock()
            record(
                miss: AskpassMiss(
                    prompt: prompt, promptText: promptText, key: nil,
                    destination: resolution?.destination, refused: false, date: now()),
                on: session)
            Log.ssh.notice("a key asked for a user-presence touch: \(description, privacy: .public)")
            return .empty

        case .notification:
            return .empty

        case .pin, .keyboardInteractiveChallenge, .unrecognised:
            record(
                miss: AskpassMiss(
                    prompt: prompt, promptText: promptText, key: nil,
                    destination: resolution?.destination, refused: true, date: now()),
                on: session)
            let reason = "a prompt that needs a human every time"
            markRefusal(reason, on: session)
            return .refuse(reason: reason)
        }
    }

    /// The shared path for the two kinds of stored answer.
    private func secretReply(
        for key: SecretKey, prompt: AskpassPrompt, promptText: String, session: Session,
        destination: SSHDestination?, isSecret: Bool
    ) -> AskpassReply {
        lock.lock()
        let masked = session.maskedAccounts.contains(key.account)
        let purpose = session.purpose
        lock.unlock()

        if !masked {
            do {
                if let value = try store.secret(for: key), !value.isEmpty {
                    lock.lock()
                    session.used.append((key: key, value: value))
                    lock.unlock()
                    return .answer(value)
                }
            } catch {
                Log.ssh.error("the keychain refused a lookup: \(String(describing: error), privacy: .public)")
            }
        }

        record(
            miss: AskpassMiss(
                prompt: prompt, promptText: promptText, key: key, destination: destination,
                refused: false, date: now()), on: session)

        if purpose == .collect, let responder = collectResponder {
            let request = AskpassCollectRequest(
                locationID: session.locationID, prompt: prompt, promptText: promptText,
                key: key, destination: destination, isSecret: isSecret)
            if let answer = responder(request) {
                // "An empty answer is a refusal of that prompt: nothing is stored, and
                // the attempt fails over" (section 4.2).
                guard !answer.isEmpty else { return .empty }
                lock.lock()
                session.used.append((key: key, value: answer))
                lock.unlock()
                return .answer(answer)
            }
        }

        // No stored item and nobody to ask: answer empty. ssh gives up on that identity
        // after its single attempt and moves on; if nothing else works the "Permission
        // denied" that follows is classified on exit like any other (section 4.2).
        return .empty
    }

    // MARK: helpers

    private func record(miss: AskpassMiss, on session: Session) {
        lock.lock(); defer { lock.unlock() }
        session.misses.append(miss)
    }

    private func markRefusal(_ reason: String, on session: Session) {
        lock.lock(); defer { lock.unlock() }
        if session.refusalReason == nil { session.refusalReason = reason }
    }

    /// The master's own prompts carry the argv the agent built; a `ProxyJump` hop carries
    /// its own, and is resolved with `ssh -G` (section 4.2).
    private func resolution(for session: Session, parentArguments: [String]) -> SSHResolution? {
        lock.lock()
        let known = session.resolution
        let argv = session.argv
        lock.unlock()

        let isTheMaster =
            parentArguments.isEmpty || argv.isEmpty || parentArguments == argv
        if isTheMaster, let known { return known }

        if !parentArguments.isEmpty, let resolved = resolver.resolve(argv: parentArguments) {
            if isTheMaster {
                lock.lock()
                session.resolution = resolved
                lock.unlock()
            }
            return resolved
        }
        return known
    }

    /// `ssh` prints the identity file through `%.100s`, so a long path arrives truncated.
    /// Map it back onto the full path when the asking `ssh`'s own `identityfile` list has
    /// one with that prefix; otherwise take the prompt at its word.
    static func identityPath(matching prefix: String, in resolution: SSHResolution?) -> String {
        guard let files = resolution?.identityFiles, !files.isEmpty else { return prefix }
        if files.contains(prefix) { return prefix }
        let matches = files.filter { $0.hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : prefix
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The seam `SSHProcess` and the tests use to drive the whole path without an `ssh`:
/// mint a token, feed prompts exactly as the askpass would, read the replies back.
public struct AskpassHarness {
    public let broker: AskpassBroker
    public let token: String

    public init(
        broker: AskpassBroker, locationID: String = "test", purpose: AskpassPurpose = .master,
        resolution: SSHResolution? = nil, argv: [String] = []
    ) {
        self.broker = broker
        self.token = broker.mint(
            locationID: locationID, purpose: purpose, resolution: resolution, argv: argv)
    }

    /// One askpass invocation. `promptKind` is `SSH_ASKPASS_PROMPT`; pass "" for a secret.
    @discardableResult
    public func prompt(
        _ text: String, kind: String = "", parentArguments: [String] = [],
        callerPID: Int32? = nil
    ) -> AskpassReply {
        broker.answer(
            token: token, promptKind: kind, prompt: text, parentArguments: parentArguments,
            callerPID: callerPID)
    }

    public var misses: [AskpassMiss] { broker.misses(token: token) }
    public var info: AskpassSessionInfo? { broker.info(token: token) }
}

/// The seam `SSHProcess` reaches the broker through (section 4.2). `SSHProcess` spawns
/// the `ssh`; it must not also know how a secret is stored, and `Secrets` must not know
/// how a process is spawned, so the two meet on `AskpassTokenProviding` and nothing else.
extension AskpassBroker: AskpassTokenProviding {
    public func mintToken(locationID: String, argv: [String]) -> String {
        mint(locationID: locationID, purpose: .master, argv: argv)
    }

    public func attachToken(_ token: String, pid: Int32, argv: [String]) {
        attach(pid: pid, argv: argv, to: token)
    }

    public func retireToken(_ token: String) {
        retire(token: token)
    }
}
