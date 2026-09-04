import XCTest
import Config
import FileProvider
import Index
import SFTP
import XPCProtocols

@testable import AgentCore

/// The row rules milestone 4 adds: the xattr and tag hash in the metadata version
/// (DESIGN.md sections 5.3, 5.4 - the S10 question), and the symlink check on the row
/// (section 5.7).
final class RowBuilderTests: XCTestCase {

    private let roots = SymlinkPolicy.Roots(canonical: "/home/alec")

    private var builder: RowBuilder {
        RowBuilder(
            permissions: .mode,
            identity: ServerIdentity(uid: 501, gid: 20, supplementaryGroups: []),
            roots: roots)
    }

    private var parent: IndexItem {
        IndexItem(
            identifier: IndexWriter.rootIdentifier, path: Data(), parent: nil,
            type: "directory", uid: 501, gid: 20, mode: 0o755)
    }

    private func file(size: Int64 = 10, mtime: Int64 = 1_700_000_000) -> SFTPFileAttributes {
        SFTPFileAttributes(
            type: .file, size: size, mtime: mtime, mode: 0o644, uid: 501, gid: 20)
    }

    // MARK: The xattr hash in the metadata version (S10)

    func testAnXattrChangeMovesTheMetadataVersionButNotTheContentVersion() throws {
        let path = try RelativePath(string: "a.txt")
        let bare = builder.build(
            path: path, attributes: file(), parent: parent, existing: nil).row
        let tagged = builder.build(
            path: path, attributes: file(), parent: parent, existing: bare,
            localAttributes: LocalAttributes(xattrs: ["com.apple.TextEncoding": Data("utf-8".utf8)])
        ).row

        XCTAssertEqual(bare.contentVersion, tagged.contentVersion)
        XCTAssertNotEqual(bare.metadataVersion, tagged.metadataVersion)
    }

    func testATagChangeMovesTheMetadataVersionToo() throws {
        // Section 5.4: tags are stored and served the same way as xattrs, in the row and
        // hashed into the metadata version, but through `tagData`. Without that, accepting
        // a tag change would return the version the system already holds and it would
        // re-offer the change for ever (the S10 question).
        let path = try RelativePath(string: "a.txt")
        let bare = builder.build(
            path: path, attributes: file(), parent: parent, existing: nil).row
        let tagged = builder.build(
            path: path, attributes: file(), parent: parent, existing: bare,
            localAttributes: LocalAttributes(tagData: Data([0x62, 0x70, 0x6c, 0x69]))).row
        XCTAssertNotEqual(bare.metadataVersion, tagged.metadataVersion)
    }

    func testTheSameAttributesTwiceProduceTheSameVersion() throws {
        // The hash is FNV-1a rather than `Hasher` precisely because Swift's is seeded per
        // process: a metadata version that moved at every agent restart would make the
        // system re-read every item it holds.
        let path = try RelativePath(string: "a.txt")
        let local = LocalAttributes(
            xattrs: ["x": Data([1, 2, 3])], tagData: Data([9]))
        let first = builder.build(
            path: path, attributes: file(), parent: parent, existing: nil,
            localAttributes: local
        ).row
        let second = builder.build(
            path: path, attributes: file(), parent: parent, existing: first,
            localAttributes: local
        ).row
        XCTAssertEqual(first.metadataVersion, second.metadataVersion)
    }

    func testAnItemWithNoLocalAttributesStoresNoBlobAtAll() throws {
        let row = builder.build(
            path: try RelativePath(string: "a.txt"), attributes: file(), parent: parent,
            existing: nil, localAttributes: LocalAttributes()
        ).row
        XCTAssertNil(row.xattrs)
    }

