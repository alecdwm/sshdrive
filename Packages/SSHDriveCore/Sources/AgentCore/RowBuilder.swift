import Foundation
import Config
import FileProvider
import Index
import SFTP
import XPCProtocols

/// Builds a finished index row from one `lstat` (DESIGN.md sections 5.2, 5.3, 5.4, 5.7).
///
/// "A row is a finished item": `capabilities`, `fs_flags`, `kept` and `link_target` are
/// derived here, by the agent, and the extension never re-derives them. It lives in the
/// package rather than in `Apps/Agent` so that every rule it applies - the version
/// formula, the generation bump, the symlink check - can be unit-tested against the fake
/// backend without an app bundle.
public struct RowBuilder: Sendable {
    public var permissions: PermissionsMode
    public var identity: ServerIdentity
    /// The two spellings of the location root a symlink target is measured against
    /// (section 5.7).
    public var roots: SymlinkPolicy.Roots

    public init(
        permissions: PermissionsMode, identity: ServerIdentity, roots: SymlinkPolicy.Roots
    ) {
        self.permissions = permissions
        self.identity = identity
        self.roots = roots
    }

    /// `hidden = 1`: a symlink whose target leaves the share. It holds its name on the
    /// server, so a create or rename onto it fails `.filenameCollision` (section 5.7).
    public static let hiddenEscapingLink: Int64 = 1
    /// `hidden = 3`: a local-only item, `.DS_Store` being the only one (section 5.4).
    public static let hiddenLocalOnly: Int64 = 3

    /// The reason string `sshdrive status` prints under "not shown" for a hidden link,
    /// alongside the row itself. Empty when the link is shown.
    public struct Built {
        public var row: IndexItem
        public var hiddenReason: String
    }

    public func build(
        path: RelativePath,
        attributes: SFTPFileAttributes,
        parent: IndexItem,
        existing: IndexItem?,
        hidden: Int64? = nil,
        localAttributes: LocalAttributes? = nil
    ) -> Built {
        // ns-mtime and inode feed change detection only. When either differs from the
        // stored value while size and second-mtime do not, the generation is bumped,
        // which changes the version and makes the system re-fetch (section 5.3).
        var generation = existing?.generation ?? 0
        if let existing,
            existing.size == attributes.size,
            existing.mtime == attributes.mtime
        {
            let nanosecondsMoved =
                existing.mtimeNanoseconds != nil && attributes.mtimeNanoseconds != nil
                && existing.mtimeNanoseconds != attributes.mtimeNanoseconds
            let inodeMoved =
                existing.inode != nil && attributes.inode != nil
                && existing.inode != Int64(bitPattern: attributes.inode ?? 0)
            if nanosecondsMoved || inodeMoved { generation += 1 }
        }

        let contentVersion = IndexItem.contentVersion(
            size: attributes.size, mtime: attributes.mtime, generation: generation)

        // The effective kept state is derived by the agent from the markers at and above
        // the path (sections 5.2, 7.1.1): the nearest explicit state at or above the item
        // decides, so a row with no marker of its own inherits its parent's *effective*
        // state, which the parent row already carries. That one line is what section 7.1
        // means by "descendants the index has never seen need nothing: their rows are
        // created with the right state when they are first listed" - a file appearing
        // remotely inside a kept folder is kept, and one appearing inside an excluded
        // subfolder is not, without any ancestor walk here.
        let pinState = existing?.pinState ?? 0
        let ownMarker = PinPolicy.Marker(rawMarker: pinState)
        let kept = ownMarker.isExplicit ? ownMarker == .pinned : parent.kept

        // Section 5.7: the lexical check runs once per link, here, and its answer is
        // stored on the row so the extension serves the target without repeating it.
        var linkTarget: Data?
        var hiddenReason = ""
        var effectiveHidden = hidden ?? existing?.hidden ?? 0
        if attributes.type == .symlink {
            let target = attributes.symlinkTarget ?? ""
            switch SymlinkPolicy.evaluate(
                target: target, linkDirectory: path.parent ?? .root, roots: roots)
            {
            case let .show(macTarget):
                linkTarget = Data(macTarget.utf8)
                if effectiveHidden == RowBuilder.hiddenEscapingLink { effectiveHidden = 0 }
            case let .hide(reason):
                hiddenReason = reason
                // A collision (2) or a local-only marker (3) already decided the row;
                // only an otherwise-visible link becomes hidden = 1.
                if effectiveHidden == 0 { effectiveHidden = RowBuilder.hiddenEscapingLink }
            }
        }

        let capabilities = ItemDerivation.capabilities(
            type: attributes.type,
            mode: attributes.mode,
            uid: attributes.uid,
            gid: attributes.gid,
            parentMode: UInt32(parent.mode ?? 0o755),
            parentUID: UInt32(parent.uid ?? 0),
            parentGID: UInt32(parent.gid ?? 0),
            permissions: permissions,
            identity: identity,
            kept: kept)

        let filename = String(decoding: path.lastComponent ?? Data(), as: UTF8.self)
        let flags = ItemDerivation.fileSystemFlags(
            type: attributes.type,
            mode: attributes.mode,
            uid: attributes.uid,
            gid: attributes.gid,
            permissions: permissions,
            identity: identity,
            capabilities: capabilities,
            filename: filename)

        // The local blob is the xattrs and the Finder tags together, and its hash is what
        // moves the metadata version (sections 5.3, 5.4).
        let blob = localAttributes.flatMap { $0.encoded() } ?? existing?.xattrs
        let metadataVersion = ItemDerivation.metadataVersion(
            contentVersion: contentVersion,
            mode: Int64(attributes.mode),
            uid: Int64(attributes.uid),
            gid: Int64(attributes.gid),
            capabilities: Int64(capabilities.rawValue),
            fileSystemFlags: Int64(flags.rawValue),
            kept: kept,
            xattrs: blob)

        let row = IndexItem(
            identifier: existing?.identifier ?? UUID().uuidString,
            path: path.bytes,
            parent: parent.identifier,
            type: attributes.type.rawValue,
            size: attributes.size,
            mtime: attributes.mtime,
            mtimeNanoseconds: attributes.mtimeNanoseconds,
            inode: attributes.inode.map { Int64(bitPattern: $0) },
            uid: Int64(attributes.uid),
            gid: Int64(attributes.gid),
            mode: Int64(attributes.mode),
            generation: generation,
            contentVersion: contentVersion,
            metadataVersion: metadataVersion,
            lastFetch: existing?.lastFetch,
            pinState: pinState,
            kept: kept,
            capabilities: Int64(capabilities.rawValue),
            fileSystemFlags: Int64(flags.rawValue),
            linkTarget: linkTarget,
            hidden: effectiveHidden,
            xattrs: blob,
            localContent: existing?.localContent)
        return Built(row: row, hiddenReason: hiddenReason)
    }

    /// Recomputes the metadata version of a row whose local blob or derived fields moved
    /// without a fresh `lstat` - a tag change, a pin change (section 5.3).
    public static func restamp(_ row: inout IndexItem) {
        row.metadataVersion = ItemDerivation.metadataVersion(
            contentVersion: row.contentVersion,
            mode: row.mode, uid: row.uid, gid: row.gid,
            capabilities: row.capabilities, fileSystemFlags: row.fileSystemFlags,
            kept: row.kept, xattrs: row.xattrs)
    }
}
