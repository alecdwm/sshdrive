import Foundation
import AgentCore
import Config
import Index
import SFTP
import Secrets
import SSHProcess
import XPCProtocols
import Logging
import ProviderCore

/// `add`, `list`, `show`, `remove`, `set`, `mount`, `unmount` and `status`: the user-facing
/// half of DESIGN.md section 8, with section 8.1's capability report.
///
/// Everything here runs in the agent, because the CLI is a pure XPC client and "even `add`
/// and `passwd` connect from the agent" (section 3, section 4.2). The CLI's only jobs are
/// to parse the flags and to be the terminal the collect connection's prompts are relayed
/// to.
public enum LocationCommands {

    public static func run(
        command: String, arguments: [String: String], relay: (any TerminalRelaying)?
    ) async throws -> Data {
        switch command {
        case "add": return try await add(arguments, relay: relay)
        case "list": return try await list()
        case "show": return try await show(arguments)
        case "remove": return try await remove(arguments)
        case "set": return try await set(arguments, relay: relay)
        case "mount": return try await mount(arguments)
        case "unmount": return try await unmount(arguments)
        case "status": return try await status(arguments)
        default:
            throw SSHDriveAgentError.notImplemented.asNSError("Unknown command \"\(command)\".")
        }
    }

    // MARK: add

