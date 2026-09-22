import AgentRuntime
import FileProvider
import Foundation
import Logging
import ProviderCore
import XPCProtocols

/// `ReplicaControlling` over `NSFileProviderManager` (`docs/design/testing.md`): the
/// domain list, the signals, the two replica enumerators, `evictItem`, the two identifier
/// lookups, and the `lstat` of a replica file.
///
/// The agent is the only process that can make any of them: `NSFileProviderManager` is
/// useless from a sandboxed extension, and reading `~/Library/CloudStorage/...` from the
/// launchd agent is allowed with no TCC prompt because it is our own domain (measured
/// 2026-09-04; `docs/design/eviction.md`).
///
/// Nothing here decides anything. **The error code does not say why**: an item with a
/// pending upload and a kept item both come back as `NSFileProviderErrorNonEvictable`
/// (-2008), and a directory eviction that meets a pending child fails as
/// `NSCocoaErrorDomain` 4101 with a `contentVersionMismatch` underneath - so the refusal
/// crosses the seam as fields, never as a verdict, and `CacheEvictor` logs it and moves on.
struct FileProviderReplica: ReplicaControlling {

    static func manager(_ locationID: String) throws -> NSFileProviderManager {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw SSHDriveAgentError.unknownDomain.asNSError(
                "The system has no domain \(locationID).")
        }
        return manager
    }

    // MARK: Domains

    func domains() async throws -> [ReplicaDomain] {
        try await NSFileProviderManager.domains().map {
            ReplicaDomain(identifier: $0.identifier.rawValue, displayName: $0.displayName)
        }
    }

    func addDomain(_ domain: ReplicaDomain, testingModes: [String]) async throws {
        let system = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domain.identifier),
            displayName: domain.displayName)
        // Only ever set by `sshdrive debug fake add --testing-modes`.
        // `alwaysEnabled` skips the user's approval, `interactive` hands the scheduler to
        // `listAvailableTestingOperations`; the appex's
        // com.apple.developer.fileprovider.testing-mode entitlement is what allows either,
        // and the system does not let a domain give `interactive` back once it has it.
        let modes = Self.testingModes(named: testingModes)
        if !modes.isEmpty { system.testingModes = modes }
        // No trash (`docs/design/names-and-attributes.md`). This property defaults to
        // YES, and with it the system draws a `.Trash` in the mount, syncs it to the
        // extension, and loops on materializing a container we do not serve; anything
        // that stats `.Trash`, such as `ls -la`, waits on that loop (measured
        // 2026-09-04).
        system.supportsSyncingTrash = false
        try await NSFileProviderManager.add(system)
    }

    /// Split out for the macOS-only `MirroredAgentConstantsTests`: these two words are the
    /// whole of what `debug fake add --testing-modes` accepts.
    static func testingModes(named words: [String]) -> NSFileProviderDomain.TestingModes {
        var modes: NSFileProviderDomain.TestingModes = []
        for word in words {
            switch word {
            case MirroredAgentConstants.testingModeAlways: modes.insert(.alwaysEnabled)
            case MirroredAgentConstants.testingModeInteractive: modes.insert(.interactive)
            default: break
            }
        }
        return modes
    }

    func removeDomain(_ domain: ReplicaDomain, mode: DomainRemovalMode) async throws -> String? {
        let system = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domain.identifier),
            displayName: domain.displayName)
        let systemMode: NSFileProviderManager.DomainRemovalMode
        switch mode {
        case .removeAll: systemMode = .removeAll
        case .preserveDownloadedUserData: systemMode = .preserveDownloadedUserData
        }
        return try await NSFileProviderManager.remove(system, mode: systemMode)?.path
    }

    // MARK: Signals

    func signalEnumerator(locationID: String, container: ProviderItemIdentifier) async throws {
        try await Self.manager(locationID)
            .signalEnumerator(for: NSFileProviderItemIdentifier(container.rawValue))
    }

    func signalErrorResolved(locationID: String) async throws {
        try await Self.manager(locationID)
            .signalErrorResolved(NSFileProviderError(.serverUnreachable))
    }

    // MARK: The two enumerators the system keeps for us

    func materializedIdentifiers(locationID: String) async -> [String]? {
        guard let manager = try? Self.manager(locationID) else { return nil }
        return await Self.drain(manager.enumeratorForMaterializedItems(), timeout: 30)
    }

    func pendingIdentifiers(locationID: String) async -> [String]? {
        guard let manager = try? Self.manager(locationID) else { return nil }
        return await Self.drain(manager.enumeratorForPendingItems(), timeout: 30)
    }

    // MARK: Eviction

    func evict(locationID: String, identifier: String) async -> [String: Any] {
        let manager: NSFileProviderManager
        do { manager = try Self.manager(locationID) } catch { return describe(error: error) }
        let error: Error? = await withCheckedContinuation { continuation in
            manager.evictItem(identifier: NSFileProviderItemIdentifier(identifier)) { error in
                continuation.resume(returning: error)
            }
        }
        guard let error else { return ["evicted": true] }
        var report = describe(error: error)
        report["evicted"] = false
        return report
    }

    // MARK: The user-visible file

    func userVisibleURL(locationID: String, identifier: String) async throws -> URL {
        let manager = try Self.manager(locationID)
        return try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(identifier)) {
                url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? SSHDriveAgentError.noSuchItem.asNSError(
                                "No user-visible URL for \(identifier)."))
                }
            }
        }
    }

    func identifierForUserVisibleFile(at url: URL, locationID: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                identifier, domain, _ in
                // A path that answers for another domain is not ours to write a row for.
                guard let identifier, let domain, domain.rawValue == locationID else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: identifier.rawValue)
            }
        }
    }

    /// `lstat` with `AT_SYMLINK_NOFOLLOW`, read **before** the eviction, since an
    /// eviction moves atime.
    func replicaTimes(url: URL) -> (atime: Double, mtime: Double)? {
        var buffer = Foundation.stat()
        guard lstat(url.path, &buffer) == 0 else { return nil }
        return (Double(buffer.st_atimespec.tv_sec), Double(buffer.st_mtimespec.tv_sec))
    }

    func statReport(url: URL, readFirst: Bool) -> [String: Any] {
        var report: [String: Any] = ["path": url.path, "read": readFirst]

        if readFirst {
            // Open and read one byte, the way anything that "uses" the file does. It is
            // made from the agent, so a TCC refusal on the open shows up too.
            let descriptor = open(url.path, O_RDONLY)
            if descriptor < 0 {
                report["openErrno"] = errno
                report["openErrnoName"] = String(cString: strerror(errno))
            } else {
                var byte: UInt8 = 0
                let count = read(descriptor, &byte, 1)
                report["bytesRead"] = count
                close(descriptor)
            }
        }

        var buffer = Foundation.stat()
        guard lstat(url.path, &buffer) == 0 else {
            report["statErrno"] = errno
            report["statErrnoName"] = String(cString: strerror(errno))
            return report
        }
        report["atime"] = buffer.st_atimespec.tv_sec
        report["mtime"] = buffer.st_mtimespec.tv_sec
        report["ctime"] = buffer.st_ctimespec.tv_sec
        report["birthtime"] = buffer.st_birthtimespec.tv_sec
        report["size"] = buffer.st_size
        // A dataless file has no blocks and carries SF_DATALESS (0x40000000), which is how
        // the loop can tell "materialized" from "placeholder" without asking the system.
        report["blocks"] = buffer.st_blocks
        report["flags"] = String(format: "0x%08x", buffer.st_flags)
        report["dataless"] = (buffer.st_flags & MirroredAgentConstants.datalessFlag) != 0
        report["now"] = Int(Date().timeIntervalSince1970)
        return report
    }

    // MARK: The synchronisation barriers

    func stabilize(locationID: String) async throws -> [String: Any] {
        let manager = try Self.manager(locationID)
        let start = Date()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.waitForStabilization { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let stabilized = Date()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.waitForChanges(below: .rootContainer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return [
            "stabilizeSeconds": stabilized.timeIntervalSince(start).rounded(toPlaces: 3),
            "waitForChangesSeconds": Date().timeIntervalSince(stabilized).rounded(toPlaces: 3),
        ]
    }

    /// `listAvailableTestingOperations`, which the appex's
    /// `com.apple.developer.fileprovider.testing-mode` entitlement unlocks. It only returns
    /// operations on a domain added with `NSFileProviderDomainTestingModeInteractive`; on
    /// any other domain it fails, and the error is the answer worth recording.
    func testingOperations(locationID: String, run: Bool) async throws -> [String: Any] {
        let manager = try Self.manager(locationID)
        let operations = try manager.listAvailableTestingOperations()
        var report: [String: Any] = ["available": operations.map { Self.describe(operation: $0) }]
        guard run, !operations.isEmpty else { return report }
        // Swift renames `runTestingOperations:error:` to `run(_:)`, and the failure map is
        // keyed by AnyHashable rather than by the operation protocol.
        let failures = try manager.run(operations)
        report["ran"] = operations.count
        report["failures"] = failures.map { key, error -> [String: Any] in
            var entry: [String: Any] = ["error": describe(error: error)]
            if let operation = key as? NSFileProviderTestingOperation {
                entry["operation"] = Self.describe(operation: operation)
            } else {
                entry["operation"] = String(describing: key)
            }
            return entry
        }
        return report
    }

    private static func describe(operation: NSFileProviderTestingOperation) -> [String: Any] {
        var report: [String: Any] = ["type": operation.type.rawValue]
        if let ingestion = operation as? NSFileProviderTestingIngestion {
            report["kind"] = "ingestion"
            report["side"] = ingestion.side.rawValue
            report["item"] = ingestion.itemIdentifier.rawValue
        } else if let fetch = operation as? NSFileProviderTestingContentFetch {
            report["kind"] = "contentFetch"
            report["item"] = fetch.itemIdentifier.rawValue
        } else if let enumeration = operation as? NSFileProviderTestingChildrenEnumeration {
            report["kind"] = "childrenEnumeration"
            report["item"] = enumeration.itemIdentifier.rawValue
        } else if let lookup = operation as? NSFileProviderTestingLookup {
            report["kind"] = "lookup"
            report["item"] = lookup.itemIdentifier.rawValue
        }
        return report
    }

    // MARK: Errors

    func describe(error: Error) -> [String: Any] {
        let nsError = error as NSError
        var report: [String: Any] = [
            "errorDomain": nsError.domain,
            "errorCode": nsError.code,
            "errorDescription": nsError.localizedDescription,
        ]
        let underlying = nsError.underlyingErrors.map { inner -> [String: Any] in
            let innerNS = inner as NSError
            return [
                "errorDomain": innerNS.domain,
                "errorCode": innerNS.code,
                "errorDescription": innerNS.localizedDescription,
                "userInfo": innerNS.userInfo.keys.sorted(),
            ]
        }
        if !underlying.isEmpty { report["underlyingErrors"] = underlying }
        if !nsError.userInfo.isEmpty { report["userInfoKeys"] = nsError.userInfo.keys.sorted() }
        return report
    }

    // MARK: Paging an enumerator the system owns

    /// Pages an enumerator to its end and returns the identifiers, under a deadline of its
    /// own: the enumerator is the system's, it is answered from the replica, and a wedged
    /// one must never stall a change-detection cycle.
    private static func drain(
        _ enumerator: NSFileProviderEnumerator, timeout: TimeInterval
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var identifiers: [String] = []
        var page = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
        while Date() < deadline {
            let observer = CollectingObserver()
            enumerator.enumerateItems(for: observer, startingAt: page)
            guard let outcome = await observer.wait(until: deadline) else { break }
            identifiers.append(contentsOf: observer.collected)
            switch outcome {
            case .finished(let next):
                guard let next else { return identifiers }
                page = next
            case .failed(let error):
                Log.agent.error(
                    "replica enumeration failed: \(error.localizedDescription, privacy: .public)")
                return identifiers
            }
        }
        return identifiers
    }

    private enum Outcome: Sendable {
        case finished(NSFileProviderPage?)
        case failed(Error)
    }

    /// One page of one enumeration. `didEnumerate` may arrive several times before
    /// `finishEnumerating`, and either finish method may arrive on any queue, so the
    /// waiting continuation is resumed exactly once behind a lock - by the observer or by
    /// the deadline, whichever comes first.
    private final class CollectingObserver: NSObject, NSFileProviderEnumerationObserver,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var identifiers: [String] = []
        private var outcome: Outcome?
        private var waiter: CheckedContinuation<Outcome?, Never>?

        var collected: [String] {
            lock.lock(); defer { lock.unlock() }
            return identifiers
        }

        func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
            let new = updatedItems.map { $0.itemIdentifier.rawValue }
            lock.lock()
            identifiers.append(contentsOf: new)
            lock.unlock()
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            settle(.finished(nextPage))
        }

        func finishEnumeratingWithError(_ error: Error) {
            settle(.failed(error))
        }

        private func settle(_ value: Outcome) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = value
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: value)
        }

        private func expire() {
            lock.lock()
            guard outcome == nil, let waiter else { lock.unlock(); return }
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: nil)
        }

        /// Nil means the deadline passed with no answer. The timer is a plain `asyncAfter`
        /// rather than a second child task: a task group waits for every child it started,
        /// so a losing child parked on a continuation nobody will resume would hang the
        /// group for ever.
        func wait(until deadline: Date) async -> Outcome? {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            return await withCheckedContinuation {
                (continuation: CheckedContinuation<Outcome?, Never>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                waiter = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { [weak self] in
                    self?.expire()
                }
            }
        }
    }
}
