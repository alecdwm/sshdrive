import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Testing
import XPCProtocols

/// Suite P on the agent's side: the login item after a bundle replacement, the window
/// `unregister()` returns inside, and the nickname that renames a domain in place
/// (`docs/design/testing.md` section 5).
///
/// These are the `VM`-anchored ones. What runs here is the **state machine** our code
/// reasons about; that LaunchServices and `SMAppService` really behave this way is
/// `MQ-062`/`MQ-063`, measured on the VM (2026-09-05) and recorded in `docs/quirks/`.
extension AgentScenarios {

    @Suite struct LifecycleScenarios {

        /// **P1** - the login item after a replacement.
        ///
        /// Registration is idempotent but not self-repairing: once the bundle has been deleted
        /// and put back (a Homebrew upgrade, or any `rm -rf` plus copy), launchd's
        /// background-task record still names the old bundle and every spawn fails with "Could
        /// not find and/or execute program specified by service", while `register()` keeps
        /// returning success because the item is still, as far as it is concerned, enabled.
        /// Only `unregister()` clears the record.
        @Test func p1RegisterAloneDoesNotRepairAReplacedBundle() async {
            let loginItem = FakeLoginItem()
            let launchd = FakeLaunchd()
            let clock = VirtualAgentClock(autoAdvance: true)

            AgentLifecycle.register(loginItem: loginItem)
            #expect(loginItem.status() == "enabled")

            loginItem.markBundleReplaced()
            AgentLifecycle.register(loginItem: loginItem)
            #expect(loginItem.status() == "enabled", "P1: it still *says* enabled")
            #expect(loginItem.isBroken, "P1: register() alone does not repair it")

            let outcome = await AgentLifecycle.unregisterAndWait(
                loginItem: loginItem, launchd: launchd, uid: 501, clock: clock)
            #expect(outcome.unregistered)
            #expect(!loginItem.isBroken, "P1: only the unregister path clears the record")
            AgentLifecycle.register(loginItem: loginItem)
            #expect(loginItem.status() == "enabled")
            #expect(loginItem.calls == [.register, .register, .unregister, .register])
        }

        /// **P2** - `unregister` waits for launchd.
        ///
        /// `unregister()` returns, and `SMAppService.status` reports `notRegistered`, before
        /// launchd has dropped the job. A `register()` that lands inside that window leaves the
        /// job holding a launch constraint captured from the previous bundle's signature: every
        /// spawn dies with `Launch Constraint Violation`, launchd retries on a 10 s throttle for
        /// ever, and the mach service never comes back. `SMAppService.status` cannot see this,
        /// so the job itself is asked - `launchctl print` answers non-zero once it is gone.
        @Test func p2TheUnregisterRolePollsUntilTheJobIsGone() async {
            let loginItem = FakeLoginItem()
            let launchd = FakeLaunchd(probesBeforeGone: 7)
            let clock = VirtualAgentClock(autoAdvance: true)

            let outcome = await AgentLifecycle.unregisterAndWait(
                loginItem: loginItem, launchd: launchd, uid: 501, clock: clock)
            #expect(outcome.unregistered)
            #expect(outcome.gone, "P2: it waited for launchd, not for SMAppService")
            #expect(launchd.probes == 8, "seven answers of yes, then the one that says no")
            #expect(
                loginItem.status() == "not registered",
                "the status said this from the first probe, which is exactly why it is not the test")

            // And it gives up rather than blocking the cask's postflight for ever.
            let stuck = FakeLaunchd(probesBeforeGone: 10_000)
            let slow = await AgentLifecycle.unregisterAndWait(
                loginItem: FakeLoginItem(), launchd: stuck, uid: 501, clock: clock, attempts: 150)
            #expect(slow.unregistered)
            #expect(!slow.gone, "P2: 30 s and then it says so")
            #expect(stuck.probes == 150)
        }

