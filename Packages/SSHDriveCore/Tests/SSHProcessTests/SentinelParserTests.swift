import XCTest
@testable import SSHProcess

/// The section 9.2 sentinel: rc files print on every non-interactive startup, so the agent
/// discards everything up to and including a random 128-bit marker. Driven here with
/// scripted output rather than a server.
final class SentinelParserTests: XCTestCase {

    private let sentinel = Sentinel(hex: "0123456789abcdef0123456789abcdef")

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private var marker: Data { Data(sentinel.marker) }

    func testASentinelIs128RandomBits() {
        let a = Sentinel(), b = Sentinel()
        XCTAssertEqual(a.hex.count, 32)
        XCTAssertNotEqual(a.hex, b.hex)
        XCTAssertTrue(a.hex.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(a.marker.last, 0)
    }

    func testRcNoiseIsDiscardedAndKeptForStatus() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(bytes("Welcome back, alec!\n"))
        parser.append(marker)
        parser.append(bytes("payload"))
        XCTAssertTrue(parser.sawOpeningSentinel)
        XCTAssertEqual(parser.prefixText, "Welcome back, alec!\n")
        XCTAssertEqual(String(decoding: parser.payload, as: UTF8.self), "payload")
    }

    /// The noise routinely arrives in a different read from the sentinel, and the sentinel
    /// itself is split across reads whenever the pipe fills mid-marker.
    func testMarkerSplitAcrossReads() {
        var parser = SentinelParser(sentinel: sentinel)
        let stream = bytes("noise") + marker + bytes("after")
        for byte in stream { parser.append(Data([byte])) }
        XCTAssertTrue(parser.sawOpeningSentinel)
        XCTAssertEqual(parser.prefixText, "noise")
        XCTAssertEqual(String(decoding: parser.payload, as: UTF8.self), "after")
    }

    /// A "Welcome back" with no newline lands in front of env's first record and glues
    /// onto it; NUL separation alone does nothing about that, which is why the sentinel
    /// exists at all.
    func testNoiseGluedToTheFirstRecord() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(bytes("no-newline-here") + Data([0]) + marker + bytes("PATH=/usr/bin") + Data([0]))
        XCTAssertEqual(parser.prefixText, "no-newline-here")
        XCTAssertEqual(parser.environment["PATH"], "/usr/bin")
    }

    /// The closing sentinel is what ends the read: EOF never arrives from an account whose
    /// rc file left a background child holding stdout (`deb-shells`' bashbg).
    func testClosingSentinelEndsTheRead() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(Data([0]) + marker)
        parser.append(bytes("PATH=/opt/homebrew/bin:/usr/bin") + Data([0]))
        parser.append(bytes("SSH_AUTH_SOCK=/tmp/agent.sock") + Data([0]))
        XCTAssertFalse(parser.sawClosingSentinel)
        parser.append(marker)
        XCTAssertTrue(parser.sawClosingSentinel)
        parser.append(bytes("this is a background child still writing"))
        XCTAssertEqual(parser.environment["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(parser.environment["SSH_AUTH_SOCK"], "/tmp/agent.sock")
        XCTAssertEqual(parser.nulRecords.count, 2, "nothing after the closing sentinel is kept")
    }

    func testEnvironmentValuesMayContainEquals() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(marker + bytes("LS_COLORS=di=1;34:ln=35") + Data([0]) + marker)
        XCTAssertEqual(parser.environment["LS_COLORS"], "di=1;34:ln=35")
    }

    /// A `ForceCommand internal-sftp` account answers an exec channel with SFTP framing.
    /// The probe must call that "no shell access", not "shell output unusable".
    func testForceCommandSFTPFramingIsRecognised() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(Data([0x00, 0x00, 0x00, 0x05, 0x02, 0x00, 0x00, 0x00, 0x03]))
        XCTAssertFalse(parser.sawOpeningSentinel)
        XCTAssertTrue(parser.looksLikeSFTPVersion)
    }

    func testPlainNoiseIsNotMistakenForSFTP() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(bytes("hello from .bashrc\n"))
        XCTAssertFalse(parser.looksLikeSFTPVersion)
    }

    /// The prefix is capped: a runaway rc file must not grow the agent's memory.
    func testPrefixIsCappedButTheSentinelIsStillFound() {
        var parser = SentinelParser(sentinel: sentinel, prefixLimit: 16)
        parser.append(Data(repeating: 0x41, count: 200_000))
        parser.append(marker + bytes("ok"))
        XCTAssertEqual(parser.prefix.count, 16)
        XCTAssertTrue(parser.sawOpeningSentinel)
        XCTAssertEqual(String(decoding: parser.payload, as: UTF8.self), "ok")
    }

    func testNulRecordsParseFindPrint0Output() {
        var parser = SentinelParser(sentinel: sentinel)
        parser.append(marker + bytes("data/weird/space in name") + Data([0])
            + bytes("data/weird/quote'name") + Data([0]))
        XCTAssertEqual(
            parser.nulRecords.map { String(decoding: $0, as: UTF8.self) },
            ["data/weird/space in name", "data/weird/quote'name"]
        )
    }
}
