import FileProvider
import Foundation
import UniformTypeIdentifiers
import XPCProtocols

/// An NSFileProviderItem built by a field-by-field copy from a finished row or from the
/// snapshot the agent sent (DESIGN.md section 5.2). No ancestor walk, no access to
/// capabilities.json, no second copy of the rules in sections 5.4, 5.7 or 7.
final class Item: NSObject, NSFileProviderItem {
    private let snapshot: SSHDriveItemSnapshot
    /// The root's filename is the domain's display name; every other item's is its own.
    private let rootDisplayName: String

    init(snapshot: SSHDriveItemSnapshot, rootDisplayName: String) {
        self.snapshot = snapshot
        self.rootDisplayName = rootDisplayName
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        snapshot.identifier == SSHDriveItemIdentifiers.root
            ? .rootContainer : NSFileProviderItemIdentifier(snapshot.identifier)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        snapshot.parentIdentifier == SSHDriveItemIdentifiers.root
            ? .rootContainer : NSFileProviderItemIdentifier(snapshot.parentIdentifier)
    }

    var filename: String {
        snapshot.filename.isEmpty ? rootDisplayName : snapshot.filename
    }

    var contentType: UTType {
        if snapshot.isDirectory { return .folder }
        if snapshot.isSymlink { return .symbolicLink }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type }
        return .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        NSFileProviderItemCapabilities(rawValue: UInt(truncatingIfNeeded: snapshot.capabilities))
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        NSFileProviderFileSystemFlags(rawValue: UInt(truncatingIfNeeded: snapshot.fileSystemFlags))
    }

    var documentSize: NSNumber? {
        snapshot.isDirectory ? nil : NSNumber(value: snapshot.size)
    }

    var contentModificationDate: Date? {
        Date(timeIntervalSince1970: TimeInterval(snapshot.mtime))
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(snapshot.contentVersion.utf8),
            metadataVersion: Data(snapshot.metadataVersion.utf8))
    }

    var symlinkTargetPath: String? { snapshot.linkTarget }

    var extendedAttributes: [String: Data] { snapshot.extendedAttributes }

    /// Pinning declares itself per item through contentPolicy (section 2, section 7.1.1).
    var contentPolicy: NSFileProviderContentPolicy {
        switch SSHDriveContentPolicy(rawValue: snapshot.contentPolicyRawValue) ?? .unset {
        case .downloadEagerlyAndKeepDownloaded: return .downloadEagerlyAndKeepDownloaded
        case .downloadLazily: return .downloadLazily
        case .inherited: return .inherited
        case .unset: return .inherited
        }
    }

    /// `userInfo.kept` is what the Finder action's activation rule tests (section 7.2).
    var userInfo: [AnyHashable: Any]? {
        ["kept": snapshot.kept]
    }
}

/// The one identifier both sides must spell the same way.
enum SSHDriveItemIdentifiers {
    /// What the index calls the root row (`IndexWriter.rootIdentifier`). It is written
    /// out rather than imported so the extension does not link the Index module's writer.
    static let root = "NSFileProviderRootContainerItemIdentifier"

    /// The agent speaks in row identifiers; the system speaks in NSFileProviderItemIdentifier.
    static func agentIdentifier(for identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? root : identifier.rawValue
    }
}
