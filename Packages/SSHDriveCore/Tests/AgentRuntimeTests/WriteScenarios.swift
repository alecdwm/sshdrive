import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import ProviderCore
import SFTP
import ServerModel
import Testing
import XPCProtocols

/// Suite D's write half and suite G's scheduler, on the agent's side
/// (docs/design/testing.md).
///
/// Most of these run against the in-memory agent fakes, because what they are about is a
/// decision `LocationRuntime` and `RemoteWriter` make. Two of them - **D10** and **D11** -
/// run against `ServerModel.FakeSFTPServer` over a real SFTP v3 wire, handed to the
/// location through `FakeTransportLauncher.transportFactory`, because what they are about
/// is what the *server* does: the umask a create's attributes go through (`SQ-033`), the
/// two rename semantics (`SQ-034`), and a `remove` that really removes.
extension AgentScenarios {

    @Suite struct WriteScenarios {

        // MARK: - D2: the conflict copy evicts, retried

        /// **D2** (`MQ-013`, `MQ-017`, `MQ-018`) - the conflict copy evicts, retried.
        ///
        /// A local edit meets a remote change made between the `baseVersion` the system
        /// passed us and now. The write policy (docs/design/writes.md): the temp file,
        /// which already holds the local content, becomes
        /// `<name> (conflicted copy from <Mac> <date>).<ext>` beside the original, the
        /// **remote** item is returned, the new sibling gets an anchor so Finder shows it
        /// at once, and the item is then evicted - because the system believes whatever
        /// version a `modifyItem` reply carries (`MQ-013`), so returning the remote version
        /// on its own would leave the replica holding the *local* bytes under the *remote*
        /// version for ever.
        ///
        /// The eviction cannot be done once: issued straight after the reply it is refused
        /// `-2008 NSFileProviderErrorNonEvictable`, because the system is still finishing
        /// the modification it has just been told about (`MQ-017`). The refusal says
        /// nothing about why (`MQ-018`), so the loop does not read it - it waits and asks
        /// again. This asserts the **schedule**, not just the outcome.
        @Test func d2TheConflictCopyIsEvictedOnTheRetry() async throws {
            let clock = VirtualAgentClock(autoAdvance: true)
            let harness = try AgentHarness(clock: clock)
            let (location, fake, runtime) = try await Self.oneFile(harness)
            let (identifier, row) = try await runtime.identifier(forPath: "README.txt")
            let base = row.contentVersion

            // The server moved under the user, between the base version and now.
            let remoteBytes = Data("the server's own newer bytes".utf8)
            try await fake.apply(
                .write(path: try RelativePath(string: "README.txt"), contents: remoteBytes))

            // Nothing has been asked of the replica yet: the eviction is the caller's, and
            // it must come *after* the reply has gone (docs/design/writes.md).
            harness.replica.resetCalls()

            let localBytes = Data("the local edit that must not be lost".utf8)
            let result = try await runtime.modifyItem(
                identifier: identifier,
                changedFields: [.contents],
                baseVersion: base,
                newParentIdentifier: nil,
                newFilename: nil,
                newExtendedAttributes: nil,
                contents: try Self.handle(harness, name: "d2-local", bytes: localBytes))

            #expect(result.evictAfterReply, "D2: the reply owes an eviction")
            #expect(
                result.snapshot.size == Int64(remoteBytes.count),
                "D2: the **remote** item is what is returned as current")
            #expect(
                harness.replica.calls.isEmpty,
                "D2: `modifyItem` itself evicts nothing; the eviction follows the reply")

