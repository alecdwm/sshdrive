import XCTest
@testable import SSHProcess

/// Spike S2's `ProxyJump` half: a two-hop chain built by the agent as its own
/// `ProxyCommand`, with a password on both hops and `ControlMaster auto` set for the
/// bastion in `~/.ssh/config` (DESIGN.md section 6.1). Gated on `SSHDRIVE_TESTBED=1`.
final class TestbedProxyChainTests: XCTestCase {

    private var master: SSHMaster?
    private var askpass: Testbed.StubAskpass?

    override func tearDown() async throws {
        if let master { await master.shutdown() }
        master = nil
        askpass?.remove()
        askpass = nil
        // Killing an ssh that used a -W hop leaves the hop alive holding the pipe open.
        Testbed.reapHopChildren()
    }

    private var bastionConfigSocket: String {
        NSString(string: "~/.ssh/cm-hop@192.168.64.1-2210").expandingTildeInPath
    }

    /// The claim the whole `ControlPath=none` rule rests on: `ControlMaster=no` alone does
    /// **not** detach a hop from the socket the config names for the bastion. `ssh -G` is
    /// the measurement.
    func testControlMasterNoAloneLeavesTheConfigsControlPath() throws {
        try Testbed.skipUnlessEnabled()
        let base = SSHTarget(host: "spike-bastion-a")
        let plain = try SSHConfigResolver.resolve(target: base, environment: Testbed.environment)
        XCTAssertEqual(plain["controlmaster"], "auto")
        XCTAssertNotNil(plain["controlpath"])
        XCTAssertNotEqual(plain["controlpath"], "none")

        let masterNo = try SSHConfigResolver.resolve(
            target: SSHTarget(host: "spike-bastion-a", sshOptions: ["-o", "ControlMaster=no"]),
            environment: Testbed.environment
        )
        XCTAssertEqual(masterNo["controlpath"], plain["controlpath"],
                       "ControlMaster=no leaves the config's ControlPath in place")

        let pathNone = try SSHConfigResolver.resolve(
            target: SSHTarget(host: "spike-bastion-a",
                              sshOptions: ["-o", "ControlMaster=no", "-o", "ControlPath=none"]),
            environment: Testbed.environment
        )
        // `ssh -G` prints no controlpath line at all under ControlPath=none, which is how
        // it says "no socket": the value the hop must have.
        XCTAssertNil(pathNone["controlpath"], "only ControlPath=none clears it")
    }

    /// `ssh -G spike-inner` prints the chain, and nothing in the config may be handed back
    /// to ssh as `-o ProxyJump=`.
    func testTheChainIsResolvedAndRebuiltNotForwarded() throws {
        try Testbed.skipUnlessEnabled()
        let resolution = try SSHConfigResolver.resolve(
            target: SSHTarget(host: "spike-inner"), environment: Testbed.environment
        )
        XCTAssertEqual(resolution.proxyJump, "spike-bastion-a,spike-bastion-b")
        let hops = try resolution.jumpChain()
        XCTAssertEqual(hops.map(\.host), ["spike-bastion-a", "spike-bastion-b"])

        let command = try XCTUnwrap(ProxyChainBuilder.proxyCommand(for: hops, identityAgentNone: true))
        let invocation = SSHCommandBuilder.master(
            target: SSHTarget(host: "spike-inner"),
            controlPath: "/tmp/sshdrive-test", proxyCommand: command
        )
        XCTAssertEqual(invocation.option("ProxyJump"), "none")
        XCTAssertTrue(try XCTUnwrap(invocation.option("ProxyCommand")).contains("ControlPath=none"))
    }

