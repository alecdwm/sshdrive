import Foundation
import FileProvider
import Index
import AgentCore
import SFTP
import XPCProtocols
import Logging

/// The object exported on every accepted XPC connection. One instance per connection, so
/// the agent can call back on that connection (transfer progress, the close-and-reopen
/// protocol of DESIGN.md section 5.3) without a lookup.
final class AgentService: NSObject, SSHDriveAgentProtocol {
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// The extension's side of this connection, for callbacks.
    private var peer: SSHDriveExtensionProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            Log.agent.error("callback to the extension failed: \(error, privacy: .public)")
        } as? SSHDriveExtensionProtocol
    }

    // MARK: Handshake

    func ping(interfaceVersion: Int, reply: @escaping (Int) -> Void) {
        reply(sshDriveXPCInterfaceVersion)
    }

    func indexReady(domainIdentifier: String, reply: @escaping (Bool) -> Void) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "indexReady", subject: "")
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                _ = try await runtime.currentSequence()
                call.finish("ready")
                reply(true)
            } catch {
                // An agent mid-restore, or one that cannot open the index at all, answers
                // no and the instance opens nothing (section 5.3).
                call.finish(error: error)
                reply(false)
            }
        }
    }

    // MARK: Enumeration

    func enumerateItems(
        domainIdentifier: String, containerIdentifier: String, pageToken: String?,
        reply: @escaping (SSHDriveItemPage?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "enumerateItems", subject: containerIdentifier)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                // Section 5.2: paged for directories with tens of thousands of entries.
                // A page token is an offset into a listing the agent already holds, so a
                // second page never re-lists the directory.
                let page = try await runtime.enumerateItems(
                    container: containerIdentifier, pageToken: pageToken)
                let anchor = try await runtime.currentSequence()
                call.finish("\(page.items.count) item(s)")
                reply(
                    SSHDriveItemPage(
                        items: page.items, nextPageToken: page.nextPageToken,
                        anchor: String(anchor)), nil)
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func enumerateChanges(
        domainIdentifier: String, containerIdentifier: String, anchor: String,
        reply: @escaping (SSHDriveItemPage?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "enumerateChanges", subject: containerIdentifier)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let result = try await runtime.enumerateChanges(container: containerIdentifier)
                let sequence = try await runtime.currentSequence()
                call.finish("\(result.items.count) changed, \(result.deleted.count) deleted")
                reply(
                    SSHDriveItemPage(
                        items: result.items, deletedIdentifiers: result.deleted,
                        anchor: String(sequence)), nil)
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func item(
        domainIdentifier: String, itemIdentifier: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "item", subject: itemIdentifier)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.snapshot(identifier: itemIdentifier)
                call.finish("ok")
                reply(snapshot, nil)
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    // MARK: Transfers

    func fetchContents(
        domainIdentifier: String, itemIdentifier: String, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool,
        into destination: FileHandle, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "fetchContents", subject: itemIdentifier,
                isSystemRequest: isSystemRequest)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.fetchContents(
                    identifier: itemIdentifier, into: destination, transferID: transferID,
                    kind: AgentService.transferClass(
                        isFileViewerRequest: isFileViewerRequest, isSystemRequest: isSystemRequest),
                    progress: progressReporter(transferID: transferID))
                peer?.transferProgress(
                    transferID: transferID, bytesCompleted: snapshot.size, bytesTotal: snapshot.size)
                call.finish("\(snapshot.size) bytes")
                reply(snapshot, nil)
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    /// Section 6.2: "foreground transfers come first: a `fetchContents` whose
    /// `NSFileProviderRequest` is a file-viewer request or is not a system request (an app
    /// or the user opening the file...)". Everything else - the eager downloads of a kept
    /// subtree (section 7.1) and anything the system issues on its own - is background.
    static func transferClass(isFileViewerRequest: Bool, isSystemRequest: Bool)
        -> TransferScheduler.Kind
    {
        (isFileViewerRequest || !isSystemRequest) ? .foreground : .background
    }

    /// Byte counts through the callback on the extension's exported object, which the
    /// extension forwards to the `Progress` it returned to the system (section 5.2).
    private func progressReporter(transferID: String) -> @Sendable (Int64, Int64) -> Void {
        let peer = self.peer
        return { completed, total in
            peer?.transferProgress(
                transferID: transferID, bytesCompleted: completed, bytesTotal: total)
        }
    }

    func fetchPartialContents(
        domainIdentifier: String, itemIdentifier: String, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "fetchPartialContents", subject: itemIdentifier)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.fetchPartialContents(
                    identifier: itemIdentifier, offset: offset, length: length,
                    into: destination, transferID: transferID,
                    progress: progressReporter(transferID: transferID))
                call.finish("ok")
                reply(snapshot, nil)
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func createItem(
        domainIdentifier: String, parentIdentifier: String, filename: String, isDirectory: Bool,
        symlinkTarget: String?, fileSystemFlags: NSNumber?, modificationDate: NSNumber?,
        extendedAttributes: [String: Data]?, tagData: Data?, contents: FileHandle?,
        transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "createItem", subject: filename)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.createItem(
                    parentIdentifier: parentIdentifier,
                    filename: filename,
                    isDirectory: isDirectory,
                    symlinkTarget: symlinkTarget,
                    fileSystemFlags: fileSystemFlags?.uint64Value,
                    modificationDate: modificationDate.map { Int64($0.doubleValue) },
                    extendedAttributes: extendedAttributes,
                    tagData: tagData,
                    contents: contents,
                    transferID: transferID,
                    progress: progressReporter(transferID: transferID))
                call.finish("created")
                reply(snapshot, nil)
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func modifyItem(
        domainIdentifier: String, itemIdentifier: String, baseVersion: String?,
        changedFields: UInt64, newParentIdentifier: String?, newFilename: String?,
        newFileSystemFlags: NSNumber?, newModificationDate: NSNumber?,
        newExtendedAttributes: [String: Data]?, newTagData: Data?, newSymlinkTarget: String?,
        contents: FileHandle?, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "modifyItem", subject: itemIdentifier)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let result = try await runtime.modifyItem(
                    identifier: itemIdentifier,
                    changedFields: NSFileProviderItemFields(rawValue: UInt(changedFields)),
                    baseVersion: baseVersion,
                    newParentIdentifier: newParentIdentifier,
                    newFilename: newFilename,
                    newFileSystemFlags: newFileSystemFlags?.uint64Value,
                    newModificationDate: newModificationDate.map { Int64($0.doubleValue) },
                    newExtendedAttributes: newExtendedAttributes,
                    newTagData: newTagData,
                    newSymlinkTarget: newSymlinkTarget,
                    contents: contents,
                    transferID: transferID,
                    progress: progressReporter(transferID: transferID))
                call.finish(result.evictAfterReply ? "conflict copy" : "modified")
                reply(result.snapshot, nil)
                // Section 5.5, and S3's finding that a `modifyItem` reply is believed: a
                // conflict copy is only half done when the remote item has been returned.
                // The eviction is what makes the next open download the remote content,
                // and it must come *after* the reply, or the system records the version
                // it was about to evict.
                if result.evictAfterReply {
                    // The conflict copy is a new sibling with an anchor of its own; the
                    // signal is what makes the system read that anchor, so Finder shows
                    // the copy at once rather than at the next enumeration (section 5.5).
                    await DomainManager.shared.signalWorkingSet(locationID: domainIdentifier)
                    await SpikeHooks.evictAfterConflict(
                        locationID: domainIdentifier, identifier: itemIdentifier)
                }
            } catch {
                call.finish(error: error)
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func deleteItem(
        domainIdentifier: String, itemIdentifier: String, baseVersion: String?, recursive: Bool,
        reply: @escaping (Error?) -> Void
    ) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "deleteItem", subject: itemIdentifier)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                try await runtime.deleteItem(identifier: itemIdentifier, recursive: recursive)
                call.finish("deleted")
                reply(nil)
            } catch {
                call.finish(error: error)
                reply(sshDriveXPCError(error))
            }
        }
    }

    func cancelTransfer(transferID: String) {
        Task {
            // A transfer id is a fresh UUID per call and the XPC method carries no domain,
            // so the cancel goes to every started runtime; each scheduler ignores an id it
            // does not hold. Only runtimes that are already up are asked, so a cancel
            // never connects a location (section 5.2).
            for runtime in await DomainManager.shared.startedRuntimes() {
                await runtime.cancel(transferID: transferID)
            }
        }
    }

    // MARK: Signals

    func materializedItemsDidChange(domainIdentifier: String) {
        // Section 6.5: the `materialized` reason is "every directory that contains at
        // least one materialized file, from enumeratorForMaterializedItems() refreshed on
        // materializedItemsDidChange". Milestone 8's pin safety net (section 7.2) hangs
        // off the same signal.
        Log.agent.debug("materializedItemsDidChange for \(domainIdentifier, privacy: .public)")
        Task { await DomainManager.shared.materializedItemsChanged(locationID: domainIdentifier) }
    }

    func workingSetAnchorExpired(domainIdentifier: String, freshAnchor: String) {
        Task {
            // Section 4.2's second re-arm trigger: a File Provider request for this
            // domain. Behind the presence test and its once-a-minute rule, so it is
            // cheap enough to sit on every request. The `CallTiming` it hands back is
            // spike S5's journal: arrival, outcome and the gap since the previous call
            // of the same kind, which is what every "how long does the system wait"
            // question in the S5 row is asking for.
            let call = DomainManager.shared.noteFileProviderRequest(
                domainIdentifier: domainIdentifier, method: "workingSetAnchorExpired", subject: freshAnchor)
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                // Section 5.3: "the agent treats handing out a fresh working-set anchor
                // exactly as it treats a reconnect: it runs one full sweep of the root set
                // at once, and every difference from the index becomes an anchor after the
                // fresh one". The detector's next cycle is that sweep; the catch-up walk
                // below is the immediate half, so a fresh anchor is never left waiting for
                // the cadence.
                await DomainManager.shared.requestFullSweep(
                    locationID: domainIdentifier, reason: "working-set anchor expired")
                let changes = try await runtime.runCatchUpSweep()
                call.finish("\(changes) change(s)")
                Log.agent.notice(
                    "catch-up sweep after an anchor expiry found \(changes, privacy: .public) change(s)")
                if changes > 0 {
                    await DomainManager.shared.signalWorkingSet(locationID: domainIdentifier)
                }
            } catch {
                call.finish(error: error)
                Log.agent.error("catch-up sweep failed: \(error, privacy: .public)")
            }
        }
    }

    func performAction(
        domainIdentifier: String, actionIdentifier: String, itemIdentifiers: [String],
        reply: @escaping (Error?) -> Void
    ) {
        // TODO milestone 8: pin and unpin (section 7.2).
        reply(SSHDriveAgentError.notImplemented.asNSError("Custom actions: milestone 8."))
    }

    // MARK: CLI

    func control(
        command: String, arguments: [String: String], reply: @escaping (Data?, Error?) -> Void
    ) {
        // The terminal, captured while the method is still on the connection: `add` and
        // `passwd` relay the collect connection's prompts back along it (section 4.2).
        let relay = CLIRelay(connection: connection)
        Task {
            do {
                reply(
                    try await ControlCommands.run(
                        command: command, arguments: arguments, relay: relay),
                    nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }
}
