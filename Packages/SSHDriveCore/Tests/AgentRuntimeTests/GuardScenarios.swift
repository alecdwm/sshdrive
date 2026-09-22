import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import Testing
import XPCProtocols

/// Suite D's guard half on the agent's side (`docs/design/testing.md` section 5).
extension AgentScenarios {

    @Suite struct GuardScenarios {

        /// **D5** - the guard holds pending items and their ancestors.
        ///
        /// 40 files, 30 deleted, and a pending edit inside a *different* directory that the
        /// same listing says has gone. Both halves of the mass-deletion guard
        /// (docs/design/change-detection.md) fire: the 30 are held in bulk, and the directory
        /// holding the pending edit is held **as an ancestor**, because a listing infers the
        /// deletion of the directory and not of the file inside it. Matching pending paths
        /// exactly would let the directory through and strand the save (measured 2026-09-04).
        @Test func d5TheGuardHoldsPendingItemsAndTheirAncestors() async throws {
            let harness = try AgentHarness()
            let (location, fake, runtime) = try await Self.tree(harness)

            // 30 of the 40 photos, and the whole of the directory with the pending edit.
            for index in 0 ..< 30 {
                try await fake.apply(
                    .delete(path: try RelativePath(string: Self.photo(index)), recursive: false))
            }
            try await fake.apply(.delete(path: try RelativePath(string: "Work"), recursive: true))

            let (noteIdentifier, _) = try await runtime.identifier(forPath: "Work/note.txt")
            await runtime.setPendingPaths(
                await runtime.paths(forIdentifiers: [noteIdentifier]))

            let application = await runtime.runPollCycle(fullSweep: true)
            #expect(application.deleted == 0, "D5: nothing is reported deleted")
            #expect(application.held == 31, "D5: 30 in bulk plus the ancestor of the pending edit")

            let held = try await runtime.heldReport()
            let heldPaths = Set(held.compactMap { $0["path"] as? String })
            #expect(heldPaths.contains("Work"), "D5: held as an ancestor of Work/note.txt")
            #expect(heldPaths.contains(Self.photo(0)))
            #expect(!heldPaths.contains(Self.photo(35)), "the ten that are still there are not held")

            // A fetch of a held item is `.cannotSynchronize`, never `.noSuchItem`: `.noSuchItem`
            // from `item(for:)` deletes the user's file, which is the whole thing the hold
            // exists to prevent (`MQ-011`, `MQ-012`).
            let destination = harness.container.appendingPathComponent("fetch.tmp")
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            let (photoIdentifier, _) = try await runtime.identifier(forPath: Self.photo(0))
            do {
                _ = try await runtime.fetchContents(
                    identifier: photoIdentifier, into: handle, transferID: "d5b", kind: .foreground)
                Issue.record("a held item must not fetch")
            } catch {
                #expect(
                    (error as NSError).code == SSHDriveAgentError.cannotSynchronize.rawValue,
                    "D5: `.cannotSynchronize` leaves the item in place")
            }
            _ = location
        }

        /// **D5**, second half - `accept-deletions` applies what the guard is holding, now.
        ///
        /// docs/design/cli.md: with no path, everything; with one, that path and its subtree. Everything
        /// beneath a held directory goes with it, and the `held` rows are released either way.
        @Test func d5AcceptDeletionsAppliesTheHolds() async throws {
            let harness = try AgentHarness()
            let (_, fake, runtime) = try await Self.tree(harness)
            for index in 0 ..< 30 {
                try await fake.apply(
                    .delete(path: try RelativePath(string: Self.photo(index)), recursive: false))
            }
            try await fake.apply(.delete(path: try RelativePath(string: "Work"), recursive: true))
            let (noteIdentifier, _) = try await runtime.identifier(forPath: "Work/note.txt")
            await runtime.setPendingPaths(
                await runtime.paths(forIdentifiers: [noteIdentifier]))
            _ = await runtime.runPollCycle(fullSweep: true)
            #expect(try await runtime.heldReport().count == 31)

            // One directory first, to prove the scope is honoured.
            let scoped = try await runtime.acceptDeletions(pathString: "Work")
            #expect(scoped == 1, "the held directory itself")
            #expect(try await runtime.heldReport().count == 30)
            // And its child went with it, because those paths are gone whatever now sits at
            // the name (docs/design/item-index.md, no tombstones).
            await #expect(throws: (any Error).self) {
                _ = try await runtime.identifier(forPath: "Work/note.txt")
            }

            let rest = try await runtime.acceptDeletions(pathString: nil)
            #expect(rest == 30)
            #expect(try await runtime.heldReport().isEmpty)
            await #expect(throws: (any Error).self) {
                _ = try await runtime.identifier(forPath: Self.photo(0))
            }
        }

        // MARK: The tree both halves start from

        static func photo(_ index: Int) -> String {
            String(format: "Photos/img-%03d.jpg", index)
        }

        /// 40 photos in one directory, and a second directory holding the file the system will
        /// say has a pending edit. Both are listed, so the index knows all 42 rows and both
        /// directories are `viewed` roots.
        static func tree(_ harness: AgentHarness) async throws
            -> (Location, FakeTransport, LocationRuntime)
        {
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            try await fake.apply(.createDirectory(path: try RelativePath(string: "Photos"), mode: 0o755))
            for index in 0 ..< 40 {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: photo(index)),
                        contents: Data("photo \(index)".utf8), mode: 0o644))
            }
            try await fake.apply(.createDirectory(path: try RelativePath(string: "Work"), mode: 0o755))
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "Work/note.txt"),
                    contents: Data("draft".utf8), mode: 0o644))

            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            for directory in ["Photos", "Work"] {
                let (identifier, _) = try await runtime.identifier(forPath: directory)
                _ = try await runtime.enumerateItems(container: identifier, pageToken: nil)
            }
            return (location, fake, runtime)
        }
    }
}
