import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import Index
import Logging
import ProviderCore
import SFTP
import ServerModel
import Testing
import XPCProtocols

/// Suite E's cost half: the first Finder listing of a directory nobody would call small,
/// end to end over the wire, and the `item(for:)` storm that follows it.
extension AgentScenarios {

    @Suite(.serialized) struct LargeListingScenarios {

        /// **E7**: ten thousand entries, listed once, read back once each, and replayed
        /// through the working set.
        ///
        /// What it defends is *shape*, not milliseconds. A listing of `n` entries must
        /// cost a constant number of statement compilations, a bounded number of wire
        /// round trips, at most three statement executions an entry, one `readlink` per
        /// link and no log line per entry. Anything that reintroduces a per-entry cost -
        /// a statement compiled per row, a `readlink` at a time, an incumbent read of its
        /// own - fails one of the counts below long before it shows up as a slow mount.
        ///
        /// The one wall-clock guard is deliberately loose and the per-phase figures are
        /// printed rather than asserted, because the box they are measured on is shared
        /// and its throughput moves by more than a round of optimisation wins. For the
        /// record, on a quiet Linux box: **debug**, the listing 0.82 s (readdir over the
        /// wire 0.20, the name rules 0.05, the row build 0.27, the transaction 0.29), the
        /// `item(for:)` storm 0.31 s, the working-set replay 0.34 s; **release**, 0.49 s,
        /// 0.21 s and 0.20 s.
        @Test func e7ATenThousandEntryFirstListing() async throws {
            let harness = try AgentHarness()
            let location = try await harness.addLocation(nickname: "nas", backend: .fake)
            let clock = ContinuousClock()
            let started = clock.now

            let server = Self.server()
            let wire = try await RealSFTPTransport.connect(
                stream: server.makeStream(), root: server.root)
            let connection = FakeLiveConnection(transport: wire)
            let runtime = try harness.makeRuntime(location: location, transport: connection)
            try await runtime.start()

            let statements = ListingScenarios.Statements()
            let compilations = ListingScenarios.Statements()
            await runtime.observeStatements { sql, depth in statements.record(sql, depth) }
            await runtime.observeCompilations { sql, depth in compilations.record(sql, depth) }
            let log = LogCapture()
            log.install()
            defer { log.uninstall() }
            server.clearRequestLog()

            // Phase 1: the whole listing, every page of it.
            let listingStart = clock.now
            var pages: [(items: [SSHDriveItemSnapshot], nextPageToken: String?)] = []
            var page = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            pages.append(page)
            while let token = page.nextPageToken {
                page = try await runtime.enumerateItems(
                    container: IndexWriter.rootIdentifier, pageToken: token)
                pages.append(page)
            }
            let listingTime = clock.now - listingStart
            await runtime.observeStatements(nil)
            await runtime.observeCompilations(nil)
            let listingLogLines = log.entries.count
            let items = pages.flatMap(\.items)

            // Phase 2: the `item(for:)` storm, through the extension's own reader.
            let store = IndexReaderStore(locationID: location.id, rootDisplayName: "nas")
            store.markReady(true)
            let readerStatements = ListingScenarios.Statements()
            let readerCompilations = ListingScenarios.Statements()
            store.observeStatements { sql, depth in readerStatements.record(sql, depth) }
            store.observeCompilations { sql, depth in readerCompilations.record(sql, depth) }
            let stormStart = clock.now
            var seen = 0
            for item in items
            where try store.item(identifier: ProviderItemIdentifier(item.identifier)) != nil {
                seen += 1
            }
            let stormTime = clock.now - stormStart

            // Phase 3: the working set replays every anchor the listing appended.
            let replayStart = clock.now
            var anchor: Int64 = 0
            var replayed = 0
            while let changes = try store.changes(since: anchor, limit: 500) {
                replayed += changes.items.count + changes.deleted.count
                anchor = changes.newAnchor
                if !changes.hasMore { break }
            }
            let replayTime = clock.now - replayStart
            let total = clock.now - started

            print(
                """
                E7 (\(Self.entryCount) entries): listing \(listingTime.ms) ms, \
                item(for:) storm \(stormTime.ms) ms, working-set replay \(replayTime.ms) ms, \
                whole scenario \(total.ms) ms
                """)

            // The rows, first: everything else here is the price of these.
            #expect(
                items.count == Self.entryCount - 2,
                "the two collision losers hold their names and are not enumerated")
            #expect(pages.count == 5, "2,000 to a page (docs/design/extension.md)")
            #expect(pages.dropLast().allSatisfy { $0.items.count == 2_000 })
            #expect(seen == items.count, "every identifier the listing handed out has a row")
            #expect(replayed == items.count, "and an anchor")

