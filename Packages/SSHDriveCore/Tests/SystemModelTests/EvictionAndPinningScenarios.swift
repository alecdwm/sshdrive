import XCTest
import AgentCore
import Config
import Index
import ProviderCore
import SystemModel

/// **Suite G - eviction and pinning** (docs/design/testing.md).
///
/// The agent-side halves of `G1`, `G4` and `G5` run in `Tests/AgentRuntimeTests` against
/// `FakeReplica`; these are the same rows against the **model**, so that what refuses an
/// eviction is measured fileproviderd behaviour rather than a scripted answer. `G13` and
/// `G14` are new ids for the two menu rows the catalogue had marked VM-only: what Finder
/// draws is not modellable, but which entries the *rules* produce is.
final class EvictionAndPinningScenarios: XCTestCase {

    // MARK: G1 - atime is not in the TTL's `max`

    /// A file fetched 280 s ago under a 60 s TTL, whose atime the system advanced 23 s ago
    /// with no read of ours near it (`MQ-022`).
    ///
    /// The model produces the measured situation - one deferred advance after the fetch,
    /// `MQ-023`'s relatime rule - and the **shipping** decision, `AgentCore.EvictionPlan`,
    /// is asked. It evicts, because last use is the later of the fetch and the save and
    /// atime is not in it. Then `MQ-021`: the eviction moves atime, which is why the loop
    /// reads it first.
    func testG1_AtimeIsReadLoggedAndNotDecidedOn() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("stale.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        harness.finder.read(harness.id(file))
        let fetchedAt = harness.clock.now()
        harness.system.advance(280)

        let item = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertEqual(harness.clock.now() - item.atime, 23, accuracy: 0.001, "MQ-022")
        XCTAssertEqual(item.lastFetch, fetchedAt)

        let candidate = EvictionPlan.Candidate(
            identifier: file, path: "stale.txt", size: item.size,
            lastFetch: item.lastFetch, mtime: item.mtime, atime: item.atime)
        let decision = try XCTUnwrap(
            EvictionPlan.decide([candidate], ttl: 60, now: harness.clock.now()).first)
        XCTAssertTrue(decision.evict, "280 s under a 60 s TTL is stale whatever the atime says")
        XCTAssertEqual(decision.ageSeconds, 280, accuracy: 0.001)

        // MQ-021: and the eviction moves the atime, so a loop that read it afterwards
        // would see a fresh one on a file it had just made dataless.
        XCTAssertTrue(domain.evictItem(harness.id(file)).didEvict)
        XCTAssertEqual(domain.replica.item(harness.id(file))?.atime, harness.clock.now())
    }

    /// **The bite-proof.** The same candidate through a rule that puts atime in the
    /// `max`. It survives the TTL for ever: the TTL silently becomes "time since
    /// whatever last touched the replica".
    func testG1_AtimeInTheMaxWouldHaveSpareTheFile() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("stale.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        harness.system.advance(280)
        let item = try XCTUnwrap(domain.replica.item(harness.id(file)))

        // The old rule, kept here and only here: `max(mtime, lastFetch, atime)`.
        let legacyLastUse = max(max(item.mtime, item.lastFetch ?? 0), item.atime)
        XCTAssertLessThan(
            harness.clock.now() - legacyLastUse, 60,
            "with atime in the max the file is 23 s old and never evicted")
    }

    // MARK: G2 - `evict --all` falls back to a walk

