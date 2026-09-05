import XCTest
@testable import AgentCore

/// DESIGN.md section 10: `doctor`'s "quarantine" check. The xattr read is a function the
/// test supplies, so the decision and the sentence it prints can be exercised without a
/// quarantined bundle.
final class BundleQuarantineTests: XCTestCase {

    private let bundlePath = "/Applications/SSH Drive.app"

    func testNoAttributeIsNotQuarantined() {
        XCTAssertFalse(BundleQuarantine.isQuarantined(bundlePath: bundlePath) { _ in nil })
    }

    func testAttributePresentIsQuarantined() {
        XCTAssertTrue(
            BundleQuarantine.isQuarantined(bundlePath: bundlePath) { path in
                XCTAssertEqual(path, self.bundlePath)
                return "0083;68bb0f00;Homebrew;"
            })
    }

    func testDetailNamesTheAttributeAndItsValue() {
        XCTAssertEqual(
            BundleQuarantine.detail(bundlePath: bundlePath, value: "0083;68bb0f00;Homebrew;"),
            "com.apple.quarantine = 0083;68bb0f00;Homebrew;")
        XCTAssertEqual(
            BundleQuarantine.detail(bundlePath: bundlePath, value: nil), "not quarantined")
    }

    func testRemedyGivesBothCommandsInOrder() {
        let remedy = BundleQuarantine.remedy(bundlePath: bundlePath)
        guard
            let strip = remedy.range(of: "xattr -dr com.apple.quarantine \"\(bundlePath)\""),
            let open = remedy.range(of: "open -g -a \"SSH Drive\"")
        else { return XCTFail("the remedy is missing one of its two commands: \(remedy)") }
        XCTAssertTrue(strip.upperBound <= open.lowerBound, "the open must follow the strip")
    }

    /// The real reader against a path that certainly has no quarantine attribute on it.
    func testAttributeValueOfAnOrdinaryFileIsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdrive-quarantine-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(BundleQuarantine.attributeValue(atPath: url.path))
    }
}
