import ArgumentParser
import Config
import Foundation
import XPCProtocols
import Logging

/// `sshdrive`, the only user interface (docs/design/cli.md).
///
/// Every subcommand is one XPC request to the agent and its reply, printed here: the CLI
/// itself runs no `ssh`, touches no keychain and calls no File Provider API. `logs` is
/// the exception; it execs `/usr/bin/log`.
@main
struct SSHDrive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sshdrive",
        abstract: "Mount SFTP locations in Finder.",
        discussion: """
            A command that changes something prints nothing when it works; prompts,
            warnings and errors always appear, and `-v` after the subcommand prints the
            full report.

            Docs: https://sshdrive.shirls.org/
            Run `sshdrive doctor` if a location does not appear in Finder.
            """,
        version: SSHDriveVersion.string,
        subcommands: [
            Add.self, ListCommand.self, Show.self, Status.self, SetCommand.self,
            Mount.self, Unmount.self, Remove.self, AcceptDeletions.self,
            Evict.self, Pin.self, Unpin.self, Pins.self,
            Logs.self, Doctor.self, Agent.self, Debug.self,
        ])
}

// MARK: doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the install and say what to fix.")

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    @OptionGroup var global: GlobalOptions

    func run() throws {
        // "agent reachable" and "CLI on PATH" are the CLI's own two checks: the first is
        // implied by the call arriving at all, the second only makes sense from a
        // terminal (docs/design/cli.md).
        var reachable = true
        var unreachableDetail = "no answer on the mach service"
        var data: Data?
        do {
            data = try AgentClient.send(command: "doctor")
        } catch {
            reachable = false
            // "unreachable" and "did not answer in time" are different faults and get
            // different lines: reporting a stalled command as a missing agent sends the
            // user after the wrong thing.
            if error is AgentClient.CommandTimedOut {
                unreachableDetail = "the agent answered the connection but not the command in time"
            }
            standardError("\(error.localizedDescription)\n")
        }

        if json, let data {
            AgentClient.prettyPrint(data)
            return
        }

        print(line(reachable ? "ok" : "fail", "agent reachable",
                   reachable ? "the background agent answered" : unreachableDetail))
        let onPath = cliOnPath()
        print(line(onPath == nil ? "warn" : "ok", "CLI on PATH",
                   onPath ?? "sshdrive is not on PATH; the Homebrew cask symlinks it for you"))

        guard let data else {
            print("\nFurther checks need the agent. Start it with: open -g -a \"SSH Drive\"")
            throw ExitCode.failure
        }

        let report = AgentClient.object(data)
        let checks = report["checks"] as? [[String: Any]] ?? []
        var failed = false
        for check in checks {
            let status = check["status"] as? String ?? "warn"
            if status == "fail" { failed = true }
            print(line(status, check["name"] as? String ?? "", check["detail"] as? String ?? ""))
            if let remedy = check["remedy"] as? String {
                print("        \(remedy.replacingOccurrences(of: "\n", with: "\n        "))")
            }
        }
        if failed || !reachable { throw ExitCode.failure }
    }

    private func line(_ status: String, _ name: String, _ detail: String) -> String {
        let marker: String
        switch status {
        case "ok": marker = "  ok  "
        case "fail": marker = " fail "
        case "note": marker = " note "
        default: marker = " warn "
        }
        return "[\(marker)] \(name.padding(toLength: max(name.count, 26), withPad: " ", startingAt: 0)) \(detail)"
    }

    private func cliOnPath() -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for directory in paths {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("sshdrive")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}

// MARK: agent

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start, stop or restart the background agent.",
        discussion: """
            `stop` asks the agent to exit cleanly; launchd leaves it down until the next
            mach lookup, which any CLI command or extension call causes, so stop is a
            pause, not a disable. Disabling is the Login Items switch in System Settings.
            """,
        subcommands: [AgentStart.self, AgentStop.self, AgentRestart.self])
}

struct AgentStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        // The mach lookup itself starts the agent.
        let reply = try AgentClient.send(command: "version")
        if global.verbose { AgentClient.prettyPrint(reply) }
    }
}

struct AgentStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let reply = try AgentClient.send(command: "agent.stop")
        if global.verbose { AgentClient.prettyPrint(reply) }
    }
}

struct AgentRestart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        _ = try? AgentClient.send(command: "agent.stop")
        Thread.sleep(forTimeInterval: 1)
        let reply = try AgentClient.send(command: "version")
        if global.verbose { AgentClient.prettyPrint(reply) }
    }
}
