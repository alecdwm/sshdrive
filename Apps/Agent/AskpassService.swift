import AgentRuntime
import Darwin
import Foundation
import Logging
import Secrets
import SSHProcess
import XPCInterfaces
import XPCProtocols

/// The object exported to `sshdrive-askpass`, and to nothing else.
///
/// The listener gives an askpass peer this one-method interface instead of the agent
/// interface (section 5.2: the peer requirement is the boundary, and the interface a peer
/// is handed follows from which of our four executables it is). So the process that
/// relays `ssh`'s prompts cannot remove a location or evict a cache, and the processes
/// that can do those cannot ask for a secret.
final class AskpassService: NSObject, SSHDriveAskpassProtocol {
    private let callerPID: Int32
    private let secrets: AgentSecrets

    init(callerPID: Int32, secrets: AgentSecrets) {
        self.callerPID = callerPID
        self.secrets = secrets
    }

    /// Wire an askpass peer up, or say it is not one. Called from `ListenerDelegate`
    /// after the code requirement has already been applied to the connection.
    static func register(peer connection: NSXPCConnection, environment: AgentEnvironment)
        -> Bool
    {
        let pid = connection.processIdentifier
        guard isAskpass(pid: pid, environment: environment) else { return false }
        connection.exportedInterface = SSHDriveXPCInterface.askpass
        connection.exportedObject = AskpassService(
            callerPID: pid, secrets: AgentSecrets.shared)
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
    private static func isAskpass(pid: Int32, environment: AgentEnvironment) -> Bool {
        guard let path = environment.peers.executablePath(pid: pid) else { return false }
        if let expected = AgentSecrets.shared.askpassPath { return path == expected }
        return (path as NSString).lastPathComponent == "sshdrive-askpass"
    }

    // MARK: SSHDriveAskpassProtocol

    func askpassRequest(
        token: String, promptKind: String, prompt: String, parentArguments: [String],
        reply: @escaping (String?, Error?) -> Void
    ) {
        // `ssh -G` for a ProxyJump hop and a keychain read both block; neither may run on
        // the connection's own queue.
        DispatchQueue.global(qos: .userInitiated).async { [callerPID, secrets] in
            // The parent argv is not a secret and is what tells a hop from its master.
            Log.ssh.debug(
                "askpass request from pid \(callerPID, privacy: .public), parent argv words: \(parentArguments.count, privacy: .public)"
            )
            let answer = secrets.broker.answer(
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
