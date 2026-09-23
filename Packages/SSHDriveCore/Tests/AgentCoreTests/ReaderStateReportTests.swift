import XCTest
@testable import AgentCore

/// `doctor`'s "index reader" line (docs/design/cli.md, docs/design/extension.md): which
/// states of the extension's reader pass, which warn, and what the line says.
final class ReaderStateReportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let path = "/g/domains/abc/index.sqlite"

    private func file(_ state: String, ago: Double = 212, lastError: String = "")
        -> [String: Any]
    {
        [
            "state": state, "at": now.timeIntervalSince1970 - ago, "generation": Int64(0),
            "lastError": lastError, "path": path,
        ]
    }

    func testReadyAndExitedPass() {
        let ready = ReaderStateReport(stateFile: file("ready"), now: now)
        XCTAssertEqual(ready.ok, true)
        XCTAssertNil(ready.remedy)
        XCTAssertEqual(ready.detail, "ready, generation 0, reported 212 s ago; \(path)")

        let exited = ReaderStateReport(stateFile: file("exited"), now: now)
        XCTAssertEqual(exited.ok, true, "a torn-down instance is the ordinary idle state")
        XCTAssertNil(exited.remedy)
        XCTAssertEqual(
            exited.detail, "last extension instance exited 212 s ago, generation 0; \(path)")
    }

    func testEveryOtherStateWarns() {
        for state in ["closed", "unknown", "not-ready", "failed", "schema-too-new"] {
            let report = ReaderStateReport(stateFile: file(state), now: now)
            XCTAssertNil(report.ok, state)
            XCTAssertNotNil(report.remedy, state)
            XCTAssertTrue(report.detail.hasPrefix("\(state), generation 0"), report.detail)
        }
        let missing = ReaderStateReport(stateFile: ["at": now.timeIntervalSince1970], now: now)
        XCTAssertNil(missing.ok)
        XCTAssertTrue(missing.detail.hasPrefix("unknown, "), missing.detail)
    }

    func testTheLastErrorIsCarried() {
        let report = ReaderStateReport(
            stateFile: file("failed", lastError: "disk I/O error"), now: now)
        XCTAssertEqual(
            report.detail,
            "failed, generation 0, reported 212 s ago; last error: disk I/O error; \(path)")
    }

    func testAnExtensionThatNeverWroteTheFileWarns() {
        XCTAssertNil(ReaderStateReport.neverReported.ok)
        XCTAssertEqual(
            ReaderStateReport.neverReported.detail, "the extension has never reported its reader")
    }
}
