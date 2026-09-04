import ArgumentParser
import Foundation
import Darwin

/// The section 8 commands a user actually types. Every one of them is a single XPC request
/// to the agent; the CLI parses flags, prints what comes back, and - for `add` - is the
/// terminal the collect connection's prompts are relayed to (DESIGN.md sections 3, 4.2, 8).

// MARK: add

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add an SFTP location and mount it in Finder.",
        discussion: """
            Resolves the host with `ssh -G` and shows what it resolves to, warns when this
            terminal's PATH or SSH_AUTH_SOCK differs from the login shell snapshot the
            agent will use, then asks the agent to connect once with the command it will
            use later. The host-key question and any password or passphrase prompt appear
            here and are stored on success, so the location never prompts again.

            The destination is [user@]host-or-alias[:port]; the host may be a ~/.ssh/config
            alias. `sshdrive add <nickname> <destination>` is accepted as a shorthand for
            `sshdrive add <destination> --nickname <nickname>`.
            """)

    @Argument(help: "[user@]host-or-alias[:port], or a nickname followed by one.")
    var destination: String

    @Argument(help: ArgumentHelp(visibility: .hidden))
    var destinationIfNamed: String?

    @Option(help: "Name for the location and for the Finder sidebar. Defaults to the host.")
    var nickname: String?

    @Option(name: [.customLong("remote-path"), .customLong("path")],
            help: "Directory on the server to mount. Defaults to the account's home.")
    var remotePath: String?

    @Option(help: "Account on the server, if not given in the destination.")
    var user: String?

    @Option(help: "Port, if not given in the destination.")
    var port: Int?

    @Option(help: "Key file to authenticate with. Implies IdentitiesOnly=yes.")
    var identity: String?

    @Option(name: [.customShort("o"), .customLong("ssh-option")],
            help: "Extra ssh option, as KEYWORD=VALUE. Repeatable.")
    var sshOption: [String] = []

    @Option(help: "ProxyJump chain: [user@]host[:port], comma separated.")
    var jump: String?

    @Option(name: .customLong("cache-ttl"),
            help: "15m | 1h | 12h | 1d | 1w | 1mo | never.")
    var cacheTTL: String?

    @Option(help: "mode | none: whether server mode bits become Finder capabilities.")
    var permissions: String?

    @Flag(help: "Accept an unknown host key without asking (StrictHostKeyChecking=accept-new).")
    var trustFirst = false

    @Flag(name: .customLong("no-password"),
          help: "Answer every password prompt with the skip: key-only, or not created.")
    var noPassword = false

    func run() throws {
        // `add <nickname> <destination>` and `add <destination> --nickname <nickname>` are
        // the same command; the two-argument form is what a script reads better as.
        var target = destination
        var name = nickname
        if let second = destinationIfNamed {
            name = nickname ?? destination
            target = second
        }

        var arguments: [String: String] = ["destination": target]
        if let name { arguments["nickname"] = name }
        if let remotePath { arguments["remotePath"] = remotePath }
        if let user { arguments["user"] = user }
        if let port { arguments["port"] = String(port) }
        if let identity { arguments["identity"] = identity }
        if let jump { arguments["jump"] = jump }
        if let cacheTTL { arguments["cacheTTL"] = cacheTTL }
        if let permissions { arguments["permissions"] = permissions }
        if trustFirst { arguments["trustFirst"] = "true" }
        if noPassword { arguments["noPassword"] = "true" }
        // The two values section 4.2 has `add` compare against the agent's snapshot.
        arguments["terminalPATH"] = ProcessInfo.processInfo.environment["PATH"] ?? ""
        arguments["terminalSSHAuthSock"] =
            ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
        // The option list travels as one value; \u{1} cannot appear in an ssh option.
        if !sshOption.isEmpty { arguments["sshOptions"] = sshOption.joined(separator: "\u{1}") }

        let data = try AgentClient.send(
            command: "add", arguments: arguments,
            timeout: AgentClient.interactiveTimeoutSeconds)
        let report = AgentClient.object(data)
        print("")
        print("Added \(report["name"] as? String ?? "") (\(report["id"] as? String ?? ""))")
        print("  server     \(report["user"] as? String ?? "")@\(report["host"] as? String ?? "")"
            + ":\(report["port"] as? Int ?? 22)")
        print("  root       \(report["remotePath"] as? String ?? "")"
            + "  (\(report["entries"] as? Int ?? 0) entries)")
        if let chain = report["jumpChain"] as? [String], !chain.isEmpty {
            print("  jump       \(chain.joined(separator: " -> "))")
        }
        for line in report["secrets"] as? [String] ?? [] { print("  auth       \(line)") }
        if report["agentDependent"] as? Bool == true {
            print("  auth       through your key agent only; the mount waits for it after login")
        }
        print("  mount      \(report["mount"] as? String ?? "")")
        if let capabilities = report["capabilities"] as? [String: Any] {
            print("")
            CapabilityRendering.print(capabilities, indent: "  ")
        }
    }
}

