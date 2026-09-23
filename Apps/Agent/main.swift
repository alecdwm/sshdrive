import AgentRuntime
import Foundation
import Logging
import XPCInterfaces
import XPCProtocols

// SSH Drive.app's main executable is the background agent (docs/design/components.md).
// The same binary runs in three roles, and this file is the whole of what tells them
// apart:
//
//   launchd     the login agent proper, started by SMAppService from
//               Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist, which sets
//               SSHDRIVE_AGENT_ROLE=launchd. It holds the mach service and does the work.
//
//   unregister  SSHDRIVE_AGENT_ROLE=unregister: drop the login item, wait for launchd to
//               let go of the job, and exit. The cask's postflight runs it before it
//               re-opens the app.
//
//   app         what `open -g -a "SSH Drive"` launches, from the Homebrew postflight or
//               from `sshdrive doctor`. Launching the app is what registers the extension
//               with PlugInKit and the login item through SMAppService, and both must be
//               done from the app's own bundle. It registers, pings the mach service so
//               launchd starts the real instance and so a job that cannot run is seen as
//               one, repairs that job if it finds it, and exits.
//
// Every decision inside those roles - what counts as a replacement bundle, how long to
// wait for launchd, what registration does and does not repair - is `AgentRuntime`.

let role = ProcessInfo.processInfo.environment["SSHDRIVE_AGENT_ROLE"] ?? "app"
let environment = AgentEnvironment.runningOnMacOS
let agent = AgentRuntimeBootstrap.install(environment: environment)

/// One line per launch when our own bundle still carries `com.apple.quarantine`
/// (docs/design/packaging.md). The agent itself runs quarantined - launchd starts it
/// directly - but LaunchServices registers no plugin of such a bundle until it has been
/// assessed through a user-visible launch, so the File Provider extension is missing and
/// every domain call fails. `sshdrive doctor`'s "quarantine" check says the same thing
/// with the fix; this is what puts it in the log of an install nobody ran `doctor` on.
func warnIfQuarantined() {
    let path = environment.bundle.bundleURL.path
    guard let value = environment.bundle.quarantineValue(atPath: path) else { return }
    Log.agent.warning(
        "the bundle at \(path, privacy: .public) is quarantined (\(value, privacy: .public)); LaunchServices will not register the File Provider extension until it is cleared - run `sshdrive doctor`"
    )
}

/// One bounded ping of the mach service, on its own connection. The mach lookup itself is
/// what makes launchd start the agent on a fresh install; the reply is what says the job
/// launchd started can run.
///
/// Each call connects afresh: a connection that has been invalidated answers nothing. The
/// timeout is needed because a job that cannot satisfy its launch constraint accepts the
/// connection and then never replies (`MQ-063`), which no error handler fires for.
func pingAgent(timeout: Double) async -> Bool {
    let connection = NSXPCConnection(
        machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
    connection.remoteObjectInterface = SSHDriveXPCInterface.agent
    connection.resume()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let outcome = PingOutcome()
        let finish: @Sendable (Bool) -> Void = { answered in
            guard outcome.claim() else { return }
            connection.invalidate()
            continuation.resume(returning: answered)
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Log.agent.error("the agent did not answer: \(error, privacy: .public)")
            finish(false)
        } as? SSHDriveAgentProtocol
        guard let proxy else {
            finish(false)
            return
        }
        proxy.ping(interfaceVersion: sshDriveXPCInterfaceVersion) { version in
            Log.agent.notice(
                "the launchd agent answered, interface version \(version, privacy: .public)")
            finish(true)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}

/// The continuation may be resumed from the reply, from the error handler or from the
/// timeout, and exactly one of them may win.
final class PingOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

switch role {
case "unregister":
    let done = DispatchSemaphore(value: 0)
    var ok = false
    Task {
        let outcome = await AgentLifecycle.unregisterAndWait(
            loginItem: environment.loginItem, launchd: environment.launchd,
            uid: getuid(), clock: environment.clock)
        ok = outcome.unregistered
        done.signal()
    }
    done.wait()
    exit(ok ? 0 : 1)

case "launchd":
    Log.agent.notice("agent starting from launchd")
    warnIfQuarantined()
    AgentLifecycle.register(loginItem: environment.loginItem)

    let delegate = ListenerDelegate(manager: agent, environment: environment)
    let listener = NSXPCListener(machServiceName: SSHDriveIdentifiers.machServiceName)
    listener.delegate = delegate
    listener.resume()
    Log.agent.notice(
        "listening on \(SSHDriveIdentifiers.machServiceName, privacy: .public)")

    Task { await agent.start() }

    // A TERM from the cask's `uninstall` stanza exits 0 with every master shut down, and
    // the vnode watch on our own executable hands over to a bundle an upgrade put in our
    // place (docs/design/packaging.md).
    AgentLifecycleAdapter.install(manager: agent, environment: environment)
    dispatchMain()

default:
    // Launched from the bundle, not by launchd. Register, make sure the agent that
    // registration produced can be talked to, and get out of the way.
    Log.agent.notice("app launch: registering the login item and the extension")
    let done = DispatchSemaphore(value: 0)
    var reachedAgent = false
    Task {
        reachedAgent = await AgentLifecycle.registerAndVerify(
            loginItem: environment.loginItem, launchd: environment.launchd, uid: getuid(),
            clock: environment.clock,
            reachable: { await pingAgent(timeout: AgentLifecycle.pingTimeoutSeconds) })
        done.signal()
    }
    done.wait()
    Log.agent.notice("app launch finished (agent reachable: \(reachedAgent, privacy: .public))")
    exit(0)
}
