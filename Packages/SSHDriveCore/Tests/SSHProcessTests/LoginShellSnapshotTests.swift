import XCTest
@testable import SSHProcess

/// The login shell snapshot (DESIGN.md section 6.1). The command has to be valid in every
/// shell, so its shape is asserted here and its behaviour against fish, tcsh and an rc
/// file that holds stdout open is an integration test.
final class LoginShellSnapshotTests: XCTestCase {

    private let sentinel = Sentinel(hex: "0123456789abcdef0123456789abcdef")

    func testCommandUsesOnlyWhatEveryShellParsesTheSameWay() {
        let command = LoginShellSnapshotReader.snapshotCommand(sentinel: sentinel)
        XCTAssertEqual(
            command,
            "/usr/bin/printf '\\000'; /usr/bin/printf '%s' '0123456789abcdef0123456789abcdef'; "
            + "/usr/bin/printf '\\000'; /usr/bin/env -0; "
            + "/usr/bin/printf '%s' '0123456789abcdef0123456789abcdef'; /usr/bin/printf '\\000'"
        )
        // Absolute-path commands, `;`, and quoted arguments that contain no variables.
        XCTAssertFalse(command.contains("$"))
        XCTAssertFalse(command.contains("\""))
        // env -0 rather than a printf of the two variables: in fish "$PATH" expands to the
        // list joined by spaces, not colons.
        XCTAssertTrue(command.contains("/usr/bin/env -0"))
    }

    /// csh and tcsh accept -l only when it is the sole flag, so those two run -ic.
    func testCshFamilyIsDetected() {
        XCTAssertTrue(LoginShellSnapshotReader.isCshFamily("/bin/tcsh"))
        XCTAssertTrue(LoginShellSnapshotReader.isCshFamily("/usr/local/bin/csh"))
        XCTAssertFalse(LoginShellSnapshotReader.isCshFamily("/bin/zsh"))
        XCTAssertFalse(LoginShellSnapshotReader.isCshFamily("/opt/homebrew/bin/fish"))
    }

    func testLoginShellComesFromGetpwuid() {
        let shell = LoginShellSnapshotReader.loginShellPath()
        XCTAssertTrue(shell.hasPrefix("/"), shell)
    }

