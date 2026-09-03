import FileProvider
import Foundation
import Index
import XPCProtocols
import Logging

/// The File Provider calls the milestone 1 spikes need and that no CLI on the machine
/// makes: `evictItem`, the materialized and pending sets, the user-visible URL of an
/// item, the stabilization barrier, and the manual scheduling the
/// `com.apple.developer.fileprovider.testing-mode` entitlement unlocks.
///
/// They live here, in the agent, because the agent is the process that will make them for
/// real: the TTL loop of DESIGN.md section 7 evicts, and the pin machinery of section 7.1
/// signals. `sshdrive evict`, `sshdrive pin` and the eviction timer replace these hooks in
/// milestones 7 and 8; until then they exist so a headless VM can answer S4 and S6.
enum SpikeHooks {

    private static func manager(_ locationID: String) throws -> NSFileProviderManager {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: locationID),
            displayName: locationID)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw SSHDriveAgentError.unknownDomain.asNSError(
                "The system has no domain \(locationID).")
        }
        return manager
    }

    // MARK: Eviction (S4-1, S4-3, S6-5)

    /// `NSFileProviderManager.evictItem`. The error is reported field by field rather than
    /// as a sentence, because which error comes back is the whole answer: the header names
    /// `NSFileProviderErrorUnsyncedEdits` for an item with pending changes and
    /// `NSFileProviderErrorNonEvictable` for one the provider marked non-purgeable.
    static func evict(locationID: String, identifier: String) async -> [String: Any] {
        let manager: NSFileProviderManager
        do { manager = try self.manager(locationID) } catch {
            return describe(error: error)
        }
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

    static func describe(error: Error) -> [String: Any] {
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

    // MARK: The materialized and pending sets (S4, S6)

    /// Every item the system currently holds content for. This is the enumerator the TTL
    /// loop walks (section 7), and it is how a headless run sees what an eager policy
    /// actually downloaded.
    static func materializedItems(locationID: String) async throws -> [[String: Any]] {
        let enumerator = try manager(locationID).enumeratorForMaterializedItems()
        return try await enumerate(enumerator)
    }

    /// Every item with a change the system has not yet handed to the extension. S4 uses it
    /// to prove an item really is pending before trying to evict it.
    static func pendingItems(locationID: String) async throws -> [[String: Any]] {
        let enumerator = try manager(locationID).enumeratorForPendingItems()
        return try await enumerate(enumerator)
    }

    private static func enumerate(_ enumerator: NSFileProviderEnumerator) async throws
        -> [[String: Any]]
    {
        try await withCheckedThrowingContinuation { continuation in
            let observer = CollectingObserver(enumerator: enumerator) { result in
                continuation.resume(with: result)
            }
            enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
        }
    }

    // MARK: The user-visible file (S4-2, S4-4, S4-5)

    /// The path under `~/Library/CloudStorage` an identifier maps to. The TTL loop needs
    /// it to `stat` the replica (section 7); asking the system for it rather than building
    /// it from the display name is what the loop will do.
    static func userVisibleURL(locationID: String, identifier: String) async throws -> URL {
        let manager = try manager(locationID)
        return try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(identifier)) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: error ?? SSHDriveAgentError.noSuchItem.asNSError(
                            "No user-visible URL for \(identifier)."))
                }
            }
        }
    }

    /// `lstat` as the eviction loop does it: `AT_SYMLINK_NOFOLLOW`, from the
    /// launchd-started agent, with the errno kept rather than turned into a sentence. A
    /// TCC refusal a launchd agent cannot answer arrives here as a plain `EPERM`
    /// (section 7).
    static func stat(url: URL, readFirst: Bool) -> [String: Any] {
        var report: [String: Any] = ["path": url.path, "read": readFirst]

        if readFirst {
            // Open and read one byte, the way anything that "uses" the file does. This is
            // the read whose effect on atime S4 is measuring, made from the agent so a
            // TCC refusal on the open shows up too.
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
        report["dataless"] = (buffer.st_flags & 0x4000_0000) != 0
        report["now"] = Int(Date().timeIntervalSince1970)
        return report
    }

    // MARK: Determinism (used by every S6 sub-question)

    /// `waitForStabilization`, and then the sub-hierarchy barrier on the root. On an idle
    /// headless Mac fileproviderd throttles its schedulers, so without these two a spike
    /// measures the throttle rather than the behaviour (results.md, 2026-09-04, s3-1).
    static func stabilize(locationID: String) async throws -> [String: Any] {
        let manager = try manager(locationID)
        let start = Date()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.waitForStabilization { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let stabilized = Date()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.waitForChanges(below: .rootContainer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return [
            "stabilizeSeconds": stabilized.timeIntervalSince(start).rounded(toPlaces: 3),
            "waitForChangesSeconds": Date().timeIntervalSince(stabilized).rounded(toPlaces: 3),
        ]
    }

    // MARK: Manual scheduling (the testing-mode entitlement)

    /// `listAvailableTestingOperations`, which the appex's
    /// `com.apple.developer.fileprovider.testing-mode` entitlement unlocks. It only
    /// returns operations on a domain added with
    /// `NSFileProviderDomainTestingModeInteractive`; on any other domain it fails, and the
    /// error is the answer worth recording.
    static func testingOperations(locationID: String, run: Bool) throws -> [String: Any] {
        let manager = try manager(locationID)
        let operations = try manager.listAvailableTestingOperations()
        var report: [String: Any] = [
            "available": operations.map { describe(operation: $0) }
        ]
        guard run, !operations.isEmpty else { return report }
        // Swift renames `runTestingOperations:error:` to `run(_:)`, and the failure map is
        // keyed by AnyHashable rather than by the operation protocol.
        let failures = try manager.run(operations)
        report["ran"] = operations.count
        report["failures"] = failures.map { key, error -> [String: Any] in
            var entry: [String: Any] = ["error": describe(error: error)]
            if let operation = key as? NSFileProviderTestingOperation {
                entry["operation"] = describe(operation: operation)
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
}

/// Collects one enumerator's pages into an array. The materialized and pending sets are
/// the only enumerators the agent ever reads; the extension owns every other one.
private final class CollectingObserver: NSObject, NSFileProviderEnumerationObserver {
    private let enumerator: NSFileProviderEnumerator
    private let finish: (Result<[[String: Any]], Error>) -> Void
    private var rows: [[String: Any]] = []
    private var finished = false

    init(
        enumerator: NSFileProviderEnumerator,
        finish: @escaping (Result<[[String: Any]], Error>) -> Void
    ) {
        self.enumerator = enumerator
        self.finish = finish
    }

    func didEnumerate(_ updatedItems: [any NSFileProviderItemProtocol]) {
        for item in updatedItems {
            rows.append([
                "identifier": item.itemIdentifier.rawValue,
                "filename": item.filename,
                "parent": item.parentItemIdentifier.rawValue,
            ])
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        guard !finished else { return }
        finished = true
        finish(.success(rows))
    }

    func finishEnumeratingWithError(_ error: Error) {
        guard !finished else { return }
        finished = true
        finish(.failure(error))
    }
}
