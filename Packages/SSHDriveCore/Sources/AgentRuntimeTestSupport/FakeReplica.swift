import AgentRuntime
import Foundation
import Logging
import ProviderCore

/// The system's side of every File Provider call the agent makes, in memory
/// (docs/testing-architecture.md section 2.3's `ReplicaControlling` row).
///
/// It is deliberately not a fileproviderd: `SystemModel.FileProviderD` is that, and it
/// drives `ProviderCore`. This is the *agent's* view - the domain list, the two
/// enumerators, `evictItem`, the two identifier lookups - recorded so a scenario can
/// assert what the agent asked for and in what order, and scriptable so a refusal, a
/// missing manager or a rename can be staged.
///
/// Everything is behind one lock and nothing sleeps: the calls are `async` because the
/// protocol is, not because they wait.
public final class FakeReplica: ReplicaControlling, @unchecked Sendable {

    /// One call, as the scenarios name them.
    public enum Call: Equatable, Sendable {
        case domains
        case addDomain(identifier: String, displayName: String, testingModes: [String])
        case removeDomain(identifier: String)
        case signalEnumerator(locationID: String, container: String)
        case signalErrorResolved(locationID: String)
        case materialized(locationID: String)
        case pending(locationID: String)
        case evict(locationID: String, identifier: String)
        case userVisibleURL(locationID: String, identifier: String)
        case identifierForFile(path: String)
        case stabilize(locationID: String)
        case testingOperations(locationID: String, run: Bool)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _domains: [ReplicaDomain] = []
    private var _materialized: [String: [String]] = [:]
    private var _pending: [String: [String]] = [:]
    private var _times: [String: (atime: Double, mtime: Double)] = [:]
    private var _evictionRefusals: [String: [String: Any]] = [:]
    /// How many more times each staged refusal answers before the item becomes evictable.
    /// Nil is "for ever", which is what `refuseEviction` used to mean and still does.
    /// A finite count is `MQ-017`/`MQ-034`'s shape: the system is still finishing a
    /// modification, or has not yet re-read a row whose policy just changed, and the same
    /// call a moment later succeeds - which is what the doubling backoff is for.
    private var _refusalsRemaining: [String: Int] = [:]
    /// `MQ-060`, scripted the other way round. **Measured** (S4, 2026-09-04, macOS 26.4):
    /// a launchd agent's `stat` and `open` under its *own* domain's mount draw no TCC
    /// prompt and no `EPERM`, because the access is evaluated as
    /// `kTCCServiceFileProviderDomain` with our domain as the indirect object. The rule in
    /// the model is therefore a **no-op**: nothing is gated, and `false` here is the
    /// measured world. `true` is the counterfactual - "TCC would deny it" - which no
    /// scenario may treat as measured behaviour (TCC is VM-only,
    /// `docs/testing-architecture.md` section 7); it exists so a scenario can pin down
    /// what our code *does* if that rule ever changes, which is the thing we control.
    private var _tccDenied = false
    /// A hook on `pendingIdentifiers`; see `setOnPendingIdentifiers`.
    private var _onPending: (@Sendable (String) -> Void)?
    /// A hook on `materializedIdentifiers`; see `setOnMaterializedIdentifiers`.
    private var _onMaterialized: (@Sendable (String) async -> Void)?
    private var _evicted: [String] = []
    /// A domain the system has no manager for: every call for it answers "no news"
    /// (section 6.5), which is never "the user evicted everything".
    private var _unmanaged: Set<String> = []
    /// What `add(domain)` throws, if anything - S9's 4099 that arrives *after* the call
    /// landed is staged by throwing while still recording the domain.
    private var _addFailure: (error: Error, landsAnyway: Bool)?
    /// Where the mount lives, so `getUserVisibleURL` answers something a `stat` can be
    /// staged against.
    public var mountRoot: URL

    public init(mountRoot: URL = URL(fileURLWithPath: "/tmp/sshdrive-fake-replica")) {
        self.mountRoot = mountRoot
    }

    // MARK: What a scenario reads

    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public func callsMatching(_ predicate: (Call) -> Bool) -> [Call] {
        calls.filter(predicate)
    }

    public var signalledContainers: [String] {
        calls.compactMap {
            if case let .signalEnumerator(_, container) = $0 { return container }
            return nil
        }
    }

    public var resolvedSignalCount: Int {
        calls.filter { if case .signalErrorResolved = $0 { return true } else { return false } }
            .count
    }

    public var evictedIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return _evicted
    }

    public var domainList: [ReplicaDomain] {
        lock.lock(); defer { lock.unlock() }
        return _domains
    }

    public func resetCalls() {
        lock.lock(); _calls.removeAll(); lock.unlock()
    }

    // MARK: What a scenario stages