    /// End to end: a master on `inner`, reached through two password hops, with the
    /// prompts answered by a stub askpass under `SSH_ASKPASS_REQUIRE=force`. Then an exec
    /// channel over it, which is what proves the connection is real and not just a socket.
    func testTwoHopChainConnectsAndCarriesAnExecChannel() async throws {
        try Testbed.skipUnlessEnabled()
        let askpass = try Testbed.StubAskpass()
        self.askpass = askpass
        try? FileManager.default.removeItem(atPath: bastionConfigSocket)

        let master = try Testbed.master(host: "spike-inner", environment: askpass.variables)
        self.master = master
        let configuration = await master.configuration
        let proxyCommand = try XCTUnwrap(configuration.proxyCommand)
        XCTAssertTrue(proxyCommand.contains("'ControlPath=none'"), proxyCommand)
        XCTAssertTrue(proxyCommand.contains("'ControlMaster=no'"), proxyCommand)

        try await master.connect()
        let running = await master.isRunning
        XCTAssertTrue(running)

        let (payload, _) = try await Testbed.runScript(
            on: master, body: "printf '%s\\000' \"$(hostname)\"", timeout: 30
        )
        XCTAssertEqual(String(decoding: payload.dropLast(), as: UTF8.self), "inner")

        // Both hops asked, each for its own host, which is what per-host keychain keying
        // exists for (section 4.2).
        let prompts = askpass.prompts.joined(separator: "\n")
        XCTAssertTrue(prompts.contains("bastion-b"), prompts)
        XCTAssertTrue(prompts.contains("192.168.64.1") || prompts.contains("hop@"), prompts)

        // And the hop touched neither the bastion's configured socket nor left one behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: bastionConfigSocket),
                       "ControlPath=none must keep the hop off the config's socket")
    }

    /// With a live ControlMaster already at the bastion's configured `ControlPath`, a hop
    /// that honoured the config would multiplex onto it and never be asked for hop 1's
    /// password. It must still be asked.
    func testHopDoesNotAttachToALiveBastionSocket() async throws {
        try Testbed.skipUnlessEnabled()
        let askpass = try Testbed.StubAskpass()
        self.askpass = askpass
        try? FileManager.default.removeItem(atPath: bastionConfigSocket)

        // A user's terminal session, as the config describes it.
        let usersMaster = try Spawn.run(
            executable: SSHProcess.sshBinaryPath,
            argv: [SSHProcess.sshBinaryPath, "-N", "-M",
                   "-o", "ControlPath=\(bastionConfigSocket)",
                   "-o", "ControlPersist=no", "-o", "ConnectTimeout=15",
                   "spike-bastion-a"],
            environment: Testbed.environment.merging(askpass.variables) { _, new in new },
            wantsStderr: true, stdinFromDevNull: true
        )
        defer { Spawn.terminate(usersMaster, grace: 1); try? FileManager.default.removeItem(atPath: bastionConfigSocket) }
        var appeared = false
        for _ in 0 ..< 100 where !appeared {
            appeared = FileManager.default.fileExists(atPath: bastionConfigSocket)
            if !appeared { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        try XCTSkipUnless(appeared, "could not stand up the user's bastion ControlMaster")
        askpass.resetLog()

        let master = try Testbed.master(host: "spike-inner", environment: askpass.variables)
        self.master = master
        try await master.connect()
        let running = await master.isRunning
        XCTAssertTrue(running)

        let prompts = askpass.prompts.joined(separator: "\n")
        XCTAssertTrue(
            prompts.contains("192.168.64.1") || prompts.contains("hop@"),
            "the hop must make its own connection to the bastion, not attach to the user's: \(prompts)"
        )
        XCTAssertTrue(prompts.contains("bastion-b"), prompts)
    }

    /// The CLI's `user@host:port` sugar, which ssh itself does not parse: the agent splits
    /// it into `-l` and `-p`. Same two hops, expressed the way `--jump` would take them.
    func testChainGivenAsUserAtHostColonPort() async throws {
        try Testbed.skipUnlessEnabled()
        let askpass = try Testbed.StubAskpass()
        self.askpass = askpass

        let hops = try JumpHop.parseChain("hop@192.168.64.1:2210,hop@bastion-b")
        XCTAssertEqual(hops.first, JumpHop(host: "192.168.64.1", user: "hop", port: 2210))
        let proxyCommand = ProxyChainBuilder.proxyCommand(for: hops, identityAgentNone: true)

        var environment = Testbed.environment
        for (key, value) in askpass.variables { environment[key] = value }
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: SSHTarget(host: "inner", user: "alec",
                              identityFile: "~/.ssh/sshdrive-spike"),
            environment: environment,
            proxyCommand: proxyCommand
        ))
        self.master = master
        try await master.connect()
        let (payload, _) = try await Testbed.runScript(
            on: master, body: "printf '%s\\000' \"$(hostname)\"", timeout: 30
        )
        XCTAssertEqual(String(decoding: payload.dropLast(), as: UTF8.self), "inner")
    }
}
