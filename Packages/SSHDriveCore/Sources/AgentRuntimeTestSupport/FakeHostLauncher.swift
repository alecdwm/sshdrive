import AgentRuntime
import Config
import Foundation
import SFTP
import SSHProcess
import Secrets
import ServerModel
import XPCProtocols

/// `TransportLauncher` over a `FakeRemoteHost`: the agent's real connect path after
/// authentication, against an in-process server.
///
/// The host decides each attempt's fate (`FakeRemoteHost.connect()`); this turns a failure
/// into the `SSHProcessError` an `ssh -N` would have produced - the stderr the host chose,
/// classified by the real `SSHExitClassifier` - after the time `ssh` would have taken to
/// produce it, on the agent's clock. A success is handed to
/// `SSHBackedTransport.establish`, so channel 1, the root check, the channel probe, the
/// server probe and the capability cache all run exactly as they do on a Mac.
public final class FakeHostLauncher: TransportLauncher, @unchecked Sendable {
    public let host: FakeRemoteHost
    private let clock: any AgentClock
    private let lock = NSLock()
    private var _configuration: SFTPClient.Configuration

    /// - Parameter deadlineTick: how often each SFTP client's deadline sweeper looks. The
    ///   default 200 ms costs a driven clock five steps a second for every channel; one
    ///   second keeps a 20 s request deadline within a second of its real value.
    public init(host: FakeRemoteHost, clock: any AgentClock, deadlineTick: Duration = .seconds(1)) {
        self.host = host
        self.clock = clock
        var configuration = SFTPClient.Configuration()
        configuration.clock = clock
        configuration.deadlineTick = deadlineTick
        self._configuration = configuration
    }

    private var _connectedUptimes: [Double] = []

    /// When each attempt the host let through was made, on the agent's monotonic clock:
    /// what "after the last connect" is measured against when the wall clock jumps.
    public var connectedUptimes: [Double] { lock.withLock { _connectedUptimes } }

    /// The base every SFTP channel's client is built from.
    public var sftpConfiguration: SFTPClient.Configuration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    public func connect(
        location: Location, askpassPath: String?, askpass: (any AskpassTokenProviding)?,
        uploadTag: String, reprobeChannels: Bool
    ) async throws -> any LiveConnection {
        switch host.connect() {
        case .connected(let master):
            let now = clock.uptime()
            lock.withLock { _connectedUptimes.append(now) }
            return try await SSHBackedTransport.establish(
                master: master, location: location, uploadTag: uploadTag,
                reprobeChannels: reprobeChannels, clock: clock,
                sftpConfiguration: sftpConfiguration)
        case let .failed(stderr, status, after):
            if after > 0 { await clock.sleep(seconds: after) }
            throw SSHProcessError.connectionFailed(
                classification: SSHExitClassifier.classify(
                    role: .master, exitStatus: status, stderr: stderr,
                    agentDependent: location.agentDependent),
                stderr: stderr)
        case .passwordRefused(let stderr):
            // The prompt goes through the agent's own broker, as an askpass invocation
            // would put it there, and the classification reads the broker's record of it.
            var sentPassword = false
            if let askpass {
                let token = askpass.mintToken(locationID: location.id, argv: [])
                _ = (askpass as? AskpassBroker)?.answer(
                    token: token, promptKind: "", prompt: "\(host.user)@\(host.hostName)'s password: ")
                askpass.retireToken(token)
                sentPassword = askpass.servedPasswordPrompt(token: token)
            }
            throw SSHProcessError.connectionFailed(
                classification: SSHExitClassifier.classify(
                    role: .master, exitStatus: 255, stderr: stderr,
                    agentDependent: location.agentDependent, sentPassword: sentPassword),
                stderr: stderr)
        case .keyAgentNotReady:
            throw SSHProcessError.keyAgentUnavailable(.missing("/private/tmp/agent.sock"))
        case .authenticationDeadline(let after):
            await clock.sleep(seconds: after)
            throw SSHProcessError.connectionFailed(
                classification: SSHExitClassifier.classify(
                    role: .master, exitStatus: -1, stderr: "", deadlineExpired: true,
                    agentDependent: location.agentDependent),
                stderr: "")
        }
    }
}
