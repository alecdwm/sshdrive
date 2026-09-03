import Foundation
import ServiceManagement
import XPCProtocols
import Logging

// SSH Drive.app's main executable is the background agent (DESIGN.md section 3). The same
// binary runs in two roles:
//
//   launchd  the login agent proper, started by SMAppService from
//            Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist, which sets
//            SSHDRIVE_AGENT_ROLE=launchd. It holds the mach service and does the work.
//
//   app      what `open -g -a "SSH Drive"` launches, from the Homebrew postflight or
//            from `sshdrive doctor`. Launching the app is what registers the extension
//            with PlugInKit and the login item through SMAppService, and both must be
//            done from the app's own bundle (section 10). It registers, pokes the mach
//            service so launchd starts the real instance, and exits.

let role = ProcessInfo.processInfo.environment["SSHDRIVE_AGENT_ROLE"] ?? "app"

/// Registration is idempotent and is done on every launch rather than checking `status`
/// first (section 10).
func registerLoginItem() {
    let service = SMAppService.agent(plistName: "\(SSHDriveIdentifiers.agentLabel).plist")
    do {
        try service.register()
        Log.agent.notice("login item registered (status \(service.status.rawValue, privacy: .public))")
    } catch {
        Log.agent.error("SMAppService.register failed: \(error, privacy: .public)")
    }
}

switch role {
case "unregister":
    // SSHDRIVE_AGENT_ROLE=unregister: drop the login item and exit. Registration is
    // idempotent but not self-repairing: once the bundle has been deleted and put back
    // (a Homebrew upgrade, or any rm -rf + copy), launchd's background-task record still
    // names the old bundle and every spawn fails with "Could not find and/or execute
    // program specified by service", while SMAppService.register() keeps returning
    // success because the item is still, as far as it is concerned, enabled. Only
    // unregister() clears the record; the next launch re-registers it. See S1 (f) in
    // docs/spikes/milestone-1.md.
    let service = SMAppService.agent(plistName: "\(SSHDriveIdentifiers.agentLabel).plist")
    do {
        try service.unregister()
        Log.agent.notice("login item unregistered (status \(service.status.rawValue, privacy: .public))")
    } catch {
        Log.agent.error("SMAppService.unregister failed: \(error, privacy: .public)")
        exit(1)
    }
    exit(0)

case "launchd":
    Log.agent.notice("agent starting from launchd")
    registerLoginItem()

    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: SSHDriveIdentifiers.machServiceName)
    listener.delegate = delegate
    listener.resume()
    Log.agent.notice(
        "listening on \(SSHDriveIdentifiers.machServiceName, privacy: .public)")

    Task {
        await DomainManager.shared.start()
    }

    // TODO milestone 10: watch our own executable with a vnode dispatch source and exit
    // cleanly when the bundle is replaced, so an upgrade hands over to the new build
    // (section 10).
    dispatchMain()

default:
    // Launched from the bundle, not by launchd. Register and get out of the way.
    Log.agent.notice("app launch: registering the login item and the extension")
    registerLoginItem()

    // Poking the mach service is what makes launchd start the agent proper on a fresh
    // install, and is how this process notices that one already holds it.
    let connection = NSXPCConnection(
        machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
    connection.remoteObjectInterface = SSHDriveXPCInterface.agent
    connection.resume()

    let done = DispatchSemaphore(value: 0)
    var reachedAgent = false
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        Log.agent.error("the agent did not answer: \(error, privacy: .public)")
        done.signal()
    } as? SSHDriveAgentProtocol
    proxy?.ping(interfaceVersion: sshDriveXPCInterfaceVersion) { version in
        reachedAgent = true
        Log.agent.notice("the launchd agent answered, interface version \(version, privacy: .public)")
        done.signal()
    }
    if proxy == nil { done.signal() }
    _ = done.wait(timeout: .now() + 10)
    connection.invalidate()
    Log.agent.notice("app launch finished (agent reachable: \(reachedAgent, privacy: .public))")
    exit(0)
}