    func testTagsAndXattrsBothSurviveTheRoundTripToASnapshot() throws {
        let local = LocalAttributes(
            xattrs: ["com.apple.TextEncoding": Data("utf-8;134217984".utf8)],
            tagData: Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]))
        let row = builder.build(
            path: try RelativePath(string: "a.txt"), attributes: file(), parent: parent,
            existing: nil, localAttributes: local
        ).row
        let snapshot = row.snapshot
        XCTAssertEqual(
            snapshot.extendedAttributes["com.apple.TextEncoding"],
            Data("utf-8;134217984".utf8))
        XCTAssertEqual(snapshot.tagData, local.tagData)
    }

    // MARK: Symlinks on the row (section 5.7)

    func testALinkInsideTheShareGetsItsMacTargetOnTheRow() throws {
        let attributes = SFTPFileAttributes(
            type: .symlink, mode: 0o777, uid: 501, gid: 20, symlinkTarget: "../Media/clip.mov")
        let built = builder.build(
            path: try RelativePath(string: "Docs/link"), attributes: attributes,
            parent: parent, existing: nil)
        XCTAssertEqual(built.row.hidden, 0)
        XCTAssertEqual(
            built.row.linkTarget.map { String(decoding: $0, as: UTF8.self) },
            "../Media/clip.mov")
    }

    func testALinkThatEscapesIsHiddenWithAReason() throws {
        let attributes = SFTPFileAttributes(
            type: .symlink, mode: 0o777, uid: 501, gid: 20, symlinkTarget: "/etc/passwd")
        let built = builder.build(
            path: try RelativePath(string: "Docs/escape"), attributes: attributes,
            parent: parent, existing: nil)
        XCTAssertEqual(built.row.hidden, RowBuilder.hiddenEscapingLink)
        XCTAssertNil(built.row.linkTarget)
        XCTAssertFalse(built.hiddenReason.isEmpty)
    }

    func testAnAbsoluteInRootTargetIsRewrittenOnTheRow() throws {
        let attributes = SFTPFileAttributes(
            type: .symlink, mode: 0o777, uid: 501, gid: 20,
            symlinkTarget: "/home/alec/Media/clip.mov")
        let built = builder.build(
            path: try RelativePath(string: "Docs/Reports/link"), attributes: attributes,
            parent: parent, existing: nil)
        XCTAssertEqual(
            built.row.linkTarget.map { String(decoding: $0, as: UTF8.self) },
            "../../Media/clip.mov")
    }

    func testALinkThatStopsEscapingBecomesVisibleAgain() throws {
        let escaping = SFTPFileAttributes(
            type: .symlink, mode: 0o777, uid: 501, gid: 20, symlinkTarget: "/etc")
        let hidden = builder.build(
            path: try RelativePath(string: "link"), attributes: escaping, parent: parent,
            existing: nil
        ).row
        XCTAssertEqual(hidden.hidden, RowBuilder.hiddenEscapingLink)

        let inside = SFTPFileAttributes(
            type: .symlink, mode: 0o777, uid: 501, gid: 20, symlinkTarget: "Media")
        let shown = builder.build(
            path: try RelativePath(string: "link"), attributes: inside, parent: parent,
            existing: hidden
        ).row
        XCTAssertEqual(shown.hidden, 0)
    }

    // MARK: The generation, which the conflict check reads

    func testANanosecondOnlyRewriteBumpsTheGeneration() throws {
        let path = try RelativePath(string: "a.txt")
        var first = file()
        first.mtimeNanoseconds = 1
        first.inode = 10
        let before = builder.build(
            path: path, attributes: first, parent: parent, existing: nil).row
        XCTAssertEqual(before.generation, 0)

        var second = first
        second.mtimeNanoseconds = 2
        let after = builder.build(
            path: path, attributes: second, parent: parent, existing: before).row
        XCTAssertEqual(after.generation, 1)
        XCTAssertNotEqual(before.contentVersion, after.contentVersion)
    }

    // MARK: The read-only mapping the write matrix leans on

    func testAWritableFileInAReadOnlyDirectoryLosesAllowsWriting() throws {
        // Section 5.4's most-argued paragraph, and the reason a "write to a read-only
        // item" never gets as far as an upload: replacing content goes through a temp
        // file in the parent directory (section 5.5).
        let readOnlyParent = IndexItem(
            identifier: "p", path: Data("ro".utf8), parent: IndexWriter.rootIdentifier,
            type: "directory", uid: 0, gid: 0, mode: 0o555)
        let attributes = SFTPFileAttributes(
            type: .file, size: 1, mtime: 1, mode: 0o666, uid: 501, gid: 20)
        let row = builder.build(
            path: try RelativePath(string: "ro/locked.txt"), attributes: attributes,
            parent: readOnlyParent, existing: nil
        ).row
        let capabilities = NSFileProviderItemCapabilities(
            rawValue: UInt(truncatingIfNeeded: row.capabilities))
        XCTAssertFalse(capabilities.contains(.allowsWriting))
        XCTAssertFalse(capabilities.contains(.allowsDeleting))
    }
}
