import XCTest
@testable import SSHProcess

/// Spike S2/S7 against `deb-shells`: the section 9.2 sentinel under every login-shell
/// shape, the section 6.1 login-shell snapshot command under the same shells, and the
/// `ForceCommand` case. Gated on `SSHDRIVE_TESTBED=1`.
final class TestbedShellTests: XCTestCase {

    private var masters: [SSHMaster] = []

    override func tearDown() async throws {
        for master in masters { await master.shutdown() }
        masters = []
        Testbed.reapHopChildren()
    }

    private func master(user: String) async throws -> SSHMaster {
        let master = try Testbed.master(host: "spike-shells", user: user)
        masters.append(master)
        try await master.connect()
        return master
    }

    /// rc files print on every non-interactive startup; the sentinel is what makes the
    /// output usable anyway. Every shape in the testbed, including the account whose rc
    /// leaves a background child holding stdout so EOF never arrives.
    func testSentinelDiscardsRcOutputOnEveryLoginShell() async throws {
        try Testbed.skipUnlessEnabled()
        for user in ["bashnoisy", "bashbg", "zshuser", "fishuser", "tcshuser", "dashuser"] {
            let master = try await master(user: user)
            let (payload, prefix) = try await Testbed.runScript(
                on: master,
                body: "printf 'ID:%s\\000' \"$(id -un)\"",
                timeout: 25
            )
            XCTAssertEqual(
                String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self),
                "ID:\(user)",
                "\(user): the script's own output must survive its rc noise"
            )
            if user != "dashuser" {
                XCTAssertFalse(prefix.isEmpty, "\(user) prints rc noise; it must land in the prefix")
            }
        }
    }

    /// `bashbg` leaves `( sleep 300 & )` holding stdout, so a reader that waited for EOF
    /// would hang for ever. Reading to the sentinel returns in seconds.
    func testBashbgDoesNotHangTheReader() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(user: "bashbg")
        let started = Date()
        let (payload, _) = try await Testbed.runScript(
            on: master, body: "printf 'done\\000'", timeout: 30
        )
        XCTAssertEqual(String(decoding: payload.dropLast(), as: UTF8.self), "done")
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "the sentinel, not EOF, ends the read")
    }

    /// Values reach the script through `set --` and are never parsed by the login shell:
    /// the testbed's `weird/` tree exists for exactly this.
    func testAwkwardNamesSurviveSetDashDash() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(user: "bashnoisy")
        let awkward = ["$(echo pwned)", "quote'name", "space in name", "back\\slash", "*star*"]
        let (payload, _) = try await Testbed.runScript(
            on: master,
            body: "for __r in \"$@\"; do printf '%s\\000' \"$__r\"; done",
            arguments: awkward,
            timeout: 25
        )
        let records = payload.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(records, awkward)
    }

    /// The section 6.1 snapshot command, run by each of the login shells the testbed has.
    /// The snapshot itself is local to the Mac; what is under test here is the claim that
    /// the command line is valid in every shell and that the closing sentinel returns the
    /// answer before the timeout even when a background child holds stdout open.
    func testLoginShellSnapshotCommandUnderEveryShell() async throws {
        try Testbed.skipUnlessEnabled()
        for user in ["bashnoisy", "bashbg", "zshuser", "fishuser", "tcshuser", "dashuser"] {
            let master = try await master(user: user)
            let sentinel = Sentinel()
            let command = LoginShellSnapshotReader.snapshotCommand(sentinel: sentinel)
            // csh and tcsh accept -l only when it is the sole flag, so those two run -ic.
            let body = """
            case "$SHELL" in
              *csh) __f=-ic ;;
              *) __f=-ilc ;;
            esac
            exec "$SHELL" "$__f" "$1"
            """
            let script = RemoteScript(arguments: [command], body: body)
            let channel = try await master.openExecChannel(script: script, readinessDeadline: 30)
            defer { channel.close() }

            var parser = SentinelParser(sentinel: sentinel)
            let started = Date()
            let deadline = started.addingTimeInterval(20)
            do {
                try await channel.stream.drain(deadline: deadline) { chunk in
                    parser.append(chunk)
                    return parser.sawClosingSentinel
                }
            } catch { /* a deadline is a failure of the assertion below, not of the test */ }
            parser.finish()

            XCTAssertTrue(parser.sawClosingSentinel,
                          "\(user): no closing sentinel; prefix was \"\(parser.prefixText)\"")
            let environment = parser.environment
            XCTAssertNotNil(environment["PATH"], "\(user): PATH")
            XCTAssertFalse(environment["PATH"]?.isEmpty ?? true, "\(user): PATH is empty")
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, "\(user): returned before the timeout")
            if user == "fishuser" {
                // env -0 rather than a printf of the two variables: in fish "$PATH"
                // expands to the list joined by spaces, not colons.
                XCTAssertTrue(environment["PATH"]!.contains(":"), "fish: PATH is still colon-separated")
            }
        }
    }

    /// A `ForceCommand internal-sftp` account must be reported as "no shell access", not
    /// as "shell output unusable" - the probe's answer decides whether `add` tells the
    /// user to fix an rc file or that the account has no shell at all.
    func testForceCommandAccountIsReportedAsNoShellAccess() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(user: "forcesftp")
        do {
            let channel = try await master.openExecChannel(
                script: RemoteScript(body: "printf 'never\\000'"), readinessDeadline: 15
            )
            channel.close()
            XCTFail("forcesftp must not give us a shell")
        } catch SSHProcessError.noShellAccess(let prefix) {
            XCTAssertFalse(prefix.isEmpty)
        } catch {
            XCTFail("expected no-shell-access, got \(error) ")
        }
    }
}
