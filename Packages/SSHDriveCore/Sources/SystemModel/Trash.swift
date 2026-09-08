import Foundation
import ProviderCore

/// The trash node the system makes for itself, and what it does with the answer.
///
/// `MQ-075`: fileproviderd creates `.Trash` at `add(domain)` time as a system-owned item
/// and then asks the extension for its children. `MQ-008`: it does this whether or not the
/// domain was added with `supportsSyncingTrash = false`, which is the whole of `B2`.
public struct TrashNode: Equatable, Sendable {
    /// Whether `.Trash` is in the mount. A `ls -la` of the mount lists it while it is.
    public var existsInMount = false
    /// How many times the extension has been asked for the trash container's enumerator.
    public var asks = 0
    /// `MQ-009`: the delete-fail-re-materialize-ask loop, one turn per second, for ever.
    /// It is a count rather than a flag because the symptom is that it never stops.
    public var materializeLoopTurns = 0
    /// True while the loop is running, which is the state in which `ls -la` of the mount
    /// never returns.
    public var isLooping = false
    /// `MQ-010`: the system gave up and took `.Trash` out of the mount.
    public var retired = false
    public var lastFailure: ProviderFailure?
}

extension ModelDomain {

    /// `MQ-075` then `MQ-009`/`MQ-010`: make the node, ask, and do what the answer says.
    func createTrashNodeAndAsk() {
        trash.existsInMount = true
        calls.append(.trashNodeCreated)
        askTrashEnumerator()
    }

    /// One turn. The answer decides whether there is another.
    ///
    /// - `.featureUnsupported` (`NSCocoaErrorDomain` / `NSFeatureUnsupportedError`) makes
    ///   the system throttle, **give up after two attempts** and remove `.Trash` from the
    ///   mount (`MQ-010`).
    /// - `.noSuchItem` makes it delete the trash from disk, fail, re-materialize it and
    ///   ask again about once a second, for ever (`MQ-009`) - the `.Trash` hang.
    func askTrashEnumerator() {
        guard !trash.retired else { return }
        let service = liveProvider()
        trash.asks += 1
        // A test seam of the **model**, not of the product: it lets a scenario answer the
        // trash question the way version 0.1.0 did, which is how `B1` proves the hang is
        // real rather than remembered.
        if let scripted = trashAnswerOverride {
            trash.lastFailure = scripted
            calls.append(.trashEnumeratorRefused(String(describing: scripted)))
            apply(trashFailure: scripted)
            return
        }
        do {
            _ = try service.enumerator(for: .trashContainer)
            // An extension that answered is one that claims to have a trash; nothing in
            // this project ever does, and the model has nothing to model for it.
            trash.isLooping = false
            return
        } catch let failure as ProviderFailure {
            trash.lastFailure = failure
            calls.append(.trashEnumeratorRefused(String(describing: failure)))
            apply(trashFailure: failure)
        } catch {
            trash.lastFailure = .cannotSynchronize
            apply(trashFailure: .cannotSynchronize)
        }
    }

    private func apply(trashFailure failure: ProviderFailure) {
        switch failure {
        case .featureUnsupported:
            trash.isLooping = false
            if trash.asks >= quirks.int(.featureUnsupportedRetiresTheTrash) {
                trash.retired = true
                trash.existsInMount = false
                calls.append(.trashRemovedFromMount)
            } else {
                // The throttle between the two attempts. It is a real interval, so a
                // scenario that never advances the clock sees exactly one ask.
                clock.schedule(after: 1) { [weak self] in self?.askTrashEnumerator() }
            }
        default:
            // `MQ-009`. The node is deleted, the delete fails because the node is the
            // system's own, it is re-materialized, and the question is asked again.
            trash.isLooping = true
            trash.materializeLoopTurns += 1
            trash.existsInMount = true
            clock.schedule(after: quirks.duration(.noSuchItemOnTheTrashLoopsForEver)) {
                [weak self] in self?.askTrashEnumerator()
            }
        }
    }

    /// `ls -la` of the mount. It returns unless the trash loop of `MQ-009` is running, in
    /// which case it never does - which is the symptom the whole trash contract exists to
    /// avoid.
    public func listMountRoot() -> [String]? {
        guard !trash.isLooping else { return nil }
        var names = replica.listing(of: .rootContainer)
        if trash.existsInMount { names.append(".Trash") }
        return names.sorted()
    }
}
