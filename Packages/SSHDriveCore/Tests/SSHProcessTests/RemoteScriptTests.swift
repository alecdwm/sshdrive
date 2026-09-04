import XCTest
@testable import SSHProcess

/// The `sh -s` script (DESIGN.md section 9.2) and the heartbeat wrapper (section 6.4).
final class RemoteScriptTests: XCTestCase {

    private let sentinel = Sentinel(hex: "0123456789abcdef0123456789abcdef")

    func testTheSentinelIsPrintedFirstAndInItsOwnPrintf() {
        let script = RemoteScript(sentinel: sentinel, body: "echo hello")
        let lines = script.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "{", "the whole script is one compound command")
        XCTAssertEqual(lines.last, "}")
        XCTAssertEqual(lines[1], "printf '%s' '0123456789abcdef0123456789abcdef'; printf '\\000'")
        // Never `printf '\0<sentinel>'`: printf reads \0 plus the following octal digits
        // as one character, so a sentinel beginning with a digit loses its first bytes.
        XCTAssertFalse(script.text.contains("\\0\(sentinel.hex)"))
    }

    /// Values are embedded single-quoted and passed through `set --` so the commands see
    /// them as "$@". A directory named `$(rm -rf ~)` must never reach a shell as code.
    func testValuesTravelThroughSetDashDash() {
        let script = RemoteScript(
            sentinel: sentinel,
            arguments: ["data/weird/$(echo pwned)", "quote'name", "space in name"],
            body: "for r in \"$@\"; do printf '%s\\0' \"$r\"; done"
        )
        XCTAssertTrue(script.text.contains(
            "set -- 'data/weird/$(echo pwned)' 'quote'\\''name' 'space in name'"
        ), script.text)
    }

    func testNoHeartbeatMeansTheBodyRunsInTheForeground() {
        let script = RemoteScript(sentinel: sentinel, body: "find data -print0")
        XCTAssertFalse(script.text.contains("__sd_child"))
        XCTAssertTrue(script.text.contains("find data -print0"))
        XCTAssertTrue(script.text.contains("exit $?"), "the body's status is still the script's")
    }

    /// A compound command has to be parsed in full before any of it runs, which is what
    /// stops dash's block-buffered stdin reader swallowing the script's own tail once the
    /// heartbeat loop starts reading (section 9.2).
    func testTheWholeScriptIsOneCompoundCommandEndingInAnExit() {
        for script in [
            RemoteScript(sentinel: sentinel, body: "true"),
            RemoteScript(sentinel: sentinel, body: "true", heartbeat: .standard),
        ] {
            let lines = script.text.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, "{")
            XCTAssertEqual(lines.last, "}")
            XCTAssertTrue(lines.contains { $0.hasPrefix("exit ") })
        }
    }

    /// Nothing is ever started bare: the wrapper backgrounds its child with </dev/null so
    /// the child cannot swallow the heartbeat lines, reads stdin, and kills the child
    /// after 60 s of silence or EOF.
    func testHeartbeatWrapperShape() {
        let script = RemoteScript(
            sentinel: sentinel, body: "sleep 300", heartbeat: .standard
        )
        let text = script.text
        XCTAssertTrue(text.contains("} </dev/null &"), "the child never shares the script's stdin")
        XCTAssertTrue(text.contains("__sd_child=$!"))
        // `IFS= read -r`, not a bare `read`: since milestone 9 the wrapper may relay the
        // line it read to the helper, and `read` without -r eats backslashes while the
        // default IFS strips leading and trailing spaces - both of which a JSON control
        // line and a filename inside one need kept.
        XCTAssertTrue(text.contains("IFS= read -r -t 60 __sd_line || break"))
        XCTAssertTrue(text.contains("sleep 15"), "the dash branch's watchdog tick")
        XCTAssertTrue(text.contains("exec 7<&0") && text.contains("done <&7"),
                      "a background child's fd 0 is /dev/null; stdin must be duplicated in the parent")
        XCTAssertTrue(text.contains("-ge 4"), "60 s of silence at 15 s a tick")
        XCTAssertTrue(text.contains("trap '' TERM"), "the wrapper survives its own group kill")
        // Every subshell inherits the EXIT trap and would delete the stamp when it exits,
        // which makes the watchdog kill a healthy child seconds after it started.
        XCTAssertEqual(text.components(separatedBy: "trap - EXIT").count - 1, 3,
                       "the child, the read -t probe and the reader all clear the EXIT trap")
        XCTAssertTrue(text.contains("kill -TERM 0"))
        XCTAssertTrue(text.contains("kill -KILL 0"))
    }

    func testHeartbeatSettingsChangeTheTickCount() {
        let script = RemoteScript(
            sentinel: sentinel, body: "true",
            heartbeat: .init(intervalSeconds: 5, timeoutSeconds: 20)
        )
        XCTAssertTrue(script.text.contains("IFS= read -r -t 20 __sd_line || break"))
        XCTAssertTrue(script.text.contains("sleep 5"))
        XCTAssertTrue(script.text.contains("-ge 4"))
    }

    func testHeartbeatLineIsOneLine() {
        XCTAssertEqual(String(decoding: RemoteScript.heartbeatLine, as: UTF8.self), ".\n")
    }

    /// The `read -t` branch is chosen by the script itself, in a subshell, so a dash
    /// `read: Illegal option -t` cannot take the shell down with it.
    func testReadTimeoutDetectionRunsInASubshell() {
        let script = RemoteScript(sentinel: sentinel, body: "true", heartbeat: .standard)
        XCTAssertTrue(script.text.contains(
            "if ( trap - EXIT; exec 2>/dev/null; read -t 1 __sd_probe </dev/null; [ $? -le 1 ] ); then"
        ), script.text)
    }

    // MARK: The helper's stdin relay (section 6.4 tier 2)

    /// Section 9.2 says background children never share the script's stdin, and section
    /// 6.4 says the helper is fed its root set and its pings on stdin. Both cannot be the
    /// channel's stdin. The wrapper stays the only reader and relays what it reads into a
    /// FIFO the child is given instead.
    func testTheRelayMakesAFifoAndFeedsTheChildFromIt() {
        let script = RemoteScript(
            sentinel: sentinel, body: "exec helper", heartbeat: .standard,
            stdinRelay: "/home/a/.cache/sshdrive/.sshdrive-helper-in-7")
        let text = script.text
        XCTAssertTrue(text.contains("mkfifo \"$__sd_relay\""), text)
        XCTAssertTrue(text.contains("__sd_relay='/home/a/.cache/sshdrive/.sshdrive-helper-in-7'"), text)
        // The child reads the FIFO, never the channel: `</dev/null` is what it falls back
        // to, and `$__sd_stdin` is one or the other.
        XCTAssertTrue(text.contains("} <\"$__sd_stdin\" &"), text)
        XCTAssertFalse(text.contains("} </dev/null &"), text)
        // The write end is opened *after* the child was started with the read end. Both
        // opens block until the other appears; the other order deadlocks the wrapper.
        let child = text.range(of: "__sd_child=$!")!
        let open = text.range(of: "exec 8>\"$__sd_relay\"")!
        XCTAssertTrue(child.upperBound < open.lowerBound, text)
    }

    /// A server where `mkfifo` fails is not a failure: the child runs with no stdin, which
    /// is what every other remote command gets, and the wrapper is its only kill switch.
    func testAFailedMkfifoLeavesTheChildWithNoStdin() {
        let script = RemoteScript(
            sentinel: sentinel, body: "exec helper", heartbeat: .standard, stdinRelay: "/tmp/r")
        XCTAssertTrue(script.text.contains("__sd_stdin=/dev/null"), script.text)
        XCTAssertTrue(script.text.contains("\(RemoteScript.relayFlagVariable)=0"), script.text)
    }

    /// Without a relay the wrapper is byte for byte what milestone 6 measured against
    /// `deb`, `alp` and `bashbg`: `</dev/null`, no FIFO, no fd 8.
    func testAScriptWithNoRelayIsUnchanged() {
        let script = RemoteScript(sentinel: sentinel, body: "find .", heartbeat: .standard)
        let text = script.text
        XCTAssertTrue(text.contains("} </dev/null &"), text)
        XCTAssertFalse(text.contains("mkfifo"), text)
        XCTAssertFalse(text.contains(">&8"), text)
    }

    /// Both heartbeat branches relay - the `read -t` one that bash and busybox take and
    /// the `sleep`-and-mtime watchdog that dash takes, which is the ordinary Linux path.
    func testBothHeartbeatBranchesRelayTheLine() {
        let script = RemoteScript(
            sentinel: sentinel, body: "exec helper", heartbeat: .standard, stdinRelay: "/tmp/r")
        let relays = script.text.components(separatedBy: "printf '%s\\n' \"$__sd_line\" >&8").count - 1
        XCTAssertEqual(relays, 2, script.text)
        // `IFS= read -r`, because a control line is JSON: an unescaped `read` would eat
        // backslashes and strip leading spaces out of a filename.
        XCTAssertTrue(script.text.contains("IFS= read -r"), script.text)
    }

    /// The relay FIFO is cleaned up on every exit path, like the stamp files.
    func testTheRelayIsRemovedOnTheWayOut() {
        let script = RemoteScript(
            sentinel: sentinel, body: "exec helper", heartbeat: .standard, stdinRelay: "/tmp/r")
        XCTAssertTrue(
            script.text.contains("trap 'rm -f \"$__sd_stamp\" \"$__sd_mark\" \"$__sd_relay\" 2>/dev/null' EXIT"),
            script.text)
        XCTAssertTrue(script.text.contains("exec 8>&- 2>/dev/null"), script.text)
    }
}