            // The wire. One `opendir` and one `lstat` of the container, a hundred pages
            // asked for through the window docs/design/sftp.md describes rather than one
            // round trip each, and
            // one `readlink` per link - never a `stat` per entry.
            let opendirs = server.requests.filter { $0.hasPrefix("opendir") }
            #expect(opendirs.count == 1, "a listing opens its directory once")
            #expect(
                server.readdirRequests <= 100 + 16,
                "SQ-051: a hundred pages cost a hundred readdirs and at most one window of over-issue")
            #expect(
                server.requests.filter { $0.hasPrefix("lstat") }.count <= 2,
                "docs/design/security.md: re-lstats the container, and nothing else is stat'ed per entry")
            #expect(connection.readlinkCount == 20, "SQ-031: one readlink per link, and no more")
            // That they go out *concurrently* is `M2`'s assertion, not this one: with no
            // latency in the fake there is nothing to stop the scheduler answering each
            // before the next is issued, and a high-water mark measured that way is a
            // coin toss.

            // The index. A constant number of compilations, and at most three executed
            // statements an entry - the incumbent read, the row and the anchor - however
            // many entries there are.
            #expect(
                compilations.all().count <= 16,
                "E7: a listing's compilations are a constant, not one per entry")
            #expect(
                statements.all().count <= 3 * Self.entryCount + 100,
                "E7: three statements an entry and a fixed overhead, and no fourth")
            #expect(
                statements.all().filter { $0.sql.hasPrefix("BEGIN IMMEDIATE") }.count == 1,
                "still one transaction (docs/design/item-index.md)")
            #expect(statements.all().filter { $0.sql.hasPrefix("SAVEPOINT") }.isEmpty)

            // The extension's side: one statement per `item(for:)`, and a constant number
            // of compilations for the whole storm and the replay together.
            #expect(
                readerStatements.all().count <= 2 * Self.entryCount + 100,
                "E7: one statement an item(for:), plus the replay's own reads")
            #expect(
                readerCompilations.all().count <= 8,
                "E7: the reader compiles a constant number of statements")

            // And no log line per entry: a `Logger` call is not free on either platform,
            // and one per row turns a listing into a log flood.
            #expect(
                listingLogLines <= 50,
                "E7: a listing logs about the listing, not about each of its entries")

            // One generous guard, so the scenario says something about time without
            // failing whenever the box is busy - and it does get busy: the same pure-CPU
            // row build measured 9 µs an hour before it measured 44 µs, and the whole
            // scenario went from 1.7 s to 3.9 s with it. The bar is set where only a
            // multiple of the worst of that trips it; the counts above are the real
            // signal, and they do not move with the box at all.
            #expect(total < .seconds(15), "E7: ten thousand entries, end to end")
        }

        static let entryCount = 10_000

        /// The directory: files with varied sizes, mtimes and modes, fifty
        /// subdirectories, twenty symlinks, three dot names, and two pairs the local
        /// filesystem cannot tell apart (one by case, one by normalisation).
        static func server() -> FakeSFTPServer {
            let server = FakeSFTPServer(profile: .debian, root: "/srv/fake")
            server.readdirPageSize = 100
            var made = 0
            for index in 0 ..< 50 {
                server.putDirectory(String(format: "dir-%03d", index))
                made += 1
            }
            for index in 0 ..< 20 {
                server.putSymlink(String(format: "link-%03d", index), target: "f-00000.txt")
                made += 1
            }
            for name in [".hidden", ".config", ".profile"] {
                server.put(name, contents: Data("x".utf8))
                made += 1
            }
            server.put("Makefile", contents: Data("m".utf8))
            server.put("makefile", contents: Data("m".utf8))
            server.put("e\u{0301}.txt", contents: Data("e".utf8))
            server.put("\u{00e9}.txt", contents: Data("e".utf8))
            made += 4
            var index = 0
            while made < entryCount {
                server.put(
                    String(format: "f-%05d.txt", index),
                    contents: Data(repeating: 0x61, count: index % 977),
                    mode: [0o644, 0o600, 0o755, 0o444][index % 4],
                    mtime: 1_700_000_000 + Int64(index % 100_000))
                index += 1
                made += 1
            }
            return server
        }
    }
}

extension Duration {
    /// Milliseconds, to one decimal place, for a scenario that prints what it measured.
    fileprivate var ms: String {
        String(
            format: "%.1f",
            Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
