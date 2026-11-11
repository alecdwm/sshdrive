import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Foundation
import ServerModel
import Testing

/// The rows about what happens on one connection: the channel budget, the server probe,
/// the helper's deployment and stream, and the sweep.
extension AgentScenarios.ResilienceScenarios {

    // MARK: The channel budget

    /// **R9** - other sessions hold the server's `MaxSessions` while the reconnect's
    /// channel probe runs, so the third channel is refused and the connection runs at a
    /// budget of two (no helper). The sessions are freed, and the next reconnect - a
    /// network blink a minute later - probes again and finds the true budget.
    @Test func r9AFullServerDuringTheChannelProbeIsReprobedOnTheNextConnect() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.extraSessionsHeld = 1
            harness.host.severConnections()
            try await Self.runUntilReconnected(harness, within: 180)
            try await harness.run(for: 10)
            harness.host.extraSessionsHeld = 0
            Self.changeTheServer(harness)
            try await harness.run(for: 60)
            harness.host.severConnections()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R9** with no reconnect after the sessions are freed: the connection that measured
    /// two channels stays up for half an hour. The location is expected back at the helper
    /// tier within that half hour, without waiting for a network blink to re-probe.
    @Test func r9AFullServerDuringTheChannelProbeOnALongLivedConnection() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.extraSessionsHeld = 1
            harness.host.severConnections()
            try await Self.runUntilReconnected(harness, within: 180)
            try await harness.run(for: 10)
            harness.host.extraSessionsHeld = 0
            Self.changeTheServer(harness)
            try await harness.run(for: Self.verdictQuiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R14** - the channel probe's third channel opens and its SFTP handshake never
    /// answers. The connection may run on two channels, but nothing about that moment may
    /// be cached; the next connect probes again and finds three.
    @Test func r14AStalledThirdProbeChannelIsNotCached() async throws {
        await Self.stalledProbeChannel(ordinal: 3)
    }

    /// **R14** with the second channel - the bulk channel - stalling instead.
    @Test func r14AStalledSecondProbeChannelIsNotCached() async throws {
        await Self.stalledProbeChannel(ordinal: 2)
    }

    static func stalledProbeChannel(ordinal: Int) async {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.stalledSFTPChannelOrdinals = [ordinal]
            harness.host.severConnections()
            try await Self.runUntilReconnected(harness, within: 180)
            try await harness.run(for: 5)
            let cached = CapabilityCache.channelBudget(locationID: harness.location.id)
            #expect(
                cached == nil || cached == .unrestricted,
                "a stalled probe channel was cached as a budget of \(cached?.concurrentChannels ?? -1)")
            harness.host.stalledSFTPChannelOrdinals = []
            Self.changeTheServer(harness)
            try await harness.run(for: 30)
            harness.host.severConnections()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// A server whose `MaxSessions` is exactly three: the metadata channel, the bulk
    /// channel and the helper fill it, so the reconnect's full sweep (and the 30-minute
    /// insurance sweep) is refused a session while the helper runs. A sweep refused a
    /// channel must not cost the helper tier.
    @Test func aServerAtMaxSessionsThreeKeepsTheHelperThroughAReconnect() async throws {
        await Self.scenario(profile: .debian.with(maxSessions: 3)) { harness in
            try await harness.run(for: 10)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: The server probe

    /// **R13** - the reconnect's server probe (`id`, `uname`, the cache directory) opens
    /// and never answers, so it misses its 25 s deadline. A probe that did not answer is
    /// not "no shell": nothing is cached from it, it is retried on the live connection,
    /// and the ladder climbs back.
    @Test func r13AStalledServerProbeIsRetriedNotCached() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.stallScript(.probe, count: 1)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await Self.runUntilReconnected(harness, within: 180)
            try await harness.run(for: 30)
            let cached = CapabilityCache.probe(locationID: harness.location.id)?.probe
            #expect(
                cached?.hasShellAccess == true,
                "capabilities.json says no shell access after a stalled probe: \(cached?.failure ?? "no probe")")
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// The reconnect's server probe is refused a session, SFTP works, and every exec
    /// channel is refused for the life of the connection. The probe in force is the last
    /// one the server answered, so the ladder offers the helper; a deployment whose exec
    /// channel cannot answer must not upload a binary it cannot verify, or it uploads,
    /// fails to verify, removes and uploads again every minute for as long as the
    /// connection stays up.
    @Test func aConnectionThatIsRefusedEveryExecChannelUploadsNoHelper() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            let uploads = harness.host.helperUploads
            harness.host.refuseExec(.sessionLimit)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            #expect(try await Self.runUntilReconnected(harness, within: 180))
            try await harness.run(for: 10 * 60)
            #expect(
                harness.host.helperUploads - uploads <= 1,
                "\(harness.host.helperUploads - uploads) helper uploads on a connection with no exec channel")
            harness.host.clearExecRefusal()
            // The probe and the budget are asked again on the live connection, by then
            // every ten minutes.
            try await harness.run(for: ReconnectSequence.recheckCapSeconds + Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: The helper

    /// **R10** - the helper's first walk of the root set takes 40 s (a large pinned tree)
    /// before it says `ready`. A slow `ready` is waited for, not read as a failure.
    @Test func r10ASlowReadyIsWaitedFor() async throws {
        await Self.slowReady(seconds: 40)
    }

    /// **R10** at 110 s, just inside the two minutes a `ready` is to be waited for.
    @Test func r10AVerySlowReadyIsWaitedFor() async throws {
        await Self.slowReady(seconds: 110)
    }

    static func slowReady(seconds: Double) async {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.helperReadyDelay = seconds
            harness.host.killHelpers()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R10** - a helper that starts and never says `ready`, for five minutes; then the
    /// server is fine again. A `ready` that never comes is transient.
    @Test func r10AHelperThatNeverSaysReadyIsTransient() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.helperNeverReady = true
            harness.host.killHelpers()
            Self.changeTheServer(harness)
            try await harness.run(for: 300)
            harness.host.helperNeverReady = false
            // A `ready` may be waited for up to two minutes, then the ladder's hold of
            // up to a minute, then a fresh start: one quiet period is not enough.
            try await harness.run(for: Self.quiet + 60)
            await Self.expectConverged(harness)
        }
    }

    /// **R11** - the helper is killed on the server while the connection stays up.
    @Test func r11AKilledHelperIsRestarted() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.killHelpers()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// The helper stops producing anything - no events, no heartbeat - while its wrapper
    /// and the connection stay up: a helper stuck on a hung filesystem. A stream silent
    /// for 60 s, its own 15 s heartbeat included, is dead and is replaced.
    @Test func aSilentHelperIsReplaced() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.freezeHelpers()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R12** - the connection drops in the middle of the helper's upload (after a
    /// reboot emptied `~/.cache`), leaving a temp file in the cache directory.
    @Test func r12ADropMidHelperUpload() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.wipeHelperCache()
            harness.host.sever(when: .treeChange(pathContaining: "/.cache/sshdrive/.sshdrive-upload-"))
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R26** - the server's disk is full when the helper has to be uploaded again;
    /// two minutes later space is freed.
    @Test func r26ADiskFullDuringTheHelperUpload() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.wipeHelperCache()
            harness.host.setDiskFull(true)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 120)
            harness.host.setDiskFull(false)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: The sweep

