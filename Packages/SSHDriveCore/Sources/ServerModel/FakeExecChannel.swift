import Foundation
import SSHProcess

/// An exec channel whose remote end is **a real POSIX shell on this Linux box**.
///
/// The shell scripts are tested against real shells, which is the deliberate design
/// choice of the whole harness (docs/design/testing.md): the `;;` dash rejects
/// (`SQ-018`), the `{ … }` group the heartbeat reader would otherwise eat, and the
/// `printf "\0<sentinel>"` that eats its own sentinel (`SQ-020`) are all reachable here.
///
/// The channel picks the profile's shell, puts the profile's rc-file noise in front of the
/// sentinel (`SQ-015`), leaves a background child holding stdout where the profile says so
/// (`SQ-016`), answers with the `ForceCommand` refusal where the profile has one
/// (`SQ-013`), enforces `MaxSessions` (`SQ-021`), and models the session's process-group
/// policy with a **real** shared or private pgid, so `kill -TERM 0` really does or does
/// not reach a bystander (`SQ-010`, `SQ-012`).
///
/// It exposes the same `SSHProcess.ByteStream` a mux client's stdio does, so `RemoteScript`,
/// `Sentinel`/`SentinelParser`, the heartbeat wrapper, `SweepPlan`'s script and the
/// helper's NDJSON reader all run **unmodified**.
public final class FakeExecChannel: @unchecked Sendable {

    public let stream: PipeByteStream
    /// What the account printed before the sentinel, which `status` shows.
    public let prefix: Data
    public let sentinel: Sentinel
    public let pid: pid_t
    /// The process group the session was put in. Equal to `pid` under sshd's policy
    /// (`SQ-012`); the daemon's under Tailscale SSH's (`SQ-010`).
    public let processGroup: pid_t

    private let process: SpawnedProcess
    private let onClose: @Sendable () -> Void
    private var closed = false
    private let closeLock = NSLock()

    init(stream: PipeByteStream, prefix: Data, sentinel: Sentinel, process: SpawnedProcess,
         processGroup: pid_t, onClose: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.prefix = prefix
        self.sentinel = sentinel
        self.process = process
        self.pid = process.pid
        self.processGroup = processGroup
        self.onClose = onClose
    }

    /// One heartbeat line. The agent writes one every 15 s; 60 s of silence, or EOF, and
    /// the wrapper on the server kills its child (docs/design/change-detection.md).
    public func sendHeartbeat() async throws {
        try await stream.write(RemoteScript.heartbeatLine)
    }

    /// Closes stdin, which the wrapper reads as EOF and treats exactly as a dead agent.
    public func endInput() { stream.closeWrite() }

    /// What an abrupt client kill looks like from the server's side: the mux client is
    /// gone, the channel's pipes are gone, and sshd reaps the *session* - which does not
    /// reach a child that has left the foreground job (`SQ-008`, `SQ-009`).
    public func killClientAbruptly() {
        kill(process.pid, SIGKILL)
        stream.close()
        markClosed()
    }

    public func exitStatus() -> ProcessExit? { Spawn.poll(pid: process.pid) }
    public func waitForExit() -> ProcessExit { Spawn.wait(pid: process.pid) }

    public func close() {
        stream.close()
        Spawn.terminate(process, grace: 1)
        markClosed()
    }

    private func markClosed() {
        closeLock.lock()
        let first = !closed
        closed = true
        closeLock.unlock()
        if first { onClose() }
    }

    /// Reads the payload up to a deadline, returning what arrived. Every read has a
    /// deadline, harnesses included: `bashbg` never sends EOF (`SQ-016`).
    public func readPayload(
        until terminatorCount: Int = 1, timeout: TimeInterval = 20
    ) async throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk: Data
            do {
                chunk = try await stream.read(upTo: 64 * 1024, deadline: deadline)
            } catch ByteStreamError.readTimedOut {
                break
            }
            if chunk.isEmpty { break }
            out.append(chunk)
            if out.filter({ $0 == 0 }).count >= terminatorCount { break }
        }
        return out
    }
}

