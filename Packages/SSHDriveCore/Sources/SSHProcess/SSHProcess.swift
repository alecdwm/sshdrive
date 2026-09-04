import Foundation
import Config
import Logging

/// Spawns and supervises `ssh` (DESIGN.md section 6.1).
///
/// The module's pieces: `SSHCommandBuilder` assembles every command line, `ProxyChainBuilder`
/// rebuilds a `ProxyJump` chain as the agent's own `ProxyCommand`, `SSHMaster` runs the
/// `-N` ControlMaster and opens mux clients on its socket, `RemoteScript` is the `sh -s`
/// script with the section 9.2 sentinel and the section 6.4 heartbeat wrapper,
/// `LoginShellSnapshot` takes `PATH` and `SSH_AUTH_SOCK` from the user's login shell, and
/// `SSHExitClassifier` says what an exit means.
public enum SSHProcess {
    /// The transport is the system's ssh, spawned by absolute path and never resolved
    /// through PATH (section 6.1). `argv[0]` is set to this same string, so a ProxyJump
    /// hop that ssh would build itself cannot be found through PATH either.
    public static let sshBinaryPath = "/usr/bin/ssh"

    /// The keywords the agent always overrides, whatever the user's config says
    /// (section 6.1). `sshdrive show` prints any of these the config would have applied.
    public static var alwaysOverriddenKeywords: [String] { SSHCommandBuilder.Overrides.all }

    /// `/usr/bin/ssh -V`, for `sshdrive doctor` and `sshdrive show`.
    public static func sshVersion() -> String? {
        guard let result = try? Spawn.capture(
            executable: sshBinaryPath, argv: [sshBinaryPath, "-V"],
            environment: ProcessInfo.processInfo.environment, timeout: 10
        ) else {
            Log.ssh.error("cannot run \(sshBinaryPath, privacy: .public)")
            return nil
        }
        // ssh -V writes to stderr.
        let text = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The login shell snapshot: `PATH` and `SSH_AUTH_SOCK` as a fresh login shell has
    /// them (section 6.1).
    public static func loginShellSnapshot(timeout: TimeInterval = 10) async -> LoginShellSnapshot {
        await LoginShellSnapshotReader.take(timeout: timeout)
    }

    /// `ssh -G <host>` and the diff against `ssh -F /dev/null -G <host>` that attributes
    /// each value to the config (section 4.1).
    public static func resolveConfiguration(
        for location: Location,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SSHConfigAttribution {
        try SSHConfigResolver.attribution(target: target(for: location), environment: environment)
    }

    /// The location's stored overrides as a spawn target. A location that passed the
    /// collect connection's first pass runs `IdentityAgent=none` for good; only an
    /// `agentDependent` location ever consults a key agent (section 4.2).
    public static func target(for location: Location) -> SSHTarget {
        SSHTarget(
            host: location.host,
            user: location.user,
            port: location.port,
            identityFile: location.identityFile,
            sshOptions: location.sshOptions,
            identityAgentNone: !location.agentDependent
        )
    }

    /// The whole pre-spawn preparation for a location: resolve, refuse to hand `ssh` a
    /// `ProxyJump`, build our own chain instead, and check the key agent's socket when the
    /// location depends on one.
    public static func masterConfiguration(
        for location: Location,
        environment: [String: String],
        snapshot: LoginShellSnapshot? = nil
    ) throws -> SSHMaster.Configuration {
        let target = target(for: location)
        let resolution = try SSHConfigResolver.resolve(target: target, environment: environment)
        let hops = try resolution.jumpChain()
        let proxyCommand = ProxyChainBuilder.proxyCommand(
            for: hops, identityAgentNone: target.identityAgentNone
        )
        let socket = location.agentDependent
            ? IdentityAgentCheck.socketPath(
                resolvedIdentityAgent: resolution.identityAgent, snapshot: snapshot)
            : nil
        return SSHMaster.Configuration(
            locationID: location.id,
            target: target,
            environment: environment,
            agentDependent: location.agentDependent,
            proxyCommand: proxyCommand,
            identityAgentSocket: socket
        )
    }
}
