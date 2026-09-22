import Foundation
import ProviderCore
import XPCProtocols

/// The user (docs/design/testing.md).
///
/// Everything a person does to a mount, expressed as the calls the *system* makes because
/// of it. Nothing here is our code; it is Finder and the kernel, and every method cites
/// the measurement that says what they do.
public final class Finder {
    private unowned let domain: ModelDomain

    public init(domain: ModelDomain) {
        self.domain = domain
    }

    // MARK: Looking

    /// Showing a folder. `MQ-001`: the first view is one `enumerateItems`; every later
    /// view is served from the replica and reaches the extension not at all.
    public func open(_ container: ProviderItemIdentifier = .rootContainer) {
        domain.openFolder(container)
    }

    /// `MQ-039`: a `readdir`/`lstat` walk of the mount is answered from the replica and
    /// **reaches the extension not at all** - `ls -R` returns the whole tree with exit 0
    /// while every provider call is failing. Nothing here touches the provider, which is
    /// the assertion.
    public func walk(_ container: ProviderItemIdentifier = .rootContainer) -> [String] {
        domain.replica.descendants(of: container).compactMap { domain.replica.path(of: $0.identifier) }
            .sorted()
    }

    /// Opening a file for reading: one foreground `fetchContents`.
    public func read(_ identifier: ProviderItemIdentifier) {
        domain.fetchContents(identifier, foreground: true)
    }

    /// `MQ-032`: eight files opened at once from a shell arrive as eight **simultaneous**
    /// foreground calls. The six-fetch ceiling bounds an eager subtree, not this.
    public func openAtOnce(_ identifiers: [ProviderItemIdentifier]) {
        for identifier in identifiers { domain.fetchContents(identifier, foreground: true) }
    }

    // MARK: Writing

