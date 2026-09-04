import Foundation

/// A script for an exec channel (DESIGN.md section 9.2).
///
/// The command line is constant: every exec channel runs exactly `sh -s`, so nothing from
/// the user, the config or the server ever reaches the account's login shell, which may be
/// bash, zsh, fish or csh, each with its own quoting rules. The script arrives on stdin
/// and is parsed by POSIX `sh`, whose quoting we control: values are embedded
/// single-quoted and passed through `set --` so the commands see them as `"$@"`.
public struct RemoteScript: Sendable, Equatable {
    /// Printed first, so the agent can discard the rc output in front of it.
    public let sentinel: Sentinel
    /// Values the body reads as `"$@"`. A directory named `$(rm -rf ~)` is one of these.
    public let arguments: [String]
    /// POSIX `sh`, and only what a `dash` or busybox `sh` also parses.
    public let body: String
    /// When set, the body is started in the background with `</dev/null` under the
    /// heartbeat wrapper of section 6.4, so nothing we start outlives the connection.
    public let heartbeat: HeartbeatSettings?

    public struct HeartbeatSettings: Sendable, Equatable {
        /// The agent writes a line this often. Keep it comfortably above one second:
        /// the dash branch's watchdog compares stamp mtimes with `test -nt`, which reads
        /// whole seconds, so a heartbeat landing in the same second as the previous tick
        /// reads as a miss.
        public var intervalSeconds: Int
        /// Silence for this long, or EOF, kills the child.
        public var timeoutSeconds: Int
        public init(intervalSeconds: Int = 15, timeoutSeconds: Int = 60) {
            self.intervalSeconds = intervalSeconds
            self.timeoutSeconds = timeoutSeconds
        }
        public static let standard = HeartbeatSettings()
    }

    public init(sentinel: Sentinel = Sentinel(), arguments: [String] = [],
                body: String, heartbeat: HeartbeatSettings? = nil) {
        self.sentinel = sentinel
        self.arguments = arguments
        self.body = body
        self.heartbeat = heartbeat
    }

    /// One heartbeat line. The content is ignored; only its arrival matters.
    public static let heartbeatLine = Data(".\n".utf8)

    /// The bytes written to the channel's stdin.
    ///
    /// The whole script is one brace group ending in an `exit`. That is not decoration:
    /// `sh -s` reads its script from the same stdin the heartbeat lines arrive on, and
    /// dash reads that stdin in blocks (§9.2). Left as a flat sequence of commands, a
    /// script longer than dash's read block has its tail still sitting in the pipe when
    /// the wrapper's reader starts consuming stdin - the reader eats the rest of the
    /// script, and dash then reads a heartbeat line as a command. `.` is a POSIX *special*
    /// builtin, so `.` with no argument ends a non-interactive shell on the spot, and the
    /// channel dies about ten seconds in. A compound command must be parsed in full before
    /// any of it runs, so the group forces dash to read the script to its end first, and
    /// the `exit` inside it stops the shell ever reading stdin as script again. Measured
    /// against `deb` on 2026-09-04.
    public var text: String {
        var lines: [String] = []
        // The sentinel first, in its own printf so the NUL cannot swallow a leading hex
        // digit through printf's `\0ddd` octal escape.
        lines.append("printf '%s' \(ShellQuoting.singleQuoted(sentinel.hex)); printf '\\000'")
        if !arguments.isEmpty {
            lines.append("set -- " + arguments.map(ShellQuoting.singleQuoted).joined(separator: " "))
        }
        if let heartbeat {
            lines.append(contentsOf: wrapper(heartbeat))
        } else {
            lines.append(body)
            lines.append("exit $?")
        }
        return "{\n" + lines.joined(separator: "\n") + "\n}\n"
    }

    public var data: Data { Data(text.utf8) }