    /// A pin in place, then straight after `--unpin-all`.
    ///
    /// `MQ-033`: the single root call fails as a whole while anything under it is kept -
    /// it meets the kept child and returns rather than evicting the rest. `MQ-034`: for
    /// 5-10 s after the unpin the system has not re-read the rows whose policy changed and
    /// the call fails naming no reason, and the **root** did not become evictable within
    /// the minute that was measured. The walk is the fallback, and the failures are logged
    /// and never interpreted.
    func testG2_TheRootCallFailsWithAPinAndJustAfterAnUnpin() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Documents")
        let inside = try harness.serverCreates("keep.txt", in: folder)
        let loose = try harness.serverCreates("loose.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        domain.openFolder(harness.id(folder))
        harness.finder.read(harness.id(inside))
        harness.finder.read(harness.id(loose))

        try harness.agent.pin(identifier: folder)
        domain.signalWorkingSet()
        XCTAssertEqual(domain.evictItem(.rootContainer).code, -2008, "MQ-033: as a whole")
        XCTAssertTrue(try XCTUnwrap(domain.replica.item(harness.id(loose))).isDownloaded)

        try harness.agent.unpin(identifier: folder)
        domain.signalWorkingSet()
        XCTAssertEqual(
            domain.evictItem(.rootContainer).code, 256,
            "MQ-034: the rows whose policy changed have not been re-read")
        harness.system.advance(59)
        XCTAssertEqual(
            domain.evictItem(.rootContainer).code, 256,
            "MQ-034.root: and the root was still refused a minute later")

        // The walk: every unkept file, one at a time, with the doubling backoff.
        var evicted: [ProviderItemIdentifier] = []
        for item in domain.replica.descendants(of: .rootContainer) where !item.isDirectory {
            if domain.evictWithBackoff(item.identifier).outcome.didEvict {
                evicted.append(item.identifier)
            }
        }
        XCTAssertEqual(Set(evicted), [harness.id(inside), harness.id(loose)])
        XCTAssertEqual(domain.replica.downloadedCount, 0)
    }

    // MARK: G3 - `-2008` says nothing about why

    /// A pending item and a kept item, evicted in turn.
    ///
    /// `MQ-018`: both refuse `-2008`, so the loop must not read a pin out of it -
    /// `NSFileProviderErrorUnsyncedEdits` (-2007) never appeared. `MQ-019`: the *parent
    /// directory* of the pending item fails differently and opaquely, as
    /// `NSCocoaErrorDomain` 4101 with an underlying `contentVersionMismatch`, and not as
    /// the `-2006` the header promises.
    func testG3_TheSameCodeComesBackForAPendingUploadAndAKeptItem() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Documents")
        let pendingFile = try harness.serverCreates("pending.txt", in: folder)
        let keptFile = try harness.serverCreates("kept.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        domain.openFolder(harness.id(folder))
        harness.finder.read(harness.id(pendingFile))
        harness.finder.read(harness.id(keptFile))

        try harness.agent.pin(identifier: keptFile)
        domain.signalWorkingSet()
        harness.agent.isReachable = false
        harness.finder.save(harness.id(pendingFile))
        XCTAssertEqual(domain.pendingIdentifiers, [harness.id(pendingFile)])

        XCTAssertEqual(domain.evictItem(harness.id(pendingFile)).code, -2008, "MQ-018")
        XCTAssertEqual(domain.evictItem(harness.id(keptFile)).code, -2008, "MQ-018, and the same")
        XCTAssertEqual(
            domain.evictItem(harness.id(folder)).code, 4101,
            "MQ-019: the parent directory fails differently again")
    }

    // MARK: G4 - the policy refuses, not the capability

    /// A file that merely **inherits** a pin, still serving `allowsEvicting`.
    ///
    /// `MQ-024`: the effective `contentPolicy` is what refuses the eviction. `MQ-025`: the
    /// capability we serve is ignored anyway - the system puts `allowsEvicting` back and
    /// the bit it reports follows `isDownloaded` - so dropping it would be no second belt.
    func testG4_TheEffectivePolicyRefusesAndTheCapabilityIsIgnored() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Documents")
        let inside = try harness.serverCreates("inherits.txt", in: folder)
        let domain = try harness.addDomain()
        domain.openFolder()
        domain.openFolder(harness.id(folder))
        harness.finder.read(harness.id(inside))

        try harness.agent.pin(identifier: folder)
        domain.signalWorkingSet()

