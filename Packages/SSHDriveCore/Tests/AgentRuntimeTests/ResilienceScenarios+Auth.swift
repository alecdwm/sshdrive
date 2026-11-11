import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Foundation
import ServerModel
import Testing

/// The rows where the server is reachable and the connection is refused: authentication,
/// the key agent, the authentication deadline and the host key.
///
/// A refused key and a refused host key are retried on a slow timer whose first retry is
/// due five minutes after the refusal (+/-20 % jitter, like every interval the breaker
/// keeps) and which never waits more than thirty, and at most once early in each of its
/// intervals, on wake, a network-path change or a screen unlock that comes more than a
/// minute after the last attempt. A deadline stop on a location that depends on a key
/// agent keeps its presence-gated re-arm, so an unattended Mac never makes a security key
/// blink. A refused password is the one terminal case, and has its row in
/// `ConnectionResilienceScenarios`.
extension AgentScenarios.ResilienceScenarios {

    /// The attempts whose outcome contains `text`, oldest first.
    static func attempts(_ harness: ResilienceHarness, containing text: String)
        -> [FakeRemoteHost.Attempt]
    {
        harness.host.attempts.filter { $0.outcome.contains(text) }
    }

    /// The gaps between consecutive attempts, in server seconds.
    static func gaps(_ attempts: [FakeRemoteHost.Attempt]) -> [Double] {
        zip(attempts.dropFirst(), attempts).map { $0.serverAt - $1.serverAt }
    }

    // MARK: Authentication refused

