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
    public func refuseEviction(identifier: String, report: [String: Any]) {
        lock.lock(); _evictionRefusals[identifier] = report; lock.unlock()
    }

    public func allowEviction(identifier: String) {
        lock.lock(); _evictionRefusals.removeValue(forKey: identifier); lock.unlock()
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
        lock.lock(); defer { lock.unlock() }
        _calls.append(.materialized(locationID: locationID))
        if _unmanaged.contains(locationID) { return nil }
        return _materialized[locationID] ?? []
    }

    public func pendingIdentifiers(locationID: String) async -> [String]? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.pending(locationID: locationID))
        if _unmanaged.contains(locationID) { return nil }
        return _pending[locationID] ?? []
    }

    public func evict(locationID: String, identifier: String) async -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.evict(locationID: locationID, identifier: identifier))
        if let refusal = _evictionRefusals[identifier] {
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
        return _times[url.path]
    }

    public func statReport(url: URL, readFirst: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
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
