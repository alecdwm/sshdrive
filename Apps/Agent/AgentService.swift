import Foundation
import FileProvider
import Index
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
                let items = try await runtime.enumerateItems(container: containerIdentifier)
                let anchor = try await runtime.currentSequence()
                // TODO milestone 3: page directories with tens of thousands of entries
                // (section 5.2). The fake backend's trees are small.
                reply(SSHDriveItemPage(items: items, anchor: String(anchor)), nil)
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
        into destination: FileHandle, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        Task {
            do {
                let runtime = try await DomainManager.shared.runtime(domainIdentifier: domainIdentifier)
                let snapshot = try await runtime.fetchContents(
                    identifier: itemIdentifier, into: destination, transferID: transferID)
                peer?.transferProgress(
                    transferID: transferID, bytesCompleted: snapshot.size, bytesTotal: snapshot.size)
                reply(snapshot, nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }

    func fetchPartialContents(
        domainIdentifier: String, itemIdentifier: String, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    ) {
        // TODO milestone 3: range requests for large media (section 5.1). Until then the
        // extension does not offer fetchPartialContents at all, so this is unreachable.
        reply(nil, SSHDriveAgentError.notImplemented.asNSError("Partial fetches: milestone 3."))
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
                    contents: contents)
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
                    contents: contents)
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
            // The transfer id is unique per domain, so the cancel is broadcast; milestone
            // 3's scheduler keeps a table and this becomes a direct lookup (section 6.2).
            guard let file = try? await DomainManager.shared.configuration() else { return }
            for location in file.locations {
                guard let runtime = try? await DomainManager.shared.runtime(for: location) else { continue }
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

    // MARK: askpass

    func askpassAnswer(
        token: String, promptKind: String, prompt: String,
        reply: @escaping (String?, Error?) -> Void
    ) {
        // TODO milestone 2: mint one-time tokens per ssh process, match this one, and
        // answer from the keychain or by relaying the prompt to the CLI (section 4.2).
        Log.agent.notice("askpass asked for a \(promptKind, privacy: .public) prompt; milestone 2")
        reply(nil, SSHDriveAgentError.notImplemented.asNSError("askpass: milestone 2."))
    }

    // MARK: CLI

    func control(
        command: String, arguments: [String: String], reply: @escaping (Data?, Error?) -> Void
    ) {
        Task {
            do {
                reply(try await ControlCommands.run(command: command, arguments: arguments), nil)
            } catch {
                reply(nil, sshDriveXPCError(error))
            }
        }
    }
}
