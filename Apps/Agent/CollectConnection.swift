import Foundation
import AgentCore
import Config
import Secrets
import SSHProcess
import XPCProtocols
import Logging

/// The verification connection `sshdrive add` and `sshdrive passwd` make (DESIGN.md
/// section 4.2), and the `AddFlow.AttemptRunning` the state machine drives.
///
/// "The agent runs the exact command it will use later, in its own environment, with the
/// token marked *collect*." Exactly that: an `SSHMaster` on a scratch control path, which
/// is the same `ssh` command line the location's real master runs, differing only in
/// `StrictHostKeyChecking` (`ask` here, so the fingerprint question of section 4.3 is
/// raised and can be relayed) and in the socket it binds. The master's control socket
/// appearing *is* authentication having succeeded, which is why this needs no remote
/// command and works against a `ForceCommand internal-sftp` account that could not run one.
///
/// Afterwards the master is shut down and the location connects for real from the stored
/// answers, which is what makes "a location that passes `add` never prompts from the agent
/// again" a thing that was tested rather than assumed.
final class CollectConnection: AddFlow.AttemptRunning, @unchecked Sendable {

    /// Everything the collect connection needs that the location itself does not carry
    /// yet, because during `add` there is no location.
    struct Request: Sendable {
        var locationID: String
        var target: SSHTarget
        var environment: [String: String]
        var askpassPath: String?
        /// The `ssh -G` resolution of the destination, so the broker keys a password on
        /// `user@hostname:port` and not on the alias (section 4.2).
        var resolution: SSHConfigResolution
        /// Identity files in offer order, for the passphrase prompt's `%.100s` mapping and
        /// for the touch refusal's "run --identity …" hint.
        var identityFiles: [String]
    }

    private let request: Request
    private let broker: AskpassBroker
    private let relay: CLIRelay?

    /// Recorded per attempt so the flow can tell a stale stored secret from one the user
    /// has just typed.
    private let lock = NSLock()
    private var answeredByUser: Set<String> = []
    private var hostKeyDeclined = false
    private var sawPasswordPrompt = false
    private var unanswered: [String] = []

    init(request: Request, broker: AskpassBroker, relay: CLIRelay?) {
        self.request = request
        self.broker = broker
        self.relay = relay
    }

    /// One attempt. Installs the responder, spawns the master, waits for the socket, and
    /// takes everything the broker's session recorded back off it.
    func run(_ attempt: AddFlow.Attempt) async -> AddFlow.AttemptResult {
        lock.lock()
        answeredByUser = []
        hostKeyDeclined = false
        sawPasswordPrompt = false
        unanswered = []
        lock.unlock()

        var target = request.target
        // Section 4.2: the first pass runs `IdentityAgent=none` so `ssh` can use only key
        // files, passphrases and passwords; the second runs with the key agent.
        target.identityAgentNone = attempt.identityAgentNone

        let hops: [JumpHop]
        do {
            hops = try request.resolution.jumpChain()
        } catch {
            return AddFlow.AttemptResult(
                authenticated: false, classification: .transient,
                stderr: error.localizedDescription)
        }
        // A hop gets the same host-key setting as the master, which is the whole reason
        // the chain is rebuilt rather than handed to `ssh -J`: a `-W` child of `ssh -J`
        // receives a fresh option set and would ask the question with no askpass armed
        // (testbed/README.md, and section 6.1).
        let proxyCommand = ProxyChainBuilder.proxyCommand(
            for: hops, identityAgentNone: attempt.identityAgentNone,
            hostKeyChecking: attempt.hostKeyChecking)

        let socket = (ControlSocket.temporaryDirectory() as NSString)
            .appendingPathComponent(
                "\(ControlSocket.namePrefix)c\(String(UUID().uuidString.prefix(6)).lowercased())")
        var configuration = SSHMaster.Configuration(
            locationID: request.locationID,
            target: target,
            environment: request.environment,
            agentDependent: !attempt.identityAgentNone,
            proxyCommand: proxyCommand,
            // A person is at the keyboard for this one connection, so the deadline is the
            // broker's collect deadline rather than section 4.2's unattended 60 s.
            authenticationDeadline: 300,
            controlPath: socket,
            askpassPath: request.askpassPath,
            askpass: broker,
            hostKeyChecking: attempt.hostKeyChecking,
            isCollectConnection: true,
            maskedAccounts: attempt.maskedAccounts)
        configuration.identityAgentSocket = nil

        let master = SSHMaster(configuration: configuration)
        broker.collectResponder = { [weak self] request in self?.answer(request) }
        defer { broker.collectResponder = nil }

        var authenticated = false
        var classification: SSHExitClassification = .clean
        var stderr = ""
        do {
            try await master.connect()
            authenticated = true
        } catch let error as SSHProcessError {
            if case let .connectionFailed(kind, text) = error {
                classification = kind
                stderr = text
            } else {
                classification = .transient
                stderr = error.localizedDescription
            }
        } catch {
            classification = .transient
            stderr = error.localizedDescription
        }

        let token = await master.askpassToken
        let info = token.flatMap { broker.info(token: $0) }
        // The master goes either way: if it authenticated, the location's own master is
        // what mounts it, and if it did not there is nothing to keep.
        await master.shutdown()
        ControlSocket.unlink(socket)

        lock.lock()
        let byUser = answeredByUser
        let declined = hostKeyDeclined
        let sawPassword = sawPasswordPrompt
        let missed = unanswered
        lock.unlock()

        let used = token.map { broker.usedAnswers(token: $0) } ?? []
        let fromStore = used.map(\.key.account).filter { !byUser.contains($0) }

        if authenticated, let token {
            // "When the connection succeeds, every answer that was actually used is
            // written to the keychain; a wrong password is never stored" (section 4.2).
            do {
                let written = try broker.commit(token: token)
                if !written.isEmpty {
                    Log.agent.notice(
                        "stored \(written.count, privacy: .public) secret(s) for \(self.request.locationID, privacy: .public)"
                    )
                }
                committedKeys = written.map(\.account)
            } catch {
                Log.agent.error("could not store a secret: \(error, privacy: .public)")
            }
        }
        if let token { broker.forget(token: token) }

        return AddFlow.AttemptResult(
            authenticated: authenticated,
            classification: classification,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            touchRequiredKeys: info?.touchRequiredKeys ?? [],
            refusalReason: info?.refusalReason,
            hostKeyDeclined: declined || classification == .hostKeyFailed,
            accountsAnsweredFromStore: Array(Set(fromStore)),
            sawPasswordPrompt: sawPassword,
            unansweredPrompts: missed)
    }