            // The conflict copy is a sibling holding the local content, with an anchor of
            // its own so the working-set signal below can carry it (docs/design/writes.md,
            // MQ-001: a folder is enumerated once, ever).
            let rows = try await runtime.dumpIndex()
            let copyRow = try #require(
                rows.first { String(decoding: $0.path, as: UTF8.self).contains("conflicted copy from") })
            let copyPath = String(decoding: copyRow.path, as: UTF8.self)
            #expect(copyPath.hasSuffix(".txt"), "D2: the extension is kept (docs/design/writes.md)")
            let kept = try await fake.read(try RelativePath(string: copyPath), offset: 0, length: nil)
            #expect(kept == localBytes, "D2: the copy holds the local bytes, so nothing is lost")
            let anchors = try await runtime.dumpAnchors(limit: 50)
            #expect(
                anchors.contains { $0.identifier == copyRow.identifier && $0.kind == .modified },
                "D2: the new sibling has an anchor, or nobody will ever ask for it")

            // Now the caller's half, exactly as `Apps/Agent`'s `modifyItem` runs it: the
            // reply, then the working-set signal, then the eviction with its backoff.
            harness.replica.refuseEviction(
                identifier: identifier, report: Self.nonEvictable, times: 1)
            let sleepsBefore = clock.requestedSleeps.count
            await harness.replica.signalWorkingSet(locationID: location.id)
            await harness.replica.evictAfterConflict(
                locationID: location.id, identifier: identifier, sleeper: clock)

            #expect(
                harness.replica.signalledContainers.contains { $0.contains("WorkingSet") },
                "D2: without the signal Finder shows the copy only at the next enumeration")
            #expect(
                harness.replica.evictedIdentifiers == [identifier],
                "D2: the retry evicted it, so the next open downloads the remote content")
            #expect(
                Array(clock.requestedSleeps.dropFirst(sleepsBefore)) == [0.25, 0.25],
                "D2: 0.25 s before the first attempt (MQ-017), then 0.25 s before the retry")

            // The order matters as much as the fact: the signal goes out before the
            // eviction, and the eviction is two calls, not one.
            let calls = harness.replica.calls
            let signalled = try #require(
                calls.firstIndex {
                    if case let .signalEnumerator(_, container) = $0 {
                        return container.contains("WorkingSet")
                    }
                    return false
                })
            let evictions = calls.indices.filter {
                if case .evict = calls[$0] { return true } else { return false }
            }
            #expect(evictions.count == 2, "D2: the first was refused, the second was taken")
            #expect(signalled < evictions[0])
        }

        /// **D2** (`MQ-017`, `MQ-018`) - the retry schedule itself: 0.25 s doubling, capped
        /// at 8 s, seven attempts, and a giving-up that is logged rather than silent.
        ///
        /// The measurement behind `MQ-017` is only ever "the first retry was enough". The
        /// schedule the agent runs is the one docs/design/writes.md writes down, and this
        /// is what pins it: a run that needs five attempts, and a run that never succeeds.
        @Test func d2TheEvictionBackoffDoublesAndIsCappedAtEight() async throws {
            let clock = VirtualAgentClock(autoAdvance: true)
            let harness = try AgentHarness(clock: clock)
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)

            harness.replica.refuseEviction(
                identifier: "slow", report: Self.nonEvictable, times: 4)
            var before = clock.requestedSleeps.count
            await harness.replica.evictAfterConflict(
                locationID: location.id, identifier: "slow", sleeper: clock)
            #expect(
                Array(clock.requestedSleeps.dropFirst(before)) == [0.25, 0.25, 0.5, 1, 2],
                "D2: the pre-attempt wait, then a doubling backoff")
            #expect(harness.replica.evictedIdentifiers == ["slow"])

            // And one that never becomes evictable: seven attempts, the delay capped at
            // 8 s, and the replica still holding the local bytes - which is what the log
            // line at the end of `evictAfterConflict` is for.
            harness.replica.refuseEviction(identifier: "stuck", report: Self.nonEvictable)
            before = clock.requestedSleeps.count
            await harness.replica.evictAfterConflict(
                locationID: location.id, identifier: "stuck", sleeper: clock)
            #expect(
                Array(clock.requestedSleeps.dropFirst(before)) == [0.25, 0.25, 0.5, 1, 2, 4, 8, 8],
                "D2: seven attempts, doubling from 0.25 s, capped at 8 s")
            #expect(!harness.replica.evictedIdentifiers.contains("stuck"))
        }

        // MARK: - D6: in-flight paths are invisible to change detection

        /// **D6** (`MQ-013`) - an upload in flight is invisible to change detection.
        ///
        /// Between the rename landing and the post-upload `lstat` (docs/design/writes.md),
        /// the path on the server carries content the index does not know about yet. A
        /// differ that looked in that window would report the agent's own write as a
        /// remote change and make the system re-fetch the file it had just written - and
        /// since the system believes the version in our reply and never re-fetches on its
        /// own (`MQ-013`), what the index says about that path is the only account of it
        /// there is. So every path with an upload in flight sits in a per-location
        /// in-flight set and the differ skips it.
        ///
        /// The cycle is held open at the `setstat` that follows the rename, which is
        /// exactly that window, and the control at the end is what makes the assertion mean
        /// something: the same cycle, over the same directory, *does* report a real remote
        /// change.
        @Test func d6AnUploadInFlightIsNotReadBackAsARemoteChange() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "Docs"), mode: 0o755))
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "Docs/note.txt"),
                    contents: Data("draft".utf8), mode: 0o644))
            let wire = InterposingTransport(fake)
            let runtime = try harness.makeRuntime(location: location, transport: wire)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let (directoryIdentifier, directoryRow) = try await runtime.identifier(forPath: "Docs")
            _ = try await runtime.enumerateItems(container: directoryIdentifier, pageToken: nil)
            let (identifier, row) = try await runtime.identifier(forPath: "Docs/note.txt")
            let versionBeforeTheSave = row.contentVersion

            // The save. Held at the `setstat` after the rename: the server now holds our
            // new bytes and the index still holds the old version.
            wire.hold(.setstat)
            let bytes = Data("a much longer body than the draft had".utf8)
            let save = Task {
                try await runtime.modifyItem(
                    identifier: identifier,
                    changedFields: [.contents],
                    baseVersion: nil,
                    newParentIdentifier: nil,
                    newFilename: nil,
                    newExtendedAttributes: nil,
                    contents: try Self.handle(harness, name: "d6-local", bytes: bytes))
            }
            #expect(
                await Self.waitUntil { !wire.arrivals(of: .setstat).isEmpty },
                "the upload should be held in the write protocol's window (docs/design/writes.md)")
            let dirty = await runtime.writerInFlightPaths()
            #expect(
                dirty.contains(Data("Docs/note.txt".utf8)),
                "D6: the path is in the in-flight set while the upload is landing")

            // A detection cycle over the same directory, right now.
            let sequenceBefore = try await runtime.currentSequence()
            let cycle = await runtime.listOne(Data("Docs".utf8))
            #expect(
                !cycle.changed.contains { $0.identifier == identifier },
                "D6: our own write is not a remote change")
            #expect(cycle.deleted.isEmpty, "D6: nor is it a deletion; the path was seen")
            let carried = try await runtime.workingSetChanges(since: sequenceBefore)
            #expect(
                !carried.items.contains { $0.identifier == identifier },
                "D6: and nothing about it reaches the working set")
            let held = try await runtime.row(identifier: identifier)
            #expect(
                held?.contentVersion == versionBeforeTheSave,
                "D6: the row is the upload's to write, and it has not written it yet")

            // Released, the upload's own post-upload `lstat` is what writes the row.
            wire.release(.setstat)
            let saved = try await save.value
            #expect(saved.snapshot.size == Int64(bytes.count))
            let after = try await runtime.row(identifier: identifier)
            #expect(after?.contentVersion != versionBeforeTheSave)
            #expect(await runtime.writerInFlightPaths().isEmpty, "the set is released after")

            // The next cycle finds a version the index already holds and reports nothing,
            // which is the other half of the write protocol's promise (docs/design/writes.md).
            let quiet = await runtime.listOne(Data("Docs".utf8))
            #expect(
                !quiet.changed.contains { $0.identifier == identifier },
                "D6: the post-upload row is what makes the next cycle silent")

            // The control: a change that really is the server's is still found. Without
            // this the assertions above would pass for a differ that reports nothing at all.
            try await fake.apply(
                .write(
                    path: try RelativePath(string: "Docs/note.txt"),
                    contents: Data("somebody else wrote this".utf8)))
            let real = await runtime.listOne(Data("Docs".utf8))
            #expect(
                real.changed.contains { $0.identifier == identifier },
                "D6: a real remote change is still reported")
            _ = directoryRow
        }

        // MARK: - D10: the temp+rename upload, on the wire

        /// **D10** (`SQ-033`, `SQ-028`, `MQ-013`) - the upload protocol
        /// (docs/design/writes.md), end to end, against a server that really speaks
        /// SFTP v3.
        ///
        /// The bytes go to `.sshdrive-upload-<mac8>-<uuid>` beside the destination, the
        /// destination is `lstat`ed immediately before the rename, the replacement is
        /// `posix-rename@openssh.com`, and only then are the mode and the modification date
        /// set back and the result `lstat`ed. Two of those steps are only there because of
        /// the server:
        ///
        /// - `SQ-033`: a create's attributes go through the server's **umask**, so the temp
        ///   file lands with bits taken off the mode that was asked for. This holds the
        ///   upload at the rename and looks at the temp file to prove it, then asserts the
        ///   `setstat` afterwards is what makes the asked-for mode true.
        /// - the post-upload `lstat` (`MQ-013`): the system believes whatever version the
        ///   reply carries, so a version we invent is one nothing will ever correct. The
        ///   row's version has to come from what the server read back.
        @Test func d10TheTempRenameUploadRestoresModeAndMtimeOnTheWire() async throws {
            let harness = try AgentHarness()
            let server = FakeSFTPServer(profile: .debian)
            server.putDirectory("Docs")
            server.put("Docs/notes.txt", contents: Data("old".utf8), mode: 0o664)
            let wire = InterposingTransport(
                try await RealSFTPTransport.connect(stream: server.makeStream(), root: server.root))
            let (location, runtime) = try await Self.wireLocation(harness, server: server, transport: wire)

            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let (directoryIdentifier, _) = try await runtime.identifier(forPath: "Docs")
            _ = try await runtime.enumerateItems(container: directoryIdentifier, pageToken: nil)
            let (identifier, row) = try await runtime.identifier(forPath: "Docs/notes.txt")
            #expect(row.mode == 0o664, "the file the server really has")
            server.clearRequestLog()

            // Held at the rename, which is where the temp file is at its most interesting.
            wire.hold(.posixRename)
            let bytes = Data("a new body, saved from the Mac".utf8)
            let modified: Int64 = 1_600_000_042
            let save = Task {
                try await runtime.modifyItem(
                    identifier: identifier,
                    changedFields: [.contents],
                    baseVersion: nil,
                    newParentIdentifier: nil,
                    newFilename: nil,
                    newModificationDate: modified,
                    newExtendedAttributes: nil,
                    contents: try Self.handle(harness, name: "d10-local", bytes: bytes))
            }
            #expect(
                await Self.waitUntil { wire.arrivals(of: .posixRename).contains("Docs/notes.txt") },
                "the upload should be held at the rename")

            let temporaries = server.names(in: "Docs").filter {
                $0.hasPrefix(".sshdrive-upload-")
            }
            #expect(temporaries.count == 1, "D10: one temp file, beside the destination")
            let temporary = try #require(temporaries.first)
            #expect(
                temporary.hasPrefix(".sshdrive-upload-\(Self.macID)-"),
                "D10: the name carries the Mac that made it (docs/design/writes.md)")
            #expect(
                server.contents(of: "Docs/\(temporary)") == bytes,
                "D10: the bytes are in the temp file, not in the destination")
            #expect(
                server.contents(of: "Docs/notes.txt") == Data("old".utf8),
                "D10: the destination is untouched until the rename")
            #expect(
                server.mode(of: "Docs/\(temporary)") == 0o664 & ~ServerProfile.debian.umask,
                "SQ-033: the create's attributes went through the server's umask")

            wire.release(.posixRename)
            let saved = try await save.value

            // The rename took the name, and the mode and the date were put back after it.
            #expect(server.contents(of: "Docs/notes.txt") == bytes)
            #expect(
                server.names(in: "Docs").allSatisfy { !$0.hasPrefix(".sshdrive-upload-") },
                "D10: the temp name is gone; the rename is what consumed it")
            #expect(
                server.mode(of: "Docs/notes.txt") == 0o664,
                "SQ-033: a `setstat` after the rename is what makes the asked-for mode true")
            #expect(
                server.node("Docs/notes.txt")?.mtime == modified,
                "D10: the date the system passed in, truncated to whole seconds")

            // The reply carries what the server read back, never a version of our own.
            #expect(saved.snapshot.size == Int64(bytes.count))
            #expect(
                saved.snapshot.contentVersion.hasPrefix("\(bytes.count)-\(modified)-"),
                "MQ-013: the version comes from the post-upload `lstat`")
            let stored = try #require(try await runtime.row(identifier: identifier))
            #expect(stored.inode == nil, "docs/design/item-index.md: the rename gave the path a new inode")
            #expect(stored.mtimeNanoseconds == nil)

            // And the protocol really was in that order, on the wire.
            let log = server.requests
            let opened = try #require(log.firstIndex { $0.hasPrefix("open ") && $0.contains(".sshdrive-upload-") })
            let checked = try #require(log.firstIndex { $0 == "lstat \(server.root)/Docs/notes.txt" })
            let renamed = try #require(log.firstIndex { $0.hasPrefix("posix-rename ") })
            let restored = try #require(log.firstIndex { $0 == "extended lsetstat@openssh.com" })
            let read = try #require(log.lastIndex { $0 == "lstat \(server.root)/Docs/notes.txt" })
            #expect(opened < checked, "the conflict window is one round trip, after the upload")
            #expect(checked < renamed)
            #expect(renamed < restored, "the mode is restored after the rename, not before")
            #expect(restored < read, "and the row is built from the `lstat` after that")

            // The location was started through the launcher, so it carries a change
            // detector, an eviction loop and a gate. Dropping it is what stops them; a
            // suite is `.serialized` for one harness at a time, not for one process at a
            // time.
            await harness.manager.dropRuntime(locationID: location.id)
        }

        /// **D10** (`SQ-034`, `SQ-028`) - a create meets the two rename semantics.
        ///
        /// The destination is free when the upload `lstat`s it and taken by the time the
        /// rename runs - "a file created meanwhile", which is the case the plain,
        /// non-overwriting rename exists for (docs/design/writes.md). What happens next is
        /// the server's to decide, and the probe is what tells the agent which server it
        /// has (`SQ-034`):
        ///
        /// - OpenSSH refuses, as `link` + `unlink` does. The refusal is a bare `FAILURE`
        ///   with no errno (`SQ-028`), so the agent asks the second question - an `lstat`
        ///   of the destination - before it says `.filenameCollision`.
        /// - a server whose plain `rename` overwrites would eat the bystander's file, so
        ///   every create there gets an `lstat` preflight instead and never reaches the
        ///   rename at all.
        @Test func d10ACreateMeetsBothRenameSemantics() async throws {
            for overwrites in [false, true] {
                let harness = try AgentHarness()
                let server = FakeSFTPServer(
                    profile: ServerProfile.debian.with(renameOverwrites: overwrites))
                let wire = InterposingTransport(
                    try await RealSFTPTransport.connect(
                        stream: server.makeStream(), root: server.root))
                let (location, runtime) = try await Self.wireLocation(
                    harness, server: server, transport: wire)
                _ = try await runtime.enumerateItems(
                    container: IndexWriter.rootIdentifier, pageToken: nil)

                // The probe runs once, in the location root, and its answer is what decides.
                let refuses = await runtime.probeRenameSemantics()
                #expect(refuses == !overwrites, "SQ-034: the probe is what decides")

                // Somebody else takes the name inside the conflict window.
                let bystander = Data("not ours".utf8)
                wire.plantOnNextMiss(of: "new.txt") { server.put("new.txt", contents: bystander) }
                server.clearRequestLog()

                do {
                    _ = try await runtime.createItem(
                        parentIdentifier: IndexWriter.rootIdentifier,
                        filename: "new.txt",
                        isDirectory: false,
                        symlinkTarget: nil,
                        contents: try Self.handle(
                            harness, name: "d10-create", bytes: Data("ours".utf8)))
                    Issue.record("a taken name must not be taken again")
                } catch {
                    #expect(
                        (error as NSError).code == SSHDriveAgentError.filenameCollision.rawValue,
                        "SQ-028: the second question is what turns a bare FAILURE into a collision")
                }

                #expect(
                    server.contents(of: "new.txt") == bystander,
                    "SQ-034: the file that was there is still there")
                #expect(
                    server.names(in: "").allSatisfy { !$0.hasPrefix(".sshdrive-upload-") },
                    "and the upload took its temp file with it")

                let log = server.requests
                let renames = log.filter { $0.hasPrefix("rename ") && $0.contains("new.txt") }
                if overwrites {
                    #expect(
                        renames.isEmpty,
                        "SQ-034: on an overwriting server the preflight refuses before the rename")
                } else {
                    #expect(
                        renames.count == 1,
                        "SQ-034: on a refusing server the rename itself is the check")
                    let renamed = try #require(log.firstIndex { $0.hasPrefix("rename ") })
                    let confirmed = try #require(
                        log.lastIndex { $0 == "lstat \(server.root)/new.txt" })
                    #expect(
                        renamed < confirmed,
                        "SQ-028: the FAILURE is confirmed with an `lstat`, not read as an errno")
                }
                await harness.manager.dropRuntime(locationID: location.id)
            }
        }

        // MARK: - D11: the stale temp sweep takes only our prefix

        /// **D11** (`SQ-074`'s class, `SQ-033`) - the stale temp sweep takes our prefix and
        /// nothing else.
        ///
        /// A temp file carrying **this** Mac's `<mac8>` that is not in the
        /// in-flight set died with a connection or an agent and is removed as soon as the
        /// agent lists its directory, however new it is; one from another Mac is left alone
        /// until it is 30 days old. Everything else in the directory is the user's.
        ///
        /// This is the same class of bug as `SQ-074`'s orphan sweep, where a name-only rule
        /// over `$TMPDIR` found six "orphaned sockets" on a clean install and would have
        /// deleted them. The bite-proof at the end is that rule, run for real against a
        /// second server seeded identically: it takes the bystanders and the live upload
        /// the real sweep leaves alone.
        @Test func d11TheStaleTempSweepTakesOnlyOurPrefix() async throws {
            let harness = try AgentHarness()
            let server = FakeSFTPServer(profile: .debian)
            server.putDirectory("drop")
            server.put("drop/notes.txt", contents: Data("mine".utf8))
            let wire = InterposingTransport(
                try await RealSFTPTransport.connect(stream: server.makeStream(), root: server.root))
            let (location, runtime) = try await Self.wireLocation(
                harness, server: server, transport: wire)
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let (directoryIdentifier, _) = try await runtime.identifier(forPath: "drop")
            _ = try await runtime.enumerateItems(container: directoryIdentifier, pageToken: nil)

            // The directory as an agent that died would have left it, beside names that
            // merely look like ours.
            let now = Date()
            let recent = Int64(now.timeIntervalSince1970)
            let ancient = recent - 40 * 86_400
            for (name, mtime) in Self.temporaryFixtures(now: recent, ancient: ancient) {
                server.put("drop/\(name)", contents: Data("x".utf8), mtime: mtime)
            }

            // And one upload actually in flight, held at the rename so its temp file is on
            // the server and in the writer's live set.
            wire.hold(.rename)
            let live = Task {
                try await runtime.createItem(
                    parentIdentifier: directoryIdentifier,
                    filename: "live.txt",
                    isDirectory: false,
                    symlinkTarget: nil,
                    contents: try Self.handle(harness, name: "d11-live", bytes: Data("live".utf8)))
            }
            #expect(
                await Self.waitUntil { wire.arrivals(of: .rename).contains("drop/live.txt") },
                "the create should be held at the rename")
            let liveTemporary = try #require(
                server.names(in: "drop").first {
                    $0.hasPrefix(".sshdrive-upload-\(Self.macID)-") && !Self.seededOurs.contains($0)
                })

            // The sweep runs as part of a listing, before any row is built.
            _ = await runtime.listOne(Data("drop".utf8))
            let left = Set(server.names(in: "drop"))

            #expect(!left.contains(Self.ourStale), "D11: our own stale temp file went, however new")
            #expect(
                !left.contains(Self.foreignAncient),
                "D11: another Mac's went too, but only at 30 days")
            #expect(
                left.contains(Self.foreignFresh),
                "D11: another Mac's upload may legitimately still be running")
            #expect(
                left.contains(liveTemporary),
                "D11: the temp file of an upload in flight is not stale by definition")
            for bystander in Self.bystanders {
                #expect(left.contains(bystander), "D11: \(bystander) is not ours to delete")
            }
            #expect(left.contains("notes.txt"))

            wire.release(.rename)
            _ = try await live.value
            #expect(
                server.names(in: "drop").contains("live.txt"),
                "and the upload that was in flight landed")

            // The bite-proof. A name-only rule - `SQ-074`'s bug, written the way it reads
            // in a hurry - against a second server with the same directory in it.
            let naive = FakeSFTPServer(profile: .debian)
            naive.putDirectory("drop")
            naive.put("drop/notes.txt", contents: Data("mine".utf8))
            for (name, mtime) in Self.temporaryFixtures(now: recent, ancient: ancient) {
                naive.put("drop/\(name)", contents: Data("x".utf8), mtime: mtime)
            }
            naive.put("drop/\(liveTemporary)", contents: Data("live".utf8), mtime: recent)
            let naiveTransport = try await RealSFTPTransport.connect(
                stream: naive.makeStream(), root: naive.root)
            let directory = try RelativePath(string: "drop")
            for entry in try await naiveTransport.readdir(directory) {
                let name = String(decoding: entry.name, as: UTF8.self)
                guard name.contains("sshdrive-upload") else { continue }
                try? await naiveTransport.remove(try directory.appending(component: entry.name))
            }
            let survivors = Set(naive.names(in: "drop"))
            for bystander in Self.bystanders where bystander.contains("sshdrive-upload") {
                #expect(
                    !survivors.contains(bystander),
                    "the bite: a name-only rule deletes \(bystander), which was never ours")
            }
            #expect(
                !survivors.contains(liveTemporary),
                "the bite: and it deletes the temp file of an upload that is still running")
            #expect(
                !survivors.contains(Self.foreignFresh),
                "the bite: and another Mac's upload from a minute ago")

            await harness.manager.dropRuntime(locationID: location.id)
        }

        // MARK: - G10: the transfer scheduler

        /// **G10** (`MQ-031`, `MQ-032`) - four at once, foreground first, the window split.
        ///
        /// The agent runs at most four transfers at once per location (docs/design/sftp.md),
        /// splits the pipelined window between them, and holds the rest with their XPC
        /// calls open.
        /// Background - the eager downloads of a kept subtree - starts only while no
        /// foreground transfer is waiting, and a running transfer is never pre-empted.
        ///
        /// `MQ-031` measured the system holding at most six `fetchContents` open at once for
        /// an eager subtree; `MQ-032` measured eight files opened from a shell arriving as
        /// eight simultaneous **foreground** calls. So six bounds the *background* class and
        /// says nothing about what the agent may be asked for: the queue is sized to six and
        /// not capped there, and a seventh arrival is admitted and counted.
        @Test func g10FourRunAtOnceAndAForegroundRequestOvertakesTheQueue() async throws {
            let harness = try AgentHarness()
            let (_, gate, runtime) = try await Self.tenFiles(harness)
            gate.hold(.read)

            // Four background transfers, one at a time, so the window each is handed is the
            // split at the moment it started rather than a race.
            var running: [Task<Void, Error>] = []
            for index in 0 ..< 4 {
                running.append(try await Self.fetch(harness, runtime, index: index, kind: .background))
                #expect(
                    await Self.waitUntil { gate.arrivals(of: .read).count == index + 1 },
                    "background \(index) should be running")
            }
            var stats = await runtime.schedulerStatistics()
            #expect(stats.running == 4, "docs/design/sftp.md: at most four at once")
            #expect(stats.peakRunning == 4)
            #expect(
                gate.windows == [16, 8, 5, 4],
                "docs/design/sftp.md: the pipelined window is split between the running transfers")

            // Two more background transfers wait, and the ceiling holds under load.
            for index in 4 ..< 6 {
                running.append(try await Self.fetch(harness, runtime, index: index, kind: .background))
            }
            #expect(
                await Self.waitUntil {
                    await runtime.schedulerStatistics().waitingBackground == 2
                },
                "the fifth and sixth wait with their calls open")
            stats = await runtime.schedulerStatistics()
            #expect(stats.running == 4, "G10: the ceiling holds under load")
            #expect(gate.arrivals(of: .read).count == 4, "and nothing else has started")

            // A foreground request arrives with the queue full: seven held, above the
            // six-fetch ceiling, and it is admitted and counted rather than refused
            // (`MQ-032`: refusing a call the system did make fails a user's open).
            running.append(try await Self.fetch(harness, runtime, index: 6, kind: .foreground))
            #expect(
                await Self.waitUntil {
                    await runtime.schedulerStatistics().waitingForeground == 1
                })
            stats = await runtime.schedulerStatistics()
            #expect(stats.overCeilingAdmissions == 1, "MQ-031/MQ-032: counted, never refused")
            #expect(stats.peakHeld == 7)

            // One background transfer finishes. The foreground one takes the freed slot,
            // ahead of the two background transfers that have been waiting longer.
            gate.release(key: Self.file(0))
            #expect(
                await Self.waitUntil { gate.arrivals(of: .read).count == 5 },
                "the freed slot should be filled")
            #expect(
                gate.arrivals(of: .read).last == Self.file(6),
                "G10: foreground before background, whatever the queue order")

            gate.release(.read)
            for task in running { _ = try await task.value }
            let final = await runtime.schedulerStatistics()
            #expect(final.running == 0)
            #expect(final.admitted == 7, "every transfer ran; none was refused")
        }

        /// **G10** (`MQ-032`) - a cancelled transfer really stops, and frees its slot.
        ///
        /// Cancelling the extension's `Progress`, or its connection going away
        /// (docs/design/extension.md), cancels the transfer's Task and every SFTP request
        /// it has not sent yet, which the caller is owed as the transport's own
        /// `.cancelled`. The slot it was holding goes
        /// back to the scheduler, so the transfer that was waiting behind it starts.
        @Test func g10ACancelledTransferStopsAndFreesItsSlot() async throws {
            let harness = try AgentHarness()
            let (_, gate, runtime) = try await Self.tenFiles(harness)
            gate.hold(.read)

            var running: [Task<Void, Error>] = []
            for index in 0 ..< 4 {
                running.append(try await Self.fetch(harness, runtime, index: index, kind: .foreground))
            }
            #expect(await Self.waitUntil { gate.arrivals(of: .read).count == 4 })
            let waiter = try await Self.fetch(harness, runtime, index: 5, kind: .foreground)
            #expect(
                await Self.waitUntil { await runtime.schedulerStatistics().waitingForeground == 1 })

            // The user closed the window: `Progress.cancel()` reaches the agent as this.
            await runtime.cancel(transferID: Self.file(2))
            do {
                _ = try await running[2].value
                Issue.record("a cancelled transfer must not succeed")
            } catch {
                let nsError = error as NSError
                #expect(
                    nsError.code == SSHDriveAgentError.serverUnreachable.rawValue,
                    "docs/design/extension.md: an abandoned transfer is retryable, never an alert")
                #expect(
                    nsError.localizedDescription.contains("cancelled"),
                    "docs/design/sftp.md: the transport's own `.cancelled`, not Swift's CancellationError")
            }
            #expect(
                Self.bytesOnDisk(harness, index: 2) == 0,
                "G10: the transfer really stopped; nothing more was written")
            #expect(
                await Self.waitUntil { gate.arrivals(of: .read).count == 5 },
                "G10: the cancelled transfer's slot went back to the queue")
            #expect(gate.arrivals(of: .read).last == Self.file(5))

            gate.release(.read)
            for (index, task) in running.enumerated() where index != 2 { _ = try await task.value }
            _ = try await waiter.value
            let stats = await runtime.schedulerStatistics()
            #expect(stats.cancelled == 1)
            #expect(stats.running == 0)
        }

        /// **G10** (`MQ-032`) - eight files opened at once are eight foreground transfers,
        /// and every one of them is served.
        ///
        /// The six-fetch ceiling is an observation about an eager subtree, not a contract:
        /// eight simultaneous opens from a shell reached the extension as eight
        /// `fetchContents` calls. Four run, the rest are held with their calls open, and
        /// `overCeilingAdmissions` is what `status` shows if the observation ever moves.
        @Test func g10EightSimultaneousOpensAreAllAdmitted() async throws {
            let harness = try AgentHarness()
            let (_, gate, runtime) = try await Self.tenFiles(harness)
            gate.hold(.read)

            var running: [Task<Void, Error>] = []
            for index in 0 ..< 8 {
                running.append(try await Self.fetch(harness, runtime, index: index, kind: .foreground))
            }
            #expect(
                await Self.waitUntil { await runtime.schedulerStatistics().waitingForeground == 4 })
            var stats = await runtime.schedulerStatistics()
            #expect(stats.running == 4)
            #expect(
                stats.overCeilingAdmissions == 2,
                "MQ-031/MQ-032: the seventh and eighth are above the ceiling, and admitted")

            gate.release(.read)
            for task in running { _ = try await task.value }
            stats = await runtime.schedulerStatistics()
            #expect(stats.admitted == 8, "every one of the eight was served")
            for index in 0 ..< 8 {
                #expect(Self.bytesOnDisk(harness, index: index) > 0)
            }
        }

        // MARK: - What the scenarios start from

        /// `MQ-017`'s refusal, field by field. `MQ-018`: the code says nothing about why, so
        /// the loop is handed the whole dictionary and reads none of it.
        static var nonEvictable: [String: Any] {
            [
                "errorDomain": "NSFileProviderErrorDomain",
                "errorCode": -2008,
                "errorDescription":
                    "The file couldn't be evicted because it is not evictable right now.",
            ]
        }

        /// The `<mac8>` every temp file of ours carries (docs/design/writes.md), fixed so
        /// a scenario can name the files an agent of ours would have left.
        static let macID = "abcd1234"

        static let ourStale = ".sshdrive-upload-abcd1234-0f0f0f0f-0000-4000-8000-000000000001"
        static let foreignFresh = ".sshdrive-upload-99999999-0f0f0f0f-0000-4000-8000-000000000002"
        static let foreignAncient = ".sshdrive-upload-99999999-0f0f0f0f-0000-4000-8000-000000000003"
        /// Names that look like ours to a rule that reads them in a hurry, and are not.
        static let bystanders = [
            "sshdrive-upload-abcd1234-report.txt",
            ".sshdrive-uploads-abcd1234-notes",
            ".sshdrive-upload.txt",
            "my-sshdrive-upload-log",
        ]
        static var seededOurs: Set<String> { [ourStale] }

        static func temporaryFixtures(now: Int64, ancient: Int64) -> [(String, Int64)] {
            var files: [(String, Int64)] = [
                (ourStale, now), (foreignFresh, now), (foreignAncient, ancient),
            ]
            files.append(contentsOf: bystanders.map { ($0, now) })
            return files
        }

        /// One file, one location, the in-memory backend.
        static func oneFile(_ harness: AgentHarness) async throws
            -> (Location, FakeTransport, LocationRuntime)
        {
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "README.txt"),
                    contents: Data("original".utf8), mode: 0o644))
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            return (location, fake, runtime)
        }

        static func file(_ index: Int) -> String { "f\(index).bin" }

        /// Ten files behind a transport a scenario can stop, for the scheduler.
        static func tenFiles(_ harness: AgentHarness) async throws
            -> (Location, InterposingTransport, LocationRuntime)
        {
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            for index in 0 ..< 10 {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: file(index)),
                        contents: Data(repeating: UInt8(65 + index), count: 4096), mode: 0o644))
            }
            let gate = InterposingTransport(fake)
            let runtime = try harness.makeRuntime(location: location, transport: gate)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            return (location, gate, runtime)
        }

        /// One `fetchContents`, started and left running. The transfer id is the file's
        /// name, so a cancel and an arrival can be matched to each other by eye.
        static func fetch(
            _ harness: AgentHarness, _ runtime: LocationRuntime, index: Int,
            kind: TransferScheduler.Kind
        ) async throws -> Task<Void, Error> {
            let (identifier, _) = try await runtime.identifier(forPath: file(index))
            let destination = harness.container.appendingPathComponent("fetch-\(index)")
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            let transferID = file(index)
            return Task {
                defer { try? handle.close() }
                _ = try await runtime.fetchContents(
                    identifier: identifier, into: handle, transferID: transferID, kind: kind)
            }
        }

        static func bytesOnDisk(_ harness: AgentHarness, index: Int) -> Int {
            let path = harness.container.appendingPathComponent("fetch-\(index)").path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? Int) ?? -1
        }

        /// A location whose transport is a real SFTP client on `FakeSFTPServer`'s wire,
        /// handed out by the launcher exactly as `SSHTransportLauncher` hands out a real
        /// connection.
        static func wireLocation(
            _ harness: AgentHarness, server: FakeSFTPServer, transport: any SFTPTransport
        ) async throws -> (Location, LocationRuntime) {
            harness.launcher.transportFactory = { _ in transport }
            let location = try await harness.addLocation(
                nickname: "nas", backend: .sftp, remotePath: server.root)
            // The write protocol's `<mac8>` (docs/design/writes.md), from the top level of
            // `config.json`.
            try await harness.manager.mutateConfiguration { file in file.macID = macID }
            let runtime = try await harness.manager.runtime(for: location)
            // The rename-semantics probe is fired detached from `applyConnection`;
            // awaiting it here means no rename of its own is in flight when a scenario
            // holds one.
            _ = await runtime.probeRenameSemantics()
            return (location, runtime)
        }

        /// A file handle over some bytes, standing in for the one the extension passes.
        static func handle(_ harness: AgentHarness, name: String, bytes: Data) throws -> FileHandle {
            let url = harness.container.appendingPathComponent("\(name)-\(UUID().uuidString)")
            try bytes.write(to: url)
            return try FileHandle(forReadingFrom: url)
        }

        /// Polls until `condition` holds. Nothing in the suite sleeps for real time; this
        /// waits for Swift's scheduler to have run the tasks a call started, the way
        /// `AgentHarness.settle` does, and gives up rather than hanging a suite.
        static func waitUntil(
            timeout: Double = 5, _ condition: @Sendable () async -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() { return true }
                for _ in 0 ..< 5 { await Task.yield() }
                try? await Task.sleep(nanoseconds: 200_000)
            }
            return await condition()
        }
    }
}

