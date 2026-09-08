import XCTest
import Config
import Index
import ProviderCore
import SystemModel

/// **Suite B - the trash** and the modellable half of **suite M - symlinks**
/// (`docs/testing-architecture.md` section 5).
///
/// The trash rows are the `.Trash` hang, which made `ls -la` of a mount never return; the
/// symlink rows are S8's answers about what the system does with an item we serve as a
/// link, and what happens to a link it refuses.
final class TrashAndSymlinkScenarios: XCTestCase {

    // MARK: B1 - the `.Trash` materialize loop

    /// A fresh domain: the system creates its trash node and asks
    /// `enumerator(for: .trashContainer)`.
    ///
    /// The provider answers `NSCocoaErrorDomain`/`NSFeatureUnsupportedError` and **never**
    /// `.noSuchItem` (`MQ-010`); the system gives up after two attempts and removes
    /// `.Trash` from the mount; a `stat` of the mount returns.
    func testB1_TheTrashIsAnsweredFeatureUnsupportedAndRetiredAfterTwoAttempts() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()

        XCTAssertTrue(
            domain.calls.contains(.trashNodeCreated),
            "MQ-075: the system makes the node itself at add(domain) time")
        XCTAssertEqual(domain.trash.asks, 1)
        XCTAssertEqual(domain.trash.lastFailure, .featureUnsupported)
        XCTAssertNotEqual(domain.trash.lastFailure, .noSuchItem, "MQ-009 is what that would cost")

        harness.system.advance(5)
        XCTAssertEqual(domain.trash.asks, 2, "MQ-010: two attempts")
        XCTAssertTrue(domain.trash.retired)
        XCTAssertFalse(domain.trash.existsInMount, "and `.Trash` is gone from the mount")
        XCTAssertTrue(domain.calls.contains(.trashRemovedFromMount))
        XCTAssertNotNil(domain.listMountRoot(), "a `ls -la` of the mount returns")

