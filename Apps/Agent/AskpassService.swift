import Foundation
import Darwin
import Secrets
import SSHProcess
import XPCProtocols
import Logging

/// The agent's keychain and its askpass broker (DESIGN.md section 4.2).
///
/// One broker for the whole agent: tokens are per spawn, but the table of live tokens,
/// the misses each connection recorded and the answers a collect connection used all
/// belong to the process. `KeychainSecretsStore` is reachable only from here, because the
/// agent is the only process with `keychain-access-groups` (section 3.1).
enum AgentSecrets {
    static let store: SecretsStore = KeychainSecretsStore(
        accessGroup: SSHDriveIdentifiers.keychainAccessGroup)

    static let broker = AskpassBroker(store: store)

    /// The askpass program beside this executable, taken from the running bundle.
    static var askpassPath: String? { AskpassEnvironment.askpassPath() }
}

/// The object exported to `sshdrive-askpass`, and to nothing else.
///
/// The listener gives an askpass peer this one-method interface instead of the agent
/// interface (section 5.2: the peer requirement is the boundary, and the interface a peer
/// is handed follows from which of our four executables it is). So the process that
/// relays `ssh`'s prompts cannot remove a location or evict a cache, and the processes
/// that can do those cannot ask for a secret.
final class AskpassService: NSObject, SSHDriveAskpassProtocol {
    private let callerPID: Int32

    init(callerPID: Int32) {
        self.callerPID = callerPID
    }

    /// Wire an askpass peer up, or say it is not one. Called from `ListenerDelegate`
    /// after the code requirement has already been applied to the connection.
    static func register(peer connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard isAskpass(pid: pid) else { return false }
        connection.exportedInterface = SSHDriveXPCInterface.askpass
        connection.exportedObject = AskpassService(callerPID: pid)
        connection.invalidationHandler = {
            Log.ssh.debug("askpass connection invalidated")
        }
        connection.resume()
        Log.ssh.debug("accepted an askpass peer")
        return true
    }

    /// Is this peer our `sshdrive-askpass`? The code requirement has already established
    /// that it is one of our four signed executables (section 5.2); this only says which,
    /// so the wrong one cannot be handed the secrets interface.
    private static func isAskpass(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            Log.ssh.error("could not read the path of peer pid \(pid, privacy: .public)")
            return false
        }
        let path = String(cString: buffer)
        if let expected = AgentSecrets.askpassPath { return path == expected }
        return (path as NSString).lastPathComponent == "sshdrive-askpass"
    }

    // MARK: SSHDriveAskpassProtocol

    func askpassRequest(
        token: String, promptKind: String, prompt: String, parentArguments: [String],
        reply: @escaping (String?, Error?) -> Void
    ) {
        // `ssh -G` for a ProxyJump hop and a keychain read both block; neither may run on
        // the connection's own queue.
        DispatchQueue.global(qos: .userInitiated).async { [callerPID] in
            // The parent argv is not a secret and is what tells a hop from its master.
            Log.ssh.debug(
                "askpass request from pid \(callerPID, privacy: .public), parent argv words: \(parentArguments.count, privacy: .public)"
            )
            let answer = AgentSecrets.broker.answer(
                token: token, promptKind: promptKind, prompt: prompt,
                parentArguments: parentArguments, callerPID: callerPID)
            switch answer {
            case .answer(let value):
                reply(value, nil)
            case .empty:
                reply("", nil)
            case .refuse(let reason):
                Log.ssh.notice("askpass prompt refused: \(reason, privacy: .public)")
                reply(nil, SSHDriveAgentError.notAuthenticated.asNSError(reason))
            }
        }
    }
}

// MARK: - `sshdrive debug secrets`

/// The milestone 2 hook set. `sshdrive debug keychain` proved the agent can reach the
/// data-protection keychain at all (S1 d2); these drive the real `Secrets` store and the
/// askpass path end to end from the launchd-started agent, which is the only place either
/// can run. Documented in docs/skeleton-notes.md.
enum AgentSecretsDebug {

