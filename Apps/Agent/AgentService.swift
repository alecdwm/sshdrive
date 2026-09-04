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
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                _ = try await runtime.currentSequence()
                reply(true)
            } catch {
                // An agent mid-restore, or one that cannot open the index at all, answers
                // no and the instance opens nothing (section 5.3).
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
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                // Section 5.2: paged for directories with tens of thousands of entries.
                // A page token is an offset into a listing the agent already holds, so a
                // second page never re-lists the directory.
                let page = try await runtime.enumerateItems(
                    container: containerIdentifier, pageToken: pageToken)
                let anchor = try await runtime.currentSequence()
                reply(
                    SSHDriveItemPage(
                        items: page.items, nextPageToken: page.nextPageToken,
                        anchor: String(anchor)), nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func enumerateChanges(
        domainIdentifier: String, containerIdentifier: String, anchor: String,
        reply: @escaping (SSHDriveItemPage?, Error?) -> Void
    ) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let result = try await runtime.enumerateChanges(container: containerIdentifier)
                let sequence = try await runtime.currentSequence()
                reply(
                    SSHDriveItemPage(
                        items: result.items, deletedIdentifiers: result.deleted,
                        anchor: String(sequence)), nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func item(
        domainIdentifier: String, itemIdentifier: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                reply(try await runtime.snapshot(identifier: itemIdentifier), nil)
            } catch {
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
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.fetchContents(
                    identifier: itemIdentifier, into: destination, transferID: transferID,
                    kind: AgentService.transferClass(
                        isFileViewerRequest: isFileViewerRequest, isSystemRequest: isSystemRequest),
                    progress: progressReporter(transferID: transferID))
                peer?.transferProgress(
                    transferID: transferID, bytesCompleted: snapshot.size, bytesTotal: snapshot.size)
                reply(snapshot, nil)
            } catch {
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
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.fetchPartialContents(
                    identifier: itemIdentifier, offset: offset, length: length,
                    into: destination, transferID: transferID,
                    progress: progressReporter(transferID: transferID))
                reply(snapshot, nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func createItem(
        domainIdentifier: String, parentIdentifier: String, filename: String, isDirectory: Bool,
        symlinkTarget: String?, contents: FileHandle?, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.createItem(
                    parentIdentifier: parentIdentifier,
                    filename: filename,
                    isDirectory: isDirectory,
                    symlinkTarget: symlinkTarget,
                    contents: contents,
                    transferID: transferID,
                    progress: progressReporter(transferID: transferID))
                reply(snapshot, nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func modifyItem(
        domainIdentifier: String, itemIdentifier: String, baseVersion: String?,
        changedFields: UInt64, newParentIdentifier: String?, newFilename: String?,
        newFileSystemFlags: NSNumber?, newModificationDate: NSNumber?,
        newExtendedAttributes: [String: Data]?, contents: FileHandle?, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.modifyItem(
                    identifier: itemIdentifier,
                    changedFields: NSFileProviderItemFields(rawValue: UInt(changedFields)),
                    newParentIdentifier: newParentIdentifier,
                    newFilename: newFilename,
                    newExtendedAttributes: newExtendedAttributes,
                    contents: contents,
                    transferID: transferID,
                    progress: progressReporter(transferID: transferID))
                reply(snapshot, nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func deleteItem(
        domainIdentifier: String, itemIdentifier: String, baseVersion: String?, recursive: Bool,
        reply: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                try await runtime.deleteItem(identifier: itemIdentifier, recursive: recursive)
                reply(nil)
            } catch {
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
        // TODO milestone 6: refresh the `materialized` reason of the root set from
        // enumeratorForMaterializedItems() (section 6.5), and milestone 8's pin safety
        // net (section 7.2).
        Log.agent.debug("materializedItemsDidChange for \(domainIdentifier, privacy: .public)")
    }

    func workingSetAnchorExpired(domainIdentifier: String, freshAnchor: String) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let changes = try await runtime.runCatchUpSweep()
                Log.agent.notice(
                    "catch-up sweep after an anchor expiry found \(changes, privacy: .public) change(s)")
                if changes > 0 {
                    await DomainManager.shared.signalWorkingSet(locationID: domainIdentifier)
                }
            } catch {
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
