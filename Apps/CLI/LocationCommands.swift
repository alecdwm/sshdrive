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

    @Flag(help: "Every location. Run this before `brew uninstall --cask sshdrive`.")
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

            nickname renames the Finder sidebar entry, and the folder under
            ~/Library/CloudStorage with it, in place: cached files and pending uploads are
            kept. remote-path re-creates the File Provider domain, so the cache is dropped
            and every path in the index is invalidated. host, user, port and identity re-run
            the connection check before the change is saved.
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
                if let note = watch["intervalNote"] as? String, !note.isEmpty {
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
            // Section 8.1's Cache line: "1.2 GB materialized (312 files), 480 MB kept
            // TTL 1d   next eviction sweep in 3m", and the Pins line under it.
            if let cache = row["cache"] as? [String: Any] {
                var line = "       cache "
                    + "\(SizeRendering.bytes(cache["bytes"] as? Int64 ?? 0)) materialized "
                    + "(\(cache["files"] as? Int ?? 0) files)"
                let keptBytes = cache["keptBytes"] as? Int64 ?? 0
                if keptBytes > 0 { line += ", \(SizeRendering.bytes(keptBytes)) kept" }
                line += "   TTL \(cache["ttl"] as? String ?? "")"
                if (cache["ttl"] as? String) != "never",
                    let next = cache["nextPassInSeconds"] as? Double
                {
                    line += "   next eviction pass in \(SizeRendering.duration(next))"
                }
                print(line)
                // Section 7.2's safety net, when it has had to do anything.
                if let outside = cache["keptEvictedOutside"] as? Int, outside > 0 {
                    print("         note: \(outside) kept file(s) were evicted outside "
                        + "SSH Drive and re-downloaded")
                }
            }
            let pins = row["pins"] as? [[String: Any]] ?? []
            if !pins.isEmpty {
                let names = pins.map { entry -> String in
                    let path = entry["path"] as? String ?? ""
                    let shown = path.isEmpty ? "/" : path
                    return (entry["state"] as? String) == "excluded" ? "!\(shown)" : shown
                }
                print("       pins  \(names.joined(separator: "   "))"
                    + "   (a leading ! is an exclusion; sshdrive pins "
                    + "\(row["name"] as? String ?? "") shows the tree)")
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

// MARK: evict, pin, unpin, pins

/// Sizes the way section 8.1 writes them: "1.2 GB", "480 MB", "210 MB".
enum SizeRendering {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    /// "in 3m", the way `status`'s Cache line names the next eviction pass.
    static func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value < 60 { return "\(max(value, 0))s" }
        if value < 3600 { return "\(value / 60)m" }
        return "\(value / 3600)h"
    }
}

/// `sshdrive evict <name> [path] [--all] [--unpin-all]` (DESIGN.md sections 7, 8).
///
/// With no path this runs the TTL routine of section 7 on demand - the same pass the
/// five-minute timer runs, so it evicts what the TTL says is stale and nothing else. With
/// a path it evicts that item now. `--all` drops everything cached, which is one
/// `evictItem` on the root container when nothing is pinned (S4, 2026-09-04).
struct Evict: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drop cached content: the TTL pass, one path, or everything.",
        discussion: """
            With no path this runs the TTL pass now: content whose last fetch or save is
            older than the location's cache-ttl is dropped, kept (pinned) items are
            skipped, and anything with an edit still waiting to upload is refused by the
            system. With a path it drops that item now. Files come back on the next open.
            """)

    @Argument(help: "The location.")
    var name: String

    @Argument(help: "One path to drop now. The TTL pass runs when it is omitted.")
    var path: String?

    @Flag(help: "Drop everything this location has cached.")
    var all = false

    @Flag(name: .customLong("unpin-all"),
          help: "With --all: remove every pin first, so kept content goes too.")
    var unpinAll = false

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        var arguments = ["name": name]
        if let path { arguments["path"] = path }
        if all { arguments["all"] = "true" }
        if unpinAll { arguments["unpinAll"] = "true" }
        let data = try AgentClient.send(command: "evict", arguments: arguments, timeout: 300)
        if json { AgentClient.prettyPrint(data); return }
        let report = AgentClient.object(data)
        let location = report["location"] as? String ?? name

        if let skipped = report["skipped"] as? String {
            print("\(location): \(skipped).")
            return
        }
        if all {
            if let removed = report["pinsRemoved"] as? Int, removed > 0 {
                print("Removed \(removed) pin(s) first.")
            }
            if report["mode"] as? String == "root container" {
                let ok = report["evicted"] as? Bool == true
                print(ok
                    ? "\(location): everything cached was dropped."
                    : "\(location): the system refused: "
                        + "\(report["errorDescription"] as? String ?? "unknown error")")
                if let left = report["stillMaterialized"] as? Int, left > 0 {
                    print("  \(left) item(s) are still materialized.")
                }
            } else {
                var line = "\(location): dropped \(report["evicted"] as? Int ?? 0) file(s)"
                let kept = report["keptSkipped"] as? Int ?? 0
                if kept > 0 {
                    line += "; \(kept) kept file(s) were left alone "
                        + "(pass --unpin-all to drop those too)"
                }
                print(line + ".")
                if let refused = report["rootContainerError"] as? String {
                    print("  the whole-location eviction was refused (\(refused)), so the "
                        + "files were dropped one at a time.")
                }
                if let stillRefused = report["refusedCount"] as? Int, stillRefused > 0 {
                    print("  \(stillRefused) file(s) the system would not drop; they have "
                        + "an edit still waiting to upload, or it is still applying a "
                        + "policy change. Try again in a moment.")
                }
            }
            return
        }
        if path != nil {
            let ok = report["evicted"] as? Bool == true
            print(ok
                ? "Dropped \(report["path"] as? String ?? "") from \(location)."
                : "\(location): \(report["errorDescription"] as? String ?? "the system refused the eviction").")
            if !ok { throw ExitCode.failure }
            return
        }
        // The TTL pass.
        let files = report["materializedFiles"] as? Int ?? 0
        let bytes = report["materializedBytes"] as? Int64 ?? 0
        print("\(location): TTL \(report["ttl"] as? String ?? "")   "
            + "\(SizeRendering.bytes(bytes)) in \(files) file(s) cached")
        print("  dropped \(report["evicted"] as? Int ?? 0), "
            + "kept \(report["skippedKept"] as? Int ?? 0) pinned, "
            + "in \(String(format: "%.2fs", report["seconds"] as? Double ?? 0))")
        for refusal in report["refused"] as? [[String: Any]] ?? [] {
            print("  refused \(refusal["path"] as? String ?? ""): "
                + "\(refusal["error"] as? String ?? "")")
        }
    }
}

