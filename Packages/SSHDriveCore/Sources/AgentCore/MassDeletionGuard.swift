import Foundation

/// DESIGN.md section 6.4's mass-deletion guard.
///
/// "A poll that finds a directory empty is not always a directory that was emptied. A ZFS
/// dataset not yet imported after the NAS rebooted, an external drive not yet mounted, an
/// autofs share that timed out: all present an empty directory at the same path, and the
/// `realpath` check (section 9.1) is satisfied because the mount point itself is still
/// there." Reporting that literally would delete every item beneath it from the replica:
/// the cache, every local xattr and Finder tag with it, and every item would come back
/// under a new identifier, since there are no tombstones (section 5.3).
///
/// So deletions inferred **from a listing** are held when they are implausibly large, and
/// separately whenever the item has a pending local edit. The guard does not apply to
/// explicit delete events from the helper: "an `rm -rf Photos` produces one event per item
/// and is real, while a vanished mount produces no events at all, so holding event-driven
/// deletions would only leave thousands of ghosts in Finder for 35 minutes."
///
/// A pure decision: the times are arguments, the `held` table is passed in, and nothing
/// here writes it.
public struct MassDeletionGuard: Sendable {

    /// "at least half of a directory's known, non-hidden items and at least 20 of them".
    public static let minimumCount = 20
    public static let fractionNumerator = 1
    public static let fractionDenominator = 2
    /// "re-listed after 5 minutes and again after 30".
    public static let firstRecheck: TimeInterval = 300
    public static let secondRecheck: TimeInterval = 1800

    /// What the caller does with this diff's missing paths.
    public struct Decision: Sendable, Equatable {
        /// Reported as deleted now.
        public var apply: [Data]
        /// Recorded in `held` with the time first seen missing, and still shown in Finder.
        public var hold: [Data]
        /// Section 8's status line, e.g. "14 deletions held in Photos". Nil when nothing
        /// is held.
        public var reason: String?

        public init(apply: [Data], hold: [Data], reason: String?) {
            self.apply = apply
            self.hold = hold
            self.reason = reason
        }
    }

    /// One directory's diff.
    public struct Input: Sendable {
        /// The directory whose listing produced the diff, as index path bytes.
        public var directory: Data
        public var isLocationRoot: Bool
        /// Items the index held for that directory before the diff. Non-hidden, because a
        /// directory of dotfiles is not what section 6.4's "half of a directory" is
        /// counting.
        public var knownNonHiddenCount: Int
        /// Paths the listing did not mention.
        public var missing: [Data]
        /// Paths the system lists in `enumeratorForPendingItems()`.
        public var pending: Set<Data>
        /// path -> first-missing time, from the `held` table.
        public var alreadyHeld: [Data: Double]
        public var now: Double

        public init(directory: Data, isLocationRoot: Bool = false, knownNonHiddenCount: Int,
                    missing: [Data], pending: Set<Data> = [], alreadyHeld: [Data: Double] = [:],
                    now: Double) {
            self.directory = directory
            self.isLocationRoot = isLocationRoot
            self.knownNonHiddenCount = knownNonHiddenCount
            self.missing = missing
            self.pending = pending
            self.alreadyHeld = alreadyHeld
            self.now = now
        }
    }