/// A transport that sits between the agent and whatever is underneath it - the in-memory
/// `FakeTransport`, or a `RealSFTPTransport` on `FakeSFTPServer`'s wire - so a scenario can
/// stop one call in the middle and look at the world while it is held.
///
/// Nothing here models a server: every call is forwarded. What it adds is a hold that a
/// test opens by hand, a record of which calls arrived and in what order, and the window
/// each transfer was handed, which is what the pipelined-window split
/// (docs/design/sftp.md) is asserted from.
final class InterposingTransport: SFTPTransport, @unchecked Sendable {

    enum Operation: String, Sendable {
        case read, setstat, rename, posixRename, writeExclusive
    }

    struct Arrival: Sendable {
        var operation: Operation
        var key: String
    }

    private let inner: any SFTPTransport
    private let lock = NSLock()
    private var heldOperations: Set<Operation> = []
    private var releasedOperations: Set<Operation> = []
    private var releasedKeys: Set<String> = []
    private var _arrivals: [Arrival] = []
    private var _windows: [Int] = []
    private var missWatch: (path: String, body: @Sendable () -> Void)?

    init(_ inner: any SFTPTransport) { self.inner = inner }

    // MARK: What a scenario drives

    func hold(_ operation: Operation) {
        lock.lock()
        heldOperations.insert(operation)
        releasedOperations.remove(operation)
        lock.unlock()
    }

