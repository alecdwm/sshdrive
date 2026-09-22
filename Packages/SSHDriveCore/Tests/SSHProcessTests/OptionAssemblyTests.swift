import XCTest
@testable import SSHProcess

/// The ssh command lines (docs/design/ssh.md), option by option. The override set is
/// twenty keywords long and every one of them is there for a named failure, so it is
/// asserted rather than eyeballed.
final class OptionAssemblyTests: XCTestCase {

    private let socket = "/var/folders/xx/T/sshdrive-1a2b3c4d"

    func testMasterCarriesTheWholeFixedOverrideSet() {
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "nas"), controlPath: socket
        )
        XCTAssertTrue(invocation.hasFlag("-N"), "the master carries no session")
        let expected: [String: String] = [
            "ControlMaster": "yes",
            "ControlPath": socket,
            "ControlPersist": "no",
            "StrictHostKeyChecking": "yes",
            "UpdateHostKeys": "no",
            "ConnectTimeout": "15",
            "ServerAliveInterval": "15",
            "ServerAliveCountMax": "2",
            "NumberOfPasswordPrompts": "1",
            "LogLevel": "ERROR",
            "RemoteCommand": "none",
            "RequestTTY": "no",
            "StdinNull": "no",
            "ForkAfterAuthentication": "no",
            "BatchMode": "no",
            "PermitLocalCommand": "no",
            "ForwardAgent": "no",
            "ForwardX11": "no",
            "ClearAllForwardings": "yes",
            "IdentityAgent": "none",
        ]
        for (keyword, value) in expected {
            XCTAssertEqual(invocation.option(keyword), value, "-o \(keyword)")
        }
        XCTAssertEqual(invocation.arguments.last, "nas")
        XCTAssertEqual(invocation.argv0, "/usr/bin/ssh")
        XCTAssertEqual(invocation.executable, "/usr/bin/ssh")
    }

    func testAgentDependentLocationKeepsTheConfigsIdentityAgent() {
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "nas", identityAgentNone: false), controlPath: socket
        )
        XCTAssertNil(invocation.option("IdentityAgent"))
    }

    /// ssh takes the FIRST value it sees for a keyword, command line included, so the
    /// fixed set has to come before the user's verbatim options or a `-o BatchMode=yes`
    /// on the location would beat it.
    func testFixedOverridesComeBeforeTheUsersOwnOptions() {
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "nas", user: "alec", port: 2222,
                              identityFile: "~/.ssh/id_nas",
                              sshOptions: ["-o", "BatchMode=yes"]),
            controlPath: socket
        )
        let fixed = invocation.arguments.firstIndex(of: "BatchMode=no")
        let theirs = invocation.arguments.firstIndex(of: "BatchMode=yes")
        XCTAssertNotNil(fixed)
        XCTAssertNotNil(theirs)
        XCTAssertLessThan(fixed!, theirs!)
        XCTAssertEqual(invocation.option("BatchMode"), "no")
        XCTAssertEqual(invocation.option("User"), "alec")
        XCTAssertEqual(invocation.option("Port"), "2222")
        XCTAssertEqual(invocation.option("IdentityFile"), "~/.ssh/id_nas")
    }

    func testProxyJumpIsCancelledWheneverWeSupplyOurOwnChain() {
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "inner"), controlPath: socket,
            proxyCommand: "/usr/bin/ssh -W %h:%p bastion"
        )
        XCTAssertEqual(invocation.option("ProxyJump"), "none")
        XCTAssertEqual(invocation.option("ProxyCommand"), "/usr/bin/ssh -W %h:%p bastion")
        // Order matters: -o ProxyJump=none ahead of -o ProxyCommand= makes OpenSSH 10.2
        // drop the ProxyCommand entirely.
        let proxyCommandIndex = invocation.arguments.firstIndex { $0.hasPrefix("ProxyCommand=") }
        let proxyJumpIndex = invocation.arguments.firstIndex(of: "ProxyJump=none")
        XCTAssertNotNil(proxyCommandIndex)
        XCTAssertNotNil(proxyJumpIndex)
        XCTAssertLessThan(proxyCommandIndex!, proxyJumpIndex!)
    }

    func testNoProxyOptionsWhenThereIsNoChain() {
        let invocation = SSHCommandBuilder.master(target: SSHTarget(host: "nas"), controlPath: socket)
        XCTAssertNil(invocation.option("ProxyJump"))
        XCTAssertNil(invocation.option("ProxyCommand"))
    }

    /// A mux client reads no config and cannot connect on its own: without these three a
    /// missing socket makes ssh open a second, unsupervised connection instead of failing.
    func testMuxClientsReadNoConfigAndCannotConnect() {
        for invocation in [
            SSHCommandBuilder.sftpChannel(controlPath: socket, host: "nas"),
            SSHCommandBuilder.execChannel(controlPath: socket, host: "nas"),
            SSHCommandBuilder.control("check", controlPath: socket, host: "nas"),
        ] {
            XCTAssertEqual(Array(invocation.arguments.prefix(4)), ["-F", "/dev/null", "-S", socket])
            XCTAssertEqual(invocation.option("BatchMode"), "yes")
            XCTAssertEqual(invocation.option("ProxyCommand"), "/usr/bin/false")
            XCTAssertNil(invocation.option("ControlPath"), "the socket goes on -S, not -o")
        }
    }

    func testChannelCommandLines() {
        XCTAssertEqual(
            SSHCommandBuilder.sftpChannel(controlPath: socket, host: "nas").arguments.suffix(3),
            ["-s", "nas", "sftp"]
        )
        // Exactly `sh -s`: nothing from the user, the config or the server ever appears on
        // an exec channel's command line (docs/design/security.md).
        XCTAssertEqual(
            SSHCommandBuilder.execChannel(controlPath: socket, host: "nas").arguments.suffix(3),
            ["nas", "sh", "-s"]
        )
        XCTAssertEqual(
            SSHCommandBuilder.control("exit", controlPath: socket, host: "nas").arguments.suffix(3),
            ["-O", "exit", "nas"]
        )
    }

    func testResolveUsesDashFOnlyForTheAttributionHalf() {
        let target = SSHTarget(host: "nas", user: "alec")
        let withConfig = SSHCommandBuilder.resolve(target: target, ignoringConfigFiles: false)
        let without = SSHCommandBuilder.resolve(target: target, ignoringConfigFiles: true)
        XCTAssertEqual(withConfig.arguments.first, "-G")
        XCTAssertEqual(Array(without.arguments.prefix(3)), ["-F", "/dev/null", "-G"])
        XCTAssertEqual(withConfig.option("User"), "alec")
    }

    /// $TMPDIR/sshdrive-<id8>, never %C: %C hashes user, host and port, so two locations
    /// on one host would compute the same socket path.
    func testControlPathIsNamedByLocationId() {
        let path = ControlSocket.path(forLocationID: "1A2B3C4D-5E6F-7081-9203-A4B5C6D7E8F9")
        XCTAssertTrue(path.hasSuffix("/sshdrive-1a2b3c4d"), path)
        XCTAssertFalse(path.contains("%C"))
        XCTAssertLessThan(path.utf8.count, 104, "unix socket paths are limited to 104 bytes")
    }

    func testTwoLocationsOnOneHostGetDifferentSockets() {
        XCTAssertNotEqual(
            ControlSocket.path(forLocationID: UUID().uuidString),
            ControlSocket.path(forLocationID: UUID().uuidString)
        )
    }

    /// "`ProxyJump` is never handed to `ssh`" (docs/design/ssh.md) has to hold for one
    /// written into the location's own `sshOptions` too. It still reaches `ssh -G`,
    /// which is how the chain builder learns about it; it never reaches the master's
    /// command line.
    func testAProxyJumpInSshOptionsReachesResolutionButNotTheMaster() {
        let target = SSHTarget(
            host: "inner",
            sshOptions: ["-o", "ProxyJump=hop@bastion:2210", "-o", "Compression=yes"])
        let master = SSHCommandBuilder.master(
            target: target, controlPath: socket,
            proxyCommand: "/usr/bin/ssh -W %h:%p hop@bastion")
        XCTAssertEqual(
            master.option("ProxyJump"), "none",
            "ours is first, and the stored one is not on the line at all")
        XCTAssertFalse(
            master.arguments.contains("ProxyJump=hop@bastion:2210"),
            "\(master.arguments)")
        XCTAssertEqual(master.option("Compression"), "yes", "every other option is verbatim")

        let resolve = SSHCommandBuilder.resolve(target: target, ignoringConfigFiles: false)
        XCTAssertTrue(
            resolve.arguments.contains("ProxyJump=hop@bastion:2210"),
            "ssh -G is where the chain comes from")
    }

    func testWithoutProxyJumpLeavesEverythingElseAlone() {
        XCTAssertEqual(
            SSHCommandBuilder.withoutProxyJump(
                ["-o", "ProxyJump=a", "-J", "b", "-o", "User=x", "-4"]),
            ["-o", "User=x", "-4"])
    }

    /// `$TMPDIR` is shared, and the `sshdrive-` prefix is not ours exclusively: the
    /// package's own tests write `sshdrive-nested-<uuid>.sqlite` there, and its `-wal`
    /// and `-shm` sidecars would otherwise be counted as orphaned control sockets,
    /// making `sshdrive doctor` report a healthy install as failing.
    func testOrphanSweepIgnoresANonSocketWithOurPrefix() throws {
        let directory = ControlSocket.temporaryDirectory()
        let name = "sshdrive-nested-\(UUID().uuidString).sqlite-wal"
        let path = (directory as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertFalse(ControlSocket.isSocket(path))
        XCTAssertFalse(
            ControlSocket.existingSockets().contains(path),
            "a plain file with our prefix must not be swept")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "and must certainly not be deleted")
    }

    /// The sweep unlinking a socket is not enough: the `ssh -N` that owned it lives on,
    /// holding a connection to the server for ever, unreachable by `-O exit` once the
    /// socket is gone. `ssh -O check` naming the pid is the only route from a socket
    /// to its process.
    func testMasterPIDIsParsedFromTheCheckReply() {
        XCTAssertEqual(ControlSocket.parseMasterPID("Master running (pid=48213)\r\n"), 48213)
        XCTAssertEqual(ControlSocket.parseMasterPID("Master running (pid=2)"), 2)
    }

    func testNoMasterMeansNoPID() {
        XCTAssertNil(ControlSocket.parseMasterPID(""))
        XCTAssertNil(
            ControlSocket.parseMasterPID(
                "Control socket connect(/tmp/sshdrive-1a2b): No such file or directory"))
        // pid 1 is launchd and pid 0 is the kernel; neither is ever an orphaned master,
        // and signalling either would be a bug with consequences.
        XCTAssertNil(ControlSocket.parseMasterPID("Master running (pid=1)"))
        XCTAssertNil(ControlSocket.parseMasterPID("Master running (pid=0)"))
        XCTAssertNil(ControlSocket.parseMasterPID("Master running (pid=)"))
    }

    /// A pid read from a socket left in `$TMPDIR` by an earlier boot can have been reused
    /// by anything, so the sweep checks the process's name before signalling it.
    func testTerminateRefusesAProcessThatIsNotAnSSH() {
        var signalled = false
        let delivered = ControlSocket.terminate(pid: 999_999, isLiveSSH: { _ in
            signalled = true
            return false
        })
        XCTAssertFalse(delivered)
        XCTAssertTrue(signalled, "the name check must actually run")
        // And this process is certainly alive and certainly not named ssh.
        XCTAssertFalse(ControlSocket.isLiveSSH(getpid()))
    }

    // MARK: The one connection that reads the server's identification string

    /// `status` names the server software (docs/design/cli.md); runtime masters run
    /// at `LogLevel=ERROR` and never see a banner (docs/design/ssh.md). The collect
    /// connection asks for `DEBUG1`, and only it.
    func testOnlyTheCapturingMasterRaisesTheLogLevel() {
        let target = SSHTarget(host: "nas")
        let quiet = SSHCommandBuilder.master(target: target, controlPath: "/tmp/s")
        XCTAssertTrue(quiet.argv.contains("LogLevel=ERROR"))
        XCTAssertFalse(quiet.argv.contains("LogLevel=DEBUG1"))
        let loud = SSHCommandBuilder.master(
            target: target, controlPath: "/tmp/s", hostKeyChecking: "ask", logLevel: "DEBUG1")
        XCTAssertTrue(loud.argv.contains("LogLevel=DEBUG1"))
        XCTAssertFalse(loud.argv.contains("LogLevel=ERROR"))
    }

    func testTheRemoteSoftwareVersionIsReadAndTheDebugLinesGoAgain() {
        let raw = """
            debug1: Reading configuration data /etc/ssh/ssh_config
            debug1: Connecting to nas port 22.
            debug1: Remote protocol version 2.0, remote software version Tailscale
            debug1: compat_banner: no match: Tailscale
            Permission denied (publickey).
            """
        XCTAssertEqual(SSHMaster.remoteSoftwareVersion(inDebugOutput: raw), "Tailscale")
        // Whatever the classifier and `add` see must be exactly the ERROR-level text.
        XCTAssertEqual(SSHMaster.withoutDebugLines(raw), "Permission denied (publickey).")
        XCTAssertNil(SSHMaster.remoteSoftwareVersion(inDebugOutput: "Permission denied."))
    }

    /// `ssh` ends every stderr log line with CRLF, and Swift counts `"\r\n"` as **one**
    /// `Character` (measured 2026-09-08), so `split(separator: "\n")` finds nothing to
    /// split: without normalising first, the captured version becomes `Tailscale`
    /// plus the hundred `debug1:` lines after it, which `sshdrive status` would print
    /// in full.
    func testCRLFLogLinesAreSplitRatherThanSwallowedWhole() {
        let raw = "debug1: Remote protocol version 2.0, remote software version Tailscale\r\n"
            + "debug1: compat_banner: no match: Tailscale\r\n"
            + "debug1: Authenticating to nas:22 as 'alec'\r\n"
            + "Permission denied (publickey).\r\n"
        XCTAssertEqual(SSHMaster.remoteSoftwareVersion(inDebugOutput: raw), "Tailscale")
        XCTAssertEqual(
            SSHMaster.withoutDebugLines(raw).trimmingCharacters(in: .whitespacesAndNewlines),
            "Permission denied (publickey).")
    }
}
