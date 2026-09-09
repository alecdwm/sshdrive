import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import Testing
import XPCProtocols

/// Suite E's listing half (`docs/testing-architecture.md` section 5): what one directory
/// listing writes, and what its transaction holds while it writes it.
extension AgentScenarios {

    @Suite struct ListingScenarios {

        /// **E2**, the behaviour half - what a second listing of a directory writes.
        ///
        /// A mix of every case one listing can meet at once: a file that has not moved, a
        /// file whose content version has, a file that is new, a file that has gone, a
        /// subdirectory, and a symlink inside the root. The rows and the anchors are the
        /// contract, and they are asserted exactly: an unchanged file keeps its
        /// identifier, its versions **and** its row, a changed one and a new one each get
        /// one `modified` anchor, the missing one gets one `deleted` anchor, and nothing
        /// else is anchored at all. This is what pins the row-building and the anchors
        /// down while the work moves in and out of the transaction (2026-09-09).
        @Test func e2ASecondListingWritesExactlyWhatChanged() async throws {
            let harness = try AgentHarness()
            let (fake, runtime) = try await Self.tree(harness)

            let firstListing = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            #expect(
                Set(firstListing.items.map(\.filename))
                    == ["keep.txt", "move.txt", "gone.txt", "dir", "link"])

            let before = try await Self.rowsByPath(runtime)
            let link = try #require(before["link"])
            #expect(link.type == "symlink", "the link is a native item, never followed")
            #expect(link.hidden == 0, "a link to a sibling inside the root is shown (section 5.7)")
            #expect(link.linkTarget == Data("keep.txt".utf8))
            let anchorsBefore = try await runtime.dumpAnchors(limit: 500).count