// MARK: list

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Every location: name, host, secrets, mount, TTL, state.")

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        let data = try AgentClient.send(command: "list")
        if json { AgentClient.prettyPrint(data); return }
        let rows = AgentClient.object(data)["locations"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else {
            print("No locations. Add one with: sshdrive add user@host")
            return
        }
        for row in rows {
            let name = (row["name"] as? String ?? "").padding(
                toLength: max(10, (row["name"] as? String ?? "").count), withPad: " ", startingAt: 0)
            let secrets = (row["secrets"] as? [String] ?? []).isEmpty
                ? "no stored secrets" : (row["secrets"] as? [String] ?? []).joined(separator: ", ")
            print("\(name)  \(row["destination"] as? String ?? "")")
            print("            \(row["mounted"] as? Bool == true ? "mounted" : "not mounted")"
                + "  \(row["state"] as? String ?? "")"
                + "  TTL \(row["cacheTTL"] as? String ?? "")"
                + "  \(secrets)")
        }
    }
}

// MARK: show

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Everything about one location: config, secrets, domain state, capabilities.")

    @Argument(help: "Nickname, host, or the start of the location id.")
    var name: String

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        let data = try AgentClient.send(command: "show", arguments: ["name": name])
        if json { AgentClient.prettyPrint(data); return }
        let report = AgentClient.object(data)

        print("\(report["name"] as? String ?? "")  (\(report["id"] as? String ?? ""))")
        print("  Server     \(report["destination"] as? String ?? "")"
            + "   root \(report["remotePath"] as? String ?? "")")
        print("  ssh        \(report["sshBinary"] as? String ?? "") (\(report["ssh"] as? String ?? ""))")
        print("  env        \(report["environment"] as? String ?? "")")
        print("  key agent  \(report["keyAgent"] as? String ?? "")")
        if let resolution = report["resolution"] as? [String], !resolution.isEmpty {
            print("  Resolves")
            for line in resolution { print("    \(line)") }
        }
        if let overridden = report["overridden"] as? [String], !overridden.isEmpty {
            print("  Overridden by SSH Drive")
            for line in overridden { print("    \(line)") }
        }
        if let chain = report["jumpChain"] as? [String], !chain.isEmpty {
            print("  Jump       \(chain.joined(separator: " -> "))")
        }
        if let warning = report["proxyCommandWarning"] as? String {
            print("  Warning    \(warning)")
        }
        if let error = report["resolutionError"] as? String {
            print("  Resolution failed: \(error)")
        }
        let secrets = report["secrets"] as? [String] ?? []
        print("  Auth       \(secrets.isEmpty ? "no stored secrets" : secrets.joined(separator: ", "))")
        print("  State      domain \(report["domain"] as? String ?? "")"
            + "   \(report["state"] as? String ?? "")"
            + "   mount \(report["mount"] as? String ?? "")")
        print("  Settings   TTL \(report["cacheTTL"] as? String ?? "")"
            + "   permissions \(report["permissions"] as? String ?? "")"
            + "   watch-mode \(report["watchMode"] as? String ?? "")"
            + "   helper \(report["helper"] as? Bool == true ? "on" : "off")"
            + "   create-check \(report["createCheck"] as? String ?? "")")
        print("  Last error \(report["lastError"] as? String ?? "none")")
        if let channels = report["channels"] as? [String: Any],
            let note = channels["note"] as? String, !note.isEmpty
        {
            print("  Channels   \(note)")
        }
        for entry in report["notShown"] as? [[String: Any]] ?? [] {
            print("  Not shown  \(entry["path"] as? String ?? "") (\(entry["reason"] as? String ?? ""))")
        }
        if let capabilities = report["capabilities"] as? [String: Any] {
            print("")
            CapabilityRendering.print(capabilities, indent: "  ")
        }
    }
}