        harness.system.advance(10 * 60)
        XCTAssertEqual(domain.trash.asks, 2, "and it is never asked again")
    }

    /// **The bite-proof.** The same domain answering `.noSuchItem`, which is what version
    /// 0.1.0 did.
    ///
    /// `MQ-009`: the system deletes the trash from disk, fails because the node is its
    /// own, re-materializes it and asks again about once a second, **for ever** - and
    /// `ls -la` of the mount never returns. If this ever stops looping, `B1` above has
    /// stopped testing anything.
    func testB1_AnsweringNoSuchItemHangsTheMountForEver() throws {
        let harness = try ScenarioHarness()
        harness.trashAnswerOverride = .noSuchItem
        let domain = try harness.addDomain()

        harness.system.advance(10 * 60)
        XCTAssertGreaterThan(domain.trash.materializeLoopTurns, 500, "MQ-009: about once a second")
        XCTAssertFalse(domain.trash.retired, "it never gives up")
        XCTAssertTrue(domain.trash.existsInMount)
        XCTAssertNil(domain.listMountRoot(), "`ls -la` of the mount never returns")
    }

    // MARK: B2 - `supportsSyncingTrash = false` alone is not enough

    /// The domain added with the flag off.
    ///
    /// `MQ-008`: it defaults to YES and turning it off changes nothing the model can see -
    /// the trash node is still created and still asked about twice. **The error code is
    /// what retires it** (`MQ-010`), which is the half of the fix that did the work.
    func testB2_TheFlagAloneDoesNotStopTheTrashBeingCreatedOrAsked() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain(supportsSyncingTrash: false)

        XCTAssertFalse(domain.supportsSyncingTrash)
        XCTAssertTrue(domain.calls.contains(.trashNodeCreated), "MQ-075, flag or no flag")
        harness.system.advance(5)
        XCTAssertEqual(domain.trash.asks, 2, "MQ-008: asked exactly as it would have been")
        XCTAssertTrue(domain.trash.retired, "MQ-010: and it is the error code that retires it")
    }

    // MARK: B3 - a `.Trash` create under the root is refused

    /// `createItem(filename: ".Trash", parent: .rootContainer)`.
    ///
    /// Refused feature-unsupported by the extension itself, and **nothing is sent to the
    /// server**: with `supportsSyncingTrash = false` the system decides how to handle a
    /// trashing operation, and whatever it decides, it is not a `.Trash` directory of ours
    /// on someone's server (section 5.4).
    func testB3_ATrashCreateUnderTheRootIsRefusedAndNothingIsSent() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()

        let identifier = harness.finder.create(".Trash", isDirectory: true)
        harness.system.advance(60)

        XCTAssertEqual(
            domain.replica.item(identifier)?.uploadingErrorCode, 3328,
            "NSFeatureUnsupportedError, from the extension and not from the agent")
        XCTAssertFalse(
            harness.agent.calls.contains { $0.hasPrefix("createItem(.Trash") },
            "nothing reached the agent, and so nothing reached the server")
        XCTAssertNil(try harness.writer.item(path: Data(".Trash".utf8)))
    }

    // MARK: M3 - a refused `ln -s` is a sync error

    /// An escaping target created in the mount.
    ///
    /// S8: `ln -s` exits 0 and the system keeps the item locally; the refusal comes back
    /// as the item's `uploadingError` (`MQ-078`, -2005) with the system's own wording, and
    /// section 5.7's sentence about the target reaches the user only through
    /// `sshdrive status`'s sync-error list. An in-root relative target, by contrast,
    /// reaches `createItem` with the target **intact**.
    func testM3_ARefusedLinkSurfacesOnlyAsTheItemsUploadingError() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("note.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        let good = harness.finder.symlink("rel-inside", target: "note.txt")
        let bad = harness.finder.symlink("escape", target: "../../etc/passwd")
        let absolute = harness.finder.symlink("absolute", target: "/etc/passwd")
        harness.system.advance(60)

        // The target crossed unchanged, which is what S8 asked and what section 5.7's
        // check needs in order to be applied at all.
        XCTAssertTrue(harness.agent.calls.contains("createItem(rel-inside)"))
        XCTAssertNil(domain.replica.item(good)?.uploadingErrorCode)

        for refused in [bad, absolute] {
            let item = try XCTUnwrap(domain.replica.item(refused))
            XCTAssertEqual(item.uploadingErrorCode, -2005, "MQ-078: and nowhere else")
            XCTAssertNotNil(
                domain.replica.identifier(atPath: item.filename),
                "the item is still in the mount; `ln -s` exited 0")
        }
        XCTAssertNil(
            try harness.writer.item(path: Data("escape".utf8)),
            "and neither target ever left the Mac")
        XCTAssertEqual(domain.pendingIdentifiers, [], "nor is it queued for ever")
    }

    // MARK: M4 - what the system makes of a link we serve

    /// `MQ-076`: the system creates a **real symlink** under CloudStorage for an item
    /// served as one - `lrwx------`, and `readlink` returns the row's target. `MQ-077`: a
    /// **dangling** one presents identically - same badge, same Kind, size = the target
    /// string's length, no broken-link marker - so nothing in the mount distinguishes a
    /// link whose target is missing, and neither may we.
    func testM4_ARealSymlinkIsMadeAndADanglingOneIsIndistinguishable() throws {
        let harness = try ScenarioHarness()
        try harness.serverCreates("note.txt")
        let domain = try harness.addDomain()
        domain.openFolder()

        harness.finder.symlink("live", target: "note.txt")
        harness.finder.symlink("dangling", target: "gone.txt")
        harness.system.advance(60)
        domain.signalWorkingSet()

        // The identifiers are the agent's now: a create that lands re-keys the item the
        // user made, and nothing is re-downloaded for it.
        let liveItem = try XCTUnwrap(
            domain.replica.item(try XCTUnwrap(domain.replica.identifier(atPath: "live"))))
        let danglingItem = try XCTUnwrap(
            domain.replica.item(try XCTUnwrap(domain.replica.identifier(atPath: "dangling"))))
        for item in [liveItem, danglingItem] {
            XCTAssertTrue(item.isSymlink, "MQ-076: a real link, not a placeholder file")
            XCTAssertNil(item.uploadingErrorCode)
        }
        XCTAssertEqual(liveItem.symlinkTarget, "note.txt", "readlink returns the row's target")
        XCTAssertEqual(danglingItem.symlinkTarget, "gone.txt")
        XCTAssertEqual(
            danglingItem.size, Int64("gone.txt".utf8.count),
            "MQ-077: size is the target string's length")
        XCTAssertNil(
            domain.replica.identifier(atPath: "gone.txt"), "and the target really is not there")
    }
}
