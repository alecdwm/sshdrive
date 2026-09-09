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
        guard !name.isEmpty else { return nil }
        // An all-ASCII name is already canonically composed and folds by adding 0x20 to
        // A-Z, so it needs neither of the two Foundation passes below - which, on a
        // directory of ten thousand names, is the difference between a normalisation each
        // and none at all. Every byte under 0x80 is also valid UTF-8 by definition, so the
        // decode cannot fail either.
        var ascii = true
        for byte in name where byte >= 0x80 {
            ascii = false
            break
        }
        guard !ascii else {
            var folded = [UInt8]()
            folded.reserveCapacity(name.count)
            for byte in name { folded.append(byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte) }
            return String(decoding: folded, as: UTF8.self)
        }
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
        result.entries.reserveCapacity(entries.count)

        // One pass over the listing: an entry that gets no row at all is recorded as
        // skipped here, and every other one is filed under the name the Mac would
        // collapse it onto. The entries are walked by index and never copied into a
        // candidate array and then into a group array as well, which would be three
        // copies of every entry in a ten-thousand-name directory before any of it is
        // classified.
        var candidate = [Bool](repeating: false, count: entries.count)
        // The key each entry folds onto is needed only to *find* the collisions, so it is
        // not kept per entry: a directory with none - which is nearly every directory -
        // carries no second array of ten thousand strings for it.
        var seen: [String: Int] = [:]
        seen.reserveCapacity(entries.count)
        var groups: [String: [Int]] = [:]
        var unrepresentable = Set<Int>()
        for index in entries.indices {
            let name = entries[index].name
            if name == dot || name == dotDot { continue }
            if entries[index].attributes.type == .other {
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
            candidate[index] = true
            // Anything with no local key is not representable at all and is hidden on its
            // own account, below.
            guard let key = localKey(for: name) else {
                unrepresentable.insert(index)
                continue
            }
            if let first = seen[key] {
                if groups[key] == nil { groups[key] = [first] }
                groups[key]?.append(index)
            } else {
                seen[key] = index
            }
        }

        // Only a key more than one name maps to has anything to decide, and the answer is
        // filed against the entries themselves so the pass below needs no key at all.
        var winnerFor: [Int: Data] = [:]
        for (_, group) in groups {
            let incumbents = group.filter { visibleNames.contains(entries[$0].name) }
            let pool = incumbents.isEmpty ? group : incumbents
            guard let winner = pool.min(by: { byteWiseLower(entries[$0].name, entries[$1].name) })
            else { continue }
            for index in group { winnerFor[index] = entries[winner].name }
        }

        // In the order the server reported them, which is the order the rows are written
        // and the pages are cut in. Walking a `[String: [entry]]` dictionary instead would
        // hand back whatever order it happens to iterate in, which is not the same from
        // one listing to the next even for a directory nothing has touched.
        for index in entries.indices where candidate[index] {
            let entry = entries[index]
            guard !unrepresentable.contains(index) else {
                result.entries.append(
                    Entry(
                        entry: entry, hidden: hiddenCollision,
                        reason: "the name is not valid UTF-8, which macOS cannot represent"))
                continue
            }
            guard let winnerName = winnerFor[index] else {
                result.entries.append(Entry(entry: entry, hidden: 0, reason: ""))
                continue
            }
            if entry.name == winnerName {
                result.entries.append(Entry(entry: entry, hidden: 0, reason: ""))
            } else {
                result.entries.append(
                    Entry(
                        entry: entry, hidden: hiddenCollision,
                        reason:
                            "the local filesystem cannot tell it from \"\(String(decoding: winnerName, as: UTF8.self))\"; rename one on the server"))
            }
        }

        return result
    }

    private static let dot = Data(".".utf8)
    private static let dotDot = Data("..".utf8)
}
