import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import Logging
import SFTP
import Testing
import XPCProtocols

/// Suite G on the agent's side: the TTL loop against a driven clock, and the pinning
/// inheritance rules of docs/design/pinning.md (`docs/design/testing.md` section 5).
extension AgentScenarios {

    @Suite struct EvictionAndPinScenarios {

        /// **G1** - atime is not in the TTL's `max`.
        ///
        /// A file fetched 280 s ago under a 60 s TTL, with the replica's atime advanced 23 s
        /// ago by something that is not a read of ours (`MQ-022`), is evicted. The atime is
        /// read **before** the eviction, because an eviction moves it (`MQ-021`), it is logged
        /// beside the age the decision used, and it changes nothing.
        @Test func g1AtimeIsReadBeforeEvictionAndDecidesNothing() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(
                nickname: "nas", backend: .fake, cacheTTL: .oneHour)
            let fake = FakeTransport(root: "/srv/fake")
            try await fake.seedSample(fileCount: 2)
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)

            // One file, fetched, so the index has a `last_fetch` to measure from.
            let (identifier, _) = try await runtime.identifier(forPath: "README.txt")
            let destination = harness.container.appendingPathComponent("g1.tmp")
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            _ = try await runtime.fetchContents(
                identifier: identifier, into: handle, transferID: "g1", kind: .foreground)
            try? handle.close()
            let rows = try await runtime.evictionRows(identifiers: [identifier])
            let fetchedAt = try #require(rows.first?.lastFetch)

            // The system says it holds the content; the replica's atime moved 23 s ago and its
            // mtime is the fetch.
            harness.replica.setMaterialized([identifier], locationID: location.id)
            harness.replica.setReplicaTimes(
                identifier: identifier, atime: fetchedAt + 257, mtime: fetchedAt,
                locationID: location.id)

