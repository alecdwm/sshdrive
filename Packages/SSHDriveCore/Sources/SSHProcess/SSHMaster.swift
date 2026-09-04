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
            askpass: (any AskpassTokenProviding)? = nil
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
        }
    }

    public private(set) var configuration: Configuration
    private var process: SpawnedProcess?
    private var stderrCollector: StderrCollector?
    public private(set) var lastClassification: SSHExitClassification?
    public private(set) var lastStderr: String = ""
    /// The token minted for the running master, retired when it goes. A `ProxyJump` hop
    /// inherits it through the environment and is told apart by its own argv (section 4.2).
    public private(set) var askpassToken: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var controlPath: String { configuration.controlPath }

    /// The exact command line, for `sshdrive show` and for a unit test.
    public var invocation: SSHInvocation {
        SSHCommandBuilder.master(
            target: configuration.target,
            controlPath: configuration.controlPath,
            proxyCommand: configuration.proxyCommand
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
                Log.ssh.info("master up for \(self.configuration.locationID, privacy: .public)")
                return
            }
            if let exit = Spawn.poll(pid: spawned.pid) {
                let stderr = collector.text
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
        let stderr = collector.text
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
    public func check() -> Bool {
        let invocation = SSHCommandBuilder.control(
            "check", controlPath: configuration.controlPath, host: configuration.target.host
        )
        guard let result = try? Spawn.capture(
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

    /// Reads the master's exit once it has one, and classifies it. The exit of the `-N`
    /// master is the disconnect signal for the location.
    public func classifyExitIfEnded() -> SSHExitClassification? {
        guard let process, let exit = Spawn.poll(pid: process.pid) else { return nil }
        let stderr = stderrCollector?.text ?? ""
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
        let token = askpass.mintToken(locationID: configuration.locationID, argv: argv)
        askpassToken = token
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
