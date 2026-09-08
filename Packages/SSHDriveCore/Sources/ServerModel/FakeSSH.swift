import Foundation
import SSHProcess

/// A stub that stands in for `/usr/bin/ssh`.
///
/// `docs/testing-architecture.md` section 4.2: "It exists so `SSHInvocation`'s argv
/// assembly, `Spawn.swift`, `ExitClassification` and `ControlSocket` are exercised for
/// real." `SSHMaster` spawns it exactly as it spawns the real thing - same argv, same
/// `posix_spawn`, same pipes, same control-socket wait - so everything from the option
/// ordering to the exit classification runs on a box with no server at all.
///
/// What it reproduces, each from `docs/quirks/servers.md`:
///
/// - `SQ-038` OpenSSH's readconf **first-setting-wins** rule, so writing `ProxyJump=none`
///   *before* `ProxyCommand=…` really does discard the ProxyCommand and leave the master
///   resolving the inner hostname itself.
/// - `SQ-039` a `ProxyCommand` is percent-expanded **once** before `/bin/sh -c` sees it,
///   which is why a nested hop's `%h`/`%p` must be doubled per level.
/// - `SQ-035` every stderr log line ends **CRLF**.
/// - `SQ-036` `remote software version …` is printed only at `DEBUG1` and above.
/// - `SQ-047`/`SQ-060` the askpass prompts, with their exact trailing spaces, and the
///   host-key question arriving with `SSH_ASKPASS_PROMPT` **unset**.
/// - `SQ-021`/`SQ-079` `mux_client_request_session: session request failed` for a real
///   refusal, and `Control socket connect(…): No such file or directory` for a master
///   that has gone - which must never be cached as a `MaxSessions` budget.
/// - `SQ-011` exit 255 with **nothing** on stderr when the remote command was killed by a
///   signal.
/// - `SQ-041` `ControlPersist` is honoured by forking away, so a master run with it set
///   loses its pid - the reason ours runs `-N` with `ControlPersist=no`.
/// - `SQ-042` a mux client whose socket is missing **falls back to a direct connection**
///   unless it carries `-F /dev/null`, `BatchMode=yes` and `ProxyCommand=/usr/bin/false`.
/// - `SQ-043` a master that finds a socket already at its `ControlPath` prints
///   `ControlSocket … already exists, disabling multiplexing` and runs with no socket.
/// - `SQ-044` a master whose socket has gone, and one that has stopped serving it
///   (`SSHDRIVE_FAKESSH_MASTER=wedged`), cannot be reached by `-O exit` at all.
public final class FakeSSH: @unchecked Sendable {

    /// The directory holding the stub, its state and its logs.
    public let directory: URL
    /// The path to write into `SSHProcess.sshBinaryPath`.
    public let executablePath: String
    public let profile: ServerProfile

    private let state: URL
    private var installedBinaryPath = false
    private var installedProcessName = false

