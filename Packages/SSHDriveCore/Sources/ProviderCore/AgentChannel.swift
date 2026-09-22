import Foundation

/// One page of an enumeration or a change stream, as it crosses the channel.
public struct ProviderItemPage: Equatable, Sendable {
    public var items: [ItemView]
    public var deletedIdentifiers: [ProviderItemIdentifier]
    public var nextPageToken: ProviderPageToken?
    /// The anchor to hand the system after this page. Empty for a plain listing.
    public var anchor: String
    public var moreComing: Bool

    public init(
        items: [ItemView] = [],
        deletedIdentifiers: [ProviderItemIdentifier] = [],
        nextPageToken: ProviderPageToken? = nil,
        anchor: String = "",
        moreComing: Bool = false
    ) {
        self.items = items
        self.deletedIdentifiers = deletedIdentifiers
        self.nextPageToken = nextPageToken
        self.anchor = anchor
        self.moreComing = moreComing
    }
}

/// The extension's whole view of the agent (docs/design/testing.md).
///
/// Three implementations: the real NSXPC proxy in `Apps/FileProvider`, an in-process
/// loopback onto the agent, and the `SystemModel`'s scripted one. Failure is a
/// `ProviderFailure` in every case, so the mapping from the agent's own error codes happens
/// once, at the edge, and the decisions above it are written against one type.
///
/// An agent that cannot be reached at all answers `.serverUnreachable` - and that is the
/// only thing that may: a reader that is merely not ready has the agent to fall back on,
/// and answering the system otherwise is what took a real domain's event stream to a
/// 47-minute retry (`MQ-005`).
public protocol AgentChannel: AnyObject {

    // MARK: Handshake

    /// `true` ready, `false` not ready, `nil` the agent could not be reached at all - which
    /// leaves the instance free to open the reader, since a missing agent is the case the
    /// direct reader exists for.
    func indexReady(_ completion: @escaping (Bool?) -> Void)

    // MARK: Enumeration

    func enumerateItems(
        container: ProviderItemIdentifier, pageToken: ProviderPageToken?,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void)

    func enumerateChanges(
        container: ProviderItemIdentifier, anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void)

    /// The fallback path for the working set, used whenever the extension's own reader is
    /// not usable. Both sides run `IndexChangeStream`, so the reader's answer and the
    /// agent's cannot drift.
    func enumerateWorkingSetChanges(
        anchor: ProviderSyncAnchor,
        _ completion: @escaping (Result<ProviderItemPage, ProviderFailure>) -> Void)

    /// The newest sync anchor, for `currentSyncAnchor` when the reader cannot answer.
    /// `nil` when the agent could not answer either.
    func currentAnchor(_ completion: @escaping (String?) -> Void)

    func item(
        identifier: ProviderItemIdentifier,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void)

    // MARK: Transfers

    func fetchContents(
        identifier: ProviderItemIdentifier, requestedVersion: String?,
        isFileViewerRequest: Bool, isSystemRequest: Bool, into destination: FileHandle,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void)

    func fetchPartialContents(
        identifier: ProviderItemIdentifier, offset: Int64, length: Int64,
        into destination: FileHandle, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void)

    // MARK: Mutations

    func createItem(
        template: ItemTemplate, contents: FileHandle?, transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void)

    func modifyItem(
        identifier: ProviderItemIdentifier, baseVersion: String?,
        changedFields: ProviderItemFields, changes: ItemChanges, contents: FileHandle?,
        transferID: String,
        _ completion: @escaping (Result<ItemView, ProviderFailure>) -> Void)

    func deleteItem(
        identifier: ProviderItemIdentifier, baseVersion: String?, recursive: Bool,
        _ completion: @escaping (ProviderFailure?) -> Void)

    func cancelTransfer(transferID: String)

    // MARK: Signals to the agent

    /// Forwarded so the agent can refresh its root set (docs/design/root-set.md) and the
    /// pin safety net (docs/design/pinning.md).
    func materializedItemsDidChange()

    /// The extension answered `.syncAnchorExpired` and handed out a fresh anchor. The
    /// agent's response is one full sweep of the root set (docs/design/item-index.md).
    func workingSetAnchorExpired(freshAnchor: String)

    /// The two Finder entries (docs/design/pinning.md). The extension holds no state and
    /// cannot write the index, so the action is forwarded to the one writer.
    func performAction(
        actionIdentifier: String, itemIdentifiers: [ProviderItemIdentifier],
        _ completion: @escaping (ProviderFailure?) -> Void)
}
