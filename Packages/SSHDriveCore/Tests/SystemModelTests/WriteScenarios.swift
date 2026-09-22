import XCTest
import Config
import Index
import ProviderCore
import SystemModel

/// **Suite D - writes, conflicts and atomicity**, and the three offline rows of **suite F**
/// that are about the same queue (docs/design/testing.md).
///
/// Every one of these is a statement about what *the system* does with a reply, and the
/// write design (docs/design/writes.md) rests on all of them: that a returned version is
/// believed (`MQ-013`) is why the conflict copy has to evict, and that a
/// `.filenameCollision` is retried for ever (`MQ-014`) is why one may never be answered
/// for a name that is not about to free itself.
final class WriteScenarios: XCTestCase {

    /// The measured intervals, compared as the clock produced them: the model's virtual
    /// clock accumulates in `Double`, so the comparison is to the millisecond rather than
    /// to the bit.
    static func assertSchedule(
        _ measured: [Double], matches expected: [Double], _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(measured.count, expected.count, message, file: file, line: line)
        for (index, wanted) in expected.enumerated() where index < measured.count {
            XCTAssertEqual(measured[index], wanted, accuracy: 0.001, message, file: file, line: line)
        }
    }

    // MARK: D1 - a `modifyItem` reply is believed

    /// A materialized file, and a reply carrying a version that is not the one written.
    ///
    /// `MQ-013`: no second `modifyItem`, no re-fetch, no conflict flag - the replica
    /// records the invented version and keeps the local bytes under it, for ever. The
    /// whole of the conflict path (docs/design/writes.md) exists because of this one
    /// assertion.
    func testD1_AModifyItemReplyIsBelieved() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("note.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        XCTAssertTrue(try XCTUnwrap(domain.replica.item(harness.id(file))).isDownloaded)

        harness.agent.onModify = { identifier, _, _ in
            .success(
                ItemView(
                    identifier: identifier, parentIdentifier: .rootContainer,
                    filename: "note.txt", contentTypeHint: .filenameExtension("txt"),
                    capabilities: .allowsReading, fileSystemFlags: [], documentSize: 4096,
                    contentModificationDate: 0, contentVersion: "a-version-nobody-wrote",
                    metadataVersion: "m1"))
        }
        let sequence = harness.finder.save(harness.id(file))
        harness.system.advance(15 * 60)

        let item = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertEqual(item.contentVersion, "a-version-nobody-wrote", "MQ-013: believed as it stands")
        XCTAssertTrue(item.isDownloaded, "the local bytes are still what is on disk")
        XCTAssertEqual(domain.offers(ofSequence: sequence).count, 1, "never re-offered")
        XCTAssertEqual(harness.agent.fetchCount[file], 1, "and never re-fetched")
        XCTAssertTrue(domain.queued.isEmpty)
    }

    // MARK: D2 - the conflict copy evicts, retried

    /// A local edit against a remote change between base and now.
    ///
    /// The agent makes the conflict copy, returns the **remote** item, and then has two
    /// things left to do that the system will not do for it: evict, because the returned
    /// version is believed (`MQ-013`), and signal the working set, because the copy is a
    /// new sibling in a folder that is enumerated once, ever (`MQ-001`). The first
    /// `evictItem` is refused `-2008` (`MQ-017`) and the retry on the 0.25 s doubling
    /// backoff succeeds.
    func testD2_TheConflictCopyEvictsOnARetryAndIsSignalled() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("report.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))

        harness.agent.makeConflictCopyOnNextModify(remoteSize: 999)
        harness.finder.save(harness.id(file), size: 24)
        harness.system.advance(1)

        let afterReply = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertEqual(afterReply.size, 999, "MQ-013: the remote item is recorded as current")
        XCTAssertTrue(afterReply.isDownloaded, "and the bytes on disk are still the Mac's")

        // The agent's retried eviction (docs/design/writes.md): doubling from 0.25 s,
        // given up after seven attempts.
        let (outcome, tries) = domain.evictWithBackoff(harness.id(file))
        XCTAssertEqual(tries, 2, "MQ-017: the first call is refused, the first retry is enough")
        XCTAssertTrue(outcome.didEvict)
        XCTAssertEqual(domain.evictionAttempts.first?.outcome.code, -2008)
        XCTAssertFalse(try XCTUnwrap(domain.replica.item(harness.id(file))).isDownloaded)

        // And the copy: invisible until the working set is signalled, because the folder
        // is never enumerated again.
        XCTAssertEqual(harness.finderListing(), ["report.txt"])
        domain.signalWorkingSet()
        XCTAssertEqual(
            harness.finderListing(), ["report (conflicted copy from mac).txt", "report.txt"])
    }

