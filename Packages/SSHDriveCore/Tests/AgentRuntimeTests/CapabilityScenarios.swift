import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import ServerModel
import Testing

/// Suite N on the agent's side: what the capability report of DESIGN.md section 8.1 is
/// allowed to say about a server (`docs/testing-architecture.md` section 5).
///
/// Half of section 8.1's catalogue is a claim about the **server**, and every line of it
/// is read by the user as the truth about their machine. Two failures are recorded here
/// rather than argued about: a helper that was still going up the wire being reported as a
/// server that "cannot run the remote helper" (2026-09-05), and `fsync@openssh.com` being
/// offered as an `upgrade:` to a Tailscale SSH node, which is Go `pkg/sftp` and has never
/// advertised it in any version (2026-09-08).
extension AgentScenarios {

    @Suite struct CapabilityScenarios {

        /// **N1** - never blame a server for our state.
        ///
        /// Quirks: `SQ-077` (the helper's stream does not survive its connection, and
        /// *nothing* about that is a statement about whether the server can run one),
        /// `SQ-079` (a channel that did not open because the master died is not a refusal
        /// either). Both are our state wearing a server's clothes.
        ///
        /// The window `add` writes its one report in is the window where the ladder has
        /// chosen tier 2 from the probe and the binary is still going up the wire. The
        /// report written there used to reach for the sweep branch's "the server cannot
        /// run the remote helper", which was false for every server that could - and the
        /// first real cask install printed it, ten seconds before `sshdrive status` said
        /// `helper 0.1.0`. So `deploying` is its own state: the sweep level, a `note:`
        /// saying the binary is on its way, and **no `upgrade:` line**, because there is
        /// nothing for the user to do.
        ///
        /// The second half is the one that keeps it fixed: that sentence must be
        /// unreachable from any state of ours. Section 6.4's list of things that really do
        /// mean "not on this server" is no shell, no exec channel, an unsupported arch,
        /// `noexec`, and a hash mismatch after a redeploy - all of them refusals the
        /// server or the account made.
        @Test func n1TheDeployingWindowNeverBlamesTheServer() async throws {
            let harness = try AgentHarness()
            harness.launcher.succeed(probe: Self.shellProbe)
            let location = try await harness.addLocation(nickname: "nas", watchMode: .auto)
            let runtime = try await harness.manager.runtime(for: location)
            // A ladder that has chosen tier 2 and has not deployed anything yet: exactly
            // where `add` writes its report.
            let detector = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: Self.helperCapable, environment: harness.environment)
            #expect(await detector.currentTier() == .helper)

            let report = try await LocationCommands.capabilityReport(
                location: location, runtime: runtime, forceProbe: false, detector: detector)
            let change = try #require(report.features.first { $0.name == "change detection" })
            #expect(change.note == CapabilityReport.deployingNote, "N1: it says `deploying`")
            #expect(change.upgrade == nil, "N1: and no `upgrade:` line goes with it")
            let rename = try #require(report.features.first { $0.name == "rename detection" })
            #expect(rename.note == CapabilityReport.deployingNote)
            #expect(rename.upgrade == nil)
            #expect(
                !Self.text(report).contains(Self.blameSentence),
                "N1: no line of the report blames the server while we are still deploying")

