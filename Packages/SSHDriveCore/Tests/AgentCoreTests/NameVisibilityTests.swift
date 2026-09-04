import XCTest
import SFTP
@testable import AgentCore

/// DESIGN.md section 5.4's name rules: case and normalisation collisions, names that are
/// not valid UTF-8, and the four kinds of entry that get no row at all.
final class NameVisibilityTests: XCTestCase {

    private func entry(_ name: String, type: SFTPFileType = .file) -> SFTPDirectoryEntry {
        SFTPDirectoryEntry(name: Data(name.utf8), attributes: SFTPFileAttributes(type: type))
    }

    private func entry(bytes: [UInt8], type: SFTPFileType = .file) -> SFTPDirectoryEntry {
        SFTPDirectoryEntry(name: Data(bytes), attributes: SFTPFileAttributes(type: type))
    }

    private func shown(_ result: NameVisibility.Result) -> Set<String> {
        Set(
            result.entries.filter { $0.hidden == 0 }
                .map { String(decoding: $0.entry.name, as: UTF8.self) })
    }

    private func hidden(_ result: NameVisibility.Result) -> Set<String> {
        Set(
            result.entries.filter { $0.hidden != 0 }
                .map { String(decoding: $0.entry.name, as: UTF8.self) })
    }

    func testNoCollisionShowsEverything() {
        let result = NameVisibility.classify(
            entries: [entry("a.txt"), entry("B.txt"), entry("c")], visibleNames: [])
        XCTAssertEqual(shown(result), ["a.txt", "B.txt", "c"])
        XCTAssertTrue(result.hiddenEntries.isEmpty)
    }

    /// "among newcomers the byte-wise lowest name is shown; the rest are recorded with
    /// `hidden = 2`". `M` is 0x4D and `m` is 0x6D, so `Makefile` wins.
    func testCaseCollisionShowsTheByteWiseLowestNewcomer() {
        let result = NameVisibility.classify(
            entries: [entry("makefile"), entry("Makefile")], visibleNames: [])
        XCTAssertEqual(shown(result), ["Makefile"])
        XCTAssertEqual(hidden(result), ["makefile"])
        XCTAssertEqual(result.entries.count, 2, "a hidden name still gets a row: it holds its slot")
    }

    /// "the one already visible in the index keeps its slot". `readdir` order is not
    /// stable across polls, so the visible name must not flip from one cycle to the next.
    func testTheIncumbentKeepsItsSlot() {
        let visible: Set<Data> = [Data("makefile".utf8)]
        let result = NameVisibility.classify(
            entries: [entry("Makefile"), entry("makefile")], visibleNames: visible)
        XCTAssertEqual(shown(result), ["makefile"])
        XCTAssertEqual(hidden(result), ["Makefile"])

        // And the answer does not depend on the order readdir happened to return.
        let reversed = NameVisibility.classify(
            entries: [entry("makefile"), entry("Makefile")], visibleNames: visible)
        XCTAssertEqual(shown(reversed), ["makefile"])
    }

    /// NFC and NFD `é.txt` are one name to the local filesystem.
    func testNormalisationCollision() {
        let composed = "e\u{0301}.txt"  // NFD
        let precomposed = "\u{00e9}.txt"  // NFC
        // Swift's == on String is canonical-equivalence, which is the very thing that
        // makes these one name locally; the server sees two different byte strings.
        XCTAssertNotEqual(
            Array(composed.utf8), Array(precomposed.utf8),
            "the two spellings differ byte for byte")
        let result = NameVisibility.classify(
            entries: [entry(composed), entry(precomposed)], visibleNames: [])
        XCTAssertEqual(shown(result).count, 1)
        XCTAssertEqual(hidden(result).count, 1)
    }

    /// "Names that are not valid UTF-8 are hidden the same way, which is why the index
    /// stores names as bytes." The testbed's `latin1-caf\xff` is exactly this case.
    func testNonUTF8NamesAreHidden() {
        let latin1 = entry(bytes: Array("latin1-caf".utf8) + [0xff])
        let result = NameVisibility.classify(entries: [latin1, entry("ok.txt")], visibleNames: [])
        XCTAssertEqual(shown(result), ["ok.txt"])
        XCTAssertEqual(result.hiddenEntries.count, 1)
        XCTAssertTrue(result.hiddenEntries[0].reason.contains("not valid UTF-8"))
        XCTAssertEqual(result.hiddenEntries[0].hidden, NameVisibility.hiddenCollision)
    }

    /// "Sockets, FIFOs and device nodes that a readdir reports are never enumerated and
    /// never get a row"; a server-side `.DS_Store` is never enumerated; our own upload
    /// temp files are never enumerated (section 5.5). None of the four gets a row at all,
    /// which is what tells them apart from a hidden name.
    func testFourKindsOfEntryGetNoRow() {
        let result = NameVisibility.classify(
            entries: [
                entry("socket", type: .other),
                entry(".DS_Store"),
                entry(".sshdrive-upload-abc12345-deadbeef"),
                entry("."),
                entry(".."),
                entry("real.txt"),
            ],
            visibleNames: [])
        XCTAssertEqual(shown(result), ["real.txt"])
        XCTAssertEqual(result.entries.count, 1, "no rows for any of them, hidden or otherwise")
        XCTAssertEqual(result.skipped.count, 3, ". and .. are not worth a reason")
        XCTAssertTrue(result.skipped.contains { $0.reason.contains(".DS_Store") })
    }

    /// A dot-file is an ordinary item: it is shown, and the hidden *flag* rather than a
    /// hidden *row* is what keeps it out of Finder's way (section 5.4).
    func testDotFilesAreShown() {
        let result = NameVisibility.classify(
            entries: [entry(".bashrc"), entry(".hidden", type: .directory)], visibleNames: [])
        XCTAssertEqual(shown(result), [".bashrc", ".hidden"])
    }

    /// The section 9.1 chokepoint has the last word: a name it rejects can never be
    /// addressed, so it gets no row.
    func testNamesTheChokepointRejectsGetNoRow() {
        let result = NameVisibility.classify(
            entries: [entry(bytes: Array("bad".utf8) + [0x00]), entry("fine")], visibleNames: [])
        XCTAssertEqual(shown(result), ["fine"])
        XCTAssertEqual(result.entries.count, 1)
    }

    func testByteWiseOrderingIsBytesNotText() {
        XCTAssertTrue(NameVisibility.byteWiseLower(Data("A".utf8), Data("a".utf8)))
        XCTAssertTrue(NameVisibility.byteWiseLower(Data("ab".utf8), Data("abc".utf8)))
        XCTAssertFalse(NameVisibility.byteWiseLower(Data("b".utf8), Data("a".utf8)))
    }
}
