import Foundation
import FileProvider
import AgentCore
import Config
import Index
import Logging
import XPCProtocols

/// DESIGN.md section 7's TTL loop, and section 6.6's timer for it.
///
/// One per location, beside the change detector and for the same reason: it makes File
/// Provider calls that can take seconds (the materialized enumerator, a `getUserVisibleURL`
/// and an `evictItem` per file) and none of them may sit in front of an `item(for:)`
/// fallback or a fetch. It asks `LocationRuntime` only for rows and gives it back only the
/// identifiers it evicted; `EvictionPlan` makes every decision in between.
///
/// The whole loop is: every five minutes, for each mounted domain whose `cacheTTL` is not
/// `never`, walk `enumeratorForMaterializedItems()`, `lstat` each replica file **before**
/// deciding (an eviction moves atime), and `evictItem` anything whose last use is older
/// than the TTL. Kept items are skipped by us; pending uploads are refused by the system,
/// so they need no check of ours (S4, 2026-09-04).
actor CacheEvictor {
    /// "Every 5 minutes" (section 7 step 1).
    static let interval: TimeInterval = 300

    let locationID: String
    private let runtime: LocationRuntime
    private var ttl: CacheTTL
    private var loop: Task<Void, Never>?
    private var lastRun: Double = 0
    private var running = false
    /// What the last pass did, for `status` and for the runbook.
    private(set) var lastPass: [String: Any] = [:]
    /// `sshdrive debug ttl <name> --seconds N`: the TTL in seconds, overriding the
    /// location's `cacheTTL` for this process only.
    ///
    /// Section 7's shortest real value is `15m`, and a runbook that had to wait a quarter
    /// of an hour per assertion would be run once and never again. The override changes the
    /// number the rule is applied to and nothing else - the pass, the `stat`s, the
    /// `evictItem`s and every skip are the ordinary ones - which is the same bargain
    /// `debug watch --clock-skew` makes for the sweep window (section 6.4).
    private var ttlOverrideSeconds: Double?

    init(locationID: String, runtime: LocationRuntime, ttl: CacheTTL) {
        self.locationID = locationID
        self.runtime = runtime
        self.ttl = ttl
    }

    // MARK: Lifecycle

    func start(now: Double = Date().timeIntervalSince1970) {
        guard loop == nil else { return }
        // The first pass is one interval away, not at startup: a location that has just
        // mounted has just been listed, and the agent has no atime for anything yet.
        lastRun = now
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.secondsUntilNextPass()
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                    continue
                }
                _ = await self.runPass(reason: "timer")
            }
        }
        Log.agent.notice(
            "\(self.locationID, privacy: .public): the cache eviction loop is running, TTL \(self.ttl.rawValue, privacy: .public)"
        )
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// `sshdrive set <name> cache-ttl <value>` takes effect at once rather than at the next
    /// restart: the loop reads it on every pass.
    func setTTL(_ value: CacheTTL) {
        ttl = value
        Log.agent.notice(
            "\(self.locationID, privacy: .public): cache TTL is now \(value.rawValue, privacy: .public)"
        )
    }

    func nextRunAt() -> Double { lastRun + CacheEvictor.interval }

    func setTTLOverride(seconds: Double?) {
        ttlOverrideSeconds = seconds
        Log.agent.notice(
            "\(self.locationID, privacy: .public): TTL override \(seconds.map { "\($0)s" } ?? "off", privacy: .public)"
        )
    }

    /// The seconds the rule is applied to: the override when a debug hook set one, and the
    /// location's `cacheTTL` otherwise. `never` is nil and evicts nothing.
    private var effectiveTTLSeconds: TimeInterval? {
        if let ttlOverrideSeconds { return ttlOverrideSeconds }
        return ttl.seconds
    }

    private func secondsUntilNextPass(now: Double = Date().timeIntervalSince1970) -> Double {
        max(0, nextRunAt() - now)
    }

    // MARK: One pass

    /// One walk of the materialized set. `force` ignores the TTL for the paths named,
    /// which is what `sshdrive evict <name> <path>` does; with no paths it is section 7's
    /// ordinary pass, which `sshdrive evict <name>` triggers on demand (step 4).
    @discardableResult
    func runPass(
        reason: String, now: Double = Date().timeIntervalSince1970
    ) async -> [String: Any] {
        guard !running else { return ["skipped": "a pass is already running"] }
        running = true
        defer { running = false; lastRun = Date().timeIntervalSince1970 }

        let started = Date()
        guard let identifiers = await ReplicaEnumerators.materializedIdentifiers(
            locationID: locationID)
        else {
            // No manager for the domain: it is being added or removed. "No news", never
            // "the user evicted everything" (section 6.5).
            return ["skipped": "the system has no domain for this location"]
        }
        let candidates = await withTimes(await rows(for: identifiers))
        let decisions = EvictionPlan.decide(candidates, ttl: effectiveTTLSeconds, now: now)
        let wanted = decisions.filter(\.evict).sorted { $0.lastUse < $1.lastUse }

        var evicted: [String] = []
        var refused: [[String: Any]] = []
        for decision in wanted {
            let report = await ReplicaAccess.evict(
                locationID: locationID, identifier: decision.candidate.identifier)
            if report["evicted"] as? Bool == true {
                evicted.append(decision.candidate.identifier)
                Log.agent.notice(
                    "\(self.locationID, privacy: .public): evicted \(decision.candidate.path, privacy: .public), unused for \(Int(decision.ageSeconds), privacy: .public)s (atime \(Int(now - (decision.candidate.atime ?? 0)), privacy: .public)s ago, not decided on)"
                )
            } else {
                // Section 7 step 3: ignore the refusal, log and move on. The code says
                // nothing about why (S4), and the pass comes round again in five minutes.
                var entry: [String: Any] = ["path": decision.candidate.path]
                entry["error"] = report["errorDescription"] as? String ?? "refused"
                entry["code"] = report["errorCode"] as? Int ?? 0
                refused.append(entry)
                Log.agent.debug(
                    "\(self.locationID, privacy: .public): \(decision.candidate.path, privacy: .public) refused eviction: \(entry["error"] as? String ?? "", privacy: .public)"
                )
            }
        }
        if !evicted.isEmpty { try? await runtime.noteEvicted(identifiers: evicted) }

        let totals = EvictionPlan.totals(candidates)
        let pass: [String: Any] = [
            "reason": reason,
            "at": Date().timeIntervalSince1970,
            "seconds": Date().timeIntervalSince(started).rounded(toPlaces: 3),
            "ttl": ttlOverrideSeconds.map { "\(Int($0))s (debug override)" } ?? ttl.rawValue,
            "materializedFiles": totals.files,
            "materializedBytes": totals.bytes,
            "keptFiles": totals.keptFiles,
            "keptBytes": totals.keptBytes,
            "considered": candidates.count,
            "evicted": evicted.count,
            "refused": refused,
            "skippedKept": decisions.filter { $0.skip == .kept }.count,
        ]
        lastPass = pass
        return pass
    }

    /// `sshdrive evict <name> <path>`: this item now, whatever the TTL says.
    ///
    /// A kept item is refused with a sentence rather than left to fail opaquely: the eager
    /// policy would refuse the call anyway (S6), and "unpin it first" is the answer
    /// (section 7.2's division of labour). The retry with the doubling backoff is section
    /// 5.5's, reused, because a user who has just unpinned is racing the same
    /// still-finishing modification the conflict path races.
    func evictPath(_ pathString: String) async throws -> [String: Any] {
        let (identifier, row) = try await runtime.identifier(forPath: pathString)
        if row.kept {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "\(pathString) is kept downloaded. Run `sshdrive unpin` on it first, or "
                    + "`sshdrive evict --all --unpin-all` to drop every pin.")
        }
        var report = await ReplicaAccess.evictWithRetry(
            locationID: locationID, identifier: identifier, attempts: 5, subject: pathString)
        if report["evicted"] as? Bool == true {
            try? await runtime.noteEvicted(identifiers: [identifier])
        }
        report["path"] = pathString
        report["identifier"] = identifier
        return report
    }

    /// `sshdrive evict <name> --all`.
    ///
    /// With nothing pinned this is **one** `evictItem` on the root container: S4 measured
    /// that it evicts the children recursively and then the container itself, so a walk
    /// would only be slower (2026-09-04). With pins in place the same call would meet a
    /// kept child and fail as a whole, so the unkept files are evicted one by one instead -
    /// which is what section 7.1 step 5 means by "`evict --all` skips kept items too,
    /// unless `--unpin-all` is passed, which removes every pin first".
    func evictAll(unpinAll: Bool) async throws -> [String: Any] {
        var report: [String: Any] = [:]
        var pinsRemoved = 0
        if unpinAll {
            let markers = try await runtime.pinMarkers()
            for pin in markers.pinRoots.reversed() {
                let path = String(decoding: pin, as: UTF8.self)
                _ = try? await runtime.applyPin(pathString: path, request: .dontKeep)
                pinsRemoved += 1
            }
            // Any exclusion left has nothing above it any more; clear those too, so the
            // location really is unpinned.
            for exclusion in try await runtime.pinMarkers().exclusions {
                _ = try? await runtime.setPinState(
                    pathString: String(decoding: exclusion, as: UTF8.self), marker: 0)
            }
            await DomainManager.shared.signalWorkingSet(locationID: locationID)
        }
        report["pinsRemoved"] = pinsRemoved

        // The one call on the root container is what section 7 wants, and S4 measured that
        // it evicts the children recursively and then the container itself. It is used
        // only when nothing is or has just been pinned: with a pin still in place it meets
        // a kept child and fails as a whole, and straight after an `--unpin-all` it fails
        // too - as `NSCocoaErrorDomain` "The file couldn't be opened", which names no
        // reason - because the system has not yet re-read the rows whose policy just
        // changed (measured 2026-09-05; a single file becomes evictable 5-10 s after the
        // unpin, and the container did not within a minute).
        let markers = try await runtime.pinMarkers()
        if markers.pinRoots.isEmpty && pinsRemoved == 0 {
            let root = await ReplicaAccess.evictWithRetry(
                locationID: locationID, identifier: IndexWriter.rootIdentifier,
                attempts: 3, subject: "the location root")
            if root["evicted"] as? Bool == true {
                report["mode"] = "root container"
                report.merge(root) { new, _ in new }
                let identifiers =
                    await ReplicaEnumerators.materializedIdentifiers(locationID: locationID) ?? []
                report["stillMaterialized"] = identifiers.count
                return report
            }
            // The one call is an optimisation, not the contract: if the system will not
            // take the whole container, `--all` still has to drop what it can.
            report["rootContainerError"] = root["errorDescription"] as? String ?? "refused"
            report["mode"] = "file by file (the root container was refused)"
        } else if pinsRemoved > 0 {
            report["mode"] = "file by file (the pins were just removed)"
        } else {
            report["mode"] = "file by file (pins are in place)"
        }

        let identifiers =
            await ReplicaEnumerators.materializedIdentifiers(locationID: locationID) ?? []
        let candidates = await rows(for: identifiers)
        var evicted: [String] = []
        var keptSkipped = 0
        var refused = 0
        for candidate in candidates {
            // A directory holds no content and a local-only row has nothing on the server
            // to fetch back; neither is counted as "kept and left alone".
            if candidate.isDirectory || candidate.isLocalOnly { continue }
            if candidate.kept { keptSkipped += 1; continue }
            // Each file gets the doubling backoff too: after an `--unpin-all` the system
            // is still finishing the metadata changes for the whole subtree.
            let outcome = await ReplicaAccess.evictWithRetry(
                locationID: locationID, identifier: candidate.identifier,
                attempts: pinsRemoved > 0 ? 5 : 2, subject: candidate.path)
            if outcome["evicted"] as? Bool == true {
                evicted.append(candidate.identifier)
            } else {
                refused += 1
            }
        }
        if !evicted.isEmpty { try? await runtime.noteEvicted(identifiers: evicted) }
        report["evicted"] = evicted.count
        report["keptSkipped"] = keptSkipped
        report["refusedCount"] = refused
        return report
    }

    // MARK: The two halves of a candidate

    private func rows(for identifiers: [String]) async -> [EvictionPlan.Candidate] {
        (try? await runtime.evictionRows(identifiers: identifiers)) ?? []
    }

    /// The replica's atime and mtime, read **before** anything is evicted, since an
    /// eviction moves atime (S4, 2026-09-04).
    ///
    /// The mtime matters: a save in the mount moves the replica's before the upload
    /// finishes, and the row's only afterwards, so the later of the two is the save the
    /// TTL means. The atime is recorded for the log and decided on by nobody
    /// (`EvictionPlan`, 2026-09-05).
    private func withTimes(_ candidates: [EvictionPlan.Candidate]) async
        -> [EvictionPlan.Candidate]
    {
        var out: [EvictionPlan.Candidate] = []
        out.reserveCapacity(candidates.count)
        for var candidate in candidates {
            // Only for the files that could actually be evicted: a directory, a kept item
            // and a local-only row are all decided without a `stat`.
            if candidate.isDirectory || candidate.kept || candidate.isLocalOnly {
                out.append(candidate)
                continue
            }
            if let url = try? await ReplicaAccess.userVisibleURL(
                locationID: locationID, identifier: candidate.identifier),
                let times = ReplicaAccess.replicaTimes(url: url)
            {
                candidate.atime = times.atime
                // The replica's mtime is the one the user's saves move; the row's is the
                // server's. The later of the two is the one section 7 wants.
                candidate.mtime = max(candidate.mtime, times.mtime)
            }
            out.append(candidate)
        }
        return out
    }
}
