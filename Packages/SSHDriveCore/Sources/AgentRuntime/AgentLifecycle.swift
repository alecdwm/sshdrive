import Foundation
import Logging
import XPCProtocols

/// The two ways the launchd-started agent is asked to go away that are not
/// `sshdrive agent stop`, as decisions rather than as sources: a TERM from the Homebrew
/// cask, and the bundle underneath it being replaced by an upgrade (DESIGN.md sections 10,
/// 10.1).
///
/// The dispatch sources themselves - `DispatchSource.makeSignalSource(signal: SIGTERM)`
/// and the `O_EVTONLY` vnode watch - are Darwin plumbing and stay in `Apps/Agent`. What is
/// here is what they decide: when a replacement bundle is ready to hand over to, and how
/// long to wait for one.
public enum AgentLifecycle {

    /// How long the shutdown may take before the agent exits anyway. Section 10: the plist
    /// sets `KeepAlive` with `SuccessfulExit` false, and the default disposition for
    /// SIGTERM is death by signal, which launchd reads as an unsuccessful exit and
    /// restarts at once - from whatever bundle sits at the path at that moment, which
    /// mid-upgrade is the old one about to be deleted. So TERM is handled, not defaulted:
    /// masters down, status 0.
    public static let shutdownGraceSeconds: Double = 20

    /// The status the agent exits with when it is asked to go away: **0**, always.
    ///
    /// Section 10: the plist sets `KeepAlive` with `SuccessfulExit` false, so any other
    /// status - including death by an undefaulted SIGTERM - is read as a crash and
    /// launchd restarts at once, from whatever bundle sits at the path in that moment,
    /// which mid-upgrade is the old one about to be deleted (`MQ-062` is what that leaves
    /// behind).
    public static let exitStatus: Int32 = 0

    /// The one shutdown: every master down, then exit 0.
    ///
    /// `sshdrive agent stop`, the cask's TERM and the upgrade handover are three ways of
    /// asking the same question and must not be three answers. Exiting without the
    /// shutdown leaves an `ssh -N` per location holding a connection to a server, with a
    /// control socket the next start unlinks out from under it (section 8, section 6.1;
    /// docs/spikes/results.md 2026-09-05) - and the master a restarted location holds
    /// without a socket at all (`SQ-043`) is then reachable by nothing, since `-O exit`
    /// needs the socket (`SQ-044`).
    ///
    /// Confidence: the ordering and the status are ours and are measured by `P4`. That
    /// launchd restarts on a non-zero exit is documented `KeepAlive`/`SuccessfulExit`
    /// behaviour, and the bundle-replacement half of what that costs is `MQ-062`,
    /// measured on the VM.
    @discardableResult
    public static func shutdownAndExit(
        reason: String, manager: DomainManager, environment: AgentEnvironment
    ) async -> DomainManager.ShutdownSummary {
        Log.agent.notice("\(reason, privacy: .public): shutting down and exiting 0")
        let summary = await manager.shutdownAll()
        environment.endpoint.terminate(status: exitStatus)
        return summary
    }

    /// One second apart, for five minutes. A replacement that never appears - somebody
    /// deleting the app and stopping there - leaves the agent running on the old inode,
    /// which is the right answer: there is nothing to hand over to.
    public static let replacementPollSeconds: Double = 1
    public static let replacementAttempts = 300

    /// Section 10.1: "the agent waits until the bundle at its path is readable, its
    /// `Info.plist` parses, and its main executable is a different inode from the one the
    /// agent is running, so it never hands over to a half-copied bundle and never waits
    /// forever on a `brew reinstall` of the same version".
    ///
    /// The "different inode" test is what makes a `brew reinstall` of the same version
    /// terminate: `ditto` of an identical tree still produces a new file, so the inode
    /// moves even when nothing else does.
    public static func replacementIsReady(
        executable: URL, bundle: URL, originalInode: UInt64, inspector: any BundleInspecting
    ) -> Bool {
        guard let current = inspector.inode(ofPath: executable.path), current != originalInode
        else { return false }
        guard inspector.isReadable(path: executable.path) else { return false }
        return inspector.bundleIdentifier(atPath: bundle.path) == SSHDriveIdentifiers.appBundleID
    }

