import Foundation
import XPCProtocols

/// An item as the system should see it, built by a field-by-field copy from a finished row
/// or from the snapshot the agent sent (DESIGN.md section 5.2).
///
/// "A row is a finished item": no ancestor walk, no access to `capabilities.json`, no
/// second copy of the rules in sections 5.4, 5.7 or 7. Everything the old
/// `Apps/FileProvider/Item.swift` computed is computed here, off Darwin, and the adapter
/// that wears `NSFileProviderItem` reads these properties and nothing else.
public struct ItemView: Equatable, Sendable {
    public var identifier: ProviderItemIdentifier
    public var parentIdentifier: ProviderItemIdentifier
    public var filename: String
    public var contentTypeHint: ProviderContentTypeHint
    public var capabilities: ProviderCapabilities
    public var fileSystemFlags: ProviderFileSystemFlags
    /// nil for a directory: a folder has no document size.
    public var documentSize: Int64?
    /// Whole-second mtime, as SFTP v3 reports it, as seconds since the epoch.
    public var contentModificationDate: Double
    public var contentVersion: String
    public var metadataVersion: String
    /// The Mac-side symlink target after section 5.7's relative rewrite; nil otherwise.
    public var symlinkTargetPath: String?
    public var extendedAttributes: [String: Data]
    /// Finder tags. They are never an xattr: the system excludes
    /// `com.apple.metadata:_kMDItemUserTags` from `extendedAttributes` deliberately
    /// (`MQ-044`) and rebuilds that xattr from this on every update, so an item that
    /// returns nothing here loses the user's tags on the next re-download (`MQ-043`).
    public var tagData: Data?
    /// Section 7.1.1's effective policy. The eager one, not `allowsEvicting`, is what
    /// refuses an eviction (`MQ-024`).
    public var contentPolicy: ProviderContentPolicy
    /// Effective kept state, which is what the Finder action's activation rule tests
    /// through `userInfo.kept` (section 7.2, `MQ-055`).
    public var kept: Bool

    public init(
        identifier: ProviderItemIdentifier,
        parentIdentifier: ProviderItemIdentifier,
        filename: String,
        contentTypeHint: ProviderContentTypeHint,
        capabilities: ProviderCapabilities,
        fileSystemFlags: ProviderFileSystemFlags,
        documentSize: Int64?,
        contentModificationDate: Double,
        contentVersion: String,
        metadataVersion: String,
        symlinkTargetPath: String? = nil,
        extendedAttributes: [String: Data] = [:],
        tagData: Data? = nil,
        contentPolicy: ProviderContentPolicy = .unset,
        kept: Bool = false
    ) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.contentTypeHint = contentTypeHint
        self.capabilities = capabilities
        self.fileSystemFlags = fileSystemFlags
        self.documentSize = documentSize
        self.contentModificationDate = contentModificationDate
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.symlinkTargetPath = symlinkTargetPath
        self.extendedAttributes = extendedAttributes
        self.tagData = tagData
        self.contentPolicy = contentPolicy
        self.kept = kept
    }

    /// The decoration a kept item carries (section 7.2's pin badge). It follows the
    /// *kept* state, not the marker: an excluded folder inside a kept one shows no badge
    /// and its kept parent still does (section 7.1.1). The identifier is declared under
    /// `NSFileProviderDecorations` in the appex's Info.plist and an item that returns one
    /// that is not declared there gets no badge and no error (`MQ-056`), which is why the
    /// spelling comes from `SSHDriveIdentifiers` and not from a literal.
    public var decorations: [String] {
        kept ? [SSHDriveIdentifiers.keptDecorationID] : []
    }

    /// What the Finder action's activation rule binds to (section 7.2).
    public var userInfoKept: Bool { kept }

    /// The one conversion between the wire value and the system's view. Both the
    /// extension's direct index reader and the XPC fallback produce an item this way, so
    /// the two paths cannot drift (section 5.2).
    ///
    /// The root's filename is the domain's display name; every other item's is its own,
    /// because the row for the location root carries an empty name.
    public init(snapshot: SSHDriveItemSnapshot, rootDisplayName: String) {
        let name = snapshot.filename.isEmpty ? rootDisplayName : snapshot.filename
        let hint: ProviderContentTypeHint
        if snapshot.isDirectory {
            hint = .folder
        } else if snapshot.isSymlink {
            hint = .symbolicLink
        } else {
            let ext = (name as NSString).pathExtension
            hint = ext.isEmpty ? .data : .filenameExtension(ext)
        }
        self.init(
            identifier: ProviderItemIdentifier(
                snapshot.identifier == ProviderItemIdentifier.rootContainer.rawValue
                    ? ProviderItemIdentifier.rootContainer.rawValue : snapshot.identifier),
            parentIdentifier: ProviderItemIdentifier(snapshot.parentIdentifier),
            filename: name,
            contentTypeHint: hint,
            capabilities: ProviderCapabilities(
                rawValue: UInt(truncatingIfNeeded: snapshot.capabilities)),
            fileSystemFlags: ProviderFileSystemFlags(
                rawValue: UInt(truncatingIfNeeded: snapshot.fileSystemFlags)),
            documentSize: snapshot.isDirectory ? nil : snapshot.size,
            contentModificationDate: Double(snapshot.mtime),
            contentVersion: snapshot.contentVersion,
            metadataVersion: snapshot.metadataVersion,
            symlinkTargetPath: snapshot.linkTarget,
            extendedAttributes: snapshot.extendedAttributes,
            tagData: snapshot.tagData,
            contentPolicy: ProviderContentPolicy(rawValue: snapshot.contentPolicyRawValue)
                ?? .inherited,
            kept: snapshot.kept)
    }
}