    /// The section 8 `add`, in the order the section itself sets out: resolve and show,
    /// warn about the environment, connect once with the command the location will use
    /// later, record, probe, mount.
    private static func add(_ arguments: [String: String], relay: (any TerminalRelaying)?) async throws -> Data {
        guard let destinationText = arguments["destination"] else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "add needs a destination: [user@]host-or-alias[:port].")
        }
        let destination = try LocationDestination.parse(destinationText)

        var sshOptions: [String] = []
        for option in (arguments["sshOptions"] ?? "").split(separator: "\u{1}") where !option.isEmpty {
            sshOptions += ["-o", String(option)]
        }
        if let identity = arguments["identity"], !identity.isEmpty {
            sshOptions += ["-o", "IdentitiesOnly=yes"]
        }
        if let jump = arguments["jump"], !jump.isEmpty {
            // Stored the way a `~/.ssh/config` ProxyJump resolves: `ssh -G` reports it and
            // the agent rebuilds every hop as its own ProxyCommand. It is never handed to
            // `ssh` as an option (section 6.1).
            _ = try JumpHop.parseChain(jump)
            sshOptions += ["-o", "ProxyJump=\(jump)"]
        }

        var location = Location(
            nickname: arguments["nickname"],
            host: destination.host,
            user: destination.user ?? arguments["user"],
            port: destination.port ?? arguments["port"].flatMap(Int.init),
            identityFile: (arguments["identity"]?.isEmpty == false)
                ? (arguments["identity"]! as NSString).expandingTildeInPath : nil,
            sshOptions: sshOptions,
            remotePath: arguments["remotePath"],
            cacheTTL: CacheTTL(rawValue: arguments["cacheTTL"] ?? "") ?? .oneHour,
            permissions: PermissionsMode(rawValue: arguments["permissions"] ?? "") ?? .mode,
            mounted: true,
            backend: .sftp)

        let existing = try await AgentCommandContext.manager.configuration().locations
        if let clash = existing.first(where: { $0.displayName == location.displayName }) {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "\"\(location.displayName)\" is already a location (\(clash.id)). "
                    + "Pick another --nickname, or remove it first.")
        }

        // Section 6.1: the login shell snapshot is refreshed on every `add`.
        let snapshot = await AgentSSHEnvironment.shared.refresh()
        let environment = await AgentSSHEnvironment.shared.environment()

        // Section 4.1: `ssh -G` and the diff against `ssh -F /dev/null -G`. A config
        // written for a newer Homebrew OpenSSH may use a keyword Apple's build rejects;
        // `add` reports that together with `/usr/bin/ssh -V`, so the mismatch is found
        // here rather than at the first reconnect.
        let target = SSHProcess.target(for: location)
        let attribution: SSHConfigAttribution
        do {
            attribution = try SSHConfigResolver.attribution(
                target: target, environment: environment)
        } catch let error as SSHProcessError {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "\(error.localizedDescription)\n"
                    + "ssh is \(SSHProcess.sshVersion() ?? "/usr/bin/ssh (version unknown)"); "
                    + "a keyword only a newer OpenSSH understands will do this.")
        }
        let display = SSHConfigDisplay.make(
            attribution: attribution,
            overrideKeywords: SSHConfigDisplay.overrideKeywords(for: target))

        relay?.note("\(location.host) resolves to:")
        relay?.note(display.text)

        // Section 4.2: the terminal can differ from the snapshot. Compare and say which
        // the agent will use, because "works in a terminal" means "works in a fresh login
        // shell" and this is where the user finds that out.
        for warning in environmentWarnings(arguments: arguments, snapshot: snapshot) {
            relay?.note(warning)
        }

        let identityFiles = attribution.resolved.identityFiles
        let request = CollectConnection.Request(
            locationID: location.id,
            target: target,
            environment: environment,
            askpassPath: AgentCommandContext.manager.secrets.askpassPath,
            resolution: attribution.resolved,
            identityFiles: identityFiles)
        let collector = CollectConnection(
            request: request, broker: AgentCommandContext.manager.secrets.broker, relay: relay)

        relay?.note("Connecting once to check, with the command SSH Drive will use later.")
        let outcome = await AddFlow.run(
            hostKeyChecking: arguments["trustFirst"] == "true" ? "accept-new" : "ask",
            allowKeyAgent: arguments["noPassword"] != "true",
            note: { [weak relay] in relay?.note($0) },
            runner: collector)

        guard outcome.authenticated else {
            let hint = AddFlow.identityHint(
                touchKeys: outcome.failure.flatMap { failure -> [String] in
                    if case let .needsAHumanEveryTime(_, keys) = failure { return keys }
                    return []
                } ?? [],
                identityFiles: identityFiles,
                fingerprints: CollectConnection.fingerprints(
                    of: identityFiles, environment: environment),
                destination: destinationText)
            let message = outcome.failure?.message(identityHint: hint)
                ?? "Could not authenticate."
            // Nothing has been written yet: the location is created only after the collect
            // connection has succeeded, so there is no half-added location to clean up.
            throw SSHDriveAgentError.notAuthenticated.asNSError(message)
        }

        location.agentDependent = outcome.agentDependent
        location.secrets = collector.committedKeys.sorted()

        let created = location
        try await AgentCommandContext.manager.mutateConfiguration { file in
            file.locations.removeAll { $0.id == created.id }
            file.locations.append(created)
        }
        // The one `ssh` that ever sees the server's identification string has just run
        // (section 8.1; 2026-09-08). It is written after the location exists so an `add`
        // that failed leaves no domain directory behind.
        CapabilityCache.storeServerVersion(
            collector.remoteSoftwareVersion, locationID: created.id)

        do {
            relay?.note("Connecting for real, from the stored answers.")
            // The location's own master, with `StrictHostKeyChecking=yes`, no relay and no
            // terminal: exactly the connection every later reconnect makes. If this works,
            // section 4.2's promise that "a location that passes `add` works from the
            // agent" has been demonstrated rather than asserted.
            let runtime = try await AgentCommandContext.manager.runtime(for: created)
            // `LocationRuntime.start()` deliberately swallows a failed `applyConnection`,
            // because section 5.6 wants a location whose server is down to mount anyway.
            // `add` is the one moment where that is wrong: the user is at the terminal,
            // nothing is mounted yet, and a location added against a root the server does
            // not have would come back `.serverUnreachable` for ever. Re-running it here
            // is what puts the `NO_SUCH_FILE` of a mistyped `--remote-path` back in front
            // of the catch below, which is the only thing that can name the path.
            //
            // Confidence: inferred, not measured. Milestone 5 made `start()` non-fatal and
            // nothing noticed that it had taken this failure away from `add`; before this
            // line, `add --remote-path /srv/typo` answered "No row for
            // NSFileProviderRootContainerItemIdentifier." (Q7, 2026-09-08).
            try await runtime.applyConnection()
            let root = try await runtime.rootDescription()
            let items = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            try await AgentCommandContext.manager.addDomain(for: created)

            var report: [String: Any] = [
                "id": created.id,
                "name": created.displayName,
                "host": created.host,
                "user": created.user ?? attribution.resolved.user ?? "",
                "port": created.port ?? attribution.resolved.port ?? 22,
                "remotePath": root,
                "entries": items.items.count,
                "agentDependent": created.agentDependent,
                "secrets": created.secrets.compactMap { SecretKey(account: $0)?.report },
                "mount": "~/Library/CloudStorage/SSHDrive-\(created.displayName)",
                "resolution": display.lines.map(\.text),
                "jumpChain": display.jumpChain.map(\.host),
            ]
            let first = await firstDeploymentReport(
                location: created, runtime: runtime,
                detector: await AgentCommandContext.manager.detector(locationID: created.id),
                relay: relay)
            if let sentence = first.helperNotice { report["helperNotice"] = sentence }
            if let capability = first.capabilities { report["capabilities"] = capability }
            return try ControlCommands.json(report)
        } catch {
            // "`add` must fail cleanly … without leaving a half-added location."
            await AgentCommandContext.manager.dropRuntime(locationID: created.id)
            try? await AgentCommandContext.manager.removeDomain(for: created)
            try? await AgentCommandContext.manager.mutateConfiguration { file in
                file.locations.removeAll { $0.id == created.id }
            }
            if let url = try? GroupContainer.domainURL(locationID: created.id) {
                try? FileManager.default.removeItem(at: url)
            }
            // The wire carries status classes, not errno (section 6.2), so the one thing
            // `add` can usefully say about a `NO_SUCH_FILE` here is which path it was: at
            // this point authentication has already succeeded, so a missing root is a
            // typo in `--remote-path` and nothing else.
            if let sftp = error as? SFTPError, sftp == .noSuchFile {
                throw SSHDriveAgentError.noSuchItem.asNSError(
                    "The server has no \(created.remotePath ?? "home directory") for "
                        + "\(LocationCommands.destinationText(created)). Nothing was added.")
            }
            throw error
        }
    }

    /// Section 4.2: "`add` compares the CLI's own two values with the snapshot before
    /// connecting and, when they differ, prints both and says which the agent will use."
    static func environmentWarnings(
        arguments: [String: String], snapshot: LoginShellSnapshot
    ) -> [String] {
        var out: [String] = []
        let agentPath = snapshot.path ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        if let terminalPath = arguments["terminalPATH"], terminalPath != agentPath {
            out.append(
                "Your terminal's PATH differs from the login shell snapshot SSH Drive will "
                    + "use.\n  terminal: \(terminalPath)\n  SSH Drive: \(agentPath)")
        }
        let agentSocket = snapshot.sshAuthSock ?? ""
        let terminalSocket = arguments["terminalSSHAuthSock"] ?? ""
        if terminalSocket != agentSocket {
            out.append(
                "Your terminal's SSH_AUTH_SOCK differs from the one SSH Drive will use.\n"
                    + "  terminal: \(terminalSocket.isEmpty ? "(unset)" : terminalSocket)\n"
                    + "  SSH Drive: \(agentSocket.isEmpty ? "(unset)" : agentSocket)\n"
                    + "  A key reachable only through the terminal's agent passes `ssh` there "
                    + "and fails from SSH Drive.")
        }
        return out
    }

    // MARK: list

    private static func list() async throws -> Data {
        let file = try await AgentCommandContext.manager.configuration()
        let domains = (try? await AgentCommandContext.manager.existingDomainDescriptions()) ?? []
        var rows: [[String: Any]] = []
        for location in file.locations {
            let mounted = domains.contains { $0.hasSuffix("(\(location.id))") }
            rows.append([
                "id": location.id,
                "name": location.displayName,
                "destination": destinationText(location),
                "secrets": location.secrets.compactMap { SecretKey(account: $0)?.report },
                "mounted": mounted,
                "cacheTTL": location.cacheTTL.rawValue,
                "state": await stateWord(location),
                "backend": location.backend.rawValue,
            ])
        }
        return try ControlCommands.json(["macID": file.macID, "locations": rows])
    }

    static func destinationText(_ location: Location) -> String {
        var text = location.host
        if let user = location.user { text = "\(user)@\(text)" }
        if let port = location.port { text += ":\(port)" }
        return text
    }

    /// `mounted` / `online` / `offline` / `not mounted`, without connecting anything: a
    /// `list` that dialled every server would take a minute on a laptop in a train.
    ///
    /// **Answered from the gate, never from `ssh -O check`.** The gate is what holds a
    /// location's connection (section 6.3), so it already knows: `connected` is the whole
    /// of "online", and the breaker's own sentence - backing off, no network path,
    /// stopped until the user acts - is the whole of the reason. The other route,
    /// `runtime.isConnected()` -> `SSHBackedTransport.isMasterAlive()` ->
    /// `SSHMaster.check()`, spawns `ssh -O check` and waits up to 10 s for it with the
    /// master's actor held, which a report may not do: a `status` printed while Finder is
    /// listing would queue behind that actor along with everything else.
    static func stateWord(_ location: Location) async -> String {
        guard location.mounted else { return "not mounted" }
        guard await AgentCommandContext.manager.startedRuntime(locationID: location.id) != nil
        else { return "idle (not connected)" }
        guard let gate = await AgentCommandContext.manager.gate(locationID: location.id) else {
            // No gate is a `.fake` backend: there is no connection to be offline from.
            return "online"
        }
        if await gate.isConnected { return "online" }
        // Section 6.3: "offline" is not the whole answer. The breaker knows whether the
        // location is backing off, has no path at all, or has stopped until the user acts,
        // and section 4.2's stop is the one the user has to be told about.
        return "offline (\(await gate.stateSentence()))"
    }

    /// Section 8.1's "Server free space" for a location with no runtime up: whatever the
    /// last probe left in `capabilities.json`, with its age, or `unknown`.
    static func cachedFreeSpace(locationID: String) async -> String {
        guard let space = CapabilityCache.freeSpace(locationID: locationID) else {
            return ServerFreeSpace.unknownSentence
        }
        return space.sentence(now: AgentCommandContext.manager.environment.clock.now())
    }

    // MARK: show

    private static func show(_ arguments: [String: String]) async throws -> Data {
        let location = try await resolve(arguments)
        let environment = await AgentSSHEnvironment.shared.environment()
        let snapshot = await AgentSSHEnvironment.shared.current()
        let target = SSHProcess.target(for: location)

        var report: [String: Any] = [
            "id": location.id,
            "name": location.displayName,
            "destination": destinationText(location),
            "remotePath": location.remotePath ?? "(the account's home)",
            "backend": location.backend.rawValue,
            "cacheTTL": location.cacheTTL.rawValue,
            "permissions": location.permissions.rawValue,
            "watchMode": location.watchMode.rawValue,
            "helper": location.helper,
            "createCheck": location.createCheck.rawValue,
            "agentDependent": location.agentDependent,
            "sshOptions": location.sshOptions,
            // Section 8: "secrets present by kind but never their values."
            "secrets": location.secrets.compactMap { SecretKey(account: $0)?.report },
            "ssh": SSHProcess.sshVersion() ?? "cannot run \(SSHProcess.sshBinaryPath)",
            "sshBinary": SSHProcess.sshBinaryPath,
            "environment": snapshotReport(snapshot),
            // Section 6.1: whether the location runs with IdentityAgent=none or through
            // the key agent.
            "keyAgent": location.agentDependent
                ? "authenticates through the key agent only; the mount waits for it after login"
                : "IdentityAgent=none; no key agent is ever consulted for this location",
            "mount": "~/Library/CloudStorage/SSHDrive-\(location.displayName)",
        ]

        if location.backend == .sftp {
            do {
                let attribution = try SSHConfigResolver.attribution(
                    target: target, environment: environment)
                let display = SSHConfigDisplay.make(
                    attribution: attribution,
                    overrideKeywords: SSHConfigDisplay.overrideKeywords(for: target))
                report["resolution"] = display.lines.map(\.text)
                report["overridden"] = display.overridden.map(\.text)
                report["jumpChain"] = display.jumpChain.map { hop -> String in
                    var text = hop.host
                    if let user = hop.user { text = "\(user)@\(text)" }
                    if let port = hop.port { text += ":\(port)" }
                    return text
                }
                if let hand = display.handWrittenProxyCommand {
                    report["proxyCommandWarning"] =
                        "the resolved ProxyCommand runs ssh itself (\(hand)); that inner ssh "
                        + "escapes every option SSH Drive sets. Prefer ProxyJump."
                }
                // The ProxyCommand the agent actually builds, so `show` can be diffed
                // against `ps` when a chain misbehaves.
                if let proxy = ProxyChainBuilder.proxyCommand(
                    for: (try? attribution.resolved.jumpChain()) ?? [],
                    identityAgentNone: target.identityAgentNone)
                {
                    report["proxyCommand"] = proxy
                }
            } catch {
                report["resolutionError"] = error.localizedDescription
            }
        }

        let domains = (try? await AgentCommandContext.manager.existingDomainDescriptions()) ?? []
        report["domain"] = domains.contains { $0.hasSuffix("(\(location.id))") }
            ? "registered" : "not registered"
        report["state"] = await stateWord(location)

        if let gate = await AgentCommandContext.manager.gate(locationID: location.id) {
            report["connection"] = await gate.report(includeCounters: false)
        }
        if let runtime = await AgentCommandContext.manager.startedRuntime(locationID: location.id) {
            report["lastError"] = await runtime.lastErrorText() ?? "none"
            report["channels"] = await runtime.channelReport()
            if let capability = try? await capabilityReport(
                location: location, runtime: runtime, forceProbe: false,
                detector: await AgentCommandContext.manager.detector(locationID: location.id))
            {
                report["capabilities"] = capability.asJSON
            }
            report["notShown"] = (try? await runtime.notShown())?.map {
                ["path": $0.path, "reason": $0.reason]
            } ?? []
        } else if let cached = CapabilityCache.probe(locationID: location.id) {
            let budget = CapabilityCache.channelBudget(locationID: location.id) ?? .unrestricted
            report["capabilities"] = CapabilityReport.make(
                probe: cached.probe, extensions: cached.extensions, location: location,
                allowsExecChannel: budget.allowsExecChannel, probedAt: cached.probedAt,
                cached: true, freeSpace: await cachedFreeSpace(locationID: location.id),
                helper: helperState(location: location, cached: cached.probe)).asJSON
        }
        return try ControlCommands.json(report)
    }

    static func snapshotReport(_ snapshot: LoginShellSnapshot) -> String {
        guard snapshot.succeeded else {
            return "login shell snapshot failed (\(snapshot.diagnostic ?? "no diagnostic")); "
                + "using launchd's PATH and SSH_AUTH_SOCK"
        }
        var text = "PATH and SSH_AUTH_SOCK from \(snapshot.shell)"
        text += "; PATH \(snapshot.path ?? "(launchd's)")"
        text += snapshot.sshAuthSock.map { ", SSH_AUTH_SOCK \($0)" } ?? ", no SSH_AUTH_SOCK"
        if snapshot.interactiveOnly {
            text += "; read with -ic, so a PATH set only in .login is missed"
        }
        return text
    }

    // MARK: remove

    private static func remove(_ arguments: [String: String]) async throws -> Data {
        let file = try await AgentCommandContext.manager.configuration()
        let targets: [Location]
        if arguments["all"] == "true" {
            targets = file.locations
        } else {
            targets = [try await resolve(arguments)]
        }
        guard !targets.isEmpty else {
            return try ControlCommands.json(["removed": [String](), "secretsRemoved": [String]()])
        }

        var removed: [String] = []
        var secretsRemoved: [String] = []
        var helperRemoved: [String] = []
        for location in targets {
            // Section 8: "refuses while uploads are pending unless --force".
            if arguments["force"] != "true",
                let runtime = await AgentCommandContext.manager.startedRuntime(locationID: location.id),
                await runtime.pendingUploadCount() > 0
            {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "\(location.displayName) has uploads in flight. Wait, or pass --force.")
            }
            // Section 8: "on its last connection removes the helper binary and its
            // directory from the server when no other location of this Mac on the same
            // user@hostname:port uses them". The stream has to stop before the file goes,
            // and both need the connection that is about to be dropped.
            // Everything this command is about to remove counts as gone, or `remove --all`
            // over two locations on one host would leave the binary behind for a sibling
            // that is being removed in the same breath.
            let targetIDs = Set(targets.map(\.id))
            let remainingAfter = file.locations.filter {
                !targetIDs.contains($0.id) && HelperCleanup.sharesHelperDirectory($0, with: location)
            }
            if remainingAfter.isEmpty,
                let detector = await AgentCommandContext.manager.detector(locationID: location.id)
            {
                helperRemoved += await detector.shutDownHelper(removeFromServer: true)
            }
            try? await AgentCommandContext.manager.removeDomain(for: location)
            await AgentCommandContext.manager.dropRuntime(locationID: location.id)
            try await AgentCommandContext.manager.mutateConfiguration { config in
                config.locations.removeAll { $0.id == location.id }
            }
            if arguments["keepFiles"] != "true",
                let url = try? GroupContainer.domainURL(locationID: location.id)
            {
                try? FileManager.default.removeItem(at: url)
            }
            removed.append(location.displayName)

            // "each keychain item the location names that no remaining location also names
            // (section 4.2 keys items by user@hostname:port, so two locations on one host
            // share one)" (section 8).
            let remaining = try await AgentCommandContext.manager.configuration().locations
            for account in location.secrets {
                guard !remaining.contains(where: { $0.secrets.contains(account) }) else { continue }
                guard let key = SecretKey(account: account) else { continue }
                do {
                    try AgentCommandContext.manager.secrets.store.removeSecret(for: key)
                    secretsRemoved.append(account)
                } catch {
                    Log.agent.error(
                        "could not remove keychain item \(account, privacy: .public): \(error, privacy: .public)"
                    )
                }
            }
        }
        return try ControlCommands.json([
            "removed": removed,
            "secretsRemoved": secretsRemoved,
            "keepFiles": arguments["keepFiles"] == "true",
            "helperRemoved": helperRemoved,
        ])
    }

    // MARK: set

    private static func set(_ arguments: [String: String], relay: (any TerminalRelaying)?) async throws -> Data {
        let location = try await resolve(arguments)
        guard let keyText = arguments["key"], let value = arguments["value"] else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "set needs a key and a value: sshdrive set <name> <\(LocationSettingKey.allNames)> <value>")
        }

        // `set <name> option add|remove <SSHOPTION>` is its own shape (section 8).
        if keyText == "option" {
            return try await setOption(location: location, arguments: arguments)
        }

        let key = try LocationSettingKey.named(keyText)
        var updated = location
        try key.apply(value, to: &updated)
        guard updated != location else {
            return try ControlCommands.json([
                "name": location.displayName, "key": key.rawValue, "value": value,
                "changed": false,
            ])
        }

        var notes: [String] = []
        if key.recreatesDomain {
            // Section 8: a new root invalidates every path in the index, so the domain goes
            // and comes back and the cache with it.
            if arguments["force"] != "true",
                let runtime = await AgentCommandContext.manager.startedRuntime(locationID: location.id),
                await runtime.pendingUploadCount() > 0
            {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "\(location.displayName) has uploads in flight; \(key.rawValue) re-creates "
                        + "the domain. Wait, or pass --force.")
            }
            notes.append(
                "\(key.rawValue) re-creates the File Provider domain, so the local cache is "
                    + "dropped and every file is downloaded again on demand.")
        }
        if key.renamesDomainInPlace {
            // S9 (2026-09-05): `add(domain)` with the identifier the system already holds
            // and a new displayName renames the domain in place. The mount directory under
            // ~/Library/CloudStorage is renamed, nothing is re-fetched, and an upload the
            // system was holding is still pending and still flushes afterwards. So this is
            // not refused while uploads are pending and drops no cache; the one thing it
            // does is move the folder, which anything holding a path to it will notice.
            notes.append(
                "the Finder sidebar entry and the folder under ~/Library/CloudStorage are "
                    + "renamed in place; cached files and pending uploads are kept.")
        }

        if key.requiresCollectConnection {
            // "host, user, port and identity change what the stored secrets are keyed on
            // or which key is offered, so they re-run the collect connection exactly as
            // passwd does before the change is saved" (section 8).
            notes.append("\(key.rawValue) changes what the stored secrets are keyed on; "
                + "checking the connection before saving.")
            relay?.note(notes.last!)
            let outcome = try await recollect(for: updated, relay: relay)
            guard outcome.authenticated else {
                throw SSHDriveAgentError.notAuthenticated.asNSError(
                    outcome.failure?.message(identityHint: nil)
                        ?? "Could not authenticate with the new setting; nothing was changed.")
            }
            updated.agentDependent = outcome.agentDependent
            updated.secrets = Array(Set(updated.secrets + outcome.storedKeys)).sorted()
        }

        // `helper off` "stops it and removes the binary on the next connection" (section
        // 6.4). The connection is still up right now, so it happens now.
        if key == .helper, !updated.helper,
            let detector = await AgentCommandContext.manager.detector(locationID: location.id)
        {
            let taken = await detector.shutDownHelper(removeFromServer: true)
            if !taken.isEmpty {
                notes.append("removed \(taken.count) helper file(s) from the server.")
            }
        }

        let wasMounted = location.mounted
        await AgentCommandContext.manager.dropRuntime(locationID: location.id)
        if key.recreatesDomain || key.requiresCollectConnection {
            // Deliberately not `renamesDomainInPlace`: removing the domain first is exactly
            // what would throw the cache and the pending uploads away, and S9 says the
            // system does not need it (2026-09-05).
            try? await AgentCommandContext.manager.removeDomain(for: location)
        }
        if key.dropsIndex, let url = try? GroupContainer.domainURL(locationID: location.id) {
            // "a new root invalidates every path in the index" (section 8).
            try? FileManager.default.removeItem(at: url)
        }
        let saved = updated
        try await AgentCommandContext.manager.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        // Section 7: the eviction loop reads the TTL on every pass, and a mounted location
        // gets a fresh evictor from `runtime(for:)` below; this covers the unmounted case
        // and makes the intent explicit rather than incidental.
        if key == .cacheTTL {
            await AgentCommandContext.manager.applyCacheTTL(locationID: saved.id, ttl: saved.cacheTTL)
        }
        if wasMounted {
            let runtime = try await AgentCommandContext.manager.runtime(for: saved)
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            try await AgentCommandContext.manager.addDomain(for: saved)
        }
        return try ControlCommands.json([
            "name": saved.displayName, "key": key.rawValue, "value": value, "changed": true,
            "notes": notes,
        ])
    }

    private static func setOption(location: Location, arguments: [String: String]) async throws
        -> Data
    {
        guard let operation = arguments["value"], let option = arguments["option"] else {
            throw SSHDriveAgentError.notImplemented.asNSError(
                "sshdrive set <name> option add|remove <SSHOPTION>")
        }
        var updated = location
        switch operation {
        case "add":
            if !updated.sshOptions.contains(option) { updated.sshOptions += ["-o", option] }
        case "remove":
            updated.sshOptions = SSHCommandBuilder.removingOption(option, from: updated.sshOptions)
        default:
            throw SSHDriveAgentError.notImplemented.asNSError("option takes add or remove.")
        }
        let saved = updated
        try await AgentCommandContext.manager.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        await AgentCommandContext.manager.dropRuntime(locationID: saved.id)
        return try ControlCommands.json([
            "name": saved.displayName, "sshOptions": saved.sshOptions,
        ])
    }

    /// The collect connection again, for `set host|user|port|identity` (and, when it
    /// arrives, `passwd`). Same flow, same relay, same storage rules (section 4.2).
    private static func recollect(for location: Location, relay: (any TerminalRelaying)?) async throws
        -> (authenticated: Bool, agentDependent: Bool, failure: AddFlow.Failure?, storedKeys: [String])
    {
        let environment = await AgentSSHEnvironment.shared.environment()
        let target = SSHProcess.target(for: location)
        let attribution = try SSHConfigResolver.attribution(
            target: target, environment: environment)
        let collector = CollectConnection(
            request: CollectConnection.Request(
                locationID: location.id, target: target, environment: environment,
                askpassPath: AgentCommandContext.manager.secrets.askpassPath, resolution: attribution.resolved,
                identityFiles: attribution.resolved.identityFiles),
            broker: AgentCommandContext.manager.secrets.broker, relay: relay)
        let outcome = await AddFlow.run(
            note: { [weak relay] in relay?.note($0) }, runner: collector)
        CapabilityCache.storeServerVersion(
            collector.remoteSoftwareVersion, locationID: location.id)
        return (
            outcome.authenticated, outcome.agentDependent, outcome.failure,
            collector.committedKeys
        )
    }

    // MARK: mount / unmount

    private static func mount(_ arguments: [String: String]) async throws -> Data {
        let location = try await resolve(arguments)
        var updated = location
        updated.mounted = true
        let saved = updated
        try await AgentCommandContext.manager.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        let runtime = try await AgentCommandContext.manager.runtime(for: saved)
        _ = try await runtime.enumerateItems(container: IndexWriter.rootIdentifier, pageToken: nil)
        try await AgentCommandContext.manager.addDomain(for: saved)
        return try ControlCommands.json([
            "mounted": saved.displayName,
            "mount": "~/Library/CloudStorage/SSHDrive-\(saved.displayName)",
        ])
    }

    private static func unmount(_ arguments: [String: String]) async throws -> Data {
        let location = try await resolve(arguments)
        try await AgentCommandContext.manager.removeDomain(for: location)
        await AgentCommandContext.manager.dropRuntime(locationID: location.id)
        var updated = location
        updated.mounted = false
        let saved = updated
        try await AgentCommandContext.manager.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        return try ControlCommands.json(["unmounted": saved.displayName])
    }

    // MARK: status

    /// `sshdrive status [<name>]` (sections 8, 8.1).
    ///
    /// **Nothing here waits on the location's writer for anything it can read for
    /// itself.** A row is about eighteen facts - the hidden names, the held rows, the
    /// root set, one `item(identifier:)` per materialized file, the pin tree, the channel
    /// budget, the identity, the scheduler, the last error, the free space - and
    /// `LocationRuntime` is an actor whose index writes a directory listing in one
    /// synchronous SQLite transaction (section 5.3), so a hop onto it for any of them
    /// waits for a listing of a large folder to finish. So:
    ///
    /// - everything that is in the index is read through `runtime.statusIndex`, the
    ///   read-only WAL reader section 5.2 gives this database, off the writer entirely;
    /// - everything else the runtime knows is taken in **one** entry, `statusFacts()`;
    /// - the materialized set comes from the snapshot section 6.5's cycle and section 7's
    ///   pass already publish, and is drained only when there is none that is fresh;
    /// - with no `<name>` the locations run concurrently, printed back in the order
    ///   `config.json` holds them;
    /// - and each location's section is bounded by `Deadline.statusSeconds`, so one
    ///   location that has stopped answering costs its own row a note and not the report.
    private static func status(_ arguments: [String: String]) async throws -> Data {
        let manager = AgentCommandContext.manager
        let file = try await manager.configuration()
        let wanted: [Location]
        if let name = arguments["name"], !name.isEmpty {
            wanted = [try await manager.location(named: name)]
        } else {
            wanted = file.locations
        }
        let forceProbe = arguments["probe"] == "true"
        let domains = (try? await manager.existingDomainDescriptions()) ?? []

        var built = [StatusRow?](repeating: nil, count: wanted.count)
        if wanted.count <= 1 {
            for (index, location) in wanted.enumerated() {
                built[index] = await statusRow(
                    location: location,
                    mounted: domains.contains { $0.hasSuffix("(\(location.id))") },
                    forceProbe: forceProbe)
            }
        } else {
            // The sections are independent - separate runtimes, separate indexes, separate
            // gates - and one location backing off should not add its wait to the next
            // one's. The order is put back below, because section 8's output is the order
            // `config.json` holds.
            await withTaskGroup(of: (Int, StatusRow).self) { group in
                for (index, location) in wanted.enumerated() {
                    let mounted = domains.contains { $0.hasSuffix("(\(location.id))") }
                    group.addTask {
                        (
                            index,
                            await statusRow(
                                location: location, mounted: mounted, forceProbe: forceProbe)
                        )
                    }
                }
                for await (index, row) in group { built[index] = row }
            }
        }
        return try ControlCommands.json(["locations": built.compactMap { $0?.fields }])
    }

    /// One row's worth of `[String: Any]`, as something a `Task` may carry.
    ///
    /// A class rather than a dictionary because `Deadline.run` and `withTaskGroup` want a
    /// `Sendable` result and `[String: Any]` is not one; the fields are only ever touched
    /// by the one task building this row, and then read after it has finished.
    final class StatusRow: @unchecked Sendable {
        var fields: [String: Any]
        init(_ fields: [String: Any]) { self.fields = fields }
    }

    /// The part of a row that costs nothing, then everything else under one deadline.
    private static func statusRow(
        location: Location, mounted: Bool, forceProbe: Bool
    ) async -> StatusRow {
        let row = StatusRow([
            "id": location.id,
            "name": location.displayName,
            "destination": destinationText(location),
            "mounted": mounted,
            "cacheTTL": location.cacheTTL.rawValue,
            "permissions": location.permissions.rawValue,
            "watchMode": location.watchMode.rawValue,
            "identity": location.agentDependent ? "key agent" : "IdentityAgent=none",
            "secrets": location.secrets.compactMap { SecretKey(account: $0)?.report },
        ])
        let clock = AgentCommandContext.manager.environment.clock
        do {
            try await Deadline.run(
                "the \(location.displayName) section of status",
                seconds: Deadline.statusSeconds, clock: clock
            ) {
                await fillStatusRow(row, location: location, mounted: mounted, forceProbe: forceProbe)
            }
        } catch let expired as Deadline.Expired {
            // Section 8's row still prints. What it cannot say, it says it cannot say:
            // a report about the other locations is worth having, and the CLI's own 120 s
            // timeout would otherwise take the whole command with this one location.
            row.fields["note"] = expired.shortDescription
            if row.fields["state"] == nil { row.fields["state"] = "not answering" }
        } catch {
            row.fields["note"] = error.localizedDescription
        }
        return row
    }

    private static func fillStatusRow(
        _ row: StatusRow, location: Location, mounted: Bool, forceProbe: Bool
    ) async {
        let manager = AgentCommandContext.manager
        row.fields["state"] = await stateWord(location)

        // The location must be up for a live probe; a `status` that dialled a server the
        // user has not touched would be a surprise, so only `--probe` connects.
        var runtime = await manager.startedRuntime(locationID: location.id)
        if runtime == nil, forceProbe, location.mounted {
            runtime = try? await manager.runtime(for: location)
        }
        let detector = await manager.detector(locationID: location.id)

        guard let runtime else {
            if let cached = CapabilityCache.probe(locationID: location.id) {
                let budget = CapabilityCache.channelBudget(locationID: location.id) ?? .unrestricted
                row.fields["capabilities"] = CapabilityReport.make(
                    probe: cached.probe, extensions: cached.extensions, location: location,
                    allowsExecChannel: budget.allowsExecChannel, probedAt: cached.probedAt,
                    cached: true,
                    freeSpace: await cachedFreeSpace(locationID: location.id),
                    advertisedExtensions: CapabilityCache.advertisedExtensions(
                        locationID: location.id),
                    helper: helperState(location: location, cached: cached.probe),
                    software: CapabilityCache.software(locationID: location.id)).asJSON
                row.fields["channels"] = budget.asJSON
            }
            if let detector { row.fields["watch"] = await detector.status() }
            return
        }

        // One entry on the writer's actor, for the things only it holds. Everything below
        // this line is either off it or out of the index's read-only reader.
        let facts = await runtime.statusFacts()
        row.fields["channels"] = facts.channels
        if let identity = facts.identity { row.fields["identityProbe"] = identity }
        row.fields["transfers"] = facts.transfers
        row.fields["lastError"] = facts.lastError ?? "none"
        if let capability = try? await capabilityReport(
            location: location, runtime: runtime, forceProbe: forceProbe, detector: detector,
            facts: forceProbe ? nil : facts)
        {
            row.fields["capabilities"] = capability.asJSON
        }

        // Section 8.1's Cache and Pins lines need the system's own materialized set. It is
        // published by section 6.4's cycle, section 7's pass and the extension's
        // `materializedItemsDidChange`, and every *change* to it arrives as the last of
        // those - so a fresh entry is the current set, and `status` walks the replica only
        // when there is none.
        var materialized: [String]?
        if mounted {
            let now = manager.environment.clock.now()
            if let fresh = runtime.materialized.fresh(at: now) {
                materialized = fresh
            } else {
                materialized = await manager.environment.replica.materializedIdentifiers(
                    locationID: location.id)
                runtime.materialized.record(materialized, at: now)
            }
            materialized = materialized ?? []
        }

        // Everything the index can answer, from the read-only reader (section 5.2).
        let index = await runtime.statusIndex.report(
            hiddenReasons: facts.hiddenReasons, materialized: materialized)
        row.fields["notShown"] = index.notShown
        row.fields["heldDeletions"] = index.held
        if let unavailable = index.unavailable {
            // Section 5.3's rebuild, or a location that has never started. The row says so
            // rather than printing zeroes that read as facts about the server.
            row.fields["indexUnavailable"] = unavailable
        }

        // Section 6.4: the tier in use, the cadence, the last sweep and where the location
        // sits on the fallback ladder. The detector is the authority where there is one,
        // which is why it is merged over the index's stored answer and not under it.
        var watch = index.watch
        if !facts.lastWatchCycle.isEmpty { watch["lastCycle"] = facts.lastWatchCycle }
        if let detector {
            watch.merge(await detector.status()) { _, live in live }
        }
        row.fields["watch"] = watch

        if mounted, index.unavailable == nil {
            let totals = EvictionPlan.totals(index.cacheCandidates)
            var cache: [String: Any] = [
                "files": totals.files,
                "bytes": totals.bytes,
                "keptFiles": totals.keptFiles,
                "keptBytes": totals.keptBytes,
                "ttl": location.cacheTTL.rawValue,
                "keptEvictedOutside": facts.keptEvictedOutside,
            ]
            if let evictor = await manager.evictor(locationID: location.id) {
                cache["nextPassInSeconds"] = max(
                    0, await evictor.nextRunAt() - Date().timeIntervalSince1970)
                let pass = await evictor.lastPass
                if !pass.isEmpty { cache["lastPass"] = pass }
            }
            row.fields["cache"] = cache
            row.fields["pins"] = index.pins
        }

        // Section 4.3: a changed host key needs no command of ours; `status` prints the
        // `ssh-keygen -R` line to run.
        if let text = hostKeyAdvice(location, lastError: facts.lastError) {
            row.fields["hostKeyAdvice"] = text
        }
    }

    /// Section 6.4: "Since it does place our code on the remote machine, `sshdrive add`
    /// states this plainly in its output, after the probe has chosen the directory so the
    /// message names the real one."
    ///
    /// Nil where no helper will be deployed - no shell, no directory, an unsupported
    /// platform, a build with no binaries - because a promise about a binary that is never
    /// uploaded is worse than silence.
    static func helperNotice(runtime: LocationRuntime, location: Location) async -> String? {
        guard location.helper else { return nil }
        let capabilities = await DomainManager.capabilities(of: runtime, location: location)
        guard capabilities.helperAvailable else { return nil }
        guard let probe = await runtime.probeForSweep(), !probe.cacheDirectory.isEmpty else {
            return nil
        }
        return "SSH Drive will upload a small helper binary to \(probe.cacheDirectory) on this "
            + "server to watch for changes; disable with "
            + "`sshdrive set \(location.displayName) helper off`"
    }

    /// The tail of `add`: the upload sentence, the bounded wait for the first deployment,
    /// and then the one capability report `add` prints (`P9`, `N1`).
    ///
    /// It is one function rather than three statements inside `add` because the **order**
    /// is the rule and the wait is the bound. Section 6.4's notice is printed first - it
    /// describes what is about to happen and names the directory the probe chose - and the
    /// report comes after `settleHelper`, which is bounded by `HelperSettle.addSeconds` so
    /// a server that never answers costs `add` a few seconds and nothing more. Without the
    /// wait the report described a sweep and blamed the server for it, ten seconds before
    /// `sshdrive status` said `helper 0.1.0` (2026-09-05; `SQ-077`).
    ///
    /// Confidence: the ordering and the bound are ours and are measured here. That a
    /// deployment can hang rather than refuse is inferred from `SQ-077` - the stream dies
    /// with its connection - and is why the wait may not be unbounded.
    @discardableResult
    public static func firstDeploymentReport(
        location: Location, runtime: LocationRuntime, detector: ChangeDetector?,
        relay: (any TerminalRelaying)?
    ) async -> (helperNotice: String?, capabilities: [String: Any]?) {
        // Section 6.4: `add` "states this plainly in its output, after the probe has
        // chosen the directory so the message names the real one". It is said before the
        // upload happens, and before the report that describes its result.
        let notice = await helperNotice(runtime: runtime, location: location)
        if let notice { relay?.note(notice) }
        // The helper is deployed by the first change-detection cycle, which starts with
        // the location. `add` prints one capability report and the user reads it as the
        // truth about this server, so it waits - bounded - for that first attempt to
        // settle (2026-09-05, sections 8, 8.1 and 6.4).
        if let detector { await detector.settleHelper() }
        // The report itself is not relayed: it goes back in the reply and the CLI renders
        // it (section 8.1's `--json` is the same data). What the terminal is told here is
        // only what it could not work out for itself, and it is told before the wait.
        let capabilities = try? await capabilityReport(
            location: location, runtime: runtime, forceProbe: false, detector: detector)
        return (notice, capabilities?.asJSON)
    }

    /// Section 8.1's report for a live location, re-probing when asked.
    ///
    /// - Parameter detector: the location's change-detection ladder, which is the
    ///   authority on the running tier and on where tier 2 has got to. Passed in rather
    ///   than looked up so `add`'s report and `status`'s report are built by the same
    ///   code from the same source, and so a scenario can hand it one (`N1`, `P9`).
    /// - Parameter facts: what `status` already took from the runtime in its one entry
    ///   (`statusFacts()`). Passing them is what keeps the report from making three more
    ///   hops onto an actor a directory listing may be holding (section 8);
    ///   `add` and `--probe` pass nil, because `--probe` has just moved all three.
    public static func capabilityReport(
        location: Location, runtime: LocationRuntime, forceProbe: Bool,
        detector: ChangeDetector?, facts: LocationRuntime.StatusFacts? = nil
    ) async throws -> CapabilityReport {
        if forceProbe { await runtime.reprobeServer() }
        // The three values `status` already took in its one entry on the runtime; `add`
        // and `--probe` hand in nothing, so they are read here.
        let probe: (probe: ServerProbe.Result, extensions: SFTPServerExtensions)?
        if let facts { probe = facts.probe } else { probe = await runtime.serverProbe() }
        let allowsExecChannel: Bool
        if let facts {
            allowsExecChannel = facts.channelBudget.allowsExecChannel
        } else {
            allowsExecChannel = await runtime.channelBudgetValue().allowsExecChannel
        }
        let freeSpaceSentence: String
        if let facts {
            freeSpaceSentence = facts.freeSpace
        } else {
            freeSpaceSentence = await runtime.freeSpaceDescription()
        }
        guard let live = probe else {
            guard let cached = CapabilityCache.probe(locationID: location.id) else {
                throw SSHDriveAgentError.notImplemented.asNSError("no probe for this location")
            }
            return CapabilityReport.make(
                probe: cached.probe, extensions: cached.extensions, location: location,
                allowsExecChannel: allowsExecChannel,
                probedAt: cached.probedAt, cached: true,
                freeSpace: freeSpaceSentence,
                advertisedExtensions: CapabilityCache.advertisedExtensions(
                    locationID: location.id),
                helper: helperState(location: location, cached: cached.probe),
                software: CapabilityCache.software(locationID: location.id))
        }
        // Read from `capabilities.json`, never from the wire: `--probe` has already
        // refreshed it above if that is what this call is, and `status` on its own may
        // not dial (section 8.1).
        let freeSpace = freeSpaceSentence
        // Section 8.1: the tier the ladder is actually running, and where tier 2 has got
        // to (section 6.4).
        let status = await detector?.status()
        return CapabilityReport.make(
            probe: live.probe, extensions: live.extensions, location: location,
            allowsExecChannel: allowsExecChannel,
            probedAt: CapabilityCache.probe(locationID: location.id)?.probedAt ?? Date(),
            cached: false, freeSpace: freeSpace,
            advertisedExtensions: CapabilityCache.advertisedExtensions(locationID: location.id),
            activeTier: status?["tier"] as? String,
            helper: await liveHelperState(location: location, runtime: runtime, status: status),
            software: CapabilityCache.software(locationID: location.id))
    }

    /// Where tier 2 has got to, for a location that is up.
    ///
    /// Only a *running* stream describes the change-detection and rename lines as the
    /// helper's: the ladder offers the tier from the probe before anything is deployed,
    /// and a report taken in that window used to print the sweep branch's "the server
    /// cannot run the remote helper" - which was false for every server that could, and
    /// was what `add` printed on the first real install (2026-09-05).
    private static func liveHelperState(
        location: Location, runtime: LocationRuntime, status: [String: Any]?
    ) async -> HelperState {
        guard location.helper else { return .off }
        if let helper = status?["helper"] as? [String: Any] {
            if helper["state"] as? String == "running" {
                return .running(
                    version: helper["version"] as? String ?? "?",
                    directory: helper["directory"] as? String ?? "?",
                    mechanism: helper["mechanism"] as? String ?? "inotify")
            }
            if let reason = helper["reason"] as? String, !reason.isEmpty {
                return .unavailable(reason)
            }
        }
        if let downgrades = status?["downgrades"] as? [[String: Any]], let last = downgrades.last {
            return .unavailable(
                "dropped from \(last["from"] as? String ?? "") to "
                    + "\(last["to"] as? String ?? "") at "
                    + "\(Date(timeIntervalSince1970: last["at"] as? Double ?? 0)): "
                    + "\(last["reason"] as? String ?? "")")
        }
        // The tier is offered and nothing has refused it yet: the binary is on its way up.
        if status?["tier"] as? String == "helper" { return .deploying }
        let capabilities = await DomainManager.capabilities(of: runtime, location: location)
        if capabilities.helperAvailable { return .deploying }
        return .unavailable(
            capabilities.helperBlockReason ?? "the server cannot run the remote helper")
    }

    /// The same for a location that is not up: what the cached probe of section 8.1 can
    /// honestly say. A server that could run it is never reported as one that cannot.
    private static func helperState(location: Location, cached: ServerProbe.Result) -> HelperState {
        guard location.helper else { return .off }
        guard cached.hasShellAccess else {
            return .unavailable(cached.failure)
        }
        guard !cached.cacheDirectory.isEmpty else {
            return .unavailable(
                cached.cacheNote.isEmpty ? "no writable directory for helper" : cached.cacheNote)
        }
        return .unavailable("not connected; the helper starts on the next connection")
    }

    /// "A host-key change needs no command of ours: `status` prints the `ssh-keygen -R`
    /// line to run" (section 8, section 4.3).
    ///
    /// Takes the sentence `status` already read rather than going back to the runtime for
    /// it: `lastErrorText()` reaches `SSHMaster` for the master's own stderr, and one
    /// report has no reason to make that hop twice.
    private static func hostKeyAdvice(_ location: Location, lastError: String?) -> String? {
        guard let error = lastError,
            error.lowercased().contains("host key")
                || error.lowercased().contains("remote host identification has changed")
        else { return nil }
        var host = location.host
        if let port = location.port { host = "[\(host)]:\(port)" }
        return "ssh-keygen -R \(host)    # then: sshdrive test \(location.displayName)"
    }

    private static func resolve(_ arguments: [String: String]) async throws -> Location {
        guard let name = arguments["name"] else {
            throw SSHDriveAgentError.unknownDomain.asNSError("This command needs a location name.")
        }
        return try await AgentCommandContext.manager.location(named: name)
    }
}
