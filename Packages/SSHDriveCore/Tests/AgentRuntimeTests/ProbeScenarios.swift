import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Testing

/// Suite K's channel-budget half on the agent's side (`docs/design/testing.md`
/// section 5): what a refused channel is evidence of, and what is done with the cache when
/// a connection dies.
extension AgentScenarios {

    @Suite struct ProbeScenarios {

        /// **K13** - a dying connection records no budget.
        ///
        /// The probe (docs/design/ssh.md) opens channels until one is refused and turns the count
        /// into the location's whole channel budget, cached in `capabilities.json` where "an
        /// explicit re-probe is its only invalidation". That is sound only while a channel that
        /// did not open means the *server* said no. Measured 2026-09-08: after `ssh` was killed
        /// under a running agent the location came up reporting "MaxSessions 1 … SFTP-only",
        /// with no helper and no shell, against a healthy `deb` - and stayed that way across
        /// every restart, because nothing re-probes.
        @Test func k13ADyingConnectionRecordsNoBudget() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")

            // A master that has gone is `connectionDied` whatever it printed on the way out.
            #expect(
                ChannelProbeVerdict.classify(
                    diagnostics: "mux_client_request_session: session request failed",
                    masterIsRunning: false) == .connectionDied)
            for marker in ["broken pipe", "Control socket connect(/tmp/x): Connection refused",
                           "mux_client_hello_exchange: write packet: Broken pipe"] {
                #expect(
                    ChannelProbeVerdict.classify(diagnostics: marker, masterIsRunning: true)
                        == .connectionDied,
                    "ssh's own words for a master that went: \(marker)")
            }

            // A refusal `ssh` actually printed, on a master that is still running, is a fact
            // about the server and is recorded.
            #expect(
                ChannelProbeVerdict.classify(
                    diagnostics: "mux_client_request_session: session request failed",
                    masterIsRunning: true) == .sessionRefused)
            // And an sshd whose wording we have never seen still produces a budget, or the
            // location would retry for ever instead of settling at the tier it can run.
            #expect(
                ChannelProbeVerdict.classify(diagnostics: "channel 2: open failed", masterIsRunning: true)
                    == .sessionRefused)

            // Nothing was probed, so nothing is cached: the connect attempt fails and
            // docs/design/offline.md's breaker tries again.
            #expect(CapabilityCache.channelBudget(locationID: location.id) == nil)
            CapabilityCache.store(.forConcurrentChannels(2), locationID: location.id)
            #expect(CapabilityCache.channelBudget(locationID: location.id)?.concurrentChannels == 2)
        }

        /// **K14** - an abrupt loss makes the cached budget suspect.
        ///
        /// docs/design/ssh.md's cache invalidates only on an explicit re-probe, which assumes
        /// the only way to get a wrong answer is a server that changes its mind - so a location
        /// that probed in a bad moment would otherwise be stuck at that answer for the life of
        /// the install. Every abrupt loss of a connection that was up - a master that died, two
        /// consecutive deadline misses, a path that went away, the will-sleep drop - marks the
        /// cached budget suspect, and the next connect probes again. Two extra channel opens is
        /// the whole cost, and the values stay in the file so an offline `status` still prints
        /// something.
        @Test func k14AnAbruptLossMakesTheCachedBudgetSuspect() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")

            // A hand-poisoned "MaxSessions 1", exactly as the field failure recorded it.
            CapabilityCache.store(.forConcurrentChannels(1), locationID: location.id)
            #expect(CapabilityCache.channelBudget(locationID: location.id)?.concurrentChannels == 1)

            _ = try await harness.manager.runtime(for: location)
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            await gate.drop(reason: "the master was killed")
            await harness.settle { harness.launcher.attempts > 1 }

            #expect(
                CapabilityCache.channelBudget(locationID: location.id) == nil,
                "K14: the cache is not believed after an abrupt loss")
            let stored = CapabilityCache.read(locationID: location.id)["channels"] as? [String: Any]
            #expect(
                stored?["concurrentChannels"] as? Int == 1,
                "K14: the values stay in the file, so an offline status still has something to print")
            #expect(stored?["suspect"] as? Bool == true)

            // And the will-sleep drop does it too, which is the other abrupt loss.
            CapabilityCache.store(.forConcurrentChannels(1), locationID: location.id)
            await gate.willSleep()
            #expect(CapabilityCache.channelBudget(locationID: location.id) == nil)
            await harness.manager.dropRuntime(locationID: location.id)
        }
    }
}
