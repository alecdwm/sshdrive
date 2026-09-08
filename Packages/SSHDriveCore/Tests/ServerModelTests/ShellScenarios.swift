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
}
