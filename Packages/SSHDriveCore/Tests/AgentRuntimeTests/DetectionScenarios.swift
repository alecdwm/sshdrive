import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import Testing
import XPCProtocols

/// Suite H's agent-side half: the root set's rotation and caps, what counts as a touch,
/// the cycle that eats its own interval, and the mass-deletion guard's thresholds
/// (`docs/design/testing.md` section 5).
///
/// H1-H3, H6 and the sweep's own dialect live in `Tests/ServerModelTests/SweepScenarios.swift`,
/// against a real shell and a real `find`. Nothing here needs a server: these are the
/// decisions the agent makes about *when* and *how much* to ask, which are pure values and
/// index state.
///
/// Serialized with the rest of `AgentScenarios`, because `Config.GroupContainer` is
/// process-wide and each harness installs a container of its own.
extension AgentScenarios {

    @Suite struct DetectionScenarios {

        // MARK: H8 - the rotation and the caps (docs/design/root-set.md)

        /// **H8** - 5,000 `materialized` roots, one tier-0 cycle: 64 of them plus the root,
        /// a rotation period of `ceil(5000/64)`, a `viewed` set capped at 256 with LRU
        /// eviction, pin roots exempt from both, and a `find` argv that has to be batched
        /// to carry the set at all (`SQ-006`).
        ///
        /// docs/design/root-set.md: "each tier 0 cycle lists every `viewed` and `pinned` root and at
        /// most 64 `materialized`-only roots, taken round-robin in order of least recent
        /// listing, so a directory holding only cached files is refreshed every
        /// `ceil(M / 64)` cycles rather than every cycle, and the cost per cycle is bounded
        /// whatever `M` is."
        ///
        /// The batching half is `SQ-006`'s *shape* and not its milliseconds: what was
        /// measured on the VM is that `-cmin` and `-printf` each cost a `stat` per entry
        /// and that an ordinary incremental sweep of a million-file tree is 876 ms. What is
        /// asserted here is the consequence the design draws from it - a cycle's cost has
        /// to be bounded by something, and at tier 1 that something is the 64 KB of argv
        /// one `find` invocation may carry (docs/design/change-detection.md), which five thousand roots
        /// exceed. No timing is asserted; this box is not that server.
        @Test func h8TheRotationAndTheCaps() throws {
            // The location root, enumerated once by the extension, plus five thousand
            // directories that hold one cached file each and nothing else.
            var entries: [RootSet.Entry] = [
                RootSet.Entry(path: Data(), reasons: [.viewed], lastSeen: 1, lastListed: 0)
            ]
            for index in 0 ..< 5000 {
                entries.append(
                    RootSet.Entry(
                        path: Self.cacheRoot(index), reasons: [.materialized],
                        lastSeen: 0, lastListed: 0))
            }
            var set = RootSet(entries: entries)

            #expect(RootSet.materializedPerCycle == 64)
            #expect(RootSet.viewedCap == 256)

            let cycle = set.tier0Cycle()
            #expect(cycle.count == 65, "H8: 64 materialized roots plus the root")
            #expect(cycle.contains(Data()), "H8: the root is listed every cycle, not rotated")
            #expect(set.rotationPeriod() == 79, "H8: ceil(5000 / 64)")
            #expect(set.rotationPeriod() == (5000 + 63) / 64)

            // A full sweep suspends the rotation for that one cycle (docs/design/change-detection.md).
            #expect(set.tier0Cycle(fullSweep: true).count == 5001)

            // The rotation really rotates: over `rotationPeriod` cycles every one of the
            // five thousand is listed, rather than the same 64 being re-picked. Each cycle
            // marks what it listed, exactly as `runPollCycle` does with `markRootListed`.
            var slot: [Data: Int] = [:]
            for (offset, entry) in set.entries.enumerated() { slot[entry.path] = offset }
            var covered: Set<Data> = []
            for round in 1 ... set.rotationPeriod() {
                for path in set.tier0Cycle() {
                    covered.insert(path)
                    if let offset = slot[path] { set.entries[offset].lastListed = Double(round) }
                }
            }
            #expect(covered.count == 5001, "H8: every root, inside one rotation period")

            // The `viewed` cap, and which entries it takes: "evicting the least recently
            // enumerated" (docs/design/root-set.md).
            let viewed = RootSet(
                entries: (0 ..< 300).map {
                    RootSet.Entry(
                        path: Data("browsed/\($0)".utf8), reasons: [.viewed], lastSeen: Double($0))
                })
            let evicted = viewed.viewedEvictions()
            #expect(evicted.count == 44, "H8: 300 - 256")
            #expect(evicted.first == Data("browsed/0".utf8), "H8: least recently enumerated first")
            #expect(evicted.contains(Data("browsed/43".utf8)))
            #expect(!evicted.contains(Data("browsed/44".utf8)))
            #expect(!evicted.contains(Data("browsed/299".utf8)), "H8: the newest survives")
            #expect(RootSet(entries: Array(viewed.entries.prefix(256))).viewedEvictions().isEmpty,
                    "H8: 256 is the boundary, and it does not fire at it")

