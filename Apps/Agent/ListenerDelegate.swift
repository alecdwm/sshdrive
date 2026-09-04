import Foundation
import XPCProtocols
import Logging

/// The agent's XPC listener (DESIGN.md section 5.2).
///
/// The listener accepts a connection only from a peer that satisfies our code
/// requirement, set with `setCodeSigningRequirement` on the connection before it is
/// resumed. That call is the system's own audit-token check: it validates the peer's
/// audit token against the requirement, which no pid-based check can do safely. Every
/// process of the user can look the service up; only ours get past the delegate.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        do {
            if SSHDriveCodeRequirement.isOverridden {
                Log.agent.error(
                    "a spike override is in force: the peer requirement is SSHDRIVE_PEER_REQUIREMENT or ~/.sshdrive-spike-peer-requirement, not the build's. Debug builds only.")
            }
            try connection.setCodeSigningRequirement(SSHDriveCodeRequirement.current)
        } catch {
            Log.agent.error(
                "refusing a peer that does not satisfy the code requirement: \(error, privacy: .public)")
            return false
        }

        // sshdrive-askpass gets the one-method askpass interface and nothing else: the
        // path that hands out secrets must not also be able to remove a location
        // (DESIGN.md sections 4.2, 5.2).
        if AskpassService.register(peer: connection) { return true }

        connection.exportedInterface = SSHDriveXPCInterface.agent
        connection.exportedObject = AgentService(connection: connection)
        // Both remaining peers export a callback object of their own, and which one they
        // export follows from which of our executables they are - the same rule that gives
        // askpass its one-method interface (section 5.2). The extension takes progress and
        // reopen callbacks; the CLI takes the collect connection's relayed prompts
        // (section 4.2), which is the only thing the agent ever asks a terminal.
        connection.remoteObjectInterface =
            PeerExecutable.isCLI(pid: connection.processIdentifier)
            ? SSHDriveXPCInterface.cli
            : SSHDriveXPCInterface.fileProviderExtension

        // Section 5.3's restore has to reach every live reader, not only the one that
        // happens to be making the current call, so an extension peer goes in the table
        // the moment it is accepted.
        let isExtension = !PeerExecutable.isCLI(pid: connection.processIdentifier)
        if isExtension { ExtensionPeers.shared.add(connection) }

        connection.invalidationHandler = { [weak connection] in
            // A transfer whose extension process disappears mid-way is cancelled the same
            // way as one the user cancelled (section 5.2).
            if let connection, isExtension { ExtensionPeers.shared.remove(connection) }
            Log.agent.debug("peer connection invalidated")
        }

        connection.resume()
        Log.agent.debug("accepted a peer connection")
        return true
    }
}
