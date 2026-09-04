import Foundation
import XCTest
@testable import AgentCore

/// The sweep's output is NUL-delimited and parsed as bytes (DESIGN.md sections 6.4, 9.2).
final class SweepParserTests: XCTestCase {

    /// Joins fields the way the script prints them: every record NUL-terminated, including
    /// the last one.
    private func stream(_ fields: [Data]) -> Data {
        var out = Data()
        for field in fields {
            out.append(field)
            out.append(0)
        }
        return out
    }

    private func stream(_ fields: [String]) -> Data { stream(fields.map { Data($0.utf8) }) }

    // MARK: The GNU record

    func testAGnuRecordRoundTripsEveryField() {
        let output = stream([
            "1756900123",
            "Photos/2024/a.jpg", "f", "4096", "1756900000.1234567890", "98765", "644", "501", "20",
        ])
        let (serverTime, hits) = SweepParser.parse(output, usesPrintf: true)
        XCTAssertEqual(serverTime, 1_756_900_123)
        XCTAssertEqual(hits.count, 1)
        let hit = hits[0]
        XCTAssertEqual(hit.path, Data("Photos/2024/a.jpg".utf8))
        XCTAssertEqual(hit.type, "f")
        XCTAssertEqual(hit.isDirectory, false)
        XCTAssertEqual(hit.size, 4096)
        // %T@ splits on the '.': seconds, then the fraction padded or truncated to nine.
        XCTAssertEqual(hit.mtime, 1_756_900_000)
        XCTAssertEqual(hit.mtimeNanoseconds, 123_456_789)
        XCTAssertEqual(hit.inode, 98765)
        // %m is octal digits: "644" is 0o644, which is 420.
        XCTAssertEqual(hit.mode, 420)
        XCTAssertEqual(hit.uid, 501)
        XCTAssertEqual(hit.gid, 20)
    }

    func testADirectoryRecordAndAShortFraction() {
        let output = stream([
            "10", "Docs", "d", "0", "1756900000.5", "1", "40755", "0", "0",
        ])
        let (_, hits) = SweepParser.parse(output, usesPrintf: true)
        XCTAssertEqual(hits[0].isDirectory, true)
        // "5" pads to "500000000", not to 5.
        XCTAssertEqual(hits[0].mtimeNanoseconds, 500_000_000)
        XCTAssertEqual(hits[0].mode, 0o40755)
    }

    func testAWholeSecondTimestampWithNoFraction() {
        let output = stream(["10", "a", "f", "1", "1756900000", "2", "600", "0", "0"])
        let (_, hits) = SweepParser.parse(output, usesPrintf: true)
        XCTAssertEqual(hits[0].mtime, 1_756_900_000)
        XCTAssertEqual(hits[0].mtimeNanoseconds, 0)
        XCTAssertEqual(hits[0].mode, 0o600)
    }

    func testSeveralRecordsInOneStream() {
        let output = stream([
            "10",
            "a", "f", "1", "1.0", "2", "644", "0", "0",
            "b", "d", "0", "2.0", "3", "755", "0", "0",
        ])
        let (_, hits) = SweepParser.parse(output, usesPrintf: true)
        XCTAssertEqual(hits.map(\.path), [Data("a".utf8), Data("b".utf8)])
        XCTAssertEqual(hits.map(\.type), ["f", "d"])
    }

    // MARK: Bytes, never Strings and never lines

    func testAPathWithANewlineAndANonUTF8ByteSurvives() {
        // Section 9.2: output is "parsed as bytes, never split on newlines". A filename may
        // contain one, and a name need not be valid UTF-8 (section 5.4).
        let path = Data([0x74, 0x77, 0x6F, 0x0A, 0x6C, 0x69, 0x6E, 0x65, 0x73, 0xFF])
        let output = stream([Data("10".utf8), path, Data("f".utf8), Data("1".utf8),
                             Data("1.0".utf8), Data("2".utf8), Data("644".utf8),
                             Data("0".utf8), Data("0".utf8)])
        let (_, hits) = SweepParser.parse(output, usesPrintf: true)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, path)
    }

    // MARK: -print0

    func testAPrintZeroStreamIsBarePathsAfterTheServerTime() {
        let output = stream(["1756900123", "a", "b/c", "d"])
        let (serverTime, hits) = SweepParser.parse(output, usesPrintf: false)
        XCTAssertEqual(serverTime, 1_756_900_123)
        XCTAssertEqual(hits.map(\.path), [Data("a".utf8), Data("b/c".utf8), Data("d".utf8)])
        // Everything else is nil: BSD and busybox hits are stat'ed over SFTP afterwards.
        XCTAssertNil(hits[0].type)
        XCTAssertNil(hits[0].size)
        XCTAssertNil(hits[0].mtime)
        XCTAssertNil(hits[0].isDirectory)
    }

    // MARK: The leading server-time record

    func testTheServerTimeIsTakenAndIsNotAlsoAHit() {
        let output = stream(["1756900123", "a"])
        let (serverTime, hits) = SweepParser.parse(output, usesPrintf: false)
        XCTAssertEqual(serverTime, 1_756_900_123)
        XCTAssertEqual(hits.map(\.path), [Data("a".utf8)])
    }

    func testASweepThatFoundNothingStillCarriesTheServerTime() {
        // The stamp is what the next window is computed from, so an empty sweep is not an
        // empty answer (section 6.4).
        let (serverTime, hits) = SweepParser.parse(stream(["1756900123"]), usesPrintf: true)
        XCTAssertEqual(serverTime, 1_756_900_123)
        XCTAssertTrue(hits.isEmpty)
    }

    func testAMissingDateLeavesTheServerTimeUnknownRatherThanZero() {
        // `date` that printed nothing must not read as the epoch, which would open the
        // next window back to 1970.
        let (serverTime, hits) = SweepParser.parse(stream(["", "a"]), usesPrintf: false)
        XCTAssertNil(serverTime)
        XCTAssertEqual(hits.map(\.path), [Data("a".utf8)])
    }

    func testNoOutputAtAll() {
        let (serverTime, hits) = SweepParser.parse(Data(), usesPrintf: true)
        XCTAssertNil(serverTime)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: A cut stream

    func testATruncatedFinalRecordIsDroppedAndNotGuessed() {
        // Half a path is a different file, so it is never reported.
        var output = stream(["10", "a"])
        output.append(contentsOf: Data("bcd".utf8))
        let (serverTime, hits) = SweepParser.parse(output, usesPrintf: false)
        XCTAssertEqual(serverTime, 10)
        XCTAssertEqual(hits.map(\.path), [Data("a".utf8)])
    }

    func testAGnuRecordCutMidWayIsDroppedWhole() {
        let output = stream([
            "10",
            "a", "f", "1", "1.0", "2", "644", "0", "0",
            "b", "d", "0",
        ])
        let (_, hits) = SweepParser.parse(output, usesPrintf: true)
        // The second record has three of its eight fields; three fields are not a hit.
        XCTAssertEqual(hits.map(\.path), [Data("a".utf8)])
    }
}
