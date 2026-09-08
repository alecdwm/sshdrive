import XCTest
import Config
import Index
import ProviderCore
import SystemModel
import XPCProtocols

/// **Suite L - paths, names and attributes**, and `E3`, which is about the same blob
/// (`docs/testing-architecture.md` section 5).
///
/// The whole of section 5.4's local-attribute design rests on three measurements that all
/// cut the same way: the system decides what we are told (`MQ-044`), tags are not an xattr
/// (`MQ-042`), and what we do not return we lose (`MQ-043`).
final class AttributeScenarios: XCTestCase {

    // MARK: L3 - `displayName` is the bare nickname

    /// `MQ-050`: the mount directory is `SSHDrive-<displayName, spaces removed>` and
    /// Finder's label is `SSH Drive - <displayName>`, so a nickname that already contains
    /// the app's name stutters in both. Nothing in the system trims it for us.
    func testL3_TheMountDirectoryAndTheLabelAreDerivedFromTheBareNickname() throws {
        let plain = try ScenarioHarness(displayName: "nas")
        let plainDomain = try plain.addDomain()
        XCTAssertEqual(plainDomain.mountDirectoryName, "SSHDrive-nas")
        XCTAssertEqual(plainDomain.sidebarLabel, "SSH Drive - nas")

        let stuttering = try ScenarioHarness(displayName: "SSH Drive - nas2")
        let stutteringDomain = try stuttering.addDomain()
        XCTAssertEqual(stutteringDomain.mountDirectoryName, "SSHDrive-SSHDrive-nas2", "MQ-050")
        XCTAssertEqual(stutteringDomain.sidebarLabel, "SSH Drive - SSH Drive - nas2")
    }

    // MARK: L4 - tags travel as `tagData`

    /// A tagged file, evicted and re-downloaded.
    ///
    /// `MQ-042`: the tag arrives as one `modifyItem` with `changedFields = 0x10` and an
    /// **empty** `extendedAttributes` dictionary - it is never an xattr. The metadata
    /// version moves, because the blob it hashes moved. `MQ-043`: the tag survives the
    /// re-download **because the item returns it**; an item that returned nothing would
    /// lose the user's tags, which is the S4 loss this design exists to prevent.
    func testL4_ATagIsTagDataAndSurvivesAReDownloadBecauseWeReturnIt() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("tagged.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        let before = try XCTUnwrap(domain.replica.item(harness.id(file))).metadataVersion

        var seenFields: UInt = 0
        var seenXattrs: [String: Data]?
        harness.agent.onModify = { _, fields, changes in
            seenFields = fields.rawValue
            seenXattrs = changes.newExtendedAttributes
            return nil
        }
        let tagArchive = Data("bplistfake-Red".utf8)
        harness.finder.tag(harness.id(file), tagArchive)
        harness.system.advance(1)

        XCTAssertEqual(seenFields, 0x10, "MQ-042: NSFileProviderItemTagData and nothing else")
        XCTAssertNil(seenXattrs, "MQ-042: an empty extendedAttributes dictionary came with it")
        let tagged = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertNotEqual(tagged.metadataVersion, before, "the xattr hash moved the version")

        // Evict and re-download: the system rebuilds the tags xattr from what the item
        // returns, which is why the row stores it. The eviction needs the retry of
        // `MQ-017`, because it is being issued straight after a `modifyItem` reply.
        XCTAssertTrue(domain.evictWithBackoff(harness.id(file)).outcome.didEvict)
        harness.finder.read(harness.id(file))
        let restored = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertEqual(restored.tagData, tagArchive, "MQ-043: because our item carried it")
        XCTAssertEqual(restored.extendedAttributes[ModelDomain.tagsXattrName], tagArchive)
    }

    /// **The bite-proof for `MQ-043`.** The same round trip with an item that returns no
    /// `tagData` - which is what section 5.4 said before S4 corrected it.
    ///
    /// The tags xattr is gone after the re-download, and no error is raised anywhere: the
    /// user simply loses the colour on the next remote change.
    func testL4_AnItemThatReturnsNoTagDataLosesTheUsersTags() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("tagged.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        harness.finder.tag(harness.id(file), Data("bplistfake-Red".utf8))
        harness.system.advance(1)
        XCTAssertNotNil(domain.replica.item(harness.id(file))?.tagData)

        // The row that forgets tags: every fetch answers with no `tagData` at all.
        try harness.forgetStoredTags(of: file)
        XCTAssertTrue(domain.evictWithBackoff(harness.id(file)).outcome.didEvict)
        harness.finder.read(harness.id(file))

        let restored = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertNil(restored.tagData, "MQ-043: wiped on the next re-download")
        XCTAssertNil(restored.extendedAttributes[ModelDomain.tagsXattrName])
    }

    /// `MQ-079`: the system asks **once**, and it asks once even when the reply carries the
    /// metadata version the item already had. So the xattr hash is not what stops a retry
    /// loop - there is no retry loop, for the same reason a returned version is believed at
    /// all (`MQ-013`). What the hash is for is the other direction: it is the only thing
    /// that moves an item's version when the **agent** changes the stored blob, which a
    /// restore from the index backup does.
    func testL4_AFrozenMetadataVersionStillEndsTheModify() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("frozen.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))
        let frozen = try XCTUnwrap(domain.replica.item(harness.id(file)))

        harness.agent.onModify = { identifier, _, _ in
            .success(
                ItemView(
                    identifier: identifier, parentIdentifier: .rootContainer,
                    filename: frozen.filename, contentTypeHint: .filenameExtension("txt"),
                    capabilities: .allowsReading, fileSystemFlags: [], documentSize: frozen.size,
                    contentModificationDate: frozen.mtime, contentVersion: frozen.contentVersion,
                    metadataVersion: frozen.metadataVersion))
        }
        let sequence = harness.finder.tag(harness.id(file), Data("bplistfake-Blue".utf8))
        harness.system.advance(60)

        XCTAssertEqual(domain.offers(ofSequence: sequence).count, 1, "MQ-079: asked once")
        XCTAssertEqual(
            domain.replica.item(harness.id(file))?.metadataVersion, frozen.metadataVersion,
            "and the version it was given is the version it kept (MQ-013)")
    }

