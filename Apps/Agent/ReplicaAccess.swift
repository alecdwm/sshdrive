import FileProvider
import Foundation
import Logging
import XPCProtocols

/// The File Provider calls the agent makes *into its own domain's replica*: evicting an
/// item, finding the user-visible file behind an identifier, `lstat`ing it, and the lookup
/// that makes a pin on a never-enumerated path start downloading.
///
/// Milestone 1 wrote these as spike hooks; DESIGN.md sections 7 and 7.1 are what they are
/// for, so from milestone 7 they live here and `SpikeHooks` forwards to them. The agent is
/// the only process that can make them: `NSFileProviderManager` is useless from a
/// sandboxed extension, and reading `~/Library/CloudStorage/...` from the launchd agent is
/// allowed with no TCC prompt because it is our own domain (S4, 2026-09-04, section 7).
enum ReplicaAccess {

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

    // MARK: Eviction (section 7)

    /// `NSFileProviderManager.evictItem`, with the error reported field by field rather
    /// than as a sentence.
    ///
    /// **The error code does not say why** (S4, 2026-09-04): an item with a pending upload
    /// and a kept item both come back as `NSFileProviderErrorNonEvictable` (-2008), never
    /// the documented `NSFileProviderErrorUnsyncedEdits` (-2007), and a directory eviction
    /// that meets a pending child fails as `NSCocoaErrorDomain` 4101 with a
    /// `contentVersionMismatch` underneath rather than as
    /// `NSFileProviderErrorNonEvictableChildren` (-2006). So nothing may be inferred from a
    /// refusal beyond "not now": it is logged and passed over.
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

    /// The same call with the doubling backoff section 5.5's conflict path needs and
    /// `sshdrive evict <name> <path>` reuses.
    ///
    /// An `evictItem` issued immediately after a `modifyItem` reply is refused -2008
    /// because the system is still finishing the modification it was just told about
    /// (S3, 2026-09-04), and a user who has just unpinned a folder is in the same race. The
    /// TTL loop itself does **not** retry: section 7 step 3 says to ignore the refusal and
    /// move on, and the loop comes round again in five minutes.
    @discardableResult
    static func evictWithRetry(
        locationID: String, identifier: String, attempts: Int = 7, subject: String = ""
    ) async -> [String: Any] {
        var delay: UInt64 = 250_000_000  // 0.25 s
        var last: [String: Any] = [:]
        for attempt in 1...max(1, attempts) {
            last = await evict(locationID: locationID, identifier: identifier)
            if last["evicted"] as? Bool == true {
                last["attempts"] = attempt
                return last
            }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 8_000_000_000)
        }
        last["attempts"] = attempts
        Log.agent.notice(
            "gave up evicting \(subject.isEmpty ? identifier : subject, privacy: .public) after \(attempts, privacy: .public) attempts"
        )
        return last
    }

    /// Section 5.5's conflict path: the eviction that has to follow the reply, which
    /// cannot be done once. Without it the replica keeps the *local* bytes under the
    /// *remote* version for ever, which is the whole reason the eviction is there.
    static func evictAfterConflict(
        locationID: String, identifier: String, attempts: Int = 7
    ) async {
        // The conflict path waits *before* its first attempt: the modification it is
        // racing has only just been replied to.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let report = await evictWithRetry(
            locationID: locationID, identifier: identifier, attempts: attempts)
        if report["evicted"] as? Bool == true {
            Log.agent.notice(
                "evicted \(identifier, privacy: .public) after a conflict copy on attempt \(report["attempts"] as? Int ?? 0, privacy: .public)"
            )
        } else {
            Log.agent.error(
                "could not evict \(identifier, privacy: .public) after a conflict copy; the replica still holds the local bytes under the remote version"
            )
        }
    }

    // MARK: The user-visible file (sections 7, 7.1)

    /// The path under `~/Library/CloudStorage` an identifier maps to. The TTL loop needs
    /// it to `stat` the replica; asking the system rather than building it from the
    /// display name is what makes it right for a renamed domain.
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

    /// Section 7.1 step 1's last step: **a lookup of the pinned path in the replica**.
    ///
    /// S6 measured (2026-09-04) that reporting the ancestor rows through the working set
    /// does not make the system ingest them - ninety seconds after the rows and their
    /// anchors were reported nothing had been enumerated or downloaded, and
    /// `signalEnumerator(for:)` on each new ancestor's own container changed nothing
    /// either. What starts it is this: `getUserVisibleURL` for the pinned identifier
    /// followed by one `lstat` of the returned path, well under a second on a still
    /// dataless item. The system then enumerates the chain and the eager download follows
    /// within about a minute.
    @discardableResult
    static func lookUpInReplica(locationID: String, identifier: String) async -> [String: Any] {
        let started = Date()
        do {
            let url = try await userVisibleURL(locationID: locationID, identifier: identifier)
            var buffer = Foundation.stat()
            let ok = lstat(url.path, &buffer) == 0
            var report: [String: Any] = [
                "path": url.path,
                "lstat": ok,
                "seconds": Date().timeIntervalSince(started).rounded(toPlaces: 3),
            ]
            if !ok {
                report["errno"] = errno
                report["errnoName"] = String(cString: strerror(errno))
            }
            Log.agent.notice(
                "looked \(url.path, privacy: .public) up in the replica so the system ingests the pinned chain (lstat \(ok ? "ok" : "failed", privacy: .public))"
            )
            return report
        } catch {
            Log.agent.error(
                "could not look the pinned item up in the replica: \(error, privacy: .public)")
            return describe(error: error)
        }
    }

    /// `lstat` as the eviction loop does it: `AT_SYMLINK_NOFOLLOW` (section 9.1), from the
    /// launchd-started agent, with the errno kept rather than turned into a sentence, and
    /// read **before** the eviction, since an eviction moves atime (S4).
    static func stat(url: URL, readFirst: Bool = false) -> [String: Any] {
        var report: [String: Any] = ["path": url.path, "read": readFirst]

        if readFirst {
            // Open and read one byte, the way anything that "uses" the file does. This is
            // the read whose effect on atime S4 measured, made from the agent so a TCC
            // refusal on the open shows up too.
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

    /// The atime and mtime the TTL rule needs, or nil when the `stat` failed. Nil is not
    /// "unused": section 7's `last_fetch` and mtime carry the meaning on their own.
    static func replicaTimes(url: URL) -> (atime: Double, mtime: Double)? {
        var buffer = Foundation.stat()
        guard lstat(url.path, &buffer) == 0 else { return nil }
        return (Double(buffer.st_atimespec.tv_sec), Double(buffer.st_mtimespec.tv_sec))
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
}