    /// Keychain accounts the successful attempt wrote. `add` records them on the location,
    /// which is what `remove` counts references against (section 8).
    private(set) var committedKeys: [String] = []

    // MARK: the relayed prompt

    /// The broker's `collectResponder`: shows the prompt on the terminal and returns what
    /// was typed. An empty answer is a deliberate refusal of that prompt (section 4.2).
    private func answer(_ request: AskpassCollectRequest) -> String? {
        guard let relay else {
            lock.lock(); unanswered.append(request.promptText); lock.unlock()
            return nil
        }
        let kind: String
        var detail = ""
        var secret = request.isSecret

        switch request.prompt {
        case .passphrase:
            kind = "passphrase"
            detail = request.key.map { "It will be stored in your keychain as \($0.report)." } ?? ""
            detail += "\nPress Enter to skip this key and let ssh try the next one."
        case .password, .keyboardInteractivePassword:
            kind = "password"
            lock.lock(); sawPasswordPrompt = true; lock.unlock()
            detail = request.key.map { "It will be stored in your keychain as \($0.report)." } ?? ""
            // Section 4.2: a user whose only key lives in 1Password and whose server also
            // accepts passwords would otherwise type a password and end up with a location
            // that quietly authenticates by password.
            detail += "\nYour key files did not authenticate and the server accepts "
                + "passwords; press Enter to skip this and try your key agent instead."
        case .confirmation(_, let isHostKey):
            kind = isHostKey ? "hostkey" : "confirm"
            // Section 4.3: read visible, and the answer goes to `ssh`, which writes it to
            // the user's own `known_hosts` exactly as it would have from a tty.
            secret = false
            detail = isHostKey
                ? "Answer yes only if that fingerprint is the server's. ssh writes the "
                    + "answer to your own ~/.ssh/known_hosts."
                : ""
        case .userPresence, .notification:
            kind = "notice"
            relay.note(request.promptText)
            return ""
        case .pin, .keyboardInteractiveChallenge, .unrecognised:
            // Never relayed: these need a human on every connection, and section 4.2
            // refuses the location rather than creating one that fails every reconnect.
            lock.lock(); unanswered.append(request.promptText); lock.unlock()
            return nil
        }

        let typed = relay.prompt(
            kind: kind, prompt: request.promptText, detail: detail, secret: secret)
        guard let typed else {
            lock.lock(); unanswered.append(request.promptText); lock.unlock()
            return nil
        }
        lock.lock()
        if kind == "hostkey", typed.lowercased() != "yes", !typed.hasPrefix("SHA256:") {
            hostKeyDeclined = true
        }
        if let key = request.key, !typed.isEmpty { answeredByUser.insert(key.account) }
        lock.unlock()
        return typed
    }
}

extension CollectConnection {

    /// `ssh-keygen -lf <path>` for every identity file, so a user-presence notice's
    /// fingerprint can be matched back onto the key that asked for the touch (section 4.2).
    static func fingerprints(of identityFiles: [String], environment: [String: String])
        -> [String: String]
    {
        var out: [String: String] = [:]
        for path in identityFiles {
            let candidate = FileManager.default.fileExists(atPath: path + ".pub")
                ? path + ".pub" : path
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            guard let result = try? Spawn.capture(
                executable: "/usr/bin/ssh-keygen",
                argv: ["/usr/bin/ssh-keygen", "-lf", candidate],
                environment: environment, timeout: 5),
                result.exit.isClean
            else { continue }
            let words = String(decoding: result.stdout, as: UTF8.self)
                .split(separator: " ", omittingEmptySubsequences: true)
            if words.count >= 2 { out[path] = String(words[1]) }
        }
        return out
    }
}
