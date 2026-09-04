import Foundation
import FileProvider
import Security
import ServiceManagement
import AgentCore
import Config
import Secrets
import Index
import SFTP
import SSHProcess
import XPCProtocols
import Logging

/// Everything the CLI asks the agent to do. The CLI is a pure XPC client: every command
/// is a request to the agent, so the CLI never touches the network, the keychain or File
/// Provider (DESIGN.md section 3).
///
/// Milestone 1 implements `doctor` and the `debug` group the spikes need. Everything else
/// in section 8 arrives with the milestone that gives it something to do.
enum ControlCommands {

    static func run(
        command: String, arguments: [String: String], relay: CLIRelay? = nil
    ) async throws -> Data {
        switch command {
        case "add", "show", "remove", "set", "mount", "unmount", "status":
            // Section 8's user-facing half. `add` and a `set` that re-keys the secrets are
            // the two that need a terminal, which is what `relay` is (section 4.2).
            return try await LocationCommands.run(
                command: command, arguments: arguments, relay: relay)

        case "version":
            return try json([
                "agentVersion": agentVersion,
                "interfaceVersion": sshDriveXPCInterfaceVersion,
            ])

        case "doctor":
            return try json(["checks": await doctor()])

        case "agent.stop":
            // launchd leaves the agent down until the next mach lookup, which any CLI
            // command or extension call causes, so stop is a pause, not a disable
            // (section 8, section 10).
            Log.agent.notice("exiting on request from the CLI")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            return try json(["stopping": true])

        case "debug.fake.add":
            return try await addFakeLocation(arguments)

        case "debug.fake.remove":
            return try await removeLocation(arguments)

        case "list":
            return try await LocationCommands.run(
                command: "list", arguments: arguments, relay: relay)

        case "debug.fake.list":
            let file = try await DomainManager.shared.configuration()
            return try json([
                "macID": file.macID,
                "locations": file.locations.map {
                    [
                        "id": $0.id, "name": $0.displayName, "host": $0.host,
                        "backend": $0.backend.rawValue, "mounted": $0.mounted,
                        "cacheTTL": $0.cacheTTL.rawValue, "permissions": $0.permissions.rawValue,
                    ] as [String: Any]
                },
            ])

        case "debug.tree":
            let runtime = try await resolveRuntime(arguments)
            let entries = try await runtime.dumpFakeTree()
            return try json([
                "tree": entries.map {
                    ["path": $0.path, "type": $0.type, "size": $0.size,
                     "mode": String($0.mode, radix: 8)] as [String: Any]
                }
            ])

        case "debug.mutate":
            return try await mutate(arguments)

        case "debug.anchor.expire":
            let runtime = try await resolveRuntime(arguments)
            try await runtime.expireAnchors()
            let location = try await resolveLocation(arguments)
            await DomainManager.shared.signalWorkingSet(locationID: location.id)
            return try json(["expired": true, "location": location.id])

        case "debug.sweep":
            let runtime = try await resolveRuntime(arguments)
            let enabled = (arguments["enabled"] ?? "on") == "on"
            await runtime.setCatchUpSweep(enabled: enabled)
            return try json(["catchUpSweep": enabled ? "on" : "off"])

        case "debug.policy":
            let runtime = try await resolveRuntime(arguments)
            guard let path = arguments["path"] else {
                throw SSHDriveAgentError.notImplemented.asNSError("debug.policy needs a path.")
            }
            let marker: Int64
            switch arguments["policy"] ?? "inherit" {
            case "eager-keep": marker = 1
            case "lazy": marker = -1
            default: marker = 0
            }
            var report = try await runtime.setPinState(pathString: path, marker: marker)
            let location = try await resolveLocation(arguments)
            await DomainManager.shared.signalWorkingSet(locationID: location.id)
            report["path"] = path
            report["marker"] = marker
            return try json(report)

        case "debug.index.dump":
            return try await dumpIndex(arguments)

        case "debug.evict":
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let (identifier, row) = try await runtime.identifier(
                forPath: arguments["path"] ?? "")
            var report = await SpikeHooks.evict(
                locationID: location.id, identifier: identifier)
            report["identifier"] = identifier
            report["path"] = arguments["path"] ?? ""
            report["kept"] = row.kept
            report["allowsEvictingServed"] =
                (row.capabilities & Int64(NSFileProviderItemCapabilities.allowsEvicting.rawValue))
                != 0
            return try json(report)

        case "debug.materialized":
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let wantsPending = arguments["pending"] == "true"
            let rows =
                wantsPending
                ? try await SpikeHooks.pendingItems(locationID: location.id)
                : try await SpikeHooks.materializedItems(locationID: location.id)
            // The system speaks in identifiers; the paths come from the index, so the
            // output can be read without a second lookup.
            let annotated = try await withPaths(rows, runtime: runtime)
            return try json([
                "set": wantsPending ? "pending" : "materialized",
                "count": annotated.count,
                "items": annotated,
            ])

        case "debug.stat":
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let (identifier, row) = try await runtime.identifier(forPath: arguments["path"] ?? "")
            let url = try await SpikeHooks.userVisibleURL(
                locationID: location.id, identifier: identifier)
            var report = SpikeHooks.stat(url: url, readFirst: arguments["read"] == "true")
            report["identifier"] = identifier
            report["indexLastFetch"] = row.lastFetch ?? -1
            report["indexMtime"] = row.mtime
            return try json(report)

        case "debug.xattr":
            let runtime = try await resolveRuntime(arguments)
            let path = arguments["path"] ?? ""
            let (identifier, row) = try await runtime.identifier(forPath: path)
            let local = LocalAttributes.decode(row.xattrs)
            return try json([
                "path": path,
                "identifier": identifier,
                "contentVersion": row.contentVersion,
                "metadataVersion": row.metadataVersion,
                // Section 5.3 hashes exactly the stored blob into the metadata version;
                // S10's question is whether that is enough to stop the system re-offering
                // a tag change, so the hash is printed beside the version it feeds.
                "xattrHash": String(ItemDerivation.fnv1a(row.xattrs ?? Data()), radix: 16),
                "storedBlobBytes": row.xattrs?.count ?? 0,
                "hidden": row.hidden,
                "servedExtendedAttributes": try await runtime.servedExtendedAttributes(
                    pathString: path),
                // Tags never arrive as an xattr: they are the item's own `tagData`
                // (section 5.4). Printed base64 because the blob is a binary plist.
                "tagDataBase64": local.tagData?.base64EncodedString() ?? "",
                "tagDataBytes": local.tagData?.count ?? 0,
            ])

        case "debug.fault":
            let runtime = try await resolveRuntime(arguments)
            // Section 6.3's outage simulation. A VM guest cannot take its host's link
            // down or stop the host's containers, so `--unreachable` and
            // `--transport-hang` are what stand in for those: the first fails every
            // transport call and every connect attempt the way a dead server does, the
            // second stalls them the way a network that has gone but not said so does.
            let location = try await resolveLocation(arguments)
            if let gate = await DomainManager.shared.gate(locationID: location.id) {
                await gate.setFault(
                    unreachable: arguments["unreachable"].map { $0 == "on" },
                    hangMilliseconds: arguments["transportHang"].flatMap { Int($0) },
                    connectHangMilliseconds: arguments["connectHang"].flatMap { Int($0) },
                    connectFailure: arguments["connectFailure"])
            }
            let writes = arguments["writes"].map { $0 == "on" }
            let delay = arguments["fetchDelay"].flatMap { Int($0) }
            let mismatch = arguments["versionMismatch"].map { $0 == "on" }
            let collisions = arguments["collisions"].map { $0 == "on" }
            let uploadDelay = arguments["uploadDelay"].flatMap { Int($0) }
            let frozen = arguments["frozenMetadata"].map { $0 == "on" }
            await runtime.setFault(
                writes: writes, fetchDelayMilliseconds: delay, versionMismatch: mismatch,
                collisions: collisions, uploadDelayMilliseconds: uploadDelay,
                frozenMetadata: frozen, fetchError: arguments["fetchError"])
            return try json(await runtime.transferStats(reset: false))

        case "accept-deletions":
            // Section 8: "apply deletions the mass-deletion guard is holding". With no
            // path, everything the location is holding; with one, that path and its
            // subtree.
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let applied = try await runtime.acceptDeletions(pathString: arguments["path"])
            if applied > 0 {
                await DomainManager.shared.signalWorkingSet(locationID: location.id)
            }
            return try json([
                "location": location.displayName,
                "applied": applied,
                "stillHeld": (try? await runtime.heldReport())?.count ?? 0,
            ])

        case "evict":
            // Section 7 step 4: "`sshdrive evict <location> [path]` triggers the same
            // routine on demand, with `--all` to drop everything cached, which is one
            // `evictItem` on the root container rather than a walk" (S4, 2026-09-04).
            let location = try await resolveLocation(arguments)
            _ = try await resolveRuntime(arguments)
            guard let evictor = await DomainManager.shared.evictor(locationID: location.id) else {
                throw SSHDriveAgentError.unknownDomain.asNSError(
                    "\(location.displayName) is not mounted, so it has no cache to evict.")
            }
            var report: [String: Any]
            if arguments["all"] == "true" {
                report = try await evictor.evictAll(unpinAll: arguments["unpinAll"] == "true")
            } else if let path = arguments["path"], !path.isEmpty {
                report = try await evictor.evictPath(path)
            } else {
                report = await evictor.runPass(reason: "sshdrive evict")
            }
            report["location"] = location.displayName
            return try json(report)

        case "debug.ttl":
            // Section 7's shortest real TTL is 15 minutes; this is what makes the loop
            // testable in a runbook. Nothing else about the pass changes.
            let location = try await resolveLocation(arguments)
            _ = try await resolveRuntime(arguments)
            guard let evictor = await DomainManager.shared.evictor(locationID: location.id) else {
                throw SSHDriveAgentError.unknownDomain.asNSError(
                    "\(location.displayName) is not mounted.")
            }
            let seconds = arguments["seconds"].flatMap { Double($0) }
            await evictor.setTTLOverride(seconds: arguments["off"] == "true" ? nil : seconds)
            return try json([
                "location": location.displayName,
                "ttlOverrideSeconds": seconds ?? -1,
                "cacheTTL": location.cacheTTL.rawValue,
            ])

        case "pin", "unpin":
            // Sections 7.1 and 7.1.1. `pin` and `unpin` are statements about the effective
            // state, never about a marker; which marker that becomes is `PinPolicy`'s.
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let path = arguments["path"] ?? ""
            let request: PinPolicy.Request = command == "pin" ? .keep : .dontKeep
            var report = try await runtime.applyPin(pathString: path, request: request)
            if report["changed"] as? Bool == true {
                // The anchors are written; this is what makes the system read them.
                await DomainManager.shared.signalWorkingSet(locationID: location.id)
                if request == .keep, let identifier = report["identifier"] as? String {
                    // Section 7.1 step 1's last step, and the one S6 found is not
                    // optional: without a lookup of the path in the replica the system
                    // ingests nothing and the eager download never starts.
                    report["replicaLookup"] = await ReplicaAccess.lookUpInReplica(
                        locationID: location.id, identifier: identifier)
                }
            }
            report["location"] = location.displayName
            return try json(report)

        case "pins":
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            if arguments["export"] == "true" {
                return try json([
                    "location": location.displayName,
                    "pins": try await runtime.exportPins(),
                ])
            }
            if let payload = arguments["import"], !payload.isEmpty {
                return try json(try await importPins(
                    payload: payload, location: location, runtime: runtime))
            }
            let materialized = await ReplicaEnumerators.materializedIdentifiers(
                locationID: location.id)
            return try json([
                "location": location.displayName,
                "cacheTTL": location.cacheTTL.rawValue,
                "pins": try await runtime.pinsReport(materialized: materialized.map(Set.init)),
            ])

        case "debug.watch":
            // Section 6.4's change detection, driven by hand: one cycle now, a full sweep
            // now, the loop paused so a spike owns the timing, and the server-clock skew a
            // container cannot provide (testbed/README.md: containers share the host's
            // clock and Docker has no time namespace, so the sweep's own reference is
            // shifted instead and `status` says so).
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            guard let detector = await DomainManager.shared.detector(locationID: location.id) else {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "no change detector for \(location.displayName)")
            }
            if let pause = arguments["pause"] { await detector.setPaused(pause == "on") }
            if let skew = arguments["clockSkew"].flatMap({ Int64($0) }) {
                await detector.setClockSkew(seconds: skew)
            }
            if arguments["forgetStamp"] == "true" { await runtime.setSweepServerTime(0) }
            var report: [String: Any] = [:]
            if arguments["now"] == "true" || arguments["full"] == "true" {
                let started = Date()
                let application = await detector.runCycle(forceFull: arguments["full"] == "true")
                report["ranSeconds"] = Date().timeIntervalSince(started)
                report["changed"] = application.changed
                report["deleted"] = application.deleted
                report["held"] = application.held
                report["released"] = application.released
                report["directoriesListed"] = application.listedDirectories
                report["errors"] = application.errors
            }
            report["status"] = await detector.status()
            report["watch"] = await runtime.watchReport()
            report["pendingPaths"] = await runtime.pendingPathCount()
            return try json(report)

        case "debug.roots":
            // Section 6.5's root set as the index holds it, with the rotation the next
            // tier 0 cycle would take.
            let runtime = try await resolveRuntime(arguments)
            if arguments["refresh"] == "true" {
                let location = try await resolveLocation(arguments)
                let identifiers = await ReplicaEnumerators.materializedIdentifiers(
                    locationID: location.id)
                _ = try? await runtime.refreshRootSet(materializedIdentifiers: identifiers)
            }
            // `--seed N` marks the first N **real** directory rows as `materialized`
            // roots. Only the reason is injected: every one of them is a directory that
            // exists and is really `readdir`ed by the cycle. Materializing a file in each
            // of five thousand directories to get the reason honestly is five thousand
            // fetches, and what section 6.5's rotation is measured on is the cost of a
            // cycle at that scale, not how the roots got there.
            if let seed = arguments["seed"].flatMap({ Int($0) }) {
                let added = try await runtime.seedMaterializedRoots(limit: seed)
                let set = try await runtime.currentRootSet()
                return try json([
                    "seeded": added, "count": set.entries.count,
                    "rotationPeriod": set.rotationPeriod(),
                    "cycle": set.tier0Cycle().count,
                ])
            }
            let set = try await runtime.currentRootSet()
            return try json([
                "count": set.entries.count,
                "rotationPeriod": set.rotationPeriod(),
                "cycle": set.tier0Cycle().map { String(decoding: $0, as: UTF8.self) },
                "fullCycle": set.tier0Cycle(fullSweep: true).count,
                "roots": set.entries.map {
                    [
                        "path": String(decoding: $0.path, as: UTF8.self),
                        "reasons": $0.reasons.map(\.rawValue).sorted(),
                        "lastSeen": $0.lastSeen,
                        "lastListed": $0.lastListed,
                    ] as [String: Any]
                },
            ])

        case "debug.reconcile":
            // Section 5.3's walk on demand: `--force` sets `meta.reconciling` first, so
            // the whole recovery path can be exercised without corrupting an index.
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            if arguments["force"] == "true" { try await runtime.markReconciling() }
            let report = await runtime.finishReconcileIfOwed()
            await DomainManager.shared.signalWorkingSet(locationID: location.id)
            return try json([
                "location": location.displayName,
                "report": report ?? ["state": "nothing owed"],
                "recovery": await runtime.recoveryReport,
            ])

        case "debug.held":
            let runtime = try await resolveRuntime(arguments)
            return try json(["held": try await runtime.heldReport()])

        case "debug.calls":
            // Spike S5's journal of the File Provider calls that reached the agent, with
            // the gap since the previous call of the same kind. Every "how long does the
            // system wait before calling again" question is read off this.
            let location = try? await resolveLocation(arguments)
            if arguments["reset"] == "true" { CallJournal.shared.reset() }
            return try json(
                CallJournal.shared.report(
                    domain: location?.id, limit: Int(arguments["limit"] ?? "") ?? 200))

        case "debug.row":
            // S5's working-set questions: forget a row (an item reported deleted) or give
            // it a content version the system cannot match (what the reconcile walk
            // produces for a pending item).
            let runtime = try await resolveRuntime(arguments)
            guard let path = arguments["path"] else {
                throw SSHDriveAgentError.notImplemented.asNSError("debug.row needs a path.")
            }
            let report = try await runtime.rewriteRowForSpike(
                pathString: path, forget: arguments["forget"] == "true",
                contentVersion: arguments["contentVersion"])
            let location = try await resolveLocation(arguments)
            await DomainManager.shared.signalWorkingSet(locationID: location.id)
            return try json(report)

        case "debug.breaker":
            // Section 6.3's breaker, as the agent holds it: state, backoff, the counters,
            // and section 4.2's re-arm flags. `--drop` runs `-O exit` on the master
            // without touching config, which is "the connection died" without a `kill`;
            // `--reset` is the `sshdrive test` reset; `--connect` clears a stop the way
            // `test` does and attempts once.
            let location = try await resolveLocation(arguments)
            _ = try? await resolveRuntime(arguments)
            guard let gate = await DomainManager.shared.gate(locationID: location.id) else {
                return try json(["breaker": "none", "reason": "not an sftp location"])
            }
            if let quiet = arguments["quietRecovery"] {
                await gate.setSuppressRecoverySignals(quiet == "on")
            }
            if arguments["drop"] == "true" { await gate.drop(reason: "sshdrive debug breaker --drop") }
            if arguments["reset"] == "true" { await gate.didWake(trigger: "sshdrive debug breaker --reset") }
            if arguments["connect"] == "true" { await gate.clearStopAndConnect() }
            return try json(["breaker": await gate.report()])

        case "debug.power":
            // `pmset sleepnow` is the real path; this is what a machine that will not
            // honour it uses instead, and it drives the same two handlers (section 6.1).
            switch arguments["event"] ?? "" {
            case "will-sleep":
                await DomainManager.shared.willSleep()
                return try json(["event": "will-sleep", "power": PowerEvents.shared.report])
            case "did-wake":
                await DomainManager.shared.didWake(trigger: "a debug hook")
                return try json(["event": "did-wake", "power": PowerEvents.shared.report])
            case "path-down":
                await DomainManager.shared.networkPathChanged(available: false)
                return try json(["event": "path-down", "path": NetworkPathGate.shared.report])
            case "path-up":
                await DomainManager.shared.networkPathChanged(available: true)
                return try json(["event": "path-up", "path": NetworkPathGate.shared.report])
            default:
                return try json([
                    "power": PowerEvents.shared.report,
                    "path": NetworkPathGate.shared.report,
                    "screen": ScreenLockObserver.shared.report,
                ])
            }

        case "debug.presence":
            // Section 4.2's presence test, exactly as the re-arm reads it.
            return try json([
                "presence": AgentPresence.report(),
                "screen": ScreenLockObserver.shared.report,
            ])

        case "debug.rearm":
            // The screen-unlock trigger of section 4.2, driven by hand because a headless
            // VM has no screen to unlock. `--request` drives the other trigger.
            let location = try await resolveLocation(arguments)
            if arguments["request"] == "true" {
                guard let gate = await DomainManager.shared.gate(locationID: location.id) else {
                    return try json(["rearm": "none"])
                }
                await gate.fileProviderRequestArrived()
                return try json(["rearm": "request", "breaker": await gate.report()])
            }
            await ScreenLockObserver.shared.simulateUnlock()
            let gate = await DomainManager.shared.gate(locationID: location.id)
            return try json([
                "rearm": "unlock",
                "breaker": await gate?.report() ?? [:],
            ])

        case "debug.transfers":
            let runtime = try await resolveRuntime(arguments)
            return try json(await runtime.transferStats(reset: arguments["reset"] == "true"))

        case "debug.stabilize":
            let location = try await resolveLocation(arguments)
            return try json(try await SpikeHooks.stabilize(locationID: location.id))

        case "debug.testing":
            let location = try await resolveLocation(arguments)
            do {
                return try json(
                    try SpikeHooks.testingOperations(
                        locationID: location.id, run: arguments["run"] == "true"))
            } catch {
                // The failure is the answer when the domain was not added with
                // NSFileProviderDomainTestingModeInteractive.
                return try json(SpikeHooks.describe(error: error))
            }

        case "debug.keychain":
            return try keychainRoundTrip(arguments)

        case "debug.secrets":
            return try await AgentSecretsDebug.run(arguments)

        case "debug.signal":
            let location = try await resolveLocation(arguments)
            if arguments["errorResolved"] == "true" {
                // Section 5.6's first half on its own, so S5 can say whether it is what
                // wakes the flush or whether the working-set signal is doing the work.
                await DomainManager.shared.signalErrorResolved(locationID: location.id)
                return try json(["signalled": location.id, "container": "errorResolved"])
            }
            guard let container = arguments["container"] else {
                await DomainManager.shared.signalWorkingSet(locationID: location.id)
                return try json(["signalled": location.id, "container": "workingSet"])
            }
            // A container's own enumerator, which is what makes the system list a folder
            // it has never listed (S6, s6-3).
            let runtime = try await resolveRuntime(arguments)
            let (identifier, _) = try await runtime.identifier(forPath: container)
            let itemIdentifier =
                identifier == IndexWriter.rootIdentifier
                ? NSFileProviderItemIdentifier.rootContainer
                : NSFileProviderItemIdentifier(identifier)
            await DomainManager.shared.signalEnumerator(
                locationID: location.id, container: itemIdentifier)
            return try json([
                "signalled": location.id, "container": container, "identifier": identifier,
            ])

        case let transport where transport.hasPrefix("debug.transport"):
            return try await TransportDebug.run(command: transport, arguments: arguments)

        default:
            throw SSHDriveAgentError.notImplemented.asNSError("Unknown command \"\(command)\".")
        }
    }

    static let agentVersion = "0.1.0-milestone1"

    // MARK: doctor

    /// The checks section 8 lists. Two of them, "CLI on PATH" and "agent reachable", the
    /// CLI adds itself: the first it can only see from the terminal, and the second is
    /// implied by this call having arrived at all.
    private static func doctor() async -> [[String: Any]] {
        var checks: [[String: Any]] = []

        func check(_ name: String, _ ok: Bool?, _ detail: String, remedy: String? = nil) {
            var entry: [String: Any] = [
                "name": name,
                "status": ok == nil ? "warn" : (ok! ? "ok" : "fail"),
                "detail": detail,
            ]
            if let remedy { entry["remedy"] = remedy }
            checks.append(entry)
        }

        // App in /Applications.
        let bundleURL = Bundle.main.bundleURL
        let inApplications = bundleURL.path.hasPrefix("/Applications/")
        check(
            "app in /Applications", inApplications, bundleURL.path,
            remedy: inApplications
                ? nil : "Move SSH Drive.app to /Applications, or install it with the Homebrew cask.")

        // macOS version. Minimum is 14 (section 2).
        let version = ProcessInfo.processInfo.operatingSystemVersion
        check(
            "macOS version", version.majorVersion >= 14,
            "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            remedy: version.majorVersion >= 14 ? nil : "SSH Drive needs macOS 14 or newer.")

        // The login item. SMAppService.agent registers it from the app's own bundle.
        let service = SMAppService.agent(plistName: "\(SSHDriveIdentifiers.agentLabel).plist")
        let statusText: String
        var loginItemOK: Bool? = nil
        switch service.status {
        case .enabled: statusText = "enabled"; loginItemOK = true
        case .requiresApproval: statusText = "requires approval"; loginItemOK = false
        case .notRegistered: statusText = "not registered"; loginItemOK = false
        case .notFound: statusText = "not found"; loginItemOK = false
        @unknown default: statusText = "unknown"
        }
        check(
            "login item", loginItemOK, statusText,
            remedy: loginItemOK == true
                ? nil
                : "Enable SSH Drive in System Settings > General > Login Items, "
                    + "or run: open -g -a \"SSH Drive\"")

        // The app group container, which is where the index and config.json live.
        if let url = GroupContainer.url {
            let writable = FileManager.default.isWritableFile(atPath: url.path)
            check("app group container", writable, url.path,
                  remedy: writable ? nil : "The container exists but is not writable.")
        } else {
            check(
                "app group container", false,
                "not available (\(GroupContainer.identifier))",
                remedy: "The agent is missing its application-groups entitlement, or is unsigned.")
        }

        // The extension, as PlugInKit sees it. `pluginkit -m -A -i <id>` prints a line
        // when the extension is registered.
        let pluginKit = pluginKitStatus()
        check(
            "extension registered", pluginKit != nil, pluginKit ?? "pluginkit reported nothing",
            remedy: pluginKit == nil
                ? "Launch the app once from its bundle: open -g -a \"SSH Drive\"" : nil)

        // The ssh binary, always /usr/bin/ssh by absolute path (section 6.1).
        let sshVersion = SSHProcess.sshVersion()
        check("ssh", sshVersion != nil, sshVersion ?? "cannot run \(SSHProcess.sshBinaryPath)")

        // Section 4.1: a config written for a newer Homebrew OpenSSH may use a keyword
        // Apple's build rejects, and `ssh -G` then fails with `Bad configuration option`.
        // Resolving a name nothing can match exercises every `Host *` and `Include` block
        // without naming anybody's server.
        let configCheck = sshConfigParse()
        check(
            "~/.ssh/config parses", configCheck.ok, configCheck.detail,
            remedy: configCheck.ok
                ? nil
                : "/usr/bin/ssh is Apple's build; a keyword only a newer OpenSSH understands "
                    + "will do this. Guard it with `Match exec` or remove it.")

        // Section 6.1's orphan sweep, reported rather than run: `doctor` is a diagnosis,
        // and adopting or killing a master while a location is mounted would be a repair
        // nobody asked for.
        let sockets = ControlSocket.existingSockets()
        let live = await liveLocationSockets()
        let orphans = sockets.filter { !live.contains($0) }
        check(
            "control sockets", orphans.isEmpty,
            sockets.isEmpty
                ? "none in \(ControlSocket.temporaryDirectory())"
                : "\(sockets.count) socket(s), \(orphans.count) with no location: "
                    + orphans.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
            remedy: orphans.isEmpty
                ? nil
                : "A crashed agent leaves its `ssh -N` children behind. "
                    + "`sshdrive agent restart` sweeps them (section 6.1).")

        // The keychain, from the only process that has `keychain-access-groups`
        // (section 3.1). Reachability, not contents: nothing here reads a secret.
        let keychain = keychainReachable()
        check(
            "keychain", keychain.ok, keychain.detail,
            remedy: keychain.ok
                ? nil
                : "The agent needs its embedded provisioning profile for "
                    + "keychain-access-groups; an ad-hoc signed build cannot have one.")

        // The login shell snapshot (section 6.1): `PATH` and `SSH_AUTH_SOCK` as a fresh
        // login shell has them, which is what makes a key agent socket exported from
        // `.zshrc` and a `ProxyCommand` in /opt/homebrew/bin work from launchd.
        let snapshot = await AgentSSHEnvironment.shared.current()
        var snapshotReport = "\(snapshot.shell): PATH \(snapshot.path ?? "(launchd's)")"
        snapshotReport += snapshot.sshAuthSock.map { ", SSH_AUTH_SOCK \($0)" } ?? ", no SSH_AUTH_SOCK"
        if snapshot.interactiveOnly {
            // csh and tcsh accept -l only as the sole flag, so those two are read with
            // -ic: interactive but not login, which misses a PATH set only in .login.
            snapshotReport += "; read with -ic, so a PATH set only in .login is missed"
        }
        check(
            "login shell snapshot", snapshot.succeeded ? true : nil,
            snapshot.succeeded
                ? snapshotReport
                : "failed (\(snapshot.diagnostic ?? "no diagnostic")); using launchd's PATH and SSH_AUTH_SOCK")

        // Domains the system currently holds for us.
        do {
            let domains = try await DomainManager.existingDomainDescriptions()
            check(
                "file provider domains", true,
                domains.joined(separator: ", ").ifEmpty("none"))
        } catch {
            check("file provider domains", false, error.localizedDescription)
        }

        checks.append([
            "name": "uninstall reminder",
            "status": "note",
            "detail": "Run `sshdrive remove --all` before `brew uninstall --cask ssh-drive`: "
                + "Homebrew cannot remove File Provider domains or keychain items for you.",
        ])
        return checks
    }

    /// `ssh -G` against a name no config can match, so every `Host *` block and every
    /// `Include` is parsed but nothing is resolved to a real server (section 4.1).
    private static func sshConfigParse() -> (ok: Bool, detail: String) {
        let probe = "sshdrive-doctor-nonexistent.invalid"
        guard let result = try? Spawn.capture(
            executable: SSHProcess.sshBinaryPath,
            argv: [SSHProcess.sshBinaryPath, "-G", probe],
            environment: ProcessInfo.processInfo.environment, timeout: 10)
        else { return (false, "could not run \(SSHProcess.sshBinaryPath) -G") }
        // `ssh -G` also prints notes about the session shape it would have used, which
        // say nothing about the config parsing and which the agent overrides anyway
        // (section 6.1). Only the parse diagnostics are a `doctor` finding.
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Pseudo-terminal will not be allocated") }
            .joined(separator: "; ")
        if result.exit.isClean {
            return (true, stderr.isEmpty ? "no warnings" : "warnings: \(stderr)")
        }
        return (false, stderr.isEmpty ? "ssh -G exited \(result.exit.status)" : stderr)
    }

    /// The control sockets of locations that are actually up, so the orphan count in
    /// `doctor` does not accuse a healthy mount.
    private static func liveLocationSockets() async -> Set<String> {
        guard let file = try? await DomainManager.shared.configuration() else { return [] }
        var out: Set<String> = []
        for location in file.locations {
            guard await DomainManager.shared.startedRuntime(locationID: location.id) != nil
            else { continue }
            out.insert(ControlSocket.path(forLocationID: location.id))
        }
        return out
    }

    /// One `SecItemCopyMatching` under our access group. A `errSecItemNotFound` is a pass:
    /// it means the query was accepted and the group is reachable.
    private static func keychainReachable() -> (ok: Bool, detail: String) {
        let group = SSHDriveIdentifiers.keychainAccessGroup
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretsStore.service,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            let count = (item as? [Any])?.count ?? 0
            return (true, "\(group): reachable, \(count) item(s)")
        case errSecItemNotFound:
            return (true, "\(group): reachable, no items yet")
        default:
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return (false, "\(group): \(text)")
        }
    }

    private static func pluginKitStatus() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-A", "-i", SSHDriveIdentifiers.extensionBundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: debug hooks

    /// `sshdrive pins --import FILE`: the CLI reads the file and sends its bytes, since it
    /// is the process with the user's working directory and their read permission. Markers
    /// are applied one at a time, shortest path first, so a pin above an exclusion is
    /// written before the exclusion that invariant 2 would otherwise wipe.
    private static func importPins(
        payload: String, location: Location, runtime: LocationRuntime
    ) async throws -> [String: Any] {
        guard let data = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw SSHDriveAgentError.notImplemented.asNSError("That file is not JSON.")
        }
        var entries: [[String: Any]] = []
        if let array = json as? [[String: Any]] { entries = array }
        if let object = json as? [String: Any], let array = object["pins"] as? [[String: Any]] {
            entries = array
        }
        var applied: [String] = []
        var failed: [String] = []
        for entry in entries.sorted(by: {
            ($0["path"] as? String ?? "").count < ($1["path"] as? String ?? "").count
        }) {
            guard let path = entry["path"] as? String else { continue }
            let state = entry["state"] as? String ?? ""
            let marker: Int64 = state == "pinned" ? 1 : (state == "excluded" ? -1 : 0)
            do {
                _ = try await runtime.setPinState(pathString: path, marker: marker)
                applied.append(path)
            } catch {
                failed.append("\(path): \(error.localizedDescription)")
            }
        }
        if !applied.isEmpty {
            await DomainManager.shared.signalWorkingSet(locationID: location.id)
        }
        return ["location": location.displayName, "imported": applied, "failed": failed]
    }

    private static func resolveLocation(_ arguments: [String: String]) async throws -> Location {
        guard let name = arguments["name"] else {
            throw SSHDriveAgentError.unknownDomain.asNSError("This command needs a location name.")
        }
        return try await DomainManager.shared.location(named: name)
    }

    private static func resolveRuntime(_ arguments: [String: String]) async throws -> LocationRuntime {
        let location = try await resolveLocation(arguments)
        return try await DomainManager.shared.runtime(for: location)
    }

    /// Creates a location backed by the in-memory tree and adds its domain, so the File
    /// Provider half can be exercised before a byte of SSH exists (section 12).
    private static func addFakeLocation(_ arguments: [String: String]) async throws -> Data {
        guard let name = arguments["name"] else {
            throw SSHDriveAgentError.unknownDomain.asNSError("debug.fake.add needs a name.")
        }
        let fileCount = Int(arguments["files"] ?? "8") ?? 8
        var location = Location(
            nickname: name,
            host: "fake",
            remotePath: "/srv/fake",
            cacheTTL: .oneHour,
            mounted: true,
            backend: .fake)
        if let existing = try? await DomainManager.shared.location(named: name) {
            location.id = existing.id
        }
        let created = location
        try await DomainManager.shared.mutateConfiguration { file in
            file.locations.removeAll { $0.id == created.id }
            file.locations.append(created)
        }
        let runtime = try await DomainManager.shared.runtime(for: created)
        try await runtime.seedFakeTree(fileCount: fileCount)
        _ = try await runtime.enumerateItems(container: IndexWriter.rootIdentifier, pageToken: nil)
        var testingModes: NSFileProviderDomain.TestingModes = []
        for word in (arguments["testingModes"] ?? "").split(separator: ",") {
            switch word.trimmingCharacters(in: .whitespaces) {
            case "always": testingModes.insert(.alwaysEnabled)
            case "interactive": testingModes.insert(.interactive)
            default: break
            }
        }
        try await DomainManager.shared.addDomain(for: created, testingModes: testingModes)
        return try json([
            "id": created.id, "name": created.displayName, "files": fileCount,
            "testingModes": arguments["testingModes"] ?? "",
            "mountHint": "~/Library/CloudStorage (the exact name is what spike S3 records)",
        ])
    }

    private static func removeLocation(_ arguments: [String: String]) async throws -> Data {
        let location = try await resolveLocation(arguments)
        try await DomainManager.shared.removeDomain(for: location)
        await DomainManager.shared.dropRuntime(locationID: location.id)
        try await DomainManager.shared.mutateConfiguration { file in
            file.locations.removeAll { $0.id == location.id }
        }
        if let url = try? GroupContainer.domainURL(locationID: location.id) {
            try? FileManager.default.removeItem(at: url)
        }
        return try json(["removed": location.id])
    }

    private static func mutate(_ arguments: [String: String]) async throws -> Data {
        let runtime = try await resolveRuntime(arguments)
        guard let operation = arguments["op"], let path = arguments["path"] else {
            throw SSHDriveAgentError.notImplemented.asNSError("debug.mutate needs op and path.")
        }
        let relative = try RelativePath(string: path)
        let contents = Data((arguments["contents"] ?? "").utf8)
        let mode = UInt32(arguments["mode"] ?? "644", radix: 8) ?? 0o644

        let mutation: FakeMutation
        switch operation {
        case "create-file": mutation = .createFile(path: relative, contents: contents, mode: mode)
        case "create-dir": mutation = .createDirectory(path: relative, mode: mode)
        case "create-symlink":
            mutation = .createSymlink(path: relative, target: arguments["target"] ?? "")
        case "write": mutation = .write(path: relative, contents: contents)
        case "touch": mutation = .touch(path: relative)
        case "rewrite-invisibly": mutation = .rewriteInvisibly(path: relative, contents: contents)
        case "chmod": mutation = .chmod(path: relative, mode: mode)
        case "rename":
            guard let to = arguments["to"] else {
                throw SSHDriveAgentError.notImplemented.asNSError("rename needs --to.")
            }
            mutation = .rename(from: relative, to: try RelativePath(string: to))
        case "delete":
            mutation = .delete(path: relative, recursive: arguments["recursive"] == "true")
        default:
            throw SSHDriveAgentError.notImplemented.asNSError("Unknown mutation \"\(operation)\".")
        }

        let changes = try await runtime.applyFakeMutation(mutation)
        let location = try await resolveLocation(arguments)
        if changes > 0 {
            await DomainManager.shared.signalWorkingSet(locationID: location.id)
        }
        return try json(["applied": operation, "path": path, "changesSeenBySweep": changes])
    }

    /// Annotates identifiers the system handed back with the path the index holds for
    /// them, so a materialized-set dump reads as paths rather than UUIDs.
    private static func withPaths(_ rows: [[String: Any]], runtime: LocationRuntime) async throws
        -> [[String: Any]]
    {
        var out: [[String: Any]] = []
        for var row in rows {
            if let identifier = row["identifier"] as? String,
                let indexRow = try await runtime.row(identifier: identifier)
            {
                row["path"] = String(decoding: indexRow.path, as: UTF8.self)
                row["kept"] = indexRow.kept
                row["pinState"] = indexRow.pinState
            }
            out.append(row)
        }
        return out.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    }

    private static func dumpIndex(_ arguments: [String: String]) async throws -> Data {
        let runtime = try await resolveRuntime(arguments)
        switch arguments["table"] ?? "items" {
        case "anchors":
            let anchors = try await runtime.dumpAnchors(limit: Int(arguments["limit"] ?? "100") ?? 100)
            return try json([
                "anchors": anchors.map {
                    ["seq": $0.sequence, "identifier": $0.identifier, "kind": $0.kind.rawValue]
                        as [String: Any]
                }
            ])
        case "roots":
            let roots = try await runtime.dumpRoots()
            return try json([
                "roots": roots.map {
                    ["path": String(decoding: $0.path, as: UTF8.self), "reason": $0.reason,
                     "lastSeen": $0.lastSeen] as [String: Any]
                }
            ])
        default:
            let items = try await runtime.dumpIndex()
            return try json([
                "items": items.map { row in
                    [
                        "identifier": row.identifier,
                        "path": String(decoding: row.path, as: UTF8.self),
                        "parent": row.parent ?? "",
                        "type": row.type,
                        "size": row.size,
                        "mode": String(UInt32(row.mode ?? 0), radix: 8),
                        "contentVersion": row.contentVersion,
                        "metadataVersion": row.metadataVersion,
                        "kept": row.kept,
                        "pinState": row.pinState,
                        "capabilities": row.capabilities,
                        "fsFlags": row.fileSystemFlags,
                        "hidden": row.hidden,
                        // Section 5.7: the Mac-side target after the relative rewrite, as
                        // the extension will serve it. Empty for anything but a link that
                        // passed the lexical check.
                        "linkTarget": row.linkTarget.map {
                            String(decoding: $0, as: UTF8.self)
                        } ?? "",
                    ] as [String: Any]
                }
            ])
        }
    }

    /// S1(d2): one `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` round trip in
    /// the data-protection keychain under the shared access group, from the
    /// launchd-started agent. This is the only process that has `keychain-access-groups`
    /// (section 3.1), and the entitlement is restricted, so it only works from a bundle
    /// that embeds a provisioning profile. The real store arrives in milestone 2; this
    /// hook exists so the spike can prove the entitlement is live before then.
    private static func keychainRoundTrip(_ arguments: [String: String]) throws -> Data {
        let account = arguments["key"] ?? "spike:s1d2"
        let value = arguments["value"] ?? "spike-\(UUID().uuidString)"
        let group = KeychainSecretsStore().accessGroup
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretsStore.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
        ]

        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)

        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        let readBack = (item as? Data).map { String(decoding: $0, as: UTF8.self) }

        let deleteStatus = SecItemDelete(base as CFDictionary)

        return try json([
            "accessGroup": group,
            "account": account,
            "wrote": value,
            "readBack": readBack ?? "",
            "matched": readBack == value,
            "addStatus": Int(addStatus),
            "readStatus": Int(readStatus),
            "deleteStatus": Int(deleteStatus),
            "addStatusText": SecCopyErrorMessageString(addStatus, nil) as String? ?? "",
            "readStatusText": SecCopyErrorMessageString(readStatus, nil) as String? ?? "",
        ])
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
