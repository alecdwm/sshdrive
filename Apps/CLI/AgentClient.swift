import Foundation
import Darwin
import XPCProtocols
import Logging

/// The CLI's XPC client. Every command is a request to the agent, so the CLI never
/// touches the network, the keychain or File Provider, and can therefore be invoked
/// through any path, including the Homebrew symlink (DESIGN.md sections 3, 8).
enum AgentClient {

    /// No answer on the mach service: launchd could not start the agent, or the listener
    /// refused the connection (the peer code requirement, section 5.2).
    struct AgentUnavailable: Error, LocalizedError {
        let underlying: Error?
        var errorDescription: String? {
            var text = """
                Cannot reach SSH Drive's background agent.

                If SSH Drive was just installed, launch it once so it can register itself:
                    open -g -a "SSH Drive"

                If it is already installed, the login item may be switched off. Enable
                SSH Drive in System Settings > General > Login Items.
                """
            if let underlying {
                text += "\n\nXPC reported: \(underlying.localizedDescription)"
            }
            return text
        }
    }

    /// The agent accepted the connection and then did not answer in time. A different
    /// thing entirely from being unreachable, and telling the two apart is the whole
    /// point: during S1 a stalled File Provider call made every command report the agent
    /// unreachable while it was in fact alive (docs/spikes/results.md, 2026-09-04).
    struct CommandTimedOut: Error, LocalizedError {
        let command: String
        let seconds: Int
        var errorDescription: String? {
            """
            SSH Drive's background agent accepted the connection but did not answer \
            "\(command)" within \(seconds) seconds.

            The agent is running; the command is still in progress or wedged. See what it
            is doing:
                log show --last 5m --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive"' --style compact

            `sshdrive agent restart` clears a wedged agent.
            """
        }
    }

    /// An error the agent itself returned. Re-wrapped so its message is what the CLI
    /// prints, whatever ArgumentParser would otherwise make of a bridged NSError.
    struct AgentRefused: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How long the CLI waits for a reply. The agent bounds its own File Provider calls
    /// at 20 s (Apps/Agent/Deadline.swift), so a command that runs past this one is
    /// wedged somewhere else.
    static let timeoutSeconds: Double = 30

    /// Sends one command and waits for the JSON reply.
    ///
    /// If the mach lookup fails because no login item is registered yet (a fresh install
    /// whose postflight did not run) the CLI launches the bundle it lives in with
    /// `open -g` once, as the postflight does, waits for the service, and retries
    /// (section 8).
    /// stdout is *fully* buffered when it is a pipe, which is what a transcript, a
    /// `script -q` run and every CI invocation are. The agent writes the collect
    /// connection's prompts through the file handle so `ssh`'s question reaches the
    /// terminal before the read blocks on it, and a buffered `print` from a command's own
    /// report would then land out of order behind it. Unbuffered costs nothing here:
    /// the CLI prints tens of lines, not thousands.
    private static let unbufferedStdout: Void = { setvbuf(stdout, nil, _IONBF, 0) }()

    static func send(
        command: String, arguments: [String: String] = [:], allowRelaunch: Bool = true,
        timeout: Double = AgentClient.timeoutSeconds
    ) throws -> Data {
        _ = unbufferedStdout
        do {
            return try sendOnce(command: command, arguments: arguments, timeout: timeout)
        } catch let error as AgentUnavailable {
            // Only an unreachable agent is worth relaunching the bundle for; a command
            // that timed out reached an agent that is already running.
            guard allowRelaunch, launchOwnBundle() else { throw error }
            return try sendOnce(command: command, arguments: arguments, timeout: timeout)
        }
    }

    /// `add`, `passwd` and a `set` that re-keys the secrets run a collect connection with
    /// prompts relayed to this terminal (section 4.2), so the reply can legitimately be
    /// minutes away: the agent is waiting on a person, and the person is waiting on the
    /// server. The broker's own collect deadline (300 s) is what actually bounds it.
    static let interactiveTimeoutSeconds: Double = 900

    private static func sendOnce(
        command: String, arguments: [String: String], timeout: Double
    ) throws -> Data {
        let connection = NSXPCConnection(
            machServiceName: SSHDriveIdentifiers.machServiceName, options: [])
        connection.remoteObjectInterface = SSHDriveXPCInterface.agent
        // The terminal, for the length of this command and no longer. The agent calls back
        // on it only while a command of ours is in flight (section 4.2).
        connection.exportedInterface = SSHDriveXPCInterface.cli
        connection.exportedObject = PromptService()
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(AgentUnavailable(underlying: nil))

        // Only a failure to *reach* the service lands here: a mach lookup that found
        // nothing, a listener that refused the peer, or a connection that went away.
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            result = .failure(AgentUnavailable(underlying: error))
            semaphore.signal()
        } as? SSHDriveAgentProtocol

        guard let proxy else { throw AgentUnavailable(underlying: nil) }

        var answered = false
        proxy.control(command: command, arguments: arguments) { data, error in
            answered = true
            if let data {
                result = .success(data)
            } else if let error {
                // The agent flattens its errors before sending them, so the description
                // is in the NSError's userInfo and survives the trip (section 5.2,
                // sshDriveXPCError).
                result = .failure(AgentRefused(message: error.localizedDescription))
            } else {
                result = .failure(AgentUnavailable(underlying: nil))
            }
            semaphore.signal()
        }

        // Long enough for a cold launchd start, short enough that a wedged agent does not
        // hang a terminal forever. Running out of it is *not* an unreachable agent: the
        // connection was made and the message was delivered, so say so instead.
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if answered { return try result.get() }
            throw CommandTimedOut(command: command, seconds: Int(timeout))
        }
        return try result.get()
    }

    /// Launching the app is what registers both the extension with PlugInKit and the
    /// login item through SMAppService, and both must be done from the app's own bundle,
    /// which a symlinked CLI cannot do (section 10).
    private static func launchOwnBundle() -> Bool {
        // The CLI lives at <bundle>/Contents/MacOS/sshdrive, so the bundle is three
        // levels up from the executable, whatever symlink was used to reach it.
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        let bundle = executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // SSH Drive.app
        guard bundle.pathExtension == "app" else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", bundle.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        // The app registers, pokes the service and exits; launchd needs a moment.
        Thread.sleep(forTimeInterval: 2)
        return process.terminationStatus == 0
    }

    /// Decodes a reply into a dictionary, for printing.
    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func prettyPrint(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