    public init(profile: ServerProfile, hostKeyKnown: Bool = true,
                authenticationDelay: TimeInterval = 0,
                agentOnlyKey: Bool = false,
                extraPrompt: String? = nil,
                extraPromptHint: String = "") throws {
        self.profile = profile
        // Eight hex digits, not a UUID string. Control sockets are made **inside** this
        // directory and a `sockaddr_un` path is limited to 104 bytes; macOS's `$TMPDIR` is
        // about fifty of them on its own, so a 36-character component here put every
        // socket path over the limit and the stub silently fell back to a plain file
        // (`SQ-085`, measured 2026-09-08 - `K4`'s "the socket outlived the pid" then failed
        // against a file that was never a socket).
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sd-ssh-\(HostTools.shortID())")
        state = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        executablePath = directory.appendingPathComponent("ssh").path

        let sshd = try FakeSSHD(profile: profile)
        let shell = try sshd.shellInvocation()
        sshd.shutdown()

        // The session's shell is a generated script rather than an argv the stub has to
        // re-split: word-splitting a command line back out of one variable is exactly the
        // kind of quoting bug section 9.2 exists to avoid, and a harness that has one
        // cannot be trusted about anybody else's. `sshd`'s side of an exec channel is
        // "hand the account's shell this stdin", and that is all this is.
        let sessionShell = directory.appendingPathComponent("session-shell.sh")
        var sessionBody = "#!/bin/sh\n"
        // The channel's real stderr, handed over on fd 4 by `run_session` so that the
        // stub shell's own job-status report cannot reach it (`SQ-084`).
        sessionBody += "exec 2>&4 4>&-\n"
        for key in ["BASH_ENV", "ZDOTDIR", "PATH"] {
            if let value = shell.environment[key] {
                sessionBody += "export \(key)=\(Self.singleQuoted(value))\n"
            }
        }
        if !shell.stdinPreamble.isEmpty {
            sessionBody += shell.stdinPreamble
        }
        sessionBody += "exec " + shell.argv.map(Self.singleQuoted).joined(separator: " ") + "\n"
        try sessionBody.write(to: sessionShell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: sessionShell.path)

        let settings: [String: String] = [
            "MAX_SESSIONS": String(profile.maxSessions),
            "IDENTIFICATION": profile.identificationString,
            "PASSWORD": profile.auth.password ?? "",
            "ACCEPTS_KEY": profile.auth.acceptsAKey ? "1" : "0",
            "KBDINT": {
                if case .keyboardInteractive = profile.auth { return "1" }
                return "0"
            }(),
            "HOST_KEY_KNOWN": hostKeyKnown ? "1" : "0",
            "AUTH_DELAY": String(Int(authenticationDelay)),
            // Section 4.2's second pass: a key that lives **only** in the key agent. The
            // first collect pass runs `IdentityAgent=none` and cannot use it, the second
            // can, and that is the whole of what makes a location `agentDependent`. The
            // stub reads the option off its own argv, so the branch is decided by the
            // command line the agent built and not by a flag the test set (inferred from
            // section 4.2; the measured half is `SQ-064`, a server that takes both).
            "AGENT_ONLY": agentOnlyKey ? "1" : "0",
            // One further prompt this server raises before it authenticates, with its
            // `SSH_ASKPASS_PROMPT` hint. Section 4.2's table has three shapes no testbed
            // service can produce - a smartcard/FIDO **PIN**, a one-time code, and the
            // user-presence notice a touch-required FIDO key raises - and all three are
            // refusals, so a scenario that wants one states it here.
            //
            // Confidence: the prompt *wording* is OpenSSH's own format string, read from
            // `strings /usr/bin/ssh` and catalogued in `Secrets.AskpassPrompt`
            // (`SQ-060`'s family); the *refusal* is DESIGN.md section 4.2. Neither has
            // been raised against a real key of ours, because we have no FIDO key -
            // `docs/testing-architecture.md` section 7 lists a real touch key as
            // unmodellable, and this is the modellable half.
            "EXTRA_PROMPT": extraPrompt ?? "",
            "EXTRA_PROMPT_HINT": extraPromptHint,
            "SESSION_SHELL": sessionShell.path,
            "FORCE_COMMAND": profile.forceCommand == nil ? "" : "1",
            "FORCE_SENTENCE": OpenSSHPrompts.forceCommandSentence,
            "STATE": state.path,
        ]

        let configuration = settings
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.singleQuoted($0.value))" }
            .joined(separator: "\n")
        try (configuration + "\n").write(
            to: directory.appendingPathComponent("profile.sh"), atomically: true, encoding: .utf8)
        try Self.script(configurationPath: directory.appendingPathComponent("profile.sh").path)
            .write(toFile: executablePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executablePath)
    }

    deinit { uninstall() }

    /// Points `SSHProcess.sshBinaryPath` at the stub. Every `SSHInvocation` built after
    /// this - the master's, the mux clients', and every `ProxyJump` hop `ProxyChainBuilder`
    /// embeds - names it, which is what makes the hop argv assertions real.
    public func install() {
        Self.installBinaryPath(executablePath)
        installedBinaryPath = true
        // ...and tells `ControlSocket` what the kernel will call a running stub. On Linux
        // that is `ssh`, the script's own name; on Darwin it is the interpreter binary's,
        // because a script has no `p_comm` of its own there (`SQ-082`). Measured once per
        // process rather than assumed, so a box that answers differently is not silently
        // read as one that answers `ssh`.
        Self.installProcessName()
        installedProcessName = true
    }

    public func uninstall() {
        if installedBinaryPath {
            installedBinaryPath = false
            Self.uninstallBinaryPath()
        }
        if installedProcessName {
            installedProcessName = false
            Self.uninstallProcessName()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// `SSHProcess.sshBinaryPath` is **reference-counted** for the same reason: `swift test`
    /// runs the swift-testing suites concurrently with XCTest in one process, and a stub
    /// that saved the value *another* stub had already installed would restore
    /// `/usr/bin/ssh` under a suite that is still running - which is a location whose
    /// masters suddenly dial a real server and report `serverUnreachable`. Counting means
    /// an uninstall can never pull the binary out from under a live stub; the real path is
    /// put back only when the last one leaves.
    ///
    /// What counting does **not** fix, and cannot: two stubs installed at once still share
    /// one global, so the last `install()` decides which stub every suite spawns. A test
    /// that needs its own `ssh` while another suite holds one wants the path carried on
    /// `SSHMaster.Configuration` rather than in a global, or the two suites kept apart.
    private static let binaryPathLock = NSLock()
    private static var binaryPathInstalls = 0
    private static var binaryPathBeforeUs: String?

    private static func installBinaryPath(_ path: String) {
        binaryPathLock.lock()
        defer { binaryPathLock.unlock() }
        if binaryPathInstalls == 0 { binaryPathBeforeUs = SSHProcess.sshBinaryPath }
        binaryPathInstalls += 1
        SSHProcess.sshBinaryPath = path
    }

    private static func uninstallBinaryPath() {
        binaryPathLock.lock()
        defer { binaryPathLock.unlock() }
        binaryPathInstalls = max(0, binaryPathInstalls - 1)
        if binaryPathInstalls == 0, let before = binaryPathBeforeUs {
            SSHProcess.sshBinaryPath = before
            binaryPathBeforeUs = nil
        }
    }

    /// `ControlSocket.masterProcessName` is **reference-counted** across stubs rather than
    /// saved and restored per stub, because `swift test` runs the swift-testing suites
    /// concurrently with XCTest in one process: two stubs alive at once would have the
    /// second save the first's value and the first restore `ssh` while the second is still
    /// installed, and a sweep running at that moment matches nothing. Every stub in a
    /// process measures the same name, so the only thing that has to be right is *when the
    /// last one leaves*.
    private static let processNameLock = NSLock()
    private static var processNameInstalls = 0
    private static var processNameBeforeUs: String?

    private static func installProcessName() {
        processNameLock.lock()
        defer { processNameLock.unlock() }
        if processNameInstalls == 0 {
            processNameBeforeUs = ControlSocket.masterProcessName
            ControlSocket.masterProcessName = stubProcessName
        }
        processNameInstalls += 1
    }

    private static func uninstallProcessName() {
        processNameLock.lock()
        defer { processNameLock.unlock() }
        processNameInstalls = max(0, processNameInstalls - 1)
        if processNameInstalls == 0, let before = processNameBeforeUs {
            ControlSocket.masterProcessName = before
            processNameBeforeUs = nil
        }
    }

    /// What `p_comm` / `/proc/<pid>/comm` says for a running stub, measured by running a
    /// throwaway script with the stub's own shebang and its own name and asking the kernel.
    ///
    /// `SQ-082`: Linux takes the short name from the **script**, so this is `ssh`; XNU
    /// takes it from the **interpreter binary**, so on a Mac it is `dash` or `bash`. There
    /// is no third option there: macOS launch constraints `SIGKILL` a copy of any system
    /// shell (ad-hoc re-signed or not), so no binary named `ssh` can be produced to point
    /// a shebang at. Falls back to `ssh` where nothing can be measured, which fails loudly
    /// in the scenario rather than passing quietly.
    static let stubProcessName: String = measureStubProcessName()

    private static func measureStubProcessName() -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sd-name-\(HostTools.shortID())")
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil
        else { return "ssh" }
        defer { try? FileManager.default.removeItem(at: directory) }

        // The same name and the same shebang as the stub, which is the whole point: what
        // is measured has to be what will run. It prints before it sleeps, and that line
        // is what makes the measurement deterministic - see below.
        let probe = directory.appendingPathComponent("ssh").path
        guard (try? "#!/bin/sh\nprintf ready\nsleep 30\n"
            .write(toFile: probe, atomically: true, encoding: .utf8)) != nil,
            (try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: probe)) != nil,
            let process = try? Spawn.run(
                executable: probe, argv: [probe],
                environment: ProcessInfo.processInfo.environment,
                wantsStdout: true, stdinFromDevNull: true, newProcessGroup: true)
        else { return "ssh" }
        defer {
            kill(process.pid, SIGKILL)
            _ = Spawn.wait(pid: process.pid)
        }

        // **Wait until the script is running, then read the name.** The read races two
        // execs on Darwin (`SQ-082`): until the first lands the child still carries this
        // process's own short name, and macOS's `/bin/sh` is a small launcher that then
        // re-execs `bash`, so `p_comm` reads `sh` for the first hundred-odd milliseconds
        // and `bash` from then on. Sampling on a timer got `sh` on a cold first run and
        // `bash` on every warm one - one character, and every pid-based route of `K4` and
        // `K6` failed on it.
        //
        // A byte from the script itself is the one signal that cannot race: `p_comm` only
        // changes at `exec`, and the script cannot have printed until the interpreter that
        // runs it is the one that is running. A real `ssh` is a single binary with no such
        // transition at all; this is a property of the shell the stub is interpreted by,
        // and it is why the name is measured rather than written out.
        let out = process.stdoutFD
        guard out >= 0 else { return "ssh" }
        defer { close(out) }
        let flags = fcntl(out, F_GETFL, 0)
        _ = fcntl(out, F_SETFL, flags | O_NONBLOCK)
        var seen = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !seen.contains(UInt8(ascii: "y")) {
            var byte = [UInt8](repeating: 0, count: 64)
            let n = read(out, &byte, byte.count)
            if n > 0 { seen.append(contentsOf: byte[0 ..< n]) } else { usleep(10_000) }
        }
        guard seen.contains(UInt8(ascii: "y")) else { return "ssh" }
        return ControlSocket.processName(of: process.pid) ?? "ssh"
    }

    // MARK: - Per-host seeding

    /// The password this host asks for, instead of the profile's own.
    ///
    /// `SQ-063`: two hops of a chain are told apart by the **argv of the asking `ssh`**,
    /// never by the prompt text, and the testbed proved it with two bastions carrying
    /// deliberately *different* passwords. One password per profile could not reproduce
    /// that, so a host may carry its own here; everything else about the hop is the
    /// profile's.
    public func setPassword(_ password: String, forHost host: String) throws {
        let directory = state.appendingPathComponent("pw")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try password.write(
            to: directory.appendingPathComponent(Self.tableName(host)), atomically: true,
            encoding: .utf8)
    }

    /// What `ssh -G` resolves this alias's `hostname` to.
    ///
    /// Section 4.2 keys a password on the **resolved** `hostname`, "lowercased as `ssh`
    /// itself prints it in the prompt; the alias the user typed never appears in a key".
    /// A model whose alias and hostname are the same string cannot tell a correct
    /// implementation from one that keys on the alias, so a scenario that cares seeds the
    /// two apart.
    public func setResolvedHostname(_ hostname: String, forAlias alias: String) throws {
        let directory = state.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try hostname.write(
            to: directory.appendingPathComponent(Self.tableName(alias)), atomically: true,
            encoding: .utf8)
    }

    /// A file name for a host: a hostname is a path component already, but an empty one
    /// or a `/` would not be.
    static func tableName(_ host: String) -> String {
        let cleaned = host.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "_" : cleaned
    }

    // MARK: - What the stub recorded

    private func lines(_ name: String) -> [String] {
        guard let text = try? String(contentsOf: state.appendingPathComponent(name),
                                     encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Every invocation's argv, one per line, arguments separated by `\u{1}`.
    public var invocations: [[String]] {
        lines("argv.log").map { $0.components(separatedBy: "\u{1}") }
    }

    /// The `ProxyCommand` each master actually ran, after one round of percent expansion
    /// (`SQ-039`), or an empty list where readconf discarded it (`SQ-038`).
    public var proxyCommandsRun: [String] { lines("proxy.log") }

    /// The argv of every `ProxyJump` hop the chain actually invoked, innermost last.
    public var hopInvocations: [[String]] {
        lines("hops.log").map { $0.components(separatedBy: "\u{1}") }
    }

    /// Every prompt handed to `SSH_ASKPASS`, in order, with its `SSH_ASKPASS_PROMPT` hint
    /// (empty where `ssh` set none, which is the host-key question's shape - `SQ-047`).
    public var askpassPrompts: [(prompt: String, hint: String)] {
        lines("askpass.log").map { line in
            guard let separator = line.range(of: "\u{1}") else { return (line, "") }
            // The stub flattens a multi-line prompt onto one log line; put it back.
            let prompt = String(line[line.startIndex ..< separator.lowerBound])
                .replacingOccurrences(of: "\u{2}", with: "\n")
            return (prompt, String(line[separator.upperBound...]))
        }
    }

    /// The pid of every master this stub ended on a **signal** rather than on an exit
    /// request, so a scenario can say which of section 6.1's three routes took which
    /// master (`SQ-043`, `SQ-044`).
    public var terminatedPIDs: [pid_t] { lines("terminated.log").compactMap(pid_t.init) }

    /// Every mux client that found no socket and made a **direct connection of its own**
    /// instead of failing (`SQ-042`). The shipping mux options make this list empty; that
    /// is the whole of what they are for.
    public var unsupervisedFallbacks: [[String]] {
        lines("fallback.log").map { $0.components(separatedBy: "\u{1}") }
    }

    /// How many mux sessions are open right now, counted the way the stub counts them:
    /// by which recorded pids are still alive.
    public var openSessionCount: Int {
        lines("sessions.log").compactMap(pid_t.init).filter { kill($0, 0) == 0 }.count
    }

    /// An askpass that answers from a table, and records what it was asked. The real one
    /// is `sshdrive-askpass` with the token protocol of section 4.2.
    public struct StubAskpass {
        public let path: String
        public let logPath: String

        public init(directory: URL, answers: [(match: String, answer: String)],
                    fallback: String = "") throws {
            let script = directory.appendingPathComponent("askpass.sh")
            logPath = directory.appendingPathComponent("askpass-answers.log").path
            var cases = ""
            for (match, answer) in answers {
                // The pattern is double-quoted inside the glob: a match with a space in
                // it - "continue connecting" - is a `sh` syntax error unquoted.
                cases += "  *\"\(match)\"*) printf '%s\\n' \(FakeSSH.singleQuoted(answer)) ;;\n"
            }
            let body = """
                #!/bin/sh
                printf '%s\\n' "$1" >> \(FakeSSH.singleQuoted(logPath))
                case "$1" in
                \(cases)  *) printf '%s\\n' \(FakeSSH.singleQuoted(fallback)) ;;
                esac
                """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path)
            FileManager.default.createFile(atPath: logPath, contents: Data())
            path = script.path
        }

        public var prompts: [String] {
            ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    public func makeAskpass(answers: [(match: String, answer: String)],
                            fallback: String = "") throws -> StubAskpass {
        try StubAskpass(directory: directory, answers: answers, fallback: fallback)
    }

    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - The stub itself

    /// A POSIX `sh` script, deliberately: it is spawned by absolute path exactly as
    /// `/usr/bin/ssh` is, it needs no build step and no product to locate, and each of the
    /// behaviours below is one line a reader can check against the quirk it cites.
    static func script(configurationPath: String) -> String {
        """
        #!/bin/sh
        # ServerModel.FakeSSH - the stand-in for /usr/bin/ssh
        # (docs/testing-architecture.md section 4.2). Every branch cites the SQ row it
        # reproduces.
        . \(singleQuoted(configurationPath))

        say() { printf '%s\\r\\n' "$1" >&2; }   # SQ-035: every stderr line ends CRLF.

        # Record the argv, arguments separated by \\001, so a test can assert the command
        # line as *executed* and not merely as assembled.
        __argv=""
        for __a in "$@"; do
          if [ -z "$__argv" ]; then __argv="$__a"; else __argv="$__argv$(printf '\\001')$__a"; fi
        done
        printf '%s\\n' "$__argv" >> "$STATE/argv.log"

        # The same argv, argv[0] included, where an askpass can read it **without
        # /proc**. `SQ-063` says two hops of a chain are told apart by the argv of the
        # asking `ssh` and never by the prompt text, and on macOS that argv comes from
        # `sysctl KERN_PROCARGS2` - which the real `sshdrive-askpass` reads in-process
        # (`Secrets.ProcessAncestry`, already branched per platform) and which no shell
        # exposes. Handing it over here is harness plumbing, not a second implementation
        # of the rule: the classification, the keying and the ancestry check are still
        # the shipping broker's. Every invocation of this stub - the master and each
        # `ProxyJump` hop - overwrites it with its own, which is what makes the hops
        # distinguishable at all.
        printf '%s\\001%s' "$0" "$__argv" > "$STATE/argv.$$"
        SSHDRIVE_FAKESSH_ARGV="$STATE/argv.$$"; export SSHDRIVE_FAKESSH_ARGV

        mode=master
        # `-G` wins over every other mode, whatever order the flags arrive in: the broker
        # resolves a master's own destination by running `ssh -G` over that master's whole
        # argv, `-N` included (section 4.2), and a `-N` read after the `-G` would put this
        # back into master mode and open a connection where `ssh` opens none.
        resolve=0
        ctl=""
        control_command=""
        proxy_command=""
        proxy_set=0          # SQ-038: readconf takes the FIRST setting of the field.
        log_level=ERROR
        port=22
        host=""
        is_hop=0
        control_persist=no
        identity_agent=""
        host_key_alias=""
        proxy_jump=""
        identity_files=""
        session_user=""
        command_words=""
        seen_host=0
        config_file=""       # SQ-042: `-F /dev/null` is one of the three mux guards.
        batch_mode=no
        false_proxy=0

        while [ $# -gt 0 ]; do
          case "$1" in
            -N) [ "$resolve" = 1 ] || mode=master ;;
            -W) is_hop=1; hop_target="$2"; shift ;;
            -G) mode=resolve; resolve=1 ;;
            -S) ctl="$2"; mode=mux; shift ;;
            -O) control_command="$2"; mode=control; shift ;;
            -s) mode=subsystem ;;
            -F) config_file="$2"; shift ;;
            -l) session_user="$2"; shift ;;
            -i) identity_files="$identity_files$(printf '\\001')$2"; shift ;;
            -p) port="$2"; shift ;;
            -o)
              __k=$(printf '%s' "$2" | cut -d= -f1)
              __v=$(printf '%s' "$2" | cut -d= -f2-)
              case "$__k" in
                ControlPath) [ -z "$ctl" ] && ctl="$__v" ;;
                ControlPersist) control_persist="$__v" ;;
                BatchMode) batch_mode="$__v" ;;
                LogLevel) log_level="$__v" ;;
                Port) port="$__v" ;;
                # `-o User=` is how the agent names the account (SSHCommandBuilder's
                # destinationOverrides); `-l` is how a ProxyJump hop does.
                User) [ -z "$session_user" ] && session_user="$__v" ;;
                # Section 4.2: the password prompt names `HostKeyAlias` where the config
                # sets one - which is exactly why the keychain key is built from the
                # `ssh -G` resolution and never parsed out of the prompt text.
                HostKeyAlias) host_key_alias="$__v" ;;
                IdentityAgent) identity_agent="$__v" ;;
                IdentityFile) identity_files="$identity_files$(printf '\\001')$__v" ;;
                # SQ-038: ProxyCommand and ProxyJump write the same field, and readconf
                # keeps the first setting of it. `ProxyJump=none` written first therefore
                # marks the field set and the ProxyCommand after it is DISCARDED.
                ProxyCommand)
                  [ "$__v" = /usr/bin/false ] && false_proxy=1
                  if [ "$proxy_set" = 0 ]; then proxy_command="$__v"; proxy_set=1; fi ;;
                ProxyJump)
                  if [ "$proxy_set" = 0 ]; then
                    proxy_set=1
                    proxy_jump="$__v"
                    [ "$__v" = none ] || proxy_command="ssh -W %h:%p $__v"
                  fi ;;
              esac
              shift ;;
            -*) ;;
            *)
              if [ "$seen_host" = 0 ]; then host="$1"; seen_host=1
              else
                if [ -z "$command_words" ]; then command_words="$1"
                else command_words="$command_words $1"; fi
              fi ;;
          esac
          shift
        done

        # A per-host table file, or the fallback. The file name is the host with `/`
        # folded, exactly as `FakeSSH.tableName` spells it.
        table() {   # table <dir> <host> <fallback>
          __n=$(printf '%s' "$2" | tr '/' '_')
          [ -n "$__n" ] || __n=_
          if [ -f "$STATE/$1/$__n" ]; then cat "$STATE/$1/$__n"; else printf '%s' "$3"; fi
        }

        # `ssh -G`'s `hostname`: the alias the user typed resolves to it, and section 4.2
        # keys a password on **this**, never on the alias.
        resolved_host=$(table alias "$host" "$host")
        # SQ-063: the password is the asking host's own, so two hops of one chain really
        # can carry different ones.
        host_password=$(table pw "$resolved_host" "$PASSWORD")

        __mark=$(printf '\\001')
        expand_proxy() {
          # SQ-039: ssh percent-expands the WHOLE ProxyCommand before /bin/sh -c sees it,
          # including a nested hop's own %h/%p - ONE pass, with %% held aside first. Doing
          # the %% last would expand a nested hop's marker too, which is the bug this
          # reproduces rather than papers over.
          printf '%s' "$1" |
            sed -e "s/%%/$__mark/g" -e "s/%h/$host/g" -e "s/%p/$port/g" -e "s/$__mark/%/g"
        }

        ask() {   # ask <prompt> <hint>
          # One log line per prompt: the host-key question is multi-line, and a reader
          # that split it on newlines would see four prompts where ssh raised one.
          __flat=$(printf '%s' "$1" | tr '\\n' '\\002')
          printf '%s\\001%s\\n' "$__flat" "$2" >> "$STATE/askpass.log"
          [ -n "$SSH_ASKPASS" ] || return 1
          [ "$SSH_ASKPASS_REQUIRE" = force ] || return 1
          if [ -n "$2" ]; then SSH_ASKPASS_PROMPT="$2"; export SSH_ASKPASS_PROMPT
          else unset SSH_ASKPASS_PROMPT; fi
          "$SSH_ASKPASS" "$1"
        }

        authenticate() {
          if [ -n "$EXTRA_PROMPT" ]; then
            # Raised before authentication, exactly where a PIN or a touch notice would
            # be. A refusal makes ssh fail; an acknowledged notice does not.
            __a=$(ask "$EXTRA_PROMPT" "$EXTRA_PROMPT_HINT") || {
              say "Permission denied (publickey,password)."
              return 1
            }
          fi
          # Section 4.3: `ask` raises the fingerprint question for an unknown host, and
          # only for an unknown one - a *changed* key raises no prompt at all (`SQ-049`).
          if [ "$HOST_KEY_KNOWN" != 1 ]; then
            # SQ-047: the host-key question reaches askpass with SSH_ASKPASS_PROMPT UNSET,
            # exactly like a password. Classifying on the hint would answer a stored
            # password to "Are you sure you want to continue connecting".
            # Built with printf rather than written out, because the newlines are the
            # prompt's own and a multi-line literal here would indent three of its lines.
            __q=$(printf "The authenticity of host '%s' can't be established.\\nED25519 key fingerprint is SHA256:0000000000000000000000000000000000000000000.\\nThis key is not known by any other names.\\nAre you sure you want to continue connecting (yes/no/[fingerprint])? " "$resolved_host")
            __a=$(ask "$__q" "")
            case "$__a" in
              yes|YES) : ;;
              *) say "Host key verification failed."; return 1 ;;
            esac
          fi

          # A server that accepts a key needs no prompt at all - including the `none`
          # method a Tailscale node authenticates with, where the tailnet ACL is the auth
          # (SQ-061). SQ-064: a server may accept BOTH, which is the branch the two-pass
          # collect connection exists for; the key wins there, exactly as ssh tries it
          # first.
          __key="$ACCEPTS_KEY"
          if [ "$AGENT_ONLY" = 1 ]; then
            # The key lives only in the key agent, so the `IdentityAgent=none` pass of
            # section 4.2 cannot use it and the second pass can. The option is read off
            # this ssh's own argv.
            if [ "$identity_agent" = none ]; then __key=0; else __key=1; fi
          fi

          __ok=0
          [ "$__key" = 1 ] && __ok=1
          if [ "$__ok" = 0 ] && [ -n "$host_password" ]; then
            __prompt_host="${host_key_alias:-$resolved_host}"
            if [ "$KBDINT" = 1 ]; then
              # SQ-062: keyboard-interactive is `(<user>@<host>) Password: `.
              __a=$(ask "(${session_user:-${USER:-alec}}@$__prompt_host) Password: " "")
            else
              # SQ-060: `<user>@<host>'s password: `, trailing space included.
              __a=$(ask "${session_user:-${USER:-alec}}@$__prompt_host's password: " "")
            fi
            [ "$__a" = "$host_password" ] && __ok=1
          fi
          if [ "$__ok" = 0 ]; then
            # SQ-052: the same bare sentence for a wrong password, a missing key agent, a
            # dead one and a locked one.
            say "Permission denied (publickey,password)."
            return 1
          fi
          return 0
        }

        # A ProxyJump hop `ssh` built itself, or one of ours. It runs its own inner
        # ProxyCommand first - the next hop down - and then records the target it was
        # given. Hop 1 dialling the *destination* instead of hop 2 is exactly what an
        # unescaped %h:%p produces (SQ-039).
        #
        # `ssh -G -W …` resolves and connects to nothing, so `-G` wins over every other
        # mode. That is what lets the askpass broker resolve a *hop* from the hop's own
        # argv, which is the only thing that tells two hops apart (`SQ-063`, section 4.2).
        if [ "$is_hop" = 1 ] && [ "$resolve" = 0 ]; then
          if [ -n "$proxy_command" ] && [ "$proxy_command" != none ]; then
            expanded=$(expand_proxy "$proxy_command")
            printf '%s\\n' "$expanded" >> "$STATE/proxy.log"
            /bin/sh -c "$expanded" </dev/null >/dev/null 2>&1
          fi
          printf '%s\\n' "$__argv" >> "$STATE/hops.log"
          printf '%s\\n' "$hop_target" >> "$STATE/hop-targets.log"
          # A hop authenticates like any other ssh, and its prompt names its own host, so
          # the agent can tell the hops apart only by the argv the askpass sends it
          # (`SQ-063`). It gets no control socket: a hop is a `-W` pipe, not a master.
          authenticate || exit 255
          exit 0
        fi

        if [ "$resolve" = 1 ]; then
          # `ssh -G` prints resolved values only, one lowercased keyword per line
          # (section 4.1). `hostname` is the one section 4.2 keys a password on, and it is
          # deliberately not the alias on the command line.
          printf 'host %s\\n' "$host"
          printf 'hostname %s\\n' "$resolved_host"
          printf 'port %s\\n' "$port"
          printf 'user %s\\n' "${session_user:-${USER:-alec}}"
          # A path may contain a space, so the accumulator is \\001-separated and never
          # word-split (section 9.2's quoting rule, applied to our own harness).
          printf '%s' "$identity_files" | tr '\\001' '\\n' | while IFS= read -r __f; do
            [ -n "$__f" ] && printf 'identityfile %s\\n' "$__f"
          done
          printf 'proxyjump %s\\n' "${proxy_jump:-none}"
          [ -n "$host_key_alias" ] && printf 'hostkeyalias %s\\n' "$host_key_alias"
          [ -n "$identity_agent" ] && printf 'identityagent %s\\n' "$identity_agent"
          exit 0
        fi

        # One master per control path, so a scenario can stand several of them up at
        # once (K6): `-O check` has to name the pid of the master that owns *this*
        # socket, not the pid of whichever master started last.
        pid_file() { printf '%s/pid.%s' "$STATE" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }

        if [ "$mode" = control ]; then
          case "$control_command" in
            check)
              if [ -e "$ctl" ]; then
                __owner=$(cat "$(pid_file "$ctl")" 2>/dev/null || cat "$STATE/master.pid" 2>/dev/null || echo 1)
                say "Master running (pid=$__owner)"
                exit 0
              fi
              # SQ-079: a dead master says this, and it must never be read as a refusal.
              say "Control socket connect($ctl): No such file or directory"
              exit 255 ;;
            exit)
              if [ -e "$ctl" ]; then
                # SQ-044, DESIGN.md section 6.1: the request reaches a master *through*
                # its socket, so it takes only one that is still serving it. A master
                # that has stopped serving - or one whose socket has already been
                # unlinked, the branch below - is left running, holding its connection
                # and its share of MaxSessions, which is why the sweep also kills.
                __owner=$(cat "$(pid_file "$ctl")" 2>/dev/null || echo "")
                rm -f "$ctl"
                if [ -n "$__owner" ] && [ -e "$STATE/serving.$__owner" ]; then
                  rm -f "$STATE/live.$__owner"
                fi
                say "Exit request sent."
                exit 0
              fi
              say "Control socket connect($ctl): No such file or directory"
              exit 255 ;;
            *) say "Invalid multiplex command."; exit 255 ;;
          esac
        fi

        # SQ-075: `kill -0` and `pgrep` both count a **zombie** as alive, so a mux client
        # that has been killed but not yet reaped would hold a session open for ever. The
        # process state is the one to read.
        __alive() {
          case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in
            ''|Z*) return 1 ;;
            *) return 0 ;;
          esac
        }

        run_session() {
          # SQ-021: MaxSessions counts the master's own session too, so a limit of 2
          # leaves exactly one spare beside the metadata channel.
          # Sessions are counted by which of them are still *open*, which is what sshd
          # does. A recorded pid that has gone is a channel that was closed - and a
          # killed mux client runs no cleanup of its own, so an EXIT trap could not be
          # the bookkeeping here any more than it can be on the server (SQ-069).
          __open=1                    # the master's own session (SQ-021)
          if [ -f "$STATE/sessions.log" ]; then
            while IFS= read -r __p; do
              [ -n "$__p" ] || continue
              __alive "$__p" && __open=$((__open + 1))
            done < "$STATE/sessions.log"
          fi
          if [ "$__open" -ge "$MAX_SESSIONS" ]; then
            say "mux_client_request_session: session request failed"
            exit 255
          fi
          printf '%s\\n' "$$" >> "$STATE/sessions.log"
          if [ -n "$FORCE_COMMAND" ]; then
            # SQ-013: a ForceCommand internal-sftp account answers with a plain sentence.
            printf '%s' "$FORCE_SENTENCE"
            exit 1
          fi
          # The channel's own stdin and stdout, handed straight to the account's shell -
          # no pipeline and no re-splitting of a command line (SQ-015's noise is printed
          # by the session shell itself, by whichever mechanism was verified to work).
          #
          # SQ-084: a shell prints a **job-status report** - `Killed`, `Terminated`, `User
          # defined signal 1` - on its own stderr when a foreground child dies by a signal,
          # and that byte is an artifact of this harness: no sshd sends it, and SQ-011 is
          # precisely the claim that a signal-killed remote command says *nothing*. Only
          # SIGINT and SIGPIPE are silent, and neither is usable (SIGPIPE is inherited
          # ignored, and SwiftPM leaves SIGINT ignored on Darwin), so the report is
          # suppressed instead: this shell's own stderr goes to /dev/null for the length of
          # the session, and the session's real stderr is handed over as fd 4, which
          # $SESSION_SHELL restores onto its fd 2 before it runs anything. dash writes the
          # report to the *command's* redirected stderr rather than its own, which is why
          # the handover cannot be spelled `"$SESSION_SHELL" 2>&3`.
          exec 4>&2 2>/dev/null
          "$SESSION_SHELL"
          __rc=$?
          exec 2>&4 4>&-
          # SQ-011: a remote command killed by a signal makes ssh return 255 with
          # NOTHING on stderr, indistinguishable at the exit code from a mux error.
          if [ "$__rc" -gt 128 ]; then exit 255; fi
          exit "$__rc"
        }

        if [ "$mode" = mux ] || [ "$mode" = subsystem ]; then
          if [ ! -e "$ctl" ]; then
            # SQ-042/SQ-079: with -F /dev/null, BatchMode=yes and ProxyCommand=/usr/bin/false
            # the client fails here rather than opening a second unsupervised connection.
            if [ "$config_file" = /dev/null ] && [ "$batch_mode" = yes ] && [ "$false_proxy" = 1 ]
            then
              say "Control socket connect($ctl): No such file or directory"
              say "mux_client_hello_exchange: write packet: Broken pipe"
              exit 255
            fi
            # SQ-042, the other half, and the whole reason those three options are
            # there: `ssh` does NOT fail a session open on a missing socket. It notes
            # it at debug level and makes a **direct connection of its own**, reading
            # the config files and authenticating from scratch - a second, unsupervised
            # connection with the config's own timeouts (verified against OpenSSH 9.6,
            # where only the `-O` commands fatal on a missing socket).
            printf '%s\n' "$__argv" >> "$STATE/fallback.log"
            if [ "$ACCEPTS_KEY" = 1 ]; then run_session; fi
            # And where the account needs a password there is nobody to answer it: the
            # agent mints no askpass token for a mux client (section 4.2), so the
            # fallback dies with the one sentence the exit classifier must NOT read as
            # an authentication failure.
            say "Permission denied (publickey,password)."
            exit 255
          fi
          run_session
        fi

        # --- master ---------------------------------------------------------------
        if [ -n "$proxy_command" ] && [ "$proxy_command" != none ]; then
          expanded=$(expand_proxy "$proxy_command")
          printf '%s\\n' "$expanded" >> "$STATE/proxy.log"
          /bin/sh -c "$expanded" </dev/null >/dev/null 2>&1
        elif [ "$proxy_set" = 1 ]; then
          # The ProxyCommand was discarded by an earlier ProxyJump=none (SQ-038): the
          # master resolves the inner hostname itself and dies.
          printf 'discarded\\n' >> "$STATE/proxy.log"
          say "ssh: Could not resolve hostname $host: Name or service not known"
          exit 255
        fi

        authenticate || exit 255

        # SQ-036: the identification string is printed only at DEBUG1 and above, which is
        # why the collect connection is the one ssh that can read it.
        case "$log_level" in
          DEBUG*|debug*)
            say "debug1: Remote protocol version 2.0, remote software version $IDENTIFICATION"
            say "debug1: Authentication succeeded (publickey)." ;;
        esac

        [ "$AUTH_DELAY" -gt 0 ] && sleep "$AUTH_DELAY"

        # SQ-043: a master that finds a socket already at its ControlPath does not fail
        # and does not take it over. It says so once, on stderr, and then runs with NO
        # socket at all - authenticated, holding the connection, and invisible to any
        # sweep that goes by sockets. A restarted location really can hold two of these.
        if [ -e "$ctl" ]; then
          say "ControlSocket $ctl already exists, disabling multiplexing"
          ctl=""
        else
          # The control socket appears only once authentication has succeeded, which is
          # the signal SSHMaster's deadline waits for. A real AF_UNIX socket where python3
          # can make one, so ControlSocket's S_IFSOCK check (SQ-074) sees what it expects.
          if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import socket,sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$ctl" 2>/dev/null || : > "$ctl"
          else
            : > "$ctl"
          fi
          printf '%s\\n' "$$" > "$(pid_file "$ctl")"
          printf '%s\\n' "$$" > "$STATE/master.pid"
          # A master that is *serving* its socket is one `-O exit` can take. With
          # SSHDRIVE_FAKESSH_MASTER=wedged it owns the socket and has stopped serving
          # it, which is the case section 6.1 says only the pid can reach.
          [ "$SSHDRIVE_FAKESSH_MASTER" = wedged ] || : > "$STATE/serving.$$"
        fi

        if [ "$control_persist" != no ]; then
          # SQ-041: with ControlPersist set ssh forks away and the agent loses the pid,
          # the stderr and the exit signal - even under -N.
          ( trap '' TERM; while [ -e "$ctl" ]; do sleep 1; done ) &
          exit 0
        fi

        # How this master ends, and it is deliberately NOT "when its socket file goes".
        # A real `ssh -N` does not watch that path: unlinking it makes the master
        # unreachable and leaves it running for ever (SQ-044), which is the failure the
        # sweep's kill exists for. So the lifetime hangs on a file only the master and a
        # served `-O exit` know about, and three shapes fall out of it:
        #   - serving its socket: `-O exit` removes the live file and the master goes;
        #   - wedged, or with no socket at all (SQ-043): nothing removes it, so the
        #     master survives every exit request and only a signal ends it;
        #   - socket unlinked from outside (SQ-044): likewise.
        # A master taken by a signal records itself, so a scenario can say which of the
        # three routes of section 6.1 actually took which master.
        : > "$STATE/live.$$"
        trap 'printf "%s\\n" "$$" >> "$STATE/terminated.log"; [ -n "$ctl" ] && rm -f "$ctl"; exit 0' TERM INT
        while [ -e "$STATE/live.$$" ]; do sleep 1; done
        exit 0
        """
    }
}