            // The other side of the same rule: the sentence is reachable, and only from a
            // server that really did refuse. A `ForceCommand internal-sftp` account has no
            // shell, so there is no exec channel to deploy over and none of section 6.4's
            // named reasons applies - this is the one state the generic sentence is for,
            // and the ladder is at tier 0 because of it.
            harness.launcher.succeed(probe: Self.shelllessProbe)
            let shellless = try await harness.addLocation(nickname: "sftponly", host: "other")
            let refusedRuntime = try await harness.manager.runtime(for: shellless)
            let pollOnly = ChangeDetector(
                locationID: shellless.id, runtime: refusedRuntime, location: shellless,
                capabilities: ChangeDetectionLadder.ServerCapabilities(),
                environment: harness.environment)
            #expect(await pollOnly.currentTier() == .poll)
            let refused = try await LocationCommands.capabilityReport(
                location: shellless, runtime: refusedRuntime, forceProbe: false,
                detector: pollOnly)
            #expect(
                Self.text(refused).contains(Self.blameSentence),
                "N1: a real refusal is what the sentence is for")

            // Bite-proof. The logic as it stood before 2026-09-05, in one line: anything
            // that is not a running stream is the sweep branch's refusal. Fed the very
            // state the scenario above is about, it produces the false sentence and an
            // `upgrade:` line telling the user to get shell access they already have.
            let asItWas: HelperState = .unavailable(Self.blameSentence)  // "not running" => "cannot run"
            let old = CapabilityReport.make(
                probe: Self.shellProbe, extensions: [], location: location,
                allowsExecChannel: true, probedAt: Date(), cached: false,
                activeTier: "helper", helper: asItWas)
            #expect(Self.text(old).contains(Self.blameSentence), "the bug, reproduced")
            let oldChange = try #require(old.features.first { $0.name == "change detection" })
            #expect(oldChange.upgrade != nil, "and it asked the user to do something about it")

            await harness.manager.dropRuntime(locationID: location.id)
            await harness.manager.dropRuntime(locationID: shellless.id)
        }

        /// **N5** - the report names the server, and `fsync`/`limits` are server facts.
        ///
        /// Quirks: `SQ-036` (the identification string is printed only at `DEBUG1`, so the
        /// collect connection is the only `ssh` that can read it), `SQ-024` (Go `pkg/sftp`
        /// advertises exactly three extensions and no version advertises `fsync` or
        /// `limits`), `SQ-025` (OpenSSH's own `sftp-server` advertises both), `SQ-026`
        /// (Alpine's `internal-sftp` advertises the same set, so nothing degrades there).
        ///
        /// `upgrade: fsync@openssh.com (OpenSSH >= 6.3)` on a Tailscale SSH node asked the
        /// user to replace their SSH server for something no version of the software they
        /// run has ever had. Where the software is **known and is not OpenSSH** the line
        /// keeps its level and states the fact instead; where it is merely unidentified
        /// nothing changes, because an unidentified server may well be an old OpenSSH.
        ///
        /// The wire half - that the fingerprint really is those three names and that the
        /// `debug1:` lines are stripped before the exit classifier sees them - is `K12`
        /// and `N2` in `Tests/ServerModelTests/SFTPWireScenarios.swift`, and is not
        /// repeated here. This is the *report* the two produce.
        @Test func n5TheReportNamesTheServerAndStatesItsFacts() async throws {
            let harness = try AgentHarness()
            let tailscale = try await harness.addLocation(nickname: "ts", host: "ts-node")
            Self.cacheProbe(of: .tailscaleSSH, locationID: tailscale.id)

            let rows = try await harness.control("status", ["name": "ts"])
            let row = try #require((rows["locations"] as? [[String: Any]])?.first)
            let capabilities = try #require(row["capabilities"] as? [String: Any])
            let software = try #require(capabilities["software"] as? [String: Any])
            #expect(software["banner"] as? String == "Tailscale", "N5: SQ-036's string, named")
            #expect(software["sftp"] as? String == "Go pkg/sftp", "N5: SQ-024's fingerprint")
            #expect(software["openSSH"] as? Bool == false)

            for (feature, extensionName) in [
                ("durable writes", "fsync@openssh.com"), ("transfer sizing", "limits@openssh.com"),
            ] {
                let line = try #require(Self.feature(feature, in: capabilities))
                #expect(line["glyph"] as? String == "◐", "N5: the level is still the fallback")
                #expect(
                    line["upgrade"] == nil,
                    "N5: never an `upgrade:` telling a Tailscale user to replace their SSH server")
                let note = try #require(line["note"] as? String)
                #expect(note.contains(extensionName))
                #expect(note.contains("OpenSSH extension"))
                #expect(note.contains("Tailscale"), "N5: it says *which* server does not have it")
            }
            // And the advertised list is in the JSON, so "it did not advertise it" is
            // checkable from the user's own machine rather than believed.
            #expect(
                capabilities["sftpExtensions"] as? [String] == ServerProfile.tailscaleSSH.extensions)

            // The contrast: OpenSSH's own `sftp-server`, where both are simply there.
            for (nickname, profile) in [
                ("deb", ServerProfile.debian), ("owner", ServerProfile.ownerDebian),
            ] {
                let location = try await harness.addLocation(nickname: nickname, host: nickname)
                Self.cacheProbe(of: profile, locationID: location.id)
                let rows = try await harness.control("status", ["name": nickname])
                let row = try #require((rows["locations"] as? [[String: Any]])?.first)
                let capabilities = try #require(row["capabilities"] as? [String: Any])
                #expect(
                    (capabilities["software"] as? [String: Any])?["openSSH"] as? Bool == true,
                    "SQ-025: anything carrying fsync/lsetstat/limits is OpenSSH")
                for feature in ["durable writes", "transfer sizing"] {
                    let line = try #require(Self.feature(feature, in: capabilities))
                    #expect(line["glyph"] as? String == "●", "SQ-025: \(feature) is at its best")
                    #expect(line["note"] == nil, "and there is no fact to state about it")
                    #expect(line["upgrade"] == nil)
                }
            }

            // "Not OpenSSH" and "not identified" are different answers. A server we have
            // not identified keeps section 8.1's original wording, because for all we know
            // it *is* an old OpenSSH that could be upgraded.
            let unknown = try await harness.addLocation(nickname: "mystery", host: "mystery")
            CapabilityCache.storeProbe(
                Self.shellProbe, extensions: [.posixRename],
                advertised: ["posix-rename@openssh.com"], locationID: unknown.id)
            let mystery = try await harness.control("status", ["name": "mystery"])
            let mysteryRow = try #require((mystery["locations"] as? [[String: Any]])?.first)
            let mysteryCapabilities = try #require(mysteryRow["capabilities"] as? [String: Any])
            #expect(
                mysteryCapabilities["software"] == nil,
                "N5: nothing at all rather than a line reading `unknown`")
            let durable = try #require(Self.feature("durable writes", in: mysteryCapabilities))
            #expect(
                (durable["upgrade"] as? String)?.contains("fsync@openssh.com") == true,
                "N5: an unidentified server keeps the upgrade line")
            #expect(durable["note"] == nil)
        }

        /// **N6** - `status` never touches the wire.
        ///
        /// The free-space line of the capability report is the one that could dial: a
        /// `transport.statvfs(.root)` goes through the `ReconnectingTransport`, and section
        /// 6.3's gate holds a call behind a connect attempt for up to the 60 s
        /// authentication deadline, or *starts* one where there is no attempt at all. A
        /// report must neither dial a server the user has not touched nor wait out a
        /// reconnect. Section 8 gives `--probe` as the way to ask for a connection on
        /// purpose, and this is the rest of the command promising not to.
        ///
        /// Three states, because the failure would be different in each: connected (a call
        /// succeeds and costs a round trip), connecting (a call *waits*), and backing off
        /// (a call fails fast, and the free-space line is silently empty rather than the
        /// last known figure).
        @Test func n6StatusNeverDialsAndNeverWaits() async throws {
            let harness = try AgentHarness(clock: VirtualAgentClock())
            let location = try await harness.addLocation(nickname: "nas")
            let runtime = try await harness.manager.runtime(for: location)
            await harness.quiesceConnects()

            // 1. Connected. The probe already paid for the one `statvfs` (`applyConnection`),
            // and `status` may not pay for another.
            let live = try #require(harness.launcher.live)
            #expect(live.statvfsCount == 1, "the free-space figure is taken at connect")
            let statvfsBefore = live.statvfsCount
            let attemptsBefore = harness.launcher.attempts
            let wallBefore = harness.clock.now()

            var rows = try await harness.control("status", ["name": "nas"])
            var row = try #require((rows["locations"] as? [[String: Any]])?.first)
            #expect(row["state"] as? String == "online")
            #expect(live.statvfsCount == statvfsBefore, "N6: status made no statvfs")
            #expect(live.aliveCheckCount == 0, "N6: and no `ssh -O check`")
            #expect(harness.launcher.attempts == attemptsBefore, "N6: and dialled nothing")
            #expect(harness.clock.now() == wallBefore, "N6: and waited for nothing")

            // 2. An attempt in progress. `--connect-hang` is section 6.3 rule 3 on its own:
            // the attempt is parked on the virtual clock and every call that reaches the
            // gate would be held on it, bounded only by the attempt's own deadline.
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            await gate.setFault(
                unreachable: nil, hangMilliseconds: nil, connectHangMilliseconds: 30_000)
            await gate.drop(reason: "the master was killed")
            await harness.settle { harness.clock.sleeperCount > 0 }
            #expect(await gate.isConnected == false)

            let waitedBefore = await gate.waitedCalls
            let gateAttemptsBefore = await gate.attempts
            rows = try await harness.control("status", ["name": "nas"])
            row = try #require((rows["locations"] as? [[String: Any]])?.first)
            #expect(await gate.waitedCalls == waitedBefore, "N6: no call of ours waited on the gate")
            #expect(await gate.attempts == gateAttemptsBefore, "N6: and none started an attempt")
            #expect(harness.clock.now() == wallBefore, "N6: the clock never had to move")
            #expect((row["state"] as? String)?.hasPrefix("offline") == true)

            // 3. The breaker open. Let the parked attempt fail, so the location is backing
            // off with nothing in flight - the state where a call would have failed fast and
            // the report would have had nothing to print.
            harness.launcher.fail()
            await gate.setFault(
                unreachable: nil, hangMilliseconds: nil, connectHangMilliseconds: 0)
            await harness.clock.advanceAndSettle(30)
            await harness.settle { await gate.isConnected == false }
            let failFastBefore = await gate.failFastCalls
            rows = try await harness.control("status", ["name": "nas"])
            row = try #require((rows["locations"] as? [[String: Any]])?.first)
            #expect(
                await gate.failFastCalls == failFastBefore,
                "N6: status did not even reach the gate to be refused by it")
            #expect((row["state"] as? String)?.hasPrefix("offline") == true)

            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **N7** - the free-space figure is taken at probe time and kept.
        ///
        /// It is the one number in section 8.1's report that is a live measurement rather
        /// than a property of the server, which is why it is the line that could dial.
        /// It is captured where a connection already exists - `applyConnection` on every
        /// connection, and `reprobeServer` on `--probe` - and lives in `capabilities.json`
        /// beside the probe. `status` renders what is there, with its age once it is old
        /// enough that the user should not read it as this minute's figure, and `unknown`
        /// where no probe has ever run. A `capabilities.json` written before the key existed
        /// decodes as one that has never been probed, not as an error.
        @Test func n7FreeSpaceIsCapturedAtProbeTimeAndCached() async throws {
            let harness = try AgentHarness(clock: VirtualAgentClock())
            let location = try await harness.addLocation(nickname: "nas")
            let runtime = try await harness.manager.runtime(for: location)
            await harness.quiesceConnects()

            // Captured by the connection, from `FakeTransport`'s 4 GiB / 2 GiB free.
            let stored = try #require(CapabilityCache.freeSpace(locationID: location.id))
            #expect(stored.totalBytes == 4096 * (1 << 20))
            #expect(stored.freeBytes == 4096 * (1 << 19))
            #expect(stored.capturedAt == harness.clock.now())

            var rows = try await harness.control("status", ["name": "nas"])
            var capabilities = try #require(
                ((rows["locations"] as? [[String: Any]])?.first)?["capabilities"] as? [String: Any])
            #expect(
                capabilities["serverFreeSpace"] as? String
                    == stored.sentence(now: harness.clock.now()),
                "N7: what status prints is what the probe stored")
            #expect((capabilities["serverFreeSpace"] as? String)?.contains("as of") == false)

            // Old enough to matter: the line says when it was taken rather than letting the
            // user read a figure from this morning as this minute's.
            let old = ServerFreeSpace(
                freeBytes: stored.freeBytes, totalBytes: stored.totalBytes,
                capturedAt: harness.clock.now() - 2 * 3600)
            CapabilityCache.storeFreeSpace(old, locationID: location.id)
            rows = try await harness.control("status", ["name": "nas"])
            capabilities = try #require(
                ((rows["locations"] as? [[String: Any]])?.first)?["capabilities"] as? [String: Any])
            #expect(
                (capabilities["serverFreeSpace"] as? String)?.contains("(as of 2h ago)") == true,
                "N7: an hour is where the age starts being printed")

            // `--probe` is the one command that may ask the server, so it is what refreshes
            // the figure: the stored timestamp moves to now.
            _ = try await harness.control("status", ["name": "nas", "probe": "true"])
            let refreshed = try #require(CapabilityCache.freeSpace(locationID: location.id))
            #expect(refreshed.capturedAt == harness.clock.now(), "N7: --probe re-took it")
            #expect(refreshed.freeBytes == stored.freeBytes)

            // A `capabilities.json` written before the key existed. It decodes as a probe
            // with no free-space figure, and `status` says so in a word rather than failing.
            let unprobed = try await harness.addLocation(nickname: "old", host: "old")
            Self.cacheProbe(of: .debian, locationID: unprobed.id)
            let raw = try #require(
                try? Data(contentsOf: GroupContainer.capabilitiesURL(locationID: unprobed.id)))
            #expect(
                !String(decoding: raw, as: UTF8.self).contains("freeSpace"),
                "N7: the fixture really is a file written without the field")
            #expect(CapabilityCache.probe(locationID: unprobed.id) != nil, "N7: and still decodes")
            #expect(CapabilityCache.freeSpace(locationID: unprobed.id) == nil)
            rows = try await harness.control("status", ["name": "old"])
            capabilities = try #require(
                ((rows["locations"] as? [[String: Any]])?.first)?["capabilities"] as? [String: Any])
            #expect(
                capabilities["serverFreeSpace"] as? String == ServerFreeSpace.unknownSentence,
                "N7: never probed is `unknown`, not a missing line and not a guess")

            _ = runtime
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **N8** - online and offline come from the gate.
        ///
        /// The other route to the word, `runtime.isConnected()` ->
        /// `SSHBackedTransport.isMasterAlive()` -> `SSHMaster.check()`, spawns
        /// `ssh -O check` and waits up to ten seconds for it *inside the master's actor*:
        /// a cooperative pool thread parked, and every other caller of that master queued
        /// behind it, for one word of one line of `status`. The gate already holds the
        /// connection and the breaker already knows why there is not one, so both halves
        /// of the answer are there for free, in section 8's wording: `online`, or
        /// `offline (<reason>)`.
        @Test func n8TheStateWordComesFromTheGate() async throws {
            let harness = try AgentHarness(clock: VirtualAgentClock())
            let location = try await harness.addLocation(nickname: "nas")
            _ = try await harness.manager.runtime(for: location)
            // The two timers a mounted location carries would otherwise call the transport
            // mid-scenario, and a call that meets a dropped gate connects - which is right,
            // and would put the location back online underneath the word being read
            // (sections 6.4, 6.6).
            await harness.manager.detector(locationID: location.id)?.stop()
            await harness.manager.evictor(locationID: location.id)?.stop()
            await harness.quiesceConnects()
            let gate = try #require(await harness.manager.gate(locationID: location.id))
            let live = try #require(harness.launcher.live)

            #expect(await Self.stateWord(harness, "nas") == "online")
            #expect(live.aliveCheckCount == 0, "N8: nothing spawned an `ssh -O check`")

            // Backing off. The reason is the breaker's own sentence, so the user is told
            // that the location is retrying rather than only that it is down.
            harness.launcher.fail()
            await gate.drop(reason: "the master was killed")
            // The drop reconnects (section 6.1), so the word is read after that attempt has
            // failed rather than while it is still in flight: one call through the gate
            // waits for exactly the attempt the drop started and comes back when the
            // breaker has been told how it went. `isConnected == false` is not that
            // moment - it is true as soon as `drop` returns, with the attempt still
            // running, and the word there is `connecting`, truthfully.
            let transport = ReconnectingTransport(gate: gate, locationID: location.id)
            await #expect(throws: SFTPError.noConnection) { try await transport.readdir(.root) }
            let backingOff = await Self.stateWord(harness, "nas")
            #expect(backingOff.hasPrefix("offline ("), "section 8's wording is unchanged")
            #expect(backingOff.contains("backing off"))
            #expect(live.aliveCheckCount == 0)

            // Stopped until the user acts. Section 6.3 rule 6: an auth failure gets no
            // reconnect schedule at all, and that is the one the user has to be told about.
            harness.launcher.fail(classification: .authenticationFailed, stderr: "Permission denied")
            // The breaker's backoff is also a reconnect schedule (section 6.3 rule 5), so
            // the next attempt is the one the clock brings round - and it is the attempt
            // that meets the refused password.
            await harness.clock.advanceAndSettle(5)
            await harness.settle { await gate.stateSentence().contains("stopped") }
            let stopped = await Self.stateWord(harness, "nas")
            #expect(stopped == "offline (stopped: authenticationFailed)")
            #expect(live.aliveCheckCount == 0, "N8: still nothing spawned")

            await harness.manager.dropRuntime(locationID: location.id)
        }


        /// **N9** - `status` reads the index through its own reader, never through the
        /// writer.
        ///
        /// The index half of keeping `status` off the writer; N6 is the wire half.
        /// `LocationRuntime` is an actor, a directory listing writes its rows in one
        /// **synchronous** SQLite transaction on it (section 5.3), and a row is about
        /// eighteen questions per location - the hidden names, the held rows, the root
        /// set, one `item(identifier:)` per materialized file, the pin tree, and eight
        /// more. Asked on that actor, any of them queues behind a listing of a large
        /// folder.
        ///
        /// Two things are asserted, because either alone would pass for the wrong reason:
        ///
        /// 1. **With a listing in flight**, `status` answers in full and answers
        ///    *correctly* - the same hidden names the writer would have listed, the held
        ///    deletions, the pin tree with its counts, and the cache totals - and the clock
        ///    never moves.
        /// 2. **The writer's connection is not the one that answered.** Every read a
        ///    `status` makes of the index is watched through `SQLiteConnection`'s statement
        ///    observer, which is the writer's; not one of the queries appears on it.
        ///
        /// The second is the load-bearing one. A parked `readdir` suspends
        /// `enumerateChanges` and therefore *releases* the actor, so a scenario in one
        /// process cannot hold the actor the way a real 10,000-row transaction does; what
        /// it can do is prove that `status` asks that actor for none of it.
        @Test func n9StatusReadsTheIndexThroughItsOwnReader() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let runtime = try await harness.manager.runtime(for: location)
            try await harness.manager.addDomain(for: location)
            let fake = try #require(await runtime.transport as? FakeTransport)

            // A tree with something for every line of section 8's report: a pin with files
            // under it, a directory the mass-deletion guard will hold, and a link that
            // leaves the location, which is section 5.4's "not shown".
            try await fake.apply(.createDirectory(path: try RelativePath(string: "Docs"), mode: 0o755))
            for index in 0 ..< 3 {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: "Docs/doc\(index).txt"),
                        contents: Data(repeating: 0x61, count: 100), mode: 0o644))
            }
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "Photos"), mode: 0o755))
            for index in 0 ..< 40 {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: "Photos/p\(index).jpg"),
                        contents: Data("p\(index)".utf8), mode: 0o644))
            }
            try await fake.apply(
                .createSymlink(path: try RelativePath(string: "escape"), target: "/etc/passwd"))

            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let (docs, _) = try await runtime.identifier(forPath: "Docs")
            _ = try await runtime.enumerateItems(container: docs, pageToken: nil)
            let (photos, _) = try await runtime.identifier(forPath: "Photos")
            _ = try await runtime.enumerateItems(container: photos, pageToken: nil)

            // A pin, and the system holding content for the three files under it.
            _ = try await harness.control("pin", ["name": "nas", "path": "Docs"])
            var downloaded: [String] = []
            for index in 0 ..< 3 {
                downloaded.append(try await runtime.identifier(forPath: "Docs/doc\(index).txt").0)
            }
            harness.replica.setMaterialized(downloaded, locationID: location.id)
            // The extension's own signal, which is what publishes the set `status` reads
            // rather than draining a third enumerator for it (section 6.5).
            await harness.manager.materializedItemsChanged(locationID: location.id)

            // 30 of 40 gone: section 6.4's guard holds them rather than reporting them.
            for index in 0 ..< 30 {
                try await fake.apply(
                    .delete(path: try RelativePath(string: "Photos/p\(index).jpg"), recursive: false))
            }
            let application = await runtime.runPollCycle(fullSweep: true)
            #expect(application.held == 30, "the guard is holding, so status has something to print")

            let viaWriter = try await runtime.notShown().map(\.path)
            #expect(!viaWriter.isEmpty, "the escaping link is recorded and not shown")

            // A listing, parked in the middle of its `readdir`.
            let parked = Counter()
            let clock = harness.clock
            await fake.setOnReaddir { _ in
                parked.bump()
                await clock.sleep(seconds: 3600)
            }
            let listing = Task { try await runtime.enumerateChanges(container: photos) }
            await harness.settle { parked.value > 0 }
            #expect(parked.value > 0, "N9: the listing is in flight")

            // Everything the writer's connection is asked while `status` runs.
            let statements = ListingScenarios.Statements()
            await runtime.observeStatements { sql, depth in statements.record(sql, depth) }
            let wallBefore = harness.clock.now()
            let materializedBefore = harness.replica.callsMatching {
                if case .materialized = $0 { return true }
                return false
            }.count

            let rows = try await harness.control("status", ["name": "nas"])
            await runtime.observeStatements(nil)

            let row = try #require((rows["locations"] as? [[String: Any]])?.first)
            #expect(harness.clock.now() == wallBefore, "N9: status waited for nothing")
            #expect(row["indexUnavailable"] == nil, "N9: the index answered")

            let notShown = try #require(row["notShown"] as? [[String: Any]])
            #expect(
                Set(notShown.compactMap { $0["path"] as? String }) == Set(viaWriter),
                "N9: the reader lists exactly the names the writer would have")
            #expect((notShown.first?["reason"] as? String ?? "").isEmpty == false)

            let held = try #require(row["heldDeletions"] as? [[String: Any]])
            #expect(held.count == 30, "N9: the held deletions come from the reader")

            let pins = try #require(row["pins"] as? [[String: Any]])
            let docsPin = try #require(pins.first { $0["path"] as? String == "Docs" })
            #expect(docsPin["state"] as? String == "pinned")
            #expect(docsPin["files"] as? Int == 3)
            #expect(docsPin["downloadedFiles"] as? Int == 3, "N9: from the published set")

            let cache = try #require(row["cache"] as? [String: Any])
            #expect(cache["files"] as? Int == 3)
            #expect(cache["bytes"] as? Int64 == 300)
            #expect(cache["keptFiles"] as? Int == 3, "the three under the pin are kept")

            let watch = try #require(row["watch"] as? [String: Any])
            #expect((watch["roots"] as? Int ?? 0) > 0, "N9: the root set comes from the reader")

            // The load-bearing half: none of that touched the writer.
            let sql = statements.all().map(\.sql)
            #expect(
                !sql.contains { $0.contains("FROM held") },
                "N9: the held rows were not read on the writer's connection")
            #expect(
                !sql.contains { $0.contains("pin_state != 0") },
                "N9: nor the pin markers")
            #expect(
                !sql.contains { $0.contains("FROM items ORDER BY path") },
                "N9: nor the whole item table the hidden-name list is filtered out of")
            #expect(
                !sql.contains { $0.contains("FROM roots") }, "N9: nor the root set")
            #expect(
                materializedBefore
                    == harness.replica.callsMatching {
                        if case .materialized = $0 { return true }
                        return false
                    }.count,
                "N9: and status drained no third materialized enumerator (section 6.5)")

            // And the listing that was held finishes normally once it is let go.
            await harness.clock.advanceAndSettle(3600)
            _ = try await listing.value
            #expect(parked.value >= 1, "N9: the listing really did run through the hold")
            await fake.setOnReaddir(nil)
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **N10** - one location that has stopped answering costs its own row, not the
        /// report.
        ///
        /// `status` with no name is a report about every location, and section 8's output
        /// prints them in the order `config.json` holds. Built one after another with no
        /// bound, a fourth location's wedged File Provider call - S1 measured
        /// `remove(domain)` not returning within three minutes - takes the whole command
        /// out through the CLI's own timeout and the user learns nothing about the three
        /// that are fine.
        ///
        /// So: the sections run concurrently, each under `Deadline.statusSeconds` on the
        /// agent's own clock, and a section that runs out prints its row with a note in
        /// place of what it could not read.
        @Test func n10AStuckLocationPrintsANoteAndNotTheReport() async throws {
            let harness = try AgentHarness()
            let stuck = try await harness.addLocation(nickname: "nas", backend: .fake)
            let healthy = try await harness.addLocation(nickname: "spare", backend: .fake)

            // The materialized enumerator is the one File Provider call a `status` section
            // still makes for a location nothing has published a set for, and it is the
            // shape of call that wedges. Parked for `nas` and only for `nas`.
            let clock = harness.clock
            let stuckID = stuck.id
            harness.replica.setOnMaterializedIdentifiers { locationID in
                guard locationID == stuckID else { return }
                await clock.sleep(seconds: 3600)
            }

            for location in [stuck, healthy] {
                _ = try await harness.manager.runtime(for: location)
                try await harness.manager.addDomain(for: location)
            }

            let report = Task { try await harness.control("status", [:]) }
            // Both sections are in flight and the stuck one is parked on the clock: three
            // sleepers, the two deadlines and the parked call.
            await harness.settle { harness.clock.sleeperCount >= 3 }
            // Then let the healthy section run out. Its remaining work is a handful of
            // in-memory reads, and `settle` is the suite's idiom for "let what was started
            // run to a standstill"; a cancelled sleep is not removed from the driven
            // clock's waiters, so the sleeper count cannot say it for us.
            await harness.settle(timeoutSeconds: 1) { false }
            await harness.clock.advanceAndSettle(Deadline.statusSeconds)

            let rows = try #require(try await report.value["locations"] as? [[String: Any]])
            #expect(rows.count == 2)
            #expect(
                rows.map { $0["name"] as? String } == ["nas", "spare"],
                "N10: printed in the order config.json holds, whatever order they finished in")

            let stuckRow = rows[0]
            let note = try #require(stuckRow["note"] as? String)
            #expect(note.contains("did not answer within 20 s"), "N10: the row says so")
            #expect(stuckRow["name"] as? String == "nas")
            #expect(stuckRow["destination"] != nil, "N10: what cost nothing is still printed")

            let healthyRow = rows[1]
            #expect(healthyRow["note"] == nil, "N10: the healthy location is unaffected")
            #expect(healthyRow["state"] as? String == "online")
            #expect(healthyRow["cache"] != nil, "N10: and is reported in full")
            #expect(healthyRow["watch"] != nil)

            harness.replica.setOnMaterializedIdentifiers(nil)
            await harness.clock.advanceAndSettle(3600)
            for location in [stuck, healthy] {
                await harness.manager.dropRuntime(locationID: location.id)
            }
        }

        /// **N11** - a rebuild in progress, and an index that is not there yet.
        ///
        /// Section 5.3's restore sets `meta.reconciling` for the whole replica walk, and
        /// section 5.2 makes any read of the index during it answer "unreachable", never
        /// "no such item". `status` is a read of the index like any other, so it says the
        /// index is being rebuilt and prints the rest of the row - it does not print zeroes,
        /// which would read as facts about the server, and it does not fail the command.
        ///
        /// The second half is the state a location is in before it has ever started: the
        /// file is not there, which is not an error and is not permanent.
        @Test func n11AReconcilingIndexAndOneThatIsNotThereYet() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let runtime = try await harness.manager.runtime(for: location)
            try await harness.manager.addDomain(for: location)
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)

            // Section 5.3's flag, set the way `IndexReconcile` sets it.
            let writer = try harness.indexWriter(locationID: location.id)
            try writer.setReconciling(true)

            let rows = try await harness.control("status", ["name": "nas"])
            let row = try #require((rows["locations"] as? [[String: Any]])?.first)
            let unavailable = try #require(row["indexUnavailable"] as? String)
            #expect(unavailable.contains("rebuilt"), "N11: the row says why, in words")
            #expect((row["notShown"] as? [[String: Any]])?.isEmpty == true)
            #expect((row["heldDeletions"] as? [[String: Any]])?.isEmpty == true)
            #expect(row["cache"] == nil, "N11: no cache totals are invented for a rebuild")
            #expect(row["pins"] == nil)
            #expect(row["state"] as? String == "online", "N11: the rest of the row still prints")
            #expect(row["channels"] != nil)

            try writer.setReconciling(false)
            let after = try await harness.control("status", ["name": "nas"])
            let afterRow = try #require((after["locations"] as? [[String: Any]])?.first)
            #expect(afterRow["indexUnavailable"] == nil, "N11: and it lifts by itself")
            #expect(afterRow["cache"] != nil)

            // A location that has never started has no `index.sqlite` at all. Not an error,
            // and not remembered: the writer creates the file when it starts, and the next
            // read opens it.
            let missing = harness.container.appendingPathComponent("nowhere/index.sqlite")
            let reader = StatusIndexReader(locationID: "unstarted", path: missing.path)
            let empty = await reader.report(hiddenReasons: [:], materialized: [])
            #expect(empty.unavailable == "this location has no index yet")
            #expect(empty.pins.isEmpty)
            #expect(empty.cacheCandidates.isEmpty)

            try FileManager.default.createDirectory(
                at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try IndexWriter(path: missing.path)
            let born = await reader.report(hiddenReasons: [:], materialized: [])
            #expect(born.unavailable == nil, "N11: the same reader opens it once it exists")

            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// A counter a `@Sendable` hook can bump from wherever it runs.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
            func bump() { lock.lock(); count += 1; lock.unlock() }
        }

        // MARK: fixtures

        /// The `state` word of one `status` row, which is what section 8 prints after the
        /// destination.
        static func stateWord(_ harness: AgentHarness, _ name: String) async -> String {
            let rows = try? await harness.control("status", ["name": name])
            return ((rows?["locations"] as? [[String: Any]])?.first)?["state"] as? String ?? ""
        }

        /// The sentence that may only ever come from a server's own refusal.
        static let blameSentence = "the server cannot run the remote helper"

        /// A server the probe found a shell, a GNU `find` and a cache directory on: the
        /// shape every line of the report has something to say about.
        static var shellProbe: ServerProbe.Result {
            var probe = ServerProbe.Result()
            probe.uname = "Linux x86_64"
            probe.home = "/home/alec"
            probe.description = "uid=1000(alec) gid=1000(alec) groups=1000(alec)"
            probe.identity = ServerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [1000])
            probe.findFlavour = "gnu"
            probe.findTakesCmin = true
            probe.findTakesPrintf = true
            probe.checksumTool = "sha256sum"
            probe.cacheDirectory = "/home/alec/.cache/sshdrive"
            return probe
        }

        /// A `ForceCommand internal-sftp` account: the probe got no shell, so there is no
        /// exec channel, no sweep and no helper - a refusal the *server* made.
        static var shelllessProbe: ServerProbe.Result {
            var probe = ServerProbe.Result()
            probe.failure = "no shell access (ForceCommand)"
            return probe
        }

        /// A server that can run the helper as far as the probe can tell, so `auto` offers
        /// tier 2 and the deployment is the only thing that can refute it.
        static let helperCapable = ChangeDetectionLadder.ServerCapabilities(
            hasExecChannel: true, hasFind: true, takesCmin: true, takesPrintf: true,
            helperAvailable: true, helperEnabledForLocation: true)

        /// `capabilities.json` as one connection to this server would have left it: the
        /// probe, the extension set it advertised, and the identification string the
        /// collect connection read (`SQ-036`).
        static func cacheProbe(of profile: ServerProfile, locationID: String) {
            CapabilityCache.storeProbe(
                shellProbe, extensions: SFTPExtensionNames.parse(profile.extensions),
                advertised: profile.extensions, locationID: locationID)
            CapabilityCache.storeServerVersion(profile.identificationString, locationID: locationID)
        }

        static func feature(_ name: String, in capabilities: [String: Any]) -> [String: Any]? {
            (capabilities["features"] as? [[String: Any]])?.first { $0["feature"] as? String == name }
        }

        /// Every word the report would print, as one string: the levels, the `upgrade:`
        /// lines and the `note:` lines together, because "unreachable" has to mean from
        /// any of them.
        static func text(_ report: CapabilityReport) -> String {
            report.features.map {
                [$0.name, $0.level, $0.upgrade ?? "", $0.note ?? "", $0.consider ?? ""]
                    .joined(separator: " ")
            }.joined(separator: "\n")
        }
    }
}
