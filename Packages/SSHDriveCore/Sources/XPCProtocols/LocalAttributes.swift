import Foundation

/// Everything an item carries that lives on this Mac and nowhere else: the extended
/// attributes the system hands us and the Finder tags it hands us separately
/// (DESIGN.md section 5.4).
///
/// Both are stored in one blob, the row's `xattrs` column, because section 5.3 hashes
/// exactly that blob into the metadata version and S10's whole question is whether that
/// hash is enough to stop the system re-offering a change it already made. Tags are not
/// an xattr - `com.apple.metadata:_kMDItemUserTags` is excluded from
/// `extendedAttributes` deliberately and arrives as the item's own `tagData` (S4,
/// 2026-09-04) - so they get their own field rather than a reserved key inside the
/// dictionary, where a future real xattr of that name would collide with them.
///
/// The system rebuilds the tags xattr from `tagData` on every update, so an item that
/// returns no `tagData` loses the user's tags on the next re-download. Serving this back
/// on every item is what stops that.
public struct LocalAttributes: Codable, Equatable, Sendable {
    public var xattrs: [String: Data]
    /// The opaque blob behind `NSFileProviderItem.tagData`. Never parsed, only stored.
    public var tagData: Data?

    public init(xattrs: [String: Data] = [:], tagData: Data? = nil) {
        self.xattrs = xattrs
        self.tagData = tagData
    }

    public var isEmpty: Bool { xattrs.isEmpty && (tagData?.isEmpty ?? true) }

    /// The blob stored on the row. Nil when there is nothing to store, so that an item
    /// that has never carried a tag or an xattr hashes exactly as it did before the
    /// column existed.
    ///
    /// **`.sortedKeys` is load-bearing.** Section 5.3 hashes this blob into the metadata
    /// version, and `JSONEncoder` does not promise a key order without it - not for the
    /// `xattrs` dictionary and not for the struct's own two keys. Without it the same
    /// attributes encode to two different byte strings within one process, the hash moves,
    /// and the system re-reads every item it holds for no reason. Caught by
    /// `RowBuilderTests.testTheSameAttributesTwiceProduceTheSameVersion` failing about one
    /// run in three (2026-09-04); it had been read as flakiness in the test.
    public func encoded() -> Data? {
        guard !isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// Decodes a stored blob. A blob written before tags had a field of their own is a
    /// bare `[String: Data]`, and is still read: the schema version moved with this
    /// change, but a database written by a build in between is cheap to keep readable
    /// and expensive to mistake for an empty attribute set.
    public static func decode(_ data: Data?) -> LocalAttributes {
        guard let data, !data.isEmpty else { return LocalAttributes() }
        if let decoded = try? JSONDecoder().decode(LocalAttributes.self, from: data) {
            return decoded
        }
        if let legacy = try? JSONDecoder().decode([String: Data].self, from: data) {
            return LocalAttributes(xattrs: legacy, tagData: nil)
        }
        return LocalAttributes()
    }
}
