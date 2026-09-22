import Foundation

/// launchd, `SMAppService` and LaunchServices, as a state machine
/// (docs/design/testing.md).
///
/// Three measured behaviours live here and nothing else does. Whether LaunchServices
/// *really* declines to register a quarantined bundle's plugins is a VM measurement; what
/// the model reproduces is what our code reasons about - the record, the window, the
/// throttle and the constraint.
///
/// `AgentRuntimeTestSupport`'s `FakeLoginItem` and `FakeLaunchd` are the same two quirks
/// seen from the agent's side, and the two must agree: `register()` is not self-repairing
/// (`MQ-062`), and `unregister()` returns before launchd has dropped the job (`MQ-063`).
public final class Launchd {
    private let clock: VirtualClock
    private let quirks: QuirkTable

    public init(clock: VirtualClock, quirks: QuirkTable) {
        self.clock = clock
        self.quirks = quirks
    }

    // MARK: The bundle on disk and LaunchServices

    /// A generation number for the bundle at the install path. Replacing the bundle bumps
    /// it, which is what makes a launchd record that names the old one stale.
    public private(set) var bundleGeneration = 0
    public private(set) var bundleIsQuarantined = false
    /// `MQ-061`: LaunchServices registers no plugin of a quarantined bundle that no person
    /// has launched, so `pluginkit -m` prints nothing and the appex does not exist as far
    /// as fileproviderd is concerned.
    public private(set) var providerPluginIsRegistered = false
    /// What `pluginkit -m` prints.
    public var pluginKitListing: [String] {
        providerPluginIsRegistered ? ["org.shirls.sshdrive.fileprovider"] : []
    }

    /// The cask's install step. `open -g` is what registers the plugin, and it is not an
    /// assessed launch.
    public func installBundle(quarantined: Bool) {
        bundleGeneration += 1
        bundleIsQuarantined = quarantined
        providerPluginIsRegistered = false
    }

    /// `xattr -dr com.apple.quarantine`, the durable half of the postflight.
    public func stripQuarantine() {
        bundleIsQuarantined = false
    }

    /// `open -g`. `MQ-061`: with the quarantine xattr still on the bundle this registers
    /// nothing on the version that was measured, and `pluginkit -a` followed by a launch
    /// wipes it again - only stripping the xattr first is durable.
    ///
    /// The 26.4 column of `MQ-061` deliberately holds the *other* value: a quarantined
    /// fresh-user install there had passed, and which half of that difference matters is
    /// not claimed. A scenario that runs on both versions therefore sees both answers,
    /// which is the point of the table.
    public func launchApp() {
        if bundleIsQuarantined, quirks.bool(.quarantineBlocksPluginRegistration) {
            providerPluginIsRegistered = false
        } else {
            providerPluginIsRegistered = true
        }
        // A launch is also what clears a stale login-item record that `unregister()` has
        // already dropped (`MQ-062`).
        if job == nil, registered {
            job = Job(bundleGeneration: bundleGeneration, constraintGeneration: bundleGeneration)
        }
        settleJob()
    }

    // MARK: The login item (`SMAppService`)

    struct Job {
        /// The bundle the record names.
        var bundleGeneration: Int
        /// The launch constraint the job carries, which is the previous bundle's when a
        /// `register()` landed inside the unregister window (`MQ-063`).
        var constraintGeneration: Int
        var spawnFailures = 0
        var isRunning = false
    }

    private var job: Job?
    private var registered = false
    /// How long launchd goes on holding a job `unregister()` has already returned from.
    /// Five seconds between the commands worked first time (`MQ-063`); the window itself
    /// was never measured, only bracketed, so the model takes the throttle interval as
    /// its length. confidence: bracketed, not measured.
    private var jobDroppedAt: Double?

    /// What `SMAppService.status` answers.
    public var loginItemStatus: String { registered ? "enabled" : "not registered" }

    /// `launchctl print`. `MQ-063`: it is still true for a while after `unregister()` has
    /// returned, and that gap is the whole scenario.
    public var serviceIsLoaded: Bool {
        if let dropped = jobDroppedAt {
            return clock.now() < dropped
        }
        return job != nil
    }

    /// Whether the job spawns and dies on a 10 s throttle for ever - which is what both
    /// `MQ-062` and `MQ-063` leave behind, by two different routes.
    public var isSpawningAndDying: Bool {
        guard let job else { return false }
        return job.bundleGeneration != bundleGeneration
            || job.constraintGeneration != bundleGeneration
    }

    public var spawnFailures: Int { job?.spawnFailures ?? 0 }
    public var agentIsRunning: Bool { job?.isRunning ?? false }

    /// `SMAppService.register()`.
    ///
    /// `MQ-062`: it **does not repair** a registration whose bundle was deleted and
    /// replaced. It returns success, `status` keeps saying `enabled`, and every spawn
    /// fails. `MQ-063`: called inside the window `unregister()` left open, it re-creates
    /// the job carrying the **previous bundle's launch constraint**, and every spawn dies
    /// `EXC_CRASH (SIGKILL (Code Signature Invalid))` on a 10 s retry, for ever.
    public func register() {
        registered = true
        if job != nil {
            // Idempotent and not self-repairing: the stale record stays exactly as it is.
            settleJob()
            return
        }
        if serviceIsLoaded {
            // The job launchd has not dropped yet is re-used, constraint and all.
            job = Job(bundleGeneration: bundleGeneration, constraintGeneration: previousConstraint)
            jobDroppedAt = nil
        } else {
            job = Job(bundleGeneration: bundleGeneration, constraintGeneration: bundleGeneration)
            jobDroppedAt = nil
        }
        settleJob()
    }

    /// The constraint the job that is on its way out was carrying.
    private var previousConstraint = 0

    /// `SMAppService.unregister()`. It returns - and `status` says `notRegistered` -
    /// **before** launchd has dropped the job (`MQ-063`).
    public func unregister() {
        registered = false
        previousConstraint = job?.constraintGeneration ?? bundleGeneration
        jobDroppedAt = clock.now() + quirks.duration(.unregisterReturnsBeforeLaunchdDrops)
        job?.isRunning = false
        job = nil
    }

    /// Replacing the bundle under a live registration - what an upgrade does.
    public func replaceBundle() {
        bundleGeneration += 1
        providerPluginIsRegistered = false
        job?.isRunning = false
        settleJob()
    }

    /// One turn of launchd's own loop: it spawns the job, and the job lives or dies.
    private func settleJob() {
        guard var job else { return }
        if job.bundleGeneration != bundleGeneration || job.constraintGeneration != bundleGeneration {
            job.isRunning = false
            job.spawnFailures += 1
            self.job = job
            // The 10 s throttle, for ever. Nothing in the model ever stops it but an
            // `unregister()`.
            clock.schedule(after: quirks.duration(.unregisterReturnsBeforeLaunchdDrops)) {
                [weak self] in self?.settleJob()
            }
            return
        }
        job.isRunning = true
        self.job = job
    }

    /// The role the CLI's `unregister` step plays: poll `launchctl print` until the
    /// service is gone rather than trusting `SMAppService.status` (`MQ-063`). It answers
    /// how long it waited, and gives up at 30 s the way the shipping one does.
    @discardableResult
    public func waitForServiceToBeDropped(limit: Double = 30) -> Double {
        let start = clock.now()
        while serviceIsLoaded, clock.now() - start < limit {
            clock.advance(0.5)
        }
        return clock.now() - start
    }
}