    /// **R16** - the account's home is not mounted yet when the location reconnects, so
    /// the key is refused once (`Permission denied (publickey)`); the next attempt works.
    /// The slow timer's first retry is due five minutes (+/-20 %) after the refusal.
    @Test func r16ARefusedKeyIsRetriedOnTheSlowTimer() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.failAuthentication(times: 1)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: Self.authQuiet)
            let refused = Self.attempts(harness, containing: "Permission denied")
            #expect(refused.count == 1, "\(refused.map(\.outcome))")
            await Self.expectConverged(harness)
        }
    }

    /// **R16** - refused at the reconnect, and a path change half a minute later is
    /// merged into that attempt. One more a minute after it is the interval's early
    /// attempt, and is refused too; a third change in the same interval makes no attempt
    /// at all. The slow timer, which the early attempt did not move, brings it back.
    @Test func r16ARefusedKeyIsRetriedOnAPathChange() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.failAuthentication(times: 2)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 30)
            try await harness.setNetworkPath(false)
            try await harness.run(for: 2)
            try await harness.setNetworkPath(true)
            try await harness.run(for: 5)
            var refused = Self.attempts(harness, containing: "Permission denied")
            #expect(refused.count == 1, "within a minute of the refusal: \(refused.map(\.outcome))")
            try await harness.run(for: 30)
            try await harness.setNetworkPath(false)
            try await harness.run(for: 2)
            try await harness.setNetworkPath(true)
            try await harness.run(for: 30)
            refused = Self.attempts(harness, containing: "Permission denied")
            #expect(refused.count == 2, "\(refused.map(\.outcome))")
            let attempts = harness.host.attempts.count
            try await harness.setNetworkPath(false)
            try await harness.run(for: 2)
            try await harness.setNetworkPath(true)
            try await harness.run(for: 30)
            #expect(harness.host.attempts.count == attempts, "a second early attempt in one interval")
            try await harness.run(for: Self.authQuiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R16** - refused for two attempts with nothing else happening: the slow timer
    /// alone brings it back. Its first retry is due five minutes (+/-20 %) after the
    /// refusal and it never waits more than thirty, and it is slow: no two refused
    /// attempts less than a minute apart.
    @Test func r16TwoRefusalsRecoverOnTheSlowTimerAlone() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.failAuthentication(times: 2)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 5 * 60 + 30 * 60 + Self.quiet)
            let refused = Self.attempts(harness, containing: "Permission denied")
            #expect(refused.count <= 2, "\(refused.map(\.outcome))")
            #expect(
                Self.gaps(refused).allSatisfy { $0 >= 60 && $0 <= 5 * 60 * 1.2 + 5 },
                "refused attempts \(Self.gaps(refused)) s apart")
            await Self.expectConverged(harness)
        }
    }

    // MARK: The key agent and the authentication deadline

    /// **R17** - a location that depends on a key agent wakes with the screen locked and
    /// the agent not unlocked yet. Its first attempt finds the key agent not ready, and
    /// from then on it makes none while nobody is there; once the user unlocks the screen
    /// it connects, retrying past the key agent's slow start.
    @Test func r17AKeyAgentLocationWaitsForTheUser() async throws {
        await Self.scenario(agentDependent: true) { harness in
            try await harness.run(for: 10)
            try await harness.sleepMac(willSleep: true)
            harness.base.presence.set(idleSeconds: 3600, screenLocked: true)
            Self.changeTheServer(harness)
            harness.host.enqueueConnectOutcomes([.keyAgentNotReady, .keyAgentNotReady])
            let slept = harness.host.serverNow
            harness.passTimeAsleep(3600)
            try await harness.wakeMac()
            try await harness.run(for: 300)
            let unattended = harness.host.attempts.filter { $0.serverAt >= slept }
            #expect(
                unattended.map(\.outcome) == ["key agent not ready"],
                "attempts with the screen locked: \(unattended.map(\.outcome))")
            harness.base.presence.setPresent()
            let screen = harness.base.screenLock
            try await harness.perform("the screen unlock") { await screen.unlock() }
            try await harness.run(for: Self.authQuiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R17**, the other side - a location that depends on a key agent whose keys are
    /// loaded needs nobody at the Mac. The screen is locked overnight, the server restarts,
    /// and the location reconnects on its own as soon as `sshd` is back.
    @Test func r17AKeyAgentLocationWithItsKeysLoadedReconnectsWhileLocked() async throws {
        await Self.scenario(agentDependent: true) { harness in
            try await harness.run(for: 10)
            harness.base.presence.set(idleSeconds: 3600, screenLocked: true)
            harness.host.sshd = .refusing
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 120)
            harness.host.sshd = .running
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R17** - a location that depends on a key agent hits the 60 s authentication
    /// deadline (a security key waiting for a touch) while the user is at the Mac, and the
    /// user walks away. Nothing is attempted while they are gone; the screen unlock
    /// re-arms one attempt, which connects.
    @Test func r17ADeadlineStopWaitsForThePresenceGatedReArm() async throws {
        await Self.scenario(agentDependent: true) { harness in
            try await harness.run(for: 10)
            harness.base.presence.setPresent()
            harness.host.enqueueConnectOutcomes([.authenticationDeadline])
            harness.host.severConnections()
            let stopped = try await harness.run(
                until: { await harness.gateReport()["stopped"] as? Bool == true }, within: 300)
            #expect(stopped, "the deadline never stopped the breaker")
            harness.base.presence.set(idleSeconds: 3600, screenLocked: true)
            Self.changeTheServer(harness)
            let away = harness.host.serverNow
            try await Self.idle(harness, for: 40 * 60)
            let unattended = harness.host.attempts.filter { $0.serverAt >= away }
            #expect(unattended.isEmpty, "attempts with nobody at the Mac: \(unattended.map(\.outcome))")
            harness.base.presence.setPresent()
            let screen = harness.base.screenLock
            try await harness.perform("the screen unlock") { await screen.unlock() }
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// The authentication deadline on a location that does **not** depend on a key agent:
    /// a server that took more than 60 s to authenticate once. It is retried on the slow
    /// timer like any other authentication failure.
    @Test func aDeadlineStopWithoutAKeyAgentIsRetriedOnTheSlowTimer() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.enqueueConnectOutcomes([.authenticationDeadline])
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 60 + Self.authQuiet)
            await Self.expectConverged(harness)
        }
    }

    // MARK: The host key

    /// **R18** - the Mac joins a network where the server's name answers with a different
    /// host key (a captive portal, a hotel's DNS), stays there twenty minutes, and comes
    /// home. While the key is wrong the agent retries only on the slow cadence; back home,
    /// the path change brings it back.
    @Test func r18AWrongHostKeyOnAForeignNetwork() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            try await harness.setNetworkPath(false)
            harness.host.failHostKey(true)
            try await harness.setNetworkPath(true)
            Self.changeTheServer(harness)
            let foreign = harness.host.serverNow
            try await Self.idle(harness, for: 20 * 60)
            let refused = harness.host.attempts.filter {
                $0.serverAt >= foreign && $0.outcome.contains("Host key verification failed")
            }
            #expect(!refused.isEmpty, "the wrong key was never met")
            #expect(
                Self.gaps(refused).allSatisfy { $0 >= 60 },
                "refused attempts \(Self.gaps(refused)) s apart")
            harness.host.failHostKey(false)
            try await harness.setNetworkPath(false)
            try await harness.run(for: 2)
            try await harness.setNetworkPath(true)
            try await harness.run(for: Self.quiet)
            await Self.expectConverged(harness)
        }
    }

    /// **R18** - the host key is wrong for two minutes (the server's admin restored a
    /// backup with old keys, then put the right ones back) with no network change at all:
    /// the slow timer brings it back.
    @Test func r18AWrongHostKeyFixedOnTheServer() async throws {
        await Self.scenario { harness in
            try await harness.run(for: 10)
            harness.host.failHostKey(true)
            harness.host.severConnections()
            Self.changeTheServer(harness)
            try await harness.run(for: 120)
            harness.host.failHostKey(false)
            try await harness.run(for: Self.authQuiet)
            await Self.expectConverged(harness)
        }
    }
}
