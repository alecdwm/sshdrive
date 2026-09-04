import XCTest
@testable import SSHProcess

/// DESIGN.md section 6.1's command lines, option by option. The override set is twenty
/// keywords long and every one of them is there for a named failure, so it is asserted
/// rather than eyeballed.
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
        // drop the ProxyCommand entirely (section 13, 2026-09-04).
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
        // an exec channel's command line (section 9.2).
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

    /// "`ProxyJump` is never handed to `ssh`" (section 6.1) has to hold for one written
    /// into the location's own `sshOptions` too. It still reaches `ssh -G`, which is how
    /// the chain builder learns about it; it never reaches the master's command line.
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
    /// package's own tests write `sshdrive-nested-<uuid>.sqlite` there. Its `-wal` and
    /// `-shm` sidecars were counted as orphaned control sockets and `sshdrive doctor`
    /// reported a healthy install as failing (2026-09-04, section 6.1).
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
}
