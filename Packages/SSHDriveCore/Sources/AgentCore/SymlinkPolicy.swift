import Foundation
import SFTP

/// DESIGN.md section 5.7's lexical inside-the-share check, and nothing else.
///
/// Remote symlinks are never followed. A link is shown only if its target stays inside
/// the location's root, and the check is **lexical**: it resolves the target string
/// against the link's own directory, collapses `.` and `..`, and never touches the
/// server. Section 9.1 depends on that: "the target string of a link is checked lexically
/// once and otherwise handed to the Mac verbatim; it is never joined to a remote path or
/// resolved on the server, so a `..` inside a target cannot steer a remote operation".
///
/// "The root" has two spellings and either is accepted (section 5.7): the canonical path
/// `realpath` returned at `add`, and the path as the user typed it - or, for the default
/// root, the `$HOME` the probe read. On a host where `/home` is itself a symlink the
/// canonical root is `/var/home/alec` while every absolute link says `/home/alec/…`, and
/// checked against the canonical spelling alone all of them would be hidden.
public enum SymlinkPolicy {

    /// What to do with one link.
    public enum Decision: Equatable, Sendable {
        /// Shown, as a native symlink whose Mac-side target is this string. For a
        /// relative target that is the server's own string; for an absolute one inside
        /// the root it is the rewritten relative form (section 5.7).
        case show(macTarget: String)
        /// Omitted from enumeration entirely, logged at debug level, otherwise ignored.
        case hide(reason: String)
    }

    /// The two spellings of the root a target may be measured against.
    public struct Roots: Equatable, Sendable {
        /// The canonical absolute path `realpath` returned at `add` (section 9.1).
        public var canonical: String
        /// The path as the user typed it, or `$HOME` for the default root. Nil when it
        /// is the same string as the canonical one, or when no probe ever ran.
        public var alternate: String?

        public init(canonical: String, alternate: String? = nil) {
            self.canonical = canonical
            self.alternate = (alternate?.isEmpty ?? true) || alternate == canonical
                ? nil : alternate
        }
    }

    /// The message section 5.7 requires for a target that would leave the share. It is
    /// shown to the user through the sync error list, so it says what to do.
    public static let escapingTargetMessage =
        "The target of a symbolic link must be a relative path that stays inside this location."

    // MARK: The check

    /// Judges one link found on the server.
    ///
    /// - Parameters:
    ///   - target: the target string exactly as `readlink` returned it.
    ///   - linkDirectory: the directory the link itself lives in, relative to the root.
    ///   - roots: the two spellings of the root.
    public static func evaluate(
        target: String, linkDirectory: RelativePath, roots: Roots
    ) -> Decision {
        guard !target.isEmpty else {
            return .hide(reason: "the link has an empty target")
        }

        if target.hasPrefix("/") {
            // Absolute. It is shown only if it lands inside the root under one of the two
            // spellings, and then the Mac-side target is rewritten relative to the link's
            // own directory - the server keeps the absolute string (section 5.7).
            guard let inside = componentsInsideRoot(absolute: target, roots: roots) else {
                return .hide(
                    reason: "the target \(target) is outside this location")
            }
            return .show(macTarget: relativeSpelling(from: linkDirectory, to: inside))
        }

        // Relative: resolve against the link's own directory and require the result to
        // stay at or below the root. The string itself is unchanged when it passes.
        guard resolve(relative: target, from: linkDirectory) != nil else {
            return .hide(
                reason: "the target \(target) climbs above this location")
        }
        return .show(macTarget: target)
    }

    /// The check as `createItem` applies it (section 5.7, "Creating symlinks from the
    /// Mac"). Stricter than `evaluate`: an absolute target from the Mac is a *Mac* path
    /// (`/Users/…/CloudStorage/…`), meaningless on the server, and is refused even when
    /// it points inside the mount. Returns the string to hand SFTP `symlink` unchanged.
    public static func targetForCreate(
        _ target: String, in linkDirectory: RelativePath, roots: Roots
    ) throws -> String {
        guard !target.isEmpty else { throw Refusal() }
        guard !target.hasPrefix("/") else { throw Refusal() }
        guard resolve(relative: target, from: linkDirectory) != nil else { throw Refusal() }
        return target
    }

    /// The check as a rename or move applies it (section 5.7): a relative target is
    /// re-checked from the **destination** directory, and an absolute target inside the
    /// root stays inside wherever the link lives. Allowing the move and then hiding the
    /// result would be a way to plant an escaping link on the server through the mount.
    /// Returns the Mac-side target for the link's new home, which for an absolute
    /// in-root target is a different relative spelling and therefore a new metadata
    /// version.
    public static func targetForMove(
        _ target: String, to destinationDirectory: RelativePath, roots: Roots
    ) throws -> String {
        switch evaluate(target: target, linkDirectory: destinationDirectory, roots: roots) {
        case let .show(macTarget): return macTarget
        case .hide: throw Refusal()
        }
    }

    /// EINVAL with section 5.7's message. `Refusal` rather than an `SFTPError` because
    /// nothing on the wire refused anything: this is our own rule.
    public struct Refusal: Error, LocalizedError, Equatable {
        public init() {}
        public var errorDescription: String? { SymlinkPolicy.escapingTargetMessage }
    }

    // MARK: Lexical machinery

    /// Splits a slash-separated string, dropping empties (so `a//b` and a trailing slash
    /// behave), and collapses nothing.
    static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Resolves a relative target against `base`, collapsing `.` and `..`. Nil when it
    /// climbs above the root, which is exactly the case section 5.7 hides.
    static func resolve(relative target: String, from base: RelativePath) -> [String]? {
        var stack = base.components.map { String(decoding: $0, as: UTF8.self) }
        for component in split(target) {
            switch component {
            case ".": continue
            case "..":
                if stack.isEmpty { return nil }
                stack.removeLast()
            default:
                stack.append(component)
            }
        }
        return stack
    }

    /// Collapses an absolute target and, if it lands at or below either spelling of the
    /// root, returns its components relative to the root. Nil when it is outside.
    static func componentsInsideRoot(absolute target: String, roots: Roots) -> [String]? {
        var stack: [String] = []
        for component in split(target) {
            switch component {
            case ".": continue
            case "..":
                // A `..` above `/` is `/` on every Unix, so it is dropped rather than
                // making the whole target unresolvable.
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(component)
            }
        }
        for spelling in [roots.canonical, roots.alternate].compactMap({ $0 }) {
            let rootComponents = split(spelling)
            guard stack.count >= rootComponents.count,
                Array(stack.prefix(rootComponents.count)) == rootComponents
            else { continue }
            return Array(stack.dropFirst(rootComponents.count))
        }
        return nil
    }

    /// The relative path from `directory` to `target`, both given relative to the root.
    /// This is the rewrite section 5.7 asks for: "the target rewritten as the relative
    /// path from the link's directory to the resolved location".
    static func relativeSpelling(from directory: RelativePath, to target: [String]) -> String {
        let here = directory.components.map { String(decoding: $0, as: UTF8.self) }
        var common = 0
        while common < here.count, common < target.count, here[common] == target[common] {
            common += 1
        }
        var pieces = Array(repeating: "..", count: here.count - common)
        pieces.append(contentsOf: target[common...])
        // A link that points at its own directory has no components left; `.` is what
        // `ln -s . x` writes and what the Mac understands.
        return pieces.isEmpty ? "." : pieces.joined(separator: "/")
    }
}