    /// Only PATH and SSH_AUTH_SOCK are taken; nothing else from the shell leaks into
    /// ssh's environment, and a failed snapshot leaves launchd's values alone.
    func testOnlyTwoVariablesAreApplied() {
        var snapshot = LoginShellSnapshot(shell: "/bin/zsh")
        snapshot.path = "/opt/homebrew/bin:/usr/bin"
        snapshot.sshAuthSock = "/tmp/agent"
        snapshot.succeeded = true
        let applied = snapshot.applied(to: ["PATH": "/usr/bin:/bin", "HOME": "/Users/alec", "TERM": "dumb"])
        XCTAssertEqual(applied["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(applied["SSH_AUTH_SOCK"], "/tmp/agent")
        XCTAssertEqual(applied["HOME"], "/Users/alec")

        var failed = LoginShellSnapshot(shell: "/bin/zsh")
        failed.path = "/should/not/be/used"
        XCTAssertEqual(failed.applied(to: ["PATH": "/usr/bin:/bin"])["PATH"], "/usr/bin:/bin")
    }

    /// A snapshot with no SSH_AUTH_SOCK removes launchd's, rather than leaving the system
    /// ssh-agent's in place under a shell that unset it.
    func testAbsentAuthSockIsRemovedNotInherited() {
        var snapshot = LoginShellSnapshot(shell: "/bin/zsh")
        snapshot.path = "/usr/bin"
        snapshot.succeeded = true
        XCTAssertNil(snapshot.applied(to: ["SSH_AUTH_SOCK": "/private/tmp/launchd/Listeners"])["SSH_AUTH_SOCK"])
    }

    /// The identityagent the check probes: `ssh -G`'s value wins, and only when it is
    /// unset or literally SSH_AUTH_SOCK does the snapshot's variable apply.
    func testIdentityAgentSocketSelection() {
        var snapshot = LoginShellSnapshot(shell: "/bin/zsh")
        snapshot.sshAuthSock = "/private/tmp/com.apple.launchd/Listeners"
        snapshot.succeeded = true
        XCTAssertEqual(
            IdentityAgentCheck.socketPath(
                resolvedIdentityAgent: "/Users/alec/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
                snapshot: snapshot),
            "/Users/alec/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        )
        XCTAssertEqual(
            IdentityAgentCheck.socketPath(resolvedIdentityAgent: "SSH_AUTH_SOCK", snapshot: snapshot),
            snapshot.sshAuthSock
        )
        XCTAssertEqual(
            IdentityAgentCheck.socketPath(resolvedIdentityAgent: nil, snapshot: snapshot),
            snapshot.sshAuthSock
        )
        XCTAssertNil(IdentityAgentCheck.socketPath(resolvedIdentityAgent: "none", snapshot: snapshot))
    }

    func testMissingSocketIsATransientFailureWithSshNeverRun() {
        let path = NSTemporaryDirectory() + "/sshdrive-test-no-such-agent-\(UUID().uuidString)"
        guard case let .missing(reported) = IdentityAgentCheck.probe(path) else {
            return XCTFail("a socket that does not exist must be reported missing")
        }
        XCTAssertEqual(reported, path)
        XCTAssertTrue(IdentityAgentCheck.probe(path).isTransientFailure)
        XCTAssertEqual(IdentityAgentCheck.probe(nil), .ok, "a first-pass location has nothing to check")
    }

    /// A path that exists but is not a socket refuses, which is the locked-key-agent case.
    func testAPathThatIsNotASocketRefuses() throws {
        let path = NSTemporaryDirectory() + "/sshdrive-test-not-a-socket-\(UUID().uuidString)"
        try Data().write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .refusing = IdentityAgentCheck.probe(path) else {
            return XCTFail("a regular file must not pass the socket check")
        }
    }
}

/// The snapshot against the machine's own login shell. Not testbed-gated: it needs only a
/// Mac, and it is the half of section 6.1 that no server can exercise.
final class LoginShellSnapshotLiveTests: XCTestCase {

    func testSnapshotOfTheRealLoginShell() async throws {
        let snapshot = await SSHProcess.loginShellSnapshot(timeout: 20)
        XCTAssertTrue(snapshot.succeeded, "\(snapshot.shell): \(snapshot.diagnostic ?? "no diagnostic")")
        let path = try XCTUnwrap(snapshot.path)
        XCTAssertTrue(path.contains(":") || path.contains("/"), path)
        XCTAssertEqual(snapshot.interactiveOnly, LoginShellSnapshotReader.isCshFamily(snapshot.shell))
    }

    /// An rc file that leaves a background child holding stdout keeps the pipe open after
    /// `env` has finished. The closing sentinel is what returns the answer anyway; a
    /// reader that waited for EOF would hit the timeout and throw a complete answer away.
    func testABackgroundChildHoldingStdoutDoesNotCostTheSnapshot() async throws {
        let rc = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-rc-\(UUID().uuidString).sh")
        try """
        echo "hello from an rc file"
        ( sleep 120 & )
        """.write(to: rc, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rc) }

        // A shell whose rc is that file: `sh -c` cannot take -ilc, so stand in for the
        // login shell with a two-line script that behaves like one.
        let fake = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-shell-\(UUID().uuidString)")
        try """
        #!/bin/sh
        . '\(rc.path)'
        shift
        exec /bin/sh -c "$1"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake) }

        let started = Date()
        let snapshot = await LoginShellSnapshotReader.take(shell: fake.path, timeout: 15)
        XCTAssertTrue(snapshot.succeeded, snapshot.diagnostic ?? "")
        XCTAssertNotNil(snapshot.path)
        XCTAssertLessThan(Date().timeIntervalSince(started), 14, "the closing sentinel ended the read")
        XCTAssertNotNil(snapshot.diagnostic, "the rc noise is reported for doctor")
    }
}
