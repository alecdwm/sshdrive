import Foundation

/// `com.apple.quarantine` on our own bundle, and what to say about it (DESIGN.md
/// section 10).
///
/// LaunchServices declines to register the **plugins** of a quarantined bundle that has
/// never been assessed through a user-visible launch. The agent itself is unaffected -
/// launchd starts it directly - so everything looks installed while the File Provider
/// extension does not exist as far as the system is concerned: `pluginkit -m` prints
/// nothing, `pluginkit -a` registers the appex and the next launch wipes the registration
/// again, and `fileproviderd` answers
/// `getDomainsForProviderIdentifier((null)) failed: FP -2001 Underlying FP -2014`.
/// Stripping the attribute and opening the app once registers it durably.
///
/// Measured on the owner's Mac (macOS 26.6.2) on 2026-09-05, on a `brew install --cask
/// sshdrive` install; a fresh-user quarantined install on the 26.4.1 build VM had not
/// shown it, so this is a difference between those two machines and nothing here claims
/// which half of it matters.
///
/// The reading is split from the deciding so the check can be tested without a
/// quarantined bundle to point it at.
public enum BundleQuarantine {

    /// The extended attribute LaunchServices writes on anything unpacked from a download.
    public static let attributeName = "com.apple.quarantine"

    /// The attribute's value, or nil when the path does not carry it. An unreadable path
    /// is reported as "not quarantined": this is a diagnosis, and the checks that care
    /// whether the bundle is there at all are elsewhere.
    public static func attributeValue(atPath path: String) -> String? {
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &bytes, size, 0, 0)
        guard read > 0 else { return nil }
        let value = String(decoding: bytes[0 ..< read], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return value.isEmpty ? attributeName : value
    }

    /// The seam: `read` answers the attribute's value for a path, or nil.
    public static func isQuarantined(
        bundlePath: String, read: (String) -> String? = attributeValue(atPath:)
    ) -> Bool {
        read(bundlePath) != nil
    }

    /// The `doctor` line's detail, quarantined or not.
    public static func detail(bundlePath: String, value: String?) -> String {
        guard let value else { return "not quarantined" }
        return "\(attributeName) = \(value)"
    }

    /// The two commands that fix it, in the order they have to run. Stripping the
    /// attribute is not enough on its own: the registration only happens on a launch out
    /// of the bundle, so the `open` is half the remedy.
    public static func remedy(bundlePath: String) -> String {
        "The bundle is still quarantined, and LaunchServices will not register its File "
            + "Provider extension while it is. Run:\n"
            + "  xattr -dr \(attributeName) \"\(bundlePath)\"\n"
            + "  open -g -a \"SSH Drive\""
    }
}
