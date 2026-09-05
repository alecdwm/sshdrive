import ArgumentParser
import Foundation
import Logging
import XPCProtocols

/// `sshdrive logs [--follow] [<name>]` (DESIGN.md section 8).
///
/// The one command in section 8 that is not "a request to the agent and the reply back":
/// what it reads is the unified log, which is the system's, not the agent's, and
/// `OSLogStore`'s local store is not open to a standard user. So the CLI runs
/// `/usr/bin/log` and gets out of the way - `exec`, not a pipe, so `--follow` streams
/// straight to the terminal, Ctrl-C reaches `log` itself, and a pager downstream sees a
/// real pipe close.
///
/// The agent is asked one thing only, and only when a `<name>` is given: which location
/// that name means (section 8's "nickname, then host, then id prefix"). With the agent
/// unreachable the name is still usable as a plain string filter, and `logs` says so
/// rather than failing - an agent that will not start is exactly when someone wants the
/// log.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show SSH Drive's unified log, ours and the system's.",
        discussion: """
            Reads our own os_log subsystem (org.shirls.sshdrive: the agent, the extension,
            the CLI and askpass) together with the fileproviderd lines about our domains,
            which is where the system records what it asked the extension for and what it
            made of the answer. Naming a location narrows both halves to that domain.

            Ctrl-C ends a --follow. Add --debug for the noisiest level.
            """)

    @Argument(help: "A location: nickname, host, or the start of its id. Omit for all.")
    var name: String?

    @Flag(name: [.customLong("follow"), .customShort("f")], help: "Stream new lines as they arrive.")
    var follow = false

    @Option(help: "How far back to read, in `log show` syntax (1h, 30m, 2d).")
    var last: String = "1h"

    @Flag(help: "Include debug-level lines as well as info.")
    var debug = false

    @Flag(help: "Print the log command and its predicate instead of running it.")
    var printCommand = false

    func run() throws {
        var domainIdentifier: String?
        var displayName: String?

        if let name {
            switch Logs.resolve(name: name) {
            case .resolved(let id, let display):
                domainIdentifier = id
                displayName = display
            case .unresolved(let reason):
                // Not fatal. The name the user typed is very often the display name and
                // the nickname alike, so it works as a needle on its own.
                standardError(
                    "Could not ask the agent which location \"\(name)\" is (\(reason)); "
                        + "filtering the log on that text instead.")
                domainIdentifier = name
                displayName = name
            }
        }

        let argv =
            follow
            ? LogQuery.streamArguments(
                domainIdentifier: domainIdentifier, displayName: displayName, debug: debug)
            : LogQuery.showArguments(
                domainIdentifier: domainIdentifier, displayName: displayName, last: last,
                debug: debug)

        if printCommand {
            print(argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
            return
        }

        // execv, not Process: `log stream` should own this terminal for as long as it
        // runs, and the CLI has nothing left to do.
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        execv(LogQuery.executable, &cArgs)
        // Only reached if execv failed.
        standardError("Could not run \(LogQuery.executable): \(String(cString: strerror(errno)))")
        throw ExitCode.failure
    }

    enum Resolution {
        case resolved(id: String, displayName: String)
        case unresolved(reason: String)
    }

    /// `show <name>` is the agent's own resolver; using it here means `logs nas` and
    /// `show nas` can never disagree about which location `nas` is.
    static func resolve(name: String) -> Resolution {
        do {
            let reply = try AgentClient.send(command: "show", arguments: ["name": name])
            let object = AgentClient.object(reply)
            guard let id = object["id"] as? String else {
                return .unresolved(reason: "the agent's reply carried no location id")
            }
            return .resolved(id: id, displayName: object["name"] as? String ?? name)
        } catch {
            return .unresolved(reason: error.localizedDescription.split(separator: "\n").first.map(String.init) ?? "unavailable")
        }
    }
}
