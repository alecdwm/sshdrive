import Foundation
import Logging
import XPCProtocols

/// The two ways the launchd-started agent is asked to go away that are not
/// `sshdrive agent stop`, as decisions rather than as sources: a TERM from the Homebrew
/// cask, and the bundle underneath it being replaced by an upgrade
/// (docs/design/packaging.md).
///
/// The dispatch sources themselves - `DispatchSource.makeSignalSource(signal: SIGTERM)`
/// and the `O_EVTONLY` vnode watch - are Darwin plumbing and stay in `Apps/Agent`. What is
/// here is what they decide: when a replacement bundle is ready to hand over to, and how
/// long to wait for one.
public enum AgentLifecycle {

    /// How long the shutdown may take before the agent exits anyway. The plist sets
    /// `KeepAlive` with `SuccessfulExit` false, and the default disposition for
    /// SIGTERM is death by signal, which launchd reads as an unsuccessful exit and
    /// restarts at once - from whatever bundle sits at the path at that moment, which
    /// mid-upgrade is the old one about to be deleted. So TERM is handled, not defaulted:
    /// masters down, status 0.
    public static let shutdownGraceSeconds: Double = 20

    /// The status the agent exits with when it is asked to go away: **0**, always.
    ///
    /// The plist sets `KeepAlive` with `SuccessfulExit` false, so any other
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
    /// control socket the next start unlinks out from under it - and the master a
    /// restarted location holds without a socket at all (`SQ-043`) is then reachable by
    /// nothing, since `-O exit` needs the socket (`SQ-044`).
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

    /// The agent waits until the bundle at its path is readable, its `Info.plist` parses,
    /// and its main executable is a different inode from the one the agent is running, so
    /// it never hands over to a half-copied bundle and never waits forever on a
    /// `brew reinstall` of the same version.
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