            let evictor = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .oneHour,
                environment: harness.environment)
            await evictor.setTTLOverride(seconds: 60)
            let pass = await evictor.runPass(reason: "g1", now: fetchedAt + 280)

            #expect(pass["evicted"] as? Int == 1, "G1: 280 s unused under a 60 s TTL is evicted")
            #expect(harness.replica.evictedIdentifiers == [identifier])

            // The atime was read first: the `getUserVisibleURL` for this item comes before the
            // `evictItem` for it.
            let calls = harness.replica.calls
            let lookedUp = try #require(
                calls.firstIndex { if case .userVisibleURL = $0 { return true } else { return false } })
            let evicted = try #require(
                calls.firstIndex { if case .evict = $0 { return true } else { return false } })
            #expect(lookedUp < evicted, "G1: an eviction moves atime, so it is read before")

            // And the row's `last_fetch` is cleared, so the next pass does not trip over it.
            let after = try await runtime.evictionRows(identifiers: [identifier])
            #expect(after.first?.lastFetch == nil)
        }

        /// **G4** - the policy refuses, not the capability.
        ///
        /// A pin on a directory makes every known descendant `kept` without writing a marker on
        /// any of them: invariant 3 (docs/design/pinning.md) says the *smallest* marker change
        /// that produces the asked-for effect is the one made. `evict <path>` on such a file is
        /// refused with "unpin it first" rather than left to fail opaquely, because the eager
        /// content policy would refuse it anyway and the code says nothing about why
        /// (`MQ-018`, `MQ-024`).
        @Test func g4APinIsInheritedByEveryDescendant() async throws {
            let harness = try AgentHarness()
            let (location, runtime) = try await Self.tree(harness)

            let report = try await runtime.applyPin(pathString: "Documents", request: .keep)
            #expect(report["changed"] as? Bool == true)

            let markers = try await runtime.pinMarkers()
            #expect(
                markers.pinRoots.map { String(decoding: $0, as: UTF8.self) } == ["Documents"],
                "G4: one marker, at the root of the pin (invariant 3)")
            #expect(markers.exclusions.isEmpty)

            for path in ["Documents", "Documents/notes.txt", "Documents/Reports",
                         "Documents/Reports/q1.txt"] {
                let (_, row) = try await runtime.identifier(forPath: path)
                #expect(row.kept, "G4: \(path) inherits the pin with no marker of its own")
            }
            let (_, outside) = try await runtime.identifier(forPath: "Media")
            #expect(!outside.kept, "nothing above it, nothing inherited")

            // The refusal is a sentence, not an opaque `-2008`.
            let evictor = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .oneHour,
                environment: harness.environment)
            do {
                _ = try await evictor.evictPath("Documents/Reports/q1.txt")
                Issue.record("a kept file must be refused")
            } catch {
                #expect(error.localizedDescription.contains("unpin"))
            }
            #expect(harness.replica.evictedIdentifiers.isEmpty)
        }

        /// **G5** - an explicit lazy child beats an eager ancestor.
        ///
        /// `Documents/Reports` excluded inside a pinned `Documents`: the excluded subtree stops
        /// being kept, the direct sibling stays kept, and the pin above it is untouched
        /// (`MQ-027`, the five situations of docs/design/pinning.md).
        @Test func g5AnExplicitExclusionBeatsThePinAboveIt() async throws {
            let harness = try AgentHarness()
            let (_, runtime) = try await Self.tree(harness)
            _ = try await runtime.applyPin(pathString: "Documents", request: .keep)

            _ = try await runtime.setPinState(pathString: "Documents/Reports", marker: -1)

            let markers = try await runtime.pinMarkers()
            #expect(markers.pinRoots.map { String(decoding: $0, as: UTF8.self) } == ["Documents"])
            #expect(
                markers.exclusions.map { String(decoding: $0, as: UTF8.self) }
                    == ["Documents/Reports"])

            let (_, sibling) = try await runtime.identifier(forPath: "Documents/notes.txt")
            #expect(sibling.kept, "G5: the direct sibling is still kept")
            for path in ["Documents/Reports", "Documents/Reports/q1.txt"] {
                let (_, row) = try await runtime.identifier(forPath: path)
                #expect(!row.kept, "G5: \(path) stays lazy and the TTL can take it")
            }
        }

        /// `Documents/{notes.txt, Reports/q1.txt}` and a `Media` outside the pin, all listed.
        static func tree(_ harness: AgentHarness) async throws -> (Location, LocationRuntime) {
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "Documents"), mode: 0o755))
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "Documents/Reports"), mode: 0o755))
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "Media"), mode: 0o755))
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "Documents/notes.txt"),
                    contents: Data("notes".utf8), mode: 0o644))
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "Documents/Reports/q1.txt"),
                    contents: Data("q1".utf8), mode: 0o644))
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            for directory in ["Documents", "Documents/Reports", "Media"] {
                let (identifier, _) = try await runtime.identifier(forPath: directory)
                _ = try await runtime.enumerateItems(container: identifier, pageToken: nil)
            }
            return (location, runtime)
        }

        // MARK: G1 (second half), G2, G3, G11, G12

        /// **G1**, second half - the TTL is measured from the last fetch **or the last
        /// save**, and four things are never evicted at all.
        ///
        /// This is the other half of `G1`; the first (`g1AtimeIsReadBeforeEvictionAndDecidesNothing`)
        /// is that atime is outside the `max` (`MQ-021`, `MQ-022`, `MQ-023`). Here the rule
        /// itself: last use is `max(last_fetch, mtime)`, and the replica's mtime counts
        /// beside the row's because a save in the mount moves the replica's before the
        /// upload finishes and the row's only afterwards (docs/design/eviction.md, step 2). A file saved
        /// since its fetch is spared; one fetched long ago and never touched is taken.
        ///
        /// The four skips of `EvictionPlan.Skip` are asserted where they are observable -
        /// at the seam: `cacheTTL = never` evicts nothing, and a directory, a local-only
        /// row (the `.DS_Store` handling of docs/design/names-and-attributes.md) and a kept item are decided without so much as
        /// a `getUserVisibleURL`, let alone an `evictItem`. A directory is skipped because
        /// a TTL is per file, not because `evictItem` cannot take one (`MQ-020`).
        @Test func g1TheTTLIsTheLaterOfTheFetchAndTheSave() async throws {
            let harness = try AgentHarness()
            let (location, runtime) = try await Self.evictionTree(harness)

            let (readme, _) = try await runtime.identifier(forPath: "README.txt")
            let (clip, _) = try await runtime.identifier(forPath: "Media/clip.mov")
            let (notes, _) = try await runtime.identifier(forPath: "Documents/notes.txt")
            let (documents, _) = try await runtime.identifier(forPath: "Documents")
            let (media, _) = try await runtime.identifier(forPath: "Media")
            for (identifier, name) in [(readme, "readme"), (clip, "clip"), (notes, "notes")] {
                try await Self.fetch(runtime, identifier, into: harness, named: name)
            }
            let fetchedAt = try #require(
                try await runtime.evictionRows(identifiers: [readme]).first?.lastFetch)

            // The local-only row for Finder's `.DS_Store` (docs/design/names-and-attributes.md),
            // which is never uploaded
            // and has nothing on the server to fetch back.
            let dsStore = try await runtime.createItem(
                parentIdentifier: IndexWriter.rootIdentifier, filename: ".DS_Store",
                isDirectory: false, symlinkTarget: nil, contents: nil)
            // A pin over `Documents`, so `notes.txt` is kept by inheritance.
            _ = try await runtime.applyPin(pathString: "Documents", request: .keep)

            // `README.txt` was fetched and never touched again; `Media/clip.mov` was saved
            // in the mount five seconds ago, which is a use.
            harness.replica.setReplicaTimes(
                identifier: readme, atime: fetchedAt + 257, mtime: fetchedAt,
                locationID: location.id)
            harness.replica.setReplicaTimes(
                identifier: clip, atime: fetchedAt, mtime: fetchedAt + 275,
                locationID: location.id)
            harness.replica.setReplicaTimes(
                identifier: notes, atime: fetchedAt, mtime: fetchedAt, locationID: location.id)

            harness.replica.setMaterialized(
                [readme, clip, notes, documents, media, dsStore.identifier],
                locationID: location.id)
            harness.replica.resetCalls()

            let evictor = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .oneHour,
                environment: harness.environment)
            await evictor.setTTLOverride(seconds: 60)
            let pass = await evictor.runPass(reason: "g1-ttl", now: fetchedAt + 280)

            #expect(
                pass["evicted"] as? Int == 1,
                "G1: only the file whose last fetch **and** last save are older than the TTL")
            #expect(harness.replica.evictedIdentifiers == [readme])
            #expect(
                pass["skippedKept"] as? Int == 1,
                "G1: the kept file is skipped by us, not refused by the system")

            let evicts = harness.replica.calls.compactMap { call -> String? in
                if case let .evict(_, identifier) = call { return identifier }
                return nil
            }
            #expect(
                evicts == [readme],
                "G1: the saved file, the directories, the local-only row and the kept file are never even offered to `evictItem`")

            // "A directory, a kept item and a local-only row are all decided without a
            // `stat`" - the loop does not pay for a replica lookup it cannot use.
            let statted = harness.replica.calls.compactMap { call -> String? in
                if case let .userVisibleURL(_, identifier) = call { return identifier }
                return nil
            }
            #expect(Set(statted) == Set([readme, clip]))
            #expect(!statted.contains(documents) && !statted.contains(media))
            #expect(!statted.contains(dsStore.identifier) && !statted.contains(notes))

            // `cacheTTL = never` (docs/design/eviction.md, step 1): the pass runs and evicts nothing, no
            // matter how old the content is.
            harness.replica.setMaterialized([clip], locationID: location.id)
            harness.replica.resetCalls()
            let never = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .never,
                environment: harness.environment)
            let neverPass = await never.runPass(
                reason: "g1-never", now: fetchedAt + 86_400 * 365)
            #expect(neverPass["evicted"] as? Int == 0)
            #expect(
                !harness.replica.calls.contains {
                    if case .evict = $0 { return true } else { return false }
                }, "G1: `never` makes no `evictItem` call at all")
            #expect(harness.replica.evictedIdentifiers == [readme])
        }

        /// **G2** - `evict --all` falls back to a walk.
        ///
        /// The one call on the root container is an optimisation and not the contract
        /// (docs/design/eviction.md, step 4). Two measurements say so: with a pin in place the call meets
        /// a kept child and fails as a whole (`MQ-033`), and for 5-10 s after an unpin it
        /// fails as `NSCocoaErrorDomain` "The file couldn't be opened", which names no
        /// reason, because the system has not re-read the rows whose policy just changed
        /// (`MQ-034`). Either way `--all` walks the materialized set and evicts the unkept
        /// files one by one, each with the doubling backoff described in docs/design/writes.md.
        ///
        /// Three arrangements, because the runtime has two ways of not evicting the root:
        /// when it *knows* the call is doomed - a pin is in place, or `--unpin-all` has
        /// just removed one - it does not spend the call, and logs why; when it does not
        /// know, it makes the call, is refused, logs the refusal and walks anyway. The
        /// last two arrangements are the same command refused with the two different
        /// measured errors, and **everything the code does afterwards is identical**,
        /// which is what "logged, never interpreted" means: no branch anywhere reads the
        /// domain, the code or the sentence.
        @Test func g2EvictAllFallsBackToAWalk() async throws {
            let capture = LogCapture()
            capture.install()
            defer { capture.uninstall() }

            let harness = try AgentHarness()
            // The backoff is exercised at its real numbers and costs no real time
            // (docs/design/testing.md).
            harness.clock.autoAdvance = true
            let (location, runtime) = try await Self.evictionTree(harness)

            let (readme, _) = try await runtime.identifier(forPath: "README.txt")
            let (clip, _) = try await runtime.identifier(forPath: "Media/clip.mov")
            let (notes, _) = try await runtime.identifier(forPath: "Documents/notes.txt")
            let (q1, _) = try await runtime.identifier(forPath: "Documents/Reports/q1.txt")
            let (documents, _) = try await runtime.identifier(forPath: "Documents")
            let (reports, _) = try await runtime.identifier(forPath: "Documents/Reports")
            let (media, _) = try await runtime.identifier(forPath: "Media")
            let everything = [readme, clip, notes, q1, documents, reports, media]

            let evictor = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .oneHour,
                environment: harness.environment)

            // 1. `MQ-033`: a pin is in place.
            _ = try await runtime.applyPin(pathString: "Documents", request: .keep)
            harness.replica.setMaterialized(everything, locationID: location.id)
            // One refusal, then the item goes: the doubling backoff is what carries a
            // still-settling file over (`MQ-017`).
            harness.replica.refuseEviction(
                identifier: readme, report: Self.mq034Refusal(), times: 1)
            harness.replica.resetCalls()
            var sleepsSoFar = harness.clock.requestedSleeps.count

            let withAPin = try await evictor.evictAll(unpinAll: false)

            #expect(withAPin["mode"] as? String == "file by file (pins are in place)")
            #expect(
                !Self.evictAttempts(harness, IndexWriter.rootIdentifier).isEmpty == false,
                "G2: the doomed call on the root container is not spent when a pin is in place")
            #expect(withAPin["evicted"] as? Int == 2, "G2: both unkept files")
            #expect(withAPin["keptSkipped"] as? Int == 2, "G2: and neither kept one")
            #expect(withAPin["refusedCount"] as? Int == 0)
            #expect(harness.replica.evictedIdentifiers.contains(readme))
            #expect(harness.replica.evictedIdentifiers.contains(clip))
            #expect(!harness.replica.evictedIdentifiers.contains(notes))
            #expect(!harness.replica.evictedIdentifiers.contains(q1))
            #expect(
                Array(harness.clock.requestedSleeps.dropFirst(sleepsSoFar)) == [0.25],
                "G2: the first backoff step, and the retry took it")

            // 2. `MQ-034`: straight after `--unpin-all`.
            harness.replica.refuseEviction(
                identifier: notes, report: Self.mq034Refusal(), times: 4)
            harness.replica.resetCalls()
            sleepsSoFar = harness.clock.requestedSleeps.count

            let afterUnpinAll = try await evictor.evictAll(unpinAll: true)

            #expect(afterUnpinAll["pinsRemoved"] as? Int == 1)
            #expect(
                afterUnpinAll["mode"] as? String == "file by file (the pins were just removed)")
            #expect(
                Self.evictAttempts(harness, IndexWriter.rootIdentifier).isEmpty,
                "G2: nor is it spent in the window after an unpin (MQ-034)")
            #expect(afterUnpinAll["evicted"] as? Int == 2, "G2: what the pin had been keeping")
            #expect(afterUnpinAll["keptSkipped"] as? Int == 0)
            #expect(
                Array(harness.clock.requestedSleeps.dropFirst(sleepsSoFar))
                    == [0.25, 0.5, 1, 2],
                "G2: the doubling backoff, at its real numbers, five attempts after an unpin")
            #expect(try await runtime.pinMarkers().isEmpty, "G2: `--unpin-all` left no marker")

            // 3a. Nothing is pinned any more, so the call *is* made - and refused, the way
            // it is refused while a kept child is still under the container (`MQ-033`).
            harness.replica.setMaterialized(everything, locationID: location.id)
            harness.replica.refuseEviction(
                identifier: IndexWriter.rootIdentifier, report: Self.mq033Refusal())
            harness.replica.resetCalls()
            sleepsSoFar = harness.clock.requestedSleeps.count

            let refusedByAKeptChild = try await evictor.evictAll(unpinAll: false)

            #expect(
                refusedByAKeptChild["mode"] as? String
                    == "file by file (the root container was refused)")
            #expect(
                Self.evictAttempts(harness, IndexWriter.rootIdentifier).count == 3,
                "G2: three attempts on the container, then the walk")
            #expect(refusedByAKeptChild["evicted"] as? Int == 4, "G2: every unkept file")
            #expect(
                Array(harness.clock.requestedSleeps.dropFirst(sleepsSoFar)) == [0.25, 0.5, 1])

            // 3b. The same command, refused with the *other* measured error (`MQ-034`).
            harness.replica.setMaterialized(everything, locationID: location.id)
            harness.replica.refuseEviction(
                identifier: IndexWriter.rootIdentifier, report: Self.mq034Refusal())
            harness.replica.resetCalls()
            sleepsSoFar = harness.clock.requestedSleeps.count

            let refusedBySettlingRows = try await evictor.evictAll(unpinAll: false)

            #expect(
                Self.evictAttempts(harness, IndexWriter.rootIdentifier).count == 3)
            #expect(
                Array(harness.clock.requestedSleeps.dropFirst(sleepsSoFar)) == [0.25, 0.5, 1])

            // Nothing branches on the error: a different domain, a different code and a
            // different sentence produce a byte-for-byte identical outcome, and the only
            // field that differs is the one that carries the sentence through to the user.
            var keptChild = Self.shape(refusedByAKeptChild)
            var settlingRows = Self.shape(refusedBySettlingRows)
            #expect(keptChild["rootContainerError"] != settlingRows["rootContainerError"])
            keptChild.removeValue(forKey: "rootContainerError")
            settlingRows.removeValue(forKey: "rootContainerError")
            #expect(
                keptChild == settlingRows,
                "G2: the two measured refusals are told apart by nothing in our code")

            // And the failure is logged. On Darwin `Log.*` is `os.Logger`, whose lines go
            // to the unified log and never to a capture (`Logging/LogCapture.swift`), so
            // this half of the assertion is the Linux build's.
            #if !canImport(os)
                let lines = capture.messages(category: Log.Category.agent)
                #expect(
                    lines.contains {
                        $0.contains("a pin is in place") && $0.contains("MQ-033")
                    })
                #expect(
                    lines.contains {
                        $0.contains("were just removed") && $0.contains("MQ-034")
                    })
                #expect(
                    lines.contains {
                        $0.contains("the root container refused eviction")
                            && $0.contains("nothing is read from it")
                    }, "G2: the refusal reaches the log with its sentence intact")
                #expect(
                    !lines.contains {
                        let text = $0.lowercased()
                        return text.contains("because it is pinned")
                            || text.contains("because it is kept")
                            || text.contains("unsynced")
                    }, "G2: and no line claims to know why it was refused")
            #endif
        }

        /// **G3** - `-2008` says nothing about why.
        ///
        /// `MQ-018`: an item with a pending upload and a kept item are both refused
        /// `NSFileProviderErrorNonEvictable` (-2008), never the documented
        /// `NSFileProviderErrorUnsyncedEdits` (-2007), so the eviction loop cannot tell a
        /// pin from a pending write by error code and must not try (gotcha 82). The loop's
        /// contract is eviction.md's step 3: ignore the refusal, log it, pass the item over
        /// and carry on to the next one; the pass comes round again in five minutes.
        ///
        /// `MQ-019` is the same rule one level up: evicting the **parent directory** of a
        /// pending item fails as `NSCocoaErrorDomain` 4101 with a `libfssync`
        /// `contentVersionMismatch` underneath rather than
        /// `NSFileProviderErrorNonEvictableChildren` (-2006). That is reported verbatim
        /// and likewise not interpreted.
        @Test func g3TheNonEvictableCodeSaysNothingAboutWhy() async throws {
            let harness = try AgentHarness()
            harness.clock.autoAdvance = true
            let (location, runtime) = try await Self.evictionTree(harness)

            let (readme, _) = try await runtime.identifier(forPath: "README.txt")
            let (clip, _) = try await runtime.identifier(forPath: "Media/clip.mov")
            let (notes, _) = try await runtime.identifier(forPath: "Documents/notes.txt")
            let (media, _) = try await runtime.identifier(forPath: "Media")
            for (identifier, name) in [(readme, "readme"), (clip, "clip"), (notes, "notes")] {
                try await Self.fetch(runtime, identifier, into: harness, named: name)
            }
            let fetchedAt = try #require(
                try await runtime.evictionRows(identifiers: [readme]).first?.lastFetch)
            _ = try await runtime.applyPin(pathString: "Documents", request: .keep)

            // `README.txt` has a pending upload; `Documents/notes.txt` is kept. The system
            // answers both with the same dictionary.
            harness.replica.setPending([readme], locationID: location.id)
            harness.replica.refuseEviction(identifier: readme, report: Self.mq018Refusal())
            harness.replica.refuseEviction(identifier: notes, report: Self.mq018Refusal())

            let pendingRefusal = await harness.replica.evict(
                locationID: location.id, identifier: readme)
            let keptRefusal = await harness.replica.evict(
                locationID: location.id, identifier: notes)
            #expect(pendingRefusal["errorCode"] as? Int == -2008)
            #expect(keptRefusal["errorCode"] as? Int == -2008)
            #expect(
                Self.shape(pendingRefusal) == Self.shape(keptRefusal),
                "G3: the two refusals are the same value; -2007 never appears")

            // The bite-proof for gotcha 82: a check reading "a -2008 means the item is kept"
            // out of the error code, injected here as a copy, against the two reports the
            // system really returns. It labels the pending upload exactly as it labels the
            // pin, so any code that reads a pin out of the error code is reading a coin flip.
            func aPinReadOutOfTheErrorCode(_ report: [String: Any]) -> Bool {
                (report["errorCode"] as? Int) == -2008
            }
            #expect(
                aPinReadOutOfTheErrorCode(pendingRefusal)
                    == aPinReadOutOfTheErrorCode(keptRefusal),
                "G3: the old logic cannot tell a pending upload from a pin, so nothing may")

            // The pass: the pending item is refused and passed over, and the loop carries
            // on to the next file.
            harness.replica.setReplicaTimes(
                identifier: readme, atime: fetchedAt, mtime: fetchedAt, locationID: location.id)
            harness.replica.setReplicaTimes(
                identifier: clip, atime: fetchedAt, mtime: fetchedAt + 10,
                locationID: location.id)
            harness.replica.setMaterialized([readme, clip, notes], locationID: location.id)
            harness.replica.resetCalls()

            let evictor = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .oneHour,
                environment: harness.environment)
            await evictor.setTTLOverride(seconds: 60)
            let pass = await evictor.runPass(reason: "g3", now: fetchedAt + 280)

            let attempted = harness.replica.calls.compactMap { call -> String? in
                if case let .evict(_, identifier) = call { return identifier }
                return nil
            }
            #expect(
                attempted == [readme, clip],
                "G3: the refused item is passed over, in order, and the pass continues")
            #expect(pass["evicted"] as? Int == 1)
            #expect(harness.replica.evictedIdentifiers == [clip])
            #expect(pass["skippedKept"] as? Int == 1, "G3: the kept item never reached the system")

            let refused = try #require(pass["refused"] as? [[String: Any]])
            #expect(refused.count == 1)
            #expect(refused[0]["path"] as? String == "README.txt")
            #expect(refused[0]["code"] as? Int == -2008)
            #expect(
                Set(refused[0].keys) == Set(["path", "error", "code"]),
                "G3: the report carries the error and no conclusion drawn from it")

            // Nothing was written to the row: no pin, no kept, and the content is still
            // recorded as downloaded, so the next pass tries again.
            let (_, after) = try await runtime.identifier(forPath: "README.txt")
            #expect(after.pinState == 0, "G3: a -2008 is not a pin")
            #expect(!after.kept)
            #expect(after.lastFetch != nil, "G3: nothing was evicted, so nothing was cleared")

            // `MQ-019`: the parent directory of a pending item, refused opaquely.
            harness.replica.refuseEviction(identifier: media, report: Self.mq019Refusal())
            let directory = try await evictor.evictPath("Media")
            #expect(directory["evicted"] as? Bool == false)
            #expect(directory["errorDomain"] as? String == "NSCocoaErrorDomain")
            #expect(directory["errorCode"] as? Int == 4101)
            #expect(
                directory["underlyingReason"] as? String == "contentVersionMismatch",
                "G3: the underlying reason is carried through and read by nobody")
            #expect(directory["attempts"] as? Int == 5)
            #expect(
                directory["kept"] == nil && directory["pinned"] == nil,
                "G3: 4101 is not turned into a statement about a pin either")
        }

        /// **G11** - `pins --export` / `pins --import` and the `pins.json` sidecar
        /// (docs/design/pinning.md).
        ///
        /// Driven through the real command handler, because the import is the handler's:
        /// it applies the markers shortest path first, so a pin above an exclusion is
        /// written before the exclusion that invariant 2 would otherwise wipe. What is
        /// asserted is the pinning algebra (docs/design/pinning.md) surviving a round trip: the exported set is
        /// the *smallest* one that produces the effect (invariant 3), an exclusion nested
        /// under a pin comes back nested under it, an import clears every explicit state
        /// beneath a path it sets (invariant 2), and a second import of the same file
        /// changes nothing.
        ///
        /// The markers are the index's, never the sidecar's: `pins.json` is "a write-only
        /// copy for recovery, never read while the index is healthy" (docs/design/item-index.md), and
        /// this asserts it is written and that it matches - not that anything reads it.
        /// No macOS measurement is involved in the round trip itself; `MQ-027` is what
        /// makes the nested exclusion worth preserving, since an explicit lazy child is
        /// what overrides an eager ancestor.
        @Test func g11PinsExportAndImportRoundTrip() async throws {
            let harness = try AgentHarness()
            let added = try await harness.control("debug.fake.add", ["name": "nas", "files": "3"])
            let spareAdded = try await harness.control(
                "debug.fake.add", ["name": "spare", "files": "3"])
            let nasID = try #require(added["id"] as? String)
            _ = try #require(spareAdded["id"] as? String)

            // A pin with an exclusion nested inside it.
            _ = try await harness.control("pin", ["name": "nas", "path": "Documents"])
            _ = try await harness.control("unpin", ["name": "nas", "path": "Documents/Reports"])

            let exported = try await harness.control("pins", ["name": "nas", "export": "true"])
            #expect(
                Self.markerPairs(exported) == [
                    ("Documents", "pinned"), ("Documents/Reports", "excluded"),
                ].map { [$0.0, $0.1] },
                "G11: two markers, and the exclusion is the one under the pin")

            // Invariant 3 in the export: nothing redundant was ever written. The three
            // files under the pin are kept by inheritance and carry no marker of their own.
            let pins = try #require(exported["pins"] as? [[String: Any]])
            #expect(pins.count == 2, "G11: a marker per *change*, not per kept path")

            // The sidecar beside the index holds the same list (docs/design/item-index.md).
            let sidecarURL = try GroupContainer.pinsURL(locationID: nasID)
            let sidecar = try #require(
                try JSONSerialization.jsonObject(with: try Data(contentsOf: sidecarURL))
                    as? [String: Any])
            #expect(sidecar["location"] as? String == nasID)
            #expect(Self.markerPairs(sidecar) == Self.markerPairs(exported))

            // The round trip: the exported file, imported onto a location with no markers
            // at all, reproduces the set exactly.
            let payload = try Self.json(["pins": pins])
            let imported = try await harness.control(
                "pins", ["name": "spare", "import": payload])
            #expect((imported["failed"] as? [String])?.isEmpty == true)
            #expect((imported["imported"] as? [String])?.count == 2)
            let spare = try await harness.control("pins", ["name": "spare", "export": "true"])
            #expect(
                Self.markerPairs(spare) == Self.markerPairs(exported),
                "G11: the marker set round-trips exactly, exclusions nested under pins included")

            // Importing the same file again is a no-op: the markers already match.
            let again = try await harness.control("pins", ["name": "spare", "import": payload])
            #expect((again["failed"] as? [String])?.isEmpty == true)
            let spareAgain = try await harness.control(
                "pins", ["name": "spare", "export": "true"])
            #expect(
                Self.markerPairs(spareAgain) == Self.markerPairs(exported),
                "G11: idempotent when the file matches what the location already has")

            // Invariant 2 on import: a file that sets `Documents` clears every explicit
            // state beneath it, exclusion included, as if nothing below had ever been
            // marked.
            let justThePin = try Self.json(
                ["pins": [["path": "Documents", "state": "pinned"]]])
            _ = try await harness.control("pins", ["name": "spare", "import": justThePin])
            let cleared = try await harness.control("pins", ["name": "spare", "export": "true"])
            #expect(
                Self.markerPairs(cleared) == [["Documents", "pinned"]],
                "G11: invariant 2 - the nested exclusion is gone, not merged")

            // Invariant 3 through the handler: "keep this" on the excluded folder inside
            // the still-pinned parent removes the exclusion rather than writing a pin, so
            // the exported set stays the smallest one.
            let smallest = try await harness.control(
                "pin", ["name": "nas", "path": "Documents/Reports"])
            #expect(smallest["situation"] as? String == "exclusionRoot")
            #expect(
                smallest["marker"] as? Int == 0,
                "G11: the exclusion is removed; no pin is written inside a kept subtree")
            let afterward = try await harness.control("pins", ["name": "nas", "export": "true"])
            #expect(Self.markerPairs(afterward) == [["Documents", "pinned"]])
        }

        /// **G12** - the agent's own `stat` under `~/Library/CloudStorage` is allowed.
        ///
        /// `MQ-060` (measured on macOS 26.4, 2026-09-04): a launchd agent's `stat` and `open`
        /// under its **own** domain's mount draw no TCC prompt and no `EPERM`. `tccd`
        /// denies the agent `kTCCServiceSystemPolicyAllFiles`, which it does not need, and
        /// then allows the access as `kTCCServiceFileProviderDomain` with our own domain
        /// as the indirect object, silently. The rule in the model is therefore a
        /// **no-op**: the TTL loop's `getUserVisibleURL` and the `lstat` behind it just
        /// work, and `sshdrive doctor` carries no line for it (docs/design/eviction.md).
        ///
        /// **Confidence.** TCC cannot be modelled: it is a VM-only measurement
        /// (`docs/design/testing.md` section 7), so nothing here proves what macOS
        /// does - the row does, and a new macOS release is a new column in that table, not
        /// a new test. What this scenario defends is the half we control: that our code
        /// does not *add* a guard, a permission probe, a prompt path or a fallback around
        /// an access that is not gated. The second half asks the counterfactual - what if
        /// the rule changed? - through `FakeReplica`'s scripted denial, purely to pin down
        /// the answer the code already gives: the `stat` is absent, so the TTL is decided
        /// from the index's own `last_fetch` and mtime, and the pin's replica lookup
        /// reports the error and leaves the markers alone. Neither is a claim about macOS.
        @Test func g12TheAgentsOwnStatUnderItsMountIsNotGated() async throws {
            let harness = try AgentHarness()
            let (location, runtime) = try await Self.evictionTree(harness)
            let (readme, _) = try await runtime.identifier(forPath: "README.txt")
            let (clip, _) = try await runtime.identifier(forPath: "Media/clip.mov")
            for (identifier, name) in [(readme, "readme"), (clip, "clip")] {
                try await Self.fetch(runtime, identifier, into: harness, named: name)
            }
            let fetchedAt = try #require(
                try await runtime.evictionRows(identifiers: [readme]).first?.lastFetch)
            for identifier in [readme, clip] {
                harness.replica.setReplicaTimes(
                    identifier: identifier, atime: fetchedAt + 257, mtime: fetchedAt,
                    locationID: location.id)
            }

            // The mount is the domain's own, under `~/Library/CloudStorage`.
            #expect(harness.replica.mountRoot.lastPathComponent == "CloudStorage")
            let url = try await harness.environment.replica.userVisibleURL(
                locationID: location.id, identifier: readme)
            #expect(url.path.hasPrefix(harness.replica.mountRoot.path))

            harness.replica.setMaterialized([readme], locationID: location.id)
            harness.replica.resetCalls()
            let evictor = CacheEvictor(
                locationID: location.id, runtime: runtime, ttl: .oneHour,
                environment: harness.environment)
            await evictor.setTTLOverride(seconds: 60)
            let pass = await evictor.runPass(reason: "g12", now: fetchedAt + 280)

            #expect(pass["evicted"] as? Int == 1, "MQ-060: the loop reaches its own mount")
            #expect(
                Self.lookups(harness).count == 1,
                "MQ-060: one lookup, with no permission probe in front of it and no retry behind it - the access is not gated, so there is nothing to guard")

            // The whole conversation with the system, for one candidate, is the
            // enumerator, the lookup and the eviction - in that order and with nothing
            // else in it. No pre-flight probe, no permission request, no second path for
            // a denial, which is also why `sshdrive doctor` carries no line for this and
            // why there is nothing for a user to grant (docs/design/eviction.md).
            #expect(
                harness.replica.calls.map(Self.name(of:))
                    == ["materialized", "userVisibleURL", "evict"],
                "MQ-060: an ungated access, with nothing wrapped around it")

            // The counterfactual. If the rule ever changed, this is the answer the code
            // already has - and it is not a prompt, a probe or a retry.
            harness.replica.setTCCDenial(true)
            harness.replica.setMaterialized([clip], locationID: location.id)
            harness.replica.resetCalls()
            let denied = await evictor.runPass(reason: "g12-denied", now: fetchedAt + 280)
            #expect(
                denied["evicted"] as? Int == 1,
                "the TTL falls back to the index's own last_fetch and mtime, which is the same answer the loop gives for a file the system has not written yet")
            #expect(
                Self.lookups(harness).count == 1,
                "one attempt, swallowed; the loop does not re-ask or escalate")
            #expect(harness.replica.evictedIdentifiers == [readme, clip])

            // The pin replica lookup (docs/design/pinning.md, step 1) under the same denial:
            // reported, and the
            // markers - which are the index's, not the system's - are written regardless.
            let report = try await runtime.applyPin(pathString: "Media", request: .keep)
            #expect(report["changed"] as? Bool == true)
            let (_, mediaRow) = try await runtime.identifier(forPath: "Media")
            #expect(mediaRow.kept, "the pin is the index's; the lookup is only what starts the download")
            let lookup = await harness.environment.replica.lookUpInReplica(
                locationID: location.id, identifier: mediaRow.identifier)
            #expect(lookup["errorDomain"] as? String == NSPOSIXErrorDomain)
            #expect(lookup["errorCode"] as? Int == Int(EPERM))
            #expect(lookup["lstat"] == nil, "the stat never happened, and nothing pretends it did")

            // Back to the measured world.
            harness.replica.setTCCDenial(false)
            let times = harness.environment.replica.replicaTimes(url: url)
            #expect(times?.mtime == fetchedAt)
        }

        // MARK: What the scenarios above stage

        /// `MQ-018`: a pending upload and a kept item are refused with **this** value, and
        /// -2007 never appears.
        static func mq018Refusal() -> [String: Any] {
            [
                "errorDomain": "NSFileProviderErrorDomain",
                "errorCode": -2008,
                "errorDescription": "The item could not be evicted.",
            ]
        }

        /// `MQ-019`: the parent directory of a pending item, refused as
        /// `NSCocoaErrorDomain` 4101 with a `libfssync` reason underneath - not -2006.
        static func mq019Refusal() -> [String: Any] {
            [
                "errorDomain": "NSCocoaErrorDomain",
                "errorCode": 4101,
                "errorDescription": "Couldn't communicate with a helper application.",
                "underlyingDomain": "libfssync.VFSFileTree.ItemNotFoundReason",
                "underlyingCode": 5,
                "underlyingReason": "contentVersionMismatch",
            ]
        }

        /// `MQ-033`: the root container meets a kept child and fails as a whole. The row
        /// records the behaviour and not a code - `MQ-020` says -2006 is what the system
        /// reserves for a child that refuses - which is exactly why nothing reads one.
        static func mq033Refusal() -> [String: Any] {
            [
                "errorDomain": "NSFileProviderErrorDomain",
                "errorCode": -2006,
                "errorDescription": "The item could not be evicted because of its children.",
            ]
        }

        /// `MQ-034`: for 5-10 s after an unpin, `NSCocoaErrorDomain` "The file couldn't be
        /// opened", naming no reason at all.
        static func mq034Refusal() -> [String: Any] {
            [
                "errorDomain": "NSCocoaErrorDomain",
                "errorCode": 256,
                "errorDescription": "The file couldn't be opened.",
            ]
        }

        /// A report as a comparable value, so two runs can be asserted identical without
        /// caring what type each field happens to be.
        static func shape(_ report: [String: Any]) -> [String: String] {
            report.mapValues { "\($0)" }
        }

        static func evictAttempts(_ harness: AgentHarness, _ identifier: String) -> [String] {
            harness.replica.calls.compactMap { call in
                if case let .evict(_, asked) = call, asked == identifier { return asked }
                return nil
            }
        }

        /// A call named the way the assertions above spell it.
        static func name(of call: FakeReplica.Call) -> String {
            switch call {
            case .domains: return "domains"
            case .addDomain: return "addDomain"
            case .removeDomain: return "removeDomain"
            case .signalEnumerator: return "signalEnumerator"
            case .signalErrorResolved: return "signalErrorResolved"
            case .materialized: return "materialized"
            case .pending: return "pending"
            case .evict: return "evict"
            case .userVisibleURL: return "userVisibleURL"
            case .identifierForFile: return "identifierForFile"
            case .stabilize: return "stabilize"
            case .testingOperations: return "testingOperations"
            }
        }

        static func lookups(_ harness: AgentHarness) -> [String] {
            harness.replica.calls.compactMap { call in
                if case let .userVisibleURL(_, identifier) = call { return identifier }
                return nil
            }
        }

        /// `[[path, state], …]`, sorted, from anything that carries a `pins` array - the
        /// export, the sidecar, or a hand-written file.
        static func markerPairs(_ payload: [String: Any]) -> [[String]] {
            ((payload["pins"] as? [[String: Any]]) ?? [])
                .map { [$0["path"] as? String ?? "", $0["state"] as? String ?? ""] }
                .sorted { $0.lexicographicallyPrecedes($1) }
        }

        static func json(_ object: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }

        /// One materialized file, so the row has a `last_fetch` for the TTL to measure
        /// from.
        static func fetch(
            _ runtime: LocationRuntime, _ identifier: String, into harness: AgentHarness,
            named: String
        ) async throws {
            let destination = harness.container.appendingPathComponent("\(named).tmp")
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            _ = try await runtime.fetchContents(
                identifier: identifier, into: handle, transferID: named, kind: .foreground)
            try? handle.close()
        }

        /// `README.txt`, `Media/clip.mov`, `Documents/notes.txt` and
        /// `Documents/Reports/q1.txt`, every directory listed: two files a pin on
        /// `Documents` keeps and two it does not.
        static func evictionTree(_ harness: AgentHarness) async throws -> (Location, LocationRuntime) {
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            for directory in ["Documents", "Documents/Reports", "Media"] {
                try await fake.apply(
                    .createDirectory(path: try RelativePath(string: directory), mode: 0o755))
            }
            for (path, body) in [
                ("README.txt", "readme"), ("Media/clip.mov", "clip"),
                ("Documents/notes.txt", "notes"), ("Documents/Reports/q1.txt", "q1"),
            ] {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: path), contents: Data(body.utf8),
                        mode: 0o644))
            }
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            for directory in ["Documents", "Documents/Reports", "Media"] {
                let (identifier, _) = try await runtime.identifier(forPath: directory)
                _ = try await runtime.enumerateItems(container: identifier, pageToken: nil)
            }
            return (location, runtime)
        }
    }
}