// MARK: remove

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a location: its domain, its index, and the keychain items only it names.")

    @Argument(help: "Nickname, host, or the start of the location id.")
    var name: String?

    @Flag(help: "Every location. Run this before `brew uninstall --cask ssh-drive`.")
    var all = false

    @Flag(name: .customLong("keep-files"),
          help: "Keep the downloaded files in the folder the system chooses.")
    var keepFiles = false

    @Flag(help: "Remove even while uploads are pending.")
    var force = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.")
    var yes = false

    func run() throws {
        guard all || name != nil else {
            throw ValidationError("Name a location, or pass --all.")
        }
        if !yes {
            let what = all ? "every location" : "\"\(name ?? "")\""
            let question = keepFiles
                ? "Remove \(what)? Downloaded files are kept."
                : "Remove \(what)? The local cache and the keychain items only it names go too."
            guard PromptService.confirm(question) else {
                print("Nothing was removed.")
                throw ExitCode.failure
            }
        }
        var arguments: [String: String] = [:]
        if let name { arguments["name"] = name }
        if all { arguments["all"] = "true" }
        if keepFiles { arguments["keepFiles"] = "true" }
        if force { arguments["force"] = "true" }
        let report = AgentClient.object(
            try AgentClient.send(command: "remove", arguments: arguments, timeout: 120))
        let removed = report["removed"] as? [String] ?? []
        print(removed.isEmpty ? "Nothing to remove." : "Removed \(removed.joined(separator: ", ")).")
        let secrets = report["secretsRemoved"] as? [String] ?? []
        if !secrets.isEmpty {
            print("Keychain items removed: \(secrets.joined(separator: ", "))")
        }
    }
}

// MARK: set

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change one setting.",
        discussion: """
            Keys: nickname, cache-ttl, remote-path, host, port, user, identity, watch-mode,
            helper, permissions, create-check, and `option add|remove KEYWORD=VALUE`.

            nickname and remote-path re-create the File Provider domain, so the cache is
            dropped; host, user, port and identity re-run the connection check before the
            change is saved.
            """)

    @Argument var name: String
    @Argument var key: String
    @Argument var value: String
    @Argument(help: "For `option add|remove`: the ssh option.")
    var option: String?

    @Flag(help: "Change even while uploads are pending.")
    var force = false

    func run() throws {
        var arguments = ["name": name, "key": key, "value": value]
        if let option { arguments["option"] = option }
        if force { arguments["force"] = "true" }
        let report = AgentClient.object(
            try AgentClient.send(
                command: "set", arguments: arguments,
                timeout: AgentClient.interactiveTimeoutSeconds))
        if let options = report["sshOptions"] as? [String] {
            print("\(report["name"] as? String ?? name): ssh options are now \(options.joined(separator: " "))")
            return
        }
        if report["changed"] as? Bool == true {
            print("\(report["name"] as? String ?? name): \(key) is now \(value)")
        } else {
            print("\(report["name"] as? String ?? name): \(key) was already \(value)")
        }
        for note in report["notes"] as? [String] ?? [] { print("  \(note)") }
    }
}

// MARK: mount / unmount

struct Mount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add the File Provider domain for a location without re-adding it.")
    @Argument var name: String
    func run() throws {
        let report = AgentClient.object(
            try AgentClient.send(command: "mount", arguments: ["name": name], timeout: 120))
        print("Mounted \(report["mounted"] as? String ?? name) at \(report["mount"] as? String ?? "")")
    }
}

struct Unmount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the File Provider domain without forgetting the location.")
    @Argument var name: String
    func run() throws {
        let report = AgentClient.object(
            try AgentClient.send(command: "unmount", arguments: ["name": name], timeout: 120))
        print("Unmounted \(report["unmounted"] as? String ?? name)")
    }
}