/// The simulated sshd: it owns the session budget and the process-group policy, and it is
/// what opens an exec channel.
///
/// One per server, exactly as one sshd serves one host. `MaxSessions` is counted across
/// the channels it has open (`SQ-021`), and nothing here ever reaps an orphan, because
/// nothing measured ever did (`SQ-008`, `SQ-009`).
public final class FakeSSHD: @unchecked Sendable {

    public let profile: ServerProfile
    /// Where the generated rc files and shell wrappers live. Removed by `shutdown()`.
    public let directory: URL

    private let lock = NSLock()
    private var openSessions = 0
    /// The session the master itself occupies. sshd counts the master's own session
    /// against `MaxSessions`, which is why `MaxSessions 2` leaves exactly one spare
    /// beside the metadata SFTP channel (`SQ-021`).
    private var reservedSessions: Int
    private var groupLeader: SpawnedProcess?

    public init(profile: ServerProfile, reservedSessions: Int = 0) throws {
        self.profile = profile
        self.reservedSessions = reservedSessions
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-servermodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { shutdown() }

    public var sessionsInUse: Int { lock.withLock { openSessions + reservedSessions } }
    public var spareSessions: Int { max(0, profile.maxSessions - sessionsInUse) }

    /// Why this profile cannot be run on this box, or nil.
    ///
    /// A scenario that needs a shell the box does not have **skips with a named reason
    /// rather than pretending** (docs/design/testing.md).
    public static func unavailabilityReason(for profile: ServerProfile) -> String? {
        switch profile.loginShell {
        case .fish:
            return "fish is not installed on this box; the fish rc-noise row is skipped, not faked"
        case .tcsh:
            return "tcsh is not installed on this box; the tcsh rc-noise row is skipped, not faked"
        case .zsh:
            return ScriptShell.zsh.isAvailable ? nil : ScriptShell.zsh.skipReason
        case .bashQuiet, .bashNoisy, .bashBackgroundHolder:
            return ScriptShell.bash.isAvailable ? nil : ScriptShell.bash.skipReason
        case .busyboxAsh:
            return ScriptShell.busyboxAsh.isAvailable ? nil : ScriptShell.busyboxAsh.skipReason
        case .dash, .none:
            return ScriptShell.dash.isAvailable ? nil : ScriptShell.dash.skipReason
        }
    }

    /// Opens an exec channel: `sh -s` with the script on stdin, and the read that discards
    /// everything up to and including the sentinel (docs/design/security.md).
    ///
    /// Every refusal here is one `ssh` really prints:
    /// - over `MaxSessions`, the mux client's `mux_client_request_session: session request
    ///   failed` with CRLF line endings (`SQ-021`, `SQ-035`);
    /// - a `ForceCommand internal-sftp` account, the plain sentence or SFTP framing
    ///   (`SQ-013`).
    public func openExecChannel(
        script: RemoteScript,
        readinessDeadline: TimeInterval = 20
    ) async throws -> FakeExecChannel {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw ServerModelUnavailable(reason: reason)
        }
        lock.lock()
        let used = openSessions + reservedSessions
        guard used < profile.maxSessions else {
            lock.unlock()
            throw SSHProcessError.channelFailed(
                classification: .channelLimitReached,
                stderr: OpenSSHPrompts.sessionRefused + "\r\n")
        }
        openSessions += 1
        lock.unlock()

        func release() { lock.withLock { openSessions -= 1 } }

        // `SQ-013`: a ForceCommand account answers an exec channel with a plain sentence
        // or with SFTP framing, never with a shell.
        if let forceCommand = profile.forceCommand {
            release()
            let refusal: Data
            switch forceCommand {
            case .internalSFTP:
                refusal = Data(OpenSSHPrompts.forceCommandSentence.utf8)
            case .internalSFTPFraming:
                // An SSH_FXP_VERSION packet: length 5, type 2, version 3.
                refusal = Data([0, 0, 0, 5, 2, 0, 0, 0, 3])
            }
            throw ForceCommandRefusal(bytes: refusal)
        }

        let invocation = try shellInvocation()
        let group = try processGroupPolicy()
        let spawned = try Spawn.run(
            executable: invocation.executable,
            argv: invocation.argv,
            environment: invocation.environment,
            wantsStdin: true, wantsStdout: true, wantsStderr: true,
            newProcessGroup: group == nil,
            joinProcessGroup: group
        )
        let stream = PipeByteStream(readFD: spawned.stdoutFD, writeFD: spawned.stdinFD,
                                    label: "servermodel-exec")
        do {
            if !invocation.stdinPreamble.isEmpty {
                try await stream.write(Data(invocation.stdinPreamble.utf8))
            }
            // The whole script in a single write, exactly as `SSHMaster` does it: dash
            // reads its stdin in blocks, so anything written while the shell was still
            // parsing would vanish into its buffer.
            try await stream.write(script.data)
        } catch {
            stream.close()
            Spawn.terminate(spawned, grace: 1)
            release()
            throw error
        }

        var parser = SentinelParser(sentinel: script.sentinel)
        let deadline = Date().addingTimeInterval(readinessDeadline)
        do {
            try await stream.drain(deadline: deadline) { chunk in
                parser.append(chunk)
                return parser.sawOpeningSentinel
            }
        } catch {
            parser.finish()
        }
        guard parser.sawOpeningSentinel else {
            parser.finish()
            stream.close()
            Spawn.terminate(spawned, grace: 1)
            release()
            if parser.looksLikeForceCommandRefusal {
                throw SSHProcessError.noShellAccess(prefix: parser.prefix)
            }
            throw SSHProcessError.shellOutputUnusable(prefix: parser.prefix)
        }
        // The sentinel scan reads past the marker; hand the rest back so the script's own
        // first bytes are not swallowed.
        if !parser.payload.isEmpty { stream.pushBack(parser.payload) }
        let pgid = group ?? spawned.pid
        return FakeExecChannel(
            stream: stream, prefix: parser.prefix, sentinel: script.sentinel,
            process: spawned, processGroup: pgid, onClose: release)
    }

