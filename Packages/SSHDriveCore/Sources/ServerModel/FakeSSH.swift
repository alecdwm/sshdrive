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
public final class FakeSSH: @unchecked Sendable {

    /// The directory holding the stub, its state and its logs.
    public let directory: URL
    /// The path to write into `SSHProcess.sshBinaryPath`.
    public let executablePath: String
    public let profile: ServerProfile

    private let state: URL
    private var previousBinaryPath: String?

    public init(profile: ServerProfile, hostKeyKnown: Bool = true,
                authenticationDelay: TimeInterval = 0) throws {
        self.profile = profile
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-fakessh-\(UUID().uuidString)")
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
        previousBinaryPath = SSHProcess.sshBinaryPath
        SSHProcess.sshBinaryPath = executablePath
    }

    public func uninstall() {
        if let previousBinaryPath {
            SSHProcess.sshBinaryPath = previousBinaryPath
            self.previousBinaryPath = nil
        }
        try? FileManager.default.removeItem(at: directory)
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

        mode=master
        ctl=""
        control_command=""
        proxy_command=""
        proxy_set=0          # SQ-038: readconf takes the FIRST setting of the field.
        log_level=ERROR
        port=22
        host=""
        is_hop=0
        control_persist=no
        session_user=""
        command_words=""
        seen_host=0

        while [ $# -gt 0 ]; do
          case "$1" in
            -N) mode=master ;;
            -W) is_hop=1; hop_target="$2"; shift ;;
            -G) mode=resolve ;;
            -S) ctl="$2"; mode=mux; shift ;;
            -O) control_command="$2"; mode=control; shift ;;
            -s) mode=subsystem ;;
            -F) shift ;;
            -l) session_user="$2"; shift ;;
            -p) port="$2"; shift ;;
            -o)
              __k=$(printf '%s' "$2" | cut -d= -f1)
              __v=$(printf '%s' "$2" | cut -d= -f2-)
              case "$__k" in
                ControlPath) [ -z "$ctl" ] && ctl="$__v" ;;
                ControlPersist) control_persist="$__v" ;;
                LogLevel) log_level="$__v" ;;
                Port) port="$__v" ;;
                # SQ-038: ProxyCommand and ProxyJump write the same field, and readconf
                # keeps the first setting of it. `ProxyJump=none` written first therefore
                # marks the field set and the ProxyCommand after it is DISCARDED.
                ProxyCommand)
                  if [ "$proxy_set" = 0 ]; then proxy_command="$__v"; proxy_set=1; fi ;;
                ProxyJump)
                  if [ "$proxy_set" = 0 ]; then
                    proxy_set=1
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

        __mark=$(printf '\\001')
        expand_proxy() {
          # SQ-039: ssh percent-expands the WHOLE ProxyCommand before /bin/sh -c sees it,
          # including a nested hop's own %h/%p - ONE pass, with %% held aside first. Doing
          # the %% last would expand a nested hop's marker too, which is the bug this
          # reproduces rather than papers over.
          printf '%s' "$1" |
            sed -e "s/%%/$__mark/g" -e "s/%h/$host/g" -e "s/%p/$port/g" -e "s/$__mark/%/g"
        }

        # A ProxyJump hop `ssh` built itself, or one of ours. It runs its own inner
        # ProxyCommand first - the next hop down - and then records the target it was
        # given. Hop 1 dialling the *destination* instead of hop 2 is exactly what an
        # unescaped %h:%p produces (SQ-039).
        if [ "$is_hop" = 1 ]; then
          if [ -n "$proxy_command" ] && [ "$proxy_command" != none ]; then
            expanded=$(expand_proxy "$proxy_command")
            printf '%s\\n' "$expanded" >> "$STATE/proxy.log"
            /bin/sh -c "$expanded" </dev/null >/dev/null 2>&1
          fi
          printf '%s\\n' "$__argv" >> "$STATE/hops.log"
          printf '%s\\n' "$hop_target" >> "$STATE/hop-targets.log"
          exit 0
        fi

        if [ "$mode" = resolve ]; then
          printf 'host %s\\n' "$host"
          printf 'port %s\\n' "$port"
          printf 'user %s\\n' "${USER:-alec}"
          printf 'proxyjump none\\n'
          exit 0
        fi

        if [ "$mode" = control ]; then
          case "$control_command" in
            check)
              if [ -e "$ctl" ]; then
                say "Master running (pid=$(cat "$STATE/master.pid" 2>/dev/null || echo 1))"
                exit 0
              fi
              # SQ-079: a dead master says this, and it must never be read as a refusal.
              say "Control socket connect($ctl): No such file or directory"
              exit 255 ;;
            exit)
              if [ -e "$ctl" ]; then rm -f "$ctl"; say "Exit request sent."; exit 0; fi
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
          "$SESSION_SHELL"
          __rc=$?
          # SQ-011: a remote command killed by a signal makes ssh return 255 with
          # NOTHING on stderr, indistinguishable at the exit code from a mux error.
          if [ "$__rc" -gt 128 ]; then exit 255; fi
          exit "$__rc"
        }

        if [ "$mode" = mux ] || [ "$mode" = subsystem ]; then
          if [ ! -e "$ctl" ]; then
            # SQ-042/SQ-079: with -F /dev/null, BatchMode=yes and ProxyCommand=/usr/bin/false
            # the client fails here rather than opening a second unsupervised connection.
            say "Control socket connect($ctl): No such file or directory"
            say "mux_client_hello_exchange: write packet: Broken pipe"
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

        if [ "$HOST_KEY_KNOWN" != 1 ]; then
          # SQ-047: the host-key question reaches askpass with SSH_ASKPASS_PROMPT UNSET,
          # exactly like a password. Classifying on the hint would answer a stored
          # password to "Are you sure you want to continue connecting".
          answer=$(ask "The authenticity of host '$host' can't be established.
        ED25519 key fingerprint is SHA256:0000000000000000000000000000000000000000000.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])? " "")
          case "$answer" in
            yes|YES) : ;;
            *) say "Host key verification failed."; exit 255 ;;
          esac
        fi

        authenticated=0
        # A server that accepts a key needs no prompt at all - including the `none` method
        # a Tailscale node authenticates with, where the tailnet ACL is the auth (SQ-061).
        # SQ-064: a server may accept BOTH, which is the branch the two-pass collect
        # connection exists for; the key wins there, exactly as ssh tries it first.
        if [ "$ACCEPTS_KEY" = 1 ]; then authenticated=1; fi
        if [ "$authenticated" = 0 ] && [ -n "$PASSWORD" ]; then
          if [ "$KBDINT" = 1 ]; then
            # SQ-062: keyboard-interactive is `(<user>@<host>) Password: `.
            answer=$(ask "(${session_user:-${USER:-alec}}@$host) Password: " "")
          else
            # SQ-060: `<user>@<host>'s password: `, trailing space included.
            answer=$(ask "${session_user:-${USER:-alec}}@$host's password: " "")
          fi
          [ "$answer" = "$PASSWORD" ] && authenticated=1
        fi
        if [ "$authenticated" = 0 ]; then
          # SQ-052: the same bare sentence for a wrong password, a missing key agent, a
          # dead one and a locked one.
          say "Permission denied (publickey,password)."
          exit 255
        fi

        # SQ-036: the identification string is printed only at DEBUG1 and above, which is
        # why the collect connection is the one ssh that can read it.
        case "$log_level" in
          DEBUG*|debug*)
            say "debug1: Remote protocol version 2.0, remote software version $IDENTIFICATION"
            say "debug1: Authentication succeeded (publickey)." ;;
        esac

        [ "$AUTH_DELAY" -gt 0 ] && sleep "$AUTH_DELAY"

        # The control socket appears only once authentication has succeeded, which is the
        # signal SSHMaster's deadline waits for. A real AF_UNIX socket where python3 can
        # make one, so ControlSocket's S_IFSOCK check (SQ-074) sees what it expects.
        if command -v python3 >/dev/null 2>&1; then
          python3 -c 'import socket,sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)' "$ctl" 2>/dev/null || : > "$ctl"
        else
          : > "$ctl"
        fi
        printf '%s\\n' "$$" > "$STATE/master.pid"

        if [ "$control_persist" != no ]; then
          # SQ-041: with ControlPersist set ssh forks away and the agent loses the pid,
          # the stderr and the exit signal - even under -N.
          ( trap '' TERM; while [ -e "$ctl" ]; do sleep 1; done ) &
          exit 0
        fi

        trap 'rm -f "$ctl"; exit 0' TERM INT
        while [ -e "$ctl" ]; do sleep 1; done
        exit 0
        """
    }
}
