import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import SFTP
import SSHProcess
import Testing

/// Suite F on the agent's side: the breaker, the reconnect sequence, the ladder's
/// climb-back and the will-sleep drop (`docs/testing-architecture.md` section 5).
///
/// Serialized because `Config.GroupContainer` is process-wide and each harness installs a
/// container of its own.
extension AgentScenarios {

    @Suite struct ReconnectScenarios {

        /// **F7** - the reconnect re-opens what the connection took with it, in
        /// `ReconnectSequence` order: after `applyConnection`, before the signals.
        ///
        /// The order is the part that was wrong. Before 2026-09-08 the recovery signalled
        /// first and left the helper's stream to the next poll cycle, which is up to ten
        /// minutes away and, on a location a runtime failure had dropped, never.
        @Test func f7ReconnectRunsTheSequenceInOrder() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            let runtime = try await harness.manager.runtime(for: location)
            let connected = await runtime.isConnected()
            #expect(connected)
            #expect(harness.launcher.attempts == 1)

            harness.replica.resetCalls()
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            await gate.drop(reason: "the master was killed")
            // The sequence's *last* step is the working-set signal, so waiting for that is
        // waiting for the whole of it.
        await harness.settle {
            harness.replica.signalledContainers.contains { $0.contains("WorkingSet") }
        }

            // The two signals, in `ReconnectSequence`'s order and only after a connection.
            let steps = ReconnectSequence.steps
            #expect(steps.firstIndex(of: .applyConnection)! < steps.firstIndex(of: .reopenHelperStream)!)
            #expect(steps.firstIndex(of: .reopenHelperStream)! < steps.firstIndex(of: .signalErrorResolved)!)
            #expect(steps.firstIndex(of: .signalErrorResolved)! < steps.firstIndex(of: .signalWorkingSet)!)

