import Foundation

/// A finished item, as it crosses XPC and as it is stored on an index row.
///
/// "A row is a finished item" (DESIGN.md section 5.2): everything derived rather than
/// observed is computed by the agent when it writes the row, so both the extension's
/// direct index reader and the XPC fallback path produce an NSFileProviderItem by a
/// field-by-field copy with no ancestor walk and no second copy of the rules in
/// sections 5.4, 5.7 and 7.
public final class SSHDriveItemSnapshot: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    /// Item identifier. The root container carries
    /// `NSFileProviderItemIdentifier.rootContainer.rawValue`.
    public let identifier: String
    public let parentIdentifier: String
    /// The name as the system sees it. Server names are bytes and need not be UTF-8
    /// (section 5.4); a name that is not valid UTF-8 is hidden and never reaches here.
    public let filename: String
    /// Path relative to the location root, as raw server bytes.
    public let pathBytes: Data

    public let isDirectory: Bool
    public let isSymlink: Bool
    /// Mac-side symlink target after the relative rewrite (section 5.7); nil otherwise.
    public let linkTarget: String?

    public let size: Int64
    /// Whole-second mtime, as SFTP v3 reports it.
    public let mtime: Int64
    public let mode: Int32
    public let uid: Int32
    public let gid: Int32

    /// "size-mtime-generation" (section 5.3).
    public let contentVersion: String
    /// Content version plus mode, owner, the derived bitmasks, the effective kept state
    /// and a hash of the xattrs blob (section 5.3).
    public let metadataVersion: String

    /// NSFileProviderItemCapabilities bitmask, derived by the agent (section 5.4).
    public let capabilities: UInt64
    /// NSFileProviderFileSystemFlags bitmask, derived by the agent (section 5.4).
    public let fileSystemFlags: UInt64

    /// Effective kept state (section 7.1.1), not the marker.
    public let kept: Bool
    /// Which content policy the extension should set on the item (section 7.1.1).
    /// Carried as an integer of our own rather than NSFileProviderContentPolicy's raw
    /// value, because this module is linked by the CLI and askpass, which do not link
    /// FileProvider at all.
    public let contentPolicyRawValue: Int

    /// Extended attributes, stored locally only (section 5.4).
    public let extendedAttributes: [String: Data]

    /// Finder tags, stored locally only (section 5.4). They never arrive as an xattr:
    /// they are the item's own `tagData`, and the system rebuilds the tags xattr from it
    /// on every update, so an item that returns none loses the user's tags on the next
    /// re-download (S4, 2026-09-04).
    public let tagData: Data?

    public init(
        identifier: String,
        parentIdentifier: String,
        filename: String,
        pathBytes: Data,
        isDirectory: Bool,
        isSymlink: Bool,
        linkTarget: String?,
        size: Int64,
        mtime: Int64,
        mode: Int32,
        uid: Int32,
        gid: Int32,
        contentVersion: String,
        metadataVersion: String,
        capabilities: UInt64,
        fileSystemFlags: UInt64,
        kept: Bool,
        contentPolicyRawValue: Int,
        extendedAttributes: [String: Data],
        tagData: Data? = nil
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.pathBytes = pathBytes
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.capabilities = capabilities
        self.fileSystemFlags = fileSystemFlags
        self.kept = kept
        self.contentPolicyRawValue = contentPolicyRawValue
        self.extendedAttributes = extendedAttributes
        self.tagData = tagData
    }

    private enum Key {
        static let identifier = "identifier"
        static let parentIdentifier = "parentIdentifier"
        static let filename = "filename"
        static let pathBytes = "pathBytes"
        static let isDirectory = "isDirectory"
        static let isSymlink = "isSymlink"
        static let linkTarget = "linkTarget"
        static let size = "size"
        static let mtime = "mtime"
        static let mode = "mode"
        static let uid = "uid"
        static let gid = "gid"
        static let contentVersion = "contentVersion"
        static let metadataVersion = "metadataVersion"
        static let capabilities = "capabilities"
        static let fileSystemFlags = "fileSystemFlags"
        static let kept = "kept"
        static let contentPolicy = "contentPolicy"
        static let xattrs = "xattrs"
        static let tagData = "tagData"
    }

    public func encode(with coder: NSCoder) {
        coder.encode(identifier as NSString, forKey: Key.identifier)
        coder.encode(parentIdentifier as NSString, forKey: Key.parentIdentifier)
        coder.encode(filename as NSString, forKey: Key.filename)
        coder.encode(pathBytes as NSData, forKey: Key.pathBytes)
        coder.encode(isDirectory, forKey: Key.isDirectory)
        coder.encode(isSymlink, forKey: Key.isSymlink)
        coder.encode(linkTarget as NSString?, forKey: Key.linkTarget)
        coder.encode(size, forKey: Key.size)
        coder.encode(mtime, forKey: Key.mtime)
        coder.encode(Int(mode), forKey: Key.mode)
        coder.encode(Int(uid), forKey: Key.uid)
        coder.encode(Int(gid), forKey: Key.gid)
        coder.encode(contentVersion as NSString, forKey: Key.contentVersion)
        coder.encode(metadataVersion as NSString, forKey: Key.metadataVersion)
        coder.encode(NSNumber(value: capabilities), forKey: Key.capabilities)
        coder.encode(NSNumber(value: fileSystemFlags), forKey: Key.fileSystemFlags)
        coder.encode(kept, forKey: Key.kept)
        coder.encode(contentPolicyRawValue, forKey: Key.contentPolicy)
        coder.encode(extendedAttributes as NSDictionary, forKey: Key.xattrs)
        coder.encode(tagData as NSData?, forKey: Key.tagData)
    }

    public init?(coder: NSCoder) {
        guard
            let identifier = coder.decodeObject(of: NSString.self, forKey: Key.identifier),
            let parent = coder.decodeObject(of: NSString.self, forKey: Key.parentIdentifier),
            let filename = coder.decodeObject(of: NSString.self, forKey: Key.filename),
            let path = coder.decodeObject(of: NSData.self, forKey: Key.pathBytes),
            let contentVersion = coder.decodeObject(of: NSString.self, forKey: Key.contentVersion),
            let metadataVersion = coder.decodeObject(of: NSString.self, forKey: Key.metadataVersion)
        else { return nil }

        self.identifier = identifier as String
        self.parentIdentifier = parent as String
        self.filename = filename as String
        self.pathBytes = path as Data
        self.isDirectory = coder.decodeBool(forKey: Key.isDirectory)
        self.isSymlink = coder.decodeBool(forKey: Key.isSymlink)
        self.linkTarget = coder.decodeObject(of: NSString.self, forKey: Key.linkTarget) as String?
        self.size = coder.decodeInt64(forKey: Key.size)
        self.mtime = coder.decodeInt64(forKey: Key.mtime)
        self.mode = Int32(coder.decodeInteger(forKey: Key.mode))
        self.uid = Int32(coder.decodeInteger(forKey: Key.uid))
        self.gid = Int32(coder.decodeInteger(forKey: Key.gid))
        self.contentVersion = contentVersion as String
        self.metadataVersion = metadataVersion as String
        self.capabilities =
            coder.decodeObject(of: NSNumber.self, forKey: Key.capabilities)?.uint64Value ?? 0
        self.fileSystemFlags =
            coder.decodeObject(of: NSNumber.self, forKey: Key.fileSystemFlags)?.uint64Value ?? 0
        self.kept = coder.decodeBool(forKey: Key.kept)
        self.contentPolicyRawValue = coder.decodeInteger(forKey: Key.contentPolicy)
        let classes: [AnyClass] = [NSDictionary.self, NSString.self, NSData.self]
        self.extendedAttributes =
            (coder.decodeObject(of: classes, forKey: Key.xattrs) as? [String: Data]) ?? [:]
        self.tagData = coder.decodeObject(of: NSData.self, forKey: Key.tagData) as Data?
    }

    public override var description: String {
        "SSHDriveItemSnapshot(\(identifier) \(filename) v\(contentVersion))"
    }
}