    /// Runs raw text through the profile's shell and returns everything it wrote, with
    /// no sentinel and no wrapper.
    ///
    /// The counter-example half of a scenario: `J4` needs to *show* that the naive
    /// `printf "\0<sentinel>"` loses bytes, and a claim about a shell is only worth
    /// something when the shell is the one that made it.
    public func runRaw(_ script: String, timeout: TimeInterval = 10) async throws -> Data {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw ServerModelUnavailable(reason: reason)
        }
        let invocation = try shellInvocation()
        let spawned = try Spawn.run(
            executable: invocation.executable, argv: invocation.argv,
            environment: invocation.environment,
            wantsStdin: true, wantsStdout: true, wantsStderr: true,
            newProcessGroup: true)
        let stream = PipeByteStream(readFD: spawned.stdoutFD, writeFD: spawned.stdinFD,
                                    label: "servermodel-raw")
        defer { stream.close(); Spawn.terminate(spawned, grace: 1) }
        try await stream.write(Data(script.utf8))
        stream.closeWrite()
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = try await stream.read(upTo: 64 * 1024, deadline: deadline)
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        return out
    }

    /// A bystander session on the same server, for the `kill -TERM 0` regression: it does
    /// nothing but sleep, and whether it survives is the whole assertion (`SQ-010`).
    @discardableResult
    public func openBystander(sleepSeconds: Int = 120) throws -> SpawnedProcess {
        let group = try processGroupPolicy()
        let shell = ScriptShell.dash.executablePath ?? "/bin/sh"
        let spawned = try Spawn.run(
            executable: shell, argv: [shell, "-c", "sleep \(sleepSeconds)"],
            environment: ProcessInfo.processInfo.environment,
            wantsStdout: true, wantsStderr: true,
            stdinFromDevNull: true,
            newProcessGroup: group == nil,
            joinProcessGroup: group)
        lock.withLock { openSessions += 1 }
        return spawned
    }

    /// True while the process is neither exited nor a zombie. `pgrep` counts zombies, so
    /// "did I kill it?" is unanswerable from a name match alone (`SQ-075`); a `waitpid`
    /// poll is the one that is not.
    public static func isAlive(_ pid: pid_t) -> Bool { Spawn.poll(pid: pid) == nil }

    public func shutdown() {
        if let leader = groupLeader {
            kill(-leader.pid, SIGKILL)
            _ = Spawn.wait(pid: leader.pid)
            groupLeader = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The process-group policy

    /// Returns the pgid every session must join, or nil where each session gets its own.
    ///
    /// `SQ-012`: OpenSSH's sshd gives each session a session and process group of its own,
    /// so `kill … 0` has a blast radius of exactly that session, which is what hides
    /// `SQ-010` on every server but the one that has it.
    ///
    /// `SQ-010`: `tailscaled` puts every session of every client in **its own** process
    /// group, so `kill -TERM 0` from one session signals all of them and the connections
    /// under them. Modelled for real: a long-lived leader process is started in a group of
    /// its own and every session is spawned into that group, so a `kill -TERM 0` run by a
    /// real shell really does reach a real bystander.
    private func processGroupPolicy() throws -> pid_t? {
        guard case .sharedWith = profile.sessionGrouping else { return nil }
        lock.lock()
        if let existing = groupLeader, Spawn.poll(pid: existing.pid) == nil {
            lock.unlock()
            return existing.pid
        }
        lock.unlock()
        let shell = ScriptShell.dash.executablePath ?? "/bin/sh"
        // The stand-in for `tailscaled` itself: it leads the group, it is not one of our
        // sessions, and it survives - as the real one does, being root.
        let leader = try Spawn.run(
            executable: shell, argv: [shell, "-c", "trap '' TERM; sleep 600"],
            environment: ProcessInfo.processInfo.environment,
            stdinFromDevNull: true,
            newProcessGroup: true)
        lock.withLock { groupLeader = leader }
        return leader.pid
    }

    // MARK: - The shell and its rc noise

    struct ShellInvocation {
        var executable: String
        var argv: [String]
        var environment: [String: String]
        /// Written before the script where the shell has no real rc mechanism we can use.
        var stdinPreamble: String
    }

    /// The command line that reproduces the account's shell shape.
    ///
    /// Where a real rc mechanism exists it is used, because that is the behaviour
    /// `SQ-015` is about: `BASH_ENV` is exactly what makes `.bashrc` print for a
    /// non-interactive bash, and `ZDOTDIR`'s `.zshenv` is read for *every* zsh invocation.
    /// Where it does not - dash and busybox ash read no rc file for a script on stdin -
    /// the noise is written ahead of the script on the same stdin, which puts the same
    /// bytes in the same place for the sentinel to discard.
    ///
    /// **The mechanism is verified rather than assumed.** A shell build that ignores the
    /// rc variable would otherwise turn a scenario about discarding rc noise into a
    /// scenario about a channel with no noise in it, which passes and proves nothing. So
    /// the chosen mechanism is run once with a marker and, if the marker does not come
    /// back, the noise falls back to the stdin preamble - same bytes, same place, and the
    /// fallback is recorded in `rcMechanism` for a reader of the failure.
    func shellInvocation() throws -> ShellInvocation {
        let invocation = try uncheckedShellInvocation()
        guard !profile.loginShell.rcNoise.isEmpty, invocation.stdinPreamble.isEmpty else {
            return invocation
        }
        if Self.rcMechanismDelivers(invocation) { return invocation }
        rcMechanism = .stdinPreamble
        var fallback = invocation
        // Run the script shell directly and put the noise in front of the script.
        let shell = profile.loginShell.scriptShell
        guard let path = shell.executablePath else {
            throw ServerModelUnavailable(reason: shell.skipReason)
        }
        fallback.executable = path
        fallback.argv = [path] + shell.stdinScriptArguments
        fallback.stdinPreamble = rcBody()
        return fallback
    }

    /// Which mechanism actually put the rc noise on the channel.
    public private(set) var rcMechanism: RCMechanism = .rcFile

    public enum RCMechanism: String, Sendable {
        /// The shell's own rc variable - `BASH_ENV`, `ZDOTDIR`/`.zshenv` - which is what
        /// `SQ-015` is a statement about.
        case rcFile
        /// The same bytes written ahead of the script on the channel's stdin, for a shell
        /// that reads no rc file for a script on stdin, or a build that ignores the one it
        /// should read.
        case stdinPreamble
    }

    /// Runs the invocation once with a marker rc file and says whether the marker came
    /// back on stdout.
    private static func rcMechanismDelivers(_ invocation: ShellInvocation) -> Bool {
        guard let result = try? Spawn.capture(
            executable: invocation.executable, argv: invocation.argv,
            environment: invocation.environment, timeout: 10)
        else { return false }
        // The rc file printed the profile's noise; the shell then read an empty stdin and
        // exited. Anything on stdout is the rc file's.
        return !result.stdout.isEmpty
    }

    private func uncheckedShellInvocation() throws -> ShellInvocation {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = profile.home
        environment["PATH"] = try shimmedPATH(environment["PATH"] ?? "/usr/bin:/bin")
        switch profile.loginShell {
        case .bashNoisy, .bashBackgroundHolder, .bashQuiet:
            guard let bash = ScriptShell.bash.executablePath,
                  let sh = profile.loginShell.scriptShell.executablePath
            else { throw ServerModelUnavailable(reason: ScriptShell.bash.skipReason) }
            let rc = directory.appendingPathComponent("bashrc")
            try rcBody().write(to: rc, atomically: true, encoding: .utf8)
            environment["BASH_ENV"] = rc.path
            let arguments = profile.loginShell.scriptShell.stdinScriptArguments
            return ShellInvocation(
                executable: bash,
                argv: [bash, "-c", "exec \(sh) \(arguments.joined(separator: " "))"],
                environment: environment, stdinPreamble: "")

        case .zsh:
            guard let zsh = ScriptShell.zsh.executablePath,
                  let sh = ScriptShell.dash.executablePath
            else { throw ServerModelUnavailable(reason: ScriptShell.zsh.skipReason) }
            let dot = directory.appendingPathComponent("zdotdir")
            try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
            try rcBody()
                .write(to: dot.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            environment["ZDOTDIR"] = dot.path
            return ShellInvocation(
                executable: zsh, argv: [zsh, "-c", "exec \(sh) -s"],
                environment: environment, stdinPreamble: "")

        case .dash, .none:
            guard let sh = ScriptShell.dash.executablePath else {
                throw ServerModelUnavailable(reason: ScriptShell.dash.skipReason)
            }
            return ShellInvocation(
                executable: sh, argv: [sh, "-s"], environment: environment,
                stdinPreamble: rcBody())

        case .busyboxAsh:
            guard let busybox = ScriptShell.busyboxAsh.executablePath else {
                throw ServerModelUnavailable(reason: ScriptShell.busyboxAsh.skipReason)
            }
            return ShellInvocation(
                executable: busybox, argv: [busybox, "sh", "-s"], environment: environment,
                stdinPreamble: rcBody())

        case .fish, .tcsh:
            throw ServerModelUnavailable(
                reason: FakeSSHD.unavailabilityReason(for: profile) ?? "shell unavailable")
        }
    }

    /// A `PATH` whose first entry holds the profile's `find` shim.
    ///
    /// This box has GNU findutils and nothing else, so a busybox profile's `find` is a
    /// generated script that behaves the way BusyBox 1.36.1 was measured to: `-cmin` and
    /// `-printf` rejected with `find: unrecognized: …` and rc 1 (`SQ-001`, `SQ-003`), and
    /// `--version` printing an error and exiting **0** (`SQ-002`), which is the trap a
    /// probe keyed on the exit status falls into. A GNU profile gets no shim at all and
    /// runs the real `find`.
    ///
    /// The same directory carries the profile's **clock** where `clockOffset` is not zero
    /// (`SQ-054`). Docker has no time namespace, so no container can be made to disagree
    /// with our clock and no testbed service ever will; a shimmed `date` is the only way a
    /// skewed server can be run at all, and `H4` is the only coverage that case will ever
    /// get. A profile at offset zero gets no `date` shim and runs the real one.
    func shimmedPATH(_ base: String) throws -> String {
        // Only a **busybox** profile is shimmed. A `.gnu` or `.bsd` profile runs this box's
        // own `find`, which is the whole point of running the sweep against a real one - and
        // shimming either of them would answer `find: unrecognized: -cmin` for a flavour that
        // takes it. Where the box's `find` is not the flavour the profile claims, the
        // scenario skips by name (`HostTools.flavourTakingCmin`, `SQ-081`); it never
        // runs against a shim pretending to be findutils.
        let needsFindShim: Bool
        switch profile.findFlavour {
        case .busybox, .busyboxNoCmin: needsFindShim = true
        case .gnu, .bsd: needsFindShim = false
        }
        guard needsFindShim || profile.clockOffset != 0 else { return base }
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if profile.clockOffset != 0 { try writeClockShim(into: bin) }
        guard needsFindShim else { return "\(bin.path):\(base)" }
        let script = """
            #!/bin/sh
            # BusyBox 1.36.1's `find`, as measured on `alp` (SQ-001, SQ-002, SQ-003).
            for __a in "$@"; do
              case "$__a" in
                -cmin)    echo "find: unrecognized: -cmin" >&2; exit 1 ;;
                -printf)  echo "find: unrecognized: -printf" >&2; exit 1 ;;
                --version)
                  # Prints an error and exits **0**: a probe keyed on the exit status
                  # therefore calls every busybox server GNU.
                  echo "find: unrecognized: --version" >&2; exit 0 ;;
              esac
            done
            exec \(Self.realFindPath) "$@"
            """
        let path = bin.appendingPathComponent("find")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        if let banner = profile.findFlavour.busyboxBanner {
            let busybox = """
                #!/bin/sh
                echo \(singleQuoted(banner))
                """
            let bbPath = bin.appendingPathComponent("busybox")
            try busybox.write(to: bbPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bbPath.path)
        }
        return "\(bin.path):\(base)"
    }

    /// The box's own `find`, which every shim ends up delegating to. Spelled absolutely
    /// because the shim puts itself first on the `PATH` and would otherwise recurse.
    static let realFindPath: String = ["/usr/bin/find", "/bin/find"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    } ?? "/usr/bin/find"

    /// The profile's own clock, as a `date` on the session's `PATH` (`SQ-054`).
    ///
    /// Only `date +%s` is shifted, because that is the only spelling anything of ours ever
    /// runs: the sweep script prints `"$(date +%s)"` before its first `find`
    /// and the helper deployment asks for the same thing. Every other invocation falls
    /// through to the real `date` rather than being answered with an invention.
    ///
    /// The offset is applied to the *reading*, not to the box: nothing here touches this
    /// machine's clock, so a skewed profile and an unskewed one can run side by side in
    /// one test, which is exactly what `H4` needs to show that the absolute values do not
    /// enter the window at all.
    private func writeClockShim(into bin: URL) throws {
        let real = ["/bin/date", "/usr/bin/date"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/bin/date"
        let offset = Int(profile.clockOffset.rounded())
        let script = """
            #!/bin/sh
            # SQ-054: this server's clock is \(offset) s from ours. A container could never
            # be made to say this - Docker has no time namespace - so the model is the
            # only place a skewed server exists.
            for __a in "$@"; do
              case "$__a" in
                +%s) echo $(( $(\(real) +%s) + (\(offset)) )); exit 0 ;;
              esac
            done
            exec \(real) "$@"
            """
        let path = bin.appendingPathComponent("date")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    /// What the account's rc file does, as shell text.
    ///
    /// One definition, used whether it lands in a real rc file or ahead of the script on
    /// stdin, so the two paths cannot drift: the difference between them is *where* the
    /// bytes come from, never *what* they are. In particular `SQ-016`'s background child
    /// belongs to both - it is what makes EOF never arrive on the channel, and losing it
    /// in one path would turn that scenario into a test of nothing.
    private func rcBody() -> String {
        var body = ""
        let noise = profile.loginShell.rcNoise
        if !noise.isEmpty { body += "printf '%s' \(singleQuoted(noise))\n" }
        if profile.loginShell.holdsStdoutOpen {
            // `SQ-016`: the rc file leaves a background child holding stdout, so EOF never
            // arrives on the channel and only the closing sentinel ends the read. Any
            // reader that waits for EOF hangs - which is the case the sentinel exists
            // for (docs/design/security.md).
            body += "( sleep 120 & )\n"
        }
        return body
    }

    private func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Thrown where a scenario's shell is not installed on this box. Scenarios turn it into a
/// **named skip**, never into a pass.
public struct ServerModelUnavailable: Error, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// `SQ-013`: what a `ForceCommand internal-sftp` account answers an exec channel with -
/// the plain sentence, or SFTP framing. Both mean "no shell access (ForceCommand)".
public struct ForceCommandRefusal: Error {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
    /// Fed through the parser the product uses, so the two shapes are told apart the way
    /// `SSHMaster.openExecChannel` tells them apart.
    public var looksLikeForceCommandRefusal: Bool {
        var parser = SentinelParser(sentinel: Sentinel(hex: String(repeating: "0", count: 32)))
        parser.append(bytes)
        parser.finish()
        return parser.looksLikeForceCommandRefusal
    }
}

/// The account as the **login-shell snapshot** meets it (docs/design/ssh.md).
///
/// A generated `HOME` whose rc files print the profile's noise and export a `PATH` and an
/// `SSH_AUTH_SOCK`, so `LoginShellSnapshotReader` can be run against a real shell shape.
public struct LoginShellAccount: Sendable {
    public let shell: LoginShell
    /// The shell `LoginShellSnapshotReader.take(shell:)` is pointed at - what `getpwuid`
    /// would have answered for this account.
    public let shellPath: String
    public let home: String
    /// The rc file the noise and the two variables were written into, named so a failure
    /// says which mechanism did not fire.
    public let rcFile: String
    /// `HOME`, and `ZDOTDIR` where the shell needs one. Handed to `take` as its base
    /// environment, so nothing of this box's own shell leaks into the answer.
    public let environment: [String: String]
    public let expectedPATH: String
    public let expectedAuthSock: String?
    /// The bytes the rc file prints before anything of ours (`SQ-015`).
    public let noise: String
    /// `SQ-016`: the rc file leaves a background child holding stdout, so EOF never
    /// arrives and only the closing sentinel can end the read.
    public let holdsStdoutOpen: Bool
}

extension FakeSSHD {

    /// Builds the account's login-shell shape: an rc file that prints the profile's noise
    /// and exports a `PATH` and an `SSH_AUTH_SOCK` (docs/design/ssh.md, `SQ-015`).
    ///
    /// A **different mechanism** from the exec channel's above, deliberately. An exec
    /// channel runs `sh -s` non-interactively, where bash reads `BASH_ENV`; the snapshot
    /// runs `<shell> -ilc`, an *interactive login* shell, where bash reads
    /// `.bash_profile`, zsh reads `.zshenv` under `ZDOTDIR` and dash reads `.profile` -
    /// and `BASH_ENV` is not consulted at all. The bytes are the same and they arrive in
    /// the same place, in front of the sentinel, which is the whole of `SQ-015`.
    ///
    /// Nothing is faked if the mechanism does not fire: the same rc file exports the
    /// `PATH` the caller then asserts on, so a shell that never read it fails the scenario
    /// rather than passing it with an empty channel.
    ///
    /// `fish` and `tcsh` throw `ServerModelUnavailable`: their rc syntax is not this
    /// POSIX body, and neither shell is on this box, so those rows skip **by name**.
    public func loginShellAccount(
        path: String = "/opt/rc/bin:/usr/bin:/bin",
        sshAuthSock: String? = "/tmp/sshdrive-rc-agent.sock"
    ) throws -> LoginShellAccount {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw ServerModelUnavailable(reason: reason)
        }
        let shell = profile.loginShell
        let executable: ScriptShell
        switch shell {
        case .bashQuiet, .bashNoisy, .bashBackgroundHolder: executable = .bash
        case .zsh: executable = .zsh
        case .busyboxAsh: executable = .busyboxAsh
        case .dash, .none: executable = .dash
        case .fish, .tcsh:
            throw ServerModelUnavailable(
                reason: FakeSSHD.unavailabilityReason(for: profile)
                    ?? "\(shell.rawValue) is not installed on this box; the row is skipped, not faked")
        }
        guard let shellPath = executable.executablePath else {
            throw ServerModelUnavailable(reason: executable.skipReason)
        }

        let home = directory.appendingPathComponent("login-home-\(shell.rawValue)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var body = ""
        if !shell.rcNoise.isEmpty {
            body += "printf '%s' \(loginQuoted(shell.rcNoise))\n"
        }
        if shell.holdsStdoutOpen {
            // `SQ-016`: the background child inherits the shell's stdout - the pipe the
            // reader is on - so EOF never arrives however long it waits.
            body += "( sleep 120 & )\n"
        }
        body += "PATH=\(loginQuoted(path)); export PATH\n"
        if let sshAuthSock {
            body += "SSH_AUTH_SOCK=\(loginQuoted(sshAuthSock)); export SSH_AUTH_SOCK\n"
        } else {
            body += "unset SSH_AUTH_SOCK\n"
        }

        var environment: [String: String] = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        let rcName: String
        switch shell {
        case .bashQuiet, .bashNoisy, .bashBackgroundHolder:
            // An interactive login bash reads `.bash_profile` and not `.bashrc`; the
            // testbed's accounts keep the noise in `.bashrc` and source it from there,
            // which is the ordinary Debian shape and the one `SQ-015` names.
            rcName = ".bashrc"
            try body.write(to: home.appendingPathComponent(".bashrc"),
                           atomically: true, encoding: .utf8)
            try ". \"$HOME/.bashrc\"\n".write(
                to: home.appendingPathComponent(".bash_profile"),
                atomically: true, encoding: .utf8)
        case .zsh:
            // `.zshenv` is read for *every* zsh invocation, which is why a zsh account's
            // noise reaches even a non-interactive channel (`SQ-015`).
            rcName = ".zshenv"
            environment["ZDOTDIR"] = home.path
            try body.write(to: home.appendingPathComponent(".zshenv"),
                           atomically: true, encoding: .utf8)
        case .dash, .none, .busyboxAsh:
            rcName = ".profile"
            try body.write(to: home.appendingPathComponent(".profile"),
                           atomically: true, encoding: .utf8)
        case .fish, .tcsh:
            throw ServerModelUnavailable(reason: "unreachable: handled above")
        }

        return LoginShellAccount(
            shell: shell, shellPath: shellPath, home: home.path,
            rcFile: home.appendingPathComponent(rcName).path,
            environment: environment, expectedPATH: path, expectedAuthSock: sshAuthSock,
            noise: shell.rcNoise, holdsStdoutOpen: shell.holdsStdoutOpen)
    }

    /// A real directory with nothing in it, for a script that has to run with **no tools
    /// on its `PATH`** (`SQ-067`).
    ///
    /// A server may have neither `sha256sum` nor `shasum`, which is why the helper's
    /// verification falls back to the remote file's size plus running the binary with
    /// `--version` (docs/design/change-detection.md). The model cannot uninstall
    /// coreutils, so it takes the tools off `PATH` instead and the shell really does find
    /// none - *inferred* staging of a row measured 2026-09-05, and the only kind this box
    /// can offer.
    public func emptyToolDirectory() throws -> String {
        let empty = directory.appendingPathComponent("no-tools")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        return empty.path
    }

    private func loginQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