    /// The bundle three components above the main executable: `…/SSH Drive.app`.
    public static func bundleURL(forExecutable executable: URL) -> URL {
        executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // SSH Drive.app
    }

    /// Waits for the replacement and answers whether one arrived, polling rather than
    /// watching: the window is seconds, the check is a `stat` and a plist parse, and a
    /// vnode source on a directory that is itself being replaced is its own problem.
    public static func awaitReplacement(
        executable: URL, originalInode: UInt64, inspector: any BundleInspecting,
        clock: any AgentClock, attempts: Int = replacementAttempts
    ) async -> Bool {
        let bundle = bundleURL(forExecutable: executable)
        for _ in 0 ..< max(1, attempts) {
            if replacementIsReady(
                executable: executable, bundle: bundle, originalInode: originalInode,
                inspector: inspector)
            {
                Log.agent.notice("a new bundle is in place; exiting so the next lookup starts it")
                return true
            }
            await clock.sleep(seconds: replacementPollSeconds)
        }
        Log.agent.error("no replacement bundle appeared in five minutes; staying up")
        return false
    }

    /// The `SSHDRIVE_AGENT_ROLE=unregister` role of section 10, as a decision.
    ///
    /// `unregister()` returns, and `SMAppService.status` reports `notRegistered`, before
    /// launchd has finished tearing the job down - and the difference is the whole reason
    /// the role exists. launchd goes on spawning the *old* registration for a second or
    /// two, and a `register()` that lands inside that window leaves the job holding a
    /// launch constraint captured from the previous bundle's signature; every spawn then
    /// dies with `Launch Constraint Violation`, launchd retries on a 10 s throttle for
    /// ever, and the mach service never comes back (measured 2026-09-05, `MQ-063`).
    ///
    /// So the job itself is asked, not `SMAppService`: `launchctl print` answers non-zero
    /// once the service is gone from the GUI domain. Waiting here is what makes the cask's
    /// "unregister, then open -g" postflight safe, since Homebrew runs the two back to
    /// back.
    ///
    /// - Returns: whether the unregister succeeded, and whether launchd had really dropped
    ///   the job before the wait gave up.
    public static func unregisterAndWait(
        loginItem: any LoginItemControlling, launchd: any LaunchdControlling, uid: UInt32,
        clock: any AgentClock, attempts: Int = 150
    ) async -> (unregistered: Bool, gone: Bool) {
        do {
            try loginItem.unregister()
            Log.agent.notice(
                "login item unregistered (status \(loginItem.status(), privacy: .public))")
        } catch {
            Log.agent.error("SMAppService.unregister failed: \(error, privacy: .public)")
            return (false, false)
        }
        let label = "gui/\(uid)/\(SSHDriveIdentifiers.agentLabel)"
        let gone = await launchd.waitUntilGone(
            label: label, attempts: attempts, clock: clock)
        Log.agent.notice(
            "login item teardown \(gone ? "finished" : "did not finish in 30 s", privacy: .public)")
        return (true, gone)
    }

    /// Registration is idempotent and is done on every launch rather than checking
    /// `status` first (section 10). It is **not** self-repairing: once the bundle has been
    /// deleted and put back, launchd's background-task record still names the old bundle
    /// and every spawn fails, while `register()` keeps returning success (`MQ-062`).
    public static func register(loginItem: any LoginItemControlling) {
        do {
            try loginItem.register()
            Log.agent.notice(
                "login item registered (status \(loginItem.status(), privacy: .public))")
        } catch {
            Log.agent.error("SMAppService.register failed: \(error, privacy: .public)")
        }
    }
}
