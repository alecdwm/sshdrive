import XCTest
@testable import AgentCore

/// The NDJSON protocol of DESIGN.md section 6.4 tier 2, from the agent's side.
///
/// Framing is the half that has to be right: the exec channel hands over arbitrary chunks,
/// so one line may arrive in six reads and six lines in one, and a decoder that assumed
/// otherwise would invent paths that exist on no server.
final class HelperEventTests: XCTestCase {

    private func decode(_ text: String) -> [HelperEvent] {
        var decoder = HelperEventDecoder()
        return decoder.append(Data(text.utf8))
    }

    func testAChangeLineCarriesEverySection6_4Field() throws {
        let events = decode(
            #"{"op":"modify","path":"a/b.txt","type":"f","size":3,"mtime_ns":1700000000123456789,"# +
            #""inode":42,"mode":420,"uid":1000,"gid":1000}"# + "\n")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .modify)
        XCTAssertEqual(event.path, Data("a/b.txt".utf8))
        XCTAssertEqual(event.size, 3)
        XCTAssertEqual(event.mtimeNanoseconds, 1_700_000_000_123_456_789)
        // Section 5.3: the content version uses whole-second mtime at every tier, so a tier
        // change is invisible. The nanoseconds feed change detection and nothing else.
        XCTAssertEqual(event.mtimeSeconds, 1_700_000_000)
        XCTAssertEqual(event.inode, 42)
        XCTAssertEqual(event.mode, 420)
        XCTAssertTrue(event.isSelfSufficient)
    }

    func testEveryOpSection6_4NamesIsUnderstood() {
        let lines = """
            {"op":"ready","version":"0.1.0","os":"linux","arch":"aarch64","mechanism":"inotify","roots":3}
            {"op":"create","path":"a"}
            {"op":"modify","path":"a"}
            {"op":"delete","path":"a"}
            {"op":"rename","from":"a","path":"b"}
            {"op":"overflow","reason":"the kernel event queue overflowed"}
            {"op":"heartbeat","t":1700000000}
            {"op":"error","message":"could not watch x"}

            """
        let events = decode(lines)
        XCTAssertEqual(
            events.map(\.kind),
            [.ready, .create, .modify, .delete, .rename, .overflow, .heartbeat, .error])
        XCTAssertEqual(events[0].mechanism, "inotify")
        XCTAssertEqual(events[4].from, Data("a".utf8))
        XCTAssertEqual(events[4].path, Data("b".utf8))
        XCTAssertEqual(events[5].message, "the kernel event queue overflowed")
    }

    /// A JSON string is UTF-8 by definition and a server filename need not be (section
    /// 5.4), so a name that is not text travels base64 under its own key and comes back as
    /// the same bytes the index stores.
    func testANonUTF8NameArrivesAsTheSameBytes() throws {
        let raw = Data([0x61, 0xff, 0xfe, 0x62])
        let line = #"{"op":"create","path_b64":"# + "\"\(raw.base64EncodedString())\"}\n"
        let event = try XCTUnwrap(decode(line).first)
        XCTAssertEqual(event.path, raw)
        XCTAssertNil(String(data: event.path!, encoding: .utf8), "still not text, and that is fine")
    }

    func testAFilenameWithANewlineDoesNotSplitTheRecord() throws {
        let event = try XCTUnwrap(decode(#"{"op":"create","path":"two\nlines.txt"}"# + "\n").first)
        XCTAssertEqual(event.path, Data("two\nlines.txt".utf8))
    }

    // MARK: framing

    func testALineSplitAcrossReadsIsOneEvent() {
        var decoder = HelperEventDecoder()
        XCTAssertTrue(decoder.append(Data(#"{"op":"cre"#.utf8)).isEmpty)
        XCTAssertTrue(decoder.append(Data(#"ate","path":"a"#.utf8)).isEmpty)
        let events = decoder.append(Data("\"}\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].path, Data("a".utf8))
    }

    func testSixLinesInOneReadAreSixEvents() {
        let text = (0..<6).map { #"{"op":"create","path":"f\#($0)"}"# }.joined(separator: "\n") + "\n"
        XCTAssertEqual(decode(text).count, 6)
    }

    func testATrailingPartialLineIsHeldAndThenCompleted() {
        var decoder = HelperEventDecoder()
        let first = decoder.append(Data("{\"op\":\"create\",\"path\":\"a\"}\n{\"op\":\"del".utf8))
        XCTAssertEqual(first.count, 1)
        let second = decoder.append(Data("ete\",\"path\":\"a\"}\n".utf8))
        XCTAssertEqual(second.map(\.kind), [.delete])
    }

    /// Half a record is a different path, so a stream that ends mid-line drops it rather
    /// than guessing - the same rule `SweepParser` follows for a truncated sweep.
    func testAPartialLineAtTheEndOfTheStreamIsDropped() {
        var decoder = HelperEventDecoder()
        _ = decoder.append(Data("{\"op\":\"create\",\"path\":\"trunc".utf8))
        XCTAssertTrue(decoder.finish().isEmpty)
    }

    func testAGarbledLineIsSkippedAndTheNextOneIsNot() {
        let events = decode("not json at all\n{\"op\":\"create\",\"path\":\"a\"}\n")
        XCTAssertEqual(events.map(\.kind), [.create])
    }

    /// Backpressure: the helper coalesces server-side, but a `rm -rf` can still outrun the
    /// agent. A bounded batch becomes one `overflow`, which section 6.4 says the agent
    /// answers with a sweep - always safe, where growing without limit is not.
    func testAFloodBecomesAnOverflowRatherThanAnUnboundedBatch() {
        let text = (0..<(HelperEventDecoder.batchLimit + 500))
            .map { #"{"op":"create","path":"f\#($0)"}"# }
            .joined(separator: "\n") + "\n"
        let events = decode(text)
        XCTAssertEqual(events.count, HelperEventDecoder.batchLimit + 1)
        XCTAssertEqual(events.last?.kind, .overflow)
    }

    func testAnAbsurdlyLongLineIsDiscardedAsAnOverflow() {
        var decoder = HelperEventDecoder()
        let events = decoder.append(Data(String(repeating: "x", count: HelperEventDecoder.lineLimit + 1).utf8))
        XCTAssertEqual(events.map(\.kind), [.overflow])
    }

    // MARK: the control line

    func testTheRootsLineIsOneLineAndCarriesAllThreeLists() throws {
        let line = HelperControl.rootsLine(
            shallow: [Data("a".utf8), Data("b/c".utf8)],
            recursive: [Data("pin".utf8)],
            excluded: [Data("pin/big".utf8)])
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["op"] as? String, "roots")
        XCTAssertEqual(object["shallow"] as? [String], ["a", "b/c"])
        XCTAssertEqual(object["recursive"] as? [String], ["pin"])
        XCTAssertEqual(object["excluded"] as? [String], ["pin/big"])
    }

    /// The one thing tier 1 cannot do: `set --` is a String pipeline end to end (section
    /// 9.2), so a root whose bytes are not UTF-8 has to be dropped from a sweep and listed
    /// at tier 0 instead. The helper takes it.
    func testARootThatIsNotUTF8TravelsBase64() throws {
        let raw = Data([0x61, 0xff])
        let line = HelperControl.rootsLine(shallow: [raw], recursive: [], excluded: [])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let shallow = try XCTUnwrap(object["shallow"] as? [[String: String]])
        XCTAssertEqual(shallow.first?["b64"], raw.base64EncodedString())
    }
}
