import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Logging
import SSHProcess
import SFTP
import ServerModel
import Testing

/// The connection side of the resilience suite: the gate, the breaker, the probes and the
/// reconnect sequence, driven through a fault on a `FakeRemoteHost` in virtual time
/// (docs/design/offline.md, docs/design/ssh.md, docs/design/secrets.md).
///
/// Each scenario asserts what the connection side owns - connected, the breaker not
/// stopped, the channel budget and the server probe in `capabilities.json` equal to the
/// server's, one live connection, bounded effort - rather than the whole of
/// `converged()`, whose tier and helper checks belong to change detection.
extension AgentScenarios {

    @Suite struct ConnectionResilienceScenarios {

        /// A harness that waits a little longer for the agent to go quiet before it moves
        /// the clock. These scenarios measure deadlines - the channel probe's 10 s
        /// handshake, the server probe's 25 s - and a step taken while a connect is still
        /// running on a loaded machine spends virtual time the connect never waited for.
        static func makeHarness() throws -> ResilienceHarness {
            let harness = try ResilienceHarness()
            harness.quietWindows = 4
            harness.quietWindowNanoseconds = 3_000_000
            return harness
        }

        // MARK: Reading the outcome

        static func isConnected(_ harness: ResilienceHarness) async -> Bool {
            await harness.gateReport()["connected"] as? Bool == true
        }

        /// The convergence checks the connection side answers for: C1, C5, C6, the
        /// live-connection count of C7, and C8.
        static func connectionViolations(
            _ harness: ResilienceHarness, effort: ResilienceHarness.Effort = .init()
        ) async -> [String] {
            await harness.converged(effort: effort).filter {
                $0.hasPrefix("C1:") || $0.hasPrefix("C5:") || $0.hasPrefix("C6:")
                    || $0.hasPrefix("C8:") || $0.hasPrefix("C7: the server holds")
            }
        }

        static func attempts(_ harness: ResilienceHarness, since index: Int) -> [FakeRemoteHost.Attempt] {
            Array(harness.host.attempts.dropFirst(index))
        }

        /// The probe a reconnect after a fault is held to: the server's own answer.
        static func expectShellProbe(_ harness: ResilienceHarness, _ what: String) async {
            let cached = CapabilityCache.probe(locationID: harness.location.id)?.probe
            #expect(cached?.hasShellAccess == true, "\(what): capabilities.json says \(cached?.failure ?? "nothing")")
            #expect(cached?.unanswered == false, "\(what): capabilities.json holds an answer")
            let runtime = try? await harness.currentRuntime()
            let applied = await runtime?.probeForSweep()
            #expect(applied?.hasShellAccess == true, "\(what): the runtime decides on \(applied?.failure ?? "nothing")")
        }

        // MARK: R4 - a master that dies with nothing asking

        /// **R4** on an idle location. Nothing calls the transport - no detector, no
        /// eviction pass, no Finder - so no request can be what finds the dead master. The
        /// gate's own watch does, within `masterWatchSeconds`, and the drop reconnects.
        @Test func r4AnIdleLocationReplacesAMasterThatDied() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let id = harness.location.id
                await harness.manager.detector(locationID: id)?.stop()
                await harness.manager.evictor(locationID: id)?.stop()
                try await harness.run(for: 5)
                let before = harness.host.attempts.count
                let killedAt = harness.clock.now()
                harness.host.severConnections()
                let back = try await harness.run(
                    until: {
                        await Self.isConnected(harness) && harness.host.liveMasters.count == 1
                            && harness.host.attempts.count > before
                    },
                    within: 60)
                #expect(back, "R4: the dead master was noticed and replaced without a request")
                let replacedAt = try #require(harness.host.attempts.last).at
                #expect(
                    replacedAt - killedAt <= ConnectionGate.masterWatchSeconds + 1,
                    "R4: the watch found it within one period")
                #expect(Self.attempts(harness, since: before).count == 1, "R4: one attempt, not a loop")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R5, R6 - sleep and wake