    func release(_ operation: Operation) {
        lock.lock()
        releasedOperations.insert(operation)
        heldOperations.remove(operation)
        lock.unlock()
    }

    func release(key: String) {
        lock.lock()
        releasedKeys.insert(key)
        lock.unlock()
    }

    /// Runs `body` the first time an `lstat` of `path` finds nothing - "a file created
    /// meanwhile", which is the race the non-overwriting rename exists for
    /// (docs/design/writes.md).
    func plantOnNextMiss(of path: String, _ body: @escaping @Sendable () -> Void) {
        lock.lock()
        missWatch = (path, body)
        lock.unlock()
    }

    var arrivals: [Arrival] { lock.lock(); defer { lock.unlock() }; return _arrivals }

    func arrivals(of operation: Operation) -> [String] {
        arrivals.filter { $0.operation == operation }.map(\.key)
    }

    /// The window each transfer was handed, in the order they were admitted.
    var windows: [Int] { lock.lock(); defer { lock.unlock() }; return _windows }

    // MARK: The hold

    private func note(_ operation: Operation, _ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _arrivals.append(Arrival(operation: operation, key: key))
        return heldOperations.contains(operation)
    }

    private func isFree(_ operation: Operation, _ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return releasedOperations.contains(operation) || releasedKeys.contains(key)
            || !heldOperations.contains(operation)
    }

