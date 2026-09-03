import Foundation

/// SSH Drive has no trash (DESIGN.md section 5.4): `allowsTrashing` is never set, a
/// delete is a delete, and nothing invents a server-side trash that other SFTP clients
/// would not understand.
///
/// That decision has to be told to the system in three places, because a replicated
/// domain gets a trash by default:
///
/// 1. the domain is added with `supportsSyncingTrash = false` (`NSFileProviderDomain`,
///    which documents the default as YES), so the system never draws a `.Trash` in the
///    mount at all;
/// 2. `enumerator(for: .trashContainer)` fails with `NSFeatureUnsupportedError`, which is
///    what `NSFileProviderReplicatedExtension.h` prescribes for an extension that does
///    not support trashing. Answering `noSuchItem` there makes the system believe the
///    trash was deleted and try to materialize it again, about once a second, for ever
///    (docs/spikes/results.md, 2026-09-04);
/// 3. `item(for: .trashContainer)` is refused from local state, without a reader read or
///    an XPC round trip, so an older domain that still carries a trash cannot stall a
///    `stat` of it.
///
/// The identifier is written out rather than imported so this module does not have to
/// link FileProvider; a test asserts it against the framework constant.
public enum SSHDriveTrash {
    /// `NSFileProviderItemIdentifier.trashContainer`.
    public static let containerIdentifier = "NSFileProviderTrashContainerItemIdentifier"

    /// The name the system gives the trash inside a File Provider mount.
    public static let name = ".Trash"

    public static func isTrash(identifier: String) -> Bool {
        identifier == containerIdentifier
    }

    /// "We do not do that", which is neither "it is gone" (the system would delete
    /// something) nor "pick another name" (the system would retry).
    public static var unsupportedError: NSError {
        NSError(
            domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
            userInfo: [
                NSLocalizedDescriptionKey: "SSH Drive has no trash; items are deleted on the server."
            ])
    }

    /// The local replica is case-insensitive and normalisation-insensitive (section 5.4),
    /// so a name that would land on the system's own trash is refused however it is
    /// spelled.
    public static func isTrash(filename: String) -> Bool {
        filename.precomposedStringWithCanonicalMapping
            .caseInsensitiveCompare(name) == .orderedSame
    }
}
