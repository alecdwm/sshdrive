import FileProvider
import Foundation
import Logging
import ProviderCore
import XPCInterfaces
import XPCProtocols

/// The extension's XPC client (DESIGN.md section 5.2).
///
/// The extension connects to the agent's mach service on first use. launchd starts the
/// agent on demand if it is registered, so the extension does not care whether the agent
/// was already running.
///
/// Nothing here decides anything: whether a failed call means the domain should be
/// disconnected, and whether a reply means it should be reconnected, are
/// `ProviderService`'s rules (`MQ-073`, `MQ-074`). This class owns the socket and calls
/// those rules through `onUnreachable`.
final class AgentConnection: NSObject {
    private let callbacks: ExtensionCallbacks
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    /// Called when a call actually fails, which is the only evidence of a missing agent.
    var onUnreachable: (() -> Void)?

    init(callbacks: ExtensionCallbacks) {
        self.callbacks = callbacks
    }

    /// A proxy, or nil when the agent cannot be reached. `onError` fires for a connection
    /// that drops after the call was made.
    func proxy(onError: @escaping (Error) -> Void) -> SSHDriveAgentProtocol? {
        lock.lock()
        defer { lock.unlock() }

        if connection == nil {
            let created = NSXPCConnection(
                machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
            created.remoteObjectInterface = SSHDriveXPCInterface.agent
            created.exportedInterface = SSHDriveXPCInterface.fileProviderExtension
            created.exportedObject = callbacks
            created.invalidationHandler = { [weak self] in
                self?.connectionWentAway()
            }
            created.interruptionHandler = { [weak self] in
                self?.connectionWentAway()
            }
            created.resume()
            connection = created
        }

        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Log.extensionLog.error("the agent is unreachable: \(error, privacy: .public)")
            self?.onUnreachable?()
            onError(error)
        } as? SSHDriveAgentProtocol
    }

    /// The connection dropped. That is *not* on its own a missing agent: the system kills
    /// an idle extension instance (`MQ-073`), and the invalidation that follows our own
    /// teardown used to call `disconnect(reason:)` on the way out, which left the domain
    /// disconnected for every later instance and answered every request
    /// `.serverUnreachable` for good (docs/spikes/results.md, 2026-09-04 signed pass).
    /// Only a call that actually fails reports a missing agent; the next call rebuilds
    /// the connection.
    private func connectionWentAway() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }
}

/// `NSFileProviderManager`'s three calls, behind `ProviderDomainSignalling`.
final class ManagerSignalling: ProviderDomainSignalling {
    private let manager: NSFileProviderManager?

    init(domain: NSFileProviderDomain) {
        self.manager = NSFileProviderManager(for: domain)
    }

    func signalErrorResolved(_ failure: ProviderFailure) {
        guard let manager else { return }
        manager.signalErrorResolved(AppleMapping.nsError(failure)) { error in
            if let error {
                Log.extensionLog.error(
                    "signalErrorResolved failed: \(error, privacy: .public)")
            }
        }
    }

    func disconnect(reason: String) {
        guard let manager else { return }
        manager.disconnect(reason: reason, options: []) { error in
            if let error {
                Log.extensionLog.error("disconnect(reason:) failed: \(error, privacy: .public)")
            }
        }
    }

    func reconnect() {
        guard let manager else { return }
        manager.reconnect { error in
            if let error {
                Log.extensionLog.error("reconnect() failed: \(error, privacy: .public)")
            }
        }
    }
}

/// `AgentChannel` over NSXPC: one method each, argument for argument, with
/// `AppleMapping.failure(from:)` at every failure edge.
final class XPCAgentChannel: AgentChannel {
    private let connection: AgentConnection
    private let domainIdentifier: String
    private let displayName: String

    init(connection: AgentConnection, domainIdentifier: String, displayName: String) {
        self.connection = connection
        self.domainIdentifier = domainIdentifier
        self.displayName = displayName
    }

    private func view(_ snapshot: SSHDriveItemSnapshot) -> ItemView {
        ItemView(snapshot: snapshot, rootDisplayName: displayName)
    }