    private func waitIfHeld(_ operation: Operation, _ key: String) async throws {
        guard note(operation, key) else { return }
        let deadline = Date().addingTimeInterval(10)
        while !isFree(operation, key) {
            if Task.isCancelled { throw SFTPError.cancelled }
            if Date() > deadline { throw SFTPError.deadlineExceeded }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000)
        }
    }

    // MARK: SFTPTransport, forwarded

    var extensions: SFTPServerExtensions { get async { await inner.extensions } }

    func realpath(_ path: RelativePath) async throws -> String { try await inner.realpath(path) }

    func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        do {
            return try await inner.lstat(path)
        } catch {
            // `withLock`, not `lock()`/`unlock()`: the bare pair is unavailable from an
            // async context and is an error in the Swift 6 language mode.
            let watch = lock.withLock { () -> (path: String, body: @Sendable () -> Void)? in
                let held = missWatch
                if held?.path == path.description { missWatch = nil }
                return held
            }
            if watch?.path == path.description { watch?.body() }
            throw error
        }
    }

    func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        try await inner.readdir(path)
    }

    func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        try await waitIfHeld(.read, path.description)
        return try await inner.read(path, offset: offset, length: length)
    }

    func readStreaming(
        _ path: RelativePath, offset: UInt64, length: UInt64?, window: Int,
        receiver: @escaping @Sendable (UInt64, Data) async -> Void
    ) async throws -> UInt64 {
        // `withLock`: see `lstat` above.
        lock.withLock { _windows.append(window) }
        try await waitIfHeld(.read, path.description)
        return try await inner.readStreaming(
            path, offset: offset, length: length, window: window, receiver: receiver)
    }

    func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        try await inner.write(path, contents: contents, mode: mode)
    }

    func writeStreaming(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await inner.writeStreaming(
            path, mode: mode, window: window, source: source, progress: progress)
    }

    func writeExclusive(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await waitIfHeld(.writeExclusive, path.description)
        try await inner.writeExclusive(
            path, mode: mode, window: window, source: source, progress: progress)
    }

    func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        try await inner.mkdir(path, mode: mode)
    }

    func remove(_ path: RelativePath) async throws { try await inner.remove(path) }

    func rmdir(_ path: RelativePath) async throws { try await inner.rmdir(path) }

    func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await waitIfHeld(.rename, destination.description)
        try await inner.rename(source, to: destination)
    }

    func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await waitIfHeld(.posixRename, destination.description)
        try await inner.posixRename(source, to: destination)
    }

    func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        try await waitIfHeld(.setstat, path.description)
        try await inner.setstat(path, mode: mode, mtime: mtime)
    }

    func symlink(target: String, at path: RelativePath) async throws {
        try await inner.symlink(target: target, at: path)
    }

    func readlink(_ path: RelativePath) async throws -> String { try await inner.readlink(path) }

    func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        try await inner.statvfs(path)
    }
}