    /// Section 6.4, both halves of it.
    ///
    /// The bulk half: "if one diff would remove at least half of a directory's known,
    /// non-hidden items and at least 20 of them, or would empty the root when the root
    /// previously held anything at all, the missing items are not reported."
    ///
    /// The pending half is independent of every count, and S5 (2026-09-04) is why.
    /// Reporting an item with a pending local edit deleted through the working set does not
    /// lose the edit: the system keeps the local content and re-offers it - but as a
    /// **`createItem`** rather than the `modifyItem` it was. Because the path is still
    /// there on the server (the deletion was wrong, which is the case the guard exists
    /// for), that create is answered `.filenameCollision`, and the system retries a
    /// collided create for ever with no alert (section 5.5, S3). The user's edit then sits
    /// in the mount, never reaches the server, and nothing ever resolves it. So a pending
    /// item is held whatever the counts say, and stays held until the pending edit
    /// resolves - the two re-checks do not release it.
    public static func evaluate(_ input: Input) -> Decision {
        // A listing infers the deletion of a *directory*, not of the file inside it: an
        // `rm -rf Photos` on the server reaches the guard as one missing path, `Photos`,
        // while the pending edit is on `Photos/2026/note.txt`. Matching pending paths
        // exactly would let the directory through and strand the save inside it, which is
        // the whole case this rule exists for, so every ancestor of every pending path
        // counts as pending too.
        let pending = withAncestors(input.pending)
        let bulk = holdsInBulk(
            missingCount: input.missing.count,
            knownNonHiddenCount: input.knownNonHiddenCount,
            isLocationRoot: input.isLocationRoot)

        var apply: [Data] = []
        var hold: [Data] = []
        for path in input.missing {
            if pending.contains(path) {
                hold.append(path)
                continue
            }
            if let firstMissing = input.alreadyHeld[path] {
                // A hold that has run its course is applied even when this diff would
                // hold it in bulk again: the re-checks are the whole mechanism, and a
                // directory that stays empty for 30 minutes is a directory that was
                // emptied. `checksDone: 0` because a caller that does not count its
                // re-checks still gets the right answer from the clock.
                if isDue(firstMissing: firstMissing, now: input.now, checksDone: 0) {
                    apply.append(path)
                } else {
                    hold.append(path)
                }
                continue
            }
            if bulk {
                hold.append(path)
            } else {
                apply.append(path)
            }
        }
        // A path in `alreadyHeld` that this listing mentioned again is in neither list:
        // it reappeared, the hold is cleared by the caller, and nothing was ever reported.
        return Decision(apply: apply, hold: hold, reason: reasonLine(held: hold.count, directory: input.directory,
                                                                    isLocationRoot: input.isLocationRoot))
    }

    /// Every path in `paths`, plus every ancestor directory of each. Byte-level: server
    /// names need not be valid UTF-8 (section 5.4). The location root - the empty path -
    /// is never added; a listing cannot report the root missing.
    public static func withAncestors(_ paths: Set<Data>) -> Set<Data> {
        var out = paths
        for path in paths {
            var bytes = path
            while let separator = bytes.lastIndex(of: 0x2F) {
                bytes = Data(bytes[bytes.startIndex ..< separator])
                if bytes.isEmpty { break }
                out.insert(bytes)
            }
        }
        return out
    }

    /// The size test on its own, so `sshdrive test` and the debug hook can ask it without
    /// a whole diff.
    public static func holdsInBulk(missingCount: Int, knownNonHiddenCount: Int, isLocationRoot: Bool) -> Bool {
        if isLocationRoot, knownNonHiddenCount > 0, missingCount >= knownNonHiddenCount { return true }
        guard missingCount >= minimumCount else { return false }
        // "at least half", as integers: missing * 2 >= known.
        return missingCount * fractionDenominator >= knownNonHiddenCount * fractionNumerator
    }

    /// When a held path is re-checked: first + 5 min, then first + 30 min, then nil - both
    /// re-checks are done and the deletions are applied.
    public static func recheckTime(firstMissing: Double, checksDone: Int) -> Double? {
        switch checksDone {
        case ..<1: return firstMissing + firstRecheck
        case 1: return firstMissing + secondRecheck
        default: return nil
        }
    }

    /// True once both re-checks have passed and the items are still missing.
    ///
    /// Either the caller counted them or the clock did; both answers agree, and the clock
    /// is the one that survives an agent restart, which drops the count and not the `held`
    /// table.
    public static func isDue(firstMissing: Double, now: Double, checksDone: Int) -> Bool {
        if checksDone >= 2 { return true }
        return now >= firstMissing + secondRecheck
    }

    /// Section 8's line: "14 deletions held in Photos".
    private static func reasonLine(held: Int, directory: Data, isLocationRoot: Bool) -> String? {
        guard held > 0 else { return nil }
        let name = (isLocationRoot || directory.isEmpty)
            ? "the location root"
            : String(decoding: lastComponent(of: directory), as: UTF8.self)
        return held == 1 ? "1 deletion held in \(name)" : "\(held) deletions held in \(name)"
    }

    /// The last "/"-separated component, as bytes. Lossily decoded only for this one
    /// status line, never for anything that reaches a server.
    private static func lastComponent(of path: Data) -> Data {
        guard let separator = path.lastIndex(of: 0x2F) else { return path }
        return Data(path[path.index(after: separator)...])
    }
}