/// `sshdrive pin <name> <remote-path>` (section 7.1), and its opposite.
struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep a folder or file downloaded, offline, for good.",
        discussion: """
            The subtree is downloaded now and kept: the TTL never touches it, new files
            that appear on the server inside it are fetched, and it stays readable with no
            network. `/` or `.` pins the whole location. Any pin or exclusion inside the
            path is cleared, which is how a complicated structure is reset.
            """)

    @Argument(help: "The location.")
    var name: String

    @Argument(help: "The remote path, relative to the location's root. `/` is the whole location.")
    var path: String

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        try PinCommands.run(command: "pin", name: name, path: path, json: json)
    }
}

struct Unpin: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop keeping a path downloaded.",
        discussion: """
            On a pinned path this removes the pin; on a path that merely inherits a pin
            from a folder above it, it records an exclusion, so the rest of the pinned
            folder is untouched. Either way the content stays on disk and falls under the
            location's cache-ttl from that moment.
            """)

    @Argument(help: "The location.")
    var name: String

    @Argument(help: "The remote path, relative to the location's root.")
    var path: String

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        try PinCommands.run(command: "unpin", name: name, path: path, json: json)
    }
}

enum PinCommands {
    static func run(command: String, name: String, path: String, json: Bool) throws {
        let data = try AgentClient.send(
            command: command, arguments: ["name": name, "path": path], timeout: 300)
        if json { AgentClient.prettyPrint(data); return }
        let report = AgentClient.object(data)
        let shown = report["path"] as? String ?? path
        let note = report["note"] as? String ?? ""
        let location = report["location"] as? String ?? name

        guard report["changed"] as? Bool == true else {
            // Section 7.1.1: the CLI says so, and names the covering ancestor when there
            // is one. Finder simply hides the entry.
            var line = "\(shown) in \(location): \(note)"
            if let covering = report["coveredBy"] as? String {
                line += " (\(covering.isEmpty ? "the location root" : covering))"
            }
            print(line + ". Nothing changed.")
            return
        }

        var line = command == "pin" ? "Pinned \(shown)" : "Unpinned \(shown)"
        // "Both `pin` and `unpin` print how many nested states they cleared, so a reset is
        // visible" (section 7.1.1).
        let pins = report["clearedPins"] as? Int ?? 0
        let exclusions = report["clearedExclusions"] as? Int ?? 0
        if pins + exclusions > 0 {
            var parts: [String] = []
            if exclusions > 0 { parts.append("\(exclusions) nested exclusion(s)") }
            if pins > 0 { parts.append("\(pins) nested pin(s)") }
            line += " (cleared \(parts.joined(separator: " and ")))"
        }
        print(line + ".")
        print("  \(note); \(report["rowsRewritten"] as? Int ?? 0) item(s) updated.")
        if let created = report["ancestorRowsCreated"] as? Int, created > 0 {
            print("  \(created) folder(s) on the way to it were listed for the first time.")
        }
        if command == "pin" {
            print("  The download starts within about a minute and runs in the background; "
                + "watch it with: sshdrive pins \(name)")
        } else {
            print("  The content stays on disk and now falls under the location's cache-ttl.")
        }
    }
}