    /// A new file in the mount. It exists in the replica at once and is offered to the
    /// provider afterwards, which is why an offline write just queues
    /// (docs/design/offline.md).
    ///
    /// `MQ-046`: a `.DS_Store` is kept by the system and **never reaches the extension** -
    /// no `createItem`, no row, and nobody is ever asked to upload it.
    @discardableResult
    public func create(
        _ filename: String, in parent: ProviderItemIdentifier = .rootContainer,
        size: Int64 = 12, isDirectory: Bool = false
    ) -> ProviderItemIdentifier {
        let identifier = domain.mintLocalIdentifier()
        var item = ReplicaItem(
            identifier: identifier, parent: parent, filename: filename,
            isDirectory: isDirectory, size: size, now: domain.clock.now())
        if SSHDriveNames.isLocalOnly(filename) {
            item.isLocalOnly = true
            domain.replica.insertLocal(item)
            return identifier
        }
        domain.replica.insertLocal(item)
        domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .create, identifier: identifier, filename: filename,
                changedFields: [], changes: ItemChanges(),
                template: ItemTemplate(
                    parentIdentifier: parent, filename: filename, isDirectory: isDirectory,
                    isSymlink: false)))
        return identifier
    }

    /// `ln -s`. It reaches `createItem` with the target **intact**, the system makes a
    /// real symlink under CloudStorage (`MQ-076`), and a refusal comes back as the item's
    /// `uploadingError` and nowhere else (`MQ-078`) - `ln -s` itself exits 0.
    @discardableResult
    public func symlink(
        _ filename: String, target: String, in parent: ProviderItemIdentifier = .rootContainer
    ) -> ProviderItemIdentifier {
        let identifier = domain.mintLocalIdentifier()
        let item = ReplicaItem(
            identifier: identifier, parent: parent, filename: filename, isSymlink: true,
            symlinkTarget: target, size: Int64(target.utf8.count), now: domain.clock.now())
        domain.replica.insertLocal(item)
        domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .create, identifier: identifier, filename: filename,
                changedFields: [], changes: ItemChanges(),
                template: ItemTemplate(
                    parentIdentifier: parent, filename: filename, isDirectory: false,
                    isSymlink: true, symlinkTarget: target)))
        return identifier
    }

    /// Finder's own duplicate. `MQ-015`: a real name collision inside Finder **never
    /// reaches the provider** - Finder resolves it itself, `run.sh` becoming
    /// `run copy.sh` - so a `.filenameCollision` is not what a duplicate produces.
    @discardableResult
    public func duplicate(_ identifier: ProviderItemIdentifier) -> ProviderItemIdentifier? {
        guard let item = domain.replica.item(identifier) else { return nil }
        let taken = Set(domain.replica.children(of: item.parentIdentifier).map(\.filename))
        var candidate = Self.copyName(of: item.filename)
        var index = 2
        while taken.contains(candidate) {
            candidate = Self.copyName(of: item.filename, ordinal: index)
            index += 1
        }
        return create(candidate, in: item.parentIdentifier, size: item.size)
    }

    /// `run.sh` -> `run copy.sh`, as measured; the suffix goes before the extension.
    public static func copyName(of filename: String, ordinal: Int = 1) -> String {
        let suffix = ordinal <= 1 ? " copy" : " copy \(ordinal)"
        let name = filename as NSString
        let ext = name.pathExtension
        guard !ext.isEmpty else { return filename + suffix }
        return name.deletingPathExtension + suffix + "." + ext
    }

    /// An atomic save - TextEdit's, and the shell's write-a-temp-and-`mv`.
    ///
    /// `MQ-049`: both arrive as **one `modifyItem` on the original item** (`0x289` and
    /// `0xc1`), with no `createItem` and no `deleteItem`. With no tombstones in the index
    /// (docs/design/item-index.md) the other shape would lose a pin or a tag placed on
    /// that one file, which is why this is a measurement and not a detail.
    @discardableResult
    public func save(_ identifier: ProviderItemIdentifier, size: Int64 = 24) -> Int {
        domain.replica.mutate(identifier) { item in
            item.size = size
            item.mtime = self.domain.clock.now()
            item.isDownloaded = true
        }
        return domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .modify, identifier: identifier,
                filename: domain.replica.item(identifier)?.filename ?? "",
                changedFields: Self.atomicSaveFields,
                changes: ItemChanges(newModificationDate: domain.clock.now())))
    }

    /// The exact mask an atomic save carried (`MQ-049`): contents, last-used date,
    /// modification date and extended attributes.
    public static let atomicSaveFields = ProviderItemFields(rawValue: 0x289)

    /// `MQ-048`: a Finder rename is one `modifyItem` with `changedFields = 0x2`.
    @discardableResult
    public func rename(_ identifier: ProviderItemIdentifier, to newName: String) -> Int {
        domain.replica.mutate(identifier) { $0.filename = newName }
        return domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .modify, identifier: identifier, filename: newName,
                changedFields: .filename, changes: ItemChanges(newFilename: newName)))
    }

    /// `MQ-047`: `chmod` arrives as `changedFields = 0x100`, and a `chmod +x` on a file
    /// that is **already** executable produces no call at all, because the only bit the
    /// replica carries is owner-execute.
    @discardableResult
    public func chmod(_ identifier: ProviderItemIdentifier, executable: Bool) -> Int? {
        guard let item = domain.replica.item(identifier) else { return nil }
        let already = item.extendedAttributes[Self.executableMarker] != nil
        guard already != executable else { return nil }
        domain.replica.mutate(identifier) { item in
            if executable {
                item.extendedAttributes[Self.executableMarker] = Data([1])
            } else {
                item.extendedAttributes.removeValue(forKey: Self.executableMarker)
            }
        }
        return domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .modify, identifier: identifier, filename: item.filename,
                changedFields: .fileSystemFlags,
                changes: ItemChanges(newFileSystemFlags: executable ? 0o755 : 0o644)))
    }

    /// The model's stand-in for the owner-execute bit the replica carries. It is a
    /// replica-side flag, not an xattr the extension is ever told about.
    static let executableMarker = "model.owner-execute"

    /// A Finder tag. `MQ-042`: it arrives as the item's **`tagData` and nothing else** -
    /// one `modifyItem` with `changedFields = 0x10` and an **empty** `extendedAttributes`
    /// dictionary, carrying an `NSKeyedArchiver` archive rather than the
    /// `_kMDItemUserTags` property list.
    @discardableResult
    public func tag(_ identifier: ProviderItemIdentifier, _ tagData: Data) -> Int {
        domain.replica.mutate(identifier) { item in
            item.tagData = tagData
            item.extendedAttributes[ModelDomain.tagsXattrName] = tagData
        }
        return domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .modify, identifier: identifier,
                filename: domain.replica.item(identifier)?.filename ?? "",
                changedFields: .tagData, changes: ItemChanges(newTagData: tagData)))
    }

    /// `xattr -w` through the mount.
    ///
    /// `MQ-044`: **the system decides which xattrs the extension is ever told about.** Of
    /// three written, only the one whose name carried `XATTR_FLAG_SYNCABLE` - the `#S`
    /// suffix - reached `changedFields.extendedAttributes`; an ordinary name lives in the
    /// replica and the extension is never told. `com.apple.metadata:_kMDItemUserTags` and
    /// `com.apple.FinderInfo` are excluded deliberately.
    @discardableResult
    public func setExtendedAttribute(
        _ identifier: ProviderItemIdentifier, name: String, value: Data
    ) -> Int? {
        domain.replica.mutate(identifier) { $0.extendedAttributes[name] = value }
        guard domain.isSyncableXattrName(name) else { return nil }
        return domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .modify, identifier: identifier,
                filename: domain.replica.item(identifier)?.filename ?? "",
                changedFields: .extendedAttributes,
                changes: ItemChanges(newExtendedAttributes: [name: value])))
    }

    @discardableResult
    public func delete(_ identifier: ProviderItemIdentifier) -> Int {
        domain.enqueue(
            PendingWrite(
                sequence: 0, kind: .delete, identifier: identifier,
                filename: domain.replica.item(identifier)?.filename ?? "",
                changedFields: [], changes: ItemChanges()))
    }

    // MARK: The contextual menu

    /// Where a right-click landed. `MQ-054`: our entries are offered on an item and on the
    /// **window background** - where the item they act on is the folder being shown - and
    /// **never on the sidebar row**, which is why a whole location is pinned only from the
    /// CLI.
    public enum Target: Equatable {
        case items([ProviderItemIdentifier])
        case windowBackground(ProviderItemIdentifier)
        case sidebarRow
    }

    public struct MenuEntry: Equatable {
        public var title: String
        /// nil for Finder's own entries; ours carry the action identifier the system
        /// hands back to `performAction`.
        public var actionIdentifier: String?
        public var isTopLevel: Bool
    }

    /// The menu, as `fileproviderctl evaluate` would print it.
    ///
    /// Two independent halves (docs/design/pinning.md): Finder's own two entries follow
    /// `isDownloaded` and nothing else (`MQ-053`), and ours are decided by the activation
    /// rules of the declaration (`MQ-055`).
    public func contextMenu(
        _ target: Target, actions: [ActionDeclaration] = ActionDeclaration.shipped
    ) -> [MenuEntry] {
        let selection: [ProviderItemIdentifier]
        switch target {
        case .items(let identifiers): selection = identifiers
        case .windowBackground(let folder): selection = [folder]
        case .sidebarRow:
            // The domain's sidebar row menu is Finder's own and carries none of ours.
            return [
                MenuEntry(title: "Open in New Tab", actionIdentifier: nil, isTopLevel: true),
                MenuEntry(title: "Show \u{201C}SSH Drive\u{201D}", actionIdentifier: nil, isTopLevel: true),
                MenuEntry(title: "Download Now", actionIdentifier: nil, isTopLevel: true),
                MenuEntry(title: "Remove from Sidebar", actionIdentifier: nil, isTopLevel: true),
            ]
        }
        let items = selection.compactMap { domain.replica.item($0) }
        var entries: [MenuEntry] = []
        // `MQ-053`: exactly two, in the third slot, chosen by `isDownloaded` and nothing
        // else - and `Remove Download` is still offered on a kept item, where it fails.
        if items.count == 1, let item = items.first, !item.isDirectory {
            entries.append(
                MenuEntry(
                    title: item.isDownloaded ? "Remove Download" : "Download Now",
                    actionIdentifier: nil, isTopLevel: false))
        }
        // `MQ-054`: ours are at the very bottom, at the top level, and exactly one of the
        // pair appears - which is what the two "at least one" rules produce.
        for action in actions {
            guard ActivationRule.evaluate(action.activationRule, items: items) == true else {
                continue
            }
            entries.append(
                MenuEntry(
                    title: action.name, actionIdentifier: action.identifier, isTopLevel: true))
        }
        return entries
    }
}

