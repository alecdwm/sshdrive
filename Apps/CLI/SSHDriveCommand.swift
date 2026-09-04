import ArgumentParser
import Foundation
import XPCProtocols
import Logging

/// `sshdrive`, the only user interface (DESIGN.md section 8).
///
/// Milestone 3 adds section 8's user-facing half: `add` with the `ssh -G` display and the
/// relayed prompts of section 4.2, `list`, `show`, `remove`, `set`, `mount`, `unmount` and
/// `status` with section 8.1's capability report. `passwd`, `test`, `evict`, `pin`,
/// `pins`, `logs` and `accept-deletions` arrive with the milestone that gives each
/// something to do.
@main
struct SSHDrive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sshdrive",
        abstract: "Mount SFTP locations in Finder.",
        discussion: """
            Docs: https://github.com/alecdwm/sshdrive
            Run `sshdrive doctor` if a location does not appear in Finder.
            """,
        version: "0.1.0 (milestone 6)",
        subcommands: [
            Add.self, ListCommand.self, Show.self, Status.self, SetCommand.self,
            Mount.self, Unmount.self, Remove.self, AcceptDeletions.self,
            Doctor.self, Agent.self, Debug.self,
        ])
}

// MARK: doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the install and say what to fix.")

    @Flag(help: "Print the raw report as JSON.")
    var json = false

    func run() throws {
        // "agent reachable" and "CLI on PATH" are the CLI's own two checks: the first is
        // implied by the call arriving at all, the second only makes sense from a
        // terminal (section 8).
        var reachable = true
        var unreachableDetail = "no answer on the mach service"
        var data: Data?
        do {
            data = try AgentClient.send(command: "doctor")
        } catch {
            reachable = false
            // "unreachable" and "did not answer in time" are different faults and get
            // different lines: a stalled command used to be reported as the agent being
            // gone (docs/spikes/results.md, 2026-09-04).
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
    func run() throws {
        // The mach lookup itself starts the agent.
        AgentClient.prettyPrint(try AgentClient.send(command: "version"))
    }
}

struct AgentStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")
    func run() throws {
        AgentClient.prettyPrint(try AgentClient.send(command: "agent.stop"))
    }
}

struct AgentRestart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart")
    func run() throws {
        _ = try? AgentClient.send(command: "agent.stop")
        Thread.sleep(forTimeInterval: 1)
        AgentClient.prettyPrint(try AgentClient.send(command: "version"))
    }
}