            // Pin roots are exempt from both. A pin root is listed every cycle whatever
            // else it is, takes no rotation slot, and the cap - which only ever removes a
            // `viewed` reason - never touches it.
            var pinnedEntries: [RootSet.Entry] = [
                RootSet.Entry(path: Data("Pinned".utf8), reasons: [.pinned], lastSeen: 0),
                RootSet.Entry(path: Data("Pinned/deep".utf8), reasons: [.materialized], lastSeen: 0),
            ]
            pinnedEntries += (0 ..< 300).map {
                RootSet.Entry(
                    path: Data("browsed/\($0)".utf8), reasons: [.viewed], lastSeen: Double($0))
            }
            let pinned = RootSet(entries: pinnedEntries)
            #expect(pinned.isUnderPinRoot(Data("Pinned/deep".utf8)),
                    "H8: the recursive watch already covers it")
            #expect(!pinned.isUnderPinRoot(Data("Pinned".utf8)),
                    "H8: the pin root is in the set on its own account")
            #expect(!pinned.isUnderPinRoot(Data("Pinned2/deep".utf8)),
                    "H8: the separator test, so `Pinned2` is not read as a child of `Pinned`")
            #expect(pinned.tier0Cycle().contains(Data("Pinned".utf8)),
                    "H8: a pin root is listed every cycle")
            #expect(!pinned.viewedEvictions().contains(Data("Pinned".utf8)),
                    "H8: the cap evicts a `viewed` reason and nothing else")

            // And the argv the same set has to reach `find` through (`SQ-006`, shape only).
            let roots = (0 ..< 5000).map { Self.argvRoot($0) }
            let plan = SweepPlan(
                shallowRoots: roots, recursiveRoots: ["./Pinned"], flavour: .gnu,
                takesCmin: true, takesPrintf: true, windowMinutes: 2)
            #expect(plan.batches.count > 2, "H8: one argv cannot carry five thousand roots")
            for batch in plan.batches {
                let bytes = batch.roots.reduce(0) { $0 + $1.utf8.count + 1 }
                #expect(bytes <= SweepPlan.argumentByteBudget, "H8: 64 KB of root arguments")
            }
            #expect(
                plan.batches.filter { !$0.recursive }.flatMap(\.roots) == roots,
                "H8: every root exactly once, in order - a dropped root is a directory that stops being watched")
            #expect(plan.batches.filter(\.recursive).flatMap(\.roots) == ["./Pinned"])
        }

        /// **H8**, bite-proof - a rotation that re-picks the same 64 roots.
        ///
        /// The rotation's whole content is the `lastListed` key: without it "at most 64
        /// materialized-only roots" is still true and the cost per cycle is still bounded,
        /// so nothing looks wrong, and 4,936 of the five thousand directories are never
        /// listed again. The old shape is run here for real against the same set.
        @Test func h8BiteProofARotationThatRePicksTheSameSixtyFour() throws {
            var entries: [RootSet.Entry] = []
            for index in 0 ..< 5000 {
                entries.append(
                    RootSet.Entry(path: Self.cacheRoot(index), reasons: [.materialized]))
            }
            var set = RootSet(entries: entries)
            let period = set.rotationPeriod()

            /// The bitten version: the first 64 in whatever order the set holds them,
            /// which is what "take 64 a cycle" means if the least-recent-listing key is
            /// left out.
            func naiveCycle(_ set: RootSet) -> [Data] {
                set.entries.filter(\.isMaterializedOnly).prefix(RootSet.materializedPerCycle)
                    .map(\.path)
            }

            var slot: [Data: Int] = [:]
            for (offset, entry) in set.entries.enumerated() { slot[entry.path] = offset }
            var naiveCovered: Set<Data> = []
            var realCovered: Set<Data> = []
            for round in 1 ... period {
                naiveCovered.formUnion(naiveCycle(set))
                for path in set.tier0Cycle() {
                    realCovered.insert(path)
                    if let offset = slot[path] { set.entries[offset].lastListed = Double(round) }
                }
            }
            #expect(naiveCovered.count == 64, "the bitten rotation lists 64 directories, for ever")
            #expect(realCovered.count == 5000, "H8: the real one covers the set in one period")
        }

        // MARK: H9 - a CLI command is a touch (docs/design/change-detection.md)

        /// **H9** - a location watched only from a terminal: `sshdrive status <name>`
        /// refreshes the touch and the cadence does not fall to ten minutes.
        ///
        /// The change-detection schedule (docs/design/change-detection.md) is "every 60 s while the user has touched the domain in
        /// the last 10 minutes (a File Provider request for it that was not a system
        /// request, **or a CLI command naming it**), every 10 min otherwise". The CLI half
        /// is not a convenience: `MQ-001` measured that a folder is enumerated **once,
        /// ever**, so a user who opened the mount an hour ago produces no further
        /// container-enumerator call at all, and `MQ-039` measured that a `readdir`/`lstat`
        /// walk of the mount - `ls -R`, a `find`, a shell loop - is answered from the
        /// system's replica and **reaches the extension not at all**. Someone working the
        /// mount from a terminal therefore generates no provider traffic whatsoever, and a
        /// CLI command naming the location is the only signal there is that anyone is
        /// looking.
        ///
        /// Driven through the real command handler, because the rule lives in
        /// `DomainManager.location(named:)` - the one place every user-facing command
        /// resolves through - and poking `noteTouch` would assert nothing about whether
        /// `status` reaches it.
        ///
        /// The suite table calls this "the location's `viewed` reason is refreshed". The
        /// reason itself is armed by our own `enumerateItems` and then kept for the rest of
        /// the session (`MQ-001`, docs/design/root-set.md), which is asserted here too; what a CLI
        /// command refreshes is the touch, which is the half that would otherwise decay.
        @Test func h9ACLICommandIsATouch() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let runtime = try await harness.manager.runtime(for: location)
            let detector = try #require(await harness.manager.detector(locationID: location.id))

            // The one enumeration the extension will ever make of this folder (`MQ-001`).
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let armed = try await runtime.currentRootSet()
            #expect(
                armed.entries.contains { $0.path.isEmpty && $0.reasons.contains(.viewed) },
                "H9: the `viewed` reason is armed from our own enumerateItems")

            let now = Date().timeIntervalSince1970
            var status = await detector.status(now: now)
            #expect(status["active"] as? Bool == false, "H9: nothing has touched it yet")
            #expect(status["intervalSeconds"] as? Double == PollSchedule.idleInterval)

            // A system request is deliberately not a touch: a Spotlight pass or the eager
            // download of a pinned subtree would otherwise hold every location at the fast
            // cadence (docs/design/change-detection.md).
            harness.manager.noteDomainTouched(location.id, isSystemRequest: true)
            await harness.settle()
            status = await detector.status(now: now)
            #expect(status["active"] as? Bool == false, "H9: a system request is not a touch")

            // `sshdrive status nas`, through the command handler the CLI's XPC call lands in.
            let report = try await harness.control("status", ["name": "nas"])
            let rows = try #require(report["locations"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["name"] as? String == "nas")

            status = await detector.status(now: now)
            #expect(status["active"] as? Bool == true, "H9: the CLI command is the touch")
            #expect(
                status["intervalSeconds"] as? Double == PollSchedule.activeInterval,
                "H9: 60 s, not ten minutes")

            // The touch is what holds it: eleven minutes later, with no second command,
            // the same detector is back on the idle cadence.
            let later = await detector.status(now: now + PollSchedule.touchWindow + 60)
            #expect(later["active"] as? Bool == false)
            #expect(later["intervalSeconds"] as? Double == PollSchedule.idleInterval)
            // And the boundary itself is inclusive, so a touch exactly ten minutes old
            // still counts rather than depending on which side of a float a timer landed.
            let boundary = await detector.status(now: now + PollSchedule.touchWindow)
            #expect(boundary["active"] as? Bool == true)

            // The reason survives all of it: nothing about a terminal session removes the
            // root from the set, and nothing about it adds a second one either.
            let after = try await runtime.currentRootSet()
            #expect(after.entries.contains { $0.path.isEmpty && $0.reasons.contains(.viewed) })

            await harness.manager.dropRuntime(locationID: location.id)
        }

        // MARK: H10 - a cycle that eats its interval (docs/design/change-detection.md)

        /// **H10** - a 56.8 s cycle against a 60 s interval.
        ///
        /// docs/design/change-detection.md: "**A cycle may take at most a third of its own interval**: where the
        /// last one took longer, the interval becomes three times that cycle's duration,
        /// capped at the 30-minute insurance interval, and `sshdrive status` prints the
        /// reason on the watch line. Measured on a real install (2026-09-05): a home
        /// directory whose sweep took 56.8 s against a 60 s interval, so the location swept
        /// without pause and the one spare exec channel was never free for anything else."
        ///
        /// That a sweep can cost that much is `SQ-006`'s shape - the time tests and
        /// `-printf` are a `stat` per entry and that is what a sweep spends - though the
        /// numbers there are the VM's and the 56.8 s is one real install's. Nothing timed
        /// is asserted here: the cycle takes 56.8 s of `VirtualAgentClock`, which is what
        /// the agent's own stopwatch reads, and the run costs milliseconds.
        ///
        /// The `status` sentence is asserted as a sentence. The number alone would pass
        /// against a watch line that never printed it, and a schedule that has silently
        /// tripled itself with nothing on the watch line is the report the measurement was
        /// made to produce.
        @Test func h10ACycleThatEatsItsInterval() async throws {
            let clock = VirtualAgentClock()
            let harness = try AgentHarness(clock: clock)
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "Photos"), mode: 0o755))
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)

            // No exec channel and no `find`: tier 0, which is the cheapest cycle there is
            // and still the one the rule is about.
            let base = Date().timeIntervalSince1970
            let detector = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: ChangeDetectionLadder.ServerCapabilities(),
                environment: harness.environment, now: base)
            #expect(await detector.currentTier() == .poll)

            // The cycle takes 56.8 s. The clock moves inside it, at the first thing the
            // cycle asks the replica for, which is after the detector has started its own
            // stopwatch.
            harness.replica.setOnPendingIdentifiers { _ in clock.advance(56.8) }
            _ = await detector.runCycle(now: base)
            harness.replica.setOnPendingIdentifiers(nil)

            await detector.noteTouch(now: base)
            var status = await detector.status(now: base)
            let outcome = try #require(status["lastCycle"] as? [String: Any])
            #expect(
                abs((outcome["seconds"] as? Double ?? 0) - 56.8) < 0.01,
                "H10: the cycle's own duration, on the agent's own clock")
            let interval = try #require(status["intervalSeconds"] as? Double)
            #expect(abs(interval - 170.4) < 0.05, "H10: three times the last cycle")
            #expect(
                interval < PollSchedule.maximumInterval, "H10: 170.4 s is under the cap")
            #expect(
                status["intervalNote"] as? String
                    == "the last cycle took 56.8s, so the interval is 170s rather than 60s",
                "H10: `status` says so, in words")

            // And the cap. A cycle of a quarter of an hour would ask for 45 minutes; the
            // insurance interval is the ceiling, so nothing goes unwatched for longer than
            // the pass that exists to catch what everything else missed.
            harness.replica.setOnPendingIdentifiers { _ in clock.advance(900) }
            _ = await detector.runCycle(now: base + 200)
            harness.replica.setOnPendingIdentifiers(nil)
            await detector.noteTouch(now: base + 200)
            status = await detector.status(now: base + 200)
            #expect(
                status["intervalSeconds"] as? Double == PollSchedule.insuranceInterval,
                "H10: capped at the 30-minute insurance interval, not 2700 s")
            #expect(
                status["intervalNote"] as? String
                    == "the last cycle took 900.0s, so the interval is 1800s rather than 60s")

            // An ordinary cycle paces nothing at all: three times zero is not an interval,
            // so the schedule is the plain 60 s.
            harness.replica.setOnPendingIdentifiers(nil)
            #expect(
                PollSchedule.interval(lastTouch: base, now: base, lastCycleSeconds: 0)
                    == PollSchedule.activeInterval)

            // "a tier-2 cycle that went nowhere paces nothing". At tier 2 an ordinary cycle
            // refreshes the root set, pushes it to the helper's stdin and touches nothing
            // on the wire; its duration is evidence about a local index read and not about
            // the server, so it is not allowed to pace anything. A tier-2 cycle that ran
            // the 30-minute insurance sweep did go to the server and counts like any other.
            #expect(PollSchedule.paces(handledByHelper: false, ranFullSweep: false))
            #expect(PollSchedule.paces(handledByHelper: false, ranFullSweep: true))
            #expect(
                !PollSchedule.paces(handledByHelper: true, ranFullSweep: false),
                "H10: a tier-2 cycle that went nowhere paces nothing")
            #expect(
                PollSchedule.paces(handledByHelper: true, ranFullSweep: true),
                "H10: the insurance sweep at tier 2 is a real cycle")

            await detector.stop()
        }

        // MARK: H11 - the mass-deletion guard's thresholds (docs/design/change-detection.md)

        /// **H11** - every threshold the mass-deletion guard (docs/design/change-detection.md) names, at its
        /// boundaries, and the schedule that releases what it held.
        ///
        /// "If one diff would remove at least half of a directory's known, non-hidden items
        /// **and at least 20 of them**, or would **empty the root** when the root previously
        /// held anything at all, the missing items are not reported. They are recorded in
        /// `held` with the time first seen missing, stay visible in Finder, and the
        /// directory is re-listed **after 5 minutes and again after 30**. If they are still
        /// missing after the second re-check, the deletions are applied."
        ///
        /// So there are three numbers and they are not interchangeable: an absolute count
        /// of 20, a proportion of a half, and - because the count is a floor - a small
        /// directory that is exempt however completely it empties. A folder of eight files
        /// that the user really did empty is reported at once; the same eight files at the
        /// **location root** are held, because an unmounted share and an emptied root look
        /// identical from a listing and only the root's own emptiness is diagnostic.
        ///
        /// **D5 covers the pending-item half** (`Tests/AgentRuntimeTests/GuardScenarios.swift`):
        /// a pending local edit is held whatever the counts say, its ancestors with it, and
        /// `accept-deletions` releases them. That half is covered there and not repeated
        /// here; this is the size half. D5 also owns the fetch of a *bulk*-held
        /// item, so the fetch asserted below is of a **root**-held one - the threshold D5
        /// never reaches. Either way the answer is `.cannotSynchronize` carrying the
        /// `ENOENT` and never `.noSuchItem`: `MQ-011` measured that `.noSuchItem` from
        /// `item(for:)` makes the system delete the user's file, and `MQ-012` that from
        /// `fetchContents` the two differ only in what the reader is told (`ETIMEDOUT`
        /// against `ESTALE`), both reversible. The hold exists to stop a half-applied
        /// deletion, so the one error that applies it is the one it must never send.
        @Test func h11TheMassDeletionGuardsThresholds() async throws {
            // The three numbers, and each boundary from both sides.
            #expect(MassDeletionGuard.minimumCount == 20)
            #expect(MassDeletionGuard.fractionNumerator == 1)
            #expect(MassDeletionGuard.fractionDenominator == 2)
            #expect(MassDeletionGuard.firstRecheck == 300)
            #expect(MassDeletionGuard.secondRecheck == 1800)

            // The count: 20 of 40 holds, 19 of 38 does not - and 19 of 38 satisfies the
            // proportion, so what refuses it is the count and only the count.
            #expect(MassDeletionGuard.holdsInBulk(
                missingCount: 20, knownNonHiddenCount: 40, isLocationRoot: false))
            #expect(!MassDeletionGuard.holdsInBulk(
                missingCount: 19, knownNonHiddenCount: 38, isLocationRoot: false))
            // The proportion: 20 of 41 is under half and is reported; 21 of 41 is not.
            #expect(!MassDeletionGuard.holdsInBulk(
                missingCount: 20, knownNonHiddenCount: 41, isLocationRoot: false))
            #expect(MassDeletionGuard.holdsInBulk(
                missingCount: 21, knownNonHiddenCount: 41, isLocationRoot: false))
            // The floor exempts a small directory however completely it empties.
            #expect(!MassDeletionGuard.holdsInBulk(
                missingCount: 8, knownNonHiddenCount: 8, isLocationRoot: false))
            #expect(!MassDeletionGuard.holdsInBulk(
                missingCount: 19, knownNonHiddenCount: 19, isLocationRoot: false))
            // The root has no floor: emptying it is the vanished-mount shape itself. But a
            // root that held nothing is not "emptied", and a root that lost some of its
            // items falls back to the ordinary counts.
            #expect(MassDeletionGuard.holdsInBulk(
                missingCount: 8, knownNonHiddenCount: 8, isLocationRoot: true))
            #expect(!MassDeletionGuard.holdsInBulk(
                missingCount: 0, knownNonHiddenCount: 0, isLocationRoot: true))
            #expect(!MassDeletionGuard.holdsInBulk(
                missingCount: 7, knownNonHiddenCount: 8, isLocationRoot: true))

            // And the same rules through the index, where the `held` rows are written.
            let clock = VirtualAgentClock()
            let harness = try AgentHarness(clock: clock)
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            try await Self.seed(fake, directory: "Photos", files: 40)
            try await Self.seed(fake, directory: "Work", files: 38)
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            for directory in ["Photos", "Work"] {
                let (identifier, _) = try await runtime.identifier(forPath: directory)
                _ = try await runtime.enumerateItems(container: identifier, pageToken: nil)
            }

            // 20 of Photos' 40 - held. 19 of Work's 38 - reported, because 19 is under the
            // count even though it is exactly half.
            for index in 0 ..< 20 {
                try await fake.apply(
                    .delete(path: try RelativePath(string: Self.file("Photos", index)), recursive: false))
            }
            for index in 0 ..< 19 {
                try await fake.apply(
                    .delete(path: try RelativePath(string: Self.file("Work", index)), recursive: false))
            }

            let first = clock.now()
            var application = await runtime.runPollCycle(fullSweep: true, now: first)
            #expect(application.held == 20, "H11: the 20 of Photos")
            #expect(application.deleted == 19, "H11: the 19 of Work, under the count floor")

            var held = try await runtime.heldReport()
            #expect(held.count == 20)
            let row = try #require(held.first)
            #expect(
                row["reason"] as? String == "20 deletions held in Photos",
                "H11: the `held` row carries the reason `status` prints")
            #expect(row["checks"] as? Int64 == 0, "H11: no re-check has run yet")
            #expect(row["firstMissing"] as? Double == first)
            #expect(
                row["recheckAt"] as? Double == first + MassDeletionGuard.firstRecheck,
                "H11: re-listed after 5 minutes")
            #expect(held.allSatisfy { ($0["directory"] as? String) == "Photos" })

            // The first re-check, at five minutes. Still missing, so still held - and the
            // next one is booked for 30 minutes after they first went, not after this one.
            clock.advance(MassDeletionGuard.firstRecheck)
            application = await runtime.recheckHeldDeletions(now: clock.now())
            #expect(application.deleted == 0, "H11: one re-check is not two")
            held = try await runtime.heldReport()
            #expect(held.count == 20)
            let rechecked = try #require(held.first)
            #expect(rechecked["checks"] as? Int64 == 1)
            #expect(
                rechecked["recheckAt"] as? Double == first + MassDeletionGuard.secondRecheck,
                "H11: and again after 30")
            #expect(rechecked["firstMissing"] as? Double == first, "H11: measured from the first absence")

            // A re-check that is not due yet does nothing at all.
            clock.advance(60)
            application = await runtime.recheckHeldDeletions(now: clock.now())
            #expect(application.listedDirectories == 0, "H11: nothing is due, nothing is listed")
            #expect(try await runtime.heldReport().count == 20)

            // The second, at thirty minutes: still missing, so the deletions are applied.
            clock.advance(MassDeletionGuard.secondRecheck - MassDeletionGuard.firstRecheck - 60)
            #expect(clock.now() == first + MassDeletionGuard.secondRecheck)
            application = await runtime.recheckHeldDeletions(now: clock.now())
            #expect(application.deleted == 20, "H11: a directory that stays empty was emptied")
            #expect(try await runtime.heldReport().isEmpty)
            await #expect(throws: (any Error).self) {
                _ = try await runtime.identifier(forPath: Self.file("Photos", 0))
            }

            // `accept-deletions` applies a bulk hold now, without waiting for either
            // re-check. Photos holds 20 rows; all 20 go.
            for index in 20 ..< 40 {
                try await fake.apply(
                    .delete(path: try RelativePath(string: Self.file("Photos", index)), recursive: false))
            }
            application = await runtime.runPollCycle(fullSweep: true, now: clock.now())
            #expect(application.held == 20, "H11: 20 of 20 is the whole directory and over the floor")
            #expect(try await runtime.acceptDeletions(pathString: nil) == 20)
            #expect(try await runtime.heldReport().isEmpty, "H11: the rows are released")

            // The root's own rule, on a location of its own, and the error a held item
            // answers a fetch with (`MQ-011`, `MQ-012`).
            let vault = try await harness.addLocation(nickname: "vault", backend: .fake)
            let vaultServer = FakeTransport(root: "/srv/vault")
            for index in 0 ..< 5 {
                try await vaultServer.apply(
                    .createFile(
                        path: try RelativePath(string: "note-\(index).txt"),
                        contents: Data("n".utf8), mode: 0o644))
            }
            let vaultRuntime = try harness.makeRuntime(location: vault, transport: vaultServer)
            try await vaultRuntime.start()
            _ = try await vaultRuntime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let (noteIdentifier, _) = try await vaultRuntime.identifier(forPath: "note-0.txt")
            for index in 0 ..< 5 {
                try await vaultServer.apply(
                    .delete(path: try RelativePath(string: "note-\(index).txt"), recursive: false))
            }
            let emptied = await vaultRuntime.runPollCycle(fullSweep: true, now: clock.now())
            #expect(emptied.held == 5, "H11: the root emptied, with no floor to clear")
            #expect(emptied.deleted == 0)
            let vaultHeld = try await vaultRuntime.heldReport()
            #expect(
                vaultHeld.first?["reason"] as? String == "5 deletions held in the location root")
            #expect(vaultHeld.allSatisfy { ($0["checks"] as? Int64) == 0 })

            let destination = harness.container.appendingPathComponent("h11-fetch.tmp")
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            do {
                _ = try await vaultRuntime.fetchContents(
                    identifier: noteIdentifier, into: handle, transferID: "h11",
                    kind: .foreground)
                Issue.record("H11: a held item must not fetch")
            } catch {
                #expect(
                    (error as NSError).code == SSHDriveAgentError.cannotSynchronize.rawValue,
                    "H11: `.cannotSynchronize`, never `.noSuchItem` (`MQ-011`, `MQ-012`)")
            }
        }

        /// **H11**, bite-proof - a threshold read as a proportion where it is a count.
        ///
        /// "At least half of a directory's known, non-hidden items **and** at least 20 of
        /// them" is two tests, and dropping the count is the easy half to lose: the
        /// proportion alone still reads as "an implausibly large deletion" and still holds
        /// every case the guard was written for. What it also holds is every ordinary
        /// emptying of a small folder - a user who deletes both files in a two-file
        /// directory waits 35 minutes to see it - which is the cost the floor in
        /// docs/design/root-set.md exists to avoid. The bitten rule is run here against
        /// the same diffs.
        @Test func h11BiteProofTheCountReadAsAProportion() throws {
            /// The guard with the count dropped: half of the directory and nothing else.
            func proportionOnly(missing: Int, known: Int) -> Bool {
                missing * MassDeletionGuard.fractionDenominator
                    >= known * MassDeletionGuard.fractionNumerator
            }

            // Every ordinary small emptying the real guard reports at once.
            for (missing, known) in [(2, 2), (1, 2), (8, 8), (19, 38), (10, 12)] {
                #expect(
                    proportionOnly(missing: missing, known: known),
                    "the bitten rule holds \(missing) of \(known)")
                #expect(
                    !MassDeletionGuard.holdsInBulk(
                        missingCount: missing, knownNonHiddenCount: known, isLocationRoot: false),
                    "H11: the count floor reports \(missing) of \(known) at once")
            }
            // And the case both agree on, so the bite-proof is about the floor and not
            // about the guard having been turned off.
            #expect(proportionOnly(missing: 30, known: 40))
            #expect(MassDeletionGuard.holdsInBulk(
                missingCount: 30, knownNonHiddenCount: 40, isLocationRoot: false))
        }

        // MARK: Fixtures

        static func cacheRoot(_ index: Int) -> Data {
            Data(String(format: "cache/dir-%04d", index).utf8)
        }

        /// The same directory as `find` sees it in its argv: `./name`, never bare, because
        /// `find` has no portable `--` (`SQ-007`, H6).
        static func argvRoot(_ index: Int) -> String {
            String(format: "./cache/dir-%04d", index)
        }

        static func file(_ directory: String, _ index: Int) -> String {
            String(format: "%@/item-%03d", directory, index)
        }

        static func seed(_ fake: FakeTransport, directory: String, files: Int) async throws {
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: directory), mode: 0o755))
            for index in 0 ..< files {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: file(directory, index)),
                        contents: Data("f\(index)".utf8), mode: 0o644))
            }
        }
    }
}
