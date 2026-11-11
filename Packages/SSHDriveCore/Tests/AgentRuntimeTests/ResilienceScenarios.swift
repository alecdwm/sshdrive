import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Foundation
import Logging
import ServerModel
import Testing

/// The resilience suite: one location on a `FakeRemoteHost`, driven through an adverse
/// sequence in virtual time, then held to the convergence checks C1-C8 once the fault is
/// lifted (docs/design/testing.md, docs/design/offline.md,
/// docs/design/change-detection.md).
///
/// Every scenario ends with `converged()` returning no violations: back at the best tier
/// the server supports, the helper's stream delivering, the index agreeing with the
/// server, and nothing left running that should not be. The quiet period after the fault
/// is the shortest the recovery policy allows, so a scenario that passes only because it
/// waited for the 10-minute idle poll proves nothing.
///
/// The rows are split over several files by subject: this one holds the shared machinery,
/// the baselines and the link, sleep and server-restart rows.
extension AgentScenarios {

    @Suite struct ResilienceScenarios {

        // MARK: Quiet periods

        /// Ordinary outages: the reconnect loop's backoff (60 s cap, +20 % jitter) and the
        /// ladder's (60 s cap) both fit with room for the full sweep and the C3 probe.
        static let quiet: Double = 180
        /// Authentication recovery: the first slow-timer retry is due 5 minutes (+/-20 %)
        /// after the refusal, which can itself come up to `masterWatchSeconds` after the
        /// fault, and the location then needs its ordinary minute to converge.
        static let authQuiet: Double = 7 * 60
        /// A permanent verdict is re-tried at most every 30 minutes on a live connection.
        static let verdictQuiet: Double = 31 * 60

        // MARK: Changing the server

        /// One of each kind of change, in the watched root, for C4 to find in the index:
        /// a new file, an edit that keeps the size, and a deletion.
        static func changeTheServer(_ harness: ResilienceHarness) {
            harness.host.writeFile("during-outage.txt", text: "written during the fault\n")
            harness.host.writeFile("notes.txt", text: "final draft\n")
            harness.host.delete("old.txt")
        }

        // MARK: Running a row

        /// A harness on `profile`, brought up to its best tier, handed to `body`, and torn
        /// down whatever happened.
        static func scenario(
            profile: ServerProfile = .debian, shipsHelper: Bool = true,
            agentDependent: Bool = false, startWithin: Double = 120,
            prepare: (ResilienceHarness) -> Void = { _ in },
            replay: String = "",
            sourceLocation: SourceLocation = #_sourceLocation,
            _ body: (ResilienceHarness) async throws -> Void
        ) async {
            let harness: ResilienceHarness
            do {
                harness = try ResilienceHarness(profile: profile, shipsHelper: shipsHelper)
            } catch {
                Issue.record(error, sourceLocation: sourceLocation)
                return
            }
            prepare(harness)
            do {
                let reached = try await harness.start(
                    agentDependent: agentDependent, within: startWithin)
                #expect(
                    reached, "the location did not reach \(harness.expectedTier.rawValue) on a healthy server",
                    sourceLocation: sourceLocation)
                try await body(harness)
            } catch {
                Issue.record(
                    error, Comment(rawValue: await diagnosis(harness) + "\n" + replay),
                    sourceLocation: sourceLocation)
            }
            await harness.tearDown()
        }