        /// **P1**, the other half - the upgrade handover never takes a half-copied bundle.
        ///
        /// docs/design/packaging.md: the agent waits until the bundle at its path is readable, its
        /// `Info.plist` parses, and its main executable is a **different inode** from the one it
        /// is running. The inode test is what makes a `brew reinstall` of the same version
        /// terminate: `ditto` of an identical tree still produces a new file.
        @Test func p1TheHandoverWaitsForAWholeBundle() async {
            let bundle = FakeBundle()
            let executable = bundle.executableURL
            let bundlePath = AgentLifecycle.bundleURL(forExecutable: executable)
            bundle.setInode(1000, atPath: executable.path)

            // Same inode: nothing has been replaced.
            #expect(
                !AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))

            // A new inode, but the Info.plist is not there yet - the copy is half done.
            bundle.setInode(1001, atPath: executable.path)
            #expect(
                !AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))

            // Someone else's bundle at our path is not ours to hand over to.
            bundle.setBundleIdentifier("com.example.other", atPath: bundlePath.path)
            #expect(
                !AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))

            bundle.setBundleIdentifier(SSHDriveIdentifiers.appBundleID, atPath: bundlePath.path)
            #expect(
                AgentLifecycle.replacementIsReady(
                    executable: executable, bundle: bundlePath, originalInode: 1000,
                    inspector: bundle))
        }

        /// **P8** - a nickname renames the domain in place.
        ///
        /// Measured 2026-09-05: `add(domain)` with the identifier the system already holds and a
        /// new `displayName` renames the domain in place (`MQ-051`). Nothing is removed first -
        /// deliberately, since removing the domain is exactly what would throw the cache and the
        /// pending uploads away - so the materialized set and the pending upload are untouched
        /// and nothing is re-fetched.
        @Test func p8ANicknameRenamesTheDomainInPlace() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas")
            _ = try await harness.manager.runtime(for: location)
            try await harness.manager.addDomain(for: location)

            harness.replica.setMaterialized(["item-1", "item-2", "item-3", "item-4"],
                                            locationID: location.id)
            harness.replica.setPending(["item-5"], locationID: location.id)
            harness.replica.resetCalls()

            let report = try await harness.control(
                "set", ["name": "nas", "key": "nickname", "value": "photos"])
            #expect(report["changed"] as? Bool == true)
            #expect(report["name"] as? String == "photos")

            let domains = harness.replica.domainList
            #expect(domains.count == 1, "P8: one domain, renamed - not removed and re-added")
            #expect(domains.first?.identifier == location.id, "P8: the same identifier")
            #expect(domains.first?.displayName == "photos")
            #expect(
                !harness.replica.calls.contains { if case .removeDomain = $0 { return true } else { return false } },
                "P8: nothing is removed first, which is what keeps the cache")

            let materialized = await harness.replica.materializedIdentifiers(locationID: location.id)
            #expect(materialized?.count == 4, "P8: the materialized set is unchanged")
            let pending = await harness.replica.pendingIdentifiers(locationID: location.id)
            #expect(pending == ["item-5"], "P8: the pending upload is still pending")
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **P4** - SIGTERM exits 0, and `agent stop` shuts every master.
        ///
        /// Quirks: `SQ-043` (a restarted location can hold **two** masters, and the second
        /// runs with no control socket at all, so nothing socket-based can see it),
        /// `SQ-044` (a master whose socket has already been unlinked cannot be reached by
        /// `ssh -O exit` at all - only its pid can), `SQ-074` (a name-only sweep of
        /// `$TMPDIR` would delete the package's own test databases, so each candidate is
        /// `lstat`ed for `S_IFSOCK`), `SQ-075` (`pgrep` counts zombies, so "did I kill it"
        /// is not answerable from `pgrep` alone). `MQ-062` is what a wrong exit status
        /// costs: launchd restarts the *old* bundle and `register()` will not repair it.
        ///
        /// Two ways of asking the same question, and they must not be two answers. The
        /// cask's `uninstall` stanza sends TERM; `sshdrive agent stop` is the CLI. Both run
        /// `AgentLifecycle.shutdownAndExit`: every location's master down first, then exit
        /// **0**, because the plist sets `KeepAlive` with `SuccessfulExit` false and the
        /// default disposition for TERM is death by signal - which launchd reads as a crash
        /// and restarts at once, from whatever bundle is at the path, which mid-upgrade is
        /// the old one about to be deleted.
        ///
        /// The `ssh` half of the shutdown - `-O exit`, then the pid from `-O check`, then
        /// the argv match for a master with no socket - is `K5` and `K6` in
        /// `Tests/ServerModelTests/MasterScenarios.swift`, against the `FakeSSH` stub. What
        /// is asserted here is the agent-side orchestration: that the shutdown reaches
        /// every location, that the sweep runs after every transport is down and not
        /// before, and that the exit status is 0.
        @Test func p4TerminationShutsEveryMasterAndExitsZero() async throws {
            let harness = try AgentHarness()
            let first = try await harness.addLocation(nickname: "nas")
            let second = try await harness.addLocation(nickname: "backups", host: "other")
            _ = try await harness.manager.runtime(for: first)
            _ = try await harness.manager.runtime(for: second)
            // The two timers a mounted location carries would otherwise have a cycle in
            // flight during the shutdown, and a transport call from one legitimately
            // connects - which is right, and is not what this scenario is about.
            for location in [first, second] {
                await harness.manager.detector(locationID: location.id)?.stop()
                await harness.manager.evictor(locationID: location.id)?.stop()
            }
            await harness.quiesceConnects()
            let masters = harness.launcher.connections
            #expect(masters.count == 2, "two locations, two masters")

            // The order is the rule: an exit that came first would leave both `ssh -N`
            // processes holding connections, with control sockets the next start unlinks
            // out from under them.
            let mastersDownAtExit = OrderLatch()
            harness.endpoint.onTerminate { _ in
                mastersDownAtExit.set(masters.allSatisfy { $0.shutdownCount == 1 })
            }

            let summary = await AgentLifecycle.shutdownAndExit(
                reason: "SIGTERM from the cask's uninstall stanza", manager: harness.manager,
                environment: harness.environment)

            #expect(
                harness.endpoint.statuses == [AgentLifecycle.exitStatus],
                "P4: one exit, status 0 - anything else is a crash to launchd")
            #expect(AgentLifecycle.exitStatus == 0)
            #expect(summary.locations == 2, "P4: every location, not the ones that answered")
            #expect(summary.gates == 2)
            #expect(masters.allSatisfy { $0.shutdownCount == 1 }, "P4: every master shut down")
            #expect(mastersDownAtExit.value == true, "P4: and they were down *before* the exit")
            #expect(
                summary.straySweepRan,
                "P4: then the argv sweep - SQ-043's second master and SQ-044's unlinked socket")

            // The `agent stop` half of `K6`, from the agent's side. One location has been
            // restarted, so it holds a master the agent has lost track of: the first
            // connection died without an `-O exit` (`SQ-044`'s unlinked socket is the same
            // shape) and a second took its place. `agent stop` replies first - the CLI is
            // waiting on it and `-O exit` against an unreachable server takes seconds - and
            // the exit still follows.
            let stopHarness = try AgentHarness()
            let restarted = try await stopHarness.addLocation(nickname: "nas")
            _ = try await stopHarness.manager.runtime(for: restarted)
            await stopHarness.manager.detector(locationID: restarted.id)?.stop()
            await stopHarness.manager.evictor(locationID: restarted.id)?.stop()
            let gate = try #require(await stopHarness.manager.gate(locationID: restarted.id))
            stopHarness.launcher.live?.killMaster()
            await gate.drop(reason: "the master was killed")
            // The second *master*, not the second attempt: the launcher counts an attempt
            // when it starts one and hands the connection over when it is finished, so a
            // scenario that waits for the count reads `connections` while the master it
            // wants is still being made.
            await stopHarness.settle { stopHarness.launcher.connections.count == 2 }
            await stopHarness.quiesceConnects()
            let restartedMasters = stopHarness.launcher.connections
            #expect(restartedMasters.count == 2, "the location holds a second master")

            let reply = try await stopHarness.control("agent.stop")
            #expect(reply["stopping"] as? Bool == true, "the reply is sent first")
            await stopHarness.settle { !stopHarness.endpoint.statuses.isEmpty }
            #expect(
                stopHarness.endpoint.statuses == [AgentLifecycle.exitStatus],
                "P4: `agent stop` takes exactly the same path as TERM")
            #expect(
                restartedMasters.allSatisfy { $0.shutdownCount == 1 },
                "P4: every master of every location, the one a restart left behind included")
            // What reaches a master this agent can no longer name is the argv sweep, and
            // it runs after every transport above is down and only there: a master the
            // agent still means to use looks exactly like a stray one. The kill itself -
            // `-O exit`, then the pid from `-O check`, then the argv match - is `K5`/`K6`.
            let stopSummary = await stopHarness.manager.shutdownAll()
            #expect(stopSummary.straySweepRan)
            #expect(stopSummary.locations == 0, "and by then there is nothing left to shut down")
        }

        /// `remove --keep-files` removes the domain in the system's preserve-downloaded-data
        /// mode and reports the folder the system moved the files to; a plain `remove`
        /// removes everything and reports no folder (docs/design/cli.md).
        @Test func removeKeepFilesPreservesDownloadedDataAndReportsWhere() async throws {
            let harness = try AgentHarness()
            let kept = try await harness.addLocation(nickname: "photos")
            let gone = try await harness.addLocation(nickname: "scratch", host: "other")
            try await harness.manager.addDomain(for: kept)
            try await harness.manager.addDomain(for: gone)
            harness.replica.resetCalls()

            let keptReport = try await harness.control(
                "remove", ["name": "photos", "keepFiles": "true", "force": "true"])
            #expect(keptReport["removed"] as? [String] == ["photos"])
            #expect(
                harness.replica.calls.contains(
                    .removeDomain(identifier: kept.id, mode: .preserveDownloadedUserData)),
                "--keep-files asks for the preserve-downloaded-data mode")
            let preserved = keptReport["preserved"] as? [[String: String]] ?? []
            let expected = harness.replica.preservedPath(
                for: ReplicaDomain(identifier: kept.id, displayName: kept.displayName))
            #expect(preserved == [["name": "photos", "path": expected]],
                    "the folder the system chose is reported")

            harness.replica.resetCalls()
            let goneReport = try await harness.control(
                "remove", ["name": "scratch", "force": "true"])
            #expect(goneReport["removed"] as? [String] == ["scratch"])
            #expect(
                harness.replica.calls.contains(
                    .removeDomain(identifier: gone.id, mode: .removeAll)),
                "a plain remove throws the cache away")
            #expect((goneReport["preserved"] as? [[String: String]])?.isEmpty == true)
            #expect(harness.replica.domainList.isEmpty)
        }

        /// **P9** - `add` waits for the first deployment.
        ///
        /// Quirks: `SQ-077` (the helper's stream does not survive its connection, and the
        /// deployment goes with it - so "nothing has settled" is an ordinary state and not
        /// a server's answer), `SQ-021` (a `MaxSessions 2` server has one spare channel and
        /// the helper is what does not get it, which is one of the refusals the wait can
        /// end on).
        ///
        /// `add` prints one capability report and the user reads it as the truth about this
        /// server (docs/design/cli.md). The helper is deployed by the first change-detection
        /// cycle, which starts with the location, so the report would otherwise be written
        /// in the window where the tier has been chosen and the binary is still going up
        /// the wire - and that report described a sweep and blamed the server for it, ten
        /// seconds before `sshdrive status` said `helper 0.1.0` (2026-09-05). So the upload
        /// sentence is printed first, the wait happens, and the report comes last.
        ///
        /// The wait must be **bounded**: a server that will never answer costs `add` a few
        /// seconds and nothing more. That bound is `HelperSettle.addSeconds`, and it is
        /// measured on the injected clock here, so this scenario costs no real time at all.
        @Test func p9AddWaitsBoundedForTheFirstDeployment() async throws {
            let resources = try Self.helperResources()
            defer { try? FileManager.default.removeItem(at: resources) }
            let harness = try AgentHarness()
            harness.bundle.helperResourcesURL = resources
            AgentRuntimeBootstrap.install(environment: harness.environment)
            defer {
                // The manifest is process-wide; put it back or every later scenario in the
                // suite would find a helper this build does not ship.
                harness.bundle.helperResourcesURL = nil
                AgentRuntimeBootstrap.install(environment: harness.environment)
            }
            harness.launcher.succeed(probe: CapabilityScenarios.shellProbe)
            let location = try await harness.addLocation(nickname: "nas", watchMode: .auto)
            let runtime = try await harness.manager.runtime(for: location)
            let detector = try #require(await harness.manager.detector(locationID: location.id))
            // The cycle loop is not what this is about; `settleHelper` drives the
            // deployment itself.
            await detector.stop()
            await harness.manager.evictor(locationID: location.id)?.stop()
            await harness.quiesceConnects()

            let relay = RecordingRelay()
            harness.clock.autoAdvance = true
            let addReport = await LocationCommands.firstDeploymentReport(
                location: location, runtime: runtime, detector: detector, relay: relay)
            harness.clock.autoAdvance = false

            // docs/design/change-detection.md: the upload sentence names the directory the probe chose, and it
            // is said before the upload rather than after it.
            let notice = try #require(addReport.helperNotice)
            #expect(notice.contains(CapabilityScenarios.shellProbe.cacheDirectory))
            #expect(
                relay.noteIndex(containing: "upload a small helper binary") == 0,
                "P9: the sentence is the first thing the terminal is told")
            let capabilities = try #require(addReport.capabilities)
            let addFeature = try #require(
                CapabilityScenarios.feature("change detection", in: capabilities))

            // "`status` ten seconds later agrees with it": the same ladder, the same
            // sentence. A report that disagreed with the `status` a user runs a moment
            // later is the failure this scenario is named for.
            harness.clock.advance(10)
            let rows = try await harness.control("status", ["name": "nas"])
            let row = try #require((rows["locations"] as? [[String: Any]])?.first)
            let statusCapabilities = try #require(row["capabilities"] as? [String: Any])
            let statusFeature = try #require(
                CapabilityScenarios.feature("change detection", in: statusCapabilities))
            #expect(
                statusFeature["note"] as? String == addFeature["note"] as? String,
                "P9: `add` and `status` say the same thing about the same connection")
            #expect(
                (statusFeature["note"] as? String ?? "")
                    .contains(CapabilityScenarios.blameSentence) == false,
                "P9: and neither of them blames the server (N1)")

            // The bound. With nothing there to deploy over, nothing settles - `SQ-077`'s
            // ordinary case - and what ends the wait is the deadline and only the deadline.
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            await gate.drop(reason: "the connection went while the helper was going up",
                            reconnect: false)
            let waiting = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: CapabilityScenarios.helperCapable, environment: harness.environment)
            // The whole of `add`'s tail this time, so the order and the bound are measured
            // together: the clock is read at the moment the sentence is relayed, and the
            // wait is what moves it.
            let slowRelay = RecordingRelay()
            let clock = harness.clock
            let noticeAt = ClockStamp()
            slowRelay.onNote { _ in noticeAt.set(clock.now()) }
            let before = harness.clock.now()
            harness.clock.autoAdvance = true
            let timedOut = await LocationCommands.firstDeploymentReport(
                location: location, runtime: runtime, detector: waiting, relay: slowRelay)
            harness.clock.autoAdvance = false
            let elapsed = harness.clock.now() - before

            #expect(slowRelay.notes.count == 1, "P9: one sentence, and the report is the reply")
            #expect(
                noticeAt.value == before,
                "P9: the sentence is said before the wait, not after it")
            #expect(
                elapsed <= HelperSettle.addSeconds + ChangeDetector.settlePollSeconds,
                "P9: bounded by HelperSettle.addSeconds (\(elapsed) s of model time)")
            #expect(elapsed >= HelperSettle.addSeconds, "P9: and it really did wait for it")

            // And what it prints when the wait runs out is `deploying` - never a claim
            // about the server that is not true yet (`N1`).
            let timedOutCapabilities = try #require(timedOut.capabilities)
            let line = try #require(
                CapabilityScenarios.feature("change detection", in: timedOutCapabilities))
            #expect(line["note"] as? String == CapabilityReport.deployingNote)
            #expect(line["upgrade"] == nil)

            // Bite-proof: the rule that ends the wait, and the version of it that does
            // not. An `add` whose wait had no bound would sit here for as long as the
            // server stayed silent, holding the terminal that is waiting on the reply.
            #expect(
                HelperSettle.step(
                    tierIsHelper: true, streamRunning: false, refusal: nil,
                    elapsed: HelperSettle.addSeconds) == .giveUp)
            #expect(
                HelperSettle.step(
                    tierIsHelper: true, streamRunning: false, refusal: nil,
                    elapsed: HelperSettle.addSeconds - 0.1) == .wait)
            #expect(
                HelperSettle.step(
                    tierIsHelper: true, streamRunning: false, refusal: nil,
                    elapsed: 86_400, timeout: .infinity) == .wait,
                "the unbounded version, for contrast: it never ends")
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// A `Contents/Resources/helper/` with a manifest in it, so the probe's
        /// `uname -sm` has a binary to match and the location is one where a helper would
        /// really be deployed (docs/design/packaging.md: CI records every hash into the manifest).
        static func helperResources() throws -> URL {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sshdrive-helper-resources-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let manifest = HelperManifest(
                version: "0.1.0",
                binaries: [
                    HelperManifest.Binary(
                        os: "linux", arch: "x86_64",
                        file: "sshdrive-helper-0.1.0-linux-x86_64",
                        sha256: String(repeating: "a", count: 64), size: 443_000)
                ])
            try JSONEncoder().encode(manifest).write(
                to: directory.appendingPathComponent(HelperManifest.fileName))
            return directory
        }
    }
}

/// One bit, written from whichever thread the hook ran on and read from the test.
/// `P4` uses it for the only thing that cannot be seen afterwards: what was already true
/// at the moment the agent asked to exit.
final class ClockStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double?

    func set(_ value: Double) { lock.lock(); if stored == nil { stored = value }; lock.unlock() }
    var value: Double? { lock.lock(); defer { lock.unlock() }; return stored }
}

final class OrderLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}
