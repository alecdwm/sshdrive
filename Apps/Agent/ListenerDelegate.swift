import AgentRuntime
import Foundation
import XPCInterfaces
import XPCProtocols
import Logging

/// The agent's XPC listener (`docs/design/extension.md`).
///
/// The listener accepts a connection only from a peer that satisfies our code
/// requirement, set with `setCodeSigningRequirement` on the connection before it is
/// resumed. That call is the system's own audit-token check: it validates the peer's
/// audit token against the requirement, which no pid-based check can do safely. Every
/// process of the user can look the service up; only ours get past the delegate.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let manager: DomainManager
    private let environment: AgentEnvironment

    init(manager: DomainManager, environment: AgentEnvironment) {
        self.manager = manager
        self.environment = environment
    }

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        do {
            if SSHDriveCodeRequirement.isOverridden {
                Log.agent.error(
                    "a peer-requirement override is in force: the requirement comes from SSHDRIVE_PEER_REQUIREMENT or ~/.sshdrive-peer-requirement-override, not from the build. Debug builds only.")
            }
            try connection.setCodeSigningRequirement(SSHDriveCodeRequirement.current)
        } catch {
            Log.agent.error(
                "refusing a peer that does not satisfy the code requirement: \(error, privacy: .public)")
            return false
        }

        // sshdrive-askpass gets the one-method askpass interface and nothing else: the
        // path that hands out secrets must not also be able to remove a location
        // (`docs/design/secrets.md`).
        if AskpassService.register(peer: connection, environment: environment) {
            return true
        }

        connection.exportedInterface = SSHDriveXPCInterface.agent
        connection.exportedObject = AgentService(connection: connection, manager: manager)
        // Both remaining peers export a callback object of their own, and which one they
        // export follows from which of our executables they are - the same rule that gives
        // askpass its one-method interface. The extension takes progress and reopen
        // callbacks; the CLI takes the collect connection's relayed prompts, which is the
        // only thing the agent ever asks a terminal.
        connection.remoteObjectInterface =
            environment.peers.isCLI(pid: connection.processIdentifier)
            ? SSHDriveXPCInterface.cli
            : SSHDriveXPCInterface.fileProviderExtension

        // The index restore has to reach every live reader, not only the one that
        // happens to be making the current call, so an extension peer goes in the table
        // the moment it is accepted.
        let isExtension = !environment.peers.isCLI(pid: connection.processIdentifier)
        if isExtension { ExtensionPeers.shared.add(connection) }

        connection.invalidationHandler = { [weak connection] in
            // A transfer whose extension process disappears mid-way is cancelled the same
            // way as one the user cancelled.
            if let connection, isExtension { ExtensionPeers.shared.remove(connection) }
            Log.agent.debug("peer connection invalidated")
        }

        connection.resume()
        Log.agent.debug("accepted a peer connection")
        return true
    }
}
