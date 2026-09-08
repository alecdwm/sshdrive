import AgentRuntime
import Foundation
import Logging
import XPCProtocols

/// The two dispatch sources behind `AgentRuntime.AgentLifecycle` (DESIGN.md sections 10,
/// 10.1): a SIGTERM source for the Homebrew cask's `uninstall` stanza, and an `O_EVTONLY`
/// vnode watch on our own executable for the bundle being replaced by an upgrade.
///
/// Both hand straight over: what counts as a replacement worth exiting for, and how long
/// to wait for one, is `AgentRuntime.AgentLifecycle`.
enum AgentLifecycleAdapter {

    /// Both, armed once from `main.swift` in the launchd role.
    static func install(manager: DomainManager, environment: AgentEnvironment) {
        installTerminationHandler(manager: manager, environment: environment)
        installBundleWatch(manager: manager, environment: environment)
    }

    // MARK: TERM

    private static var termSource: DispatchSourceSignal?

    /// The cask's `uninstall` stanza is `signal: ["TERM", "org.shirls.sshdrive.agent"]`,
    /// and Homebrew runs it on `brew upgrade` and `brew reinstall` as well as on
    /// `brew uninstall`. Section 10 also says the agent "exits with status 0 on TERM", and
    /// that matters exactly as much as it sounds: the plist sets `KeepAlive` with
    /// `SuccessfulExit` false, and the **default** disposition for SIGTERM is death by
    /// signal, which launchd reads as an unsuccessful exit and restarts at once - from
    /// whatever bundle sits at the path at that moment, which mid-upgrade is the old one
    /// about to be deleted. So TERM is handled, not defaulted: masters down, status 0.
    private static func installTerminationHandler(
        manager: DomainManager, environment: AgentEnvironment
    ) {
        // The default action has to be disabled explicitly or it races the source.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // The decision - every master down, then exit 0 - is
            // `AgentRuntime.AgentLifecycle`, which is where `sshdrive agent stop` takes it
            // too and where `P4` asserts it. This is the source and nothing else.
            Task {
                await AgentLifecycle.shutdownAndExit(
                    reason: "SIGTERM", manager: manager, environment: environment)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + AgentLifecycle.shutdownGraceSeconds
            ) {
                Log.agent.error("shutdown did not finish in 20 s; exiting anyway")
                environment.endpoint.terminate(status: AgentLifecycle.exitStatus)
            }
        }
        source.resume()
        termSource = source
    }

    // MARK: the bundle underneath us

    private static var bundleSource: DispatchSourceFileSystemObject?

    /// Section 10.1: "The agent watches its own executable with a vnode dispatch source;
    /// when it is deleted or replaced, the agent waits until the bundle at its path is
    /// readable, its `Info.plist` parses, and its main executable is a different inode
    /// from the one the agent is running … and then exits cleanly, and the next mach
    /// lookup starts the new build."
    private static func installBundleWatch(
        manager: DomainManager, environment: AgentEnvironment
    ) {
        let executable = environment.bundle.executableURL
        guard let originalInode = environment.bundle.inode(ofPath: executable.path) else {
            Log.agent.error("cannot stat my own executable; the upgrade watch is off")
            return
        }
        let descriptor = open(executable.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.agent.error("cannot open my own executable for events; the upgrade watch is off")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.delete, .rename, .write, .revoke],
            queue: .main)
        source.setEventHandler {
            Log.agent.notice("my own executable was replaced; waiting for the new bundle")
            source.cancel()
            Task {
                let ready = await AgentLifecycle.awaitReplacement(
                    executable: executable, originalInode: originalInode,
                    inspector: environment.bundle, clock: environment.clock)
                guard ready else { return }
                await AgentLifecycle.shutdownAndExit(
                    reason: "a new bundle is in place", manager: manager,
                    environment: environment)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        bundleSource = source
        Log.agent.info("watching \(executable.path, privacy: .public) for an upgrade")
    }
}
