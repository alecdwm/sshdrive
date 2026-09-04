import Foundation

/// DESIGN.md section 7.1.1's "one rule", as a pure value.
///
/// Two words are used strictly (section 7.1): **pinned** and **excluded** are *markers* a
/// user places on a path; **kept** is the *effect* at an item, which is whether the
/// nearest marker at or above it is a pin. Kept is what the system, the eviction loop, the
/// badge and the Finder menu act on, and it is what this type computes.
///
/// Nothing here does I/O or reads a clock. It answers four questions: what the effective
/// state of a path is, which of section 7.1.1's five situations an item is in, what the
/// smallest marker change is that makes an item kept or not kept (invariant 3), and which
/// explicit states a change wipes out beneath it (invariant 2).
///
/// Paths are index path bytes ("a/b/c", no leading slash, empty `Data` for the location
/// root) and every comparison is byte-wise, because a server name need not be valid UTF-8
/// (section 5.4) and a `String` round trip would merge two different paths into one.
public enum PinPolicy {

    /// The `pin_state` column, spelled out (section 5.3).
    public enum Marker: Int64, Sendable, CaseIterable {
        case excluded = -1
        case inherit = 0
        case pinned = 1

        public init(rawMarker: Int64) {
            switch rawMarker {
            case 1: self = .pinned
            case -1: self = .excluded
            default: self = .inherit
            }
        }

        public var isExplicit: Bool { self != .inherit }
    }

    /// What the user asked for. Section 7.1.1: "there are only two user-facing operations",
    /// and each is a statement about the effective state, never about a marker.
    public enum Request: String, Sendable {
        /// `sshdrive pin`, Finder's "Keep Downloaded".
        case keep
        /// `sshdrive unpin`, Finder's "Don't Keep Downloaded".
        case dontKeep
    }

    /// Section 7.1.1's five situations. Every item is in exactly one of them.
    public enum Situation: String, Sendable {
        /// A. no marker at or above.
        case plain
        /// B. `pinned` on this item.
        case pinRoot
        /// C. `pinned` on an ancestor.
        case inheritingPin
        /// D. `excluded` on this item.
        case exclusionRoot
        /// E. `excluded` on an ancestor.
        case inheritingExclusion

        public var isKept: Bool { self == .pinRoot || self == .inheritingPin }
    }

    /// What a `pin` or `unpin` does to one path.
    public struct Change: Equatable, Sendable {
        public var situation: Situation
        /// True when the request already holds and nothing is written. Section 7.1.1's
        /// table: the CLI says so, and Finder never offers the entry at all.
        public var isNoOp: Bool
        /// The marker to write on the path itself. Nil only for a no-op.
        public var newMarker: Marker?
        /// Invariant 2: "any change to a path's explicit state ... first deletes every
        /// explicit state beneath that path". A no-op clears nothing.
        public var clearsDescendants: Bool
        /// The effective state after the change, which is what the row's `kept` column and
        /// the served `contentPolicy` become.
        public var keptAfter: Bool
        /// One sentence for the CLI. Finder has no output channel (section 7.1.1).
        public var note: String

        public init(
            situation: Situation, isNoOp: Bool, newMarker: Marker?, clearsDescendants: Bool,
            keptAfter: Bool, note: String
        ) {
            self.situation = situation
            self.isNoOp = isNoOp
            self.newMarker = newMarker
            self.clearsDescendants = clearsDescendants
            self.keptAfter = keptAfter
            self.note = note
        }
    }

    // MARK: The effective state

    /// The effective state from the markers at and above an item, nearest first.
    ///
    /// "The effective state of any item is the nearest explicit state at or above it in
    /// the tree" (section 7.1.1). `markersNearestFirst` therefore starts with the item's
    /// own marker and walks upwards to the root; `.inherit` entries are skipped, and an
    /// item with nothing explicit anywhere above it is not kept.
    public static func kept(markersNearestFirst: [Marker]) -> Bool {
        for marker in markersNearestFirst where marker.isExplicit {
            return marker == .pinned
        }
        return false
    }

    /// The same answer with the situation that produced it.
    public static func situation(own: Marker, nearestAncestor: Marker) -> Situation {
        switch own {
        case .pinned: return .pinRoot
        case .excluded: return .exclusionRoot
        case .inherit:
            switch nearestAncestor {
            case .pinned: return .inheritingPin
            case .excluded: return .inheritingExclusion
            case .inherit: return .plain
            }
        }
    }

    // MARK: The smallest change that produces the asked-for effect

