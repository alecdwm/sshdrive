import XCTest

@testable import Secrets

final class SecretKeyTests: XCTestCase {

    func testPasswordKeyShape() {
        let key = SecretKey.password(SSHDestination(user: "alec", hostname: "NAS.local", port: 2222))
        // Lowercased, as ssh itself prints the hostname; the alias never appears.
        XCTAssertEqual(key.account, "password:alec@nas.local:2222")
    }

    func testPassphraseKeyShape() {
        XCTAssertEqual(
            SecretKey.passphrase(path: "/Users/alec/.ssh/id_nas").account,
            "passphrase:/Users/alec/.ssh/id_nas")
    }

    func testRoundTrip() {
        let keys: [SecretKey] = [
            .password(SSHDestination(user: "alec", hostname: "nas.example", port: 22)),
            .password(SSHDestination(user: "a-b_c", hostname: "10.0.0.4", port: 2210)),
            .passphrase(path: "/Users/alec/.ssh/id ed25519 with spaces"),
            .passphrase(path: "/Users/alec/.ssh/weird:name@here"),
        ]
        for key in keys {
            XCTAssertEqual(SecretKey(account: key.account), key, key.account)
        }
    }

    func testTwoLocationsOnOneHostShareOneItem() {
        // Section 4: the key carries no location id, which is what makes the item shared.
        let first = SecretKey.password(SSHDestination(user: "alec", hostname: "nas", port: 22))
        let second = SecretKey.password(SSHDestination(user: "alec", hostname: "NAS", port: 22))
        XCTAssertEqual(first, second)
    }

    func testEachProxyJumpHopGetsItsOwnItem() {
        let hopA = SecretKey.password(SSHDestination(user: "hop", hostname: "bastion", port: 2210))
        let hopB = SecretKey.password(SSHDestination(user: "hop", hostname: "bastion", port: 22))
        XCTAssertNotEqual(hopA, hopB, "the port is in the key, section 4.2")
    }

    func testNonsenseAccountsDoNotParse() {
        for account in ["", "password:", "password:nohost", "password:a@b:notaport",
                        "passphrase:", "something:else", "password:@host:22"] {
            XCTAssertNil(SecretKey(account: account), account)
        }
    }

    func testReports() {
        XCTAssertEqual(
            SecretKey.password(SSHDestination(user: "alec", hostname: "nas", port: 22)).report,
            "password stored for alec@nas")
        XCTAssertEqual(
            SecretKey.passphrase(path: "/opt/keys/id_nas").report,
            "passphrase stored for /opt/keys/id_nas")
    }
}
