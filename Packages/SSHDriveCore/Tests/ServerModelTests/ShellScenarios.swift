import Foundation
import XCTest

import AgentCore
import SSHProcess
@testable import ServerModel

/// The scenarios that run our remote scripts through **real shells**
/// (`docs/testing-architecture.md` sections 4.2 and 5, suite J).
///
/// This is the deliberate design choice of the whole harness: three of this project's
/// worst bugs lived in shell behaviour and nothing above the shell could have caught any
/// of them. A shell this box does not have is **skipped by name**, never faked.
final class ShellScenarios: XCTestCase {

    private var servers: [FakeSSHD] = []

    override func tearDown() async throws {
        for server in servers { server.shutdown() }
        servers = []
    }

    private func sshd(_ profile: ServerProfile) throws -> FakeSSHD {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let server = try FakeSSHD(profile: profile)
        servers.append(server)
        return server
    }

    // MARK: - J5: the sentinel discards the rc noise, in every shell shape

    /// **J5** (`SQ-015`): rc files print on non-interactive startup in every shell shape -
    /// `.bashrc` through `BASH_ENV` for bash, `.zshenv` for zsh (read for *every*
    /// invocation), `/etc/profile` for a busybox ash. Everything before the sentinel must
    /// be discarded, and it must still be *available* to `status`, which is what tells the
    /// user which rc file to go and fix (section 9.2).
    func testJ5_theSentinelDiscardsTheRCNoiseInEveryShellShape() async throws {
        var ran = 0
        var skipped: [String] = []
        for profile in [ServerProfile.debianShells,                       // bash, BASH_ENV
                        ServerProfile.debianShells.with(loginShell: .zsh),   // zsh, .zshenv
                        ServerProfile.debianShells.with(loginShell: .dash),  // dash
                        ServerProfile.alpine] {                              // busybox ash
            if let reason = FakeSSHD.unavailabilityReason(for: profile) {
                skipped.append("\(profile.loginShell.rawValue): \(reason)")
                continue
            }
            let server = try sshd(profile)
            let script = RemoteScript(body: "printf '%s\\000' ready")
            let channel = try await server.openExecChannel(script: script)
            defer { channel.close() }

            XCTAssertTrue(
                String(decoding: channel.prefix, as: UTF8.self)
                    .contains(profile.loginShell.rcNoise.trimmingCharacters(in: .newlines)),
                "\(profile.loginShell.rawValue): SQ-015 - the noise is kept for `status`")
            let payload = try await channel.readPayload(timeout: 10)
            XCTAssertEqual(
                String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self), "ready",
                "\(profile.loginShell.rawValue): SQ-015 - and nothing but our own output survives")
            ran += 1
        }
        XCTAssertGreaterThanOrEqual(ran, 2, "at least dash and one other shell must have run")
        if !skipped.isEmpty {
            print("J5 skipped rows (not faked): \(skipped.joined(separator: "; "))")
        }
    }

    /// **J5** (`SQ-016`): an rc file can leave a **background child holding stdout**, so
    /// EOF never arrives on the channel and only the closing sentinel ends the read. Any
    /// reader that waits for EOF hangs - which is why every read in this project, harness
    /// reads included, takes a deadline.
    func testJ5_bashbgNeverSendsEOFSoOnlyASentinelOrADeadlineEndsTheRead() async throws {
        let server = try sshd(.debianBackgroundHolder)
        let script = RemoteScript(body: "printf '%s\\000' ready")
        let channel = try await server.openExecChannel(script: script)
        defer { channel.close() }

        let payload = try await channel.readPayload(timeout: 5)
        XCTAssertEqual(
            String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self), "ready")

        // The script has exited. A reader waiting for EOF would now wait for ever,
        // because the rc file's `( sleep 120 & )` still holds the write end.
        let started = Date()
        do {
            _ = try await channel.stream.read(
                upTo: 4096, deadline: Date().addingTimeInterval(1.5))
            XCTFail("SQ-016: EOF must not arrive - the background child holds stdout")
        } catch ByteStreamError.readTimedOut {
            XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0,
                                 "SQ-016: the deadline is what ended the read, not EOF")
        }
    }

    // MARK: - J4: the sentinel's NUL is its own printf

    /// **J4** (`SQ-020`): `printf "\\0<sentinel>"` reads the `\\0` **and the octal digits
    /// after it** as one character, so a sentinel beginning with digits silently loses its
    /// first bytes and the marker is never found. Every sentinel's NUL must be its own
    /// `printf`, which is what `RemoteScript` does.
    ///
    /// Both halves are asserted against a real shell, because this is a claim about
    /// `printf`'s escape handling and nothing but `printf` can settle it.
    func testJ4_theNaiveSentinelPrintfEatsItsOwnFirstBytes() async throws {
        let server = try sshd(.debian)
        // Deliberately begins with octal digits, which is what makes the bug bite.
        let sentinel = Sentinel(hex: "17263540a1b2c3d4e5f60718293a4b5c")

        // The bug, run for real.
        let naive = try await server.runRaw("printf '\\0\(sentinel.hex)'\n")
        XCTAssertFalse(
            naive.contains(Data(sentinel.hex.utf8)),
            "SQ-020: `printf \\\"\\\\0<sentinel>\\\"` loses the digits after the NUL")
        // `\017` is a three-digit octal escape: printf ate the `17` and wrote 0x0F.
        XCTAssertEqual(naive.first, 0x0F,
                       "SQ-020: the NUL and the two digits after it became one character")
        let naiveText = String(decoding: naive.dropFirst(), as: UTF8.self)
        XCTAssertEqual(naiveText, String(sentinel.hex.dropFirst(2)),
                       "SQ-020: the first two hex digits of the sentinel are simply gone")

        // The fix, which is the form `RemoteScript.text` emits.
        let script = RemoteScript(sentinel: sentinel, body: "printf '%s\\000' ok")
        XCTAssertTrue(
            script.text.contains("printf '%s' '\(sentinel.hex)'; printf '\\000'"),
            "SQ-020: the NUL is its own printf")
        let channel = try await server.openExecChannel(script: script)
        defer { channel.close() }
        let payload = try await channel.readPayload(timeout: 10)
        XCTAssertEqual(
            String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self), "ok",
            "the full sentinel was found, so the payload starts where it should")
    }

    // MARK: - J7 / J6: the wrapper the shells actually parse

    /// **J7** (`SQ-018`): dash answers `;;` with `Syntax error: ";;" unexpected` and the
    /// channel dies on the spot. The relay fragment already ends in `;`, so
    /// `… || break; <relay>; done` produces exactly that. The wrapper the helper runs
    /// under must parse clean on dash and on busybox ash both.
    func testJ7_theRelayWrapperParsesCleanOnEveryPOSIXShell() async throws {
        var ran = 0
        for profile in [ServerProfile.debian, ServerProfile.alpine] {
            if let reason = FakeSSHD.unavailabilityReason(for: profile) {
                print("J7 skipped row (not faked): \(profile.name): \(reason)")
                continue
            }
            let server = try sshd(profile)
            let script = RemoteScript(
                arguments: ["/tmp"],
                body: "printf '%s\\000' ready; sleep 30",
                heartbeat: .init(intervalSeconds: 2, timeoutSeconds: 6),
                stdinRelay: "\(server.directory.path)/relay.fifo")
            // The control: the same relay fragment written the wrong way really is a
            // syntax error, on this shell, today.
            let broken = try await server.runRaw(
                "while :; do read -r l || break; printf '%s' \"$l\";; done < /dev/null\n")
            XCTAssertTrue(
                String(decoding: broken, as: UTF8.self).isEmpty,
                "\(profile.name): SQ-018 - `;;` kills the shell before it prints anything")

            let channel = try await server.openExecChannel(script: script, readinessDeadline: 10)
            defer { channel.close() }
            let payload = try await channel.readPayload(timeout: 10)
            XCTAssertEqual(
                String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self), "ready",
                "\(profile.name): SQ-018 - the wrapper parsed and the channel lives")
            ran += 1
        }
        XCTAssertGreaterThanOrEqual(ran, 1, "dash must have run: it is /bin/sh here")
    }

    /// **J6** (`SQ-017`, `SQ-019`): the wrapper must not kill its own **healthy** child.
    /// Two ways it used to: the one-second `read -t` probe ran with the EXIT trap still
    /// set and deleted the stamp file, and the heartbeat reader was handed a `/dev/null`
    /// stdin by the fork and saw EOF at once. Both looked exactly like the failure the
    /// wrapper exists to prevent. Debian's `sh` is dash, so this is the ordinary Linux
    /// path and not a fallback.
    func testJ6_theWrapperDoesNotKillItsOwnHealthyChild() async throws {
        let server = try sshd(.debian)
        let marker = "sshdrive-j6-\(UUID().uuidString.prefix(8))"
        let script = RemoteScript(
            body: "printf '%s\\000' started; sleep 45 \(marker) 2>/dev/null || sleep 45",
            heartbeat: .init(intervalSeconds: 2, timeoutSeconds: 6))
        let channel = try await server.openExecChannel(script: script, readinessDeadline: 10)
        defer { channel.close() }
        let payload = try await channel.readPayload(timeout: 10)
        XCTAssertEqual(
            String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self), "started")

        // Heartbeats keep arriving, so the child must still be there well past the
        // timeout the watchdog would otherwise have fired at.
        for _ in 0 ..< 5 {
            try await channel.sendHeartbeat()
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        XCTAssertNil(channel.exitStatus(),
                     "SQ-019: a healthy child under a heartbeat is never killed")
    }

    // MARK: - N4: a shell-less account

    /// **N4** (`SQ-013`): a `ForceCommand internal-sftp` account answers an exec channel
    /// with the plain sentence `This service allows sftp connections only.` or with SFTP
    /// framing. Both mean **"no shell access (ForceCommand)"**, never "shell output
    /// unusable" - the difference the user sees in `status`.
    func testN4_aForceCommandAccountIsNoShellAccessInBothItsShapes() async throws {
        for forceCommand in [ForceCommand.internalSFTP, .internalSFTPFraming] {
            let profile = ServerProfile.debianForceCommand.with(forceCommand: forceCommand)
            let server = try sshd(profile)
            do {
                _ = try await server.openExecChannel(script: RemoteScript(body: "true"))
                XCTFail("SQ-013: a ForceCommand account has no shell to answer with")
            } catch let refusal as ForceCommandRefusal {
                XCTAssertTrue(
                    refusal.looksLikeForceCommandRefusal,
                    "SQ-013: \(forceCommand.rawValue) must read as no shell access")
            }
        }
    }

    // MARK: - J14: the login-shell env snapshot, per shell

    /// **J14** (`SQ-015`, `SQ-016`, `SQ-017`): the login-shell snapshot of section 6.1
    /// runs the *account's own* shell - `<shell> -ilc` - and takes exactly two variables
    /// out of it. Every byte the rc files print arrives **in front of** the opening
    /// sentinel and must be discarded, in every shell shape the box can run: bash quiet,
    /// bash noisy, dash (which is Debian's `/bin/sh`, `SQ-017`) and zsh, whose `.zshenv`
    /// is read for every invocation there is.
    ///
    /// This is a different mechanism from `J5`'s and deliberately so: an exec channel is
    /// non-interactive, where bash reads `BASH_ENV`; a login shell reads `.bash_profile`,
    /// `.zshenv` or `.profile` and never `BASH_ENV`. The claim `SQ-015` makes is about
    /// both, so both are run.
    ///
    /// A shell this box does not have skips **by name**: `busybox ash`, `fish` and `tcsh`
    /// are asserted to skip rather than being quietly left out of the loop.
    func testJ14_theLoginShellSnapshotDiscardsTheRCNoiseAndReturnsTheTwoVariables() async throws {
        var ran: [String] = []
        var skipped: [String] = []
        for shape in [LoginShell.bashQuiet, .bashNoisy, .dash, .zsh, .busyboxAsh, .fish, .tcsh] {
            let profile = ServerProfile.debianShells.with(loginShell: shape)
            if let reason = FakeSSHD.unavailabilityReason(for: profile) {
                skipped.append("\(shape.rawValue): \(reason)")
                continue
            }
            // `SQ-083`: on macOS the zsh row cannot be isolated at all. `/etc/zprofile`
            // runs `path_helper`, which **rewrites** `PATH` from `/etc/paths` and
            // `/etc/paths.d`, and zsh reads `$ZDOTDIR/.zshenv` *before* the system's
            // `/etc/zprofile` - so the account's PATH comes back as the system's list with
            // the account's appended, and `ZDOTDIR` cannot stop it. (`-f`/`NO_RCS` would
            // suppress the account's own file along with the system's, which is the
            // opposite of what this row is about.) bash is unaffected, because
            // `/etc/profile` runs `path_helper` *before* `.bash_profile`. The claim
            // `SQ-015` makes about zsh keeps its whole coverage on Linux, where no
            // `path_helper` runs; bash and dash run on both.
            if shape == .zsh, ScriptShell.zsh.systemRCRewritesPATH {
                skipped.append("\(shape.rawValue): \(ScriptShell.zsh.systemRCSkipReason)")
                continue
            }
            let server = try sshd(profile)
            let account = try server.loginShellAccount(
                path: "/opt/\(shape.rawValue)/bin:/usr/bin:/bin",
                sshAuthSock: "/tmp/sshdrive-\(shape.rawValue)-agent.sock")

            let snapshot = await LoginShellSnapshotReader.take(
                shell: account.shellPath, timeout: 20, baseEnvironment: account.environment)

            XCTAssertTrue(
                snapshot.succeeded,
                "\(shape.rawValue): the snapshot failed: \(snapshot.diagnostic ?? "no diagnostic")")
            XCTAssertEqual(snapshot.path, account.expectedPATH,
                           "\(shape.rawValue): SQ-015 - the PATH is the rc file's, not launchd's")
            XCTAssertEqual(snapshot.sshAuthSock, account.expectedAuthSock,
                           "\(shape.rawValue): SQ-015 - and so is SSH_AUTH_SOCK")
            XCTAssertFalse(
                (snapshot.path ?? "").contains("hello from"),
                "\(shape.rawValue): SQ-015 - not one byte of the noise is in the answer")
            XCTAssertFalse(account.rcFile.isEmpty)

            if account.noise.isEmpty {
                XCTAssertNil(
                    snapshot.diagnostic,
                    "\(shape.rawValue): a quiet account prints nothing before the sentinel "
                        + "(a diagnostic here is this box's own /etc rc files talking)")
            } else {
                let diagnostic = snapshot.diagnostic ?? ""
                XCTAssertTrue(
                    diagnostic.contains("bytes before the sentinel"),
                    "\(shape.rawValue): SQ-015 - the noise is discarded but still reported, "
                        + "which is what tells the user which rc file to fix: \(diagnostic)")
                let reported = diagnostic.split(separator: " ").compactMap { Int($0) }.first ?? 0
                XCTAssertGreaterThanOrEqual(
                    reported, account.noise.utf8.count,
                    "\(shape.rawValue): every byte the rc file wrote is accounted for")
            }
            // Only the two variables travel; nothing else of the shell's is taken.
            let applied = snapshot.applied(to: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty"])
            XCTAssertEqual(applied["PATH"], account.expectedPATH)
            XCTAssertEqual(applied["HOME"], "/var/empty", "section 6.1: only the two")
            ran.append(shape.rawValue)
        }

        XCTAssertTrue(ran.contains("dash"), "dash is /bin/sh here and must have run")
        XCTAssertGreaterThanOrEqual(ran.count, 2, "at least dash and one other shell ran: \(ran)")
        // The shells this box does not have are skipped by name, never faked.
        for absent in [LoginShell.fish, .tcsh] {
            let profile = ServerProfile.debianShells.with(loginShell: absent)
            XCTAssertNotNil(
                FakeSSHD.unavailabilityReason(for: profile),
                "\(absent.rawValue) has no POSIX rc body and is not installed: it skips by name")
        }
        if !skipped.isEmpty {
            print("J14 skipped rows (not faked): \(skipped.joined(separator: "; "))")
        }
    }

    /// **J14** (`SQ-016`): `deb-shells`' `bashbg` account leaves a background child holding
    /// stdout, so **EOF never arrives** on the snapshot's pipe. The closing sentinel is
    /// what ends the read, and every read has a deadline - which is why a complete answer
    /// comes back in a fraction of the timeout rather than at the end of it.
    ///
    /// The bite-proof is the second half: a reader that waits for EOF, run against the
    /// very same shell and the very same command, is still waiting when its deadline
    /// fires - **with the whole answer already in its buffer**, which is the answer it
    /// would have thrown away.
    func testJ14_theBashbgSnapshotIsEndedByItsSentinelAndAnEOFReaderHangsOnTheSameShell() async throws {
        let profile = ServerProfile.debianBackgroundHolder
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let server = try sshd(profile)
        let account = try server.loginShellAccount(
            path: "/opt/bashbg/bin:/usr/bin:/bin", sshAuthSock: "/tmp/sshdrive-bashbg.sock")
        XCTAssertTrue(account.holdsStdoutOpen, "SQ-016: this is the account that holds stdout")

        let timeout: TimeInterval = 20
        let started = Date()
        let snapshot = await LoginShellSnapshotReader.take(
            shell: account.shellPath, timeout: timeout, baseEnvironment: account.environment)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(snapshot.succeeded,
                      "SQ-016: \(snapshot.diagnostic ?? "the snapshot failed with no diagnostic")")
        XCTAssertEqual(snapshot.path, account.expectedPATH)
        XCTAssertEqual(snapshot.sshAuthSock, account.expectedAuthSock)
        XCTAssertLessThan(
            elapsed, timeout / 2,
            "SQ-016: the closing sentinel ended the read; taking the whole \(Int(timeout)) s "
                + "would mean it had waited for an EOF that never comes")

        // The bite-proof: the reader as it would be if EOF were trusted. Same shell, same
        // argv, same rc file - and it is still waiting when the deadline fires.
        let sentinel = Sentinel()
        var environment = account.environment
        environment["TERM"] = "dumb"
        let spawned = try Spawn.run(
            executable: account.shellPath,
            argv: [account.shellPath, "-ilc",
                   LoginShellSnapshotReader.snapshotCommand(sentinel: sentinel)],
            environment: environment,
            wantsStdout: true, stdinFromDevNull: true, newProcessGroup: true)
        defer {
            kill(-spawned.pid, SIGKILL)
            _ = Spawn.wait(pid: spawned.pid)
        }
        let stream = PipeByteStream(readFD: spawned.stdoutFD, writeFD: -1, label: "j14-eof-reader")
        defer { stream.close() }
        var parser = SentinelParser(sentinel: sentinel)
        var collected = Data()
        let legacyDeadline = Date().addingTimeInterval(4)
        var sawEOF = false
        do {
            while Date() < legacyDeadline {
                let chunk = try await stream.read(upTo: 64 * 1024, deadline: legacyDeadline)
                if chunk.isEmpty { sawEOF = true; break }
                collected.append(chunk)
                parser.append(chunk)
            }
        } catch ByteStreamError.readTimedOut {
            // What the old reader does with a complete answer: nothing.
        }
        XCTAssertFalse(
            sawEOF,
            "SQ-016: EOF must never arrive - the rc file's background child holds stdout")
        XCTAssertTrue(
            parser.sawClosingSentinel,
            "SQ-016: and the answer was complete the whole time the EOF reader was waiting")
        XCTAssertNotNil(parser.environment["PATH"],
                        "SQ-016: including the PATH an EOF-waiting reader would have thrown away")
    }
}