/// The content policy an item asks for (DESIGN.md section 7.1.1). The extension maps
/// these to NSFileProviderContentPolicy; nothing else in the project names that type.
public enum SSHDriveContentPolicy: Int, Sendable {
    /// Do not set a policy at all; the system's default applies.
    case unset = -1
    case inherited = 0
    case downloadLazily = 1
    case downloadEagerlyAndKeepDownloaded = 2
}

/// One page of an enumeration. `nextPageToken` is nil on the last page (section 5.2:
/// directory listings travel as XPC values, paged for large directories).
public final class SSHDriveItemPage: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    public let items: [SSHDriveItemSnapshot]
    /// Identifiers of items reported deleted. Empty for a plain listing.
    public let deletedIdentifiers: [String]
    public let nextPageToken: String?
    /// The sync anchor to hand the system after this page, when the enumeration is a
    /// change stream. Empty otherwise.
    public let anchor: String

    public init(
        items: [SSHDriveItemSnapshot],
        deletedIdentifiers: [String] = [],
        nextPageToken: String? = nil,
        anchor: String = ""
    ) {
        self.items = items
        self.deletedIdentifiers = deletedIdentifiers
        self.nextPageToken = nextPageToken
        self.anchor = anchor
    }

    public func encode(with coder: NSCoder) {
        coder.encode(items as NSArray, forKey: "items")
        coder.encode(deletedIdentifiers as NSArray, forKey: "deleted")
        coder.encode(nextPageToken as NSString?, forKey: "next")
        coder.encode(anchor as NSString, forKey: "anchor")
    }

    public init?(coder: NSCoder) {
        let itemClasses: [AnyClass] = [NSArray.self, SSHDriveItemSnapshot.self]
        let stringClasses: [AnyClass] = [NSArray.self, NSString.self]
        self.items = (coder.decodeObject(of: itemClasses, forKey: "items") as? [SSHDriveItemSnapshot]) ?? []
        self.deletedIdentifiers =
            (coder.decodeObject(of: stringClasses, forKey: "deleted") as? [String]) ?? []
        self.nextPageToken = coder.decodeObject(of: NSString.self, forKey: "next") as String?
        self.anchor = (coder.decodeObject(of: NSString.self, forKey: "anchor") as String?) ?? ""
    }
}
