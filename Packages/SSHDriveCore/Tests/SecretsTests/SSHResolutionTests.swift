import XCTest

@testable import Secrets

final class SSHResolutionTests: XCTestCase {

    /// A trimmed but verbatim-shaped `ssh -G` block. `ssh -G` prints one lowercased
    /// keyword per line and lists `identityfile` once per identity, in offer order.
    private let output = """
        user alec
        hostname nas.example.com
        port 2222
        identityfile ~/.ssh/id_ed25519_sk
        identityfile ~/.ssh/id_nas
        proxyjump hop@bastion
        controlmaster auto
        """

    func testParsesTheFourLinesThatMatter() throws {
        let resolution = try XCTUnwrap(SSHGResolver.parse(output))
        XCTAssertEqual(resolution.destination.user, "alec")
        XCTAssertEqual(resolution.destination.hostname, "nas.example.com")
        XCTAssertEqual(resolution.destination.port, 2222)
        XCTAssertEqual(resolution.identityFiles.count, 2)
        XCTAssertTrue(resolution.identityFiles[0].hasSuffix("/.ssh/id_ed25519_sk"))
        XCTAssertFalse(resolution.identityFiles[0].hasPrefix("~"), "the prompt carries the expanded path")
    }

    func testAnIncompleteResolutionIsNoResolution() {
        XCTAssertNil(SSHGResolver.parse("user alec\nport 22\n"))
        XCTAssertNil(SSHGResolver.parse(""))
    }

    func testHostnameIsLowercasedTheWaySSHPrintsIt() throws {
        let resolution = try XCTUnwrap(
            SSHGResolver.parse("user alec\nhostname NAS.Example.COM\nport 22\n"))
        XCTAssertEqual(
            SecretKey.password(resolution.destination).account, "password:alec@nas.example.com:22")
    }

    func testTildeExpansion() {
        XCTAssertEqual(SSHGResolver.expandTilde("~"), NSHomeDirectory())
        XCTAssertEqual(SSHGResolver.expandTilde("~/.ssh/id"), NSHomeDirectory() + "/.ssh/id")
        XCTAssertEqual(SSHGResolver.expandTilde("/abs/id"), "/abs/id")
    }
}
