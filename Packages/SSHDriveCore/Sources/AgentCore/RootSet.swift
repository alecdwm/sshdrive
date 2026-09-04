import Foundation

/// DESIGN.md section 6.5's root set, as a pure value.
///
/// Every tier watches the same bounded set of directories, and the three reasons a
/// directory is in it - it holds a materialized file, it is a pin root, the extension has
/// enumerated it this session - are kept together on one entry rather than in three lists,
/// because most of the rules in section 6.5 are about a directory that has more than one
/// of them: a `viewed` directory that also holds cached files is listed every cycle and
/// takes no rotation slot, and a directory under a pin root gets neither reason at all.
///
/// This type does no I/O and reads no clock. It answers four questions and nothing else:
/// which roots one tier 0 cycle lists, how long a rotation takes, which `viewed` entries
/// the 256-entry cap evicts, and how the whole set splits into the shallow and recursive
/// roots one tier 1 `find` takes.
///
/// Paths are index path bytes ("a/b/c", no leading slash, empty for the location root) and
/// every comparison here is byte-wise. A server name need not be valid UTF-8 (section 5.4),
/// so a `String` round trip would silently merge two different directories into one.
public struct RootSet: Sendable {

    /// One directory, with every reason it is watched.
    public struct Entry: Equatable, Sendable {
        /// Index path bytes; empty `Data` is the location root.
        public var path: Data
        public var reasons: Set<RootReason>
        /// The most recent time any reason was refreshed. This is the `viewed` LRU key:
        /// section 6.5 evicts "the least recently enumerated".
        public var lastSeen: Double
        /// When tier 0 last `readdir`'d it. This is the rotation key, and it is separate
        /// from `lastSeen` on purpose: a directory can be re-enumerated by the extension
        /// without the agent having listed it, and it is the listing that the round-robin
        /// of section 6.5 is fair about.
        public var lastListed: Double

        public init(path: Data, reasons: Set<RootReason>, lastSeen: Double = 0, lastListed: Double = 0) {
            self.path = path
            self.reasons = reasons
            self.lastSeen = lastSeen
            self.lastListed = lastListed
        }

        /// True when the only reason to watch it is that it holds cached files. These are
        /// the entries the tier 0 rotation applies to; everything else is listed every
        /// cycle.
        public var isMaterializedOnly: Bool {
            reasons.contains(.materialized) && !reasons.contains(.pinned) && !reasons.contains(.viewed)
        }
    }

    /// Section 6.5: "the viewed set holds at most 256 directories per location, evicting
    /// the least recently enumerated".
    public static let viewedCap = 256
    /// Section 6.5: "at most 64 materialized-only roots, taken round-robin in order of
    /// least recent listing".
    public static let materializedPerCycle = 64

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: Tier 0

    /// The roots one tier 0 cycle lists: every `viewed` and `pinned` root, plus at most
    /// `perCycle` materialized-only roots in order of least recent listing.
    ///
    /// The rotation is the whole point of section 6.5's cap on tier 0's cost: "a photo
    /// library browsed under a one-month TTL leaves thousands of directories holding one
    /// downloaded file each, and a `readdir` of every one per cycle is not proportional to
    /// anything the user is looking at."
    ///
    /// `fullSweep` suspends the rotation for that one cycle, which is section 6.4's "at
    /// tier 0 a `readdir` of every root with the rotation of section 6.5 suspended for
    /// that one cycle" - the reconnect and insurance passes, where missing a directory for
    /// another `ceil(M / 64)` cycles is exactly what the pass exists to prevent.
    ///
    /// The `viewed` cap and the pin-root exclusions are invariants of the set the caller
    /// maintains as it adds entries (`viewedEvictions`, `isUnderPinRoot`); this returns
    /// what is in `entries` and does not re-apply them, so one cycle is not silently
    /// different from the table `status` prints.
    public func tier0Cycle(fullSweep: Bool = false, perCycle: Int = RootSet.materializedPerCycle) -> [Data] {
        var out: [Data] = []
        var seen: Set<Data> = []
        var rotating: [Entry] = []

        for entry in entries {
            if entry.isMaterializedOnly {
                rotating.append(entry)
            } else if entry.reasons.contains(.viewed) || entry.reasons.contains(.pinned) {
                if seen.insert(entry.path).inserted { out.append(entry.path) }
            }
        }

        // Least recent listing first, and the path as a tiebreak so a set that has never
        // been listed still rotates in a stable order rather than in dictionary order.
        rotating.sort { left, right in
            left.lastListed == right.lastListed
                ? RootSet.isOrderedBefore(left.path, right.path)
                : left.lastListed < right.lastListed
        }
        let take = fullSweep ? rotating.count : max(0, perCycle)
        for entry in rotating.prefix(take) where seen.insert(entry.path).inserted {
            out.append(entry.path)
        }
        return out
    }

    /// `ceil(M / perCycle)`: how many cycles a materialized-only directory waits before it
    /// is listed again. `status` shows it when it exceeds one cycle (section 6.5). Zero
    /// when there is nothing rotating.
    public func rotationPeriod(perCycle: Int = RootSet.materializedPerCycle) -> Int {
        let count = entries.reduce(into: 0) { total, entry in
            if entry.isMaterializedOnly { total += 1 }
        }
        guard count > 0 else { return 0 }
        let slots = max(1, perCycle)
        return (count + slots - 1) / slots
    }