    public func setMaterialized(_ identifiers: [String], locationID: String) {
        lock.lock(); _materialized[locationID] = identifiers; lock.unlock()
    }

    public func setPending(_ identifiers: [String], locationID: String) {
        lock.lock(); _pending[locationID] = identifiers; lock.unlock()
    }

    /// The replica's own atime and mtime for one item, which is what section 7's TTL rule
    /// reads before deciding (S4: an eviction moves atime, so it is read first).
    public func setReplicaTimes(
        identifier: String, atime: Double, mtime: Double, locationID: String
    ) {
        lock.lock()
        _times[url(locationID: locationID, identifier: identifier).path] = (atime, mtime)
        lock.unlock()
    }

    /// Refuse an eviction, field by field, the way the system does. `MQ-018`: the code
    /// says nothing about why, so this takes the whole dictionary.
    ///
    /// `times` is how many calls are refused before the item becomes evictable; nil, the
    /// default, refuses for ever. A finite count is what the doubling backoff of section
    /// 5.5 is written against (`MQ-017`, `MQ-034`).
    public func refuseEviction(identifier: String, report: [String: Any], times: Int? = nil) {
        lock.lock()
        _evictionRefusals[identifier] = report
        if let times { _refusalsRemaining[identifier] = times }
        lock.unlock()
    }

    public func allowEviction(identifier: String) {
        lock.lock()
        _evictionRefusals.removeValue(forKey: identifier)
        _refusalsRemaining.removeValue(forKey: identifier)
        lock.unlock()
    }

    /// `MQ-060` the other way round: the counterfactual in which TCC denies the agent its
    /// own domain's mount, so `getUserVisibleURL` and the `lstat` behind it fail with
    /// `EPERM`. **Never a measurement** - the measured answer is that the access is
    /// allowed silently (see `_tccDenied`) - only a way to ask what our code does with a
    /// denial it has never seen.
    public func setTCCDenial(_ value: Bool = true) {
        lock.lock(); _tccDenied = value; lock.unlock()
    }

