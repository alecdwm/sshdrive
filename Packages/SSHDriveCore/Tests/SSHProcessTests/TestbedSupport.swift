import Foundation
import XCTest
@testable import SSHProcess
import XPCProtocols

/// Shared scaffolding for the integration tests, which run only against the spike testbed
/// (`testbed/README.md`) and only from the build VM, where `192.168.64.1` is the Mac's
/// vmnet gateway. Everything here is inert without `SSHDRIVE_TESTBED=1`.
enum Testbed {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SSHDRIVE_TESTBED"] == "1" }

    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(enabled, "set SSHDRIVE_TESTBED=1 on the build VM to run this")
    }

    /// launchd's environment stands in for the agent's here; the login shell snapshot is
    /// applied by the caller where a test needs it.
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The stub askpass the two-hop tests arm, written into the test's own temp dir.
    /// The real one is `sshdrive-askpass` with the token protocol of section 4.2, which
    /// is the Secrets module's half of milestone 2.
    struct StubAskpass {
        let directory: URL
        let scriptPath: String
        let logPath: String

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sshdrive-askpass-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scriptPath = directory.appendingPathComponent("askpass.sh").path
            logPath = directory.appendingPathComponent("prompts.log").path
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(logPath)'
            case "$1" in
              *bastion-b*)  echo spike-password-b ;;
              *hop@*)       echo spike-password-a ;;
              *passphrase*) echo spike-passphrase ;;
              *)            echo spike-password ;;
            esac
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptPath
            )
            FileManager.default.createFile(atPath: logPath, contents: Data())
        }

        /// `SSH_ASKPASS_REQUIRE=force` is what makes ssh use the program with no tty and
        /// no DISPLAY (section 4.2).
        var variables: [String: String] {
            [
                AskpassEnvironment.askpassVariable: scriptPath,
                AskpassEnvironment.requireVariable: AskpassEnvironment.requireForce,
            ]
        }

        var prompts: [String] {
            (try? String(contentsOfFile: logPath, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }

        func resetLog() { FileManager.default.createFile(atPath: logPath, contents: Data()) }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A master for one testbed alias, with a control path of its own so concurrent tests
    /// never share a socket.
    static func master(
        host: String,
        user: String? = nil,
        environment extra: [String: String] = [:],
        agentDependent: Bool = false
    ) throws -> SSHMaster {
        var environment = Testbed.environment
        for (key, value) in extra { environment[key] = value }
        let target = SSHTarget(host: host, user: user, identityAgentNone: !agentDependent)
        let resolution = try SSHConfigResolver.resolve(target: target, environment: environment)
        let proxyCommand = ProxyChainBuilder.proxyCommand(
            for: try resolution.jumpChain(), identityAgentNone: !agentDependent
        )
        return SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: target,
            environment: environment,
            agentDependent: agentDependent,
            proxyCommand: proxyCommand
        ))
    }

    /// Reads a channel's whole payload up to a deadline, returning what arrived. Every
    /// read has a deadline, harnesses included: `bashbg` never sends EOF.
    static func read(
        _ channel: ExecChannel, until terminator: UInt8 = 0, timeout: TimeInterval = 20
    ) async throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = try await channel.stream.read(upTo: 64 * 1024, deadline: deadline)
            if chunk.isEmpty { break }
            out.append(chunk)
            if out.contains(terminator) { break }
        }
        return out
    }

    /// Runs one `sh -s` script on a fresh exec channel and returns its payload.
    static func runScript(
        on master: SSHMaster, body: String, arguments: [String] = [],
        timeout: TimeInterval = 30
    ) async throws -> (payload: Data, prefix: Data) {
        let script = RemoteScript(arguments: arguments, body: body)
        let channel = try await master.openExecChannel(script: script, readinessDeadline: timeout)
        defer { channel.close() }
        let payload = try await read(channel, timeout: timeout)
        return (payload, channel.prefix)
    }

    /// The testbed's `-W` children outlive a killed parent, exactly as section 6.1 says
    /// our own masters' do. Ours are recognisable by `ControlPath=none`, which only a hop
    /// carries.
    static func reapHopChildren() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "ControlPath=none"]
        try? process.run()
        process.waitUntilExit()
    }
}
