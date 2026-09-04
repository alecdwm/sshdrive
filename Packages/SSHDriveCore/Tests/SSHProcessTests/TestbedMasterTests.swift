import XCTest
@testable import SSHProcess

/// Spike S2 against the testbed: the `-N` master, its mux clients, and what happens when
/// one of them loses its socket (DESIGN.md section 6.1). Gated on `SSHDRIVE_TESTBED=1`.
final class TestbedMasterTests: XCTestCase {

    private var master: SSHMaster?

    override func tearDown() async throws {
        if let master { await master.shutdown() }
        master = nil
        Testbed.reapHopChildren()
    }

    /// The master is our own foreground child with `ControlPersist=no`, and two mux
    /// clients run on its socket at once. Killing one leaves the other and the master
    /// untouched: that is the whole reason every channel is its own process.
    func testMasterWithTwoMuxClientsAndKillingOne() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try Testbed.master(host: "spike-deb")
        self.master = master
        try await master.connect()

        let socket = await master.controlPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "the socket is the auth signal")
        var running = await master.isRunning
        XCTAssertTrue(running, "ControlPersist=no keeps the master in the foreground as our child")
        var check = await master.check()
        XCTAssertTrue(check, "-O check asks our own child whether it is alive")

        // Two exec channels, each echoing what we write to it.
        let echo = "while read __l; do printf '%s\\000' \"$__l\"; done"
        let first = try await master.openExecChannel(script: RemoteScript(body: echo))
        let second = try await master.openExecChannel(script: RemoteScript(body: echo))
        defer { first.close(); second.close() }

        try await first.stream.write(Data("one\n".utf8))
        let firstEcho = try await Testbed.read(first)
        XCTAssertEqual(String(decoding: firstEcho.dropLast(), as: UTF8.self), "one")
        try await second.stream.write(Data("two\n".utf8))
        let secondEcho = try await Testbed.read(second)
        XCTAssertEqual(String(decoding: secondEcho.dropLast(), as: UTF8.self), "two")

        // Kill one channel outright; the other must not notice.
        kill(first.pid, SIGKILL)
        first.close()
        try await Task.sleep(nanoseconds: 500_000_000)

        try await second.stream.write(Data("still here\n".utf8))
        let survivorEcho = try await Testbed.read(second)
        XCTAssertEqual(
            String(decoding: survivorEcho.dropLast(), as: UTF8.self),
            "still here",
            "a wedged or killed channel never touches the connection"
        )
        running = await master.isRunning
        XCTAssertTrue(running)
        check = await master.check()
        XCTAssertTrue(check)

        // A third channel still opens on the same master.
        let third = try await master.openExecChannel(script: RemoteScript(body: "printf 'ok\\000'"))
        defer { third.close() }
        let thirdEcho = try await Testbed.read(third)
        XCTAssertEqual(String(decoding: thirdEcho.dropLast(), as: UTF8.self), "ok")
    }

    /// A mux client whose socket is gone must exit at once rather than make a second,
    /// unsupervised connection of its own - which is what `-F /dev/null`, `BatchMode=yes`
    /// and `ProxyCommand=/usr/bin/false` are for - and the agent must read that exit as
    /// master lost, never as an authentication failure.
    func testMuxClientWithoutASocketExitsAtOnceAndIsMasterLost() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try Testbed.master(host: "spike-deb")
        self.master = master
        try await master.connect()
        let socket = await master.controlPath
        try FileManager.default.removeItem(atPath: socket)

        let started = Date()
        do {
            let channel = try await master.openExecChannel(
                script: RemoteScript(body: "printf 'never\\000'"), readinessDeadline: 20
            )
            channel.close()
            XCTFail("a mux client with no socket must not connect on its own")
        } catch let error as SSHProcessError {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertEqual(error.classification, .masterLost, "\(error)")
            XCTAssertLessThan(elapsed, 10, "it must fail fast, not open a second connection")
            XCTAssertFalse(try XCTUnwrap(error.classification).stopsReconnection)
        }
    }

    /// A host block written for interactive use breaks both the master and a hop:
    /// `spike-deb-shapes` carries RemoteCommand, RequestTTY force and
    /// ForkAfterAuthentication yes. The overrides must keep the master in the foreground
    /// and the mux clients working.
    func testSessionShapeOverrides() async throws {
        try Testbed.skipUnlessEnabled()
        // First: the config really does carry the shapes, so the test is not vacuous.
        let resolution = try SSHConfigResolver.resolve(
            target: SSHTarget(host: "spike-deb-shapes"), environment: Testbed.environment
        )
        XCTAssertEqual(resolution["requesttty"], "force")
        XCTAssertEqual(resolution["forkafterauthentication"], "yes")
        XCTAssertEqual(resolution["controlmaster"], "auto")
        XCTAssertNotNil(resolution["remotecommand"])
        XCTAssertNotEqual(resolution["remotecommand"], "none")

        let master = try Testbed.master(host: "spike-deb-shapes")
        self.master = master
        try await master.connect()
        let running = await master.isRunning
        XCTAssertTrue(running, "ForkAfterAuthentication=no keeps the master as our child")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: NSString(string: "~/.ssh/cm-alec@192.168.64.1-2201").expandingTildeInPath),
            "ControlPath=<ours> must beat the config's ControlPath"
        )
        let (payload, _) = try await Testbed.runScript(on: master, body: "printf 'shapes-ok\\000'")
        XCTAssertEqual(String(decoding: payload.dropLast(), as: UTF8.self), "shapes-ok")
    }

    /// MaxSessions 2: the third channel must come back classified rather than hang.
    func testMaxSessionsProducesAClassifiedError() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try Testbed.master(host: "spike-maxsess")
        self.master = master
        try await master.connect()

        let hold = "while read __l; do :; done"
        let first = try await master.openExecChannel(script: RemoteScript(body: hold))
        let second = try await master.openExecChannel(script: RemoteScript(body: hold))
        defer { first.close(); second.close() }

        let started = Date()
        do {
            let third = try await master.openExecChannel(
                script: RemoteScript(body: "printf 'x\\000'"), readinessDeadline: 25
            )
            third.close()
            XCTFail("MaxSessions 2 must refuse the third channel")
        } catch let error as SSHProcessError {
            XCTAssertEqual(error.classification, .channelLimitReached, "\(error)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 20, "a refusal, not a hang")
            XCTAssertFalse(try XCTUnwrap(error.classification).stopsReconnection,
                           "the agent drops a channel; it does not stop the location")
        }
        // The master is untouched by the refusal.
        let running = await master.isRunning
        XCTAssertTrue(running)
    }

    /// The other kind of mux client: `ssh $MUX -s <host> sftp`. One of these is the
    /// metadata channel and a second the bulk channel, and both run beside an exec channel
    /// on the same connection. The SFTP wire protocol is section 6.2's; all this proves is
    /// that the channel is a real byte stream in both directions.
    func testTwoSFTPChannelsAndAnExecChannelShareOneConnection() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try Testbed.master(host: "spike-deb")
        self.master = master
        try await master.connect()

        // SSH_FXP_INIT, version 3.
        let initPacket = Data([0x00, 0x00, 0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x03])
        var channels: [SFTPChannel] = []
        for _ in 0 ..< 2 {
            let channel = try await master.openSFTPChannel()
            channels.append(channel)
            try await channel.stream.write(initPacket)
            let reply = try await channel.stream.read(
                upTo: 4096, deadline: Date().addingTimeInterval(15)
            )
            XCTAssertGreaterThanOrEqual(reply.count, 5)
            XCTAssertEqual([UInt8](reply)[4], 2, "SSH_FXP_VERSION")
        }
        defer { channels.forEach { $0.close() } }

        let exec = try await master.openExecChannel(script: RemoteScript(body: "printf 'both\\000'"))
        defer { exec.close() }
        let payload = try await Testbed.read(exec)
        XCTAssertEqual(String(decoding: payload.dropLast(), as: UTF8.self), "both")

        // Killing the bulk channel leaves the metadata channel and the master alone.
        channels[1].close()
        try await Task.sleep(nanoseconds: 300_000_000)
        try await channels[0].stream.write(initPacket)
        let running = await master.isRunning
        XCTAssertTrue(running)
    }

    /// Orphans are not adopted: `-O exit` then unlink, before the first connection.
    func testOrphanSweepRemovesLeftoverSockets() async throws {
        try Testbed.skipUnlessEnabled()
        let path = ControlSocket.path(forLocationID: "ffffffff-0000-0000-0000-000000000000")
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = ControlSocket.sweepOrphans(environment: Testbed.environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