// MARK: status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Per-domain state, sync errors, hidden names, and the capability report.")

    @Argument(help: "One location, or every location when omitted.")
    var name: String?

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    @Flag(help: "Re-run the server probe instead of using the cached result.")
    var probe = false

    func run() throws {
        var arguments: [String: String] = [:]
        if let name { arguments["name"] = name }
        if probe { arguments["probe"] = "true" }
        let data = try AgentClient.send(command: "status", arguments: arguments, timeout: 120)
        if json { AgentClient.prettyPrint(data); return }
        let rows = AgentClient.object(data)["locations"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else {
            print("No locations. Add one with: sshdrive add user@host")
            return
        }
        for row in rows {
            print("\(row["name"] as? String ?? "")   \(row["destination"] as? String ?? "")"
                + "   \(row["mounted"] as? Bool == true ? "mounted" : "not mounted")"
                + "   \(row["state"] as? String ?? "")"
                + "   TTL \(row["cacheTTL"] as? String ?? "")")
            if let transfers = row["transfers"] as? [String: Any] {
                print("       transfers \(transfers["running"] as? Int ?? 0) running, "
                    + "\(transfers["waiting"] as? Int ?? 0) waiting, "
                    + "\(transfers["admitted"] as? Int ?? 0) admitted")
            }
            print("       identity \(row["identity"] as? String ?? "")"
                + "   permissions \(row["permissions"] as? String ?? "")"
                + "   watch-mode \(row["watchMode"] as? String ?? "")")
            if let channels = row["channels"] as? [String: Any] {
                let count = channels["concurrentChannels"] as? Int ?? 3
                let note = channels["note"] as? String ?? ""
                print("       channels \(count) at a time"
                    + (channels["bulkChannel"] as? Bool == true ? ", bulk channel" : ", no bulk channel")
                    + (channels["execChannel"] as? Bool == true ? ", shell" : ", no shell")
                    + (note.isEmpty ? "" : "\n         note: \(note)"))
            }
            if let identity = row["identityProbe"] as? [String: Any],
                let description = identity["description"] as? String, !description.isEmpty
            {
                print("       server sees us as \(description)")
            }
            let notShown = row["notShown"] as? [[String: Any]] ?? []
            for entry in notShown {
                print("       not shown  \(entry["path"] as? String ?? "") "
                    + "(\(entry["reason"] as? String ?? ""))")
            }
            // Section 6.4: the tier in use, the cadence, the last sweep and where the
            // location sits on the fallback ladder.
            if let watch = row["watch"] as? [String: Any] {
                var line = "       watch \(watch["tier"] as? String ?? "?")"
                if let interval = watch["intervalSeconds"] as? Double {
                    line += "   every \(Int(interval))s"
                        + ((watch["active"] as? Bool == true) ? " (active)" : " (idle)")
                }
                if let cycles = watch["cycles"] as? Int { line += "   \(cycles) cycle(s)" }
                if let roots = watch["roots"] as? Int {
                    line += "   \(roots) root(s)"
                    // "status shows the rotation period when it exceeds one cycle"
                    // (section 6.5).
                    if let period = watch["rotationPeriod"] as? Int, period > 1 {
                        line += " rotating over \(period) cycles"
                    }
                }
                print(line)
                if let note = watch["note"] as? String, !note.isEmpty {
                    print("         note: \(note)")
                }
                if watch["sweepUsesMmin"] as? Bool == true {
                    print("         note: this server's find has no -cmin, so the sweep uses "
                        + "-mmin and a chmod, a chown or a write that preserved mtime is only "
                        + "found by the 30-minute full sweep")
                }
                if let skew = watch["clockSkewSeconds"] as? Int, skew != 0 {
                    print("         note: the sweep's server-clock reference is shifted by "
                        + "\(skew)s by a debug hook")
                }
                for downgrade in watch["downgrades"] as? [[String: Any]] ?? [] {
                    print("         note: dropped from \(downgrade["from"] as? String ?? "") to "
                        + "\(downgrade["to"] as? String ?? "") - "
                        + "\(downgrade["reason"] as? String ?? "")")
                }
                if let last = watch["lastCycle"] as? [String: Any] {
                    let seconds = last["seconds"] as? Double ?? 0
                    print("         last \((last["full"] as? Bool == true) ? "full sweep" : "cycle") "
                        + "\(CapabilityRendering.age(last["at"] as? Double ?? 0)): "
                        + "\(last["changed"] as? Int ?? 0) changed, "
                        + "\(last["deleted"] as? Int ?? 0) deleted, "
                        + "\(last["held"] as? Int ?? 0) held, "
                        + "\(last["directoriesListed"] as? Int ?? 0) listed, "
                        + String(format: "%.2fs", seconds))
                }
            }
            // Section 8: "0 held deletions" on the Sync line, and section 6.4's
            // "14 deletions held in Photos, re-check at 14:32" when there are any.
            let held = row["heldDeletions"] as? [[String: Any]] ?? []
            if held.isEmpty {
                print("       0 held deletions")
            } else {
                let byDirectory = Dictionary(grouping: held) {
                    ($0["directory"] as? String ?? "")
                }
                for (directory, entries) in byDirectory.sorted(by: { $0.key < $1.key }) {
                    let next = entries.compactMap { $0["recheckAt"] as? Double }.min() ?? 0
                    print("       \(entries.count) deletion(s) held in "
                        + "\(directory.isEmpty ? "the location root" : directory)"
                        + ", re-check at \(CapabilityRendering.clock(next))")
                }
                print("       apply them now with: sshdrive accept-deletions "
                    + "\(row["name"] as? String ?? "")")
            }
            if let error = row["lastError"] as? String, error != "none" {
                print("       last error \(error)")
            }
            if let advice = row["hostKeyAdvice"] as? String {
                print("       the server's host key changed. Run:")
                print("         \(advice)")
            }
            if let capabilities = row["capabilities"] as? [String: Any] {
                CapabilityRendering.print(capabilities, indent: "       ")
            }
            print("")
        }
    }
}

