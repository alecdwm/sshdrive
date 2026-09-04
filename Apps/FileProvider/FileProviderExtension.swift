import FileProvider
import Foundation
import UniformTypeIdentifiers
import Index
import XPCProtocols
import Logging

/// The File Provider extension (DESIGN.md section 5).
///
/// One instance per domain; the system may host several instances in one process, so
/// nothing here is global. It holds no state of its own, opens no sockets and never
/// writes the index. Its only file I/O is the index it reads and the temp file the system
/// gives it for fetched content, whose handle it passes to the agent to fill (section 3).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let domainIdentifier: String
    let displayName: String
    let readerStore: IndexReaderStore

    private let callbacks = ExtensionCallbacks()
    private let connection: AgentConnection
    private let manager: NSFileProviderManager?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.domainIdentifier = domain.identifier.rawValue
        self.displayName = domain.displayName
        self.readerStore = IndexReaderStore(locationID: domain.identifier.rawValue)
        self.connection = AgentConnection(domain: domain, callbacks: callbacks)
        self.manager = NSFileProviderManager(for: domain)
        super.init()

        callbacks.onReaderClose = { [weak self] in self?.readerStore.close() }
        callbacks.onReaderReopen = { [weak self] in self?.readerStore.reopen() }

        // One XPC call per instance launch: is the index ready to be read (section 5.3)?
        // An agent that cannot be reached at all leaves the instance free to open the
        // reader, since a missing agent is the case the direct reader exists for.
        if let proxy = agentProxy({ [weak self] _ in self?.readerStore.markReady(true) }) {
            proxy.indexReady(domainIdentifier: domainIdentifier) { [weak self] ready in
                // A reply of any kind is proof the agent is there, so lift a disconnect a
                // previous instance may have left on the domain (section 5.2).
                self?.connection.noteAgentReachable()
                self?.readerStore.markReady(ready)
            }
        } else {
            readerStore.markReady(true)
        }

        Log.extensionLog.notice(
            "extension instance for \(self.displayName, privacy: .public) started")
    }

    func invalidate() {
        connection.invalidate()
        readerStore.close()
    }

    /// The proxy, with a single place that turns a dead connection into an error the
    /// system understands.
    func agentProxy(_ onError: @escaping (Error) -> Void) -> SSHDriveAgentProtocol? {
        connection.proxy { error in
            Log.extensionLog.error("the agent is unreachable: \(error, privacy: .public)")
            onError(NSFileProviderError(.serverUnreachable))
        }
    }

    func currentSequence() -> Int64 {
        readerStore.currentSequence() ?? 0
    }

    /// The extension tells the agent it has answered `.syncAnchorExpired` and handed out
    /// a fresh anchor, one call per expiry (section 5.3).
    func reportAnchorExpired(freshAnchor: String) {
        agentProxy({ _ in })?.workingSetAnchorExpired(
            domainIdentifier: domainIdentifier, freshAnchor: freshAnchor)
    }

    // MARK: item(for:)

    /// Answered from the index by the extension itself, with no agent involved, because
    /// the system issues this in bulk and it must be answered from local state
    /// (sections 2, 5.2).
    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let agentIdentifier = SSHDriveItemIdentifiers.agentIdentifier(for: identifier)

        // No trash (section 5.4). Answered here, from nothing, so that neither the reader
        // nor the agent is asked for a row that can never exist: a domain added before
        // `supportsSyncingTrash = false` still has a trash the system may stat, and a
        // slow answer to that is what a `ls -la` waits on.
        if SSHDriveTrash.isTrash(identifier: agentIdentifier) {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        do {
            if let snapshot = try readerStore.item(identifier: agentIdentifier) {
                completionHandler(Item(snapshot: snapshot, rootDisplayName: displayName), nil)
                progress.completedUnitCount = 1
                return progress
            }
        } catch {
            completionHandler(nil, error)
            progress.completedUnitCount = 1
            return progress
        }

        // No reader, or a schema this build does not understand: ask the agent
        // (section 5.2).
        guard let proxy = agentProxy({ completionHandler(nil, $0) }) else {
            completionHandler(nil, NSFileProviderError(.serverUnreachable))
            progress.completedUnitCount = 1
            return progress
        }
        proxy.item(domainIdentifier: domainIdentifier, itemIdentifier: agentIdentifier) {
            [weak self] snapshot, error in
            guard let self else { return }
            progress.completedUnitCount = 1
            if let snapshot {
                completionHandler(Item(snapshot: snapshot, rootDisplayName: self.displayName), nil)
            } else {
                completionHandler(nil, AgentConnection.fileProviderError(from: error ?? NSFileProviderError(.serverUnreachable)))
            }
        }
        return progress
    }

    // MARK: Content

    /// The extension creates the target file in its own temp directory, opens it for
    /// writing and sends the handle; the agent writes through it and never needs to
    /// resolve, or be allowed to reach, a path inside the extension's container
    /// (section 5.2).
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        fetch(
            itemIdentifier, version: requestedVersion, range: nil, request: request,
            completionHandler: { url, item, error in completionHandler(url, item, error) })
    }

    /// Range requests, for large media (section 5.1). Always a foreground transfer under
    /// the scheduler of section 6.2.
    func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest, minimalRange: NSRange, aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void
    ) -> Progress {
        // The range is widened to the alignment the system asked for, which is what lets
        // it stitch neighbouring windows together rather than re-fetching them.
        let stride = max(alignment, 1)
        let start = (minimalRange.location / stride) * stride
        let end = ((minimalRange.location + minimalRange.length + stride - 1) / stride) * stride
        let aligned = NSRange(location: start, length: max(end - start, stride))
        return fetch(
            itemIdentifier, version: requestedVersion, range: aligned, request: request
        ) { url, item, error in
            completionHandler(url, item, aligned, [], error)
        }
    }

    private func fetch(
        _ itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        range: NSRange?, request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let transferID = UUID().uuidString

        guard let manager else {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return progress
        }

        let temporaryURL: URL
        do {
            let directory = try manager.temporaryDirectoryURL()
            temporaryURL = directory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw NSFileProviderError(.cannotSynchronize)
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

        guard let proxy = agentProxy({ completionHandler(nil, nil, $0) }) else {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return progress
        }

        callbacks.register(progress, for: transferID)
        // Cancelling the Progress sends a cancel for that transfer's id over the same
        // connection; the agent abandons the SFTP requests in flight (section 5.2).
        progress.cancellationHandler = { [weak self] in
            self?.agentProxy({ _ in })?.cancelTransfer(transferID: transferID)
        }

        let done: @Sendable (SSHDriveItemSnapshot?, Error?) -> Void = { [weak self] snapshot, error in
            guard let self else { return }
            try? handle.close()
            self.callbacks.unregister(transferID: transferID)
            if let snapshot {
                completionHandler(
                    temporaryURL, Item(snapshot: snapshot, rootDisplayName: self.displayName), nil)
            } else {
                try? FileManager.default.removeItem(at: temporaryURL)
                completionHandler(
                    nil, nil,
                    AgentConnection.fileProviderError(from: error ?? NSFileProviderError(.serverUnreachable)))
            }
        }

        if let range {
            proxy.fetchPartialContents(
                domainIdentifier: domainIdentifier,
                itemIdentifier: SSHDriveItemIdentifiers.agentIdentifier(for: itemIdentifier),
                offset: Int64(range.location),
                length: Int64(range.length),
                into: handle,
                transferID: transferID,
                reply: done)
            return progress
        }

        // Section 6.2's two classes, read straight off the request: a file-viewer request,
        // or anything that is not a system request, is the user or an app opening the
        // file and goes in the foreground.
        proxy.fetchContents(
            domainIdentifier: domainIdentifier,
            itemIdentifier: SSHDriveItemIdentifiers.agentIdentifier(for: itemIdentifier),
            requestedVersion: requestedVersion.map { String(decoding: $0.contentVersion, as: UTF8.self) },
            isFileViewerRequest: request.isFileViewerRequest,
            isSystemRequest: request.isSystemRequest,
            into: handle,
            transferID: transferID,
            reply: done)
        return progress
    }

    // MARK: Mutations

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let transferID = UUID().uuidString

        // With `supportsSyncingTrash = false` the system decides how to handle a trashing
        // operation, and the header does not guarantee what it decides. Whatever it is, it
        // is not a `.Trash` directory of ours on someone's server (section 5.4).
        if itemTemplate.parentItemIdentifier == .rootContainer,
            SSHDriveTrash.isTrash(filename: itemTemplate.filename)
        {
            completionHandler(nil, [], false, SSHDriveTrash.unsupportedError)
            return progress
        }

        var handle: FileHandle?
        if let url {
            handle = try? FileHandle(forReadingFrom: url)
        }

        guard let proxy = agentProxy({ completionHandler(nil, [], false, $0) }) else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return progress
        }

        let isDirectory = itemTemplate.contentType == .folder
        let isSymlink = itemTemplate.contentType == .symbolicLink

        proxy.createItem(
            domainIdentifier: domainIdentifier,
            parentIdentifier: SSHDriveItemIdentifiers.agentIdentifier(for: itemTemplate.parentItemIdentifier),
            filename: itemTemplate.filename,
            isDirectory: isDirectory,
            symlinkTarget: isSymlink ? itemTemplate.symlinkTargetPath ?? nil : nil,
            contents: handle,
            transferID: transferID
        ) { [weak self] snapshot, error in
            guard let self else { return }
            try? handle?.close()
            if let snapshot {
                completionHandler(
                    Item(snapshot: snapshot, rootDisplayName: self.displayName), [], false, nil)
            } else {
                completionHandler(
                    nil, [], false,
                    AgentConnection.fileProviderError(from: error ?? NSFileProviderError(.serverUnreachable)))
            }
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let transferID = UUID().uuidString

        var handle: FileHandle?
        if let newContents {
            handle = try? FileHandle(forReadingFrom: newContents)
        }

        guard let proxy = agentProxy({ completionHandler(nil, [], false, $0) }) else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return progress
        }

        proxy.modifyItem(
            domainIdentifier: domainIdentifier,
            itemIdentifier: SSHDriveItemIdentifiers.agentIdentifier(for: item.itemIdentifier),
            baseVersion: String(decoding: version.contentVersion, as: UTF8.self),
            changedFields: UInt64(changedFields.rawValue),
            newParentIdentifier: changedFields.contains(.parentItemIdentifier)
                ? SSHDriveItemIdentifiers.agentIdentifier(for: item.parentItemIdentifier) : nil,
            newFilename: changedFields.contains(.filename) ? item.filename : nil,
            newFileSystemFlags: (item.fileSystemFlags?.rawValue).map { NSNumber(value: UInt64($0)) },
            newModificationDate: (item.contentModificationDate ?? nil).map {
                NSNumber(value: $0.timeIntervalSince1970)
            },
            newExtendedAttributes: changedFields.contains(.extendedAttributes)
                ? (item.extendedAttributes ?? [:]) : nil,
            contents: handle,
            transferID: transferID
        ) { [weak self] snapshot, error in
            guard let self else { return }
            try? handle?.close()
            if let snapshot {
                completionHandler(
                    Item(snapshot: snapshot, rootDisplayName: self.displayName), [], false, nil)
            } else {
                completionHandler(
                    nil, [], false,
                    AgentConnection.fileProviderError(from: error ?? NSFileProviderError(.serverUnreachable)))
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
        guard let proxy = agentProxy({ completionHandler($0) }) else {
            completionHandler(NSFileProviderError(.serverUnreachable))
            return progress
        }
        proxy.deleteItem(
            domainIdentifier: domainIdentifier,
            itemIdentifier: SSHDriveItemIdentifiers.agentIdentifier(for: identifier),
            baseVersion: String(decoding: version.contentVersion, as: UTF8.self),
            recursive: options.contains(.recursive)
        ) { error in
            progress.completedUnitCount = 1
            completionHandler(error.map { AgentConnection.fileProviderError(from: $0) })
        }
        return progress
    }

    // MARK: Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(extensionInstance: self)
        }
        if containerItemIdentifier == .trashContainer {
            // No trash (section 5.4). NSFeatureUnsupportedError is what
            // NSFileProviderReplicatedExtension.h prescribes for an extension that does
            // not support trashing. It must not be `noSuchItem`: the system reads that as
            // "the container was deleted", tries to delete it from disk, fails because the
            // trash is its own, and retries about once a second for ever, which is the
            // hang `ls -la` used to sit in (docs/spikes/results.md, 2026-09-04).
            throw SSHDriveTrash.unsupportedError
        }
        return ContainerEnumerator(container: containerItemIdentifier, extensionInstance: self)
    }

    // MARK: Signals

    /// Forwarded so the agent can refresh its root set (section 6.5) and the pin safety
    /// net (section 7.2).
    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        agentProxy({ _ in })?.materializedItemsDidChange(domainIdentifier: domainIdentifier)
        completionHandler()
    }
}
