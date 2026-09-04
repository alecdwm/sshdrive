import Foundation

/// Version of the XPC interface. A mismatched agent and extension (mid upgrade) is
/// reported as `.serverUnreachable` until the agent restarts (DESIGN.md section 5.2).
public let sshDriveXPCInterfaceVersion = 1

/// The agent's interface, exported to the extension, the CLI and askpass alike. One
/// interface rather than three keeps the peer check in one place; what a peer may
/// usefully call is decided by its signing identifier, which the listener has already
/// validated.
///
/// Every method is a request to the agent. The extension answers `item(for:)` and the
/// working-set change stream from the index itself and calls none of these on that path
/// (section 5.2).
@objc public protocol SSHDriveAgentProtocol {

    // MARK: Handshake

    /// Interface version negotiation. The reply carries the agent's version; a caller
    /// whose own version differs treats the agent as unreachable.
    func ping(interfaceVersion: Int, reply: @escaping (Int) -> Void)

    /// Asked once per extension instance launch, before it opens the index reader
    /// (section 5.3). An agent mid-restore answers false, and the instance serves
    /// `.serverUnreachable` and opens nothing until `reopenIndexReader` arrives.
    func indexReady(domainIdentifier: String, reply: @escaping (Bool) -> Void)

    // MARK: Enumeration

    /// `opendir`/`readdir` the mapped path, reconcile with the index, return items.
    /// Records the folder as recently viewed (section 6.5).
    @objc(enumerateItemsInDomain:container:pageToken:reply:)
    func enumerateItems(
        domainIdentifier: String,
        containerIdentifier: String,
        pageToken: String?,
        reply: @escaping (SSHDriveItemPage?, Error?) -> Void
    )

    /// The same listing, diffed against the index. This is how a folder refreshes when
    /// Finder shows it (S3 confirms the system asks).
    @objc(enumerateChangesInDomain:container:anchor:reply:)
    func enumerateChanges(
        domainIdentifier: String,
        containerIdentifier: String,
        anchor: String,
        reply: @escaping (SSHDriveItemPage?, Error?) -> Void
    )

    /// The fallback path for `item(for:)`: used when the extension has no reader, or
    /// found a schema version newer than it understands (section 5.2).
    @objc(itemInDomain:identifier:reply:)
    func item(
        domainIdentifier: String,
        itemIdentifier: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    )

    // MARK: Transfers

    /// The extension creates the target file in its own temp directory, opens it for
    /// writing and sends the handle; the agent writes through it (section 5.2).
    @objc(fetchContentsInDomain:identifier:requestedVersion:into:transferID:reply:)
    func fetchContents(
        domainIdentifier: String,
        itemIdentifier: String,
        requestedVersion: String?,
        into destination: FileHandle,
        transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    )

    /// A range request, for large media (`fetchPartialContents`).
    @objc(fetchPartialContentsInDomain:identifier:offset:length:into:transferID:reply:)
    func fetchPartialContents(
        domainIdentifier: String,
        itemIdentifier: String,
        offset: Int64,
        length: Int64,
        into destination: FileHandle,
        transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    )

    /// `mkdir`, `symlink`, or upload-to-temp plus a non-overwriting rename into place.
    /// `contents` is nil for a directory or a symlink.
    @objc(createItemInDomain:parent:filename:isDirectory:symlinkTarget:contents:transferID:reply:)
    func createItem(
        domainIdentifier: String,
        parentIdentifier: String,
        filename: String,
        isDirectory: Bool,
        symlinkTarget: String?,
        contents: FileHandle?,
        transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    )

    /// Rename/move, content, attributes or extended attributes, per `changedFields`
    /// (the raw value of NSFileProviderItemFields).
    @objc(modifyItemInDomain:identifier:baseVersion:changedFields:newParent:newFilename:newFileSystemFlags:newModificationDate:newExtendedAttributes:contents:transferID:reply:)
    func modifyItem(
        domainIdentifier: String,
        itemIdentifier: String,
        baseVersion: String?,
        changedFields: UInt64,
        newParentIdentifier: String?,
        newFilename: String?,
        newFileSystemFlags: NSNumber?,
        newModificationDate: NSNumber?,
        newExtendedAttributes: [String: Data]?,
        contents: FileHandle?,
        transferID: String,
        reply: @escaping (SSHDriveItemSnapshot?, Error?) -> Void
    )

    /// `remove`, or `rmdir` after a server-side depth-first walk when recursive.
    func deleteItem(
        domainIdentifier: String,
        itemIdentifier: String,
        baseVersion: String?,
        recursive: Bool,
        reply: @escaping (Error?) -> Void
    )

    /// Cancelling the Progress the extension returned, or the extension's connection
    /// invalidating, abandons the SFTP requests in flight (section 5.2).
    func cancelTransfer(transferID: String)

    // MARK: Signals from the extension

    /// Forwarded so the agent can refresh its root set (section 6.5) and the pin safety
    /// net (section 7.2).
    func materializedItemsDidChange(domainIdentifier: String)

    /// The extension answered `.syncAnchorExpired` and handed out a fresh anchor. The
    /// agent's response is one full sweep of the root set (section 5.3).
    func workingSetAnchorExpired(domainIdentifier: String, freshAnchor: String)

    /// Finder context-menu entries. Pin and unpin, milestone 8.
    @objc(performActionInDomain:action:itemIdentifiers:reply:)
    func performAction(
        domainIdentifier: String,
        actionIdentifier: String,
        itemIdentifiers: [String],
        reply: @escaping (Error?) -> Void
    )

    // The askpass path is deliberately NOT on this interface. `sshdrive-askpass` is
    // handed `SSHDriveAskpassProtocol` and nothing else (AskpassProtocol.swift,
    // AskpassService.register), so the process that relays ssh's prompts cannot remove a
    // location or evict a cache, and the processes that can do those cannot ask for a
    // secret (section 4.2, section 5.2).

    // MARK: CLI

    /// The CLI's single channel. `command` is the subcommand path ("doctor",
    /// "debug.mutate", ...), `arguments` its flags, and the reply is JSON. Keeping the
    /// CLI to one method means a new subcommand does not change the interface version.
    @objc(controlCommand:arguments:reply:)
    func control(
        command: String,
        arguments: [String: String],
        reply: @escaping (Data?, Error?) -> Void
    )
}
