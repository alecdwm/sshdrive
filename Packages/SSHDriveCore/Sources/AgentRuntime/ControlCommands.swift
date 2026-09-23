import Foundation
import AgentCore
import Config
import Secrets
import Index
import SFTP
import SSHProcess
import XPCProtocols
import Logging
import ProviderCore

/// Everything the CLI asks the agent to do. The CLI is a pure XPC client: every command
/// is a request to the agent, so the CLI never touches the network, the keychain or File
/// Provider (docs/design/components.md).
///
/// The commands that name a location are forwarded to `LocationCommands`; `doctor`, the
/// cache and pin commands, the agent's lifecycle and the whole `debug` group are here.
public enum ControlCommands {

    public static func run(
        command: String, arguments: [String: String], relay: (any TerminalRelaying)? = nil
    ) async throws -> Data {
        let manager = AgentCommandContext.manager
        let environment = manager.environment
        switch command {
        case "add", "show", "remove", "set", "mount", "unmount", "status":
            // The user-facing half. `add` and a `set` that re-keys the secrets are the two
            // that need a terminal, which is what `relay` is.
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
            // command or extension call causes, so stop is a pause, not a disable.
            //
            // Every location's master and its mux clients go first. Exiting without that
            // leaves an `ssh -N` per location holding a connection to a server, with a
            // control socket the next start will unlink out from under it. The reply is
            // sent before the shutdown runs - the CLI is waiting on it, and `-O exit`
            // against an unreachable server can take seconds per location - so `stopping`
            // means "accepted" and the exit still follows.
            //
            // It is `AgentLifecycle.shutdownAndExit` and not an `exit(0)` of its own: the
            // cask's TERM takes the same path, and one shutdown with one exit status is
            // the whole of `P4`. The exit goes through `AgentEndpoint` so a harness can
            // record the status instead of taking the test process with it.
            let manager = AgentCommandContext.manager
            let environment = manager.environment
            Task {
                await AgentLifecycle.shutdownAndExit(
                    reason: "exiting on request from the CLI", manager: manager,
                    environment: environment)
            }
            // A server that has gone away must not be able to keep the agent alive.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + AgentLifecycle.shutdownGraceSeconds
            ) {
                Log.agent.error("shutdown did not finish in 20 s; exiting anyway")
                environment.endpoint.terminate(status: AgentLifecycle.exitStatus)
            }
            return try json(["stopping": true])

        case "debug.fake.add":
            return try await addFakeLocation(arguments)

        case "debug.fake.remove":
            return try await removeLocation(arguments)

        case "list":
            return try await LocationCommands.run(
                command: "list", arguments: arguments, relay: relay)

        case "debug.fake.list":
            let file = try await AgentCommandContext.manager.configuration()
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
            await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
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
            await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
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
            var report = await environment.replica.evict(
                locationID: location.id, identifier: identifier)
            report["identifier"] = identifier
            report["path"] = arguments["path"] ?? ""
            report["kept"] = row.kept
            report["allowsEvictingServed"] =
                (row.capabilities & Int64(ProviderCapabilities.allowsEvicting.rawValue))
                != 0
            return try json(report)

        case "debug.materialized":
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let wantsPending = arguments["pending"] == "true"
            let identifiers =
                wantsPending
                ? (await environment.replica.pendingIdentifiers(locationID: location.id) ?? [])
                : (await environment.replica.materializedIdentifiers(locationID: location.id)
                    ?? [])
            let rows = identifiers.map { ["identifier": $0] as [String: Any] }
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
            let url = try await environment.replica.userVisibleURL(
                locationID: location.id, identifier: identifier)
            var report = environment.replica.statReport(
                url: url, readFirst: arguments["read"] == "true")
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
                // Exactly the stored blob is hashed into the metadata version, so the
                // hash is printed beside the version it feeds.
                "xattrHash": String(ItemDerivation.fnv1a(row.xattrs ?? Data()), radix: 16),
                "storedBlobBytes": row.xattrs?.count ?? 0,
                "hidden": row.hidden,
                "servedExtendedAttributes": try await runtime.servedExtendedAttributes(
                    pathString: path),
                // Tags never arrive as an xattr: they are the item's own `tagData`
                // Printed base64 because the blob is a binary plist.
                "tagDataBase64": local.tagData?.base64EncodedString() ?? "",
                "tagDataBytes": local.tagData?.count ?? 0,
            ])

        case "debug.fault":
            let runtime = try await resolveRuntime(arguments)
            // Outage simulation. A VM guest cannot take its host's link
            // down or stop the host's containers, so `--unreachable` and
            // `--transport-hang` are what stand in for those: the first fails every
            // transport call and every connect attempt the way a dead server does, the
            // second stalls them the way a network that has gone but not said so does.
            let location = try await resolveLocation(arguments)
            if let gate = await AgentCommandContext.manager.gate(locationID: location.id) {
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
            // Applies deletions the mass-deletion guard is holding. With no path,
            // everything the location is holding; with one, that path and its subtree.
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let applied = try await runtime.acceptDeletions(pathString: arguments["path"])
            if applied > 0 {
                await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
            }
            return try json([
                "location": location.displayName,
                "applied": applied,
                "stillHeld": (try? await runtime.heldReport())?.count ?? 0,
            ])

        case "evict":
            // `sshdrive evict <location> [path]` triggers the TTL routine on demand, with
            // `--all` to drop everything cached, which is one `evictItem` on the root
            // container rather than a walk.
            let location = try await resolveLocation(arguments)
            _ = try await resolveRuntime(arguments)
            guard let evictor = await AgentCommandContext.manager.evictor(locationID: location.id) else {
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
            // The shortest real TTL is 15 minutes; this is what makes the loop
            // testable in a runbook. Nothing else about the pass changes.
            let location = try await resolveLocation(arguments)
            _ = try await resolveRuntime(arguments)
            guard let evictor = await AgentCommandContext.manager.evictor(locationID: location.id) else {
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
            // `pin` and `unpin` are statements about the effective state, never about a
            // marker; which marker that becomes is `PinPolicy`'s.
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            let path = arguments["path"] ?? ""
            let request: PinPolicy.Request = command == "pin" ? .keep : .dontKeep
            var report = try await runtime.applyPin(pathString: path, request: request)
            if report["changed"] as? Bool == true {
                // The anchors are written; this is what makes the system read them.
                await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
                if request == .keep, let identifier = report["identifier"] as? String {
                    // The last step of a pin, and not an optional one: without a lookup
                    // of the path in the replica the system ingests nothing and the eager
                    // download never starts.
                    report["replicaLookup"] = await environment.replica.lookUpInReplica(
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
            let materialized = await environment.replica.materializedIdentifiers(
                locationID: location.id)
            return try json([
                "location": location.displayName,
                "cacheTTL": location.cacheTTL.rawValue,
                "pins": try await runtime.pinsReport(materialized: materialized.map(Set.init)),
            ])

        case "debug.watch":
            // Change detection driven by hand: one cycle now, a full sweep now, the loop
            // paused so the caller owns the timing, and the server-clock skew a container
            // cannot provide (testbed/README.md: containers share the host's
            // clock and Docker has no time namespace, so the sweep's own reference is
            // shifted instead and `status` says so).
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            guard let detector = await AgentCommandContext.manager.detector(locationID: location.id) else {
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
            // The root set as the index holds it, with the rotation the next tier 0
            // cycle would take.
            let runtime = try await resolveRuntime(arguments)
            if arguments["refresh"] == "true" {
                let location = try await resolveLocation(arguments)
                let identifiers = await environment.replica.materializedIdentifiers(
                    locationID: location.id)
                _ = try? await runtime.refreshRootSet(materializedIdentifiers: identifiers)
            }
            // `--seed N` marks the first N **real** directory rows as `materialized`
            // roots. Only the reason is injected: every one of them is a directory that
            // exists and is really `readdir`ed by the cycle. Materializing a file in each
            // of five thousand directories to get the reason honestly is five thousand
            // fetches, and what the rotation is measured on is the cost of a
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
            // The reconcile walk on demand: `--force` sets `meta.reconciling` first, so
            // the whole recovery path can be exercised without corrupting an index.
            let location = try await resolveLocation(arguments)
            let runtime = try await resolveRuntime(arguments)
            if arguments["force"] == "true" { try await runtime.markReconciling() }
            let report = await runtime.finishReconcileIfOwed()
            await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
            return try json([
                "location": location.displayName,
                "report": report ?? ["state": "nothing owed"],
                "recovery": await runtime.recoveryReport,
            ])

        case "debug.held":
            let runtime = try await resolveRuntime(arguments)
            return try json(["held": try await runtime.heldReport()])

        case "debug.calls":
            // A journal of the File Provider calls that reached the agent, with the gap
            // since the previous call of the same kind. Every "how long does the system
            // wait before calling again" question is read off this.
            let location = try? await resolveLocation(arguments)
            if arguments["reset"] == "true" { CallJournal.shared.reset() }
            return try json(
                CallJournal.shared.report(
                    domain: location?.id, limit: Int(arguments["limit"] ?? "") ?? 200))

        case "debug.row":
            // The working-set edge cases: forget a row (an item reported deleted) or give
            // it a content version the system cannot match (what the reconcile walk
            // produces for a pending item).
            let runtime = try await resolveRuntime(arguments)
            guard let path = arguments["path"] else {
                throw SSHDriveAgentError.notImplemented.asNSError("debug.row needs a path.")
            }
            let report = try await runtime.rewriteRowForDebug(
                pathString: path, forget: arguments["forget"] == "true",
                contentVersion: arguments["contentVersion"])
            let location = try await resolveLocation(arguments)
            await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
            return try json(report)

        case "debug.breaker":
            // The breaker, as the agent holds it: state, backoff, the counters, and the
            // authentication-deadline re-arm flags. `--drop` runs `-O exit` on the master
            // without touching config, which is "the connection died" without a `kill`;
            // `--reset` is the reset a path change or a wake makes; `--connect` clears a
            // stop and attempts once, which is how a user recovers a stopped location
            // without restarting the agent.
            let location = try await resolveLocation(arguments)
            _ = try? await resolveRuntime(arguments)
            guard let gate = await AgentCommandContext.manager.gate(locationID: location.id) else {
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
            // honour it uses instead, and it drives the same two handlers.
            switch arguments["event"] ?? "" {
            case "will-sleep":
                await AgentCommandContext.manager.willSleep()
                return try json(["event": "will-sleep", "power": environment.power.report])
            case "did-wake":
                await AgentCommandContext.manager.didWake(trigger: "a debug hook")
                return try json(["event": "did-wake", "power": environment.power.report])
            case "path-down":
                await AgentCommandContext.manager.networkPathChanged(available: false)
                return try json(["event": "path-down", "path": environment.network.report])
            case "path-up":
                await AgentCommandContext.manager.networkPathChanged(available: true)
                return try json(["event": "path-up", "path": environment.network.report])
            default:
                return try json([
                    "power": environment.power.report,
                    "path": environment.network.report,
                    "screen": environment.screenLock.report,
                ])
            }

        case "debug.presence":
            // The presence test, exactly as the re-arm reads it.
            return try json([
                "presence": PresenceOverride.report(environment.presence),
                "screen": environment.screenLock.report,
            ])

        case "debug.rearm":
            // The screen-unlock trigger, driven by hand because a headless VM has no
            // screen to unlock. `--request` drives the other trigger.
            let location = try await resolveLocation(arguments)
            if arguments["request"] == "true" {
                guard let gate = await AgentCommandContext.manager.gate(locationID: location.id) else {
                    return try json(["rearm": "none"])
                }
                await gate.fileProviderRequestArrived()
                return try json(["rearm": "request", "breaker": await gate.report()])
            }
            // `sshdrive debug rearm --unlock` drives the same path a real unlock does,
            // because a headless VM cannot lock or unlock a screen.
            await manager.screenUnlocked()
            let gate = await AgentCommandContext.manager.gate(locationID: location.id)
            return try json([
                "rearm": "unlock",
                "breaker": await gate?.report() ?? [:],
            ])

        case "debug.transfers":
            let runtime = try await resolveRuntime(arguments)
            return try json(await runtime.transferStats(reset: arguments["reset"] == "true"))

        case "debug.reader":
            // The extension's read-only reader, from the outside: what it last told us in
            // its state file, and a switch that makes the agent answer `indexReady` no for
            // a while so the reader's readiness race can be reproduced on purpose.
            let location = try await resolveLocation(arguments)
            if let seconds = arguments["notReady"].flatMap(Double.init) {
                ForcedNotReady.shared.set(domainIdentifier: location.id, seconds: seconds)
                await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
            }
            var readerReport: [String: Any] = ["location": location.displayName]
            if let url = try? GroupContainer.readerStateURL(locationID: location.id),
                let data = try? Data(contentsOf: url),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                readerReport["state"] = object
            } else {
                readerReport["state"] = "the extension has not reported its reader"
            }
            return try json(readerReport)

        case "debug.stabilize":
            let location = try await resolveLocation(arguments)
            return try json(try await environment.replica.stabilize(locationID: location.id))

        case "debug.testing":
            let location = try await resolveLocation(arguments)
            do {
                return try json(
                    try await environment.replica.testingOperations(
                        locationID: location.id, run: arguments["run"] == "true"))
            } catch {
                // The failure is the answer when the domain was not added with the
                // interactive testing mode.
                return try json(environment.replica.describe(error: error))
            }

        case "debug.keychain":
            return try keychainRoundTrip(arguments)

        case "debug.secrets":
            return try await AgentSecretsDebug.run(arguments, manager: manager)

        case "debug.domain.rename":
            // `NSFileProviderManager.add(domain)` with an existing identifier and a new
            // displayName renames the domain in place, keeping the cache and the pending
            // uploads. `add` is the only call there is - there is no `rename` on
            // NSFileProviderManager. Nothing is removed first, deliberately: removing the
            // domain is what would throw the cache away.
            let location = try await resolveLocation(arguments)
            guard let display = arguments["displayName"], !display.isEmpty else {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "debug domain rename needs a display name.")
            }
            let before = try await manager.existingDomainDescriptions()
            let materializedBefore = await environment.replica.materializedIdentifiers(
                locationID: location.id)?.count
            var renamed = location
            renamed.nickname = display
            try await AgentCommandContext.manager.addDomain(for: renamed)
            let after = try await manager.existingDomainDescriptions()
            return try json([
                "id": location.id,
                "displayNameBefore": location.displayName,
                "displayNameAfter": display,
                "domainsBefore": before,
                "domainsAfter": after,
                "materializedBefore": materializedBefore as Any,
            ])

        case "debug.signal":
            let location = try await resolveLocation(arguments)
            if arguments["errorResolved"] == "true" {
                // The error-resolved signal on its own. It is what wakes a queued write;
                // the working-set signal does not.
                await AgentCommandContext.manager.signalErrorResolved(locationID: location.id)
                return try json(["signalled": location.id, "container": "errorResolved"])
            }
            guard let container = arguments["container"] else {
                await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
                return try json(["signalled": location.id, "container": "workingSet"])
            }
            // A container's own enumerator, which is what makes the system list a folder
            // it has never listed.
            let runtime = try await resolveRuntime(arguments)
            let (identifier, _) = try await runtime.identifier(forPath: container)
            let itemIdentifier =
                identifier == IndexWriter.rootIdentifier
                ? ProviderItemIdentifier.rootContainer
                : ProviderItemIdentifier(identifier)
            await AgentCommandContext.manager.signalEnumerator(
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

    /// The release version, from the repository's VERSION file through
    /// `scripts/set-version.sh`. The same string the CLI's `--version` prints and the
    /// bundle's `CFBundleShortVersionString`.
    static let agentVersion = SSHDriveVersion.string

    // MARK: doctor

    /// The `doctor` checks. Two of them, "CLI on PATH" and "agent reachable", the
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
        let environment = AgentCommandContext.manager.environment
        let bundleURL = environment.bundle.bundleURL
        let inApplications = bundleURL.path.hasPrefix("/Applications/")
        check(
            "app in /Applications", inApplications, bundleURL.path,
            remedy: inApplications
                ? nil : "Move SSH Drive.app to /Applications, or install it with the Homebrew cask.")

        // macOS version. Minimum is 14.
        let version = environment.bundle.operatingSystemVersion
        check(
            "macOS version", version.major >= 14,
            "\(version.major).\(version.minor).\(version.patch)",
            remedy: version.major >= 14 ? nil : "SSH Drive needs macOS 14 or newer.")

        // The login item. `SMAppService.agent` registers it from the app's own bundle.
        let statusText = environment.loginItem.status()
        let loginItemOK: Bool? = statusText == "unknown" ? nil : (statusText == "enabled")
        check(
            "login item", loginItemOK, statusText,
            remedy: loginItemOK == true
                ? nil
                : "Enable SSH Drive in System Settings > General > Login Items & Extensions, "
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

        // Quarantine, which is checked before the extension because it is the ordinary
        // cause of that check failing. LaunchServices will not register the plugins of a
        // quarantined bundle that has never been assessed through a user-visible launch:
        // the agent runs (launchd starts it directly) while the appex does not exist as
        // far as the system is concerned (measured 2026-09-05).
        let quarantineValue = environment.bundle.quarantineValue(atPath: bundleURL.path)
        check(
            "quarantine", quarantineValue == nil,
            BundleQuarantine.detail(bundlePath: bundleURL.path, value: quarantineValue),
            remedy: quarantineValue == nil ? nil : BundleQuarantine.remedy(bundlePath: bundleURL.path))

        // The extension, as PlugInKit sees it. `pluginkit -m -A -i <id>` prints a line
        // when the extension is registered.
        let pluginKit = environment.bundle.plugInRegistration(
            bundleID: SSHDriveIdentifiers.extensionBundleID)
        check(
            "extension registered", pluginKit != nil, pluginKit ?? "pluginkit reported nothing",
            remedy: pluginKit == nil
                ? "Rebuild the bundle's LaunchServices record: /System/Library/Frameworks"
                    + "/CoreServices.framework/Frameworks/LaunchServices.framework/Support"
                    + "/lsregister -f -R -trusted \"\(bundleURL.path)\", then open -g -a "
                    + "\"SSH Drive\". A record built while the bundle was still being copied "
                    + "is reused by every launch after it, so open -g on its own may not "
                    + "rebuild it. A bundle still carrying com.apple.quarantine is the other "
                    + "cause - LaunchServices registers no plugin of one, and re-registering "
                    + "with pluginkit -a does not survive the next launch. See the "
                    + "\"quarantine\" check above."
                : nil)

        // What the extension's own read-only index reader last said about itself. The
        // extension is sandboxed, short-lived and not running most of the time, so it
        // writes its state into the group container and this is where it is read back. A
        // reader that is not `ready` is not on its own a fault - every read falls back to
        // the agent - but it is the difference between a mount that is slow and a mount
        // that is silent.
        for line in await readerStates() {
            check(
                "index reader (\(line.name))", line.ok, line.detail, remedy: line.remedy)
        }

        // The ssh binary, always /usr/bin/ssh by absolute path.
        let sshVersion = SSHProcess.sshVersion()
        check("ssh", sshVersion != nil, sshVersion ?? "cannot run \(SSHProcess.sshBinaryPath)")

        // A config written for a newer Homebrew OpenSSH may use a keyword
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

        // The orphan socket sweep, reported rather than run: `doctor` is a diagnosis,
        // and adopting or killing a master while a location is mounted would be a repair
        // nobody asked for.
        let sockets = ControlSocket.existingSockets()
        let live = await liveLocationSockets()
        // `ControlSocket.orphanedSockets` rather than a filter written here, so the
        // answer `doctor` prints is the one `K5` asserts (`SQ-074`).
        let orphans = ControlSocket.orphanedSockets(among: sockets, inUse: live)
        check(
            "control sockets", orphans.isEmpty,
            sockets.isEmpty
                ? "none in \(ControlSocket.temporaryDirectory())"
                : "\(sockets.count) socket(s), \(orphans.count) with no location: "
                    + orphans.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
            remedy: orphans.isEmpty
                ? nil
                : "A crashed agent leaves its `ssh -N` children behind. "
                    + "`sshdrive agent restart` sweeps them.")

        // The keychain, from the only process that has `keychain-access-groups`.
        // Reachability, not contents: nothing here reads a secret.
        let keychain = environment.keychain.reachability()
        check(
            "keychain", keychain.ok, keychain.detail,
            remedy: keychain.ok
                ? nil
                : "The agent reaches the keychain only through the "
                    + "keychain-access-groups entitlement, which needs an embedded "
                    + "provisioning profile issued for the certificate the bundle was "
                    + "signed with. An ad-hoc build cannot have one, and a profile made "
                    + "for a different Developer ID certificate does not count. Passwords "
                    + "and key passphrases are all that stop working. Reinstall with "
                    + "`brew reinstall --cask sshdrive`, or use a key the agent needs no "
                    + "stored secret for.")

        // The login shell snapshot: `PATH` and `SSH_AUTH_SOCK` as a fresh
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
            let domains = try await AgentCommandContext.manager.existingDomainDescriptions()
            check(
                "file provider domains", true,
                domains.joined(separator: ", ").ifEmpty("none"))
        } catch {
            check("file provider domains", false, error.localizedDescription)
        }

        checks.append([
            "name": "uninstall reminder",
            "status": "note",
            "detail": "Run `sshdrive remove --all` before `brew uninstall --cask sshdrive`: "
                + "Homebrew cannot remove File Provider domains or keychain items for you.",
        ])
        return checks
    }

    /// `ssh -G` against a name no config can match, so every `Host *` block and every
    /// `Include` is parsed but nothing is resolved to a real server.
    private static func sshConfigParse() -> (ok: Bool, detail: String) {
        let probe = "sshdrive-doctor-nonexistent.invalid"
        guard let result = try? Spawn.capture(
            executable: SSHProcess.sshBinaryPath,
            argv: [SSHProcess.sshBinaryPath, "-G", probe],
            environment: ProcessInfo.processInfo.environment, timeout: 10)
        else { return (false, "could not run \(SSHProcess.sshBinaryPath) -G") }
        // `ssh -G` also prints notes about the session shape it would have used, which
        // say nothing about the config parsing and which the agent overrides anyway
        // Only the parse diagnostics are a `doctor` finding.
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

    /// One line per location, from the `reader-state.json` the File Provider extension
    /// writes into the group container.
    private struct ReaderStateLine {
        var name: String
        var ok: Bool?
        var detail: String
        var remedy: String?
    }

    private static func readerStates() async -> [ReaderStateLine] {
        guard let file = try? await ConfigAccess().load() else { return [] }
        var lines: [ReaderStateLine] = []
        for location in file.locations where location.mounted {
            guard let url = try? GroupContainer.readerStateURL(locationID: location.id) else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                lines.append(
                    ReaderStateLine(
                        name: location.displayName, ok: nil,
                        detail: "the extension has never reported its reader",
                        remedy: "Open the location in Finder once. If this stays empty the "
                            + "extension is not running; see the \"extension registered\" check."))
                continue
            }
            let state = (object["state"] as? String) ?? "unknown"
            let at = (object["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let age = at.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "at an unknown time"
            let generation = (object["generation"] as? Int64) ?? -1
            let lastError = (object["lastError"] as? String) ?? ""
            var detail = "\(state), generation \(generation), reported \(age)"
            if !lastError.isEmpty { detail += "; last error: \(lastError)" }
            if let path = object["path"] as? String, !path.isEmpty { detail += "; \(path)" }
            let ok: Bool? = state == "ready" ? true : nil
            lines.append(
                ReaderStateLine(
                    name: location.displayName, ok: ok, detail: detail,
                    remedy: ok == true
                        ? nil
                        : "Every read falls back to the agent over XPC, so the location still "
                            + "works; a reader that stays unready is slower and worth reporting."))
        }
        return lines
    }

    /// `doctor` does not accuse a healthy mount.
    private static func liveLocationSockets() async -> Set<String> {
        guard let file = try? await AgentCommandContext.manager.configuration() else { return [] }
        var out: Set<String> = []
        for location in file.locations {
            guard await AgentCommandContext.manager.startedRuntime(locationID: location.id) != nil
            else { continue }
            out.insert(ControlSocket.path(forLocationID: location.id))
        }
        return out
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
            await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
        }
        return ["location": location.displayName, "imported": applied, "failed": failed]
    }

    private static func resolveLocation(_ arguments: [String: String]) async throws -> Location {
        guard let name = arguments["name"] else {
            throw SSHDriveAgentError.unknownDomain.asNSError("This command needs a location name.")
        }
        return try await AgentCommandContext.manager.location(named: name)
    }

    private static func resolveRuntime(_ arguments: [String: String]) async throws -> LocationRuntime {
        let location = try await resolveLocation(arguments)
        return try await AgentCommandContext.manager.runtime(for: location)
    }

    /// Creates a location backed by the in-memory tree and adds its domain, so the File
    /// Provider half can be exercised with no server and no SSH.
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
        if let existing = try? await AgentCommandContext.manager.location(named: name) {
            location.id = existing.id
        }
        let created = location
        try await AgentCommandContext.manager.mutateConfiguration { file in
            file.locations.removeAll { $0.id == created.id }
            file.locations.append(created)
        }
        let runtime = try await AgentCommandContext.manager.runtime(for: created)
        try await runtime.seedFakeTree(fileCount: fileCount)
        _ = try await runtime.enumerateItems(container: IndexWriter.rootIdentifier, pageToken: nil)
        let testingModes = (arguments["testingModes"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 == "always" || $0 == "interactive" }
        try await AgentCommandContext.manager.addDomain(for: created, testingModes: testingModes)
        return try json([
            "id": created.id, "name": created.displayName, "files": fileCount,
            "testingModes": arguments["testingModes"] ?? "",
            "mountHint": "~/Library/CloudStorage",
        ])
    }

    private static func removeLocation(_ arguments: [String: String]) async throws -> Data {
        let location = try await resolveLocation(arguments)
        try await AgentCommandContext.manager.removeDomain(for: location)
        await AgentCommandContext.manager.dropRuntime(locationID: location.id)
        try await AgentCommandContext.manager.mutateConfiguration { file in
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
            await AgentCommandContext.manager.signalWorkingSet(locationID: location.id)
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
                        // The Mac-side target after the relative rewrite, as
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

    /// One `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` round trip in the
    /// data-protection keychain under the shared access group, from the launchd-started
    /// agent. This is the only process that has `keychain-access-groups`, and the
    /// entitlement is restricted, so it only works from a bundle that embeds a
    /// provisioning profile. The hook proves the entitlement is live without touching a
    /// real secret.
    private static func keychainRoundTrip(_ arguments: [String: String]) throws -> Data {
        let account = arguments["key"] ?? "debug:keychain"
        let value = arguments["value"] ?? "debug-\(UUID().uuidString)"
        return try json(
            AgentCommandContext.manager.environment.keychain.roundTrip(
                account: account, value: value))
    }

    public static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
