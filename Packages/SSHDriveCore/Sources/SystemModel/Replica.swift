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
    public var isSymlink: Bool
    /// The target the system wrote into the real symlink it made under CloudStorage
    /// (`MQ-076`); a dangling one is indistinguishable from a live one (`MQ-077`).
    public var symlinkTarget: String?
    public var size: Int64
    public var contentVersion: String
    public var metadataVersion: String
    /// The policy the item was served. The **effective** one - this or the nearest
    /// ancestor's - is what refuses an eviction (`MQ-024`), and `Replica` computes that.
    public var contentPolicy: ProviderContentPolicy
    public var kept: Bool
    /// Whether the bytes are on disk. Finder's own two menu entries follow it and nothing
    /// else (`MQ-053`), and so does the `allowsEvicting` bit the system reports back
    /// whatever we serve (`MQ-025`).
    public var isDownloaded: Bool
    /// The whole xattr set the replica holds, including the names the extension is never
    /// told about (`MQ-044`). They survive an eviction (`MQ-045`).
    public var extendedAttributes: [String: Data] = [:]
    /// Finder tags, which are never an xattr (`MQ-042`) and are rebuilt from the item's
    /// own `tagData` on a re-download - so an item that returns none loses them
    /// (`MQ-043`).
    public var tagData: Data?
    public var atime: Double = 0
    public var mtime: Double = 0
    /// When the bytes last came down, which is what the TTL is measured from and what the
    /// deferred atime advance is scheduled off (`MQ-022`).
    public var lastFetch: Double?
    /// The trash node the system makes for itself (`MQ-075`), and anything else it owns.
    public var isSystemOwned = false
    /// A local-only item the system keeps and never asks anyone to upload - `.DS_Store`
    /// is the measured one (`MQ-046`).
    public var isLocalOnly = false
    /// The last error a write of this item came back with, which is where a refused
    /// `ln -s` surfaces and the only place the user can be told (`MQ-078`).
    public var uploadingErrorCode: Int?

    public init(view: ItemView) {
        self.identifier = view.identifier
        self.parentIdentifier = view.parentIdentifier
        self.filename = view.filename
        self.isDirectory = view.contentTypeHint == .folder
        self.isSymlink = view.contentTypeHint == .symbolicLink
        self.symlinkTarget = view.symlinkTargetPath
        self.size = view.documentSize ?? 0
        self.contentVersion = view.contentVersion
        self.metadataVersion = view.metadataVersion
        self.contentPolicy = view.contentPolicy
        self.kept = view.kept
        self.isDownloaded = false
        self.extendedAttributes = view.extendedAttributes
        self.tagData = view.tagData
        self.mtime = view.contentModificationDate
    }

    /// A locally created item: the user's write lands in the replica first and is offered
    /// to the provider afterwards, which is why an offline write "just queues".
    public init(
        identifier: ProviderItemIdentifier, parent: ProviderItemIdentifier, filename: String,
        isDirectory: Bool = false, isSymlink: Bool = false, symlinkTarget: String? = nil,
        size: Int64 = 0, now: Double = 0
    ) {
        self.identifier = identifier
        self.parentIdentifier = parent
        self.filename = filename
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.size = size
        self.contentVersion = ""
        self.metadataVersion = ""
        self.contentPolicy = .unset
        self.kept = false
        self.isDownloaded = !isDirectory
        self.atime = now
        self.mtime = now
        self.lastFetch = isDirectory ? nil : now
    }

    /// `MQ-025`: the capability we serve is ignored and the bit the system reports follows
    /// `isDownloaded`. A scenario reads this rather than the served capabilities, because
    /// the served ones are not what the menu is driven from.
    public var reportsAllowsEvicting: Bool { isDownloaded }
}

/// The domain's replica: the tree of items the system holds, keyed by identifier.
public final class Replica {
    private var items: [ProviderItemIdentifier: ReplicaItem] = [:]

    /// How many items the system was told about and could not place, because their parent
    /// was not in the replica. That is `MQ-029` in one number: a working-set report of an
    /// unseen ancestor chain ingests nothing, and only a path lookup starts it.
    public private(set) var droppedForUnknownParent = 0

    public init() {}

    /// `MQ-013`: the version the provider returned is recorded as it stands. The model
    /// never re-reads it from anywhere and never asks again.
    ///
    /// `MQ-029`: an item whose parent the replica does not hold is **not** ingested. The
    /// system has nowhere to put it, which is why reporting a new ancestor chain through
    /// the working set starts no download and why the pin path needs the replica lookup.
    public func ingest(_ view: ItemView) {
        guard canPlace(view) else {
            droppedForUnknownParent += 1
            return
        }
        if var existing = items[view.identifier] {
            let fresh = ReplicaItem(view: view)
            // Local state the system keeps across an update: the bytes, when they came
            // down, and the atime the filesystem owns.
            existing.parentIdentifier = fresh.parentIdentifier
            existing.filename = fresh.filename
            existing.isDirectory = fresh.isDirectory
            existing.isSymlink = fresh.isSymlink
            existing.symlinkTarget = fresh.symlinkTarget
            existing.size = fresh.size
            existing.contentVersion = fresh.contentVersion
            existing.metadataVersion = fresh.metadataVersion
            existing.contentPolicy = fresh.contentPolicy
            existing.kept = fresh.kept
            existing.mtime = fresh.mtime
            // `MQ-043`: the tags xattr is rebuilt from the item's own `tagData`, so an
            // item that returns none leaves the replica's copy alone here and loses it on
            // the next re-download, which is what `evict` below models.
            if let tagData = view.tagData { existing.tagData = tagData }
            // `MQ-044`: only the syncable names cross, so an update carries a subset and
            // must not delete the rest.
            for (name, value) in view.extendedAttributes { existing.extendedAttributes[name] = value }
            items[view.identifier] = existing
            return
        }
        items[view.identifier] = ReplicaItem(view: view)
    }

