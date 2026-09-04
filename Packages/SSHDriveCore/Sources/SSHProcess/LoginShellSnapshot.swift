import Foundation
import Logging

/// `PATH` and `SSH_AUTH_SOCK` as the user's login shell has them (DESIGN.md section 6.1).
///
/// A launchd agent's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and its `SSH_AUTH_SOCK` is
/// the system `ssh-agent`'s, so a 1Password or Secretive socket exported from `.zshrc`,
/// or a `ProxyCommand` that calls `cloudflared` from `/opt/homebrew/bin`, works in a
/// terminal and is invisible to launchd. Only these two variables are taken; nothing else
/// from the shell leaks into `ssh`'s environment.
public struct LoginShellSnapshot: Sendable, Equatable {
    public var shell: String
    public var path: String?
    public var sshAuthSock: String?
    /// csh and tcsh accept `-l` only when it is the sole flag, so those two run `-ic`:
    /// interactive but not login, which reads `.cshrc`/`.tcshrc` and misses a `PATH` set
    /// only in `.login`. `sshdrive doctor` says so when this is true.
    public var interactiveOnly: Bool
    public var takenAt: Date
    public var succeeded: Bool
    /// Why it failed, or what the shell printed in front of the sentinel when it worked.
    public var diagnostic: String?

    public init(shell: String, path: String? = nil, sshAuthSock: String? = nil,
                interactiveOnly: Bool = false, takenAt: Date = Date(),
                succeeded: Bool = false, diagnostic: String? = nil) {
        self.shell = shell
        self.path = path
        self.sshAuthSock = sshAuthSock
        self.interactiveOnly = interactiveOnly
        self.takenAt = takenAt
        self.succeeded = succeeded
        self.diagnostic = diagnostic
    }

    /// The two variables merged over a base environment. When the snapshot failed the base
    /// is used unchanged, which is launchd's, and `sshdrive doctor` says so.
    public func applied(to base: [String: String]) -> [String: String] {
        var out = base
        guard succeeded else { return out }
        if let path { out["PATH"] = path }
        if let sshAuthSock { out["SSH_AUTH_SOCK"] = sshAuthSock } else { out["SSH_AUTH_SOCK"] = nil }
        return out
    }
}

public enum LoginShellSnapshotReader {

    /// From `getpwuid`, not `$SHELL`: a launchd agent's `$SHELL` is not the user's, and a
    /// terminal's may have been changed for that session only.
    public static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/sh"
    }

    static func isCshFamily(_ shell: String) -> Bool {
        let name = (shell as NSString).lastPathComponent
        return name == "csh" || name == "tcsh"
    }

    /// The three commands, in the only spelling every shell parses the same way:
    /// absolute-path commands, `;`, and quoted arguments that contain no variables.
    ///
    /// `env -0` rather than a `printf` of the two variables because the command has to be
    /// valid in every shell: in fish `"$PATH"` expands to the list joined by spaces, not
    /// colons.
    ///
    /// The NULs are printed by their own `printf` rather than embedded in the sentinel's
    /// format string. `printf "\0<sentinel>"` reads `\0` plus the following octal digits
    /// as one character, so a sentinel beginning with a digit loses its first bytes —
    /// measured on macOS 26.4, see section 13.
    public static func snapshotCommand(sentinel: Sentinel) -> String {
        let printf = "/usr/bin/printf"
        let nul = "\(printf) '\\000'"
        let mark = "\(printf) '%s' '\(sentinel.hex)'"
        return "\(nul); \(mark); \(nul); /usr/bin/env -0; \(mark); \(nul)"
    }

    /// Runs the login shell and reads the records between the two sentinels.
    ///
    /// The closing sentinel is what ends the read: EOF is not a reliable end, because an
    /// rc file that leaves a background child holding stdout keeps the pipe open after
    /// `env` has finished, and a reader that waited for EOF would hit the timeout and
    /// throw away a complete answer. Only a snapshot with no closing sentinel by the
    /// timeout counts as failed.
    public static func take(
        shell: String? = nil,
        timeout: TimeInterval = 10,
        sentinel: Sentinel = Sentinel(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> LoginShellSnapshot {
        let shellPath = shell ?? loginShellPath()
        let interactiveOnly = isCshFamily(shellPath)
        let flags = interactiveOnly ? "-ic" : "-ilc"
        var environment = baseEnvironment
        environment["TERM"] = "dumb"

        var snapshot = LoginShellSnapshot(
            shell: shellPath, interactiveOnly: interactiveOnly, takenAt: Date()
        )
        let spawned: SpawnedProcess
        do {
            spawned = try Spawn.run(
                executable: shellPath,
                argv: [shellPath, flags, snapshotCommand(sentinel: sentinel)],
                environment: environment,
                wantsStdout: true,
                // stdin from /dev/null stops an rc file that reads input or execs tmux
                // from hanging until the timeout.
                stdinFromDevNull: true,
                // Its own group, so the kill below reaches the background children an rc
                // file left behind without reaching the agent.
                newProcessGroup: true
            )
        } catch {
            snapshot.diagnostic = "could not run \(shellPath): \(error)"
            return snapshot
        }

        let stream = PipeByteStream(readFD: spawned.stdoutFD, writeFD: -1, label: "login-shell")
        var parser = SentinelParser(sentinel: sentinel)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try await stream.drain(deadline: deadline) { chunk in
                parser.append(chunk)
                return parser.sawClosingSentinel
            }
        } catch {
            // A timeout is a failure; an EOF with a complete answer already parsed is not.
            if !parser.sawClosingSentinel {
                snapshot.diagnostic = "\(shellPath) \(flags): \(error.localizedDescription)"
            }
        }
        stream.close()
        // Kill the group whatever happened: the answer is complete at the closing
        // sentinel and a background child may still be holding the pipe open.
        kill(-spawned.pid, SIGKILL)
        _ = Spawn.wait(pid: spawned.pid)

        guard parser.sawClosingSentinel else {
            if snapshot.diagnostic == nil {
                snapshot.diagnostic = "the login shell produced no closing sentinel within \(Int(timeout)) s"
            }
            Log.ssh.error("login shell snapshot failed: \(snapshot.diagnostic ?? "", privacy: .public)")
            return snapshot
        }
        let environmentRecords = parser.environment
        snapshot.path = environmentRecords["PATH"]
        snapshot.sshAuthSock = environmentRecords["SSH_AUTH_SOCK"]
        snapshot.succeeded = snapshot.path != nil
        if !parser.prefix.isEmpty {
            snapshot.diagnostic = "the login shell printed \(parser.prefix.count) bytes before the sentinel"
        }
        return snapshot
    }
}