        /// `converged()`, expected to report no violations.
        static func expectConverged(
            _ harness: ResilienceHarness,
            effort: ResilienceHarness.Effort = ResilienceHarness.Effort(),
            requireResolvedSignal: Bool = true,
            replay: String = "",
            sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            let violations = await harness.converged(
                effort: effort, requireResolvedSignal: requireResolvedSignal)
            let context = await diagnosis(harness) + (replay.isEmpty ? "" : "\n\(replay)")
            #expect(
                violations.isEmpty, "\(violations.joined(separator: "\n"))\n\(context)",
                sourceLocation: sourceLocation)
        }

        /// What a failing row prints after its violations: the tier, the gate and the
        /// connect attempts, which between them usually name the cause.
        static func diagnosis(_ harness: ResilienceHarness) async -> String {
            let status = await harness.detectorStatus()
            let gate = await harness.gateReport()
            let attempts = harness.host.attempts.suffix(12).map {
                "  \(Int($0.serverAt - harness.host.attempts[0].serverAt)) s: \($0.outcome)"
            }
            let downgrades = (status["downgrades"] as? [[String: Any]] ?? []).map {
                "  \($0["from"] ?? "?") -> \($0["to"] ?? "?") \($0["permanence"] ?? "?"): \($0["reason"] ?? "?")"
            }
            // `SSHDRIVE_RESILIENCE_LOG=debug` prints every level, and more of it.
            let verbose = ProcessInfo.processInfo.environment["SSHDRIVE_RESILIENCE_LOG"] == "debug"
            let log = harness.log.entries.filter { verbose || $0.level >= .notice }
                .suffix(verbose ? 400 : 40).map {
                    "  \($0.category): \($0.message.prefix(220))"
                }
            return """
                tier \(status["tier"] ?? "?") (note: \(status["note"] ?? "none")); \
                gate \(gate["state"] ?? "?"), last failure \(gate["lastClassification"] ?? "none"), \
                retry scheduled \(gate["retryScheduled"] ?? "?")
                downgrades:
                \(downgrades.joined(separator: "\n"))
                last attempts:
                \(attempts.joined(separator: "\n"))
                the agent's log, last \(log.count) lines:
                \(log.joined(separator: "\n"))
                """
        }

        /// Runs with a long step while nothing that needs one-second resolution is
        /// running: an outage with no connection, or the Mac asleep. Every timer still
        /// fires at its own deadline; the step only bounds how far the clock moves past a
        /// task that had not parked yet, and `settle()` has waited for those.
        static func idle(_ harness: ResilienceHarness, for seconds: Double) async throws {
            let saved = harness.maxStep
            harness.maxStep = 30
            defer { harness.maxStep = saved }
            try await harness.run(for: seconds)
        }

        /// Runs until a master newer than every one that existed when it was called is up
        /// and the gate holds a connection, or `within` virtual seconds pass. A severed
        /// master can look connected to the gate for a while, so the gate alone is not the
        /// answer.
        @discardableResult
        static func runUntilReconnected(_ harness: ResilienceHarness, within: Double) async throws -> Bool {
            let before = harness.host.masters.count
            return try await harness.run(
                until: {
                    guard harness.host.masters.dropFirst(before).contains(where: \.alive) else {
                        return false
                    }
                    return await harness.gateReport()["connected"] as? Bool == true
                },
                within: within)
        }

        /// Runs until the fake server has an exec channel of this kind open, or `within`
        /// virtual seconds pass.
        @discardableResult
        static func runUntilOpen(
            _ kind: FakeRemoteHost.ScriptKind, _ harness: ResilienceHarness, within: Double
        ) async throws -> Bool {
            try await harness.run(
                until: { harness.host.liveMasters.contains { $0.openExecKinds.contains(kind) } },
                within: within)
        }

        // MARK: The baseline

        /// **R0** - the baseline every other scenario is measured against: a location
        /// added on a healthy server reaches the helper tier and stays converged.
        @Test func r0AHealthyLocationConverges() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 60)
                await Self.expectConverged(harness)
            }
        }

        /// **R0** on every server shape the suite fuzzes against, so a fuzzer failure on
        /// one of them is about the faults and not about the server.
        @Test(arguments: ["alpine", "ts-ssh", "synology-dsm", "freebsd", "deb-maxsessions"])
        func r0EveryServerShapeConverges(_ name: String) async throws {
            let profile = ResilienceScenarios.profile(named: name)
            await Self.scenario(profile: profile) { harness in
                try await harness.run(for: 60)
                await Self.expectConverged(harness)
            }
        }

        static func profile(named name: String) -> ServerProfile {
            switch name {
            case "alpine": return .alpine
            case "ts-ssh": return .tailscaleSSH
            case "synology-dsm": return .synologyDSM
            case "freebsd": return .freeBSD
            case "deb-maxsessions": return .debianMaxSessions
            default: return .debian
            }
        }

        // MARK: The network path and the link

        /// **R1** (short) - the network path goes away for five seconds and comes back.
        /// The agent drops the master when the path goes, reconnects when it returns, and
        /// catches the change made in between with the reconnect's full sweep.
        @Test func r1AShortPathLossConverges() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.unreachable)
                try await harness.setNetworkPath(false)
                Self.changeTheServer(harness)
                try await harness.run(for: 5)
                harness.host.setLink(.up)
                try await harness.setNetworkPath(true)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R1** (long) - two hours with no network path at all, then it returns.
        @Test func r1ALongPathLossConverges() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.unreachable)
                try await harness.setNetworkPath(false)
                Self.changeTheServer(harness)
                try await Self.idle(harness, for: 2 * 3600)
                harness.host.setLink(.up)
                try await harness.setNetworkPath(true)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R2** - the link dies with the path still up, so nothing tells the agent: the
        /// master is half-open until `ServerAliveInterval` gives up on it, and every
        /// connect after that fails at once with `Network is unreachable`. Five minutes
        /// later the link is back.
        @Test func r2AnUnreachableLinkWithNoPathChange() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.unreachable)
                Self.changeTheServer(harness)
                try await harness.run(for: 300)
                harness.host.setLink(.up)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R2** with a black hole: every connect times out after `ConnectTimeout`.
        @Test func r2ABlackholedLinkWithNoPathChange() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.blackhole)
                Self.changeTheServer(harness)
                try await harness.run(for: 300)
                harness.host.setLink(.up)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R3** (short) - the live connection goes half-open for 20 s, inside
        /// `ServerAliveInterval`'s 45 s: calls and the helper's output stall and then
        /// resume on the same master.
        @Test func r3AShortHalfOpenStall() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.blackhole)
                Self.changeTheServer(harness)
                try await harness.run(for: 20)
                harness.host.setLink(.up)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R3** (long) - half-open for two minutes: `ServerAliveInterval` kills the
        /// master at 45 s and the server's wrapper kills the helper at 60 s without a
        /// heartbeat.
        @Test func r3ALongHalfOpenStall() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.blackhole)
                Self.changeTheServer(harness)
                try await harness.run(for: 120)
                harness.host.setLink(.up)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R4** - the master is killed abruptly, with nothing on the agent's side telling
        /// it so. Three virtual minutes later the location is back at the helper tier, with
        /// a change made on the server while it was down in the index.
        @Test func r4AKilledMasterIsReplaced() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.severConnections()
                Self.changeTheServer(harness)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R4** on a location nobody has touched for eleven minutes, so its poll cadence
        /// is the idle ten minutes. The master dying is still noticed and replaced within the
        /// ordinary quiet period: the stream ending is the evidence, not the next cycle.
        @Test func r4AKilledMasterOnAnIdleLocation() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 11 * 60)
                harness.host.severConnections()
                Self.changeTheServer(harness)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R7** on an idle location, with three requests holding the dead connection:
        /// the first one to fail starts a reconnect, which `sshd` refuses, and the others'
        /// failures arrive while the breaker is backing off. The reconnect loop survives
        /// them; nothing else will retry for ten minutes.
        @Test func r7ConcurrentCallsOnADeadMasterKeepTheReconnectLoop() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 11 * 60)
                harness.host.severConnections()
                harness.host.sshd = .refusing
                harness.host.after(30) { [host = harness.host] in host.sshd = .running }
                let runtime = try await harness.currentRuntime()
                for _ in 0 ..< 3 {
                    Task { _ = try? await runtime.rootDescription() }
                }
                Self.changeTheServer(harness)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        // MARK: Sleep and wake

        /// **R5** - the Mac sleeps with the will-sleep message, the Wi-Fi is off when it
        /// wakes, and the path comes back ten seconds later.
        @Test func r5ASleepWithWillSleepAndALatePath() async throws {
            await Self.scenario { harness in
                try await Self.sleepAndWakeOntoALatePath(harness, dnsFailures: 0)
                await Self.expectConverged(harness)
            }
        }

        /// **R5** with the resolver not ready either: the first two connects after the path
        /// returns fail `Could not resolve hostname`.
        @Test func r5ASleepWithALatePathAndALateResolver() async throws {
            await Self.scenario { harness in
                try await Self.sleepAndWakeOntoALatePath(harness, dnsFailures: 2)
                await Self.expectConverged(harness)
            }
        }

        static func sleepAndWakeOntoALatePath(_ harness: ResilienceHarness, dnsFailures: Int)
            async throws
        {
            try await harness.run(for: 10)
            try await harness.sleepMac(willSleep: true)
            harness.host.setLink(.unreachable)
            try await harness.setNetworkPath(false)
            Self.changeTheServer(harness)
            harness.passTimeAsleep(1800)
            try await harness.wakeMac()
            try await harness.run(for: 10)
            if dnsFailures > 0 { harness.host.failNameResolution(times: dnsFailures) }
            harness.host.setLink(.up)
            try await harness.setNetworkPath(true)
            try await harness.run(for: Self.quiet)
        }

        /// **R6** - the lid closes and no will-sleep message arrives: the master is left
        /// behind half-open, and the server forgets it while the Mac sleeps.
        @Test func r6ASleepWithNoWillSleep() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                try await harness.sleepMac(willSleep: false)
                Self.changeTheServer(harness)
                harness.passTimeAsleep(1800)
                try await harness.wakeMac()
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R6** with no wake message either: nothing at all tells the agent the Mac was
        /// away, and the dead master is found by whatever uses it next.
        @Test func r6ASleepWithNoPowerMessagesAtAll() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                try await harness.sleepMac(willSleep: false)
                Self.changeTheServer(harness)
                harness.passTimeAsleep(1800)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        // MARK: The server restarts

        /// **R7** - `sshd` restarts: the master dies and connects are refused for 10 s.
        @Test func r7AnSSHDRestart() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.severConnections()
                harness.host.sshd = .refusing
                harness.host.after(10) { [host = harness.host] in host.sshd = .running }
                Self.changeTheServer(harness)
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// **R8** - the server reboots: `sshd` is down for two minutes, the reboot empties
        /// `~/.cache` so the helper has to be uploaded again, and the location's root is
        /// missing for the first 30 s after `sshd` comes up (a dataset still mounting).
        @Test func r8AServerReboot() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.severConnections()
                harness.host.sshd = .refusing
                harness.host.wipeHelperCache()
                Self.changeTheServer(harness)
                try await harness.run(for: 120)
                harness.host.hideRoot()
                harness.host.sshd = .running
                try await harness.run(for: 30)
                harness.host.restoreRoot()
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        // MARK: The harness checks itself

        /// The checks are not vacuous: a server that stops running the helper is reported,
        /// whatever the agent makes of it. C7 is not part of this: the agent holds the
        /// helper's exec channel for as long as it waits for `ready`, which is the session
        /// count C7 expects at the helper tier.
        @Test func theHarnessReportsAHelperThatNeverReturns() async throws {
            await Self.scenario { harness in
                harness.host.helperNeverReady = true
                harness.host.killHelpers()
                try await harness.run(for: 120)
                let violations = await harness.converged()
                #expect(violations.contains { $0.hasPrefix("C3:") }, "\(violations)")
            }
        }

        /// The server's side of a connection the agent gave up on over a dead link: the
        /// `-O exit` never arrives, so the helper runs on until its wrapper has heard no
        /// heartbeat for 60 s, beside the one the next connection starts. That overlap is
        /// the server's, and C7 holds the agent to one helper per connection, not one per
        /// server.
        @Test func aHelperLeftBehindOnAHalfOpenConnectionRunsOutItsWrapper() async throws {
            await Self.scenario { harness in
                try await harness.run(for: 10)
                harness.host.setLink(.blackhole)
                try await harness.setNetworkPath(false)
                try await harness.run(for: 5)
                #expect(harness.host.liveMasters.isEmpty, "the agent dropped the master")
                #expect(
                    harness.host.helperConnections == [1],
                    "the server never heard the -O exit: \(harness.host.helperConnections)")
                harness.host.setLink(.up)
                try await harness.setNetworkPath(true)
                try await harness.run(for: 70)
                #expect(
                    !harness.host.helperConnections.contains(1),
                    "the wrapper outlived 60 s without a heartbeat: \(harness.host.helperConnections)")
                try await harness.run(for: Self.quiet)
                await Self.expectConverged(harness)
            }
        }

        /// A change the agent was never told about is reported by C4, and the helper that
        /// did not report it by C3.
        @Test func theHarnessReportsAChangeTheAgentMissed() async throws {
            await Self.scenario { harness in
                harness.host.sftp.onChange = nil
                harness.host.writeFile("unseen.txt", text: "never announced\n")
                try await harness.run(for: 5)
                let violations = await harness.converged()
                #expect(violations.contains { $0.hasPrefix("C4: unseen.txt") }, "\(violations)")
                #expect(violations.contains { $0.hasPrefix("C3:") }, "\(violations)")
            }
        }

        /// A helper that goes silent is reported by C3 while the agent keeps it: the
        /// frozen-helper fault is visible to the checks.
        @Test func theHarnessReportsAFrozenHelper() async throws {
            await Self.scenario { harness in
                harness.host.freezeHelpers()
                try await harness.run(for: 5)
                let violations = await harness.converged()
                #expect(violations.contains { $0.hasPrefix("C3:") }, "\(violations)")
            }
        }
    }
}
