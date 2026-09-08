import Foundation

/// The neutral half of the File Provider vocabulary (DESIGN.md section 5,
/// `docs/testing-architecture.md` section 2.2).
///
/// Everything the extension decides is expressed in these types, so the decision compiles
/// and is tested off Darwin; `Apps/FileProvider` is the only place that names an Apple
/// type at all, and every constant mirrored here is asserted against Apple's own by the
/// macOS-only `MirroredProviderConstantsTests`.

// MARK: Identifiers

/// `NSFileProviderItemIdentifier`. The three well-known identifiers are string literals
/// in the framework, and both sides of the mount have always had to spell them the same
/// way: the index's root row carries the root literal, and the trash refusal of
/// section 5.4 is keyed on the trash one.
public struct ProviderItemIdentifier: RawRepresentable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// `NSFileProviderItemIdentifier.rootContainer`.
    public static let rootContainer = ProviderItemIdentifier("NSFileProviderRootContainerItemIdentifier")
    /// `NSFileProviderItemIdentifier.workingSet`.
    public static let workingSet = ProviderItemIdentifier("NSFileProviderWorkingSetContainerItemIdentifier")
    /// `NSFileProviderItemIdentifier.trashContainer`.
    public static let trashContainer = ProviderItemIdentifier("NSFileProviderTrashContainerItemIdentifier")
}

/// A page token as the agent understands it: nil is "the first page". The system's two
/// well-known first-page constants are not tokens of ours and never travel past the
/// adapter (section 5.2).
public typealias ProviderPageToken = String

/// `NSFileProviderSyncAnchor`, which is a byte string; ours is always the decimal
/// spelling of an index sequence number (section 5.3).
public struct ProviderSyncAnchor: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(sequence: Int64) { self.rawValue = String(sequence) }
    public var description: String { rawValue }

    /// The sequence number this anchor names, or 0 for anything unparseable - which the
    /// system never sends, because every anchor it holds came from us.
    public var sequence: Int64 { Int64(rawValue) ?? 0 }
}

// MARK: Capabilities and flags

/// `NSFileProviderItemCapabilities`, as a value with no Apple framework behind it.
///
/// The bits are Apple's, mirrored here so the derivation of DESIGN.md section 5.4 - which
/// is a decision, not an adapter - compiles and is tested off Darwin. The extension turns
/// a row's raw value straight back into `NSFileProviderItemCapabilities`, so the numbers
/// must not drift; `MirroredProviderConstantsTests` asserts each one against Apple's on
/// macOS, which is step 4's `AppleConstantsTests` in miniature.
public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let allowsReading = ProviderCapabilities(rawValue: 1 << 0)
    public static let allowsWriting = ProviderCapabilities(rawValue: 1 << 1)
    public static let allowsReparenting = ProviderCapabilities(rawValue: 1 << 2)
    public static let allowsRenaming = ProviderCapabilities(rawValue: 1 << 3)
    public static let allowsTrashing = ProviderCapabilities(rawValue: 1 << 4)
    public static let allowsDeleting = ProviderCapabilities(rawValue: 1 << 5)
    public static let allowsEvicting = ProviderCapabilities(rawValue: 1 << 6)
    public static let allowsExcludingFromSync = ProviderCapabilities(rawValue: 1 << 7)

    /// Apple's own aliases: adding sub-items is the write bit and enumerating is the read
    /// bit, on a directory.
    public static let allowsAddingSubItems = allowsWriting
    public static let allowsContentEnumerating = allowsReading
}

/// `NSFileProviderFileSystemFlags`, mirrored for the same reason.
public struct ProviderFileSystemFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let userExecutable = ProviderFileSystemFlags(rawValue: 1 << 0)
    public static let userReadable = ProviderFileSystemFlags(rawValue: 1 << 1)
    public static let userWritable = ProviderFileSystemFlags(rawValue: 1 << 2)
    public static let hidden = ProviderFileSystemFlags(rawValue: 1 << 3)
    public static let pathExtensionHidden = ProviderFileSystemFlags(rawValue: 1 << 4)
}

/// `NSFileProviderItemFields`, the `changedFields` bitmask a `modifyItem` carries and the
/// set a `createItem` is told to read. Three of the measured quirks are statements about
/// exact values of it - a Finder rename is `0x2` (`MQ-048`), a tag change `0x10`
/// (`MQ-042`), a `chmod` `0x100` (`MQ-047`) - so the numbers are part of the contract.
public struct ProviderItemFields: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let contents = ProviderItemFields(rawValue: 1 << 0)
    public static let filename = ProviderItemFields(rawValue: 1 << 1)
    public static let parentItemIdentifier = ProviderItemFields(rawValue: 1 << 2)
    public static let lastUsedDate = ProviderItemFields(rawValue: 1 << 3)
    public static let tagData = ProviderItemFields(rawValue: 1 << 4)
    public static let favoriteRank = ProviderItemFields(rawValue: 1 << 5)
    public static let creationDate = ProviderItemFields(rawValue: 1 << 6)
    public static let contentModificationDate = ProviderItemFields(rawValue: 1 << 7)
    public static let fileSystemFlags = ProviderItemFields(rawValue: 1 << 8)
    public static let extendedAttributes = ProviderItemFields(rawValue: 1 << 9)
    public static let typeAndCreator = ProviderItemFields(rawValue: 1 << 10)
}

/// `NSFileProviderContentPolicy` (DESIGN.md section 7.1.1). `.unset` is ours: it means
/// "serve no policy at all", which is not the same as `.inherited`, the neutral value the
/// system itself uses (`MQ-026`).
public enum ProviderContentPolicy: Int, Sendable, Hashable {
    case unset = -1
    case inherited = 0
    case downloadLazily = 1
    case downloadEagerlyAndKeepDownloaded = 2
}

/// What the system should be told an item *is*. `UTType` is Apple's and stays in the
/// adapter; the decision - a directory is a folder, a symlink is a symlink, everything
/// else is named by its extension and falls back to raw data - is section 5.4's and is
/// here.
public enum ProviderContentTypeHint: Equatable, Sendable {
    case folder
    case symbolicLink
    case filenameExtension(String)
    case data
}