    private func canPlace(_ view: ItemView) -> Bool {
        view.identifier == .rootContainer || view.parentIdentifier == .rootContainer
            || items[view.parentIdentifier] != nil
    }

    /// An item the user made locally. It exists in the mount before anyone has been asked
    /// about it, which is the whole of "an offline write just queues".
    public func insertLocal(_ item: ReplicaItem) {
        items[item.identifier] = item
    }

    public func update(_ item: ReplicaItem) {
        items[item.identifier] = item
    }

    public func mutate(_ identifier: ProviderItemIdentifier, _ body: (inout ReplicaItem) -> Void) {
        guard var item = items[identifier] else { return }
        body(&item)
        items[identifier] = item
    }

    /// The identifier the provider minted for an item the system created locally. The
    /// system keeps the user's file and re-keys it; nothing is re-downloaded.
    public func reidentify(from old: ProviderItemIdentifier, to new: ProviderItemIdentifier) {
        guard old != new, var item = items.removeValue(forKey: old) else { return }
        item.identifier = new
        items[new] = item
        for (key, child) in items where child.parentIdentifier == old {
            items[key]?.parentIdentifier = new
        }
    }

    public func remove(_ identifier: ProviderItemIdentifier) {
        for child in children(of: identifier) { remove(child.identifier) }
        items.removeValue(forKey: identifier)
    }

    public func item(_ identifier: ProviderItemIdentifier) -> ReplicaItem? {
        items[identifier]
    }

    public func contains(_ identifier: ProviderItemIdentifier) -> Bool {
        items[identifier] != nil
    }

    public func children(of container: ProviderItemIdentifier) -> [ReplicaItem] {
        items.values.filter { $0.parentIdentifier == container && $0.identifier != container }
            .sorted { $0.filename < $1.filename }
    }

    /// Everything under a container, the container excluded - which is the set an
    /// `evictItem` on it touches (`MQ-020`).
    public func descendants(of container: ProviderItemIdentifier) -> [ReplicaItem] {
        children(of: container).flatMap { [$0] + descendants(of: $0.identifier) }
    }

    public func ancestors(of identifier: ProviderItemIdentifier) -> [ReplicaItem] {
        var chain: [ReplicaItem] = []
        var seen: Set<ProviderItemIdentifier> = [identifier]
        var cursor = items[identifier]?.parentIdentifier
        // The root's parent is the root, so the walk stops on the first repeat rather
        // than on a nil.
        while let next = cursor, !seen.contains(next), let parent = items[next] {
            chain.append(parent)
            seen.insert(next)
            cursor = parent.parentIdentifier
        }
        return chain
    }

    /// The effective content policy as the *system* resolves it (docs/design/pinning.md):
    /// the nearest explicit value at or above the item. `.unset` and `.inherited` are
    /// both "say nothing" (`MQ-026`), and an explicit `.downloadLazily` on a child beats
    /// an eager ancestor (`MQ-027`) because it is nearer.
    public func effectivePolicy(of identifier: ProviderItemIdentifier) -> ProviderContentPolicy {
        var cursor: ProviderItemIdentifier? = identifier
        while let current = cursor, let item = items[current] {
            if item.contentPolicy == .downloadEagerlyAndKeepDownloaded
                || item.contentPolicy == .downloadLazily
            {
                return item.contentPolicy
            }
            cursor = item.parentIdentifier == current ? nil : item.parentIdentifier
        }
        return .inherited
    }

    /// The mount-relative path, which is what `getUserVisibleURL` answers and what a
    /// scenario names an item by.
    public func path(of identifier: ProviderItemIdentifier) -> String? {
        guard identifier != .rootContainer else { return "" }
        guard let item = items[identifier] else { return nil }
        guard let parent = path(of: item.parentIdentifier) else { return nil }
        return parent.isEmpty ? item.filename : parent + "/" + item.filename
    }

    public func identifier(atPath path: String) -> ProviderItemIdentifier? {
        guard !path.isEmpty else { return .rootContainer }
        var cursor = ProviderItemIdentifier.rootContainer
        for component in path.split(separator: "/").map(String.init) {
            guard let next = children(of: cursor).first(where: { $0.filename == component })
            else { return nil }
            cursor = next.identifier
        }
        return cursor
    }

    /// The names in one container, which is what a `ls` of that folder shows. Answered
    /// from the replica and never from the extension (`MQ-039`).
    public func listing(of container: ProviderItemIdentifier) -> [String] {
        children(of: container).map(\.filename).sorted()
    }

    public var allIdentifiers: Set<ProviderItemIdentifier> { Set(items.keys) }
    public var count: Int { items.count }
    public var filenames: [String] { items.values.map(\.filename).sorted() }
    public var downloadedIdentifiers: Set<ProviderItemIdentifier> {
        Set(items.values.filter(\.isDownloaded).map(\.identifier))
    }
    public var downloadedCount: Int { items.values.filter(\.isDownloaded).count }
}