        /// **R5** - a sleep with the will-sleep message, and a wake onto a network that is
        /// not there yet: the path is reported down for ten seconds and the first two
        /// lookups after it fail. The path coming up connects at once, and the failures
        /// after it are the ordinary short backoff.
        @Test func r5AWakeOntoAPathThatComesUpLaterConnects() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                try await harness.sleepMac()
                // The Wi-Fi goes with the sleep, before the clock passes: every timer that
                // came due during the sleep goes off at the wake.
                try await harness.setNetworkPath(false)
                harness.host.failNameResolution(times: 2)
                let before = harness.host.attempts.count
                harness.passTimeAsleep(1800)
                try await harness.wakeMac()
                try await harness.run(for: 10)
                #expect(
                    Self.attempts(harness, since: before).isEmpty,
                    "R5: nothing is attempted while there is no path")
                try await harness.setNetworkPath(true)
                let upAt = harness.clock.now()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                #expect(back)
                let made = Self.attempts(harness, since: before)
                #expect(made.map(\.succeeded) == [false, false, true])
                #expect(
                    (made.last?.at ?? .infinity) - upAt < 15,
                    "R5: two failed lookups cost the short backoff")
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R5**, with the path never reported down: the wake's attempt and the next ones
        /// fail on a link that is not there for ten seconds, and the backoff brings the
        /// location back once it is.
        @Test func r5AWakeOntoADeadLinkConnectsOnTheBackoff() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                try await harness.sleepMac()
                harness.host.setLink(.unreachable)
                harness.host.failNameResolution(times: 2)
                harness.passTimeAsleep(1800)
                harness.host.after(10) { harness.host.setLink(.up) }
                try await harness.wakeMac()
                let wokeAt = harness.clock.now()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                #expect(back)
                let connectedAt = harness.host.attempts.last(where: \.succeeded)?.at ?? .infinity
                #expect(connectedAt - wokeAt < 30, "R5: the backoff, not a poll, brought it back")
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R5** - between the will-sleep message and the wake nothing connects. The
        /// helper's stream ends with the dropped master, and a stream ending on a gate that
        /// holds no connection is not a reason to call the transport: the gate dropped it
        /// on purpose and decides for itself when to reconnect.
        @Test func r5NothingConnectsBetweenWillSleepAndWake() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let before = harness.host.attempts.count
                try await harness.sleepMac()
                try await harness.run(for: 5)
                #expect(
                    Self.attempts(harness, since: before).isEmpty,
                    "R5: connected after the will-sleep drop: \(Self.attempts(harness, since: before).map(\.outcome))")
                #expect(harness.host.liveMasters.isEmpty)
                try await harness.wakeMac()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 30)
                #expect(back)
                #expect(Self.attempts(harness, since: before).map(\.succeeded) == [true])
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R6** - a sleep with no will-sleep message. The connection is still held on
        /// wake, half-open: the master process is alive and nothing on the far end
        /// answers. It is checked with one round trip, dropped when that does not come back,
        /// and replaced well inside the 45 s `ServerAliveInterval` would take.
        @Test func r6AHalfOpenConnectionIsCheckedOnWake() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let first = try #require(harness.host.liveMasters.first)
                try await harness.sleepMac(willSleep: false)
                harness.passTimeAsleep(20)
                try await harness.wakeMac()
                let wokeAt = harness.clock.now()
                let back = try await harness.run(
                    until: {
                        await Self.isConnected(harness)
                            && harness.host.liveMasters.map(\.ordinal) != [first.ordinal]
                    },
                    within: 60)
                #expect(back)
                let replacedAt = try #require(harness.host.attempts.last).at
                #expect(
                    replacedAt - wokeAt <= ConnectionGate.wakeCheckSeconds + 1,
                    "R6: the wake check, not ServerAliveInterval, found it")
                #expect(first.shutDownByClient, "R6: the half-open master was shut down by us")
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// The other half of R6: a connection that did survive a sleep is kept.
        @Test func r6AConnectionThatAnswersOnWakeIsKept() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let before = harness.host.attempts.count
                try await harness.sleepMac(willSleep: false)
                harness.passTimeAsleep(20)
                harness.host.resumeLiveConnections()
                try await harness.wakeMac()
                try await harness.run(for: 30)
                #expect(await Self.isConnected(harness))
                #expect(harness.host.attempts.count == before, "a live connection is not replaced")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R9, R14 - the channel budget

        /// **R9** - the server probe's exec channel is refused while other sessions hold
        /// the limit. That is not "no shell": `capabilities.json` keeps the answer it had,
        /// the ladder decides on it, and the probe is asked again on the live connection.
        @Test func r9ARefusedProbeChannelIsNotNoShell() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let before = harness.host.attempts.count
                harness.host.refuseExec(.sessionLimit, count: 1)
                harness.host.severConnections()
                let back = try await harness.run(
                    until: { await Self.isConnected(harness) && harness.host.attempts.count > before },
                    within: 60)
                #expect(back)
                await Self.expectShellProbe(harness, "R9 right after the connect")
                try await harness.run(for: 180)
                await Self.expectShellProbe(harness, "R9 once settled")
                #expect(Self.attempts(harness, since: before).count == 1, "R9: re-asked on the same connection")
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R9** at the channel probe: a server that is full when the location connects
        /// refuses the third channel, and that connection runs on two. A budget below the
        /// full three is asked again on every connect, so the next one - a reconnect, or an
        /// agent restart over a `capabilities.json` that says one - finds the room again.
        @Test func r9ALowBudgetIsAskedAgainOnEveryConnect() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let id = harness.location.id
                // Full but for two: the third channel of the probe is the one refused.
                harness.host.extraSessionsHeld = harness.host.maxSessions - 2
                harness.host.severConnections()
                let measured = try await harness.run(
                    until: { CapabilityCache.channelBudget(locationID: id)?.concurrentChannels == 2 },
                    within: 60)
                #expect(measured, "the full server's refusal is a verdict for that connection")
                harness.host.extraSessionsHeld = 0
                try await harness.run(for: 20)

                harness.host.severConnections()
                let restored = try await harness.run(
                    until: { CapabilityCache.channelBudget(locationID: id) == .unrestricted },
                    within: 60)
                #expect(restored, "R9: the next connect asked again")

                // A wrong "MaxSessions 1" does not survive an agent restart either.
                CapabilityCache.store(.forConcurrentChannels(1), locationID: id)
                try await harness.restartAgent()
                let afterRestart = try await harness.run(
                    until: {
                        await Self.isConnected(harness)
                            && CapabilityCache.channelBudget(locationID: id) == .unrestricted
                    },
                    within: 60)
                #expect(afterRestart, "R9: the restart's connect re-probed the low budget")
                let runtime = try await harness.currentRuntime()
                #expect(await runtime.channelBudgetValue() == .unrestricted)
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R14** - the channel probe's second channel opens and never answers its
        /// handshake. That is neither a refusal nor a death, so the connection runs on one
        /// channel, nothing is cached as a verdict, and the budget is asked again on the
        /// live connection; the clear answer, once the stall is gone, is room for three,
        /// and the location reconnects to use it.
        @Test(arguments: [2, 3])
        func r14AStalledProbeChannelIsInconclusive(ordinal: Int) async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let id = harness.location.id
                let before = harness.host.attempts.count
                harness.host.stalledSFTPChannelOrdinals = [ordinal]
                harness.host.severConnections()
                let reduced = try await harness.run(
                    until: {
                        guard await Self.isConnected(harness),
                            harness.host.attempts.count > before,
                            let runtime = try? await harness.currentRuntime()
                        else { return false }
                        return await !runtime.channelBudgetValue().conclusive
                    },
                    within: 60)
                #expect(reduced, "R14: the connection came up on the channels it got")
                let runtime = try await harness.currentRuntime()
                #expect(await runtime.channelBudgetValue().concurrentChannels == ordinal - 1)
                let cached = CapabilityCache.channelBudget(locationID: id)
                #expect(cached == nil || cached == .unrestricted, "R14: no verdict was cached: \(String(describing: cached))")
                harness.host.stalledSFTPChannelOrdinals = []

                let full = try await harness.run(
                    until: {
                        guard await Self.isConnected(harness),
                            CapabilityCache.channelBudget(locationID: id) == .unrestricted,
                            let runtime = try? await harness.currentRuntime()
                        else { return false }
                        return await runtime.channelBudgetValue() == .unrestricted
                    },
                    within: 120)
                #expect(full, "R14: the re-check found room for three and the location took it")
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R13 - the server probe

        /// **R13** - the server probe stalls past its deadline on a reconnect. The ladder
        /// keeps deciding on the last answer, `capabilities.json` is not overwritten with
        /// "no shell", and the probe answers on the re-check.
        @Test func r13AStalledProbeKeepsTheLastAnswer() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let before = harness.host.attempts.count
                harness.host.stallScript(.probe, count: 1)
                harness.host.severConnections()
                let back = try await harness.run(
                    until: { await Self.isConnected(harness) && harness.host.attempts.count > before },
                    within: 60)
                #expect(back)
                await Self.expectShellProbe(harness, "R13 with the probe unanswered")
                try await harness.run(for: 180)
                await Self.expectShellProbe(harness, "R13 once settled")
                #expect(Self.attempts(harness, since: before).count == 1)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R13** on a location whose very first probe stalls: there is no earlier answer
        /// to keep, so it starts without a shell, and the re-check on the same connection
        /// is what brings the shell - and the tiers above poll - back.
        @Test func r13AFirstProbeThatStallsIsAskedAgain() async throws {
            let harness = try Self.makeHarness()
            do {
                harness.host.stallScript(.probe, count: 1)
                let reached = try await harness.start(within: 180)
                #expect(reached, "the location reached its best tier after the re-check")
                #expect(harness.host.attempts.count == 1, "R13: on the connection it came up on")
                await Self.expectShellProbe(harness, "R13 first probe")
                try await harness.run(for: 60)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R16, R17, R18 - authentication and host keys

        /// **R16** - the home directory is not mounted yet, so the server refuses every key
        /// in it: twice, once at wake and once on the network change a minute later, which
        /// is the stop's one early attempt. The refusal stops the fast backoff, the early
        /// attempt leaves the slow retry where it was, and that retry brings the location
        /// back within one interval of the home mounting, with no user action and no
        /// attempt in between.
        @Test func r16ARefusalIsRetriedSlowlyAndRecovers() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                try await harness.sleepMac()
                // In place before the clock passes: every timer that came due during the
                // sleep goes off at the wake, and any of them may be the first attempt.
                harness.host.failAuthentication(times: 2)
                let before = harness.host.attempts.count
                harness.passTimeAsleep(600)
                try await harness.wakeMac()
                // Past the debounce: a path change within a minute of the wake's attempt is
                // merged into it and makes none of its own.
                try await harness.run(for: 65)
                try await harness.setNetworkPath(false)
                try await harness.setNetworkPath(true)
                try await harness.run(for: 1)
                // The second refusal was the last: the home directory is there from now.
                let mountedAt = harness.clock.now()
                let refused = Self.attempts(harness, since: before)
                #expect(refused.map(\.succeeded) == [false, false])

                let report = await harness.gateReport()
                #expect(report["stopped"] as? Bool == true)
                #expect(report["lastClassification"] as? String == "authenticationFailed")
                // Five minutes from the first refusal, +/-20 % jitter: the early attempt did not
                // move it. The report counts down from now, which is a moment later.
                let next = report["nextAttemptSeconds"] as? Double ?? 0
                let interval = next + (harness.clock.now() - (refused.first?.at ?? harness.clock.now()))
                #expect(
                    interval >= 239.8 && interval <= 360.2,
                    "R16: the slow retry is 5 minutes (+/-20 %) after the refusal: \(interval)")
                let sentence = await harness.manager.gate(locationID: harness.location.id)?.stateSentence() ?? ""
                #expect(sentence.contains("authenticationFailed") && sentence.contains("next attempt in"))

                harness.maxStep = 5
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 400)
                harness.maxStep = 1
                #expect(back)
                let retriedAt = harness.host.attempts.last(where: \.succeeded)?.at ?? .infinity
                #expect(retriedAt - mountedAt <= 361, "R16: back within ~6 minutes of the mount")
                #expect(
                    Self.attempts(harness, since: before).map(\.succeeded) == [false, false, true],
                    "R16: nothing between the refusals and the retry that worked")
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R16**, a refusal that lasts: an hour of it costs at most five attempts, each
        /// at least four minutes after the last, and a screen unlock afterwards is one
        /// attempt at once.
        @Test func r16ALastingRefusalCostsTheSlowCadenceAndNoMore() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.failAuthentication(times: 1000)
                let before = harness.host.attempts.count
                harness.host.severConnections()
                harness.maxStep = 5
                try await harness.run(for: 3600)
                harness.maxStep = 1
                let refused = Self.attempts(harness, since: before)
                #expect(refused.allSatisfy { !$0.succeeded })
                #expect((3...5).contains(refused.count), "R16: \(refused.count) attempts in an hour")
                let gaps = zip(refused.dropFirst(), refused).map { $0.at - $1.at }
                #expect(gaps.allSatisfy { $0 >= 240 }, "R16: never faster than the slow cadence: \(gaps)")

                harness.host.failAuthentication(times: 0)
                // The unlock is an early attempt only past the debounce of the last one.
                if let last = refused.last?.at, harness.clock.now() - last < 61 {
                    try await harness.run(for: 61 - (harness.clock.now() - last))
                }
                let unlockedAt = harness.clock.now()
                await harness.base.screenLock.unlock()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                let report = await harness.gateReport()
                #expect(back, "R16: the unlock is one attempt at once: \(report) \(harness.host.attempts.suffix(3))")
                let made = Self.attempts(harness, since: before)
                #expect(made.count == refused.count + 1)
                #expect((made.last?.at ?? .infinity) - unlockedAt < 2)
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R16**, a password - the password in the keychain went stale. Each attempt
        /// sends it, and `pam_faillock` counts every one, so it is tried once and never
        /// again on its own: not by the slow timer, and not by a lid opening's wake, path
        /// change and unlock, nor by four hours of them. `debug breaker --connect` after the
        /// password is fixed is the one attempt, and it connects.
        @Test func r16AStalePasswordIsTriedOnceAndNeverAgain() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                try await harness.sleepMac()
                harness.host.refusePassword(times: 1000)
                let before = harness.host.attempts.count
                harness.passTimeAsleep(600)
                try await harness.wakeMac()
                try await harness.run(for: 3)
                try await harness.setNetworkPath(false)
                try await harness.setNetworkPath(true)
                try await harness.run(for: 5)
                await harness.base.screenLock.unlock()
                try await harness.run(for: 120)
                // And a second lid opening, well after the first.
                try await harness.sleepMac()
                harness.passTimeAsleep(3600)
                try await harness.wakeMac()
                try await harness.setNetworkPath(false)
                try await harness.setNetworkPath(true)
                await harness.base.screenLock.unlock()
                harness.maxStep = 30
                try await harness.run(for: 4 * 3600)
                harness.maxStep = 1
                let made = Self.attempts(harness, since: before)
                #expect(made.count == 1, "R16: the stale password was sent \(made.count) times: \(made.map(\.outcome))")
                #expect(made.first?.outcome.hasPrefix("password refused") == true)
                let report = await harness.gateReport()
                #expect(report["stopped"] as? Bool == true)
                #expect(report["lastClassification"] as? String == "passwordRefused")
                #expect(report["nextAttemptSeconds"] == nil, "no slow retry for a refused password")

                harness.host.refusePassword(times: 0)
                let gate = try #require(await harness.manager.gate(locationID: harness.location.id))
                try await harness.perform("debug breaker --connect") { await gate.clearStopAndConnect() }
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                #expect(back)
                #expect(Self.attempts(harness, since: before).count == 2)
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R17** - an `agentDependent` location wakes before its key agent is ready. The
        /// pre-spawn socket probe fails: that is the key agent, on its own backoff, not an
        /// authentication stop. The agent's socket then appears but the key is not in it
        /// yet, and the server refuses with a bare `Permission denied (publickey)`; with the
        /// socket answering that is a refusal (gotcha 40), on the slow retry. The user
        /// unlocking the screen a minute later is its early attempt, and it connects.
        @Test func r17AKeyAgentThatIsNotReadyIsRetried() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start(agentDependent: true)
                try await harness.run(for: 10)
                harness.base.presence.setPresent()
                try await harness.sleepMac()
                // In place before the clock passes: every timer that came due during the
                // sleep goes off at the wake, and any of them may be the first attempt.
                harness.host.enqueueConnectOutcomes([.keyAgentNotReady])
                harness.host.failAuthentication(times: 1, stderr: "alec@nas: Permission denied (publickey).")
                let before = harness.host.attempts.count
                harness.passTimeAsleep(600)
                try await harness.wakeMac()
                let stopped = try await harness.run(
                    until: { await harness.gateReport()["stopped"] as? Bool == true }, within: 60)
                #expect(stopped)
                #expect(await harness.gateReport()["lastClassification"] as? String == "authenticationFailed")
                #expect(Self.attempts(harness, since: before).map(\.succeeded) == [false, false])
                try await harness.run(for: 65)
                await harness.base.screenLock.unlock()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                #expect(back)
                #expect(Self.attempts(harness, since: before).map(\.succeeded) == [false, false, true])
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R17**, the deadline: a key agent that waits for a touch nobody gives stops the
        /// location, and nothing is attempted unattended - two hours of an unlocked but idle
        /// Mac cost no attempt at all, because an attempt can make a security key blink or
        /// a phone prompt fire. The unlock is the one attempt, and it connects.
        @Test func r17ADeadlineStopMakesNoUnattendedAttempt() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start(agentDependent: true)
                try await harness.run(for: 10)
                harness.base.presence.set(idleSeconds: 3600, screenLocked: false)
                harness.host.enqueueConnectOutcomes([.authenticationDeadline])
                let before = harness.host.attempts.count
                harness.host.severConnections()
                let stopped = try await harness.run(
                    until: { await harness.gateReport()["stopped"] as? Bool == true }, within: 120)
                #expect(stopped)
                #expect(await harness.gateReport()["nextAttemptSeconds"] == nil, "no slow retry for a deadline")
                let stoppedAttempts = harness.host.attempts.count
                harness.maxStep = 5
                try await harness.run(for: 7200)
                harness.maxStep = 1
                #expect(harness.host.attempts.count == stoppedAttempts, "R17: nothing unattended")
                harness.base.presence.setPresent()
                await harness.base.screenLock.unlock()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                #expect(back)
                #expect(Self.attempts(harness, since: before).count == 2)
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R18** - a foreign network whose server presents another host key. Every retry
        /// is a fresh `ssh` that checks `known_hosts`, so the location never connects there,
        /// and it tries no faster than the slow cadence. Home again, the path change is one
        /// attempt at once and it connects.
        @Test func r18AChangedHostKeyNeverConnectsAndRecoversAtHome() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                try await harness.setNetworkPath(false)
                harness.host.failHostKey(true)
                let before = harness.host.attempts.count
                try await harness.setNetworkPath(true)
                harness.maxStep = 5
                try await harness.run(for: 1200)
                harness.maxStep = 1
                let foreign = Self.attempts(harness, since: before)
                #expect(!foreign.isEmpty && foreign.allSatisfy { !$0.succeeded }, "R18: never connected")
                #expect(foreign.count <= 3, "R18: \(foreign.count) attempts in 20 minutes")
                #expect(await harness.gateReport()["lastClassification"] as? String == "hostKeyFailed")

                harness.host.failHostKey(false)
                try await harness.setNetworkPath(false)
                let homeAt = harness.clock.now()
                try await harness.setNetworkPath(true)
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 60)
                #expect(back)
                let connectedAt = harness.host.attempts.last(where: \.succeeded)?.at ?? .infinity
                #expect(connectedAt - homeAt < 2, "R18: home again, at once")
                try await harness.run(for: 180)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R19, R20 - restarts and flapping

        /// **R19** - the agent restarts while the server is unreachable. The new agent
        /// starts offline, backs off, and connects on its own once the link is back.
        @Test func r19AnAgentRestartedMidOutageReconnects() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.setLink(.unreachable)
                harness.host.severConnections()
                // Long enough for the backoff to have grown: a fresh agent starts its own
                // breaker from the first interval, by design.
                try await harness.run(for: 90)
                try await harness.restartAgent()
                try await harness.run(for: 30)
                #expect(await !Self.isConnected(harness))
                harness.host.setLink(.up)
                let linkUpAt = harness.clock.now()
                let back = try await harness.run(until: { await Self.isConnected(harness) }, within: 120)
                #expect(back, "R19: the restarted agent's own backoff brought it back")
                let connectedAt = harness.host.attempts.last(where: \.succeeded)?.at ?? .infinity
                #expect(connectedAt - linkUpAt <= 60 * 1.2 + 1, "R19: within one capped backoff interval")
                try await harness.run(for: 180)
                await Self.expectShellProbe(harness, "R19")
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R20** - the link flaps, three seconds up and three down, twenty times. The
        /// breaker's backoff bounds the attempts, and once the link is steady the location
        /// is connected on one connection with its budget and probe intact.
        @Test func r20AFlappingLinkSettles() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                for _ in 0..<20 {
                    harness.host.setLink(.unreachable)
                    try await harness.run(for: 3)
                    harness.host.setLink(.up)
                    try await harness.run(for: 3)
                }
                try await harness.run(for: 180)
                await Self.expectShellProbe(harness, "R20")
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R22 - a drop inside the reconnect

        /// **R22** - the connection drops while the server probe is running on it. That
        /// connection is not handed out with "no shell" on it: the attempt fails, and the
        /// next connection's probe is the one in force.
        @Test func r22ADropDuringTheProbeLeavesNoStaleAnswer() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.sever(when: .scriptOpened(.probe))
                harness.host.severConnections()
                try await harness.run(for: 180)
                await Self.expectShellProbe(harness, "R22")
                let runtime = try await harness.currentRuntime()
                #expect(await runtime.allowsExecChannel())
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R22** - the connection drops while its reconnect sequence is deploying the
        /// helper. The rest of that sequence is skipped and the next connection's runs in
        /// full, so the probe and budget in force are the live connection's.
        @Test func r22ADropDuringTheSequenceLeavesTheNextConnectionInForce() async throws {
            let harness = try Self.makeHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.sever(when: .scriptOpened(.interrogate))
                harness.host.severConnections()
                try await harness.run(for: 180)
                await Self.expectShellProbe(harness, "R22 deploy")
                let runtime = try await harness.currentRuntime()
                #expect(await runtime.channelBudgetValue() == .unrestricted)
                let violations = await Self.connectionViolations(harness)
                #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: The sequence itself

        /// The first connection is made from inside `runtime(for:)`, while `start()` is
        /// still connecting and before the runtime and the detector are in their maps. Its
        /// reconnect sequence still runs - it waits for both - and two callers asking for
        /// the runtime at once share one start and one connection.
        @Test func theFirstConnectionsSequenceRunsAndStartsAreShared() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            let capture = LogCapture()
            capture.install()
            defer { capture.uninstall() }
            let manager = harness.manager
            async let one = manager.runtime(for: location)
            async let two = manager.runtime(for: location)
            let (first, second) = try await (one, two)
            #expect(first === second)
            await harness.quiesceConnects()
            #expect(harness.launcher.attempts == 1)
            // `applyConnection` is the only `statvfs` here (the other is `status --probe`),
            // so one call is the sequence having run, once. The log line says the same on
            // Linux; on Darwin `Log.agent` is os.Logger and a LogCapture never sees it.
            #expect(harness.launcher.live?.statvfsCount == 1,
                    "the first connection's sequence ran, and did not apply it twice")
            #if !canImport(os)
                let applied = capture.messages().filter {
                    $0.contains(location.id) && $0.contains("connection 1 is applied")
                }
                #expect(applied.count == 1, "the first connection's sequence ran: \(applied)")
            #endif
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// Decision 2: `applyConnection` records the connection's budget and probe before
        /// anything that can fail. Here the root call fails because the gate is backing
        /// off, and the runtime still holds what the connection found.
        @Test func applyConnectionRecordsBeforeItCanFail() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            let runtime = try await harness.manager.runtime(for: location)
            await harness.manager.detector(locationID: location.id)?.stop()
            await harness.manager.evictor(locationID: location.id)?.stop()
            await harness.quiesceConnects()
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            harness.launcher.fail()
            await gate.drop(reason: "the master was killed")
            await harness.settle { await gate.stateSentence().contains("backing off") }

            var probe = ServerProbe.Result()
            probe.uname = "Linux x86_64"
            probe.failure = "no shell access (ForceCommand)."
            let budget = ChannelBudget.forConcurrentChannels(2)
            let stale = FakeLiveConnection(
                transport: FakeTransport(root: location.remotePath ?? "/srv/fake"),
                budget: budget, probe: probe)
            await #expect(throws: (any Error).self) { try await runtime.applyConnection(stale) }
            #expect(await runtime.channelBudgetValue() == budget)
            #expect(await runtime.probeForSweep()?.uname == "Linux x86_64")
            #expect(await !runtime.allowsPersistentExecChannel())
            await harness.manager.dropRuntime(locationID: location.id)
        }
    }
}
