import Foundation
import Config
import Logging
import SSHProcess
import Secrets
import XPCProtocols

/// The agent's secrets store and its askpass broker (docs/design/secrets.md).
///
/// One broker for the whole agent: tokens are per spawn, but the table of live tokens, the
/// misses each connection recorded and the answers a collect connection used all belong to
/// the process. The *store* is a seam - `KeychainSecretsStore` on Darwin, where the agent
/// is the only process with `keychain-access-groups` (docs/design/components.md), and
/// `InMemorySecretsStore` everywhere else - so the whole askpass flow runs on Linux
/// without a keychain.
public final class AgentSecrets: Sendable {
    public let store: any SecretsStore
    public let broker: AskpassBroker
    /// The askpass program beside this executable, taken from the running bundle.
    public let askpassPath: String?

    public init(
        store: any SecretsStore, askpassPath: String?,
        resolver: (any SSHResolving)? = nil
    ) {
        self.store = store
        // `SSHGResolver` is how the broker learns the destination of the `ssh` that is
        // asking - the one thing that tells a `ProxyJump` hop from the master whose token
        // it inherited. It runs `/usr/bin/ssh -G` by default; a harness that has installed
        // a stand-in `ssh` hands its own in, or the hops would be resolved by a binary
        // that is not the one connecting.
        self.broker = resolver.map { AskpassBroker(store: store, resolver: $0) }
            ?? AskpassBroker(store: store)
        self.askpassPath = askpassPath
    }

    /// The process-wide one, set by `AgentRuntimeBootstrap.install`. `Apps/Agent`'s askpass
    /// listener reaches the broker through this and through nothing else; everything
    /// inside `AgentRuntime` takes it from the environment it was handed.
    nonisolated(unsafe) public static var shared = AgentSecrets(
        store: InMemorySecretsStore(), askpassPath: nil)
}

// MARK: - `sshdrive debug secrets`

/// The `sshdrive debug secrets` hooks drive the real `Secrets` store and the askpass path
/// end to end from the launchd-started agent, which is the only place either can run.
enum AgentSecretsDebug {

    static func run(_ arguments: [String: String], manager: DomainManager) async throws -> Data {
        let secrets = manager.secrets
        switch arguments["op"] ?? "list" {
        case "store":
            let key = try requireKey(arguments)
            guard let value = arguments["value"], !value.isEmpty else {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "debug secrets store needs --value.")
            }
            try secrets.store.setSecret(value, for: key)
            return try json(["stored": key.account, "report": key.report])

        case "lookup":
            let key = try requireKey(arguments)
            let value = try secrets.store.secret(for: key)
            var report: [String: Any] = ["key": key.account, "found": value != nil]
            // The value itself never leaves the agent; --value says whether it matches.
            if let expected = arguments["value"] { report["matches"] = (value == expected) }
            if let value { report["length"] = value.count }
            return try json(report)

        case "delete":
            let key = try requireKey(arguments)
            try secrets.store.removeSecret(for: key)
            return try json(["deleted": key.account])

        case "list":
            let keys = try secrets.store.keys()
            let unparsed = try secrets.store.accounts()
                .filter { SecretKey(account: $0) == nil }
            return try json([
                "accessGroup": SSHDriveIdentifiers.keychainAccessGroup,
                "service": SSHDriveIdentifiers.appBundleID,
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
            return try await connect(arguments, manager: manager)

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
    /// protocol armed, which is how a launchd-started agent authenticates from the
    /// keychain with no tty anywhere. The command line here is deliberately minimal; the
    /// master and its mux clients are built in `SSHProcess`.
    private static func connect(
        _ arguments: [String: String], manager: DomainManager
    ) async throws -> Data {
        let secrets = manager.secrets
        guard let destinationText = arguments["destination"],
            let destination = splitDestination(
                destinationText, port: Int(arguments["port"] ?? "22") ?? 22)
        else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "debug secrets connect needs --destination user@host [--port N].")
        }
        guard let askpass = secrets.askpassPath else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "sshdrive-askpass is not beside this executable.")
        }

        var argv = [
            SSHProcess.sshBinaryPath,
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
            // ProxyJump is never handed to `ssh`. Each hop is rebuilt as the agent's own
            // ProxyCommand by the one builder that knows the rules - ControlMaster=no
            // *and* ControlPath=none, the nested percent doubling, the single quoting,
            // and ProxyCommand written *before* ProxyJump=none (docs/design/ssh.md).
            let hops = try JumpHop.parseChain(jump)
            if let proxy = ProxyChainBuilder.proxyCommand(for: hops, identityAgentNone: true) {
                argv += ["-o", "ProxyCommand=\(proxy)", "-o", "ProxyJump=none"]
            }
        }
        if arguments["noAgent"] != "false" {
            // A first-pass location runs IdentityAgent=none for good.
            argv += ["-o", "IdentityAgent=none"]
        }
        argv.append("\(destination.user)@\(destination.hostname)")
        argv.append(arguments["command"] ?? "echo sshdrive-askpass-ok")

        let purpose: AskpassPurpose = (arguments["purpose"] == "collect") ? .collect : .master
        let token = secrets.broker.mint(
            locationID: arguments["location"] ?? "debug",
            purpose: purpose,
            resolution: SSHResolution(destination: destination),
            argv: argv)
        defer { secrets.broker.retire(token: token) }

        // The same environment a master gets (docs/design/ssh.md): launchd's, with
        // `HOME`, and with `PATH` and `SSH_AUTH_SOCK` from the login shell snapshot. It
        // matters here and not only for masters: a key that lives in a 1Password or
        // Secretive agent whose socket is exported from `.zshrc` is invisible to
        // launchd's own `SSH_AUTH_SOCK`, which always names Apple's `ssh-agent`.
        let environment = AskpassEnvironment.environment(
            base: await AgentSSHEnvironment.shared.environment(),
            askpassPath: askpass, token: token)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHProcess.sshBinaryPath)
        // argv[0] is the absolute path to `ssh`, never a `PATH` lookup.
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let started = Date()
        try process.run()
        secrets.broker.attach(pid: process.processIdentifier, argv: argv, to: token)

        // The 60 s authentication deadline, applied here as a plain wait: this hook has
        // no control socket to watch for.
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

        let info = secrets.broker.info(token: token)
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
