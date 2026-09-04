import Foundation
import SFTP

/// DESIGN.md section 5.4's name rules, applied to one directory listing.
///
/// **Case and normalisation.** The server is byte-exact and usually case-sensitive; the
/// local replica is case-insensitive and normalisation-insensitive. When two server names
/// in one directory map to the same local name (`Makefile` and `makefile`; NFC and NFD
/// `é.txt`), the one already visible in the index keeps its slot, and among newcomers the
/// byte-wise lowest name is shown; the rest are recorded with `hidden = 2`. `readdir`
/// order is not stable across polls on hash-ordered directories, so it cannot be the
/// tie-breaker: the visible name must not flip from one cycle to the next.
///
/// **Names that are not valid UTF-8 are hidden the same way,** which is why the index
/// stores names as bytes (section 5.3).
///
/// **Hidden names hold their slot:** a create or rename to one of them fails with
/// `.filenameCollision`, which is what `LocationRuntime` checks before a create.
///
/// Four kinds of entry get no row at all rather than a hidden one, because they are not
/// items the Mac ever sees: `.` and `..`, anything that is not a file, directory or
/// symlink (section 5.4: "sockets, FIFOs and device nodes ... are never enumerated and
/// never get a row"), a server-side `.DS_Store` (section 5.4: "a `.DS_Store` on the
/// server is never enumerated"), and our own upload temp files (section 5.5).
public enum NameVisibility {

    /// `hidden = 2`: recorded, holding its name, never shown.
    public static let hiddenCollision: Int64 = 2

    public struct Entry {
        public var entry: SFTPDirectoryEntry
        /// 0 shown, 2 hidden.
        public var hidden: Int64
        /// The sentence `sshdrive status` prints under "not shown". Empty when shown.
        public var reason: String
    }

    public struct Skipped {
        public var name: Data
        public var reason: String
    }

    public struct Result {
        public var entries: [Entry] = []
        public var skipped: [Skipped] = []

        public var hiddenEntries: [Entry] { entries.filter { $0.hidden != 0 } }
    }

    /// The name the local filesystem would collapse this one onto: case-folded and
    /// canonically composed, which is what "case-insensitive and normalisation-insensitive"
    /// means on APFS. Nil when the name is not valid UTF-8, which is itself a reason to
    /// hide it.
    public static func localKey(for name: Data) -> String? {
        guard let text = String(data: name, encoding: .utf8), !text.isEmpty else { return nil }
        return text.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Byte-wise ordering, which is the tie-breaker section 5.4 names. Not string
    /// ordering: the names need not be text at all.
    public static func byteWiseLower(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    public static func isUploadTemporary(_ name: Data) -> Bool {
        guard let text = String(data: name, encoding: .utf8) else { return false }
        return text.hasPrefix(".sshdrive-upload-")
    }

    public static func isDSStore(_ name: Data) -> Bool {
        name == Data(".DS_Store".utf8)
    }

    /// `visibleNames` is the set of names in this directory that already have a row with
    /// `hidden = 0`. They keep their slot: without that rule the visible name would flip
    /// from one poll to the next as soon as a newcomer sorted lower.
    public static func classify(entries: [SFTPDirectoryEntry], visibleNames: Set<Data>) -> Result {
        var result = Result()

        var candidates: [SFTPDirectoryEntry] = []
        for entry in entries {
            let name = entry.name
            if name == Data(".".utf8) || name == Data("..".utf8) { continue }
            if entry.attributes.type == .other {
                result.skipped.append(
                    Skipped(
                        name: name,
                        reason: "not a file, directory or symlink; File Provider has no item type for it"))
                continue
            }
            if isDSStore(name) {
                result.skipped.append(
                    Skipped(name: name, reason: "a server-side .DS_Store is never enumerated"))
                continue
            }
            if isUploadTemporary(name) {
                result.skipped.append(
                    Skipped(name: name, reason: "an SSH Drive upload temp file"))
                continue
            }
            // The section 9.1 chokepoint has the last word on whether a name can be a path
            // component at all. A name it rejects (a NUL, a slash) can never be addressed,
            // so it gets no row.
            guard (try? RelativePath(components: [name])) != nil else {
                result.skipped.append(
                    Skipped(name: name, reason: "the name cannot be a path component"))
                continue
            }
            candidates.append(entry)
        }

        // Group by the name the Mac would collapse onto. Anything with no local key is
        // not representable at all and is hidden on its own account.
        var groups: [String: [SFTPDirectoryEntry]] = [:]
        for entry in candidates {
            guard let key = localKey(for: entry.name) else {
                result.entries.append(
                    Entry(
                        entry: entry, hidden: hiddenCollision,
                        reason: "the name is not valid UTF-8, which macOS cannot represent"))
                continue
            }
            groups[key, default: []].append(entry)
        }

        for (_, group) in groups {
            guard group.count > 1 else {
                result.entries.append(Entry(entry: group[0], hidden: 0, reason: ""))
                continue
            }
            let incumbents = group.filter { visibleNames.contains($0.name) }
            let pool = incumbents.isEmpty ? group : incumbents
            guard
                let winner = pool.min(by: { byteWiseLower($0.name, $1.name) })
            else { continue }
            let winnerName = String(decoding: winner.name, as: UTF8.self)
            for entry in group {
                if entry.name == winner.name {
                    result.entries.append(Entry(entry: entry, hidden: 0, reason: ""))
                } else {
                    result.entries.append(
                        Entry(
                            entry: entry, hidden: hiddenCollision,
                            reason:
                                "the local filesystem cannot tell it from \"\(winnerName)\"; rename one on the server"))
                }
            }
        }

        return result
    }
}
