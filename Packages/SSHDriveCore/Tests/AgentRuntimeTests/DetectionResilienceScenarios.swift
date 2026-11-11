import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Foundation
import ServerModel
import Testing

/// The change-detection half of the resilience suite: faults that reach the helper's
/// stream, the ladder or the sweep rather than the connection, each followed by the
/// convergence checks C1-C8 (docs/design/change-detection.md, "Tiers and the ladder").
///
/// What every one of them defends is the same sentence: once the fault is gone the
/// location is back at the best tier the server supports, without anyone running a
/// command.
extension AgentScenarios {

    @Suite struct DetectionResilienceScenarios {

        private static func expectConverged(
            _ harness: ResilienceHarness, _ what: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            let violations = await harness.converged()
            #expect(
                violations.isEmpty, "\(what):\n\(violations.joined(separator: "\n"))",
                sourceLocation: sourceLocation)
        }

        private static func downgrades(_ harness: ResilienceHarness) async -> [[String: Any]] {
            await harness.detectorStatus()["downgrades"] as? [[String: Any]] ?? []
        }

        // MARK: R10 - a slow `ready`

        /// **R10** - the helper's first walk of a large pinned tree takes 40 s before its
        /// `ready` line. That is a helper starting, not one failing, and the location
        /// settles at tier 2 on the first attempt.
        @Test func r10AFortySecondReadyIsWaitedFor() async throws {
            let harness = try ResilienceHarness()
            do {
                harness.host.helperReadyDelay = 40
                let settled = try await harness.start(within: 120)
                #expect(settled, "R10: the helper is running 120 s after the add")
                let downgrades = await Self.downgrades(harness)
                #expect(downgrades.isEmpty, "R10: a 40 s ready costs nothing: \(downgrades)")
                try await harness.run(for: 30)
                await Self.expectConverged(harness, "R10 (40 s)")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R10** - a helper that does not say `ready` within the 120 s deadline, for
        /// 130 s, and then does. The miss is transient: the stream is retried on the
        /// ladder's backoff and the location is back at tier 2 once the helper answers.
        @Test func r10AHelperThatNeverSaysReadyThenDoesIsRetried() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.helperNeverReady = true
                harness.host.killHelpers()
                ResilienceScenarios.changeTheServer(harness)
                try await harness.run(for: 130)
                let during = await Self.downgrades(harness)
                #expect(
                    during.allSatisfy { $0["permanence"] as? String == "transient" },
                    "R10: a missing ready is never a verdict: \(during)")
                harness.host.helperNeverReady = false
                try await harness.run(for: 180)
                await Self.expectConverged(harness, "R10 (never ready, then ready)")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R11 - the helper killed under a live connection

        /// **R11** - the helper is killed on the server while the connection stays up.
        /// The stream's death is a transient tier failure: the location sweeps for the
        /// hold, climbs back, and starts a new helper on the same connection.
        @Test func r11AKilledHelperIsRestartedOnTheSameConnection() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let attempts = harness.host.attempts.count
                harness.host.killHelpers()
                ResilienceScenarios.changeTheServer(harness)
                try await harness.run(for: 180)
                #expect(
                    harness.host.attempts.count == attempts,
                    "R11: the connection was never replaced")
                await Self.expectConverged(harness, "R11")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R4 - one stream per connection

        /// **R4**, twenty times - the master killed abruptly. The reconnect and the cycle
        /// that climbs back from the stream's death both want a helper, and exactly one
        /// may run: a second stream holds an exec session on the server for nothing.
        @Test func r4NeverLeavesTwoHelpersOnOneConnection() async throws {
            for round in 1 ... 20 {
                let harness = try ResilienceHarness()
                do {
                    try await harness.start()
                    try await harness.run(for: 10)
                    harness.host.severConnections()
                    ResilienceScenarios.changeTheServer(harness)
                    try await harness.run(for: 180)
                    await Self.expectConverged(harness, "R4 round \(round)")
                } catch {
                    Issue.record(error, "R4 round \(round)")
                }
                await harness.tearDown()
            }
        }

        // MARK: A stream that goes silent

