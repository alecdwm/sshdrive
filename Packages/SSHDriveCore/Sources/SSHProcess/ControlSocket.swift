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

    /// Every `sshdrive-*` **socket** in `$TMPDIR`, including the `<path>.<pid>` names `ssh`
    /// leaves behind when it dies between bind and rename.
    ///
    /// The name alone is not enough: `$TMPDIR` is a shared directory and the prefix is not
    /// ours exclusively - the package's own tests write `sshdrive-nested-<uuid>.sqlite`
    /// there, and its `-wal` and `-shm` sidecars were counted as six orphaned control
    /// sockets by `sshdrive doctor`, which reported a healthy install as failing
    /// (2026-09-04). So the type is checked too: `S_IFSOCK` with `lstat`, never following
    /// a link, and a non-socket with our prefix is left alone rather than deleted.
    public static func existingSockets() -> [String] {
        let directory = temporaryDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return entries.filter { $0.hasPrefix(namePrefix) }
            .map { (directory as NSString).appendingPathComponent($0) }
            .filter { isSocket($0) }
    }

    /// `lstat` rather than `stat`: a symlink at that name is not our socket, and following
    /// it would let anything in a shared directory decide what we unlink (section 9.1).
    public static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Run before the agent's first connection. If the agent crashed, its `ssh -N`
    /// children live on with their sockets in place, and `ControlMaster=yes` against an
    /// existing socket disables multiplexing and leaves later mux clients attaching to
    /// the orphan. So: ask each socket who owns it, `-O exit`, unlink whatever is left,
    /// and **kill the owner if it is still there**. Orphans are not adopted.
    ///
    /// The kill is not belt and braces. `-O exit` reaches a master through the socket, so
    /// a master whose socket has already been unlinked - or one that has stopped serving
    /// it - cannot be asked to leave at all, and unlinking the socket only makes it
    /// unreachable: the `ssh` stays, holding a TCP connection to the server, a mux client
    /// or two, and its share of the server's `MaxSessions`, for ever. Milestone 7/8 left
    /// one behind on four install cycles out of four (docs/spikes/results.md, 2026-09-05).
    /// So the sweep takes the pid `-O check` prints, and if that process is still alive
    /// after the exit request it gets a TERM and then, a moment later, a KILL.
    @discardableResult
    public static func sweepOrphans(environment: [String: String]) -> [String] {
        var swept: [String] = []
        for socket in existingSockets() {
            let owner = masterPID(socket: socket, environment: environment)
            let invocation = SSHCommandBuilder.control("exit", controlPath: socket, host: "sshdrive-orphan")
            _ = try? Spawn.capture(
                executable: invocation.executable, argv: invocation.argv,
                environment: environment, timeout: 5
            )
            if FileManager.default.fileExists(atPath: socket) {
                try? FileManager.default.removeItem(atPath: socket)
            }
            if let owner, terminate(pid: owner) {
                Log.ssh.notice(
                    "killed the ssh master \(owner, privacy: .public) that owned orphaned socket \(socket, privacy: .public)"
                )
            }
            swept.append(socket)
            Log.ssh.info("swept orphan control socket \(socket, privacy: .public)")
        }
        return swept
    }

    /// `ssh -O check` answers `Master running (pid=NNNN)` on stderr, which is the only
    /// route from a socket to the process that owns it: the socket carries no credentials
    /// we can read and `lsof` is not something to shell out to on every start.
    public static func masterPID(socket: String, environment: [String: String]) -> pid_t? {
        let invocation = SSHCommandBuilder.control("check", controlPath: socket, host: "sshdrive-orphan")
        guard let result = try? Spawn.capture(
            executable: invocation.executable, argv: invocation.argv,
            environment: environment, timeout: 5
        ) else { return nil }
        let text = String(decoding: result.stderr, as: UTF8.self)
            + String(decoding: result.stdout, as: UTF8.self)
        return parseMasterPID(text)
    }

    /// Pulled out so the parse is testable without an `ssh`.
    public static func parseMasterPID(_ text: String) -> pid_t? {
        guard let range = text.range(of: "pid=") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int32(digits), value > 1 else { return nil }
        return pid_t(value)
    }

    /// TERM, then KILL if it is still there half a second later. Returns whether a signal
    /// was actually delivered to a live process.
    ///
    /// The pid is checked against the process's own name first. A pid read from a socket
    /// that has been sitting in `$TMPDIR` since the last boot can have been reused by
    /// anything, and the sweep must never signal a stranger; `ssh` is the only name we
    /// ever start on that socket.
    @discardableResult
    public static func terminate(pid: pid_t, isLiveSSH: (pid_t) -> Bool = ControlSocket.isLiveSSH)
        -> Bool
    {
        guard isLiveSSH(pid) else { return false }
        guard kill(pid, SIGTERM) == 0 else { return false }
        for _ in 0 ..< 10 {
            usleep(50_000)
            if kill(pid, 0) != 0 { return true }
        }
        if isLiveSSH(pid) { _ = kill(pid, SIGKILL) }
        return true
    }

    /// `KERN_PROC_PID` rather than `ps`: no subprocess, and the answer is the kernel's.
    public static func isLiveSSH(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return name == "ssh"
    }

    /// Every live `ssh` of ours, found by its command line rather than by a socket.
    ///
    /// The socket-based sweep above cannot see a master whose socket is already gone, and
    /// that is not a hypothetical: a location that was restarted can hold **two** masters -
    /// the second finds the first's socket in place, prints "ControlSocket already exists,
    /// disabling multiplexing" and runs without one - and `SSHMaster.shutdown()` unlinks
    /// the path on the way out, so a master the agent lost track of is left with no socket
    /// at all. Two of them survived an `agent stop` on 2026-09-05 for exactly that reason.
    ///
    /// The match is deliberately tight: a process named `ssh`, owned by this uid, whose
    /// argv contains `ControlPath=<our $TMPDIR>/sshdrive-`. `$TMPDIR` is per-user and
    /// per-boot, and nothing else writes that option, so this cannot reach a terminal's
    /// own `ssh`.
    public static func liveMasterPIDs() -> [pid_t] {
        let needle = "ControlPath=\((temporaryDirectory() as NSString).appendingPathComponent(namePrefix))"
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let found = size / MemoryLayout<kinfo_proc>.stride

        var pids: [pid_t] = []
        for index in 0 ..< min(found, procs.count) {
            var entry = procs[index]
            let pid = entry.kp_proc.p_pid
            guard pid > 1 else { continue }
            let name = withUnsafeBytes(of: &entry.kp_proc.p_comm) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard name == "ssh" else { continue }
            if commandLine(of: pid)?.contains(needle) == true { pids.append(pid) }
        }
        return pids
    }

    /// `KERN_PROCARGS2`, the same call askpass uses to read its parent `ssh`'s argv
    /// (section 4.2). Returned as one string with NULs turned into spaces, because all
    /// this needs is a substring test.
    static func commandLine(of pid: pid_t) -> String? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let bytes = buffer.prefix(size).dropFirst(4)  // argc
        return String(decoding: bytes.map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
    }

    /// Kill every `ssh` of ours that is still running. Safe **only** where nothing of ours
    /// is meant to be connected: the agent's start, before the first connection, and its
    /// exit, after every transport has been shut down.
    @discardableResult
    public static func killStrayMasters() -> [pid_t] {
        var killed: [pid_t] = []
        for pid in liveMasterPIDs() where terminate(pid: pid) {
            killed.append(pid)
            Log.ssh.notice("killed stray ssh master \(pid, privacy: .public)")
        }
        return killed
    }

    /// The location's socket is unlinked before every spawn, not only at startup: a master
    /// that died without `-O exit` leaves its socket behind, and `ssh` moves a new socket
    /// into place with `link`, which fails on an existing path and silently disables
    /// multiplexing for that connection.
    public static func unlink(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