    // MARK: The viewed cap

    /// The paths whose `viewed` reason the cap evicts, least recently enumerated first.
    ///
    /// Section 6.5 bounds this reason because "Finder has enumerated" is not "the user has
    /// looked at": `ls -R`, a Spotlight pass or `grep -r` enumerates every directory it
    /// touches, and each would otherwise become a polled root for the rest of the session.
    ///
    /// Only the `viewed` reason is evicted. A path returned here that is also `pinned` or
    /// `materialized` stays in the set for those reasons; the caller removes the reason,
    /// not the row.
    public func viewedEvictions(cap: Int = RootSet.viewedCap) -> [Data] {
        let viewed = entries.filter { $0.reasons.contains(.viewed) }
        let limit = max(0, cap)
        guard viewed.count > limit else { return [] }
        let sorted = viewed.sorted { left, right in
            left.lastSeen == right.lastSeen
                ? RootSet.isOrderedBefore(left.path, right.path)
                : left.lastSeen < right.lastSeen
        }
        return sorted.prefix(viewed.count - limit).map(\.path)
    }

    // MARK: Pin roots

    /// Section 6.5: "a directory under a recursive pin root is never added to it
    /// [`viewed`], since the pin's recursive watch already covers it", and "the
    /// `materialized` reason too skips directories under a pin root".
    ///
    /// True when `path` is *strictly* under some pinned root. The pin root itself is not
    /// under itself: it is in the set on its own account, as the recursive root.
    public func isUnderPinRoot(_ path: Data) -> Bool {
        for entry in entries where entry.reasons.contains(.pinned) {
            if RootSet.isStrictlyUnder(path, root: entry.path) { return true }
        }
        return false
    }

    // MARK: Tier 1

    /// Section 6.4 passes the whole set to one `find` per shape, so this splits it in two:
    /// the shallow roots take `-maxdepth 1` and the recursive ones do not.
    ///
    /// A pinned entry is recursive whatever else it is; everything else is shallow. A
    /// shallow root that lies under a recursive one is dropped, because the recursive
    /// `find` already walks it and a duplicate root only costs the server another walk of
    /// the same subtree. That can only happen if the caller let section 6.5's pin-root
    /// exclusion slip, so it is a guard rather than the normal path.
    public func sweepRoots() -> (shallow: [Data], recursive: [Data]) {
        var recursive: [Data] = []
        var recursiveSeen: Set<Data> = []
        for entry in entries where entry.reasons.contains(.pinned) {
            if recursiveSeen.insert(entry.path).inserted { recursive.append(entry.path) }
        }

        var shallow: [Data] = []
        var shallowSeen: Set<Data> = []
        for entry in entries {
            guard !entry.reasons.contains(.pinned) else { continue }
            guard entry.reasons.contains(.materialized) || entry.reasons.contains(.viewed) else { continue }
            guard !recursive.contains(where: { RootSet.isStrictlyUnder(entry.path, root: $0) }) else { continue }
            if shallowSeen.insert(entry.path).inserted { shallow.append(entry.path) }
        }
        return (shallow, recursive)
    }

    // MARK: Byte-wise path containment

    /// True when `path` lies strictly under `root`.
    ///
    /// A path P is under a root R when R is the location root (the empty path, which
    /// contains everything) or P starts with R followed by "/". The separator test is what
    /// keeps `Photos2` from being read as a child of `Photos`. Bytes, never `String`s: a
    /// server name need not be valid UTF-8 (section 5.4), and two names that differ only
    /// in an invalid byte would compare equal after a lossy decode.
    public static func isStrictlyUnder(_ path: Data, root: Data) -> Bool {
        if root.isEmpty { return !path.isEmpty }
        guard path.count > root.count else { return false }
        var pathIndex = path.startIndex
        var rootIndex = root.startIndex
        while rootIndex < root.endIndex {
            if path[pathIndex] != root[rootIndex] { return false }
            pathIndex = path.index(after: pathIndex)
            rootIndex = root.index(after: rootIndex)
        }
        return path[pathIndex] == 0x2F
    }

    /// A total byte order, used only as a tiebreak so that two entries with the same
    /// timestamp still sort deterministically.
    private static func isOrderedBefore(_ left: Data, _ right: Data) -> Bool {
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex
        while leftIndex < left.endIndex, rightIndex < right.endIndex {
            let a = left[leftIndex], b = right[rightIndex]
            if a != b { return a < b }
            leftIndex = left.index(after: leftIndex)
            rightIndex = right.index(after: rightIndex)
        }
        return left.count < right.count
    }
}

/// Why a directory is in the root set (DESIGN.md section 6.5).
public enum RootReason: String, Sendable, CaseIterable {
    /// It contains at least one materialized file. Leaves when the last one is evicted.
    case materialized
    /// It is a pin root, watched recursively with excluded subtrees pruned.
    case pinned
    /// The extension has been asked to enumerate it this session. Leaves when the
    /// 256-entry cap evicts it, or when the agent restarts: S3 measured that the system
    /// gives no second enumeration of a folder, so there is no later call to time from.
    case viewed
}
