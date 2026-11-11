import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Foundation
import ServerModel
import Testing

/// The rows where the trouble is the order things happen in: an agent restart inside an
/// outage, a flapping network, the connection going away during the reconnect sequence,
/// the Mac going to sleep in the middle of a sweep, a deployment or a `ready`, clocks that
/// disagree, and a root that is not there yet.
extension AgentScenarios.ResilienceScenarios {

    // MARK: The agent restarts

    /// **R19** - the agent is restarted (`sshdrive agent restart`, or an upgrade) in the
    /// middle of an outage; the outage ends a minute later.
    @Test func r19AnAgentRestartMidOutage() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.setLink(.unreachable)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 60)
            try await harness.restartAgent()
            try await harness.run(for: 60)
            harness.host.setLink(.up)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// The agent is restarted on a healthy connection.
    @Test func anAgentRestartOnAHealthyServer() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            try await harness.restartAgent()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: Flapping

    /// **R20** - the Wi-Fi flaps: three seconds up, three seconds down, twenty times, with
    /// the path following it. Each path that comes back is owed one attempt, and nothing
    /// more: the busiest minute of the flapping holds no more attempts than path returns
    /// plus one, and the quiet period after it the ordinary limit.
    @Test func r20AFlappingNetworkPath() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            let flapStart = harness.host.serverNow
            for round in 0 ..< 20 {
                harness.host.setLink(.unreachable)
                try await harness.setNetworkPath(false)
                try await harness.run(for: 3)
                harness.host.setLink(.up)
                try await harness.setNetworkPath(true)
                try await harness.run(for: 3)
                if round == 10 { Self.changeTheServer(harness) }
            }
            let settled = harness.host.serverNow
            let during = harness.host.attempts.filter { $0.serverAt >= flapStart && $0.serverAt < settled }
            let (busiest, _) = ResilienceHarness.busiestMinute(during)
            // Ten path returns in any minute of a 3 s / 3 s flap.
            #expect(busiest <= 11, "\(busiest) connect attempts in one minute of flapping, with ten path returns")
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(
                harness, effort: ResilienceHarness.Effort(since: settled))
        }
    }

    /// The link flaps with no path change at all: the live connection stalls and resumes
    /// inside `ServerAliveInterval`, twenty times.
    @Test func aFlappingLinkWithNoPathChange() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            for round in 0 ..< 20 {
                harness.host.setLink(.unreachable)
                try await harness.run(for: 3)
                harness.host.setLink(.up)
                try await harness.run(for: 3)
                if round == 10 { Self.changeTheServer(harness) }
            }
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: Connect hangs

    /// **R21** - TCP is accepted and the SSH banner never arrives, for two minutes: every
    /// connect waits out `ConnectTimeout`.
    @Test func r21ABannerThatNeverArrives() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.sshd = .bannerHang
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 120)
            harness.host.sshd = .running
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: The connection goes during the reconnect sequence

    /// **R22** - the connection drops while the reconnect's server probe is running, and
    /// the next connect is clean.
    @Test func r22ADropDuringTheServerProbe() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.sever(when: .scriptOpened(.probe))
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R22** - the connection drops while `LocationRuntime.applyConnection` is running
    /// (its `statvfs` of the root), after the master, the channels and the probe were
    /// all fine.
    @Test func r22ADropDuringApplyConnection() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.sever(when: .sftpExtended(name: "statvfs@openssh.com"))
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R22** - the connection drops while the helper's deployment is interrogating the
    /// binary on the server.
    @Test func r22ADropDuringTheHelperDeployment() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.sever(when: .scriptOpened(.interrogate))
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: Sleep in the middle of something

    /// The Mac goes to sleep while the reconnect's full sweep is stuck in `find`, sleeps
    /// an hour, and wakes.
    @Test func aSleepThatLandsMidSweep() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.stallScript(.sweep, count: 1)
            harness.host.severConnections()
            let opened = try await Self.runUntilOpen(.sweep, harness, within: 180)
            #expect(opened, "the reconnect ran no sweep")
            try await harness.sleepMac(willSleep: true)
            Self.changeTheServer(harness)
            harness.passTimeAsleep(3600)
            harness.host.clearScriptStalls()
            try await harness.wakeMac()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// The Mac goes to sleep while the helper's deployment is interrogating the binary.
    @Test func aSleepThatLandsMidDeployment() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.stallScript(.interrogate, count: 1)
            harness.host.severConnections()
            let opened = try await Self.runUntilOpen(.interrogate, harness, within: 180)
            #expect(opened, "the reconnect ran no deployment")
            try await harness.sleepMac(willSleep: true)
            Self.changeTheServer(harness)
            harness.passTimeAsleep(3600)
            harness.host.clearScriptStalls()
            try await harness.wakeMac()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// The Mac goes to sleep while the helper is walking its roots before `ready`.
    @Test func aSleepThatLandsMidReady() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.helperReadyDelay = 15
            harness.host.severConnections()
            let opened = try await harness.run(
                until: {
                    harness.host.liveMasters.contains { $0.openExecKinds.contains(.helper) }
                        && harness.host.runningHelperCount == 0
                },
                within: 180)
            #expect(opened, "the reconnect started no helper")
            try await harness.sleepMac(willSleep: true)
            harness.host.helperReadyDelay = 0.5
            Self.changeTheServer(harness)
            harness.passTimeAsleep(3600)
            try await harness.wakeMac()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: Clocks

    /// **R23** - the Mac's wall clock jumps an hour forward after a wake (an NTP
    /// correction); the server's does not move.
    @Test func r23TheMacsClockJumpsForwardAfterAWake() async throws {
        await Self.clockJump(by: 3600)
    }

    /// **R23** - and an hour back.
    @Test func r23TheMacsClockJumpsBackAfterAWake() async throws {
        await Self.clockJump(by: -3600)
    }

    static func clockJump(by seconds: Double) async {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            try await harness.sleepMac(willSleep: true)
            Self.changeTheServer(harness)
            harness.passTimeAsleep(600)
            harness.jumpMacWallClock(by: seconds)
            try await harness.wakeMac()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// A server whose clock is five hours behind the Mac's, through a reconnect.
    @Test func aServerFiveHoursBehind() async throws {
        await Self.serverClockOff(by: -5 * 3600)
    }

    /// A server whose clock is five hours ahead of the Mac's, through a reconnect.
    @Test func aServerFiveHoursAhead() async throws {
        await Self.serverClockOff(by: 5 * 3600)
    }

    static func serverClockOff(by seconds: Double) async {
        await Self.scenario(prepare: { $0.host.serverClockOffset = seconds }) { harness in
            try await harness.run(for: 10)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            harness.host.writeFile("after-reconnect.txt", text: "written once converged\n")
            try await harness.run(for: 5)
            await Self.expectConverged(harness)
        }
    }

    // MARK: Long sleeps

    /// **R24** - twelve hours asleep while the server changes a lot: forty new files, an
    /// edit, a deletion and a rename in the watched root.
    @Test func r24ATwelveHourSleepWithManyChanges() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            try await harness.sleepMac(willSleep: true)
            Self.changeTheServer(harness)
            for index in 0 ..< 40 {
                harness.host.writeFile("batch-\(index).txt", text: "file \(index)\n")
            }
            harness.host.rename("README.txt", to: "README.md")
            harness.passTimeAsleep(12 * 3600)
            try await harness.wakeMac()
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: The root

    /// **R25** - the root is missing when the location reconnects (an autofs mount not
    /// there yet, a locked dataset), and appears a minute later.
    @Test func r25ARootMissingAtReconnect() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.hideRoot()
            harness.host.severConnections()
            try await harness.run(for: 60)
            harness.host.restoreRoot()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R25** - the root disappears under a live connection for a minute (the dataset is
    /// unmounted and remounted) and nothing else happens.
    @Test func r25ARootMissingUnderALiveConnection() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.hideRoot()
            try await harness.run(for: 60)
            harness.host.restoreRoot()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }
}
