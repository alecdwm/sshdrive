import XCTest

@testable import Secrets
import XPCProtocols

/// The in-memory store's contract, which is also the keychain store's contract.
///
/// `KeychainSecretsStore` itself cannot be tested here. The data-protection keychain under
/// `RWGDZAYBM8.org.shirls.sshdrive` needs the `keychain-access-groups` entitlement, which
/// needs an embedded provisioning profile, which only the app bundle has - so only the
/// signed agent can reach it (DESIGN.md section 3.1, and S1 d2). A `swift test` binary
/// gets `errSecMissingEntitlement`. The equivalent round trip on the VM is
/// `sshdrive debug secrets store|lookup|delete|list`, run against the launchd-started
/// agent; see docs/skeleton-notes.md.
final class SecretsStoreContractTests: XCTestCase {

    func testStoreLookupDeleteList() throws {
        let store = InMemorySecretsStore()
        let key = SecretKey.password(SSHDestination(user: "pw", hostname: "nas", port: 2201))

        XCTAssertNil(try store.secret(for: key))
        try store.setSecret("spike-password", for: key)
        XCTAssertEqual(try store.secret(for: key), "spike-password")
        // Storing again replaces rather than duplicating.
        try store.setSecret("spike-password-2", for: key)
        XCTAssertEqual(try store.secret(for: key), "spike-password-2")
        XCTAssertEqual(try store.keys(), [key])

        try store.removeSecret(for: key)
        XCTAssertNil(try store.secret(for: key))
        // Deleting what is not there is not an error: `sshdrive remove` runs over a list.
        try store.removeSecret(for: key)
        XCTAssertTrue(try store.accounts().isEmpty)
    }

    func testKeysSkipsAccountsThatAreNotOurs() throws {
        let store = InMemorySecretsStore([
            "passphrase:/k": "x",
            "spike:s1d2": "left over from the S1 hook",
        ])
        XCTAssertEqual(try store.keys(), [.passphrase(path: "/k")])
        XCTAssertEqual(try store.accounts().count, 2)
    }

    func testTheAccessGroupAndServiceAreTheOnesSection31Fixes() {
        XCTAssertEqual(KeychainSecretsStore().accessGroup, "RWGDZAYBM8.org.shirls.sshdrive")
        XCTAssertEqual(KeychainSecretsStore.service, "org.shirls.sshdrive")
    }

    /// Runs only where the entitlement exists. Left in so a future signed test host, or a
    /// developer running the binary from inside the bundle, exercises the real thing.
    func testTheRealKeychainRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["SSHDRIVE_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("needs the keychain-access-groups entitlement; use `sshdrive debug secrets`")
        }
        let store = KeychainSecretsStore()
        let key = SecretKey.passphrase(path: "/tmp/sshdrive-test-\(UUID().uuidString)")
        try store.setSecret("value", for: key)
        XCTAssertEqual(try store.secret(for: key), "value")
        try store.removeSecret(for: key)
        XCTAssertNil(try store.secret(for: key))
    }
}

final class AskpassEnvironmentTests: XCTestCase {

    func testTheThreeVariablesSection42Names() {
        let variables = AskpassEnvironment.variables(
            askpassPath: "/Applications/SSH Drive.app/Contents/MacOS/sshdrive-askpass",
            token: "abc")
        XCTAssertEqual(
            variables["SSH_ASKPASS"],
            "/Applications/SSH Drive.app/Contents/MacOS/sshdrive-askpass")
        XCTAssertEqual(variables["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(variables["SSHDRIVE_ASKPASS_TOKEN"], "abc")
        XCTAssertEqual(variables.count, 3)
    }

    func testAnInheritedPromptHintAndTokenAreStripped() {
        let base = [
            "PATH": "/usr/bin",
            "SSH_ASKPASS_PROMPT": "confirm",
            "SSHDRIVE_ASKPASS_TOKEN": "somebody else's",
        ]
        let environment = AskpassEnvironment.environment(
            base: base, askpassPath: "/x/sshdrive-askpass", token: "ours")
        XCTAssertNil(environment["SSH_ASKPASS_PROMPT"])
        XCTAssertEqual(environment["SSHDRIVE_ASKPASS_TOKEN"], "ours")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }
}

final class ProcessAncestryTests: XCTestCase {

    func testDescendantWalk() {
        let ancestry = StaticProcessAncestry([951: 950, 950: 900, 900: 400, 500: 400])
        XCTAssertTrue(ancestry.isDescendant(900, of: 900))
        XCTAssertTrue(ancestry.isDescendant(950, of: 900))
        XCTAssertTrue(ancestry.isDescendant(951, of: 900))
        XCTAssertFalse(ancestry.isDescendant(500, of: 900))
        XCTAssertFalse(ancestry.isDescendant(400, of: 900))
    }

    func testTheWalkIsBounded() {
        // A cycle, which sysctl should never produce but which must not hang the agent.
        let ancestry = StaticProcessAncestry([10: 11, 11: 10])
        XCTAssertFalse(ancestry.isDescendant(10, of: 99))
    }

    func testTheRealAncestryFindsThisProcessesParent() {
        let ancestry = SysctlProcessAncestry()
        let parent = ancestry.parent(of: getpid())
        XCTAssertEqual(parent, getppid())
        XCTAssertTrue(ancestry.isDescendant(getpid(), of: getppid()))
    }
}
