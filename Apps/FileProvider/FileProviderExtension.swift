import FileProvider
import Foundation
import ProviderCore
import UniformTypeIdentifiers
import XPCProtocols

/// The File Provider extension (`docs/design/extension.md`).
///
/// One instance per domain; the system may host several instances in one process, so
/// nothing here is global. It holds no state of its own, opens no sockets and never
/// writes the index.
///
/// **This file contains no decision.** Every rule the extension applies - which source
/// answers the working set, which error a reader that cannot answer deserves, the trash
/// refusal, the readiness window, item construction, the two Finder actions - lives in
/// `ProviderCore.ProviderService`, where it compiles on Linux and is driven by
/// `SystemModel.FileProviderD` (`docs/design/testing.md`). What is left is one forwarding
/// call per protocol method, plus the file I/O that only the appex can do: the temp file
/// the system gives it for fetched content, whose handle it passes to the agent to
/// fill.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let domainIdentifier: String
    let displayName: String

    private let callbacks = ExtensionCallbacks()
    private let connection: AgentConnection
    private let manager: NSFileProviderManager?
    private let service: ProviderService

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.domainIdentifier = domain.identifier.rawValue
        self.displayName = domain.displayName
        self.connection = AgentConnection(callbacks: callbacks)
        self.manager = NSFileProviderManager(for: domain)

        let reader = IndexReaderStore(
            locationID: domain.identifier.rawValue, rootDisplayName: domain.displayName)
        let channel = XPCAgentChannel(
            connection: connection, domainIdentifier: domain.identifier.rawValue,
            displayName: domain.displayName)
        self.service = ProviderService(
            domainIdentifier: domain.identifier.rawValue,
            displayName: domain.displayName,
            reader: reader,
            agent: channel,
            signalling: ManagerSignalling(domain: domain))
        super.init()

        callbacks.onReaderClose = { [weak self] in self?.service.reader.close() }
        callbacks.onReaderReopen = { [weak self] in self?.service.reader.reopen() }
        connection.onUnreachable = { [weak self] in self?.service.noteAgentUnreachable() }

        service.start()
    }

    func invalidate() {
        connection.invalidate()
        service.invalidate()
    }

    // MARK: item(for:)

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        service.item(for: AppleMapping.identifier(identifier)) { result in
            progress.completedUnitCount = 1
            switch result {
            case .success(let view): completionHandler(Item(view: view), nil)
            case .failure(let failure): completionHandler(nil, AppleMapping.nsError(failure))
            }
        }
        return progress
    }

    // MARK: Content

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // The transfer scheduler's two classes, foreground and background, are read
        // straight off the request and travel to the agent unchanged
        // (`docs/design/sftp.md`).
        transfer(completionHandler) { [self] handle, transferID, done in
            service.fetchContents(
                identifier: AppleMapping.identifier(itemIdentifier),
                requestedVersion: requestedVersion.map {
                    String(decoding: $0.contentVersion, as: UTF8.self)
                },
                isFileViewerRequest: request.isFileViewerRequest,
                isSystemRequest: request.isSystemRequest,
                into: handle, transferID: transferID, done)
        }
    }

    /// Range requests, for large media. Always a foreground transfer under the transfer
    /// scheduler (`docs/design/sftp.md`).
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest, minimalRange: NSRange, aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (
            URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?
        ) -> Void
    ) -> Progress {
        let widened = ProviderService.alignedRange(
            location: minimalRange.location, length: minimalRange.length, alignment: alignment)
        let aligned = NSRange(location: widened.location, length: widened.length)
        return transfer({ url, item, error in
            completionHandler(url, item, aligned, [], error)
        }) { [self] handle, transferID, done in
            service.fetchPartialContents(
                identifier: AppleMapping.identifier(itemIdentifier),
                alignedOffset: Int64(aligned.location), alignedLength: Int64(aligned.length),
                into: handle, transferID: transferID, done)
        }
    }

    /// The extension creates the target file in its own temp directory, opens it for
    /// writing and sends the handle; the agent writes through it and never needs to
    /// resolve, or be allowed to reach, a path inside the extension's container.
    private func transfer(
        _ completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void,
        _ start: (FileHandle, String, @escaping (Result<ItemView, ProviderFailure>) -> Void) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let transferID = UUID().uuidString

        guard let manager else {
            completionHandler(nil, nil, AppleMapping.nsError(.serverUnreachable))
            return progress
        }

        let temporaryURL: URL
        do {
            let directory = try manager.temporaryDirectoryURL()
            temporaryURL = directory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw AppleMapping.nsError(.cannotSynchronize)
            }
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }

        callbacks.register(progress, for: transferID)
        // Cancelling the Progress sends a cancel for that transfer's id over the same
        // connection; the agent abandons the SFTP requests in flight.
        progress.cancellationHandler = { [weak self] in
            self?.service.agent.cancelTransfer(transferID: transferID)
        }

        start(handle, transferID) { [weak self] result in
            try? handle.close()
            self?.callbacks.unregister(transferID: transferID)
            switch result {
            case .success(let view):
                completionHandler(temporaryURL, Item(view: view), nil)
            case .failure(let failure):
                try? FileManager.default.removeItem(at: temporaryURL)
                completionHandler(nil, nil, AppleMapping.nsError(failure))
            }
        }
        return progress
    }

    // MARK: Mutations

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
        contents url: URL?, options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        var handle: FileHandle?
        if let url { handle = try? FileHandle(forReadingFrom: url) }

        let template = ItemTemplate(
            parentIdentifier: AppleMapping.identifier(itemTemplate.parentItemIdentifier),
            filename: itemTemplate.filename,
            isDirectory: itemTemplate.contentType == .folder,
            isSymlink: itemTemplate.contentType == .symbolicLink,
            symlinkTarget: itemTemplate.contentType == .symbolicLink
                ? itemTemplate.symlinkTargetPath ?? nil : nil,
            // The temp file is opened with the Mac file's permission bits, 0755 when
            // the local one is executable, and the modification date is set back after
            // the rename (`docs/design/writes.md`).
            fileSystemFlags: (itemTemplate.fileSystemFlags?.rawValue).map { UInt64($0) },
            modificationDate: (itemTemplate.contentModificationDate ?? nil)?.timeIntervalSince1970,
            extendedAttributes: fields.contains(.extendedAttributes)
                ? (itemTemplate.extendedAttributes ?? [:]) : nil,
            // Tags never arrive as an xattr; they are the item's own `tagData`, and an
            // item that returns none loses them on the next re-download.
            tagData: fields.contains(.tagData) ? (itemTemplate.tagData ?? nil) : nil)

        service.createItem(
            template: template, contents: handle, transferID: UUID().uuidString
        ) { result in
            try? handle?.close()
            switch result {
            case .success(let view): completionHandler(Item(view: view), [], false, nil)
            case .failure(let failure):
                completionHandler(nil, [], false, AppleMapping.nsError(failure))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        var handle: FileHandle?
        if let newContents { handle = try? FileHandle(forReadingFrom: newContents) }

        let changes = ItemChanges(
            newParentIdentifier: changedFields.contains(.parentItemIdentifier)
                ? AppleMapping.identifier(item.parentItemIdentifier) : nil,
            newFilename: changedFields.contains(.filename) ? item.filename : nil,
            newFileSystemFlags: (item.fileSystemFlags?.rawValue).map { UInt64($0) },
            newModificationDate: (item.contentModificationDate ?? nil)?.timeIntervalSince1970,
            newExtendedAttributes: changedFields.contains(.extendedAttributes)
                ? (item.extendedAttributes ?? [:]) : nil,
            newTagData: changedFields.contains(.tagData) ? (item.tagData ?? nil) : nil,
            newSymlinkTarget: item.symlinkTargetPath ?? nil)

        service.modifyItem(
            identifier: AppleMapping.identifier(item.itemIdentifier),
            baseVersion: String(decoding: version.contentVersion, as: UTF8.self),
            changedFields: ProviderItemFields(rawValue: changedFields.rawValue),
            changes: changes, contents: handle, transferID: UUID().uuidString
        ) { result in
            try? handle?.close()
            switch result {
            case .success(let view): completionHandler(Item(view: view), [], false, nil)
            case .failure(let failure):
                completionHandler(nil, [], false, AppleMapping.nsError(failure))
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        service.deleteItem(
            identifier: AppleMapping.identifier(identifier),
            baseVersion: String(decoding: version.contentVersion, as: UTF8.self),
            recursive: options.contains(.recursive)
        ) { failure in
            progress.completedUnitCount = 1
            completionHandler(failure.map(AppleMapping.nsError))
        }
        return progress
    }

    // MARK: Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        do {
            return EnumeratorAdapter(
                core: try service.enumerator(for: AppleMapping.identifier(containerItemIdentifier)))
        } catch let failure as ProviderFailure {
            throw AppleMapping.nsError(failure)
        }
    }

    // MARK: Signals

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        service.materializedItemsDidChange()
        completionHandler()
    }
}

// MARK: The context-menu entries

/// "Keep Downloaded" and "Don't Keep Downloaded", declared in the appex's Info.plist with
/// the activation rules that read `userInfo.kept`, and forwarded here
/// (`docs/design/pinning.md`).
extension FileProviderExtension: NSFileProviderCustomAction {
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        service.performAction(
            actionIdentifier: actionIdentifier.rawValue,
            itemIdentifiers: itemIdentifiers.map(AppleMapping.identifier)
        ) { failure in
            progress.completedUnitCount = 1
            completionHandler(failure.map(AppleMapping.nsError))
        }
        return progress
    }
}