    /// **R15** - the reconnect's full sweep hangs in `find` (an NFS mount under the root
    /// stopped answering) and the filesystem comes back a minute later, so the stuck
    /// `find` completes.
    @Test func r15AHungSweepThatCompletes() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.stallScript(.sweep, count: 1)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            let opened = try await Self.runUntilOpen(.sweep, harness, within: 180)
            #expect(opened, "the reconnect ran no sweep")
            try await harness.run(for: 60)
            harness.host.resumeStalledScripts()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R15** - the hung sweep never completes and runs into its own deadline (900 s for a
    /// full sweep). A sweep timeout is transient and never costs the helper tier, and the
    /// helper keeps delivering while the sweep is stuck.
    @Test func r15AHungSweepThatTimesOut() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.stallScript(.sweep, count: 1)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 16 * 60)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: Permanent verdicts

    /// A genuine server fact that stops being true: the cache directory is on a `noexec`
    /// mount when the location reconnects, and the admin remounts it `exec` a minute
    /// later. The verdict is permanent for the connection it was observed on, and is
    /// retried at most every 30 minutes on a long-lived connection.
    @Test func aPermanentVerdictIsRetriedOnALongLivedConnection() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.cacheDirectoryState = .noexec
            harness.host.severConnections()
            try await Self.runUntilReconnected(harness, within: 180)
            try await harness.run(for: 60)
            let tier = await harness.detectorStatus()["tier"] as? String
            #expect(tier == "sweep", "a noexec cache directory should hold the location at sweep, not \(tier ?? "?")")
            harness.host.cacheDirectoryState = .exec
            Self.changeTheServer(harness)
            try await harness.run(for: Self.verdictQuiet)
            await Self.expectConverged(harness)
        }
    }

    /// The same verdict, and the next connection: a permanent verdict lasts only for the
    /// connection it was observed on.
    @Test func aPermanentVerdictEndsWithItsConnection() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.cacheDirectoryState = .noexec
            harness.host.severConnections()
            try await Self.runUntilReconnected(harness, within: 180)
            try await harness.run(for: 60)
            harness.host.cacheDirectoryState = .exec
            Self.changeTheServer(harness)
            harness.host.severConnections()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }
}