    /// The `SSHDRIVE_AGENT_ROLE=unregister` role, as a decision.
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
    /// once the service is gone from the GUI domain, and then the grace below is waited
    /// out. Both together are what makes the cask's "unregister, then open -g" postflight
    /// safe, since Homebrew runs the two back to back.
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
        if gone {
            await clock.sleep(seconds: unregisterGraceSeconds)
            Log.agent.notice(
                "waited \(unregisterGraceSeconds, privacy: .public) s after launchd let the job go (MQ-063)"
            )
        }
        return (true, gone)
    }

    /// How many times a launch that finds the agent silent unregisters, waits the
    /// grace and registers again before giving up.
    public static let repairAttempts = 3

    /// How long to wait after launchd has dropped the job before a `register()` may
    /// land. The job being gone from `launchctl print` is not a sufficient condition:
    /// measured on macOS 26.4.1 (2026-09-23), the `unregister` role's poll said the job
    /// was gone 7 ms after `unregister()` returned, the `open -g` 110 ms later registered
    /// it again, and the spawn that followed died `EXC_CRASH SIGKILL (Code Signature
    /// Invalid)` with `namespace CODESIGNING, indicator "Launch Constraint Violation"` -
    /// `launchctl print` then reporting `job state = spawn failed`, `last exit code = 78:
    /// EX_CONFIG` and `needs LWCR update | has LWCR`, launchd retrying every 10 s for
    /// ever, and the mach service accepting connections and answering no command. The same
    /// bundle, with about 5 s between the unregister and the `open -g`, started first
    /// time. The constraint is captured from the bundle's signature, so a build whose
    /// signing certificate differs from the installed one is what exposes it: the 0.1.3 to
    /// 0.1.4 upgrade did not hit it and 0.1.4 to 0.1.5, which changed certificate, did.
    ///
    /// Confidence: 5 s is the interval that worked, not a measured boundary.
    public static let unregisterGraceSeconds: Double = 5

    /// Registration is idempotent and is done on every launch rather than checking
    /// `status` first. It is **not** self-repairing: once the bundle has been deleted and
    /// put back, launchd's background-task record still names the old bundle and every
    /// spawn fails, while `register()` keeps returning success (`MQ-062`).
    public static func register(loginItem: any LoginItemControlling) {
        do {
            try loginItem.register()
            Log.agent.notice(
                "login item registered (status \(loginItem.status(), privacy: .public))")
        } catch {
            Log.agent.error("SMAppService.register failed: \(error, privacy: .public)")
        }
    }

    /// How long one launch waits for the agent to answer after registering it, and how
    /// often it asks. launchd's own retry throttle is 10 s, so a job that is going to come
    /// up has come up well inside this.
    public static let reachableTimeoutSeconds: Double = 10
    public static let reachablePollSeconds: Double = 0.5

    /// How long a single ping of the mach service may take before it counts as no answer.
    /// A job holding a launch constraint it cannot satisfy *accepts* the connection and
    /// then answers nothing (`MQ-063`), so the ping needs its own bound or the poll below
    /// never gets a second turn.
    public static let pingTimeoutSeconds: Double = 2

    /// What launching the app does: register the login item, and make sure the agent it
    /// registered can actually be talked to.
    ///
    /// A registration that landed inside the window `unregister()` leaves open carries a
    /// launch constraint from the previous bundle's signature. Every spawn then dies, and
    /// nothing about `register()`, `SMAppService.status` or the mach lookup says so - the
    /// service is there and accepts connections; it is the command that never comes back
    /// (`MQ-063`). The only thing that distinguishes it is asking the agent a question and
    /// not getting an answer, so that is what this does, and the repair is the same pair
    /// the cask's postflight runs: unregister, wait for launchd and for the grace, then
    /// register again.
    ///
    /// - Parameter reachable: one bounded question to the agent, answering whether it
    ///   replied. Called repeatedly, so it must not reuse a connection it invalidated.
    /// - Returns: whether the agent answered by the end.
    public static func registerAndVerify(
        loginItem: any LoginItemControlling, launchd: any LaunchdControlling, uid: UInt32,
        clock: any AgentClock, reachable: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        register(loginItem: loginItem)
        if await waitUntilReachable(clock: clock, reachable: reachable) { return true }

        // A registration made inside the unregister window carries a launch constraint
        // the new bundle cannot satisfy, and one repair is not always enough: on macOS
        // 26.4.1 a register made 100 ms after the 5 s grace still died the same way and
        // the second repair started the agent (2026-09-23). So the repair is bounded,
        // not single.
        for attempt in 1 ... repairAttempts {
            Log.agent.error(
                "the agent did not answer in \(reachableTimeoutSeconds, privacy: .public) s; the job is stuck (MQ-063: a registration made inside the unregister window carries a launch constraint it cannot satisfy) - unregistering and registering again (repair \(attempt, privacy: .public) of \(repairAttempts, privacy: .public))"
            )
            let outcome = await unregisterAndWait(
                loginItem: loginItem, launchd: launchd, uid: uid, clock: clock)
            guard outcome.unregistered else { return false }
            register(loginItem: loginItem)
            if await waitUntilReachable(clock: clock, reachable: reachable) { return true }
        }
        Log.agent.error(
            "the agent still does not answer after \(repairAttempts, privacy: .public) re-registrations; run `sshdrive doctor`")
        return false
    }

    /// `lsregister`, which is not on any PATH and is spelled absolutely wherever it is
    /// run: by the adapter behind `BundleInspecting`, and in `doctor`'s remedy text.
    public static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks"
        + "/LaunchServices.framework/Support/lsregister"

    /// How long one launch waits for PlugInKit to pick the extension up after the
    /// LaunchServices record has been rebuilt, and how often it asks. Measured on 27.0
    /// (2026-09-23), `pkd` logged `Created plugin` 16 ms after `lsregister` returned.
    public static let plugInRegistrationTimeoutSeconds: Double = 5
    public static let plugInRegistrationPollSeconds: Double = 0.5

    /// How long to wait before each further pass when the first one leaves the extension
    /// unregistered, and so how many passes there are: one immediately, then one after
    /// each of these.
    ///
    /// Straight after Homebrew moves the bundle into `/Applications`, neither the code
    /// signing subsystem nor `lsregister` is usable: the postflight's `spctl --assess`
    /// answered `internal error in Code Signing subsystem`, its `lsregister` answered
    /// `failed to scan /Applications/SSH Drive.app: -10822 from spotlight`
    /// (`kLSServerCommunicationErr`) and exited non-zero, and its `open -g` answered
    /// `-10810 kLSUnknownErr` with `Couldn't communicate with a helper application` under
    /// it, so the app-launch role never ran either. The same two commands run by hand
    /// minutes later both succeeded (`MQ-081`, measured on 27.0, 2026-09-23). The window
    /// is minutes and it clears on its own, so the passes are spread across roughly six
    /// minutes rather than repeated tightly.
    ///
    /// Confidence: 15/60/300 covers the one observed recovery with room either side; it is
    /// not a measured boundary.
    public static let registrationRetryBackoffSeconds: [Double] = [15, 60, 300]

    /// The File Provider extension being registered with PlugInKit: the other half of what
    /// launching the app is for, and what the launchd role checks on every agent start,
    /// that being the one path that always runs.
    ///
    /// LaunchServices keys its records on the bundle identifier, and a second record for
    /// the same identifier at another path stops the installed bundle's own record from
    /// being built. The other path is the DMG: the app is opened from `/Volumes/SSH
    /// Drive/SSH Drive.app` once, the volume is detached, the record stays, and after the
    /// next upgrade `lsd` answers every registration of the installed copy with
    /// `SecStaticCodeCreateWithPath(<private>) failed with error -67028`, `skipping
    /// registration of an incomplete bundle` and `Registration succeeded, but did not
    /// actually register anything new; returning existing bundle`. PlugInKit then knows no
    /// appex: `pluginkit -m` prints nothing, `doctor` fails "extension registered", and a
    /// domain cannot be added at all ("The application cannot be used right now"), while
    /// the agent itself is fine because launchd starts it directly (`MQ-081`, measured on
    /// 27.0, 2026-09-23).
    ///
    /// So the sweep comes first and the force second. `lsregister -u` on every record path
    /// that is not the installed bundle drops the records that are answering for us;
    /// `lsregister -f -R -trusted` then rebuilds ours, and that survives the next launch,
    /// which `pluginkit -a` does not (`MQ-061`).
    ///
    /// A pass that leaves the extension unregistered is repeated on
    /// `registrationRetryBackoffSeconds`, sweep and all, because the failure this repairs
    /// is not always about the records: right after a bundle is moved into place
    /// `lsregister` itself fails and recovers minutes later, and a `lsregister -dump` made
    /// in that window lists no record to sweep. A launch that finds PlugInKit already
    /// knowing the extension does none of it - no dump, no force, no wait.
    ///
    /// - Parameter backoff: the wait before each pass after the first. Empty means one
    ///   pass and no retry.
    /// - Returns: whether PlugInKit knows the extension by the time this returns.
    public static func ensureExtensionRegistered(
        inspector: any BundleInspecting, clock: any AgentClock,
        backoff: [Double] = registrationRetryBackoffSeconds
    ) async -> Bool {
        let identifier = SSHDriveIdentifiers.extensionBundleID
        if let line = inspector.plugInRegistration(bundleID: identifier) {
            Log.agent.notice("extension registered with PlugInKit: \(line, privacy: .public)")
            return true
        }
        Log.agent.error(
            "PlugInKit does not know \(identifier, privacy: .public) (MQ-081: a LaunchServices record for another copy of the app answers for the installed one, and a LaunchServices that has just had the bundle moved under it answers nothing at all) - sweeping the stale records and rebuilding ours"
        )
        let passes = backoff.count + 1
        for pass in 1 ... passes {
            if await sweepAndForce(
                inspector: inspector, clock: clock, identifier: identifier, pass: pass,
                of: passes)
            {
                return true
            }
            guard pass < passes else { break }
            let wait = backoff[pass - 1]
            Log.agent.notice(
                "retrying the sweep and the forced registration in \(wait, privacy: .public) s")
            await clock.sleep(seconds: wait)
        }
        Log.agent.error(
            "the extension is still unregistered after \(passes, privacy: .public) attempts; run `sshdrive doctor`"
        )
        return false
    }

    /// One pass: drop every record that is not ours, force our own registration, and wait
    /// `plugInRegistrationTimeoutSeconds` for PlugInKit to pick the appex up.
    private static func sweepAndForce(
        inspector: any BundleInspecting, clock: any AgentClock, identifier: String, pass: Int,
        of passes: Int
    ) async -> Bool {
        for path in staleRecordPaths(inspector: inspector) {
            let dropped = inspector.unregisterLaunchServicesRecord(atPath: path)
            Log.agent.notice(
                "lsregister -u \(path, privacy: .public): \(dropped ? "dropped" : "failed", privacy: .public)"
            )
        }
        guard inspector.forceLaunchServicesRegistration() else {
            Log.agent.error(
                "lsregister did not run (attempt \(pass, privacy: .public) of \(passes, privacy: .public)); the extension stays unregistered"
            )
            return false
        }
        let deadline = clock.uptime() + plugInRegistrationTimeoutSeconds
        while true {
            await clock.sleep(seconds: plugInRegistrationPollSeconds)
            if let line = inspector.plugInRegistration(bundleID: identifier) {
                Log.agent.notice(
                    "extension registered after lsregister: \(line, privacy: .public)")
                return true
            }
            if clock.uptime() >= deadline { break }
        }
        Log.agent.error(
            "the extension is still unregistered \(plugInRegistrationTimeoutSeconds, privacy: .public) s after lsregister (attempt \(pass, privacy: .public) of \(passes, privacy: .public))"
        )
        return false
    }

    /// Every LaunchServices record for the app identifier that is not the bundle this
    /// process runs from. Paths are compared standardized, because a record can carry the
    /// path with a trailing slash or a `.` component and still name the same bundle.
    /// `doctor` lists what this returns; the launch unregisters it.
    public static func staleRecordPaths(inspector: any BundleInspecting) -> [String] {
        let installed = URL(fileURLWithPath: inspector.bundleURL.path).standardizedFileURL.path
        return inspector.launchServicesRecordPaths(bundleID: SSHDriveIdentifiers.appBundleID)
            .filter { URL(fileURLWithPath: $0).standardizedFileURL.path != installed }
    }

    /// Polls `reachable` on the clock until it answers true or the timeout passes. The
    /// deadline is read from the clock rather than counted in turns, so a slow ping spends
    /// the same budget a fast one does.
    private static func waitUntilReachable(
        clock: any AgentClock, reachable: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = clock.uptime() + reachableTimeoutSeconds
        while true {
            if await reachable() { return true }
            if clock.uptime() >= deadline { return false }
            await clock.sleep(seconds: reachablePollSeconds)
        }
    }
}

/// Reading `lsregister -dump`, which is the only place LaunchServices will say what
/// records it holds for an identifier.
public enum LaunchServicesDump {

    /// The path of every record in `dump` whose `identifier:` is `identifier`, in the
    /// order the dump prints them and without duplicates.
    ///
    /// A record is a block of `key:` lines separated from the next by a line of dashes.
    /// `path:` opens one and the first `identifier:` after it belongs to the same record,
    /// which is the order every record is printed in, so the pairing holds whether or not
    /// the separator is there. A value can carry a trailing store id in parentheses
    /// (`path:  /Applications/SSH Drive.app (0x266c)`), which is not part of the path.
    public static func recordPaths(in dump: String, identifier: String) -> [String] {
        var paths: [String] = []
        var pending: String?
        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, line.allSatisfy({ $0 == "-" }) {
                pending = nil
            } else if let path = value(of: "path", in: line) {
                pending = path.isEmpty ? nil : path
            } else if let recorded = value(of: "identifier", in: line) {
                if let path = pending, recorded == identifier, !paths.contains(path) {
                    paths.append(path)
                }
                pending = nil
            }
        }
        return paths
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(")"), let marker = value.range(of: " (0x", options: .backwards) {
            value = String(value[value.startIndex..<marker.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
