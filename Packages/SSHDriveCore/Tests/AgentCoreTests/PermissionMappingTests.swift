import XCTest
import FileProvider
import Config
import SFTP
@testable import AgentCore

/// DESIGN.md section 5.4's "permissions become capabilities" and "execute bits become
/// `fileSystemFlags`", against a fixed identity.
final class PermissionMappingTests: XCTestCase {

    /// uid 1000, gid 1000, also in group 27. The testbed's `alec` account, roughly.
    private let account = ServerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [27])
    private let writableDirectory: (mode: UInt32, uid: UInt32, gid: UInt32) = (0o755, 1000, 1000)
    private let foreignDirectory: (mode: UInt32, uid: UInt32, gid: UInt32) = (0o755, 0, 0)

    private func capabilities(
        type: SFTPFileType = .file, mode: UInt32, uid: UInt32 = 1000, gid: UInt32 = 1000,
        parent: (mode: UInt32, uid: UInt32, gid: UInt32)? = nil,
        permissions: PermissionsMode = .mode,
        identity: ServerIdentity? = nil,
        kept: Bool = false
    ) -> NSFileProviderItemCapabilities {
        let parent = parent ?? writableDirectory
        return ItemDerivation.capabilities(
            type: type, mode: mode, uid: uid, gid: gid,
            parentMode: parent.mode, parentUID: parent.uid, parentGID: parent.gid,
            permissions: permissions, identity: identity ?? account, kept: kept)
    }

    func testOwnedWritableFileIsWritable() {
        let capabilities = capabilities(mode: 0o644)
        XCTAssertTrue(capabilities.contains(.allowsReading))
        XCTAssertTrue(capabilities.contains(.allowsWriting))
        XCTAssertTrue(capabilities.contains(.allowsRenaming))
        XCTAssertTrue(capabilities.contains(.allowsDeleting))
        // No trash, ever (section 5.4).
        XCTAssertFalse(capabilities.contains(.allowsTrashing))
    }

    func testGroupWriteCountsWhenTheAccountIsInThatGroup() {
        // Owned by root, group 27, group-writable: the account is in 27, so it may write.
        XCTAssertTrue(capabilities(mode: 0o664, uid: 0, gid: 27).contains(.allowsWriting))
        // Same file in a group the account is not in.
        XCTAssertFalse(capabilities(mode: 0o664, uid: 0, gid: 99).contains(.allowsWriting))
    }

    /// "A file loses `allowsWriting` when the account cannot write it **or cannot write
    /// its directory**, because replacing content goes through a temp file in that
    /// directory ... so a writable file in a read-only directory is shown locked rather
    /// than failing at save time."
    func testWritableFileInAReadOnlyDirectoryIsLocked() {
        let capabilities = capabilities(mode: 0o666, uid: 0, gid: 0, parent: foreignDirectory)
        XCTAssertFalse(capabilities.contains(.allowsWriting))
        XCTAssertFalse(capabilities.contains(.allowsRenaming))
        XCTAssertFalse(capabilities.contains(.allowsDeleting))
        XCTAssertTrue(capabilities.contains(.allowsReading))
    }

    /// "`allowsRenaming` and `allowsDeleting` follow the parent's write bit".
    func testRenameAndDeleteFollowTheParent() {
        // A file the account cannot write, in a directory it can: still renamable.
        let capabilities = capabilities(mode: 0o444, uid: 0, gid: 0)
        XCTAssertFalse(capabilities.contains(.allowsWriting))
        XCTAssertTrue(capabilities.contains(.allowsRenaming))
        XCTAssertTrue(capabilities.contains(.allowsDeleting))
    }

    /// "when the parent carries the sticky bit (a `1777` drop directory) they
    /// additionally require the item or the parent to be owned by the account".
    func testStickyParentRequiresOwnership() {
        let sticky: (mode: UInt32, uid: UInt32, gid: UInt32) = (0o1777, 0, 0)
        let mine = capabilities(mode: 0o644, uid: 1000, gid: 1000, parent: sticky)
        XCTAssertTrue(mine.contains(.allowsDeleting))
        let theirs = capabilities(mode: 0o644, uid: 0, gid: 0, parent: sticky)
        XCTAssertFalse(theirs.contains(.allowsDeleting))
        XCTAssertFalse(theirs.contains(.allowsRenaming))
        // Without the sticky bit the same 0777 directory lets anyone delete anything.
        let loose = capabilities(mode: 0o644, uid: 0, gid: 0, parent: (0o777, 0, 0))
        XCTAssertTrue(loose.contains(.allowsDeleting))
    }

    /// "a directory the account cannot write loses `allowsAddingSubItems`".
    func testDirectoryAddingSubItemsFollowsItsOwnWriteBit() {
        XCTAssertTrue(
            capabilities(type: .directory, mode: 0o755).contains(.allowsAddingSubItems))
        XCTAssertFalse(
            capabilities(type: .directory, mode: 0o555, uid: 0, gid: 0)
                .contains(.allowsAddingSubItems))
        XCTAssertTrue(
            capabilities(type: .directory, mode: 0o555, uid: 0, gid: 0)
                .contains(.allowsContentEnumerating))
    }

    /// "SFTP-only accounts, where the identity is unknown, get full capabilities and learn
    /// about permission errors from the sync error list."
    func testUnknownIdentityGetsFullCapabilities() {
        let capabilities = capabilities(
            mode: 0o400, uid: 0, gid: 0, parent: foreignDirectory, identity: .unknown)
        XCTAssertFalse(
            capabilities.contains(.allowsWriting),
            "0400 root has no write bit at all, so even an unknown identity cannot claim one")
        let anyWrite = self.capabilities(
            mode: 0o642, uid: 0, gid: 0, parent: (0o757, 0, 0), identity: .unknown)
        XCTAssertTrue(anyWrite.contains(.allowsWriting), "any write bit counts when the identity is unknown")
    }

    /// The `permissions: none` setting: "everything writable, errors after upload", which
    /// is what a NAS with ACLs needs.
    func testPermissionsNoneMakesEverythingWritable() {
        let capabilities = capabilities(
            mode: 0o444, uid: 0, gid: 0, parent: foreignDirectory, permissions: .none)
        XCTAssertTrue(capabilities.contains(.allowsWriting))
        XCTAssertTrue(capabilities.contains(.allowsRenaming))
        XCTAssertTrue(capabilities.contains(.allowsDeleting))
    }

    /// A kept item drops `allowsEvicting` so Finder's own menu cannot undo the pin
    /// (section 7.2).
    func testKeptItemsDropAllowsEvicting() {
        XCTAssertTrue(capabilities(mode: 0o644, kept: false).contains(.allowsEvicting))
        XCTAssertFalse(capabilities(mode: 0o644, kept: true).contains(.allowsEvicting))
    }

    // MARK: fileSystemFlags

    private func flags(
        type: SFTPFileType = .file, mode: UInt32, uid: UInt32 = 1000, gid: UInt32 = 1000,
        permissions: PermissionsMode = .mode, identity: ServerIdentity? = nil,
        filename: String = "script.sh"
    ) -> NSFileProviderFileSystemFlags {
        let identity = identity ?? account
        let capabilities = ItemDerivation.capabilities(
            type: type, mode: mode, uid: uid, gid: gid,
            parentMode: writableDirectory.mode, parentUID: writableDirectory.uid,
            parentGID: writableDirectory.gid,
            permissions: permissions, identity: identity, kept: false)
        return ItemDerivation.fileSystemFlags(
            type: type, mode: mode, uid: uid, gid: gid, permissions: permissions,
            identity: identity, capabilities: capabilities, filename: filename)
    }

    /// "`.userExecutable` is set when the mode has an execute bit the account can
    /// exercise (the owner's bit when the file is the account's, the group's when the
    /// account is in the group, otherwise the world bit)". Without it, a script fetched
    /// from the server arrives non-executable.
    func testExecutableBitFollowsTheAccountsOwnClass() {
        XCTAssertTrue(flags(mode: 0o755).contains(.userExecutable))
        XCTAssertFalse(flags(mode: 0o644).contains(.userExecutable))
        // Owner-executable only, but owned by root: the account reads the world bits.
        XCTAssertFalse(flags(mode: 0o744, uid: 0, gid: 0).contains(.userExecutable))
        // Group-executable, in the group.
        XCTAssertTrue(flags(mode: 0o754, uid: 0, gid: 27).contains(.userExecutable))
        // "any execute bit at all where the identity is unknown".
        XCTAssertTrue(flags(mode: 0o744, uid: 0, gid: 0, identity: .unknown).contains(.userExecutable))
    }

    /// "a directory always carries it, since there it is the search bit"; ".userReadable
    /// is always set, and .userWritable follows allowsWriting".
    func testDirectoriesAreAlwaysExecutableAndReadableIsAlwaysSet() {
        let directory = flags(type: .directory, mode: 0o400, uid: 0, gid: 0, filename: "d")
        XCTAssertTrue(directory.contains(.userExecutable))
        XCTAssertTrue(directory.contains(.userReadable))
        XCTAssertFalse(directory.contains(.userWritable))
        XCTAssertTrue(flags(mode: 0o644).contains(.userWritable))
    }

    /// Dot-files carry the hidden flag, which is how Finder treats them locally without
    /// the name being changed on the server.
    func testDotFilesAreHidden() {
        XCTAssertTrue(flags(mode: 0o644, filename: ".bashrc").contains(.hidden))
        XCTAssertFalse(flags(mode: 0o644, filename: "bashrc").contains(.hidden))
    }

    // MARK: the metadata version

    /// Section 5.3: the metadata version moves when the derived bitmasks, the owner, the
    /// kept state or the xattrs move, and is stable across processes.
    func testMetadataVersionMovesOnEveryInput() {
        func version(
            content: String = "10-20-0", mode: Int64 = 0o644, uid: Int64 = 1000,
            gid: Int64 = 1000, capabilities: Int64 = 1, flags: Int64 = 1, kept: Bool = false,
            xattrs: Data? = nil
        ) -> String {
            ItemDerivation.metadataVersion(
                contentVersion: content, mode: mode, uid: uid, gid: gid,
                capabilities: capabilities, fileSystemFlags: flags, kept: kept, xattrs: xattrs)
        }
        let base = version()
        XCTAssertEqual(base, version(), "the same inputs must give the same version")
        XCTAssertNotEqual(base, version(content: "11-20-0"))
        XCTAssertNotEqual(base, version(mode: 0o755))
        XCTAssertNotEqual(base, version(uid: 0))
        XCTAssertNotEqual(base, version(capabilities: 2))
        XCTAssertNotEqual(base, version(flags: 2))
        XCTAssertNotEqual(base, version(kept: true))
        XCTAssertNotEqual(base, version(xattrs: Data("tag".utf8)))
    }

    /// FNV-1a rather than `Hasher`: Swift's is seeded per process, and a metadata version
    /// that moved at every agent restart would re-read every item the system holds.
    func testHashIsStableAcrossProcesses() {
        XCTAssertEqual(ItemDerivation.fnv1a(Data()), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(ItemDerivation.fnv1a(Data("a".utf8)), 0xaf63_dc4c_8601_ec8c)
    }
}