    static func run(_ arguments: [String: String]) async throws -> Data {
        switch arguments["op"] ?? "list" {
        case "store":
            let key = try requireKey(arguments)
            guard let value = arguments["value"], !value.isEmpty else {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "debug secrets store needs --value.")
            }
            try AgentSecrets.store.setSecret(value, for: key)
            return try json(["stored": key.account, "report": key.report])

        case "lookup":
            let key = try requireKey(arguments)
            let value = try AgentSecrets.store.secret(for: key)
            var report: [String: Any] = ["key": key.account, "found": value != nil]
            // The value itself never leaves the agent; --value says whether it matches.
            if let expected = arguments["value"] { report["matches"] = (value == expected) }
            if let value { report["length"] = value.count }
            return try json(report)

        case "delete":
            let key = try requireKey(arguments)
            try AgentSecrets.store.removeSecret(for: key)
            return try json(["deleted": key.account])

        case "list":
            let keys = try AgentSecrets.store.keys()
            let unparsed = try AgentSecrets.store.accounts()
                .filter { SecretKey(account: $0) == nil }
            return try json([
                "accessGroup": SSHDriveIdentifiers.keychainAccessGroup,
                "service": KeychainSecretsStore.service,
                "items": keys.map { ["key": $0.account, "report": $0.report] },
                "unparsed": unparsed,
            ])

        case "classify":
            let prompt = arguments["prompt"] ?? ""
            let kind = arguments["kind"] ?? ""
            let classified = AskpassPromptClassifier.classify(prompt: prompt, promptKind: kind)
            return try json([
                "prompt": prompt, "promptKind": kind,
                "classified": String(describing: classified),
            ])

        case "connect":
            return try await connect(arguments)

        default:
            throw SSHDriveAgentError.notImplemented.asNSError(
                "debug secrets: op must be store, lookup, delete, list, classify or connect.")
        }
    }

    private static func requireKey(_ arguments: [String: String]) throws -> SecretKey {
        if let identity = arguments["identity"], !identity.isEmpty {
            return .passphrase(path: (identity as NSString).expandingTildeInPath)
        }
        if let key = arguments["key"], let parsed = SecretKey(account: key) {
            return parsed
        }
        if let destination = arguments["destination"] {
            let port = Int(arguments["port"] ?? "22") ?? 22
            guard let split = splitDestination(destination, port: port) else {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "debug secrets: --destination must be user@host.")
            }
            return .password(split)
        }
        throw SSHDriveAgentError.notImplemented.asNSError(
            "debug secrets needs --key password:u@h:p, --key passphrase:/path, --identity PATH, or --destination user@host [--port N].")
    }

    private static func splitDestination(_ text: String, port: Int) -> SSHDestination? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let user = String(text[text.startIndex..<at])
        let host = String(text[text.index(after: at)...])
        guard !user.isEmpty, !host.isEmpty else { return nil }
        return SSHDestination(user: user, hostname: host, port: port)
    }

    /// One real `ssh`, spawned from the agent's own environment with the askpass token
    /// protocol armed - the S2 proof that a launchd-started agent authenticates from the
    /// keychain with no tty anywhere. The command line here is deliberately minimal; the
    /// master and its mux clients are section 6.1's, in `SSHProcess`.
    private static func connect(_ arguments: [String: String]) async throws -> Data {
        guard let destinationText = arguments["destination"],
            let destination = splitDestination(
                destinationText, port: Int(arguments["port"] ?? "22") ?? 22)
        else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "debug secrets connect needs --destination user@host [--port N].")
        }
        guard let askpass = AgentSecrets.askpassPath else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "sshdrive-askpass is not beside this executable.")
        }

        var argv = [
            "/usr/bin/ssh",
            "-o", "BatchMode=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=15",
            "-o", "UpdateHostKeys=no",
            "-o", "StrictHostKeyChecking=\(arguments["hostKeyChecking"] ?? "yes")",
            "-p", String(destination.port),
        ]
        if let identity = arguments["identity"], !identity.isEmpty {
            argv += [
                "-o", "IdentitiesOnly=yes",
                "-i", (identity as NSString).expandingTildeInPath,
            ]
        }
        if let jump = arguments["jump"], !jump.isEmpty {
            // Section 6.1: ProxyJump is never handed to `ssh`. Each hop is rebuilt as the
            // agent's own ProxyCommand by the one builder that knows the rules -
            // ControlMaster=no *and* ControlPath=none, the nested percent doubling, the
            // single quoting, and ProxyCommand written *before* ProxyJump=none. This hook
            // used to carry a hand-rolled copy of that; it now takes a comma-separated
            // chain, so the two-hop testbed chain works here too.
            let hops = try JumpHop.parseChain(jump)
            if let proxy = ProxyChainBuilder.proxyCommand(for: hops, identityAgentNone: true) {
                argv += ["-o", "ProxyCommand=\(proxy)", "-o", "ProxyJump=none"]
            }
        }
        if arguments["noAgent"] != "false" {
            // Section 4.2: a first-pass location runs IdentityAgent=none for good.
            argv += ["-o", "IdentityAgent=none"]
        }
        argv.append("\(destination.user)@\(destination.hostname)")
        argv.append(arguments["command"] ?? "echo sshdrive-askpass-ok")

        let purpose: AskpassPurpose = (arguments["purpose"] == "collect") ? .collect : .master
        let token = AgentSecrets.broker.mint(
            locationID: arguments["location"] ?? "debug",
            purpose: purpose,
            resolution: SSHResolution(destination: destination),
            argv: argv)
        defer { AgentSecrets.broker.retire(token: token) }

        // The same environment a master gets (section 6.1): launchd's, with `HOME`, and
        // with `PATH` and `SSH_AUTH_SOCK` from the login shell snapshot. It matters here
        // and not only for masters: a key that lives in a 1Password or Secretive agent
        // whose socket is exported from `.zshrc` is invisible to launchd's own
        // `SSH_AUTH_SOCK`, which always names Apple's `ssh-agent`.
        let environment = AskpassEnvironment.environment(
            base: await AgentSSHEnvironment.shared.environment(),
            askpassPath: askpass, token: token)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // argv[0] is the absolute path, as section 6.1 requires.
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let started = Date()
        try process.run()
        AgentSecrets.broker.attach(pid: process.processIdentifier, argv: argv, to: token)

        // Section 4.2's authentication deadline, applied here as a plain wait: this hook
        // has no control socket to watch for.
        let killer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let out = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        killer.cancel()

        let info = AgentSecrets.broker.info(token: token)
        let report: [String: Any] = [
            "argv": argv,
            "askpass": askpass,
            "exitStatus": Int(process.terminationStatus),
            "seconds": Date().timeIntervalSince(started),
            "stdout": out.trimmingCharacters(in: .whitespacesAndNewlines),
            "stderr": err.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompts": info?.invocations ?? 0,
            "answeredFromKeychain": (info.map { $0.invocations - $0.misses.count }) ?? 0,
            "misses": (info?.misses ?? []).map {
                [
                    "prompt": $0.promptText,
                    "key": $0.key?.account ?? "",
                    "refused": $0.refused,
                ] as [String: Any]
            },
            "refusal": info?.refusalReason ?? "",
            "touchRequired": info?.touchRequiredKeys ?? [],
        ]
        return try json(report)
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }
}
