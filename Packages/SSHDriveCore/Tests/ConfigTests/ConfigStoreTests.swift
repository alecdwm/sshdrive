import XCTest
@testable import Config

final class ConfigStoreTests: XCTestCase {

    private func temporaryStore() -> (ConfigStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-tests-\(UUID().uuidString)", isDirectory: true)
        return (ConfigStore(url: directory.appendingPathComponent("config.json")), directory)
    }

    func testCreatesAFreshConfigOnFirstLoad() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try store.load()
        XCTAssertEqual(file.schemaVersion, ConfigFile.currentSchemaVersion)
        XCTAssertEqual(file.macID.count, 8)
        XCTAssertTrue(file.locations.isEmpty)
    }

    func testRoundTripsALocation() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = Location(nickname: "homelab", host: "nas", remotePath: "/srv/media")
        try store.mutate { $0.locations.append(location) }
        store.invalidate()
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.locations, [location])
    }

    func testResolvesNameByNicknameHostThenIDPrefix() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Location(id: "AAAA1111-0000", nickname: "homelab", host: "nas")
        let second = Location(id: "BBBB2222-0000", host: "backup")
        try store.mutate { $0.locations = [first, second] }
        XCTAssertEqual(try store.location(named: "homelab").id, first.id)
        XCTAssertEqual(try store.location(named: "backup").id, second.id)
        XCTAssertEqual(try store.location(named: "bbbb").id, second.id)
        XCTAssertThrowsError(try store.location(named: "nope"))
    }

    func testDecodesAConfigMissingLaterFields() throws {
        let json = """
            {"schemaVersion": 1, "macID": "abcd1234",
             "locations": [{"id": "1", "host": "nas"}]}
            """
        let file = try JSONDecoder().decode(ConfigFile.self, from: Data(json.utf8))
        let location = try XCTUnwrap(file.locations.first)
        XCTAssertEqual(location.cacheTTL, .oneHour)
        XCTAssertEqual(location.permissions, .mode)
        XCTAssertEqual(location.watchMode, .auto)
        XCTAssertEqual(location.backend, .sftp)
        XCTAssertTrue(location.helper)
        XCTAssertFalse(location.mounted)
    }

    func testDisplayNameFallsBackToHost() {
        XCTAssertEqual(Location(host: "nas").displayName, "nas")
        XCTAssertEqual(Location(nickname: "homelab", host: "nas").displayName, "homelab")
    }
}
