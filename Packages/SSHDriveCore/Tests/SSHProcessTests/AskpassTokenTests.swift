import Foundation
import XCTest
import XPCProtocols

@testable import SSHProcess

/// A stand-in for `AskpassBroker`, which lives in `Secrets` and must not be a dependency
/// of this module: the two meet on `AskpassTokenProviding` and nothing else (section 4.2).
/// The real broker is driven end to end through `AskpassHarness` in `SecretsTests`, and
/// with a real `ssh` from the signed agent (`docs/spikes/results.md`, S2).
final class RecordingTokenProvider: AskpassTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var minted: [(locationID: String, argv: [String])] = []
    private(set) var attached: [(token: String, pid: Int32)] = []
    private(set) var retired: [String] = []
    var nextToken = "token-1"

    func mintToken(locationID: String, argv: [String]) -> String {
        lock.lock(); defer { lock.unlock() }
        minted.append((locationID, argv))
        return nextToken
    }

    func attachToken(_ token: String, pid: Int32, argv: [String]) {
        lock.lock(); defer { lock.unlock() }
        attached.append((token, pid))
    }

    func retireToken(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        retired.append(token)
    }
}

/// The askpass half of section 4.2 as `SSHProcess` sees it: a token in the master's
/// environment, the same token inherited by every hop of the agent-built `ProxyCommand`,
/// and none of it on a mux client.
final class AskpassTokenTests: XCTestCase {

    private var testbedMaster: SSHMaster?

    override func tearDown() async throws {
        // Not a `defer { Task { … } }`: a detached task in a defer can outlive the test
        // process, and what it leaves behind is a live `ssh -N` whose socket nothing
        // unlinks - an orphan the agent's own sweep cannot reach either, because `-O exit`
        // needs the socket (section 6.1).
        if let testbedMaster { await testbedMaster.shutdown() }
        testbedMaster = nil
    }

    private func master(
        provider: RecordingTokenProvider?, askpassPath: String? = "/x/sshdrive-askpass"
    ) -> SSHMaster {
        SSHMaster(configuration: .init(
            locationID: "loc-1",
            target: SSHTarget(host: "nas"),
            environment: ["HOME": "/Users/alec", "PATH": "/usr/bin", "SSH_ASKPASS_PROMPT": "confirm"],
            askpassPath: askpassPath,
            askpass: provider))
    }

    func testTheMasterCarriesTheThreeAskpassVariablesAndAFreshToken() async {
        let provider = RecordingTokenProvider()
        let master = master(provider: provider)
        let environment = await master.mintedEnvironment(argv: ["/usr/bin/ssh", "-N", "nas"])

        XCTAssertEqual(environment[AskpassEnvironment.askpassVariable], "/x/sshdrive-askpass")
        XCTAssertEqual(environment[AskpassEnvironment.requireVariable], "force")
        XCTAssertEqual(environment[AskpassEnvironment.tokenVariable], "token-1")
        // ssh sets SSH_ASKPASS_PROMPT on the askpass it invokes; it must never be
        // inherited into one (section 4.2).
        XCTAssertNil(environment[AskpassEnvironment.promptVariable])
        XCTAssertEqual(environment["PATH"], "/usr/bin", "the rest of the environment is untouched")
        XCTAssertEqual(provider.minted.count, 1)
        XCTAssertEqual(provider.minted.first?.locationID, "loc-1")
        XCTAssertEqual(
            provider.minted.first?.argv, ["/usr/bin/ssh", "-N", "nas"],
            "the argv the agent built is what tells a hop's own argv apart from the master's")

        let token = await master.askpassToken
        XCTAssertEqual(token, "token-1")
    }

    func testWithoutABrokerNothingIsMintedAndTheEnvironmentIsUnchanged() async {
        let master = master(provider: nil, askpassPath: nil)
        let environment = await master.mintedEnvironment(argv: ["/usr/bin/ssh"])
        XCTAssertNil(environment[AskpassEnvironment.tokenVariable])
        let token = await master.askpassToken
        XCTAssertNil(token)
    }

    func testShutdownRetiresTheTokenBecauseThatEndsEveryHopWithIt() async {
        let provider = RecordingTokenProvider()
        let master = master(provider: provider)
        _ = await master.mintedEnvironment(argv: ["/usr/bin/ssh"])
        await master.shutdown()
        XCTAssertEqual(provider.retired, ["token-1"])
        let token = await master.askpassToken
        XCTAssertNil(token, "a retired token is not offered to the next spawn")
    }

    /// A mux client runs `BatchMode=yes` and can never prompt, and the agent mints it no
    /// token; leaving the variables on it would only invite a refusal the exit classifier
    /// would have to read as an authentication failure (section 6.1).
    func testAMuxClientGetsNoAskpassAndNoToken() {
        let full = AskpassEnvironment.environment(
            base: ["PATH": "/usr/bin"], askpassPath: "/x/sshdrive-askpass", token: "abc")
        let stripped = AskpassEnvironment.removingAskpass(from: full)
        XCTAssertNil(stripped[AskpassEnvironment.askpassVariable])
        XCTAssertNil(stripped[AskpassEnvironment.requireVariable])
        XCTAssertNil(stripped[AskpassEnvironment.tokenVariable])
        XCTAssertNil(stripped[AskpassEnvironment.promptVariable])
        XCTAssertEqual(stripped["PATH"], "/usr/bin")
    }

    /// The real thing against the testbed's password account: a master that has to be
    /// prompted, answered by an askpass named in `SSHMaster.Configuration` and reached
    /// through the environment the master built for itself. The broker's own half needs
    /// `sshdrive-askpass` and the agent's XPC service, so it is proved on the VM instead
    /// (`docs/spikes/results.md`, S2).
    func testMasterAuthenticatesThroughItsOwnAskpassEnvironment() async throws {
        try Testbed.skipUnlessEnabled()
        let stub = try Testbed.StubAskpass()
        defer { stub.remove() }
        let provider = RecordingTokenProvider()
        provider.nextToken = "testbed-token"

        let target = SSHTarget(host: "spike-deb", user: "pw")
        let master = SSHMaster(configuration: .init(
            locationID: UUID().uuidString,
            target: target,
            environment: Testbed.environment,
            askpassPath: stub.scriptPath,
            askpass: provider))
        testbedMaster = master
        do {
            try await master.connect()
        } catch {
            XCTFail("the master did not come up: \(error); prompts seen: \(stub.prompts)")
            return
        }

        XCTAssertEqual(provider.minted.count, 1)
        XCTAssertEqual(provider.attached.first?.token, "testbed-token")
        XCTAssertGreaterThan(provider.attached.first?.pid ?? 0, 0, "the pid is the descendant check")
        XCTAssertTrue(
            stub.prompts.contains { $0.contains("password") },
            "the password prompt reached the askpass: \(stub.prompts)")

        // The channel on that master is a mux client and carries none of it.
        let channel = try await master.openSFTPChannel()
        defer { channel.close() }
        let alive = await master.check()
        XCTAssertTrue(alive)
    }
}
