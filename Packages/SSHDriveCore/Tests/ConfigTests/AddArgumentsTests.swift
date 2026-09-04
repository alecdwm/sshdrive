import XCTest

@testable import Config

/// `sshdrive add`'s destination sugar and `sshdrive set`'s key table (DESIGN.md sections
/// 4, 8). Both live in the package so the whole surface can be checked without an XPC
/// connection, a keychain or a server.
final class AddArgumentsTests: XCTestCase {

    // MARK: [user@]host[:port]

    func testPlainHost() throws {
        let parsed = try LocationDestination.parse("nas")
        XCTAssertEqual(parsed, LocationDestination(user: nil, host: "nas", port: nil))
    }

    func testUserAndPort() throws {
        let parsed = try LocationDestination.parse("alec@192.168.64.1:2201")
        XCTAssertEqual(
            parsed, LocationDestination(user: "alec", host: "192.168.64.1", port: 2201))
    }

    func testAliasKeepsItsShape() throws {
        // A `~/.ssh/config` alias is passed through untouched, which is what makes the
        // host block apply (section 4.1).
        let parsed = try LocationDestination.parse("spike-inner")
        XCTAssertEqual(parsed.host, "spike-inner")
        XCTAssertNil(parsed.user)
        XCTAssertNil(parsed.port)
    }

    func testUserWithAtSignInIt() throws {
        // The split is from the right, so an account spelled as an email survives.
        let parsed = try LocationDestination.parse("alec@example.com@gateway:22")
        XCTAssertEqual(parsed.user, "alec@example.com")
        XCTAssertEqual(parsed.host, "gateway")
        XCTAssertEqual(parsed.port, 22)
    }

    func testBracketedIPv6() throws {
        let parsed = try LocationDestination.parse("alec@[fe80::1]:2222")
        XCTAssertEqual(parsed.host, "fe80::1")
        XCTAssertEqual(parsed.port, 2222)
    }

    func testUnbracketedIPv6KeepsEveryColon() throws {
        // Two colons cannot be a port separator, so the literal is taken whole rather than
        // silently losing its last group to `Int()`.
        let parsed = try LocationDestination.parse("fe80::1")
        XCTAssertEqual(parsed.host, "fe80::1")
        XCTAssertNil(parsed.port)
    }

    func testRejects() {
        XCTAssertThrowsError(try LocationDestination.parse(""))
        XCTAssertThrowsError(try LocationDestination.parse("@host"))
        XCTAssertThrowsError(try LocationDestination.parse("host:0"))
        XCTAssertThrowsError(try LocationDestination.parse("host:99999"))
        XCTAssertThrowsError(try LocationDestination.parse("host:ssh"))
    }

    // MARK: set

    private func location() -> Location {
        Location(nickname: "nas", host: "nas.example.org")
    }

    func testEveryKeyInSection8IsNamed() throws {
        for spelling in [
            "nickname", "cache-ttl", "remote-path", "host", "port", "user", "identity",
            "watch-mode", "helper", "permissions", "create-check",
        ] {
            XCTAssertNoThrow(try LocationSettingKey.named(spelling), spelling)
        }
        XCTAssertThrowsError(try LocationSettingKey.named("colour"))
    }

    func testAlternativeSpellings() throws {
        XCTAssertEqual(try LocationSettingKey.named("cacheTTL"), .cacheTTL)
        XCTAssertEqual(try LocationSettingKey.named("path"), .remotePath)
        XCTAssertEqual(try LocationSettingKey.named("watch_mode"), .watchMode)
        XCTAssertEqual(try LocationSettingKey.named("identityFile"), .identity)
    }

    func testNicknameRecreatesTheDomainAndRemotePathDropsTheIndex() {
        // Section 8 and section 13's caveat: the sidebar name is fixed at domain creation
        // unless S9 says otherwise, and a new root invalidates every path in the index.
        XCTAssertTrue(LocationSettingKey.nickname.recreatesDomain)
        XCTAssertTrue(LocationSettingKey.remotePath.recreatesDomain)
        XCTAssertTrue(LocationSettingKey.remotePath.dropsIndex)
        XCTAssertFalse(LocationSettingKey.nickname.dropsIndex)
        XCTAssertFalse(LocationSettingKey.cacheTTL.recreatesDomain)
    }

    func testTheFourKeysThatRekeySecretsReRunTheCollectConnection() {
        for key in [LocationSettingKey.host, .user, .port, .identity] {
            XCTAssertTrue(key.requiresCollectConnection, key.rawValue)
        }
        for key in [LocationSettingKey.nickname, .cacheTTL, .permissions, .helper] {
            XCTAssertFalse(key.requiresCollectConnection, key.rawValue)
        }
    }

    func testApplyingValues() throws {
        var location = self.location()
        try LocationSettingKey.cacheTTL.apply("1d", to: &location)
        XCTAssertEqual(location.cacheTTL, .oneDay)

        try LocationSettingKey.permissions.apply("none", to: &location)
        XCTAssertEqual(location.permissions, .none)

        try LocationSettingKey.helper.apply("off", to: &location)
        XCTAssertFalse(location.helper)

        try LocationSettingKey.watchMode.apply("sweep", to: &location)
        XCTAssertEqual(location.watchMode, .sweep)

        try LocationSettingKey.createCheck.apply("lstat", to: &location)
        XCTAssertEqual(location.createCheck, .lstat)

        try LocationSettingKey.nickname.apply("  homelab  ", to: &location)
        XCTAssertEqual(location.nickname, "homelab")
        XCTAssertEqual(location.displayName, "homelab")
    }

    func testIdentityAlsoWritesIdentitiesOnly() throws {
        // Section 4: `--identity` means the override *plus* `IdentitiesOnly=yes`, so a
        // touch-required FIDO key sitting in `~/.ssh` never gets its turn first (4.2).
        var location = self.location()
        try LocationSettingKey.identity.apply("~/.ssh/id_nas", to: &location)
        XCTAssertEqual(location.identityFile, (("~/.ssh/id_nas") as NSString).expandingTildeInPath)
        XCTAssertTrue(location.sshOptions.contains("IdentitiesOnly=yes"))
        // Applied twice, it is still written once.
        try LocationSettingKey.identity.apply("~/.ssh/id_other", to: &location)
        XCTAssertEqual(location.sshOptions.filter { $0 == "IdentitiesOnly=yes" }.count, 1)
    }

    func testHostTakesTheWholeDestination() throws {
        var location = self.location()
        try LocationSettingKey.host.apply("pw@192.168.64.1:2201", to: &location)
        XCTAssertEqual(location.host, "192.168.64.1")
        XCTAssertEqual(location.user, "pw")
        XCTAssertEqual(location.port, 2201)
    }

    func testBadValuesAreRefusedAndChangeNothing() {
        var location = self.location()
        let before = location
        XCTAssertThrowsError(try LocationSettingKey.cacheTTL.apply("2h", to: &location))
        XCTAssertThrowsError(try LocationSettingKey.permissions.apply("maybe", to: &location))
        XCTAssertThrowsError(try LocationSettingKey.port.apply("70000", to: &location))
        XCTAssertThrowsError(try LocationSettingKey.helper.apply("sometimes", to: &location))
        XCTAssertThrowsError(try LocationSettingKey.nickname.apply("   ", to: &location))
        XCTAssertEqual(location, before)
    }
}