    /// **The bite-proof.** The same conflict without the retried eviction - one call, the
    /// refusal taken as the answer.
    ///
    /// Everything above is false here: the replica keeps the *local* bytes under the
    /// *remote* version, for ever, which is precisely the loss the eviction exists to
    /// prevent. If this ever passes, `D2` has stopped testing anything.
    func testD2_WithoutTheRetryTheReplicaKeepsLocalBytesUnderTheRemoteVersion() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("report.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))

        harness.agent.makeConflictCopyOnNextModify(remoteSize: 999)
        harness.finder.save(harness.id(file), size: 24)
        harness.system.advance(1)

        // One call, no retry. It is refused, and nothing in the system ever comes back to
        // it: there is no re-fetch and no re-offer (`MQ-013`).
        let outcome = domain.evictItem(harness.id(file))
        XCTAssertEqual(outcome.code, -2008)
        harness.system.advance(60 * 60)
        let item = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertTrue(item.isDownloaded, "the Mac's bytes are still what any open returns")
        XCTAssertEqual(item.size, 999, "under the server's version, for ever")
    }

    // MARK: D3 - `.filenameCollision` only when the name frees

    /// A standing `.filenameCollision` from `createItem`.
    ///
    /// `MQ-014`: it is retried **for ever** with no alert, on the measured 0 s / 0.04 s /
    /// 5 s / 15 s backoff; the caller was told it succeeded, the item stays in the mount,
    /// and `enumeratorForPendingItems` stays empty. So a refusal that is not about to
    /// resolve itself is a permanent invisible loop, which is why a `.filenameCollision`
    /// is answered only where the conflict path is about to rename our file away
    /// (docs/design/writes.md).
    func testD3_AStandingFilenameCollisionIsAnInvisibleForeverLoop() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()
        harness.agent.onCreate = { _ in .failure(.filenameCollision) }

        let identifier = harness.finder.create("new.txt")
        let sequence = 1
        harness.system.advance(30 * 60)