            // One of each, in one listing: a new file, a changed file, a deleted file, and
            // three rows nothing touched.
            try await fake.apply(.touch(path: try RelativePath(string: "move.txt")))
            try await fake.apply(
                .delete(path: try RelativePath(string: "gone.txt"), recursive: false))
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "new.txt"), contents: Data("new".utf8),
                    mode: 0o644))

            let (changed, deleted) = try await runtime.enumerateChanges(
                container: IndexWriter.rootIdentifier)
            #expect(
                Set(changed.map(\.filename)) == ["move.txt", "new.txt"],
                "E2: the unchanged rows, the directory and the link are not re-reported")
            #expect(deleted == [before["gone.txt"]?.identifier].compactMap { $0 })

            let after = try await Self.rowsByPath(runtime)
            #expect(
                Set(after.keys) == ["keep.txt", "move.txt", "new.txt", "dir", "dir/x.txt", "link"])

            // The rows nothing changed are the same rows: same identifier, and the same
            // versions, which is what stops the system re-reading every item in a
            // directory each time it is listed (section 5.3).
            for path in ["keep.txt", "dir", "link"] {
                #expect(after[path] == before[path], "E2: \(path) was not rewritten")
            }
            let moved = try #require(after["move.txt"])
            #expect(moved.identifier == before["move.txt"]?.identifier, "no tombstones, same row")
            #expect(moved.contentVersion != before["move.txt"]?.contentVersion)

            // Exactly three anchors, and the deletion is last: the deletion pass runs
            // after the entries, inside the same transaction.
            let anchors = try await runtime.dumpAnchors(limit: 500).reversed()
            let appended = Array(anchors.dropFirst(anchorsBefore))
            #expect(appended.count == 3, "E2: one anchor per change and not one more")
            let modified = Set(appended.filter { $0.kind == .modified }.map(\.identifier))
            #expect(
                modified
                    == Set([after["move.txt"]?.identifier, after["new.txt"]?.identifier]
                        .compactMap { $0 }))
            #expect(appended.last?.kind == .deleted)
            #expect(appended.last?.identifier == before["gone.txt"]?.identifier)
        }

        /// **E2**, the transaction half - one `BEGIN IMMEDIATE`, and the writes alone
        /// inside it.
        ///
        /// Section 5.3 wants the listing written atomically; what it does not want is the
        /// row building held inside the write lock, because `LocationRuntime` is an actor
        /// and everything else about the location - `sshdrive status` included - waits
        /// behind it. The per-entry read (`SELECT ... WHERE path = ?1`) is the marker: it
        /// used to be issued once per entry inside the transaction, and it must now be
        /// issued only outside it (2026-09-09).
        @Test func e2TheTransactionHoldsTheWritesAlone() async throws {
            let harness = try AgentHarness()
            let (fake, runtime) = try await Self.tree(harness)
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)

            for index in 0 ..< 20 {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: String(format: "f-%03d.txt", index)),
                        contents: Data("f\(index)".utf8), mode: 0o644))
            }

            let statements = Statements()
            await runtime.observeStatements { sql, depth in statements.record(sql, depth) }
            _ = try await runtime.enumerateChanges(container: IndexWriter.rootIdentifier)
            await runtime.observeStatements(nil)

            let recorded = statements.all()
            #expect(
                recorded.filter { $0.sql.hasPrefix("BEGIN IMMEDIATE") }.count == 1,
                "E2: a directory listing is written in one transaction, not in chunks")
            #expect(recorded.filter { $0.sql.hasPrefix("COMMIT") }.count == 1)
            #expect(
                recorded.contains { $0.sql.contains("FROM items WHERE path = ?1") && $0.depth == 0 },
                "the incumbent rows are read before the transaction is taken")
            #expect(
                !recorded.contains { $0.sql.contains("FROM items WHERE path = ?1") && $0.depth > 0 },
                "E2: no per-entry row read is issued inside the transaction")
            #expect(
                recorded.filter { $0.sql.hasPrefix("INSERT INTO items") && $0.depth > 0 }.count == 20,
                "E2: every row the listing writes is written inside the transaction")
            #expect(
                !recorded.contains { $0.sql.hasPrefix("INSERT INTO items") && $0.depth == 0 },
                "and none of them outside it")
        }

        /// A statement log a `@Sendable` observer can write to from inside the actor.
        final class Statements: @unchecked Sendable {
            struct Entry {
                let sql: String
                let depth: Int
            }

            private let lock = NSLock()
            private var entries: [Entry] = []

            func record(_ sql: String, _ depth: Int) {
                lock.lock()
                entries.append(Entry(sql: sql, depth: depth))
                lock.unlock()
            }

            func all() -> [Entry] {
                lock.lock()
                defer { lock.unlock() }
                return entries
            }
        }

        // MARK: The tree both halves start from

        /// Five entries in the root - an unchanged file, a file that will change, a file
        /// that will go, a subdirectory with a child, and a symlink to a sibling - and a
        /// runtime that has started but listed nothing yet.
        static func tree(_ harness: AgentHarness) async throws -> (FakeTransport, LocationRuntime) {
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            for name in ["keep.txt", "move.txt", "gone.txt"] {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: name), contents: Data("\(name) v1".utf8),
                        mode: 0o644))
            }
            try await fake.apply(
                .createDirectory(path: try RelativePath(string: "dir"), mode: 0o755))
            try await fake.apply(
                .createFile(
                    path: try RelativePath(string: "dir/x.txt"), contents: Data("x".utf8),
                    mode: 0o644))
            try await fake.apply(
                .createSymlink(path: try RelativePath(string: "link"), target: "keep.txt"))

            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()
            // The subdirectory is listed once so its child has a row: the listing of the
            // root must leave both alone.
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            let (dir, _) = try await runtime.identifier(forPath: "dir")
            _ = try await runtime.enumerateItems(container: dir, pageToken: nil)
            return (fake, runtime)
        }

        static func rowsByPath(_ runtime: LocationRuntime) async throws -> [String: IndexItem] {
            var out: [String: IndexItem] = [:]
            for row in try await runtime.dumpIndex() where !row.path.isEmpty {
                out[String(decoding: row.path, as: UTF8.self)] = row
            }
            return out
        }
    }
}
