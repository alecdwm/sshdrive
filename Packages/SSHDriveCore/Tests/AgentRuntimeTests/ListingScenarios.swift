import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import SFTP
import ServerModel
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
        /// down whatever moves in and out of the transaction.
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
        /// behind it. The per-entry read (`SELECT ... WHERE path = ?1`) is the marker:
        /// once per entry, and only outside the transaction.
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

        /// **E2**, the cost half - what a large first listing compiles.
        ///
        /// The rows are the contract above; this is the price of writing them. Compiled
        /// per execution, a listing of 2,000 entries is 8,006 compilations - the incumbent
        /// read, the row, the anchor and a `SELECT last_insert_rowid()` for every entry -
        /// plus a `SAVEPOINT` opened and released per anchor. The statement cache of
        /// section 5.2 makes the compilations a constant, the C API answers the rowid, and
        /// an anchor inside the listing's own transaction takes no savepoint, since a
        /// throw fails the whole batch either way.
        @Test func e2ALargeListingCompilesAConstantNumberOfStatements() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let fake = FakeTransport(root: "/srv/fake")
            for index in 0 ..< 2000 {
                try await fake.apply(
                    .createFile(
                        path: try RelativePath(string: String(format: "f-%05d.txt", index)),
                        contents: Data("x".utf8), mode: 0o644))
            }
            let runtime = try harness.makeRuntime(location: location, transport: fake)
            try await runtime.start()

            let executed = Statements()
            let compiled = Statements()
            await runtime.observeStatements { sql, depth in executed.record(sql, depth) }
            await runtime.observeCompilations { sql, depth in compiled.record(sql, depth) }
            let listed = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            await runtime.observeStatements(nil)
            await runtime.observeCompilations(nil)

            #expect(listed.items.count == 2000)
            #expect(
                compiled.all().count <= 12,
                "E2: a listing's compilations are a constant, not four per entry")
            #expect(
                executed.all().filter { $0.sql.hasPrefix("SAVEPOINT") }.isEmpty,
                "E2: an anchor inside the listing's transaction takes no savepoint of its own")
            #expect(
                !executed.all().contains { $0.sql.contains("last_insert_rowid") },
                "E2: the anchor's sequence number comes from the C API, not from a query")
            #expect(
                executed.all().count < 3 * 2000 + 50,
                "E2: three statements an entry - the incumbent read, the row, the anchor")
        }

        /// **M2** (`SQ-031`): the links in one listing are read through section 6.2's
        /// window, not one at a time.
        ///
        /// SFTP v3's `readdir` carries attributes but no link target, so a directory of
        /// links is a `readlink` per link however it is written. What this pins is that
        /// they are *concurrent*: serially, a directory of a thousand links is a thousand
        /// round trips before the first row can be built, a first Finder listing whose
        /// length is the link count times the link latency. Measured here with a 20 ms
        /// answer per link: fifteen links take 0.48 s one at a time and 0.12 s through the
        /// window, with fifteen in flight.
        ///
        /// And the rows are the contract, not the speed: the same rows, in the same
        /// order, with a dangling link shown (section 5.7 draws it as an alias, dangling
        /// or not), an escaping one hidden, and a link whose `readlink` was refused hidden
        /// too - one refusal cannot fail the listing it was found in.
        @Test func m2ALinkHeavyListingReadsItsTargetsThroughTheWindow() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            // Over the **wire**, not over `FakeTransport`: `FakeTransport.readdir` hands
            // back the target it knows, and a listing that is given the targets asks no
            // `readlink` at all. `SQ-031` is the thing being tested, so it has to be the
            // server that omits them.
            let server = FakeSFTPServer(profile: .debian, root: "/srv/fake")
            server.put("note.txt", contents: Data("x".utf8))
            for index in 0 ..< 12 {
                server.putSymlink(String(format: "link-%02d", index), target: "note.txt")
            }
            // The three that are not ordinary: a target nothing points at, a target that
            // leaves the location, and one the server will refuse to answer for.
            server.putSymlink("dangling", target: "gone.txt")
            server.putSymlink("escaping", target: "../secrets")
            server.putSymlink("refused", target: "note.txt")
            let wire = try await RealSFTPTransport.connect(
                stream: server.makeStream(), root: server.root)

            let connection = FakeLiveConnection(transport: wire)
            connection.readlinkDelay = .milliseconds(20)
            connection.readlinkFailures = ["refused"]
            let runtime = try harness.makeRuntime(location: location, transport: connection)
            try await runtime.start()

            let listing = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)

            #expect(connection.readlinkCount == 15, "SQ-031: one readlink per link, and no more")
            #expect(
                connection.peakReadlinksInFlight == 15,
                "section 6.2: they go out through the window, not one at a time")
            #expect(
                connection.peakReadlinksInFlight <= LocationRuntime.readlinkWindow,
                "and never more than the window")

            // The rows: the twelve ordinary links and the dangling one are shown, the
            // escaping one and the refused one are not, and the file is untouched.
            let shown = Set(listing.items.map(\.filename))
            var expected = Set((0 ..< 12).map { String(format: "link-%02d", $0) })
            expected.insert("note.txt")
            expected.insert("dangling")
            #expect(shown == expected, "section 5.7: the escaping and the unreadable link are omitted")

            let rows = try await Self.rowsByPath(runtime)
            #expect(rows["link-00"]?.linkTarget == Data("note.txt".utf8))
            #expect(
                rows["dangling"]?.linkTarget == Data("gone.txt".utf8),
                "a link is never followed, so a target that does not exist is still a target")
            #expect(rows["escaping"]?.hidden == 1)
            #expect(rows["refused"]?.hidden == 1, "no target, no row anyone may see")
            #expect(rows["refused"]?.linkTarget == nil)
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