/// `sshdrive pins [<name>] [--export | --import FILE]` (section 7.1).
struct Pins: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The pins and exclusions of a location, as a tree.")

    @Argument(help: "The location.")
    var name: String

    @Flag(help: "Print the markers as JSON, for a backup or another Mac.")
    var export = false

    @Option(name: .customLong("import"), help: "Read markers back from a file written by --export.")
    var importFile: String?

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        var arguments = ["name": name]
        if export { arguments["export"] = "true" }
        if let importFile {
            // The CLI reads the file: it is the process with the user's working directory
            // and their read permission, and the agent runs as a login agent with neither.
            guard let contents = try? String(contentsOfFile: importFile, encoding: .utf8) else {
                throw ValidationError("Cannot read \(importFile).")
            }
            arguments["import"] = contents
        }
        let data = try AgentClient.send(command: "pins", arguments: arguments, timeout: 300)
        if json || export { AgentClient.prettyPrint(data); return }
        let report = AgentClient.object(data)

        if let imported = report["imported"] as? [String] {
            print("Imported \(imported.count) marker(s) into \(report["location"] as? String ?? name).")
            for failure in report["failed"] as? [String] ?? [] { print("  failed: \(failure)") }
            return
        }

        let pins = report["pins"] as? [[String: Any]] ?? []
        guard !pins.isEmpty else {
            print("No pins in \(report["location"] as? String ?? name). "
                + "Keep a folder offline with: sshdrive pin \(name) <path>")
            return
        }
        for entry in pins {
            let depth = entry["depth"] as? Int ?? 0
            let path = entry["path"] as? String ?? ""
            let shown = path.isEmpty ? "/" : path
            let indent = String(repeating: "  ", count: depth)
            let name = (indent + shown)
            let state = entry["state"] as? String ?? ""
            let files = entry["files"] as? Int ?? 0
            let bytes = entry["bytes"] as? Int64 ?? 0
            let downloadedFiles = entry["downloadedFiles"] as? Int ?? 0
            let downloadedBytes = entry["downloadedBytes"] as? Int64 ?? 0
            let detail = state == "pinned"
                ? "\(SizeRendering.bytes(downloadedBytes)), \(downloadedFiles) of \(files) file(s) downloaded"
                : "(\(SizeRendering.bytes(bytes)) on the server, \(downloadedFiles) file(s) downloaded)"
            print("\(name.padding(toLength: max(32, name.count), withPad: " ", startingAt: 0)) "
                + "\(state.padding(toLength: 9, withPad: " ", startingAt: 0)) \(detail)")
        }
    }
}
