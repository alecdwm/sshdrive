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
    // `unregister()` returns, and `status` reports `notRegistered`, before launchd has
    // finished tearing the job down - and the difference is the whole reason this role
    // exists. launchd goes on spawning the *old* registration for a second or two, and a
    // `register()` that lands inside that window leaves the job holding a launch
    // constraint (LWCR) captured from the previous bundle's signature. Every spawn then
    // dies with `Launch Constraint Violation` / `EXC_CRASH (SIGKILL (Code Signature
    // Invalid))`, launchd retries on a 10 s throttle for ever, and the mach service never
    // comes back. Measured 2026-09-05, replacing an Apple Development build with a
    // Developer ID one; the same shape as any `brew upgrade`.
    //
    // `SMAppService.status` cannot see this, so the job itself is asked: `launchctl print`
    // answers non-zero once the service is gone from the GUI domain. Waiting here is what
    // makes the cask's "unregister, then open -g" postflight safe, since Homebrew runs the
    // two back to back (section 10).
    let label = "gui/\(getuid())/\(SSHDriveIdentifiers.agentLabel)"
    var gone = false
    for _ in 0 ..< 150 {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        probe.arguments = ["print", label]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        if probe.terminationStatus != 0 { gone = true; break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    Log.agent.notice(
        "login item teardown \(gone ? "finished" : "did not finish in 30 s", privacy: .public)")
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

    // Section 10: a TERM from the cask's `uninstall` stanza exits 0 with every master shut
    // down, and the vnode watch on our own executable hands over to a bundle an upgrade
    // put in our place (section 10.1).
    AgentLifecycle.install()
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