// MARK: the capability report

/// Section 8.1's fixed shape: a level glyph, the feature name, the level in use, and an
/// indented `upgrade:` line whenever the level is not the best one. The agent computes
/// every one of these values; nothing here decides anything, so `--json` and the text can
/// never disagree.
enum CapabilityRendering {

    static func print(_ report: [String: Any], indent: String) {
        let optimal = report["optimal"] as? Int ?? 0
        let total = report["total"] as? Int ?? 0
        let cached = report["cached"] as? Bool == true
        let probedAt = report["probedAt"] as? Double ?? 0
        Swift.print("\(indent)Capabilities  \(optimal)/\(total) optimal"
            + "   probed \(age(probedAt))\(cached ? " (cached)" : "")")
        for feature in report["features"] as? [[String: Any]] ?? [] {
            let name = (feature["feature"] as? String ?? "")
            let padded = name.padding(toLength: max(20, name.count), withPad: " ", startingAt: 0)
            Swift.print("\(indent)\(feature["glyph"] as? String ?? "?") \(padded) "
                + "\(feature["level"] as? String ?? "")")
            if let note = feature["note"] as? String, !note.isEmpty {
                Swift.print("\(indent)      note: \(note)")
            }
            if let upgrade = feature["upgrade"] as? String, !upgrade.isEmpty {
                Swift.print("\(indent)      upgrade: \(upgrade)")
            }
            if let consider = feature["consider"] as? String, !consider.isEmpty {
                Swift.print("\(indent)      consider: \(consider)")
            }
        }
        if let free = report["serverFreeSpace"] as? String {
            Swift.print("\(indent)Server free space  \(free)")
        }
    }

    /// A wall-clock time, which is how section 8 prints a guard re-check:
    /// "14 deletions held in Photos, re-check at 14:32".
    static func clock(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "the next cycle" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func age(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "never" }
        let seconds = Int(Date().timeIntervalSince1970 - timestamp)
        if seconds < 60 { return "\(max(seconds, 0))s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}


// MARK: accept-deletions

/// `sshdrive accept-deletions <name> [path]` (DESIGN.md section 8): apply the deletions
/// the mass-deletion guard of section 6.4 is holding, now, rather than waiting for its
/// second re-check.
struct AcceptDeletions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accept-deletions",
        abstract: "Apply deletions the mass-deletion guard is holding.",
        discussion: """
            The guard holds a diff that would remove at least half of a directory's known
            items and at least twenty of them, or would empty a root that held anything -
            a NAS whose dataset has not imported yet looks exactly like a directory that
            was emptied. It also holds any deletion of an item with a local edit still
            waiting to upload. Held items stay visible in Finder and fail to open; this
            command says the deletions are real.
            """)

    @Argument(help: "The location.")
    var name: String

    @Argument(help: "Only this path and what is under it. Everything when omitted.")
    var path: String?

    func run() throws {
        var arguments = ["name": name]
        if let path { arguments["path"] = path }
        let data = try AgentClient.send(
            command: "accept-deletions", arguments: arguments, timeout: 120)
        let report = AgentClient.object(data)
        let applied = report["applied"] as? Int ?? 0
        let remaining = report["stillHeld"] as? Int ?? 0
        print("Applied \(applied) held deletion(s) in \(report["location"] as? String ?? name).")
        if remaining > 0 { print("\(remaining) still held.") }
    }
}
