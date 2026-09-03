import Foundation
import FileProvider
import Index
import Config
import SFTP
import XPCProtocols

/// The account the probe found on the server (`id -u`, `id -G`), or nothing when exec is
/// not available. SFTP-only accounts, where the identity is unknown, get full
/// capabilities and learn about permission errors from the sync error list
/// (DESIGN.md section 5.4).
struct ServerIdentity {
    var uid: UInt32?
    var gid: UInt32?
    var supplementaryGroups: Set<UInt32>

    static let unknown = ServerIdentity(uid: nil, gid: nil, supplementaryGroups: [])

    var isKnown: Bool { uid != nil }

    func canRead(mode: UInt32, uid: UInt32, gid: UInt32) -> Bool {
        permits(bit: 0o4, mode: mode, uid: uid, gid: gid)
    }

    func canWrite(mode: UInt32, uid: UInt32, gid: UInt32) -> Bool {
        permits(bit: 0o2, mode: mode, uid: uid, gid: gid)
    }

    func canExecute(mode: UInt32, uid: UInt32, gid: UInt32) -> Bool {
        permits(bit: 0o1, mode: mode, uid: uid, gid: gid)
    }

    private func permits(bit: UInt32, mode: UInt32, uid fileUID: UInt32, gid fileGID: UInt32) -> Bool {
        guard let uid else {
            // Unknown identity: any bit at all counts (section 5.4).
            return (mode & (bit | (bit << 3) | (bit << 6))) != 0
        }
        if uid == 0 { return true }
        if fileUID == uid { return (mode & (bit << 6)) != 0 }
        if fileGID == gid || supplementaryGroups.contains(fileGID) {
            return (mode & (bit << 3)) != 0
        }
        return (mode & bit) != 0
    }
}

/// Turns an lstat plus the location's `permissions` setting into the two bitmasks the
/// index stores on the row, so that `item(for:)` in the extension is a row read and a
/// field-by-field copy with no second copy of these rules (DESIGN.md sections 5.2, 5.4).
enum ItemDerivation {

    /// `capabilities`, from the item's own mode and its parent's write bit. A file loses
    /// allowsWriting when the account cannot write it or cannot write its directory,
    /// because replacing content goes through a temp file in that directory (section 5.5).
    static func capabilities(
        type: SFTPFileType,
        mode: UInt32,
        uid: UInt32,
        gid: UInt32,
        parentMode: UInt32,
        parentUID: UInt32,
        parentGID: UInt32,
        permissions: PermissionsMode,
        identity: ServerIdentity,
        kept: Bool
    ) -> NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]

        let writable: Bool
        let parentWritable: Bool
        switch permissions {
        case .none:
            // Everything writable, errors after upload, as for SFTP-only accounts.
            writable = true
            parentWritable = true
        case .mode:
            writable = identity.canWrite(mode: mode, uid: uid, gid: gid)
            parentWritable = identity.canWrite(mode: parentMode, uid: parentUID, gid: parentGID)
        }

        // A writable file in a read-only directory is shown locked rather than failing at
        // save time.
        if writable && parentWritable { capabilities.insert(.allowsWriting) }

        // Renaming and deleting follow the parent's write bit, and when the parent
        // carries the sticky bit they additionally require the item or the parent to be
        // owned by the account, which is what the kernel requires.
        let stickyParent = (parentMode & 0o1000) != 0
        let ownsSomething: Bool = {
            guard let accountUID = identity.uid else { return true }
            return uid == accountUID || parentUID == accountUID
        }()
        if parentWritable && (!stickyParent || ownsSomething || permissions == .none) {
            capabilities.insert(.allowsRenaming)
            capabilities.insert(.allowsDeleting)
            capabilities.insert(.allowsReparenting)
        }

        if type == .directory {
            capabilities.insert(.allowsContentEnumerating)
            if writable { capabilities.insert(.allowsAddingSubItems) }
        }

        // allowsTrashing is never set: no trash (section 5.4).

        // Kept items drop allowsEvicting, so Finder's own menu cannot undo the pin
        // (section 7.2). Everything else may be evicted.
        if !kept { capabilities.insert(.allowsEvicting) }

        return capabilities
    }

    /// `fileSystemFlags`. userReadable is always set; userWritable follows allowsWriting;
    /// userExecutable is set when the mode has an execute bit the account can exercise,
    /// and a directory always carries it, since there it is the search bit (section 5.4).
    static func fileSystemFlags(
        type: SFTPFileType,
        mode: UInt32,
        uid: UInt32,
        gid: UInt32,
        permissions: PermissionsMode,
        identity: ServerIdentity,
        capabilities: NSFileProviderItemCapabilities,
        filename: String
    ) -> NSFileProviderFileSystemFlags {
        var flags: NSFileProviderFileSystemFlags = [.userReadable]
        if capabilities.contains(.allowsWriting) { flags.insert(.userWritable) }
        if type == .directory {
            flags.insert(.userExecutable)
        } else if permissions == .none {
            flags.insert(.userExecutable)
        } else if identity.canExecute(mode: mode, uid: uid, gid: gid) {
            flags.insert(.userExecutable)
        }
        if filename.hasPrefix(".") { flags.insert(.hidden) }
        return flags
    }

    /// Metadata version = content version plus mode, uid, gid, the derived bitmasks, the
    /// effective kept state and a hash of the stored xattrs blob (section 5.3).
    static func metadataVersion(
        contentVersion: String,
        mode: Int64?,
        uid: Int64?,
        gid: Int64?,
        capabilities: Int64,
        fileSystemFlags: Int64,
        kept: Bool,
        xattrs: Data?
    ) -> String {
        // A stable hash, not Hasher: Swift's is seeded per process, and a metadata
        // version that moved at every agent restart would make the system re-read every
        // item it holds.
        let xattrHash = ItemDerivation.fnv1a(xattrs ?? Data())
        return [
            contentVersion,
            String(mode ?? -1), String(uid ?? -1), String(gid ?? -1),
            String(capabilities), String(fileSystemFlags),
            kept ? "1" : "0",
            String(xattrHash, radix: 16),
        ].joined(separator: ":")
    }

    /// FNV-1a, 64 bit. Small, stable across processes and builds, and no dependency.
    static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