        /// A helper whose channel stops carrying anything at all - no events, no
        /// heartbeats - while the connection and its other channels are fine. The helper
        /// writes a heartbeat every 15 s, so 60 s of silence is a dead stream: it is torn
        /// down as a transient failure and a new one is started.
        @Test func aSilentHelperStreamIsDeclaredDeadAndReplaced() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.freezeHelpers()
                ResilienceScenarios.changeTheServer(harness)
                try await harness.run(for: 180)
                let reasons = await Self.downgrades(harness).compactMap { $0["reason"] as? String }
                #expect(
                    reasons.contains { $0.contains("went silent") },
                    "the watchdog is what ended the stream: \(reasons)")
                await Self.expectConverged(harness, "silent helper")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// A new root set - a folder opened in Finder - makes the helper walk every root
        /// again, and on a large tree an older helper says nothing until the walk is done:
        /// here 100 s with no event and no heartbeat. Silence that long is not death while
        /// a walk the agent asked for may be running, and the stream is not torn down.
        @Test func aHelperSilentWhileItWalksANewRootSetIsNotKilled() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let starts = harness.host.helperStarts
                harness.host.helperRootsWalkSeconds = 100
                let runtime = try await harness.currentRuntime()
                let docs = try await runtime.identifier(forPath: "docs").identifier
                try await harness.perform("opening docs in Finder") {
                    _ = try await runtime.enumerateItems(container: docs, pageToken: nil)
                }
                ResilienceScenarios.changeTheServer(harness)
                try await harness.run(for: 240)
                let reasons = await Self.downgrades(harness).compactMap { $0["reason"] as? String }
                #expect(reasons.isEmpty, "the stream was ended during the walk: \(reasons)")
                #expect(harness.host.helperStarts == starts, "the helper was restarted")
                harness.host.helperRootsWalkSeconds = 0
                await Self.expectConverged(harness, "a silent re-walk")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: Permanent verdicts last for the connection

        /// Takes the helper's directory away from the account, or gives it back: the one
        /// refusal the deployment makes on a live connection that is about the server.
        private static func setCacheOwner(_ harness: ResilienceHarness, uid: UInt32) {
            var taken = harness.host.sftp.detachTree(harness.host.cacheDirectory)
            let key = harness.host.sftp.absolute(harness.host.cacheDirectory)
            taken[key]?.uid = uid
            harness.host.sftp.attachTree(taken)
        }

        /// A permanent refusal on a connection that stays up for hours is re-decided every
        /// 30 minutes rather than held for the session: a directory someone else owned is
        /// a fact about the server, and facts about a server change.
        @Test func aPermanentVerdictExpiresAfterThirtyMinutes() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                let attempts = harness.host.attempts.count
                Self.setCacheOwner(harness, uid: 4242)
                harness.host.killHelpers()
                try await harness.run(for: 60)
                let status = await harness.detectorStatus()
                #expect(status["tier"] as? String == "sweep")
                let permanent = await Self.downgrades(harness).filter {
                    $0["permanence"] as? String == "permanent"
                }
                #expect(permanent.count == 1, "the refusal is a verdict: \(permanent)")

                Self.setCacheOwner(harness, uid: harness.host.uid)
                try await harness.run(for: 25 * 60)
                let held = await harness.detectorStatus()["tier"] as? String
                #expect(held == "sweep", "held for the connection until the 30 minutes are up")
                try await harness.run(for: 6 * 60)
                #expect(
                    harness.host.attempts.count == attempts,
                    "the connection was never replaced, so only the expiry can have lifted it")
                await Self.expectConverged(harness, "permanent verdict, expired")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// The same verdict, lifted by the next connection instead: its probe and its
        /// deployment decide again.
        @Test func aPermanentVerdictIsReDecidedByTheNextConnection() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                Self.setCacheOwner(harness, uid: 4242)
                harness.host.killHelpers()
                try await harness.run(for: 60)
                let refused = await harness.detectorStatus()["tier"] as? String
                #expect(refused == "sweep")
                Self.setCacheOwner(harness, uid: harness.host.uid)
                harness.host.severConnections()
                try await harness.run(for: 180)
                await Self.expectConverged(harness, "permanent verdict, new connection")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: R15 - a sweep that times out

        /// **R15** at tier 2 - the reconnect's full sweep hangs on the server (a `find`
        /// stuck on an NFS mount) and times out, while the helper cannot start either.
        /// Neither costs the location anything once both are well: a sweep failure is a
        /// note on that cycle, never a verdict and never the helper tier.
        @Test func r15ASweepTimeoutAtTheHelperTierIsOnlyACycleNote() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.stallScript(.sweep)
                harness.host.helperNeverReady = true
                harness.host.severConnections()
                ResilienceScenarios.changeTheServer(harness)
                try await harness.run(for: 1000)
                let during = await Self.downgrades(harness)
                #expect(
                    during.allSatisfy { $0["permanence"] as? String == "transient" },
                    "R15: a sweep timeout is not a verdict: \(during)")
                harness.host.clearScriptStalls()
                harness.host.helperNeverReady = false
                try await harness.run(for: 240)
                await Self.expectConverged(harness, "R15 at tier 2")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R15** at tier 1, for hours - a `find` stuck on a hung NFS mount under a root,
        /// every time. Each timeout is a note on its cycle and never a verdict, but the
        /// sweep backs off: one paced interval after the first, doubling to 30 minutes, with
        /// those cycles polling instead. The first sweep that completes ends the backoff.
        @Test func r15ASweepThatAlwaysTimesOutBacksOff() async throws {
            let harness = try ResilienceHarness(shipsHelper: false)
            do {
                let settled = try await harness.start()
                #expect(settled)
                try await harness.run(for: 10)
                let before = harness.host.sweepsStarted
                harness.host.stallScript(.sweep)
                harness.maxStep = 10
                try await harness.run(for: 3 * 3600)
                let sweeps = harness.host.sweepsStarted - before
                // At a fixed 900 s pace - the 300 s timeout times three - three hours is
                // twelve sweeps; the backoff makes it six or fewer.
                #expect(sweeps <= 7, "R15: \(sweeps) sweeps in three hours of timeouts")
                let downgrades = await Self.downgrades(harness)
                #expect(
                    downgrades.allSatisfy { $0["permanence"] as? String == "transient" },
                    "R15: a sweep timeout is not a verdict: \(downgrades)")
                harness.host.clearScriptStalls()
                harness.host.resumeStalledScripts()
                ResilienceScenarios.changeTheServer(harness)
                try await harness.run(for: SweepTimeoutBackoff.capSeconds + 300)
                harness.maxStep = 5
                try await harness.run(for: 60)
                await Self.expectConverged(harness, "R15 at tier 1")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        // MARK: The connection going during tier 2's own work

        /// **R12** - the connection drops in the middle of the helper's upload, leaving a
        /// temp file behind. The failed deployment belongs to a connection that is gone and
        /// costs nothing; the next connection uploads again.
        @Test func r12ADropMidUploadIsNotAVerdict() async throws {
            let harness = try ResilienceHarness()
            do {
                harness.host.sever(
                    when: .treeChange(pathContaining: "/.cache/sshdrive/.sshdrive-upload-"))
                try await harness.start(within: 200)
                try await harness.run(for: 180)
                await Self.expectConverged(harness, "R12")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R22** - the connection drops while the reconnect is deploying the helper.
        @Test func r22ADropDuringTheDeploymentIsNotAVerdict() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.sever(when: .scriptOpened(.interrogate))
                harness.host.severConnections()
                try await harness.run(for: 180)
                await Self.expectConverged(harness, "R22 (deploy)")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }

        /// **R25** - the location root stops resolving for a minute after a reconnect (an
        /// autofs mount, a locked dataset). The helper cannot start without its root; that
        /// is a hold of seconds, not a wait for the next idle cycle.
        @Test func r25ARootMissingForAWhileHoldsTheHelperBriefly() async throws {
            let harness = try ResilienceHarness()
            do {
                try await harness.start()
                try await harness.run(for: 10)
                harness.host.hideRoot()
                harness.host.severConnections()
                try await harness.run(for: 60)
                harness.host.restoreRoot()
                try await harness.run(for: 180)
                await Self.expectConverged(harness, "R25")
            } catch {
                Issue.record(error)
            }
            await harness.tearDown()
        }
    }
}
