import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import Testing
import XPCProtocols

/// Suite G on the agent's side: the TTL loop against a driven clock, and section 7.1.1's
/// inheritance (`docs/testing-architecture.md` section 5).
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
        /// any of them: section 7.1.1's invariant 3 says the *smallest* marker change that
        /// produces the asked-for effect is the one made. `evict <path>` on such a file is
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
        /// (`MQ-027`, section 7.1.1's five situations).
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
    }
}
