import XCTest
@testable import SFTP

final class RelativePathTests: XCTestCase {

    func testRootHasNoComponents() throws {
        XCTAssertTrue(RelativePath.root.isRoot)
        XCTAssertTrue(try RelativePath(string: "/").isRoot)
        XCTAssertTrue(try RelativePath(string: "").isRoot)
    }

    func testRejectsEscapingComponents() {
        XCTAssertThrowsError(try RelativePath(string: "a/../b"))
        XCTAssertThrowsError(try RelativePath(components: [Data("..".utf8)]))
        XCTAssertThrowsError(try RelativePath(components: [Data(".".utf8)]))
        XCTAssertThrowsError(try RelativePath(components: [Data()]))
        XCTAssertThrowsError(try RelativePath(components: [Data("a/b".utf8)]))
        XCTAssertThrowsError(try RelativePath(components: [Data([0x61, 0x00])]))
    }

    func testAcceptsNonUTF8Component() throws {
        let name = Data([0xFF, 0xFE, 0x41])
        let path = try RelativePath(components: [name])
        XCTAssertEqual(path.lastComponent, name)
        XCTAssertEqual(path.bytes, name)
    }

    func testRoundTripsThroughIndexBytes() throws {
        let path = try RelativePath(string: "Documents/Reports/report-000.txt")
        let restored = try RelativePath.fromIndexBytes(path.bytes)
        XCTAssertEqual(restored, path)
        XCTAssertEqual(try RelativePath.fromIndexBytes(Data()), .root)
    }

    func testAbsoluteJoinsToRoot() throws {
        let path = try RelativePath(string: "a/b")
        XCTAssertEqual(path.absolute(root: "/srv/media"), "/srv/media/a/b")
        XCTAssertEqual(path.absolute(root: "/srv/media/"), "/srv/media/a/b")
        XCTAssertEqual(RelativePath.root.absolute(root: "/srv/media"), "/srv/media")
    }

    func testContainment() throws {
        let parent = try RelativePath(string: "Documents")
        XCTAssertTrue(try RelativePath(string: "Documents/Reports").isUnder(parent))
        XCTAssertTrue(parent.isUnder(parent))
        XCTAssertFalse(try RelativePath(string: "Media").isUnder(parent))
        XCTAssertTrue(parent.isUnder(.root))
    }
}
