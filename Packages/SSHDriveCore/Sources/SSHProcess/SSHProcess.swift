import Foundation
import Config
import Logging

/// Spawns and supervises `ssh` (DESIGN.md section 6.1).
///
/// TODO milestone 2 (Transport): everything below is a stub. The real module owns the
/// `-N` ControlMaster with `ControlPersist=no`, the mux clients that run with
/// `-F /dev/null`, `BatchMode=yes` and `ProxyCommand=/usr/bin/false`, the ProxyJump chain
/// the agent builds itself as a ProxyCommand, the login shell snapshot taken through
/// `env -0` between two sentinels, the fixed override set, the 60 s authentication
/// deadline and its re-arm, and the askpass token protocol of section 4.2.
public enum SSHProcess {
    /// The transport is the system's ssh, spawned by absolute path and never resolved
    /// through PATH (section 6.1). `argv[0]` is set to this same string, so a ProxyJump
    /// hop that ssh would build itself cannot be found through PATH either.
    public static let sshBinaryPath = "/usr/bin/ssh"

    /// The keywords the agent always overrides, whatever the user's config says
    /// (section 6.1). Listed here in milestone 1 so the doctor check and the design stay
    /// in step; nothing applies them yet.
    public static let alwaysOverriddenKeywords = [
        "ControlMaster", "ControlPath", "ControlPersist",
        "ConnectTimeout", "ServerAliveInterval", "ServerAliveCountMax",
        "UpdateHostKeys",
        "RemoteCommand", "RequestTTY", "StdinNull", "ForkAfterAuthentication",
        "BatchMode", "PermitLocalCommand", "ForwardAgent",
    ]

    /// `/usr/bin/ssh -V`, for `sshdrive doctor` and `sshdrive show`. This is the one
    /// piece of section 6.1 milestone 1 needs, because doctor reports the ssh version.
    public static func sshVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshBinaryPath)
        process.arguments = ["-V"]
        let pipe = Pipe()
        // ssh -V writes to stderr.
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            Log.ssh.error("cannot run \(sshBinaryPath, privacy: .public): \(error, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// TODO milestone 2: the login shell snapshot. A launchd agent does not get the
    /// user's shell environment, so PATH and SSH_AUTH_SOCK are taken from `env -0`
    /// between two sentinels in a login shell (section 6.1).
    public static func loginShellSnapshot() throws -> [String: String] {
        throw SSHProcessError.notImplemented(milestone: 2)
    }

    /// TODO milestone 2: `ssh -G <host>`, and the diff against `ssh -F /dev/null -G <host>`
    /// that attributes each value to the config (section 4.1).
    public static func resolveConfiguration(for location: Location) throws -> [String: String] {
        throw SSHProcessError.notImplemented(milestone: 2)
    }
}

public enum SSHProcessError: Error, LocalizedError {
    case notImplemented(milestone: Int)

    public var errorDescription: String? {
        switch self {
        case let .notImplemented(milestone):
            return "Not implemented until milestone \(milestone)."
        }
    }
}