    /// `EPERM` as a `stat` under a denied mount would report it.
    public static func tccDenial(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(EPERM),
            userInfo: [
                NSLocalizedDescriptionKey: "Operation not permitted",
                NSFilePathErrorKey: path,
            ])
    }

    /// No manager for this domain: it is being added or removed (section 6.5).
    public func setUnmanaged(_ locationID: String, _ value: Bool = true) {
        lock.lock()
        if value { _unmanaged.insert(locationID) } else { _unmanaged.remove(locationID) }
        lock.unlock()
    }

    /// `MQ-052`: `add(domain)` may report `NSCocoaErrorDomain` 4099 *after* the call has
    /// landed. `landsAnyway` is that case; `false` is a domain that really is not there.
    public func failNextAdd(with error: Error, landsAnyway: Bool) {
        lock.lock(); _addFailure = (error, landsAnyway); lock.unlock()
    }

    private func url(locationID: String, identifier: String) -> URL {
        mountRoot.appendingPathComponent(locationID).appendingPathComponent(identifier)
    }

    // MARK: ReplicaControlling

    public func domains() async throws -> [ReplicaDomain] {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.domains)
        return _domains
    }

    /// `MQ-051`: the same identifier with a new display name **renames in place**. The
    /// replica's materialized set, its pending set and its atimes are untouched, which is
    /// exactly what `P8` asserts.
    public func addDomain(_ domain: ReplicaDomain, testingModes: [String]) async throws {
        lock.lock()
        _calls.append(
            .addDomain(
                identifier: domain.identifier, displayName: domain.displayName,
                testingModes: testingModes))
        let failure = _addFailure
        _addFailure = nil
        if let index = _domains.firstIndex(where: { $0.identifier == domain.identifier }) {
            _domains[index] = domain
        } else {
            _domains.append(domain)
        }
        if let failure, !failure.landsAnyway {
            _domains.removeAll { $0.identifier == domain.identifier }
        }
        lock.unlock()
        if let failure { throw failure.error }
    }

    public func removeDomain(_ domain: ReplicaDomain) async throws {
        lock.lock()
        _calls.append(.removeDomain(identifier: domain.identifier))
        _domains.removeAll { $0.identifier == domain.identifier }
        lock.unlock()
    }

    public func signalEnumerator(
        locationID: String, container: ProviderItemIdentifier
    ) async throws {
        lock.lock()
        _calls.append(
            .signalEnumerator(locationID: locationID, container: container.rawValue))
        lock.unlock()
    }

    public func signalErrorResolved(locationID: String) async throws {
        lock.lock()
        _calls.append(.signalErrorResolved(locationID: locationID))
        lock.unlock()
    }

    public func materializedIdentifiers(locationID: String) async -> [String]? {
        lock.lock()
        _calls.append(.materialized(locationID: locationID))
        let hook = _onMaterialized
        let unmanaged = _unmanaged.contains(locationID)
        let answer = _materialized[locationID] ?? []
        lock.unlock()
        // Awaited with the lock down, exactly like `pendingIdentifiers`' hook. This is the
        // one File Provider call `status` can still make for a location whose materialized
        // set nothing has published recently, so it is where `N10` parks a location to
        // watch the per-location deadline fire (section 8).
        await hook?(locationID)
        return unmanaged ? nil : answer
    }

    /// Runs on every `materializedIdentifiers`, before the answer is given, and is
    /// awaited - so a scenario may park the call there. Nil clears it.
    public func setOnMaterializedIdentifiers(_ body: (@Sendable (String) async -> Void)?) {
        lock.lock(); _onMaterialized = body; lock.unlock()
    }

    public func pendingIdentifiers(locationID: String) async -> [String]? {
        lock.lock()
        _calls.append(.pending(locationID: locationID))
        let hook = _onPending
        let unmanaged = _unmanaged.contains(locationID)
        let answer = _pending[locationID] ?? []
        lock.unlock()
        // Called with the lock down, so a hook may call back in. This is the first thing
        // `ChangeDetector.runCycle` asks the replica for after it starts its own
        // stopwatch, which is where a scenario hangs the clock advance that makes a cycle
        // *take* time without taking it (`H10`).
        hook?(locationID)
        return unmanaged ? nil : answer
    }

    /// Runs on every `pendingIdentifiers`, before the answer is given. Nil clears it.
    public func setOnPendingIdentifiers(_ body: (@Sendable (String) -> Void)?) {
        lock.lock(); _onPending = body; lock.unlock()
    }

    public func evict(locationID: String, identifier: String) async -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.evict(locationID: locationID, identifier: identifier))
        if let refusal = _evictionRefusals[identifier] {
            if let remaining = _refusalsRemaining[identifier] {
                if remaining <= 1 {
                    _refusalsRemaining.removeValue(forKey: identifier)
                    _evictionRefusals.removeValue(forKey: identifier)
                } else {
                    _refusalsRemaining[identifier] = remaining - 1
                }
            }
            var report = refusal
            report["evicted"] = false
            return report
        }
        _evicted.append(identifier)
        _materialized[locationID]?.removeAll { $0 == identifier }
        return ["evicted": true]
    }

    public func userVisibleURL(locationID: String, identifier: String) async throws -> URL {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.userVisibleURL(locationID: locationID, identifier: identifier))
        if _unmanaged.contains(locationID) {
            throw SSHDriveFakeReplicaError.noDomain(locationID)
        }
        // `MQ-060` is a **no-op rule**: the measured world has no gate here at all, so
        // this returns the URL and the TTL loop's `lstat` behind it just works. The throw
        // is the scripted counterfactual and nothing else.
        if _tccDenied {
            throw FakeReplica.tccDenial(
                path: url(locationID: locationID, identifier: identifier).path)
        }
        return url(locationID: locationID, identifier: identifier)
    }

    public func identifierForUserVisibleFile(at url: URL, locationID: String) async -> String? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.identifierForFile(path: url.path))
        let prefix = mountRoot.appendingPathComponent(locationID).path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return String(url.path.dropFirst(prefix.count))
    }

    public func replicaTimes(url: URL) -> (atime: Double, mtime: Double)? {
        lock.lock(); defer { lock.unlock() }
        // The `lstat` of our own mount is ungated (`MQ-060`); under the scripted denial it
        // is the `EPERM` a `stat` would return, which reaches the caller as "no times".
        if _tccDenied { return nil }
        return _times[url.path]
    }

    public func statReport(url: URL, readFirst: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if _tccDenied {
            return [
                "path": url.path, "read": readFirst,
                "error": FakeReplica.tccDenial(path: url.path).localizedDescription,
            ]
        }
        guard let times = _times[url.path] else { return ["path": url.path, "read": readFirst] }
        return [
            "path": url.path, "read": readFirst,
            "atime": Int(times.atime), "mtime": Int(times.mtime),
        ]
    }

    public func stabilize(locationID: String) async throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.stabilize(locationID: locationID))
        return ["stabilizeSeconds": 0, "waitForChangesSeconds": 0]
    }

    public func testingOperations(locationID: String, run: Bool) async throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.testingOperations(locationID: locationID, run: run))
        return ["available": []]
    }

    public func describe(error: Error) -> [String: Any] {
        let nsError = error as NSError
        return [
            "errorDomain": nsError.domain,
            "errorCode": nsError.code,
            "errorDescription": nsError.localizedDescription,
        ]
    }
}

public enum SSHDriveFakeReplicaError: Error, LocalizedError {
    case noDomain(String)

    public var errorDescription: String? {
        switch self {
        case .noDomain(let id): return "The system has no domain \(id)."
        }
    }
}