    /// Section 7.1.1's table, row by row.
    ///
    /// Invariant 3, "minimal markers": the handler writes the smallest explicit state that
    /// produces the asked-for effective result - removing an exclusion rather than adding
    /// a pin inside an already-kept subtree, removing a pin rather than adding an exclusion
    /// when nothing above is kept. Invariant 2 is what makes that safe: a redundant nested
    /// pin could never behave differently from inheriting, because any change to the
    /// ancestor wipes it.
    ///
    /// The one case that needs spelling out is situation D with no pin above it: markers
    /// move with their paths, so an exclusion can end up outside the kept tree it was made
    /// in. "Make this kept" there removes the exclusion *and* writes `pinned`, since
    /// removing it alone would leave the item inheriting nothing.
    public static func plan(
        _ request: Request, own: Marker, nearestAncestor: Marker
    ) -> Change {
        let situation = self.situation(own: own, nearestAncestor: nearestAncestor)
        let ancestorKeeps = nearestAncestor == .pinned

        switch (request, situation) {
        case (.keep, .plain):
            return Change(
                situation: situation, isNoOp: false, newMarker: .pinned,
                clearsDescendants: true, keptAfter: true, note: "pinned")

        case (.keep, .pinRoot):
            // "CLI only: re-asserts the pin, clearing the subtree (the one-command reset)."
            return Change(
                situation: situation, isNoOp: false, newMarker: .pinned,
                clearsDescendants: true, keptAfter: true,
                note: "already pinned; the pin was re-asserted and the subtree reset")

        case (.keep, .inheritingPin):
            return Change(
                situation: situation, isNoOp: true, newMarker: nil,
                clearsDescendants: false, keptAfter: true,
                note: "already kept by a pin above it")

        case (.keep, .exclusionRoot):
            // Removing the exclusion is enough only when something above still pins.
            let marker: Marker = ancestorKeeps ? .inherit : .pinned
            return Change(
                situation: situation, isNoOp: false, newMarker: marker,
                clearsDescendants: true, keptAfter: true,
                note: ancestorKeeps
                    ? "exclusion removed; the pin above it keeps this again"
                    : "exclusion removed and pinned, since nothing above it is pinned")

        case (.keep, .inheritingExclusion):
            return Change(
                situation: situation, isNoOp: false, newMarker: .pinned,
                clearsDescendants: true, keptAfter: true,
                note: "pinned below an exclusion")

        case (.dontKeep, .plain):
            return Change(
                situation: situation, isNoOp: true, newMarker: nil,
                clearsDescendants: false, keptAfter: false, note: "not kept already")

        case (.dontKeep, .pinRoot):
            // Removing the pin, not adding an exclusion: the smallest marker that produces
            // "not kept" unless an ancestor pin would take over, in which case the item
            // does have to be excluded.
            let marker: Marker = ancestorKeeps ? .excluded : .inherit
            return Change(
                situation: situation, isNoOp: false, newMarker: marker,
                clearsDescendants: true, keptAfter: false,
                note: ancestorKeeps
                    ? "pin removed and excluded, since a pin above it would keep it"
                    : "pin removed; the content stays and falls under the TTL")

        case (.dontKeep, .inheritingPin):
            return Change(
                situation: situation, isNoOp: false, newMarker: .excluded,
                clearsDescendants: true, keptAfter: false,
                note: "excluded from the pin above it; the content stays and falls under the TTL")

        case (.dontKeep, .exclusionRoot):
            return Change(
                situation: situation, isNoOp: true, newMarker: nil,
                clearsDescendants: false, keptAfter: false, note: "already excluded")

        case (.dontKeep, .inheritingExclusion):
            return Change(
                situation: situation, isNoOp: true, newMarker: nil,
                clearsDescendants: false, keptAfter: false,
                note: "already excluded by a marker above it")
        }
    }

    // MARK: Byte-wise paths

    /// Every ancestor of `path`, nearest first, ending with the location root (empty
    /// `Data`). The path itself is not included.
    public static func ancestors(of path: Data) -> [Data] {
        guard !path.isEmpty else { return [] }
        var out: [Data] = []
        var current = path
        while let slash = current.lastIndex(of: 0x2F) {
            current = Data(current.prefix(upTo: slash))
            out.append(current)
        }
        out.append(Data())
        return out
    }

    /// True when `path` lies strictly under `root`. Shares its definition with the root
    /// set (section 6.5), which asks the same question of the same bytes.
    public static func isStrictlyUnder(_ path: Data, root: Data) -> Bool {
        RootSet.isStrictlyUnder(path, root: root)
    }
}