    /// The section 6.4 wrapper: start the child in the background with its stdin from
    /// `/dev/null`, so it cannot swallow the heartbeat lines, then read stdin; when no
    /// line has arrived for the timeout, or stdin hits EOF, kill the child and exit.
    ///
    /// Two branches because `read -t` exists in bash, zsh, ksh and busybox and not in
    /// dash. Which one is taken is decided by the script itself rather than by the probe,
    /// with a subshell so a `read: Illegal option -t` cannot take the shell down; the
    /// probe still records the answer for `status`.
    ///
    /// The kill is a TERM to our own process group, with TERM ignored first so the
    /// wrapper survives to send the KILL. sshd gives the session its own process group, so
    /// this reaches the child and everything it started - a `( sleep 300 & )` included -
    /// and nothing outside the session. Signalling only `$!` would leave the child's own
    /// background children alive, which is the case this wrapper exists for.
    private func wrapper(_ settings: HeartbeatSettings) -> [String] {
        let ticks = max(1, settings.timeoutSeconds / max(1, settings.intervalSeconds))
        // Deliberately unquoted: `${TMPDIR:-/tmp}` and `$$` are meant to expand, and the
        // only other part is our own hex. Quoting it turned the path into a literal
        // `${TMPDIR:-/tmp}/…`, and a redirection failure on `:` - a POSIX *special*
        // builtin - makes a non-interactive `dash` exit on the spot, which took the
        // whole wrapper down and left the child running (measured 2026-09-04).
        let stamp = "${TMPDIR:-/tmp}/sshdrive-hb-\(sentinel.short).$$"
        let fallback = "/tmp/sshdrive-hb-\(sentinel.short).$$"
        return [
            "__sd_stamp=\(stamp)",
            // `touch`, never `: >`, for the same reason: a plain utility's failure is a
            // status, a special builtin's is the end of the shell.
            "touch \"$__sd_stamp\" 2>/dev/null || __sd_stamp=\(fallback)",
            "touch \"$__sd_stamp\" 2>/dev/null || true",
            "__sd_mark=\"$__sd_stamp.m\"",
            "trap 'rm -f \"$__sd_stamp\" \"$__sd_mark\" 2>/dev/null' EXIT",
            "{",
            // Every subshell inherits that EXIT trap and runs it when *it* exits. Without
            // clearing it here and below, the one-second `read -t` probe deletes the stamp
            // the moment it finishes, the watchdog sees it gone on its first tick and
            // kills the child about five seconds in - the wrapper killing its own healthy
            // child, which looks exactly like the failure it exists to prevent. Measured
            // against `deb` on 2026-09-04.
            "trap - EXIT",
            body,
            "} </dev/null &",
            "__sd_child=$!",
            "__sd_readt=0",
            "if ( trap - EXIT; exec 2>/dev/null; read -t 1 __sd_probe </dev/null; [ $? -le 1 ] ); then __sd_readt=1; fi",
            "if [ \"$__sd_readt\" = 1 ]; then",
            "  while :; do read -t \(settings.timeoutSeconds) __sd_line || break; done",
            "else",
            // The heartbeat reader has to be handed the channel's stdin on a descriptor
            // of its own. With job control off - which it always is for a script on stdin
            // - a background child's fd 0 is replaced by /dev/null, and `<&0` on the
            // child cannot recover it: the shell replaces fd 0 in the forked child and
            // only then applies the command's redirections, so `<&0` duplicates
            // /dev/null. The reader then sees EOF at once, deletes the stamp, and the
            // watchdog kills a perfectly healthy child on its first tick - the wrapper
            // killing the thing it exists to protect. Duplicating stdin in the *parent*
            // is what survives the fork. Measured against `deb` on 2026-09-04.
            "  exec 7<&0",
            "  ( trap - EXIT; while read __sd_line; do touch \"$__sd_stamp\" 2>/dev/null; done <&7; rm -f \"$__sd_stamp\" ) &",
            "  __sd_misses=0",
            "  while :; do",
            "    sleep \(settings.intervalSeconds)",
            "    [ -e \"$__sd_stamp\" ] || break",
            "    if [ ! -e \"$__sd_mark\" ] || [ \"$__sd_stamp\" -nt \"$__sd_mark\" ]; then",
            "      __sd_misses=0",
            "    else",
            "      __sd_misses=$((__sd_misses + 1))",
            "      [ \"$__sd_misses\" -ge \(ticks) ] && break",
            "    fi",
            "    touch \"$__sd_mark\" 2>/dev/null",
            "  done",
            "fi",
            "trap '' TERM",
            "kill -TERM \"$__sd_child\" 2>/dev/null",
            "kill -TERM 0 2>/dev/null",
            "sleep 2",
            "rm -f \"$__sd_stamp\" \"$__sd_mark\" 2>/dev/null",
            "kill -KILL 0 2>/dev/null",
            "exit 0",
        ]
    }
}