        let item = try XCTUnwrap(domain.replica.item(harness.id(inside)))
        XCTAssertTrue(item.kept, "kept is derived from the parent's marker, not a marker of its own")
        XCTAssertTrue(
            item.reportsAllowsEvicting,
            "MQ-025: the bit the system reports follows isDownloaded, whatever we serve")
        XCTAssertEqual(
            domain.replica.effectivePolicy(of: harness.id(inside)),
            .downloadEagerlyAndKeepDownloaded)
        XCTAssertEqual(domain.evictItem(harness.id(inside)).code, -2008, "MQ-024")
    }

    // MARK: G5 - an explicit lazy child wins

    /// `Documents/Reports` excluded inside a pinned `Documents`.
    ///
    /// `MQ-027`: the explicit `.downloadLazily` **overrides the eager ancestor** - only the
    /// direct sibling under the eager folder is fetched and the excluded subtree stays
    /// dataless. `MQ-026`: `.inherited` forces nothing, which is why an unmarked tree
    /// downloads none of itself.
    func testG5_AnExplicitLazyChildBeatsAnEagerAncestor() throws {
        let harness = try ScenarioHarness()
        let documents = try harness.serverCreatesDirectory("Documents")
        let sibling = try harness.serverCreates("sibling.txt", in: documents)
        let reports = try harness.serverCreatesDirectory(
            "Reports", identifier: "id-Reports", parent: documents)
        let excluded = try harness.serverCreates("deep.txt", in: reports)
        let domain = try harness.addDomain()
        domain.openFolder()
        domain.openFolder(harness.id(documents))
        domain.openFolder(harness.id(reports))

        try harness.agent.pin(identifier: documents)
        try harness.agent.exclude(identifier: reports)
        domain.signalWorkingSet()
        domain.runEagerPass()

        XCTAssertTrue(try XCTUnwrap(domain.replica.item(harness.id(sibling))).isDownloaded)
        XCTAssertFalse(
            try XCTUnwrap(domain.replica.item(harness.id(excluded))).isDownloaded,
            "MQ-027: nine files inside the excluded subtree stayed dataless")
        XCTAssertEqual(domain.fetchesIssued, [harness.id(sibling)], "one fetch, the direct sibling")
    }

    // MARK: G6 - a pin on an unseen path

    /// A path with no rows the replica has ever seen.
    ///
    /// `MQ-029`: listing the ancestors and anchoring them is **not enough** - reporting
    /// them through the working set starts nothing, reproduced three times. What starts it
    /// is `getUserVisibleURL` plus one `lstat` of the replica. `MQ-028`: once it starts,
    /// the eager policy pulls the whole subtree including a subfolder nothing has ever
    /// listed.
    func testG6_APinOnAnUnseenPathNeedsTheReplicaLookup() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()
        domain.openFolder()

        // The agent lists the ancestors, writes the rows and anchors each of them, exactly
        // as the five pin steps do (docs/design/pinning.md).
        let documents = try harness.serverCreatesDirectory("Documents")
        let reports = try harness.serverCreatesDirectory(
            "Reports", identifier: "id-Reports", parent: documents)
        let unopened = try harness.serverCreatesDirectory(
            "Never-Listed", identifier: "id-Never", parent: reports)
        for index in 0..<8 {
            try harness.serverCreates("f\(index).txt", in: unopened, identifier: "id-deep-\(index)")
        }
        try harness.agent.pin(identifier: documents)
        domain.signalWorkingSet()
        domain.runEagerPass()

        XCTAssertGreaterThan(domain.replicaDroppedContainers, 0, "MQ-029")
        XCTAssertEqual(domain.fetchesIssued, [], "the signal alone downloads nothing")
        XCTAssertNil(domain.replica.item(harness.id(documents)))

        // `getUserVisibleURL` plus one `lstat`, which is what the agent does next.
        XCTAssertNotNil(domain.userVisibleURL(of: .rootContainer))
        XCTAssertNotNil(domain.lstatUserVisible(harness.id(documents)))
        domain.runEagerPass()

        XCTAssertEqual(domain.fetchesIssued.count, 8, "MQ-028: including the never-listed subfolder")
        XCTAssertTrue(
            domain.enumeratedContainers.contains(harness.id(unopened)),
            "which the system had to ask us to enumerate")
        XCTAssertEqual(domain.replica.downloadedCount, 8)
    }

    // MARK: G8 - six fetches, and the seventh

    /// A 30-file eager subtree, then eight concurrent opens.
    ///
    /// `MQ-031`: strict batches of **six**, never seven, over 38 transfers with each held
    /// 5 s. `MQ-032`: eight files opened at once from a shell arrive as eight
    /// **simultaneous foreground** calls, all admitted and none refused - so the ceiling
    /// is the eager pass's and not the agent's queue.
    func testG8_TheEagerCeilingIsSixAndForegroundOpensAreAllAdmitted() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Bulk")
        var identifiers: [String] = []
        for index in 0..<30 {
            identifiers.append(
                try harness.serverCreates("b\(index).txt", in: folder, identifier: "id-b-\(index)"))
        }
        let domain = try harness.addDomain()
        domain.openFolder()
        domain.openFolder(harness.id(folder))
        harness.agent.fetchDelay = 5

        try harness.agent.pin(identifier: folder)
        domain.signalWorkingSet()
        domain.runEagerPass()

        XCTAssertEqual(domain.fetchBatchSizes, [6, 6, 6, 6, 6], "MQ-031")
        XCTAssertEqual(domain.peakFetchesInFlight, 6, "never seven")
        XCTAssertEqual(domain.replica.downloadedCount, 30)

        // Eight opens from a shell, all at once.
        domain.evictItem(harness.id(folder))
        domain.peakFetchesInFlight = 0
        harness.finder.openAtOnce(identifiers.prefix(8).map(harness.id))
        XCTAssertEqual(domain.peakFetchesInFlight, 8, "MQ-032: all eight admitted at once")
        XCTAssertTrue(domain.fetchFailures.isEmpty, "and none refused")
    }

    // MARK: G9 - `evictItem` is recursive

    /// A materialized tree, evicted from the root container.
    ///
    /// `MQ-020`: one call takes a directory **recursively** - 11 materialized items to 0 -
    /// and `MQ-030`: the root is not a special case. That is what `evict --all` is, and
    /// why the TTL loop still goes file by file: a TTL is per file.
    func testG9_EvictOnTheRootContainerIsRecursive() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Tree")
        let nested = try harness.serverCreatesDirectory("Nested", identifier: "id-Nested", parent: folder)
        var files: [String] = []
        for index in 0..<5 {
            files.append(try harness.serverCreates("a\(index).txt", in: folder, identifier: "id-a-\(index)"))
            files.append(try harness.serverCreates("n\(index).txt", in: nested, identifier: "id-n-\(index)"))
        }
        let domain = try harness.addDomain()
        domain.openFolder()
        domain.openFolder(harness.id(folder))
        domain.openFolder(harness.id(nested))
        for file in files { harness.finder.read(harness.id(file)) }
        XCTAssertEqual(domain.replica.downloadedCount, 10)

        let outcome = domain.evictItem(.rootContainer)
        XCTAssertEqual(outcome, .evicted(count: 10))
        XCTAssertEqual(domain.replica.downloadedCount, 0, "MQ-020, MQ-030: directories included")
        XCTAssertEqual(
            domain.replica.listing(of: .rootContainer), ["Tree"], "and nothing was removed")
    }

    // MARK: G13 - Finder's own two entries

    /// `MQ-053`: Finder's own File Provider entries are exactly two, chosen by
    /// `isDownloaded` and **nothing else** - `Download Now` when the item is dataless,
    /// `Remove Download` when it is materialized - and `Remove Download` is still offered
    /// on a kept item, where it fails. It draws no built-in "Keep Downloaded" for a
    /// third-party provider, which is why our labels do not clash.
    ///
    /// What Finder *puts on the screen* is a VM measurement (docs/design/eviction.md);
    /// this asserts the rule that decides which entry exists.
    func testG10_FinderOwnsDownloadNowAndRemoveDownloadByDownloadState() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("doc.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        var titles = harness.finder.contextMenu(.items([harness.id(file)])).map(\.title)
        XCTAssertEqual(titles.first, "Download Now", "dataless")

        harness.finder.read(harness.id(file))
        titles = harness.finder.contextMenu(.items([harness.id(file)])).map(\.title)
        XCTAssertEqual(titles.first, "Remove Download", "materialized")

        // And on a kept item it is still offered, and still ours to let fail.
        try harness.agent.pin(identifier: file)
        domain.signalWorkingSet()
        titles = harness.finder.contextMenu(.items([harness.id(file)])).map(\.title)
        XCTAssertEqual(titles.first, "Remove Download", "MQ-053: offered on a kept item too")
        XCTAssertEqual(domain.evictItem(harness.id(file)).code, -2008, "where it fails")
        XCTAssertFalse(titles.contains("Keep Downloaded and Finder's own"), "no built-in of its own")
    }

    // MARK: G14 - our two custom actions

    /// `MQ-054`: exactly **one of the pair** at a time, at the **top level**, offered on
    /// the window background - where the item is the folder being shown - and **never on
    /// the sidebar row**, which is why a whole location is pinned only from the CLI.
    ///
    /// The declaration the rules come from is the shipped `Info.plist`, read here rather
    /// than paraphrased, so the model cannot drift from what the appex actually declares.
    func testG11_OneOfThePairTopLevelWindowBackgroundYesSidebarNo() throws {
        let harness = try ScenarioHarness()
        let folder = try harness.serverCreatesDirectory("Documents")
        let file = try harness.serverCreates("plain.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        let declared = try Self.declaredActions()
        XCTAssertEqual(declared, ActionDeclaration.shipped, "the model reads the shipped plist")

        let unkept = harness.finder.contextMenu(.items([harness.id(file)]), actions: declared)
        XCTAssertEqual(unkept.filter { $0.actionIdentifier != nil }.map(\.title), ["Keep Downloaded"])
        XCTAssertTrue(unkept.filter { $0.actionIdentifier != nil }.allSatisfy(\.isTopLevel))

        try harness.agent.pin(identifier: file)
        domain.signalWorkingSet()
        let kept = harness.finder.contextMenu(.items([harness.id(file)]), actions: declared)
        XCTAssertEqual(
            kept.filter { $0.actionIdentifier != nil }.map(\.title), ["Don't Keep Downloaded"],
            "MQ-054: exactly one of the pair")

        // The window background, evaluated against the folder being shown.
        let background = harness.finder.contextMenu(
            .windowBackground(harness.id(folder)), actions: declared)
        XCTAssertEqual(
            background.filter { $0.actionIdentifier != nil }.map(\.title), ["Keep Downloaded"])

        // The sidebar row offers nothing of ours, on any state.
        let sidebar = harness.finder.contextMenu(.sidebarRow, actions: declared)
        XCTAssertTrue(
            sidebar.allSatisfy { $0.actionIdentifier == nil },
            "MQ-054: never on the sidebar row")

        // An empty selection matches neither entry: the "at least one" form is false,
        // where the "all selected items" form would be `0 == nil-count` and show both.
        XCTAssertTrue(harness.finder.contextMenu(.items([]), actions: declared).isEmpty)
    }

    /// **The bite-proof for `MQ-055`.** The bound key is `fileproviderItems`, lower-case
    /// p, as a **key path**. Either mistake - the capital-P spelling Apple's documentation
    /// uses, or a `$` substitution variable against an empty bindings dictionary - drops
    /// the entry **silently**, with nothing in any log. Both are one character from the
    /// shipped rule and both are asserted to produce no menu entry at all.
    func testG11_EitherMisspellingOfTheBindingDropsTheEntrySilently() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("plain.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        let items = [try XCTUnwrap(domain.replica.item(harness.id(file)))]

        let shipped = ActionDeclaration.shipped[0].activationRule
        XCTAssertEqual(ActivationRule.evaluate(shipped, items: items), true)

        for wrong in [
            shipped.replacingOccurrences(of: "fileproviderItems", with: "fileProviderItems"),
            shipped.replacingOccurrences(of: "fileproviderItems", with: "$fileproviderItems"),
        ] {
            XCTAssertNil(
                ActivationRule.evaluate(wrong, items: items),
                "MQ-055: the rule is dropped, not answered false")
            let menu = harness.finder.contextMenu(
                .items([harness.id(file)]),
                actions: [
                    ActionDeclaration(
                        identifier: "org.shirls.sshdrive.action.pin", name: "Keep Downloaded",
                        activationRule: wrong)
                ])
            XCTAssertTrue(
                menu.filter { $0.actionIdentifier != nil }.isEmpty,
                "and the entry never appears, with nothing to say why")
        }
    }

    /// The appex's own `NSExtensionFileProviderActions`, read from the repository, so that
    /// a change to the plist that the model does not know about fails here rather than in
    /// a menu nobody can see (`MQ-055`, `MQ-056`).
    static func declaredActions() throws -> [ActionDeclaration] {
        let plist = repositoryRoot()
            .appendingPathComponent("Apps/FileProvider/Info.plist")
        let data = try Data(contentsOf: plist)
        let root =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let extensionDictionary = root?["NSExtension"] as? [String: Any]
        let actions = extensionDictionary?["NSExtensionFileProviderActions"] as? [[String: Any]] ?? []
        return actions.map {
            ActionDeclaration(
                identifier: $0["NSExtensionFileProviderActionIdentifier"] as? String ?? "",
                name: $0["NSExtensionFileProviderActionName"] as? String ?? "",
                activationRule: $0["NSExtensionFileProviderActionActivationRule"] as? String ?? "")
        }
    }

    /// `Packages/SSHDriveCore/Tests/SystemModelTests/<file>` -> the repository root.
    static func repositoryRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }
}