    /// One place turning "there is no proxy" and "the call failed" into the same answer.
    private func withProxy(
        _ onUnreachable: @escaping () -> Void, _ body: (SSHDriveAgentProtocol) -> Void
    ) {
        guard let proxy = connection.proxy(onError: { _ in onUnreachable() }) else {
            onUnreachable()
            return
        }
        body(proxy)
    }

    private func itemReply(
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) -> (SSHDriveItemSnapshot?, Error?) -> Void {
        { [weak self] snapshot, error in
            guard let self else { return }
            if let snapshot {
                completion(.success(self.view(snapshot)))
            } else {
                completion(.failure(error.map(AppleMapping.failure(from:)) ?? .serverUnreachable))
            }
        }
    }

    private func pageReply(
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) -> (SSHDriveItemPage?, Error?) -> Void {
        { [weak self] page, error in
            guard let self else { return }
            if let error {
                completion(.failure(AppleMapping.failure(from: error)))
                return
            }
            completion(
                .success(
                    ProviderItemPage(
                        items: (page?.items ?? []).map(self.view),
                        deletedIdentifiers: (page?.deletedIdentifiers ?? []).map {
                            ProviderItemIdentifier($0)
                        },
                        nextPageToken: page?.nextPageToken,
                        anchor: page?.anchor ?? "",
                        moreComing: page?.moreComing ?? false)))
        }
    }

    // MARK: Handshake

    func indexReady(_ completion: @escaping (Bool?) -> Void) {
        withProxy({ completion(nil) }) { proxy in
            proxy.indexReady(domainIdentifier: domainIdentifier) { completion($0) }
        }
    }

    // MARK: Enumeration