    // MARK: L5 - the system filters xattrs

    /// Three xattrs written through the mount, one of them carrying `XATTR_FLAG_SYNCABLE`.
    ///
    /// `MQ-044`: only that one reaches `changedFields.extendedAttributes`; an ordinary
    /// name lives in the replica and the extension is **never told**, and
    /// `com.apple.metadata:_kMDItemUserTags` and `com.apple.FinderInfo` are excluded
    /// deliberately. `MQ-045`: all three survive an eviction, because the system treats
    /// extended attributes as metadata rather than content.
    func testL5_OnlyASyncableNamedXattrReachesTheExtension() throws {
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("report.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        harness.finder.read(harness.id(file))

        var delivered: [[String: Data]] = []
        harness.agent.onModify = { _, fields, changes in
            if fields.contains(.extendedAttributes) {
                delivered.append(changes.newExtendedAttributes ?? [:])
            }
            return nil
        }
        harness.finder.setExtendedAttribute(
            harness.id(file), name: "org.sshdrive.spike", value: Data("s4-4".utf8))
        harness.finder.setExtendedAttribute(
            harness.id(file), name: "org.sshdrive.spike2#S", value: Data("syncable-value".utf8))
        harness.finder.setExtendedAttribute(
            harness.id(file), name: "com.apple.FinderInfo", value: Data([0, 1]))
        harness.system.advance(1)

        XCTAssertEqual(delivered.count, 1, "MQ-044: one of the three")
        XCTAssertEqual(delivered.first.map { Array($0.keys) }, ["org.sshdrive.spike2#S"])

        // MQ-045: and all three are still on the file after it goes dataless. The
        // eviction takes the `MQ-017` retry, being issued straight after a reply.
        XCTAssertTrue(domain.evictWithBackoff(harness.id(file)).outcome.didEvict)
        let item = try XCTUnwrap(domain.replica.item(harness.id(file)))
        XCTAssertFalse(item.isDownloaded)
        XCTAssertEqual(
            item.extendedAttributes.keys.sorted(),
            ["com.apple.FinderInfo", "org.sshdrive.spike", "org.sshdrive.spike2#S"])
    }

    // MARK: L6 - `.DS_Store` never arrives

    /// `MQ-046`: a `.DS_Store` written into the mount **never reaches the extension** - no
    /// `createItem`, no `modifyItem`, no row. The system keeps it in the replica, reports
    /// it with `isUploaded = 0` and never asks anyone to upload it, which is why the
    /// local-only row of section 5.4 exists for a different writer and not for this one.
    func testL6_ADSStoreIsKeptByTheSystemAndNeverOffered() throws {
        let harness = try ScenarioHarness()
        let domain = try harness.addDomain()
        domain.openFolder()

        let identifier = harness.finder.create(".DS_Store")
        harness.system.advance(10 * 60)

        XCTAssertTrue(domain.replica.contains(identifier), "the system keeps it")
        XCTAssertTrue(try XCTUnwrap(domain.replica.item(identifier)).isLocalOnly)
        XCTAssertTrue(domain.writeOffers.isEmpty, "MQ-046: nobody was ever asked")
        XCTAssertFalse(harness.agent.calls.contains { $0.hasPrefix("createItem") })
        XCTAssertNil(try harness.writer.item(path: Data(".DS_Store".utf8)), "and there is no row")
    }

    // MARK: E3 - sorted keys in the attributes blob

    /// A six-key `LocalAttributes`, encoded 200 times in one process.
    ///
    /// `.sortedKeys` is load-bearing: section 5.3 hashes exactly this blob into the
    /// metadata version, and without a promised key order the same attributes encode to
    /// two byte strings, the hash moves, and the system re-reads every item it holds for no
    /// reason. It was caught as a test failing about one run in three and had been read as
    /// flakiness.
    func testE3_TheAttributesBlobIsByteIdenticalEveryTime() throws {
        let attributes = LocalAttributes(
            xattrs: [
                "org.sshdrive.a": Data("1".utf8), "org.sshdrive.b": Data("2".utf8),
                "org.sshdrive.c": Data("3".utf8), "org.sshdrive.d#S": Data("4".utf8),
                "com.apple.FinderInfo": Data([0, 1]), "user.zzz": Data("z".utf8),
            ], tagData: Data("bplistfake-Red".utf8))
        let first = try XCTUnwrap(attributes.encoded())
        for _ in 0..<200 {
            XCTAssertEqual(attributes.encoded(), first, "the same attributes, the same bytes")
        }

        // And the metadata version does not move on its own: the same blob hashes the same
        // way, so nothing re-offers an item nobody touched.
        let harness = try ScenarioHarness()
        let file = try harness.serverCreates("steady.txt")
        let domain = try harness.addDomain()
        domain.openFolder()
        let version = try XCTUnwrap(domain.replica.item(harness.id(file))).metadataVersion
        for _ in 0..<5 {
            domain.signalWorkingSet()
            XCTAssertEqual(domain.replica.item(harness.id(file))?.metadataVersion, version)
        }
    }
}