/// The explicit markers of one location, which is what the `pin_state` column holds.
///
/// A value rather than a query against the index, so that section 7.1.1's rules can be
/// tested without a database and so the agent can evaluate a whole subtree in one pass
/// (a pin change rewrites every known descendant, section 7.1 step 2).
public struct PinMarkerSet: Sendable, Equatable {
    /// Only the explicit ones. A path absent here inherits.
    public private(set) var markers: [Data: PinPolicy.Marker]

    public init(markers: [Data: PinPolicy.Marker] = [:]) {
        self.markers = markers.filter { $0.value.isExplicit }
    }

    /// Built from `(path, pin_state)` pairs as the index stores them.
    public init(rows: [(path: Data, marker: Int64)]) {
        var markers: [Data: PinPolicy.Marker] = [:]
        for row in rows {
            let marker = PinPolicy.Marker(rawMarker: row.marker)
            if marker.isExplicit { markers[row.path] = marker }
        }
        self.markers = markers
    }

    public var isEmpty: Bool { markers.isEmpty }

    public var pinRoots: [Data] {
        markers.filter { $0.value == .pinned }.keys.sorted { $0.lexicographicallyPrecedes($1) }
    }

    public var exclusions: [Data] {
        markers.filter { $0.value == .excluded }.keys.sorted { $0.lexicographicallyPrecedes($1) }
    }

    public func marker(at path: Data) -> PinPolicy.Marker { markers[path] ?? .inherit }

    /// The nearest explicit marker strictly above `path`, and where it sits.
    public func nearestAncestorMarker(of path: Data) -> (path: Data, marker: PinPolicy.Marker)? {
        for ancestor in PinPolicy.ancestors(of: path) {
            let marker = marker(at: ancestor)
            if marker.isExplicit { return (ancestor, marker) }
        }
        return nil
    }

    /// The effective state of a path: the nearest marker at or above it is a pin.
    public func isKept(_ path: Data) -> Bool {
        if marker(at: path).isExplicit { return marker(at: path) == .pinned }
        return nearestAncestorMarker(of: path)?.marker == .pinned
    }

    public func situation(of path: Data) -> PinPolicy.Situation {
        PinPolicy.situation(
            own: marker(at: path),
            nearestAncestor: nearestAncestorMarker(of: path)?.marker ?? .inherit)
    }

    /// The change a request makes at `path`, in this set.
    public func plan(_ request: PinPolicy.Request, at path: Data) -> PinPolicy.Change {
        PinPolicy.plan(
            request, own: marker(at: path),
            nearestAncestor: nearestAncestorMarker(of: path)?.marker ?? .inherit)
    }

    /// Invariant 2's victims: every explicit marker strictly beneath `path`.
    public func explicitStatesBelow(_ path: Data) -> [Data] {
        markers.keys
            .filter { PinPolicy.isStrictlyUnder($0, root: path) }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Applies a change, so a caller can ask what the set looks like afterwards without
    /// touching the index. Returns the paths whose effective state the caller must
    /// therefore rewrite (section 7.1 step 2 bumps every known descendant row).
    @discardableResult
    public mutating func apply(_ change: PinPolicy.Change, at path: Data) -> [Data] {
        guard !change.isNoOp, let marker = change.newMarker else { return [] }
        var cleared: [Data] = []
        if change.clearsDescendants {
            cleared = explicitStatesBelow(path)
            for victim in cleared { markers.removeValue(forKey: victim) }
        }
        if marker.isExplicit {
            markers[path] = marker
        } else {
            markers.removeValue(forKey: path)
        }
        return cleared
    }

    /// How many explicit markers sit strictly above this one. `sshdrive pins` indents by
    /// it, so an exclusion is drawn under the pin it sits in and a re-pin under that
    /// (section 7.1's rendering).
    public func ancestorMarkerDepth(of path: Data) -> Int {
        PinPolicy.ancestors(of: path).reduce(into: 0) { total, ancestor in
            if marker(at: ancestor).isExplicit { total += 1 }
        }
    }

    /// The recursive watch of section 6.5 with section 7.1.1's "the recursive watch of
    /// kept subtrees skips excluded subtrees": every exclusion that actually sits inside a
    /// pinned subtree, which is what tier 1 prunes and tier 0 refuses to descend into.
    public func prunedExclusions() -> [Data] {
        exclusions.filter { exclusion in
            nearestAncestorMarker(of: exclusion)?.marker == .pinned
        }
    }
}