    func enumerateItems(
        container: ProviderItemIdentifier, pageToken: ProviderPageToken?,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.enumerateItems(
                domainIdentifier: domainIdentifier, containerIdentifier: container.rawValue,
                pageToken: pageToken, reply: pageReply(completion))
        }
    }

    func enumerateChanges(
        container: ProviderItemIdentifier, anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.enumerateChanges(
                domainIdentifier: domainIdentifier, containerIdentifier: container.rawValue,
                anchor: anchor.rawValue, reply: pageReply(completion))
        }
    }

    func enumerateWorkingSetChanges(
        anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.enumerateWorkingSetChanges(
                domainIdentifier: domainIdentifier, anchor: anchor.rawValue,
                reply: pageReply(completion))
        }
    }

    func currentAnchor(_ completion: @escaping (String?) -> Void) {
        withProxy({ completion(nil) }) { proxy in
            proxy.currentAnchor(domainIdentifier: domainIdentifier) { anchor, _ in
                completion(anchor)
            }
        }
    }

    func item(
        identifier: ProviderItemIdentifier,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.item(
                domainIdentifier: domainIdentifier, itemIdentifier: identifier.rawValue,
                reply: itemReply(completion))
        }
    }

    // MARK: Transfers

    func fetchContents(
        identifier: ProviderItemIdentifier, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool, into destination: FileHandle,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.fetchContents(
                domainIdentifier: domainIdentifier, itemIdentifier: identifier.rawValue,
                requestedVersion: requestedVersion, isFileViewerRequest: isFileViewerRequest,
                isSystemRequest: isSystemRequest, into: destination, transferID: transferID,
                reply: itemReply(completion))
        }
    }

    func fetchPartialContents(
        identifier: ProviderItemIdentifier, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.fetchPartialContents(
                domainIdentifier: domainIdentifier, itemIdentifier: identifier.rawValue,
                offset: offset, length: length, into: destination, transferID: transferID,
                reply: itemReply(completion))
        }
    }

    // MARK: Mutations

    func createItem(
        template: ItemTemplate, contents: FileHandle?, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.createItem(
                domainIdentifier: domainIdentifier,
                parentIdentifier: template.parentIdentifier.rawValue,
                filename: template.filename,
                isDirectory: template.isDirectory,
                symlinkTarget: template.symlinkTarget,
                fileSystemFlags: template.fileSystemFlags.map { NSNumber(value: $0) },
                modificationDate: template.modificationDate.map { NSNumber(value: $0) },
                extendedAttributes: template.extendedAttributes,
                tagData: template.tagData,
                contents: contents,
                transferID: transferID,
                reply: itemReply(completion))
        }
    }

    func modifyItem(
        identifier: ProviderItemIdentifier, baseVersion: String?,
        changedFields: ProviderItemFields, changes: ItemChanges, contents: FileHandle?,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void
    ) {
        withProxy({ completion(.failure(.serverUnreachable)) }) { proxy in
            proxy.modifyItem(
                domainIdentifier: domainIdentifier,
                itemIdentifier: identifier.rawValue,
                baseVersion: baseVersion,
                changedFields: UInt64(changedFields.rawValue),
                newParentIdentifier: changes.newParentIdentifier?.rawValue,
                newFilename: changes.newFilename,
                newFileSystemFlags: changes.newFileSystemFlags.map { NSNumber(value: $0) },
                newModificationDate: changes.newModificationDate.map { NSNumber(value: $0) },
                newExtendedAttributes: changes.newExtendedAttributes,
                newTagData: changes.newTagData,
                newSymlinkTarget: changes.newSymlinkTarget,
                contents: contents,
                transferID: transferID,
                reply: itemReply(completion))
        }
    }

    func deleteItem(
        identifier: ProviderItemIdentifier, baseVersion: String?, recursive: Bool,
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        withProxy({ completion(.serverUnreachable) }) { proxy in
            proxy.deleteItem(
                domainIdentifier: domainIdentifier, itemIdentifier: identifier.rawValue,
                baseVersion: baseVersion, recursive: recursive
            ) { error in
                completion(error.map(AppleMapping.failure(from:)))
            }
        }
    }

    func cancelTransfer(transferID: String) {
        withProxy({}) { $0.cancelTransfer(transferID: transferID) }
    }

    // MARK: Signals

    func materializedItemsDidChange() {
        withProxy({}) { $0.materializedItemsDidChange(domainIdentifier: domainIdentifier) }
    }

    func workingSetAnchorExpired(freshAnchor: String) {
        withProxy({}) {
            $0.workingSetAnchorExpired(
                domainIdentifier: domainIdentifier, freshAnchor: freshAnchor)
        }
    }

    func performAction(
        actionIdentifier: String, itemIdentifiers: [ProviderItemIdentifier],
        _ completion: @escaping (ProviderFailure?) -> Void
    ) {
        withProxy({ completion(.serverUnreachable) }) { proxy in
            proxy.performAction(
                domainIdentifier: domainIdentifier, actionIdentifier: actionIdentifier,
                itemIdentifiers: itemIdentifiers.map(\.rawValue)
            ) { error in
                completion(error.map(AppleMapping.failure(from:)))
            }
        }
    }
}

/// The object the agent calls back on: transfer progress and the close-and-reopen
/// protocol of section 5.3.
final class ExtensionCallbacks: NSObject, SSHDriveExtensionProtocol {
    private let lock = NSLock()
    private var progresses: [String: Progress] = [:]
    /// Set while the agent is rebuilding the index, so the reader stays shut.
    private(set) var readerIsClosed = false
    var onReaderClose: (() -> Void)?
    var onReaderReopen: (() -> Void)?

    func register(_ progress: Progress, for transferID: String) {
        lock.lock()
        progresses[transferID] = progress
        lock.unlock()
    }

    func unregister(transferID: String) {
        lock.lock()
        progresses.removeValue(forKey: transferID)
        lock.unlock()
    }

    func transferProgress(transferID: String, bytesCompleted: Int64, bytesTotal: Int64) {
        lock.lock()
        let progress = progresses[transferID]
        lock.unlock()
        progress?.totalUnitCount = max(bytesTotal, 1)
        progress?.completedUnitCount = bytesCompleted
    }

    func closeIndexReader(reply: @escaping () -> Void) {
        readerIsClosed = true
        onReaderClose?()
        reply()
    }

    func reopenIndexReader() {
        readerIsClosed = false
        onReaderReopen?()
    }
}
