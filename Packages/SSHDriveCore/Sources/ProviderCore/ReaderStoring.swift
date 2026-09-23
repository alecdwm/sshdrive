import Foundation

/// One page of the working-set change stream as the reader answers it.
public struct ReaderChangePage: Equatable, Sendable {
    public var items: [ItemView]
    public var deleted: [ProviderItemIdentifier]
    public var newAnchor: Int64
    public var hasMore: Bool

    public init(
        items: [ItemView], deleted: [ProviderItemIdentifier], newAnchor: Int64, hasMore: Bool
    ) {
        self.items = items
        self.deleted = deleted
        self.newAnchor = newAnchor
        self.hasMore = hasMore
    }
}

/// The extension's own read-only view of the domain's index (docs/design/extension.md), as
/// a protocol so a scenario can hand the provider a reader that is deliberately not usable.
///
/// **Every method that cannot answer returns nil rather than throwing**, because the
/// caller has somewhere else to go: the agent has the same rows. The only errors that
/// travel are the two that are real answers rather than failures of this reader -
/// `.noSuchItem` about a real identifier and `.syncAnchorExpired` about the anchor the
/// system holds.
public protocol ReaderStoring: AnyObject {
    /// What `doctor` and the log call the reader's state: `ready`, `not-ready`,
    /// `schema-too-new`, `closed`, `failed`, `exited`, `unknown`.
    var stateName: String { get }
    var isReady: Bool { get }

    /// The agent's answer to `indexReady`; `nil` means it could not be reached at all.
    func markReady(_ ready: Bool?)
    /// Shut for the truncate window of a restore (docs/design/item-index.md).
    func close()
    func reopen()
    /// The system is tearing the extension instance down: the handle is closed and the
    /// state file says `exited`, which `doctor` does not warn about.
    func shutdown()

    /// One row, or nil when the reader is not usable and the caller should ask the agent.
    func item(identifier: ProviderItemIdentifier) throws -> ItemView?
    /// The change stream, or nil for the same reason.
    func changes(since anchor: Int64, limit: Int) throws -> ReaderChangePage?
    func currentSequence() -> Int64?

    /// How the store asks the agent again. Set by the provider, which owns the channel.
    var askAgent: ((@escaping (Bool?) -> Void) -> Void)? { get set }
}

extension ReaderStoring {
    public func changes(since anchor: Int64) throws -> ReaderChangePage? {
        try changes(since: anchor, limit: 500)
    }
}