/// What a `createItem` is asked to make, with the Apple item template already read
/// (section 5.5).
public struct ItemTemplate: Equatable, Sendable {
    public var parentIdentifier: ProviderItemIdentifier
    public var filename: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var symlinkTarget: String?
    /// The mode the temp file is opened with: 0644 for an ordinary file, 0755 when the
    /// local one is executable, as `sftp put` does (section 5.5).
    public var fileSystemFlags: UInt64?
    /// Set back onto the file after the rename, truncated to whole seconds since SFTP v3
    /// carries no more.
    public var modificationDate: Double?
    public var extendedAttributes: [String: Data]?
    public var tagData: Data?

    public init(
        parentIdentifier: ProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        isSymlink: Bool,
        symlinkTarget: String? = nil,
        fileSystemFlags: UInt64? = nil,
        modificationDate: Double? = nil,
        extendedAttributes: [String: Data]? = nil,
        tagData: Data? = nil
    ) {
        self.parentIdentifier = parentIdentifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.fileSystemFlags = fileSystemFlags
        self.modificationDate = modificationDate
        self.extendedAttributes = extendedAttributes
        self.tagData = tagData
    }
}

/// What a `modifyItem` carries beyond its `changedFields` (section 5.5).
public struct ItemChanges: Equatable, Sendable {
    public var newParentIdentifier: ProviderItemIdentifier?
    public var newFilename: String?
    public var newFileSystemFlags: UInt64?
    public var newModificationDate: Double?
    public var newExtendedAttributes: [String: Data]?
    public var newTagData: Data?
    public var newSymlinkTarget: String?

    public init(
        newParentIdentifier: ProviderItemIdentifier? = nil,
        newFilename: String? = nil,
        newFileSystemFlags: UInt64? = nil,
        newModificationDate: Double? = nil,
        newExtendedAttributes: [String: Data]? = nil,
        newTagData: Data? = nil,
        newSymlinkTarget: String? = nil
    ) {
        self.newParentIdentifier = newParentIdentifier
        self.newFilename = newFilename
        self.newFileSystemFlags = newFileSystemFlags
        self.newModificationDate = newModificationDate
        self.newExtendedAttributes = newExtendedAttributes
        self.newTagData = newTagData
        self.newSymlinkTarget = newSymlinkTarget
    }
}
