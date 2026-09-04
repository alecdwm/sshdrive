import Foundation

/// `posix_spawn` with the three things Foundation's `Process` cannot do and this module
/// needs: an `argv[0]` that differs from the executable path, a child in its own process
/// group, and raw file descriptors for the channel's `ByteStream`.
///
/// `argv[0]` matters because OpenSSH reuses it for any `ProxyJump` hop it builds itself
/// (DESIGN.md section 6.1); the process group matters because the login-shell snapshot
/// has to kill a shell whose rc file left background children behind, and killing our own
/// group would take the agent with it.
public struct SpawnedProcess: @unchecked Sendable {
    public let pid: pid_t
    /// Our end of the child's stdin. -1 when not requested.
    public let stdinFD: Int32
    /// Our end of the child's stdout. -1 when not requested.
    public let stdoutFD: Int32
    /// Our end of the child's stderr. -1 when not requested.
    public let stderrFD: Int32
    public let ownProcessGroup: Bool
}

public struct ProcessExit: Sendable, Equatable {
    public var status: Int32
    public var signal: Int32?
    public var isClean: Bool { signal == nil && status == 0 }
}

public enum Spawn {

    public static func run(
        executable: String,
        argv: [String],
        environment: [String: String],
        wantsStdin: Bool = false,
        wantsStdout: Bool = false,
        wantsStderr: Bool = false,
        stdinFromDevNull: Bool = false,
        newProcessGroup: Bool = false
    ) throws -> SpawnedProcess {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        if wantsStdin, pipe(&inPipe) != 0 { throw ByteStreamError.posix(errno) }
        if wantsStdout, pipe(&outPipe) != 0 { throw ByteStreamError.posix(errno) }
        if wantsStderr, pipe(&errPipe) != 0 { throw ByteStreamError.posix(errno) }

        // Our ends must never raise SIGPIPE: writing a script to a mux client whose
        // socket has just gone is an ordinary, expected EPIPE, not a reason to kill the
        // agent.
        for fd in [inPipe[1], outPipe[0], errPipe[0]] where fd >= 0 {
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if wantsStdin {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
            posix_spawn_file_actions_addclose(&actions, inPipe[0])
            posix_spawn_file_actions_addclose(&actions, inPipe[1])
        } else if stdinFromDevNull {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if wantsStdout {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
            posix_spawn_file_actions_addclose(&actions, outPipe[0])
            posix_spawn_file_actions_addclose(&actions, outPipe[1])
        }
        if wantsStderr {
            posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
            posix_spawn_file_actions_addclose(&actions, errPipe[0])
            posix_spawn_file_actions_addclose(&actions, errPipe[1])
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if newProcessGroup {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
        }

        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for pointer in cArgv where pointer != nil { free(pointer) }
            for pointer in cEnv where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, &cArgv, &cEnv)
        // The child's ends belong to the child now.
        if inPipe[0] >= 0 { close(inPipe[0]) }
        if outPipe[1] >= 0 { close(outPipe[1]) }
        if errPipe[1] >= 0 { close(errPipe[1]) }
        guard result == 0 else {
            if inPipe[1] >= 0 { close(inPipe[1]) }
            if outPipe[0] >= 0 { close(outPipe[0]) }
            if errPipe[0] >= 0 { close(errPipe[0]) }
            throw SSHProcessError.spawnFailed(executable: executable, code: result)
        }
        return SpawnedProcess(
            pid: pid,
            stdinFD: inPipe[1],
            stdoutFD: outPipe[0],
            stderrFD: errPipe[0],
            ownProcessGroup: newProcessGroup
        )
    }

    /// Blocking `waitpid`, for a background thread.
    public static func wait(pid: pid_t) -> ProcessExit {
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) < 0 {
            if errno != EINTR { return ProcessExit(status: -1, signal: nil) }
        }
        return decode(raw)
    }

    /// Non-blocking reap. Nil while the child is still running.
    public static func poll(pid: pid_t) -> ProcessExit? {
        var raw: Int32 = 0
        let result = waitpid(pid, &raw, WNOHANG)
        if result == 0 { return nil }
        if result < 0 { return ProcessExit(status: -1, signal: nil) }
        return decode(raw)
    }

    static func decode(_ raw: Int32) -> ProcessExit {
        if (raw & 0o177) == 0 { return ProcessExit(status: (raw >> 8) & 0xFF, signal: nil) }
        return ProcessExit(status: -1, signal: raw & 0o177)
    }

    /// TERM, then KILL after `grace`, to the process group when the child has its own.
    public static func terminate(_ process: SpawnedProcess, grace: TimeInterval = 2) {
        let target = process.ownProcessGroup ? -process.pid : process.pid
        kill(target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            kill(target, SIGKILL)
        }
    }

    /// Runs to completion, capturing stdout and stderr, with a wall-clock deadline.
    /// Every call in this module has one: nothing here may wait for a server for ever.
    public static func capture(
        executable: String,
        argv: [String],
        environment: [String: String],
        timeout: TimeInterval,
        newProcessGroup: Bool = false
    ) throws -> (exit: ProcessExit, stdout: Data, stderr: Data) {
        let process = try run(
            executable: executable, argv: argv, environment: environment,
            wantsStdout: true, wantsStderr: true,
            stdinFromDevNull: true, newProcessGroup: newProcessGroup
        )
        let lock = NSLock()
        var out = Data(), err = Data()
        let group = DispatchGroup()
        for (fd, isOut) in [(process.stdoutFD, true), (process.stderrFD, false)] {
            group.enter()
            DispatchQueue.global().async {
                var chunk = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n > 0 {
                        lock.lock()
                        if isOut { out.append(contentsOf: chunk[0 ..< n]) } else { err.append(contentsOf: chunk[0 ..< n]) }
                        lock.unlock()
                        continue
                    }
                    if n < 0, errno == EINTR { continue }
                    break
                }
                close(fd)
                group.leave()
            }
        }
        let deadline = DispatchTime.now() + timeout
        var exit: ProcessExit?
        let waiter = DispatchGroup()
        waiter.enter()
        DispatchQueue.global().async {
            let result = Spawn.wait(pid: process.pid)
            lock.lock(); exit = result; lock.unlock()
            waiter.leave()
        }
        if waiter.wait(timeout: deadline) == .timedOut {
            terminate(process, grace: 1)
            _ = waiter.wait(timeout: .now() + 3)
            _ = group.wait(timeout: .now() + 3)
            lock.lock(); let o = out, e = err; lock.unlock()
            throw SSHProcessError.timedOut(command: argv.joined(separator: " "), stdout: o, stderr: e)
        }
        _ = group.wait(timeout: .now() + 5)
        lock.lock(); let o = out, e = err, code = exit ?? ProcessExit(status: -1, signal: nil); lock.unlock()
        return (code, o, e)
    }
}