/// One `NSExtensionFileProviderActions` entry, as the appex's Info.plist declares it.
/// `SystemModelTests` reads the real plist and asserts these are what it says, so the
/// model cannot drift from the shipped declaration.
public struct ActionDeclaration: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var activationRule: String

    public init(identifier: String, name: String, activationRule: String) {
        self.identifier = identifier
        self.name = name
        self.activationRule = activationRule
    }

    public static let shipped: [ActionDeclaration] = [
        ActionDeclaration(
            identifier: SSHDriveIdentifiers.pinActionID, name: "Keep Downloaded",
            activationRule: "SUBQUERY(fileproviderItems, $item, $item.userInfo.kept == 0).@count > 0"),
        ActionDeclaration(
            identifier: SSHDriveIdentifiers.unpinActionID, name: "Don't Keep Downloaded",
            activationRule: "SUBQUERY(fileproviderItems, $item, $item.userInfo.kept == 1).@count > 0"),
    ]
}

/// The activation rule, evaluated the way `fileproviderctl evaluate` does.
///
/// `MQ-055`: the bound key is **`fileproviderItems`, lower-case p**, and it is a key path
/// on the evaluated object, not a `$` substitution variable. Either mistake drops the
/// entry **silently**, with nothing in any log: `$fileProviderItems` raises out of
/// `NSVariableExpression` because the bindings dictionary is empty, and the capital-P
/// spelling does not occur anywhere in the dyld shared cache. So a rule this parser
/// cannot bind answers `nil` - dropped - rather than false.
public enum ActivationRule {
    /// nil means the rule was dropped: the entry never appears and nothing says why.
    public static func evaluate(_ rule: String, items: [ReplicaItem]) -> Bool? {
        // SUBQUERY(<binding>, $item, $item.userInfo.kept == N).@count > 0
        guard rule.hasPrefix("SUBQUERY("), rule.hasSuffix(").@count > 0") else { return nil }
        let body = String(
            rule.dropFirst("SUBQUERY(".count).dropLast(").@count > 0".count))
        let parts = body.components(separatedBy: ", ")
        guard parts.count == 3 else { return nil }
        // The two silent mistakes: `fileProviderItems` binds nothing, and
        // `$fileproviderItems` raises out of NSVariableExpression against an empty
        // bindings dictionary. Either way the rule is dropped and the entry is absent.
        guard parts[0] == "fileproviderItems", parts[1] == "$item" else { return nil }
        let prefix = "$item.userInfo.kept == "
        guard parts[2].hasPrefix(prefix), let wanted = Int(parts[2].dropFirst(prefix.count))
        else { return nil }
        // The "at least one" form: false on an empty selection, where the "all selected
        // items" form would be `0 == nil-count`, i.e. true, and would show both entries.
        return items.contains { ($0.kept ? 1 : 0) == wanted }
    }
}

/// Names the system keeps to itself.
enum SSHDriveNames {
    /// `MQ-046`: `.DS_Store` never reaches the extension. It is the only measured member
    /// of this set.
    static func isLocalOnly(_ filename: String) -> Bool { filename == ".DS_Store" }
}

extension ModelDomain {
    /// `MQ-044`'s rule, as the catalogue holds it: only a name carrying
    /// `XATTR_FLAG_SYNCABLE` - written as the `#S` suffix - is passed on, and the two
    /// names the system excludes deliberately never are.
    func isSyncableXattrName(_ name: String) -> Bool {
        if name == ModelDomain.tagsXattrName || name == "com.apple.FinderInfo" { return false }
        return name.hasSuffix(quirks.text(.onlySyncableXattrsReachTheExtension))
    }
}
