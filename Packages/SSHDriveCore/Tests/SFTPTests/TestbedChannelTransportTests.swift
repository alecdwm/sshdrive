import Foundation
import XCTest
import SSHProcess

@testable import SFTP

/// The seam milestone 2 closes: the wire client of section 6.2 running on a **mux client
/// of the `-N` master** of section 6.1, not on an `ssh` of its own.
///
/// `SFTPSubprocess` spawns its own `ssh -s <host> sftp` and stays as the test path that
/// let the codec be written before `SSHProcess` existed; production opens the subsystem on
/// the master's socket, which is what these tests exercise. Both hand the client the same
/// `ByteStream`, which is the point of there being only one of those now.
///
/// Gated on `SSHDRIVE_TESTBED=1`: the testbed answers the build VM and nothing else.
final class TestbedChannelTransportTests: XCTestCase {

    private var master: SSHMaster?
    private var channel: SFTPChannel?

    override func tearDown() async throws {
        channel?.close()
        channel = nil
        if let master { await master.shutdown() }
        master = nil
    }

    private func connect(alias: String) async throws -> RealSFTPTransport {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SSHDRIVE_TESTBED"] == "1",
            "set SSHDRIVE_TESTBED=1 on the build VM to run this")
        let target = SSHTarget(host: alias)
        let environment = ProcessInfo.processInfo.environment
        let resolution = try SSHConfigResolver.resolve(target: target, environment: environment)
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: target,
            environment: environment,
            proxyCommand: ProxyChainBuilder.proxyCommand(
                for: try resolution.jumpChain(), identityAgentNone: true)))
        self.master = master
        try await master.connect()
        let channel = try await master.openSFTPChannel()
        self.channel = channel
        var configuration = SFTPClient.Configuration()
        configuration.metadataDeadline = .seconds(30)
        configuration.transferBaseDeadline = .seconds(30)
        do {
            return try await RealSFTPTransport.connect(
                stream: channel.stream, root: ".", configuration: configuration)
        } catch {
            XCTFail("the SFTP subsystem did not open on the mux client: \(error); ssh said: \(channel.stderrText)")
            throw error
        }
    }

    /// List, write, read back, rename and delete over the master's SFTP channel: the
    /// whole `SFTPTransport` surface the File Provider paths use.
    func testTheWholeTransportOverAMuxClient() async throws {
        let transport = try await connect(alias: "spike-deb")

        let root = await transport.root
        XCTAssertTrue(root.hasPrefix("/"), "realpath canonicalises the root (section 9.1)")

        let listing = try await transport.readdir(.root)
        XCTAssertTrue(
            listing.contains { String(decoding: $0.name, as: UTF8.self) == "data" },
            "the testbed's data tree is in the account's home")

        let scratch = try RelativePath(string: "sshdrive-mux-\(UUID().uuidString.prefix(8).lowercased())")
        try await transport.mkdir(scratch, mode: 0o755)

        let file = try scratch.appending(component: Data("hello.txt".utf8))
        try await transport.write(file, contents: Data("over the mux client\n".utf8), mode: 0o644)
        let read = try await transport.read(file, offset: 0, length: nil)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "over the mux client\n")

        let attributes = try await transport.lstat(file)
        XCTAssertEqual(attributes.type, .file)
        XCTAssertEqual(attributes.size, 20)
        XCTAssertEqual(attributes.mode & 0o777, 0o644, "the mode is restored after the rename (5.5)")

        let renamed = try scratch.appending(component: Data("renamed.txt".utf8))
        try await transport.rename(file, to: renamed)
        let afterRename = try await transport.readdir(scratch)
        XCTAssertEqual(afterRename.map { String(decoding: $0.name, as: UTF8.self) }, ["renamed.txt"])

        try await transport.remove(renamed)
        let afterDelete = try await transport.readdir(scratch)
        XCTAssertTrue(afterDelete.isEmpty)

        // Cleaned up here rather than in a `defer`, which cannot await: a `Task` in one
        // outlives the test process and leaves the scratch directory on the server.
        try await transport.rmdir(scratch)
    }

    /// The master outlives its channels: a wedged SFTP channel is killed and reopened on
    /// its own without touching the connection (section 6.1).
    func testASecondChannelOpensOnTheSameMasterAfterTheFirstIsKilled() async throws {
        let first = try await connect(alias: "spike-deb")
        _ = try await first.readdir(.root)
        channel?.close()
        channel = nil
        await first.shutdown()

        guard let master else { return XCTFail("no master") }
        let alive = await master.check()
        XCTAssertTrue(alive, "-O check: killing a channel does not touch the connection")

        let second = try await master.openSFTPChannel()
        channel = second
        let transport = try await RealSFTPTransport.connect(stream: second.stream, root: ".")
        let listing = try await transport.readdir(.root)
        XCTAssertFalse(listing.isEmpty)
    }
}
