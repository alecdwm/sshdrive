import Foundation
import Logging

/// The mux socket path and the orphan sweep (DESIGN.md section 6.1).
public enum ControlSocket {
    public static let namePrefix = "sshdrive-"

    /// `$TMPDIR` means the directory `confstr(_CS_DARWIN_USER_TEMP_DIR)` returns, read
    /// directly rather than from the environment, since a launchd agent's environment is
    /// not guaranteed to carry it.
    public static func temporaryDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 0, length <= buffer.count {
            let path = String(cString: buffer)
            if !path.isEmpty { return (path as NSString).standardizingPath }
        }
        return NSTemporaryDirectory()
    }

    /// `$TMPDIR/sshdrive-<id8>`, the first eight hex digits of the location id, and
    /// deliberately not `%C`: `%C` hashes user, host and port, so two locations on one
    /// host would compute the same socket path and the second master would find it, print
    /// "ControlSocket already exists, disabling multiplexing", and let its mux clients
    /// attach to the first location's connection. Length is the other reason - a Unix
    /// socket path is limited to 104 bytes, `$TMPDIR` on macOS is about 50, and `ssh`
    /// binds under a temporary `<path>.<pid>` name before renaming.
    public static func path(forLocationID id: String) -> String {
        let hex = id.lowercased().filter { $0.isHexDigit }
        let short = String(hex.prefix(8))
        return (temporaryDirectory() as NSString)
            .appendingPathComponent("\(namePrefix)\(short.isEmpty ? "0" : short)")
    }

    /// Every `sshdrive-*` socket in `$TMPDIR`, including the `<path>.<pid>` names `ssh`
    /// leaves behind when it dies between bind and rename.
    public static func existingSockets() -> [String] {
        let directory = temporaryDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return entries.filter { $0.hasPrefix(namePrefix) }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// Run before the agent's first connection. If the agent crashed, its `ssh -N`
    /// children live on with their sockets in place, and `ControlMaster=yes` against an
    /// existing socket disables multiplexing and leaves later mux clients attaching to
    /// the orphan. So: `-O exit` against every socket, then unlink whatever is left.
    /// Orphans are not adopted.
    @discardableResult
    public static func sweepOrphans(environment: [String: String]) -> [String] {
        var swept: [String] = []
        for socket in existingSockets() {
            let invocation = SSHCommandBuilder.control("exit", controlPath: socket, host: "sshdrive-orphan")
            _ = try? Spawn.capture(
                executable: invocation.executable, argv: invocation.argv,
                environment: environment, timeout: 5
            )
            if FileManager.default.fileExists(atPath: socket) {
                try? FileManager.default.removeItem(atPath: socket)
            }
            swept.append(socket)
            Log.ssh.info("swept orphan control socket \(socket, privacy: .public)")
        }
        return swept
    }

    /// The location's socket is unlinked before every spawn, not only at startup: a master
    /// that died without `-O exit` leaves its socket behind, and `ssh` moves a new socket
    /// into place with `link`, which fails on an existing path and silently disables
    /// multiplexing for that connection.
    public static func unlink(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