            let calls = harness.replica.calls
            let resolvedAt = try #require(
                calls.firstIndex { if case .signalErrorResolved = $0 { return true } else { return false } })
            let workingSetAt = try #require(
                calls.firstIndex {
                    if case let .signalEnumerator(_, container) = $0 {
                        return container.contains("WorkingSet")
                    }
                    return false
                })
            #expect(resolvedAt < workingSetAt, "F7: the flush cue comes before the working set")
            // The connection really was re-made rather than the old one being reused.
            #expect(harness.launcher.attempts == 2)
            #expect(harness.launcher.connections[0].shutdownCount == 1)
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **F8** - an outage is not a tier verdict.
        ///
        /// A tier-2 failure that says nothing about the server holds the tier for a bounded,
        /// doubling backoff and no longer. Section 6.4's permanent list - no shell, no exec
        /// channel, an unsupported arch, `noexec`, a hash mismatch after a redeploy - is about
        /// the server, and only those cost the location the tier for the session.
        @Test func f8ATransientHelperFailureIsHeldNotVerdicted() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", watchMode: .auto)
            let runtime = try await harness.manager.runtime(for: location)
            // The ladder's own clock is wall-clock, because `status` counts the hold down
            // against it; the cycles below are offsets from the same base.
            let t0 = Date().timeIntervalSince1970
            let detector = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: Self.helperCapable, environment: harness.environment,
                now: t0)
            #expect(await detector.currentTier() == .helper)

            // The connection this location has is one with no exec channel, so the deployment
            // meets a transport failure - the shape of a channel that died under it.
            _ = await detector.runCycle(now: t0)
            #expect(await detector.currentTier() == .sweep, "F8: dropped one tier")

            var status = await detector.status()
            let remaining = try #require(status["retryingHigherTierInSeconds"] as? Double)
            #expect(
                remaining <= ChangeDetectionLadder.firstRetrySeconds,
                "F8: held for 2 s, not for the session")
            let downgrades = try #require(status["downgrades"] as? [[String: Any]])
            #expect(downgrades.last?["permanence"] as? String == "transient")

            // The cycle after the hold expires climbs back, unprompted.
            _ = await detector.runCycle(now: t0 + 3)
            status = await detector.status()
            #expect(status["downgrades"] as? [[String: Any]] != nil)
            #expect(
                downgrades.allSatisfy { $0["permanence"] as? String == "transient" },
                "F8: it never becomes the session-long downgrade section 6.4 reserves for the server's own refusals")
            await detector.stop()
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **F9** - repeated down/up cycles converge: every round ends at tier 2, and the
        /// ladder's backoff does not compound across rounds.
        ///
        /// Four outages in a row with link between them. `noteConnected` is what clears the
        /// hold outright - the stream died with the link, the link is back, so the backoff
        /// starts again from the bottom rather than at four doublings.
        @Test func f9RepeatedOutagesConverge() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", watchMode: .auto)
            let runtime = try await harness.manager.runtime(for: location)
            let t0 = Date().timeIntervalSince1970
            let detector = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: Self.helperCapable, environment: harness.environment,
                now: t0)

            var now = t0
            for round in 1...4 {
                _ = await detector.runCycle(now: now)
                #expect(await detector.currentTier() == .sweep, "round \(round): the failure held it")
                await detector.connectionWentAway(reason: "the link went")
                now += 30
                await detector.connectionCameUp()
                // The reconnect climbs the tier back at once; the deployment then fails again
                // on the new connection, which is the hold this round is measured by.
                await harness.settle {
                    await detector.status()["retryingHigherTierInSeconds"] != nil
                }
                // The link came back, so the ladder's backoff starts again from the bottom.
                // Before 2026-09-08 four rounds compounded to 16 s and then to the cap, and a
                // location that had seen a few outages took a minute to come back each time.
                let status = await detector.status()
                let remaining = try #require(status["retryingHigherTierInSeconds"] as? Double)
                #expect(
                    remaining <= ChangeDetectionLadder.firstRetrySeconds,
                    "F9: round \(round)'s hold is the 2 s one, not a compounded one")
                #expect(remaining <= ChangeDetectionLadder.retryCapSeconds)
                now += 30
            }
            await detector.stop()
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **F6** - sleep drops every master, wake brings them back.
        ///
        /// At the will-sleep message the agent does not wait to find out whether the
        /// connection survived: it runs `-O exit` on every master, because a connection that
        /// slept through a network change is dead more often than not. No reconnect is
        /// scheduled from the drop - that would defeat the point - and the masters come back at
        /// `kIOMessageSystemHasPoweredOn`.
        @Test func f6SleepDropsAndWakeRestoresEveryMaster() async throws {
            let harness = try AgentHarness()
            let first = try await harness.addLocation(nickname: "nas")
            let second = try await harness.addLocation(nickname: "backups", host: "other")
            await harness.installSystemObservers()
            _ = try await harness.manager.runtime(for: first)
            _ = try await harness.manager.runtime(for: second)
            #expect(harness.launcher.attempts == 2)
            // The two timers a mounted location carries would otherwise make a transport
            // call of their own mid-scenario, and a call that meets a dropped gate
            // connects - which is right, and is not what this scenario is about
            // (sections 6.4, 6.6).
            for location in [first, second] {
                await harness.manager.detector(locationID: location.id)?.stop()
                await harness.manager.evictor(locationID: location.id)?.stop()
            }
            await harness.quiesceConnects()
            let beforeSleep = harness.launcher.connections
            let attemptsBeforeSleep = harness.launcher.attempts

            await harness.power.sleepNow()
            await harness.settle {
                harness.launcher.connections.allSatisfy { $0.shutdownCount == 1 }
            }
            #expect(
                beforeSleep.allSatisfy { $0.shutdownCount == 1 },
                "F6: both masters dropped by -O exit")
            #expect(
                harness.launcher.attempts == attemptsBeforeSleep, "F6: the drop does not connect")
            let firstGate = try #require(await harness.manager.gate(locationID: first.id))
            #expect(
                (await firstGate.report())["retryScheduled"] as? Bool == false,
                "F6: no reconnect is scheduled by the will-sleep drop - that would defeat it")
            let connectedAfterSleep = await firstGate.isConnected
            #expect(!connectedAfterSleep)

            await harness.power.wake()
            // An attempt *started* is not a master back up: the gate records the connection
            // when the attempt returns, which is what `status` and every later call read.
            await harness.settle { await firstGate.isConnected }
            #expect(
                harness.launcher.attempts == attemptsBeforeSleep + 2,
                "F6: one new master per location after wake")
            let connectedAfterWake = await firstGate.isConnected
            #expect(connectedAfterWake)
            await harness.manager.dropRuntime(locationID: first.id)
            await harness.manager.dropRuntime(locationID: second.id)
        }

        /// **F10** - the authentication deadline re-arms once per trigger.
        ///
        /// Section 4.2: a location stopped by the 60 s deadline is re-armed **for one attempt**
        /// when a human is demonstrably present, and each of the two triggers - the screen
        /// unlock and a File Provider request with the presence test passing - fires exactly
        /// once per stop. A request on its own is not evidence of a human: Spotlight, Quick
        /// Look and the working-set enumerator issue them on an unattended Mac all day.
        @Test func f10TheDeadlineRearmsOncePerTrigger() async throws {
            let harness = try AgentHarness()
            harness.launcher.fail(classification: .authenticationDeadline, stderr: "deadline")
            let location = try await harness.addLocation(nickname: "nas")
            await harness.installSystemObservers()
            _ = try? await harness.manager.runtime(for: location)
            await harness.settle()
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            let stopped = await gate.report()
            #expect(stopped["stopped"] as? Bool == true, "the deadline stops reconnection")
            let attemptsWhenStopped = harness.launcher.attempts

            #expect(stopped["rearmArmed"] as? Bool == true, "a deadline stop arms both triggers")

            // Nobody at the keyboard: the request trigger reads the presence test and refuses.
            harness.presence.set(idleSeconds: 3600, screenLocked: true)
            await gate.fileProviderRequestArrived()
            await harness.settle()
            #expect(harness.launcher.attempts == attemptsWhenStopped)
            #expect((await gate.report())["presenceEvaluations"] as? Int == 1)

            // And a second request inside the minute does not even read it: section 4.2's
            // "evaluated at most once a minute so the test itself costs nothing".
            await gate.fileProviderRequestArrived()
            await harness.settle()
            #expect((await gate.report())["presenceEvaluations"] as? Int == 1)
            #expect(harness.launcher.attempts == attemptsWhenStopped)

            // A minute later, with a human there, the request re-arms exactly one attempt.
            harness.clock.advance(61)
            harness.presence.setPresent()
            await gate.fileProviderRequestArrived()
            await harness.settle { harness.launcher.attempts == attemptsWhenStopped + 1 }
            #expect(
                harness.launcher.attempts == attemptsWhenStopped + 1,
                "F10: one attempt, re-armed by a request with the user present")

            // That attempt hit the deadline too, so the stop is fresh and both triggers are
            // armed again - which is why the unlock still works.
            await harness.settle {
                await (gate.report()["rearmRequestUsed"] as? Bool) == false
            }
            let afterRequest = await gate.report()
            #expect(afterRequest["rearmArmed"] as? Bool == true)
            #expect(afterRequest["rearmRequestUsed"] as? Bool == false)
            await harness.screenLock.unlock()
            await harness.settle { harness.launcher.attempts == attemptsWhenStopped + 2 }
            #expect(
                harness.launcher.attempts == attemptsWhenStopped + 2,
                "F10: the screen unlock is the other trigger, and needs no presence test")
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **F5** - a call waits for the attempt in flight.
        ///
        /// Section 6.3 rule 2, and the number it turns on: two reads three seconds apart
        /// during a 20 s connect both wait for the **one** attempt, and the wait is bounded
        /// by *that attempt's own remaining deadline* - the 60 s authentication deadline of
        /// section 4.2 measured from the spawn of `ssh`, which already contains the 15 s
        /// `ConnectTimeout` - never by 60 s from now and never by the two added together.
        ///
        /// Failing the second call fast instead was considered and rejected: the first
        /// enumeration after login or wake arrives during the connect, the system never
        /// retries an enumeration on its own (`MQ-001`, and `MQ-007` measured that it will
        /// hold one for the full 60 s and take the answer), so Finder would show the folder
        /// as unavailable until the user clicked again. A spinner for the length of one
        /// connect is the better of the two.
        ///
        /// Everything here is on `VirtualAgentClock`: the 20 s connect and the three
        /// seconds between the reads are model time and cost the suite nothing.
        @Test func f5TwoCallsWaitForTheOneAttemptInFlight() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            _ = try await harness.manager.runtime(for: location)
            await harness.manager.detector(locationID: location.id)?.stop()
            await harness.manager.evictor(locationID: location.id)?.stop()
            await harness.quiesceConnects()
            let gate = try #require(await harness.manager.gate(locationID: location.id))

            // A server that accepts the TCP connection and then takes its time: 20 s of
            // connect, which is section 6.3 rule 3's world with nothing else in it.
            await gate.setFault(
                unreachable: nil, hangMilliseconds: nil, connectHangMilliseconds: 20_000)
            await gate.drop(reason: "the master was killed", reconnect: false)
            let attemptsBefore = harness.launcher.attempts
            // The transport every call goes through, held directly: two calls on one
            // `LocationRuntime` would serialise on the actor and never meet the gate
            // together, which is not what section 6.3 is about.
            let transport = ReconnectingTransport(gate: gate, locationID: location.id)

            let gateAttemptsBefore = await gate.attempts
            async let firstRead = transport.readdir(.root)
            // The gate counts the attempt when it starts it; the launcher counts it when
            // the 20 s of connect are over, which is exactly the window under test.
            await harness.settle {
                await gate.attempts == gateAttemptsBefore + 1 && harness.clock.sleeperCount >= 1
            }
            #expect(await gate.attempts == gateAttemptsBefore + 1, "F5: the first call connects")
            #expect(
                harness.launcher.attempts == attemptsBefore,
                "F5: and it is still in the connect while the second call arrives")

            // Three seconds in, a second call arrives. It waits on the same attempt.
            harness.clock.advance(3)
            async let secondRead = transport.lstat(.root)
            await harness.settle { await gate.waitedCalls == 1 }

            // The attempt finishes. Both calls run.
            harness.clock.advance(17)
            let entries = try await firstRead
            let attributes = try await secondRead
            #expect(entries.isEmpty, "an empty root is still an answer, and both calls got one")
            #expect(attributes.type == .directory, "F5: the second call ran on the same connection")

            #expect(
                harness.launcher.attempts == attemptsBefore + 1,
                "F5: one attempt, not one per call")
            #expect(await gate.attempts == gateAttemptsBefore + 1)
            #expect(await gate.waitedCalls == 1, "F5: and the second call waited for it")
            let bound = try #require(await gate.lastWaitBoundSeconds)
            #expect(
                abs(bound - (CircuitBreaker.authenticationDeadlineSeconds - 3)) < 0.001,
                "F5: bounded by what is left of the attempt's own deadline - 57 s, not 60")
            #expect(
                bound < CircuitBreaker.authenticationDeadlineSeconds,
                "F5: a fresh 60 s from now would be the deadline plus the time already spent")
            let connected = await gate.isConnected
            #expect(connected)
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **F11** - the network path gate fails fast, and a returning path connects at once.
        ///
        /// Section 6.3 rule 1: `NWPathMonitor` says there is no path at all, so the call is
        /// `.serverUnreachable` immediately and **no `ssh` is spawned**. Waiting out a
        /// connect timeout instead is what freezes Finder, and it is the one case where the
        /// answer is free.
        ///
        /// Rule 2's other half is here too: "a path change ... resets the breaker". A
        /// location that was backing off when the Wi-Fi went does not owe that backoff to
        /// the network that just came back - waiting it out would mean a mount that
        /// reconnects up to a minute after the user can see they are online again. The
        /// backoff is a reconnect schedule (rule 5), not a punishment.
        ///
        /// The kill and the socket half of a dropped master are `K5`/`K6`; what this
        /// asserts is that the launcher was never asked while the path was down.
        @Test func f11NoNetworkPathFailsFastAndSpawnsNothing() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            await harness.installSystemObservers()
            _ = try await harness.manager.runtime(for: location)
            await harness.manager.detector(locationID: location.id)?.stop()
            await harness.manager.evictor(locationID: location.id)?.stop()
            await harness.quiesceConnects()
            let gate = try #require(await harness.manager.gate(locationID: location.id))

            // A failed attempt first, so the breaker is genuinely backing off when the path
            // goes: that is the state the returning path has to clear.
            harness.launcher.fail(classification: .transient, stderr: "no route to host")
            await gate.drop(reason: "the link went")
            await harness.settle { await (gate.report()["state"] as? String)?.hasPrefix("backing off") == true }
            #expect(await gate.report()["retryScheduled"] as? Bool == true)

            await harness.network.setAvailable(false)
            await harness.settle()
            let attemptsWhileDown = harness.launcher.attempts
            #expect(await gate.report()["hasNetworkPath"] as? Bool == false)

            let transport = ReconnectingTransport(gate: gate, locationID: location.id)
            let failFastBefore = await gate.failFastCalls
            let sleepersWhileDown = harness.clock.sleeperCount
            await #expect(throws: SFTPError.noConnection) { try await transport.readdir(.root) }
            #expect(
                await gate.failFastCalls == failFastBefore + 1,
                "F11: rule 1 answered it, without touching the network")
            #expect(
                harness.launcher.attempts == attemptsWhileDown,
                "F11: no `ssh` is spawned at all while there is no path")
            #expect(
                harness.clock.sleeperCount == sleepersWhileDown,
                "F11: and nothing new is waiting out a connect timeout")

            // Not even the reconnect schedule: an attempt on an interface that is down is
            // a spawn that can only fail.
            harness.clock.advance(300)
            await harness.settle()
            #expect(
                harness.launcher.attempts == attemptsWhileDown,
                "F11: five minutes of backoff expiries produce nothing while the path is gone")

            // The path comes back. The breaker connects at once - it does not sit out the
            // backoff it owed the failure before the outage.
            harness.launcher.succeed()
            await harness.network.setAvailable(true)
            await harness.settle { await gate.isConnected }
            #expect(
                harness.launcher.attempts == attemptsWhileDown + 1,
                "F11: one attempt, the moment the path returned")
            let connected = await gate.isConnected
            #expect(connected)

            // Bite-proof: the gate is the whole of rule 1. The same breaker, in the same
            // state, with the path flag left alone hands out a connect - which is a spawned
            // `ssh` on an interface that is down, and a call held for its timeout.
            var breaker = CircuitBreaker(jitter: { $0 })
            breaker.setNetworkPath(false)
            #expect(breaker.admit(now: 0) == .failFast(.noNetworkPath))
            var unguarded = CircuitBreaker(jitter: { $0 })
            #expect(unguarded.admit(now: 0) == .connect, "without rule 1 it would dial")
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// A server that can run the helper as far as the probe can tell: `auto` tries the
        /// tiers from the top, and the deployment is what refutes it.
        static let helperCapable = ChangeDetectionLadder.ServerCapabilities(
            hasExecChannel: true, hasFind: true, takesCmin: true, takesPrintf: true,
            helperAvailable: true, helperEnabledForLocation: true)
    }
}
