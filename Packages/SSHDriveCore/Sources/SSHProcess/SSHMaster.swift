import Foundation
import Logging
import XPCProtocols

/// The `-N` ControlMaster for one location, and the mux clients that run on its socket
/// (DESIGN.md section 6.1).
///
/// The master carries no session: authentication, the TCP connection and the mux socket,
/// nothing else. Every SFTP and exec channel is a mux client with its own process, so a
/// wedged channel is killed and reopened on its own without touching the connection.
/// `ControlPersist` is `no` and must stay so: with it set, `ssh` forks the master into the
/// background after authentication and the process the agent spawned exits, even under
/// `-N`, which would leave the agent with no pid to supervise, no stderr to read and no
/// exit to watch.
public actor SSHMaster {

    public struct Configuration: Sendable {
        public var locationID: String
        public var target: SSHTarget
        /// launchd's, with `HOME`, the askpass variables, and `PATH` and `SSH_AUTH_SOCK`
        /// replaced by the login shell snapshot (section 6.1).
        public var environment: [String: String]
        /// Only an `agentDependent` location consults a key agent, and only it is subject
        /// to the pre-spawn socket check and the deadline re-arm (section 4.2).
        public var agentDependent: Bool
        /// The chain the agent built as its own `ProxyCommand`, or nil.
        public var proxyCommand: String?
        /// Which socket to probe before spawning, for an `agentDependent` location.
        public var identityAgentSocket: String?
        /// 60 s from spawn, signalled by the control socket appearing. The 15 s
        /// `ConnectTimeout` is contained in it, never added (section 4.2, section 6.3).
        public var authenticationDeadline: TimeInterval
        public var controlPath: String
        /// `Contents/MacOS/sshdrive-askpass`, from the running bundle. Nil in a unit test
        /// and in `doctor`, where nothing may be prompted.
        public var askpassPath: String?
        /// The broker that mints the one-time token for this spawn and answers the
        /// prompts it raises (section 4.2). `SSHProcess` never sees a secret: it puts the
        /// token in the child's environment and retires it when the master exits.
        public var askpass: (any AskpassTokenProviding)?
        /// `yes` for every runtime connection. The collect connection of section 4.2 runs
        /// `ask`, so the fingerprint question of section 4.3 is raised and can be relayed
        /// to the terminal, or `accept-new` under `--trust-first`.
        public var hostKeyChecking: String
        /// True for the collect connection: its token is minted `collect`, so a prompt the
        /// keychain cannot answer is relayed to the CLI instead of skipped (section 4.2).
        public var isCollectConnection: Bool
        /// Stored items masked for this spawn, so a stale password reaches the terminal
        /// rather than being answered from the keychain and refused by the server
        /// (section 4.2).
        public var maskedAccounts: Set<String>
        /// Raise this one connection to `LogLevel=DEBUG1` and keep the server's
        /// identification string out of it.
        ///
        /// Section 8.1 wants `status` to name the server software, and section 6.1 says
        /// why nothing else can: the runtime masters run at `LogLevel=ERROR`, which prints
        /// no remote version, and a mux client never talks to the server at all. The
        /// collect connection of section 4.2 is a real, fresh `ssh` the agent makes once
        /// per `add`, so it is the one place the line is free. Everything that looks at
        /// this connection's stderr afterwards - the exit classifier and the sentence
        /// `add` prints - sees the debug lines stripped again, so raising the level
        /// changes no decision (2026-09-08).
        public var capturesRemoteVersion: Bool

        public init(
            locationID: String,
            target: SSHTarget,
            environment: [String: String],
            agentDependent: Bool = false,
            proxyCommand: String? = nil,
            identityAgentSocket: String? = nil,
            authenticationDeadline: TimeInterval = 60,
            controlPath: String? = nil,
            askpassPath: String? = nil,
            askpass: (any AskpassTokenProviding)? = nil,
            hostKeyChecking: String = "yes",
            isCollectConnection: Bool = false,
            maskedAccounts: Set<String> = [],
            capturesRemoteVersion: Bool = false
        ) {
            self.locationID = locationID
            self.target = target
            self.environment = environment
            self.agentDependent = agentDependent
            self.proxyCommand = proxyCommand
            self.identityAgentSocket = identityAgentSocket
            self.authenticationDeadline = authenticationDeadline
            self.controlPath = controlPath ?? ControlSocket.path(forLocationID: locationID)
            self.askpassPath = askpassPath
            self.askpass = askpass
            self.hostKeyChecking = hostKeyChecking
            self.isCollectConnection = isCollectConnection
            self.maskedAccounts = maskedAccounts
            self.capturesRemoteVersion = capturesRemoteVersion
        }
    }

    public private(set) var configuration: Configuration
    private var process: SpawnedProcess?
    private var stderrCollector: StderrCollector?
    public private(set) var lastClassification: SSHExitClassification?
    public private(set) var lastStderr: String = ""
    /// `ssh`'s "remote software version <x>", when this master was asked for it.
    public private(set) var remoteSoftwareVersion: String?
    /// The token minted for the running master, retired when it goes. A `ProxyJump` hop
    /// inherits it through the environment and is told apart by its own argv (section 4.2).
    public private(set) var askpassToken: String?
    /// The token the **last** spawn used, which `retireToken()` does not clear.
    ///
    /// `askpassToken` is the *live* one and goes as soon as the master dies, which is
    /// right for everything that might still put a prompt to it. But everything the
    /// connection recorded - the touch-required keys, the refusal reason, the answers it
    /// took from the keychain - is read off the broker's session *after* the attempt, and
    /// a failed attempt is exactly when section 4.2 needs it: a refused PIN is a failure,
    /// and "add explains which prompt it saw" has to survive it. Retiring the session is
    /// what stops it answering; forgetting it is what makes it unreadable, and the collect
    /// connection does that itself when it has finished with it (2026-09-08, Q8).
    public private(set) var lastAskpassToken: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var controlPath: String { configuration.controlPath }

    /// The exact command line, for `sshdrive show` and for a unit test.
    public var invocation: SSHInvocation {
        SSHCommandBuilder.master(
            target: configuration.target,
            controlPath: configuration.controlPath,
            proxyCommand: configuration.proxyCommand,
            hostKeyChecking: configuration.hostKeyChecking,
            logLevel: configuration.capturesRemoteVersion ? "DEBUG1" : "ERROR"
        )
    }

    public var isRunning: Bool {
        guard let process else { return false }
        return Spawn.poll(pid: process.pid) == nil
    }

    /// Spawns the master and waits for its control socket, which is created only once
    /// authentication has succeeded, so its appearance is the signal the deadline waits for.
    public func connect() async throws {
        if configuration.agentDependent {
            let result = IdentityAgentCheck.probe(configuration.identityAgentSocket)
            if result.isTransientFailure {
                lastClassification = .keyAgentNotReady
                throw SSHProcessError.keyAgentUnavailable(result)
            }
        }
        ControlSocket.unlink(configuration.controlPath)
        let invocation = self.invocation
        // One token per spawn, in this process's environment and nowhere else. Every hop
        // of an agent-built ProxyCommand inherits it, which is exactly what section 4.2
        // wants; a mux client gets an environment with all of it stripped (below).
        let environment = mintedEnvironment(argv: invocation.argv)
        Log.ssh.info("spawning master for \(self.configuration.locationID, privacy: .public)")
        let spawned = try Spawn.run(
            executable: invocation.executable,
            argv: invocation.argv,
            environment: environment,
            wantsStderr: true,
            stdinFromDevNull: true
        )
        if let token = askpassToken {
            configuration.askpass?.attachToken(token, pid: spawned.pid, argv: invocation.argv)
        }
        let collector = StderrCollector(fd: spawned.stderrFD)
        process = spawned
        stderrCollector = collector

        let deadline = Date().addingTimeInterval(configuration.authenticationDeadline)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: configuration.controlPath) {
                lastClassification = nil
                // The identification string is exchanged before authentication, so it is
                // already in the buffer by the time the socket appears.
                _ = absorb(collector.text)
                Log.ssh.info("master up for \(self.configuration.locationID, privacy: .public)")
                return
            }
            if let exit = Spawn.poll(pid: spawned.pid) {
                let stderr = absorb(collector.text)
                lastStderr = stderr
                let classification = SSHExitClassifier.classify(
                    role: .master, exitStatus: exit.status, terminationSignal: exit.signal,
                    stderr: stderr, agentDependent: configuration.agentDependent
                )
                lastClassification = classification
                process = nil
                retireToken()
                throw SSHProcessError.connectionFailed(classification: classification, stderr: stderr)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // The deadline. For an agentDependent location this stops reconnection and is
        // re-armed once; for a first-pass location, which no key agent can be holding up,
        // it is a transient failure retried through the breaker (section 6.1).
        let stderr = absorb(collector.text)
        lastStderr = stderr
        Spawn.terminate(spawned, grace: 1)
        process = nil
        retireToken()
        let classification = SSHExitClassifier.classify(
            role: .master, exitStatus: -1, stderr: stderr,
            deadlineExpired: true, agentDependent: configuration.agentDependent
        )
        lastClassification = classification
        throw SSHProcessError.connectionFailed(classification: classification, stderr: stderr)
    }

    /// `-O check`: asks our own child, over the socket, whether it is alive. It says
    /// nothing about the server or the TCP connection, so it is the cheap "is our child
    /// sane" check; the per-request deadline is the real liveness probe (section 6.1).
    ///
    /// "Cheap" is about the server, not about us: it still spawns an `ssh` and waits for
    /// it, and it used to do that synchronously inside this actor - up to ten seconds of a
    /// cooperative pool thread with the master's actor held, which every other caller then
    /// queued behind (2026-09-09). It awaits now, so the actor is released while the child
    /// runs. Nothing on the `status` path calls it any more; what does is section 6.4's
    /// "did the helper's stream die with the connection or on its own", which has to know.
    public func check() async -> Bool {
        let invocation = SSHCommandBuilder.control(
            "check", controlPath: configuration.controlPath, host: configuration.target.host
        )
        guard let result = try? await Spawn.captureAsync(
            executable: invocation.executable, argv: invocation.argv,
            environment: configuration.environment, timeout: 10
        ) else { return false }
        return result.exit.isClean
    }

    /// `-O exit`: the clean shutdown. Also what runs at the will-sleep message, on every
    /// master, before the Mac abandons the connection (section 6.1).
    public func shutdown() {
        let invocation = SSHCommandBuilder.control(
            "exit", controlPath: configuration.controlPath, host: configuration.target.host
        )
        _ = try? Spawn.capture(
            executable: invocation.executable, argv: invocation.argv,
            environment: configuration.environment, timeout: 10
        )
        if let process {
            _ = Spawn.poll(pid: process.pid)
            Spawn.terminate(process, grace: 1)
        }
        process = nil
        retireToken()
        ControlSocket.unlink(configuration.controlPath)
    }

    /// Takes the server's identification string out of a raw stderr buffer and hands
    /// back the buffer as every other reader expects to see it.
    ///
    /// Only the collect connection ever runs at `DEBUG1`; for every other master this is
    /// the identity function. For that one it is what keeps raising the level free: the
    /// exit classifier and the sentence `add` prints both see exactly the ERROR-level
    /// text they saw before, because `debug1:`/`debug2:`/`debug3:` lines are dropped
    /// (2026-09-08, section 8.1).
    @discardableResult
    private func absorb(_ raw: String) -> String {
        guard configuration.capturesRemoteVersion else { return raw }
        if let found = SSHMaster.remoteSoftwareVersion(inDebugOutput: raw) {
            remoteSoftwareVersion = found
        }
        return SSHMaster.withoutDebugLines(raw)
    }

    /// `debug1: Remote protocol version 2.0, remote software version OpenSSH_9.2p1 …`
    public static func remoteSoftwareVersion(inDebugOutput raw: String) -> String? {
        let marker = "remote software version "
        for line in lines(of: raw) {
            guard let range = line.range(of: marker) else { continue }
            let value = line[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    public static func withoutDebugLines(_ raw: String) -> String {
        lines(of: raw)
            .filter { line in
                !(line.hasPrefix("debug1: ") || line.hasPrefix("debug2: ")
                    || line.hasPrefix("debug3: "))
            }
            .joined(separator: "\n")
    }

    /// **`ssh` ends every stderr log line with `\r\n`, and in Swift `"\r\n"` is one
    /// `Character`.** So `split(separator: "\n")` finds no separator at all in `ssh -v`
    /// output, the whole transcript is one "line", and the first thing that reads a value
    /// off it takes the rest of the file with it: the captured server version became
    /// `Tailscale` followed by a hundred `debug1:` lines, which `status` then printed
    /// (measured 2026-09-08). Normalise the line endings first, on scalars.
    static func lines(of raw: String) -> [Substring] {
        var normalised = ""
        normalised.reserveCapacity(raw.unicodeScalars.count)
        var previousWasCR = false
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\r":
                normalised.unicodeScalars.append("\n")
            case "\n":
                if !previousWasCR { normalised.unicodeScalars.append("\n") }
            default:
                normalised.unicodeScalars.append(scalar)
            }
            previousWasCR = scalar == "\r"
        }
        return normalised.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Reads the master's exit once it has one, and classifies it. The exit of the `-N`
    /// master is the disconnect signal for the location.
    public func classifyExitIfEnded() -> SSHExitClassification? {
        guard let process, let exit = Spawn.poll(pid: process.pid) else { return nil }
        let stderr = absorb(stderrCollector?.text ?? "")
        lastStderr = stderr
        let classification = SSHExitClassifier.classify(
            role: .master, exitStatus: exit.status, terminationSignal: exit.signal,
            stderr: stderr, agentDependent: configuration.agentDependent
        )
        lastClassification = classification
        self.process = nil
        retireToken()
        return classification
    }

    /// The environment for the master itself: the location's, plus the askpass variables
    /// and a token minted for this one spawn (section 4.2). Without a broker or an
    /// askpass path it is the environment unchanged, which is what a unit test wants.
    func mintedEnvironment(argv: [String]) -> [String: String] {
        guard let askpass = configuration.askpass, let path = configuration.askpassPath else {
            askpassToken = nil
            return configuration.environment
        }
        let token = configuration.isCollectConnection
            ? askpass.mintCollectToken(
                locationID: configuration.locationID, argv: argv,
                maskedAccounts: configuration.maskedAccounts)
            : askpass.mintToken(locationID: configuration.locationID, argv: argv)
        askpassToken = token
        lastAskpassToken = token
        return AskpassEnvironment.environment(
            base: configuration.environment, askpassPath: path, token: token)
    }

    /// Retiring ends every hop with the master, since a hop's `-W` pipe closes with it.
    private func retireToken() {
        guard let token = askpassToken else { return }
        configuration.askpass?.retireToken(token)
        askpassToken = nil
    }

    // MARK: - Channels

    /// `ssh $MUX -s <host> sftp`. One of these is the metadata channel and a second the
    /// bulk channel, so a long transfer never blocks a listing (section 6.1).
    public func openSFTPChannel(readinessDeadline: TimeInterval = 15) throws -> SFTPChannel {
        let invocation = SSHCommandBuilder.sftpChannel(
            controlPath: configuration.controlPath, host: configuration.target.host
        )
        let spawned = try Spawn.run(
            executable: invocation.executable, argv: invocation.argv,
            environment: muxEnvironment(), wantsStdin: true, wantsStdout: true, wantsStderr: true
        )
        let collector = StderrCollector(fd: spawned.stderrFD)
        let stream = PipeByteStream(readFD: spawned.stdoutFD, writeFD: spawned.stdinFD, label: "sftp")
        return SFTPChannel(stream: stream, process: spawned, stderrCollector: collector)
    }

    /// `ssh $MUX <host> sh -s`, the script on stdin, and the read that discards everything
    /// up to and including the sentinel (section 9.2).
    ///
    /// A channel whose sentinel has not arrived by the deadline is "shell output
    /// unusable", except when the first bytes are SFTP framing, which is a
    /// `ForceCommand internal-sftp` account and is reported as no shell access.
    public func openExecChannel(
        script: RemoteScript,
        readinessDeadline: TimeInterval = 30
    ) async throws -> ExecChannel {
        let invocation = SSHCommandBuilder.execChannel(
            controlPath: configuration.controlPath, host: configuration.target.host
        )
        let spawned = try Spawn.run(
            executable: invocation.executable, argv: invocation.argv,
            environment: muxEnvironment(), wantsStdin: true, wantsStdout: true, wantsStderr: true
        )
        let collector = StderrCollector(fd: spawned.stderrFD)
        let stream = PipeByteStream(readFD: spawned.stdoutFD, writeFD: spawned.stdinFD, label: "exec")
        // The whole script in a single write: dash reads its stdin in blocks, so anything
        // written while the shell was still parsing would vanish into its buffer (9.2).
        do {
            try await stream.write(script.data)
        } catch {
            stream.close()
            Spawn.terminate(spawned, grace: 1)
            throw try channelFailure(spawned: spawned, collector: collector)
        }

        var parser = SentinelParser(sentinel: script.sentinel)
        let deadline = Date().addingTimeInterval(readinessDeadline)
        var sawEOF = false
        do {
            try await stream.drain(deadline: deadline) { chunk in
                parser.append(chunk)
                return parser.sawOpeningSentinel
            }
            sawEOF = !parser.sawOpeningSentinel
        } catch {
            parser.finish()
            stream.close()
            Spawn.terminate(spawned, grace: 1)
            if parser.looksLikeForceCommandRefusal { throw SSHProcessError.noShellAccess(prefix: parser.prefix) }
            throw SSHProcessError.shellOutputUnusable(prefix: parser.prefix)
        }
        guard parser.sawOpeningSentinel else {
            parser.finish()
            stream.close()
            Spawn.terminate(spawned, grace: 1)
            if parser.looksLikeForceCommandRefusal { throw SSHProcessError.noShellAccess(prefix: parser.prefix) }
            // EOF with no sentinel and nothing on stdout is a channel that never opened,
            // which for a mux client is always master lost, never an auth failure.
            if sawEOF, parser.prefix.isEmpty {
                throw try channelFailure(spawned: spawned, collector: collector)
            }
            throw SSHProcessError.shellOutputUnusable(prefix: parser.prefix)
        }
        // The sentinel scan reads past the marker; hand the rest back so the script's own
        // first bytes are not swallowed.
        if !parser.payload.isEmpty { stream.pushBack(parser.payload) }
        return ExecChannel(
            stream: stream, prefix: parser.prefix, sentinel: script.sentinel,
            process: spawned, stderrCollector: collector
        )
    }

    /// A mux client gets no askpass token: it runs `BatchMode=yes` and can never prompt,
    /// and the agent mints no token for one (section 4.2).
    private func muxEnvironment() -> [String: String] {
        AskpassEnvironment.removingAskpass(from: configuration.environment)
    }

    private func channelFailure(spawned: SpawnedProcess, collector: StderrCollector) throws -> Error {
        let exit = Spawn.poll(pid: spawned.pid) ?? Spawn.wait(pid: spawned.pid)
        let stderr = collector.text
        let classification = SSHExitClassifier.classify(
            role: .muxClient, exitStatus: exit.status, terminationSignal: exit.signal,
            stderr: stderr, channelOpened: false
        )
        return SSHProcessError.channelFailed(classification: classification, stderr: stderr)
    }
}
