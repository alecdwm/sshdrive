import Foundation
import FileProvider
import AgentCore
import Config
import Index
import SFTP
import Secrets
import SSHProcess
import XPCProtocols
import Logging

/// `add`, `list`, `show`, `remove`, `set`, `mount`, `unmount` and `status`: the user-facing
/// half of DESIGN.md section 8, with section 8.1's capability report.
///
/// Everything here runs in the agent, because the CLI is a pure XPC client and "even `add`
/// and `passwd` connect from the agent" (section 3, section 4.2). The CLI's only jobs are
/// to parse the flags and to be the terminal the collect connection's prompts are relayed
/// to.
enum LocationCommands {

    static func run(
        command: String, arguments: [String: String], relay: CLIRelay?
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
    private static func add(_ arguments: [String: String], relay: CLIRelay?) async throws -> Data {
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

        let existing = try await DomainManager.shared.configuration().locations
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
            askpassPath: AgentSecrets.askpassPath,
            resolution: attribution.resolved,
            identityFiles: identityFiles)
        let collector = CollectConnection(
            request: request, broker: AgentSecrets.broker, relay: relay)

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
        try await DomainManager.shared.mutateConfiguration { file in
            file.locations.removeAll { $0.id == created.id }
            file.locations.append(created)
        }

        do {
            relay?.note("Connecting for real, from the stored answers.")
            // The location's own master, with `StrictHostKeyChecking=yes`, no relay and no
            // terminal: exactly the connection every later reconnect makes. If this works,
            // section 4.2's promise that "a location that passes `add` works from the
            // agent" has been demonstrated rather than asserted.
            let runtime = try await DomainManager.shared.runtime(for: created)
            let root = try await runtime.rootDescription()
            let items = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            try await DomainManager.shared.addDomain(for: created)

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
            if let capability = try? await capabilityReport(
                location: created, runtime: runtime, forceProbe: false)
            {
                report["capabilities"] = capability.asJSON
            }
            return try ControlCommands.json(report)
        } catch {
            // "`add` must fail cleanly … without leaving a half-added location."
            await DomainManager.shared.dropRuntime(locationID: created.id)
            try? await DomainManager.shared.removeDomain(for: created)
            try? await DomainManager.shared.mutateConfiguration { file in
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
        let file = try await DomainManager.shared.configuration()
        let domains = (try? await DomainManager.existingDomainDescriptions()) ?? []
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
    static func stateWord(_ location: Location) async -> String {
        guard location.mounted else { return "not mounted" }
        guard let runtime = await DomainManager.shared.startedRuntime(locationID: location.id)
        else { return "idle (not connected)" }
        return await runtime.isConnected() ? "online" : "offline"
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

        let domains = (try? await DomainManager.existingDomainDescriptions()) ?? []
        report["domain"] = domains.contains { $0.hasSuffix("(\(location.id))") }
            ? "registered" : "not registered"
        report["state"] = await stateWord(location)

        if let runtime = await DomainManager.shared.startedRuntime(locationID: location.id) {
            report["lastError"] = await runtime.lastErrorText() ?? "none"
            report["channels"] = await runtime.channelReport()
            if let capability = try? await capabilityReport(
                location: location, runtime: runtime, forceProbe: false)
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
                budget: budget, probedAt: cached.probedAt, cached: true).asJSON
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
        let file = try await DomainManager.shared.configuration()
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
        for location in targets {
            // Section 8: "refuses while uploads are pending unless --force".
            if arguments["force"] != "true",
                let runtime = await DomainManager.shared.startedRuntime(locationID: location.id),
                await runtime.pendingUploadCount() > 0
            {
                throw SSHDriveAgentError.notImplemented.asNSError(
                    "\(location.displayName) has uploads in flight. Wait, or pass --force.")
            }
            try? await DomainManager.shared.removeDomain(for: location)
            await DomainManager.shared.dropRuntime(locationID: location.id)
            try await DomainManager.shared.mutateConfiguration { config in
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
            let remaining = try await DomainManager.shared.configuration().locations
            for account in location.secrets {
                guard !remaining.contains(where: { $0.secrets.contains(account) }) else { continue }
                guard let key = SecretKey(account: account) else { continue }
                do {
                    try AgentSecrets.store.removeSecret(for: key)
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
            // The helper's own removal is section 6.4 tier 2, milestone 9; there is
            // nothing on the server for milestone 3 to take away.
            "helperRemoved": false,
        ])
    }

    // MARK: set

    private static func set(_ arguments: [String: String], relay: CLIRelay?) async throws -> Data {
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
            // Section 8, and section 13's caveat: the sidebar name is fixed at domain
            // creation unless S9 says otherwise, and S9 has not been answered, so the
            // documented behaviour is what runs - the domain is removed and re-added.
            if arguments["force"] != "true",
                let runtime = await DomainManager.shared.startedRuntime(locationID: location.id),
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

        let wasMounted = location.mounted
        await DomainManager.shared.dropRuntime(locationID: location.id)
        if key.recreatesDomain || key.requiresCollectConnection {
            try? await DomainManager.shared.removeDomain(for: location)
        }
        if key.dropsIndex, let url = try? GroupContainer.domainURL(locationID: location.id) {
            // "a new root invalidates every path in the index" (section 8).
            try? FileManager.default.removeItem(at: url)
        }
        let saved = updated
        try await DomainManager.shared.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        if wasMounted {
            let runtime = try await DomainManager.shared.runtime(for: saved)
            _ = try await runtime.enumerateItems(
                container: IndexWriter.rootIdentifier, pageToken: nil)
            try await DomainManager.shared.addDomain(for: saved)
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
        try await DomainManager.shared.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        await DomainManager.shared.dropRuntime(locationID: saved.id)
        return try ControlCommands.json([
            "name": saved.displayName, "sshOptions": saved.sshOptions,
        ])
    }

    /// The collect connection again, for `set host|user|port|identity` (and, when it
    /// arrives, `passwd`). Same flow, same relay, same storage rules (section 4.2).
    private static func recollect(for location: Location, relay: CLIRelay?) async throws
        -> (authenticated: Bool, agentDependent: Bool, failure: AddFlow.Failure?, storedKeys: [String])
    {
        let environment = await AgentSSHEnvironment.shared.environment()
        let target = SSHProcess.target(for: location)
        let attribution = try SSHConfigResolver.attribution(
            target: target, environment: environment)
        let collector = CollectConnection(
            request: CollectConnection.Request(
                locationID: location.id, target: target, environment: environment,
                askpassPath: AgentSecrets.askpassPath, resolution: attribution.resolved,
                identityFiles: attribution.resolved.identityFiles),
            broker: AgentSecrets.broker, relay: relay)
        let outcome = await AddFlow.run(
            note: { [weak relay] in relay?.note($0) }, runner: collector)
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
        try await DomainManager.shared.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        let runtime = try await DomainManager.shared.runtime(for: saved)
        _ = try await runtime.enumerateItems(container: IndexWriter.rootIdentifier, pageToken: nil)
        try await DomainManager.shared.addDomain(for: saved)
        return try ControlCommands.json([
            "mounted": saved.displayName,
            "mount": "~/Library/CloudStorage/SSHDrive-\(saved.displayName)",
        ])
    }

    private static func unmount(_ arguments: [String: String]) async throws -> Data {
        let location = try await resolve(arguments)
        try await DomainManager.shared.removeDomain(for: location)
        await DomainManager.shared.dropRuntime(locationID: location.id)
        var updated = location
        updated.mounted = false
        let saved = updated
        try await DomainManager.shared.mutateConfiguration { file in
            if let index = file.locations.firstIndex(where: { $0.id == saved.id }) {
                file.locations[index] = saved
            }
        }
        return try ControlCommands.json(["unmounted": saved.displayName])
    }

    // MARK: status

    private static func status(_ arguments: [String: String]) async throws -> Data {
        let file = try await DomainManager.shared.configuration()
        let wanted: [Location]
        if let name = arguments["name"], !name.isEmpty {
            wanted = [try await DomainManager.shared.location(named: name)]
        } else {
            wanted = file.locations
        }
        let forceProbe = arguments["probe"] == "true"
        let domains = (try? await DomainManager.existingDomainDescriptions()) ?? []

        var rows: [[String: Any]] = []
        for location in wanted {
            var row: [String: Any] = [
                "id": location.id,
                "name": location.displayName,
                "destination": destinationText(location),
                "mounted": domains.contains { $0.hasSuffix("(\(location.id))") },
                "state": await stateWord(location),
                "cacheTTL": location.cacheTTL.rawValue,
                "permissions": location.permissions.rawValue,
                "watchMode": location.watchMode.rawValue,
                "identity": location.agentDependent
                    ? "key agent" : "IdentityAgent=none",
                "secrets": location.secrets.compactMap { SecretKey(account: $0)?.report },
            ]
            // The location must be up for a live probe; a `status` that dialled a server
            // the user has not touched would be a surprise, so only `--probe` connects.
            var runtime = await DomainManager.shared.startedRuntime(locationID: location.id)
            if runtime == nil, forceProbe, location.mounted {
                runtime = try? await DomainManager.shared.runtime(for: location)
            }
            if let runtime {
                row["channels"] = await runtime.channelReport()
                if let identity = await runtime.identityReport() { row["identityProbe"] = identity }
                row["notShown"] = (try? await runtime.notShown())?.map {
                    ["path": $0.path, "reason": $0.reason]
                } ?? []
                let statistics = await runtime.schedulerStatistics()
                row["transfers"] = [
                    "running": statistics.running,
                    "waiting": statistics.waitingForeground + statistics.waitingBackground,
                    "admitted": statistics.admitted,
                ] as [String: Any]
                row["lastError"] = await runtime.lastErrorText() ?? "none"
                if let capability = try? await capabilityReport(
                    location: location, runtime: runtime, forceProbe: forceProbe)
                {
                    row["capabilities"] = capability.asJSON
                }
            } else if let cached = CapabilityCache.probe(locationID: location.id) {
                let budget = CapabilityCache.channelBudget(locationID: location.id) ?? .unrestricted
                row["capabilities"] = CapabilityReport.make(
                    probe: cached.probe, extensions: cached.extensions, location: location,
                    budget: budget, probedAt: cached.probedAt, cached: true).asJSON
                row["channels"] = budget.asJSON
            }
            // Section 4.3: a changed host key needs no command of ours; `status` prints
            // the `ssh-keygen -R` line to run.
            if let text = await hostKeyAdvice(location) { row["hostKeyAdvice"] = text }
            rows.append(row)
        }
        return try ControlCommands.json(["locations": rows])
    }

    /// Section 8.1's report for a live location, re-probing when asked.
    private static func capabilityReport(
        location: Location, runtime: LocationRuntime, forceProbe: Bool
    ) async throws -> CapabilityReport {
        if forceProbe { await runtime.reprobeServer() }
        guard let live = await runtime.serverProbe() else {
            guard let cached = CapabilityCache.probe(locationID: location.id) else {
                throw SSHDriveAgentError.notImplemented.asNSError("no probe for this location")
            }
            return CapabilityReport.make(
                probe: cached.probe, extensions: cached.extensions, location: location,
                budget: await runtime.channelBudgetValue(), probedAt: cached.probedAt,
                cached: true)
        }
        let freeSpace = await runtime.freeSpaceDescription()
        return CapabilityReport.make(
            probe: live.probe, extensions: live.extensions, location: location,
            budget: await runtime.channelBudgetValue(),
            probedAt: CapabilityCache.probe(locationID: location.id)?.probedAt ?? Date(),
            cached: false, freeSpace: freeSpace)
    }

    /// "A host-key change needs no command of ours: `status` prints the `ssh-keygen -R`
    /// line to run" (section 8, section 4.3).
    private static func hostKeyAdvice(_ location: Location) async -> String? {
        guard let runtime = await DomainManager.shared.startedRuntime(locationID: location.id),
            let error = await runtime.lastErrorText(),
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
        return try await DomainManager.shared.location(named: name)
    }
}
