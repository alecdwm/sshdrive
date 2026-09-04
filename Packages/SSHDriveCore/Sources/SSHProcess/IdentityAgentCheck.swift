import Foundation
import Logging

/// The pre-spawn key-agent socket check (DESIGN.md section 6.1).
///
/// `agent refused operation` on stderr is what 1Password and Secretive produce between
/// login and their first unlock. A socket that does not exist yet, because the key
/// agent's app has not launched, is worse: `ssh` logs that only at debug level, so at
/// `LogLevel=ERROR` the failure reads as a plain "Permission denied (publickey)", which
/// would stop reconnection on exactly the morning this exception exists for. So the agent
/// does not rely on stderr for it: before every spawn for an `agentDependent` location it
/// connects to the socket itself, and a missing or refusing socket is a transient failure
/// with `ssh` never run at all.
public enum IdentityAgentCheck {

    public enum Result: Sendable, Equatable {
        /// The socket accepted a connection, or there is nothing to check because the
        /// location does not depend on a key agent.
        case ok
        /// No socket at that path: the key agent's app has not launched.
        case missing(String)
        /// The path exists but will not accept a connection.
        case refusing(String, errno: Int32)

        public var isTransientFailure: Bool { self != .ok }
    }

    /// Which socket to check. `ssh -G` prints `identityagent` with `~` already expanded;
    /// only when that is unset or reads `SSH_AUTH_SOCK` does the snapshot's variable
    /// apply. 1Password and Secretive both document their setup as an `IdentityAgent`
    /// line in `~/.ssh/config`, so for most agent-dependent locations `SSH_AUTH_SOCK`
    /// still names Apple's `ssh-agent`, which is always there and would make the check
    /// pass while the agent that actually holds the key was absent.
    public static func socketPath(
        resolvedIdentityAgent: String?,
        snapshot: LoginShellSnapshot?
    ) -> String? {
        let resolved = resolvedIdentityAgent?.trimmingCharacters(in: .whitespaces)
        if let resolved, !resolved.isEmpty {
            if resolved.lowercased() == "none" { return nil }
            if resolved != "SSH_AUTH_SOCK" && resolved != "$SSH_AUTH_SOCK" { return resolved }
        }
        return snapshot?.sshAuthSock
    }

    /// Connects to the socket. Nothing is sent: an accepted connection is the whole answer.
    public static func probe(_ path: String?) -> Result {
        guard let path, !path.isEmpty else { return .ok }
        guard FileManager.default.fileExists(atPath: path) else { return .missing(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .refusing(path, errno: errno) }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return .refusing(path, errno: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.baseAddress?.copyMemory(from: bytes, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let code = errno
            Log.ssh.error("identity agent socket \(path, privacy: .public) refused: \(code)")
            return .refusing(path, errno: code)
        }
        return .ok
    }
}
