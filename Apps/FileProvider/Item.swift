import FileProvider
import Foundation
import ProviderCore
import UniformTypeIdentifiers

/// `NSFileProviderItem` over an `ItemView` (`docs/design/extension.md`).
///
/// Nothing is computed here. Every field was decided in `ProviderCore.ItemView` - which
/// itself is a field-by-field copy from a finished row, with no ancestor walk and no
/// second copy of the naming, symlink or eviction rules - and this class is the Apple
/// coat over it.
final class Item: NSObject, NSFileProviderItemDecorating {
    private let view: ItemView

    init(view: ItemView) {
        self.view = view
    }

    var itemIdentifier: NSFileProviderItemIdentifier { AppleMapping.identifier(view.identifier) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        AppleMapping.identifier(view.parentIdentifier)
    }

    var filename: String { view.filename }

    var contentType: UTType {
        switch view.contentTypeHint {
        case .folder: return .folder
        case .symbolicLink: return .symbolicLink
        case .filenameExtension(let ext):
            return UTType(filenameExtension: ext) ?? .data
        case .data: return .data
        }
    }

    var capabilities: NSFileProviderItemCapabilities {
        NSFileProviderItemCapabilities(rawValue: view.capabilities.rawValue)
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        NSFileProviderFileSystemFlags(rawValue: view.fileSystemFlags.rawValue)
    }

    var documentSize: NSNumber? { view.documentSize.map { NSNumber(value: $0) } }

    var contentModificationDate: Date? {
        Date(timeIntervalSince1970: view.contentModificationDate)
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(view.contentVersion.utf8),
            metadataVersion: Data(view.metadataVersion.utf8))
    }

    var symlinkTargetPath: String? { view.symlinkTargetPath }

    var extendedAttributes: [String: Data] { view.extendedAttributes }

    var tagData: Data? { view.tagData }

    var contentPolicy: NSFileProviderContentPolicy {
        switch view.contentPolicy {
        case .downloadEagerlyAndKeepDownloaded: return .downloadEagerlyAndKeepDownloaded
        case .downloadLazily: return .downloadLazily
        case .inherited, .unset: return .inherited
        }
    }

    var userInfo: [AnyHashable: Any]? { ["kept": view.userInfoKept] }

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        let identifiers = view.decorations
        return identifiers.isEmpty
            ? nil : identifiers.map { NSFileProviderItemDecorationIdentifier($0) }
    }
}
