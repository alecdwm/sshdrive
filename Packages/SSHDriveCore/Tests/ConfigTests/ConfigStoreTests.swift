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

    func testDisplayNameWinsOverAnotherLocationsHost() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nicknamed = Location(
            id: "AAAA1111-0000", nickname: "media", host: "nas", remotePath: "/srv/media")
        let bare = Location(id: "BBBB2222-0000", host: "nas")
        try store.mutate { $0.locations = [nicknamed, bare] }
        XCTAssertEqual(try store.location(named: "nas").id, bare.id)
        XCTAssertEqual(try store.location(named: "media").id, nicknamed.id)
    }

    func testHostSharedByTwoNicknamedLocationsIsAmbiguous() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = Location(id: "AAAA1111-0000", nickname: "media", host: "nas")
        let backup = Location(id: "BBBB2222-0000", nickname: "backup", host: "nas")
        try store.mutate { $0.locations = [media, backup] }
        XCTAssertThrowsError(try store.location(named: "nas")) { error in
            guard case ConfigStoreError.ambiguousLocation(_, let names) = error else {
                return XCTFail("expected ambiguousLocation, got \(error)")
            }
            XCTAssertEqual(names, ["media", "backup"])
        }
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
