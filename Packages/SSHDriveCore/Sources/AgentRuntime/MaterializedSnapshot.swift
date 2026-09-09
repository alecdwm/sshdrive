import Foundation

/// The last drained `enumeratorForMaterializedItems()` answer for one location, with when
/// it was taken (DESIGN.md sections 6.5, 7, 8.1).
///
/// Three things walk the system's materialized set: section 6.4's change-detection cycle
/// (which sources the `materialized` reason of the root set from it), section 7's TTL pass
/// (which is what it is *for*), and `sshdrive status` (whose Cache and Pins lines report
/// what is downloaded). The first two already take it on their own schedules, so a walk of
/// the replica for the third is paid to learn what one of the others learnt a moment
/// earlier.
///
/// What makes reusing it correct rather than merely cheap is that the set does not change
/// silently: the extension reports `materializedItemsDidChange` whenever it moves, and the
/// agent's handler drains and records here (section 6.5). So an entry taken inside the
/// freshness window is the current set, not a stale one, and `status` drains for itself
/// when there is no entry or the entry is older than that.
///
/// A lock rather than an actor: it is read from off every actor - that is the point - and
/// it holds two fields.
public final class MaterializedSnapshot: @unchecked Sendable {
    /// How old an entry `status` will still use. One TTL pass (section 7's five minutes)
    /// is the natural bound: past it the pass has been round again and recorded a newer
    /// one, so an entry older than this means nothing has walked the replica in a while
    /// and `status` may as well ask.
    public static let freshnessSeconds: Double = 300

    private let lock = NSLock()
    private var identifiers: [String] = []
    private var takenAt: Double = 0
    private var everRecorded = false

    public init() {}

    /// Records a drain. `nil` is the system having no manager for the domain, which is
    /// "no news" and never "the user evicted everything" (section 6.5): it records
    /// nothing, so a later reader falls back to draining rather than believing an empty
    /// set.
    public func record(_ identifiers: [String]?, at now: Double) {
        guard let identifiers else { return }
        lock.lock()
        self.identifiers = identifiers
        self.takenAt = now
        self.everRecorded = true
        lock.unlock()
    }

    /// The recorded set if it is younger than `within`, and nil otherwise.
    public func fresh(
        at now: Double, within seconds: Double = MaterializedSnapshot.freshnessSeconds
    ) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard everRecorded, now - takenAt <= seconds, now >= takenAt else { return nil }
        return identifiers
    }

    /// When the entry `status` used was taken, for the report's own honesty.
    public var takenAtOrNil: Double? {
        lock.lock()
        defer { lock.unlock() }
        return everRecorded ? takenAt : nil
    }
}
