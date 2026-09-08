import Foundation
import ProviderCore

/// One item as the system's replica holds it.
///
/// The replica is the system's copy, not ours: what Finder shows, what `ls` answers
/// (`MQ-039`), and what a scenario asserts on. It records the version the provider
/// **returned**, because the system believes whatever version a reply carries and never
/// re-fetches to check (`MQ-013`).
public struct ReplicaItem: Equatable, Sendable {
    public var identifier: ProviderItemIdentifier
    public var parentIdentifier: ProviderItemIdentifier
    public var filename: String
    public var isDirectory: Bool
    public var size: Int64
    public var contentVersion: String
    public var metadataVersion: String
    public var contentPolicy: ProviderContentPolicy
    public var kept: Bool
    /// Whether the bytes are on disk. Nothing in step 1.3 downloads; it is here because
    /// the eviction rules of step 5 read it and Finder's own two menu entries follow it
    /// and nothing else (`MQ-053`).
    public var isDownloaded: Bool

    public init(view: ItemView) {
        self.identifier = view.identifier
        self.parentIdentifier = view.parentIdentifier
        self.filename = view.filename
        self.isDirectory = view.contentTypeHint == .folder
        self.size = view.documentSize ?? 0
        self.contentVersion = view.contentVersion
        self.metadataVersion = view.metadataVersion
        self.contentPolicy = view.contentPolicy
        self.kept = view.kept
        self.isDownloaded = false
    }
}

/// The domain's replica: the tree of items the system holds, keyed by identifier.
public final class Replica {
    private var items: [ProviderItemIdentifier: ReplicaItem] = [:]

    public init() {}

    /// `MQ-013`: the version the provider returned is recorded as it stands. The model
    /// never re-reads it from anywhere and never asks again.
    public func ingest(_ view: ItemView) {
        items[view.identifier] = ReplicaItem(view: view)
    }

    public func remove(_ identifier: ProviderItemIdentifier) {
        items.removeValue(forKey: identifier)
    }

    public func item(_ identifier: ProviderItemIdentifier) -> ReplicaItem? {
        items[identifier]
    }

    public func contains(_ identifier: ProviderItemIdentifier) -> Bool {
        items[identifier] != nil
    }

    /// The names in one container, which is what a `ls` of that folder shows. Answered
    /// from the replica and never from the extension (`MQ-039`).
    public func listing(of container: ProviderItemIdentifier) -> [String] {
        items.values.filter { $0.parentIdentifier == container }.map(\.filename).sorted()
    }

    public var allIdentifiers: Set<ProviderItemIdentifier> { Set(items.keys) }
    public var count: Int { items.count }
    public var filenames: [String] { items.values.map(\.filename).sorted() }
}