        let offers = domain.offers(ofSequence: sequence)
        XCTAssertGreaterThan(offers.count, 6, "MQ-014: retried for ever")
        Self.assertSchedule(
            domain.retryIntervals(ofSequence: sequence), matches: [0, 0.04, 5, 15],
            "MQ-014: the measured backoff")
        XCTAssertEqual(
            domain.pendingIdentifiers, [], "MQ-014: the pending-items enumerator stays empty")
        XCTAssertNil(
            domain.replica.item(identifier)?.uploadingErrorCode,
            "MQ-014: the caller was told it succeeded; there is no alert anywhere")
        XCTAssertEqual(domain.replica.item(identifier)?.filename, "new.txt", "still in the mount")
        XCTAssertTrue(
            offers.allSatisfy { $0.failure == .filenameCollision },
            "and every one of them came back the same way")
    }

    /// The other half: a **real** collision inside Finder never reaches the provider at
    /// all (`MQ-015`). Finder renames the duplicate itself, so the name that arrives is
    /// already free.
    func testD3_FinderRenamesADuplicateBeforeItReachesTheProvider() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("run.sh")
        let domain = try harness.addDomain()
        domain.openFolder()

        harness.finder.duplicate(harness.id(file))
        harness.system.advance(1)

        XCTAssertEqual(
            domain.calls.compactMap {
                if case .createItem(let filename, _) = $0 { return filename }
                return nil
            }, ["run copy.sh"], "MQ-015: Finder resolved it; the provider was never asked twice")
        XCTAssertTrue(
            domain.writeOffers.allSatisfy { $0.failure == nil }, "and nothing collided")
        XCTAssertEqual(harness.finderListing(), ["run copy.sh", "run.sh"])
    }

    // MARK: D4 - a pending edit on a deleted item

    /// A pending `modifyItem` whose row the agent has forgotten, with the path still taken
    /// on the server.
    ///
    /// `MQ-080`: the system does not lose the edit - it re-offers it as a
    /// **`createItem`** of the same name, which then collides with the path that is still
    /// there and is retried for ever (`MQ-014`), invisibly. That is why the mass-deletion
    /// guard (docs/design/change-detection.md) holds pending items and their ancestors
    /// rather than reporting them deleted.
    func testD4_APendingEditOnADeletedItemComesBackAsACollidingCreate() throws {
        let harness = try ScenarioHarness()
        let original = try harness.serverCreates("edit.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(original))

        // The row is forgotten - a re-listing minted a new identifier for the same path,
        // which is exactly the case the guard exists for - and the edit is offered.
        try harness.serverDeletes(original)
        try harness.serverCreates("edit.txt", identifier: "id-edit-again")
        let sequence = harness.finder.save(harness.id(original))
        harness.system.advance(30 * 60)

        XCTAssertEqual(
            domain.offers(ofSequence: sequence).count, 1, "the modify is offered exactly once")
        XCTAssertEqual(domain.offers(ofSequence: sequence).first?.failure, .noSuchItem)
        let creates = domain.calls.filter {
            if case .createItem(let filename, _) = $0 { return filename == "edit.txt" }
            return false
        }
        XCTAssertGreaterThan(creates.count, 5, "MQ-080 then MQ-014: re-offered as a create, for ever")
        XCTAssertEqual(domain.pendingIdentifiers, [], "and invisible while it happens")
    }

    // MARK: D9 - an atomic save keeps the identifier

    /// TextEdit's save and the shell's write-a-temp-and-`mv`.
    ///
    /// `MQ-049`: **one `modifyItem` on the original item**, no `createItem`, no
    /// `deleteItem`. Without tombstones (docs/design/item-index.md) the other shape would
    /// lose a pin or a tag placed on that one file. `MQ-048`: a rename is one `modifyItem`
    /// too, with
    /// `changedFields = 0x2`.
    func testD9_AnAtomicSaveIsOneModifyItemOnTheOriginalIdentifier() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("doc.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        domain.resetCalls()

        harness.finder.save(harness.id(file))
        harness.system.advance(1)

        let modifies = domain.calls.compactMap { call -> (String, UInt)? in
            if case .modifyItem(let identifier, let fields, _) = call { return (identifier, fields) }
            return nil
        }
        XCTAssertEqual(modifies.count, 1)
        XCTAssertEqual(modifies.first?.0, file, "MQ-049: on the original identifier")
        XCTAssertEqual(modifies.first?.1, 0x289, "MQ-049: the mask TextEdit's save carried")
        XCTAssertFalse(
            domain.calls.contains { if case .createItem = $0 { return true } else { return false } })
        XCTAssertFalse(
            domain.calls.contains { if case .deleteItem = $0 { return true } else { return false } })

        // MQ-048: and a rename is one modifyItem with 0x2.
        domain.resetCalls()
        harness.finder.rename(harness.id(file), to: "renamed.txt")
        harness.system.advance(1)
        XCTAssertEqual(
            domain.calls.compactMap { call -> UInt? in
                if case .modifyItem(_, let fields, _) = call { return fields }
                return nil
            }, [0x2])
        XCTAssertEqual(harness.finderListing(), ["renamed.txt"])
    }

    // MARK: D12 - the two answers a `fetchContents` may give

    /// `MQ-012`: from `fetchContents`, `.noSuchItem` and `.cannotSynchronize` **both leave
    /// the item in place** and differ only in what the reader is told - `ESTALE` against
    /// `ETIMEDOUT`. Both are reversible, which is what lets the mass-deletion guard answer
    /// `.cannotSynchronize` for a held item without destroying anything.
    ///
    /// `MQ-011` is the contrast that makes the rule matter: the *same* code from
    /// `item(for:)` makes the system consider the item deleted and delete the user's file.
    func testD10_BothFetchFailuresLeaveTheItemInPlaceAndOnlyItemForDeletes() throws {
        let harness = try ScenarioHarness()
        let held = try harness.serverCreates("held.txt")
        let stale = try harness.serverCreates("stale.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        harness.agent.fetchFailures = [held: .cannotSynchronize, stale: .noSuchItem]
        harness.finder.read(harness.id(held))
        harness.finder.read(harness.id(stale))
        harness.system.advance(10 * 60)

        XCTAssertEqual(
            harness.finderListing(), ["held.txt", "stale.txt"],
            "MQ-012: neither answer removes anything")
        XCTAssertFalse(try XCTUnwrap(domain.replica.item(harness.id(held))).isDownloaded)

        // MQ-011: from `item(for:)` the same `.noSuchItem` deletes the user's file.
        harness.agent.isReachable = false
        try harness.writer.delete(identifier: stale)
        harness.agent.isReachable = true
        _ = domain.item(for: harness.id(stale))
        XCTAssertEqual(harness.finderListing(), ["held.txt"], "MQ-011")
    }

    // MARK: F2 - no system retry for a fetch

    /// `MQ-036`: the system **never re-issues a failed `fetchContents`**. One call, one
    /// error, and nothing for the next seven minutes; a second read produces a second
    /// call, so the item is not poisoned - there is simply no retry. That is why the
    /// agent gives a read one retry of its own (docs/design/offline.md).
    func testF2_AFailedFetchIsNeverReIssued() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("far.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.agent.fetchFailures = [file: .serverUnreachable]

        harness.finder.read(harness.id(file))
        harness.system.advance(7 * 60)
        XCTAssertEqual(harness.agent.fetchCount[file], 1, "MQ-036: nothing came back for it")
        XCTAssertEqual(domain.fetchFailures, [harness.id(file)])

        // A second read is a second call: the item is not poisoned.
        harness.agent.fetchFailures = [:]
        harness.finder.read(harness.id(file))
        XCTAssertEqual(harness.agent.fetchCount[file], 2)
        XCTAssertTrue(try XCTUnwrap(domain.replica.item(harness.id(file))).isDownloaded)
    }

    // MARK: F4 - a queued write is re-offered for ever

    /// `MQ-035`: the doubling backoff, measured at 5.50, 10.56, 20.30, 43.03, 79.36,
    /// 153.23 and 331.30 s and still climbing ten minutes into the outage, with no ceiling
    /// in sight - and `MQ-003`: **each retry arrives on a freshly launched instance**, so
    /// nothing an extension learned survives to the next attempt.
    func testF4_AQueuedWriteIsReOfferedForEverOnTheMeasuredBackoff() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("queued.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        harness.agent.isReachable = false

        let sequence = harness.finder.save(harness.id(file))
        harness.system.advance(12 * 60)

        Self.assertSchedule(
            domain.retryIntervals(ofSequence: sequence),
            matches: [5.50, 10.56, 20.30, 43.03, 79.36, 153.23],
            "MQ-035, interval for interval")
        XCTAssertTrue(domain.hasPendingWrites, "it never gives up")
        XCTAssertEqual(
            domain.pendingIdentifiers, [harness.id(file)],
            "and unlike a collision this one is in the pending set")
        let instances = domain.offers(ofSequence: sequence).map(\.instance)
        XCTAssertEqual(Set(instances).count, instances.count, "MQ-003: a fresh instance each time")
    }

    // MARK: F1 - `signalErrorResolved` is the only flush

    /// `MQ-037`: a queued write is flushed by `signalErrorResolved(.serverUnreachable)`
    /// and by nothing else. `signalEnumerator(.workingSet)` alone did nothing in 60 s and
    /// a plain reconnect nothing in 75 s; the `modifyItem` arrived 20 ms after the call.
    func testF1_OnlySignalErrorResolvedFlushesTheQueue() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("flush.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        harness.agent.isReachable = false

        let sequence = harness.finder.save(harness.id(file))
        harness.system.advance(6 * 60)
        let offersDuringTheOutage = domain.offers(ofSequence: sequence).count
        XCTAssertGreaterThan(offersDuringTheOutage, 3, "the backoff is past five minutes")

        // The connection comes back. Nothing happens: the system is not watching.
        harness.agent.isReachable = true
        harness.system.advance(1)
        XCTAssertEqual(domain.offers(ofSequence: sequence).count, offersDuringTheOutage)

        // A signalled enumerator is re-scheduled, not un-throttled, and flushes nothing.
        domain.signalWorkingSet()
        harness.system.advance(1)
        XCTAssertEqual(
            domain.offers(ofSequence: sequence).count, offersDuringTheOutage,
            "MQ-037: signalEnumerator alone does nothing")
        XCTAssertTrue(domain.hasPendingWrites)

        domain.signalErrorResolved(.serverUnreachable)
        harness.system.advance(0.02)
        XCTAssertEqual(
            domain.offers(ofSequence: sequence).count, offersDuringTheOutage + 1,
            "MQ-037: 20 ms after the call")
        XCTAssertFalse(domain.hasPendingWrites, "and it went through")
    }
}
