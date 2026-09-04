import XCTest

@testable import XPCProtocols

/// The one blob a row keeps for this Mac: the extended attributes and the Finder tags
/// that never arrive as one (DESIGN.md section 5.4). Its bytes are what section 5.3
/// hashes into the metadata version, so what it encodes has to be stable.
final class LocalAttributesTests: XCTestCase {

    func testAnEmptyAttributeSetEncodesToNothingAtAll() {
        XCTAssertNil(LocalAttributes().encoded())
        XCTAssertNil(LocalAttributes(xattrs: [:], tagData: Data()).encoded())
    }

    func testXattrsAndTagsRoundTrip() throws {
        let original = LocalAttributes(
            xattrs: ["com.apple.TextEncoding": Data("utf-8".utf8)],
            tagData: Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]))
        let blob = try XCTUnwrap(original.encoded())
        XCTAssertEqual(LocalAttributes.decode(blob), original)
    }

    func testTheSameAttributesEncodeToTheSameBytes() throws {
        // The metadata version is a hash of these bytes, so an encoding that reordered
        // keys between runs would move every item's version for nothing.
        let attributes = LocalAttributes(
            xattrs: ["a": Data([1]), "b": Data([2]), "c": Data([3])], tagData: Data([9]))
        XCTAssertEqual(attributes.encoded(), attributes.encoded())
    }

    func testABareDictionaryWrittenBeforeTagsHadAFieldIsStillRead() throws {
        let legacy = try JSONEncoder().encode(["x": Data([1, 2, 3])])
        let decoded = LocalAttributes.decode(legacy)
        XCTAssertEqual(decoded.xattrs, ["x": Data([1, 2, 3])])
        XCTAssertNil(decoded.tagData)
    }

    func testGarbageDecodesToNothingRatherThanThrowing() {
        XCTAssertEqual(LocalAttributes.decode(Data([0xff, 0x00])), LocalAttributes())
        XCTAssertEqual(LocalAttributes.decode(nil), LocalAttributes())
    }

    func testTagDataSurvivesTheSnapshotCoder() throws {
        let snapshot = SSHDriveItemSnapshot(
            identifier: "id", parentIdentifier: "p", filename: "a.txt",
            pathBytes: Data("a.txt".utf8), isDirectory: false, isSymlink: false,
            linkTarget: nil, size: 1, mtime: 2, mode: 0o644, uid: 501, gid: 20,
            contentVersion: "1-2-0", metadataVersion: "v", capabilities: 3,
            fileSystemFlags: 6, kept: false, contentPolicyRawValue: -1,
            extendedAttributes: ["k": Data([1])], tagData: Data([7, 8]))
        let encoded = try NSKeyedArchiver.archivedData(
            withRootObject: snapshot, requiringSecureCoding: true)
        let back = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(
                ofClass: SSHDriveItemSnapshot.self, from: encoded))
        XCTAssertEqual(back.tagData, Data([7, 8]))
        XCTAssertEqual(back.extendedAttributes, ["k": Data([1])])
    }

    /// The blob is hashed into the metadata version (section 5.3), so two encodes of the
    /// same attributes have to be the same bytes. `JSONEncoder` promises no key order
    /// without `.sortedKeys`, and without it this fails about one run in three - which is
    /// the system re-reading every item the agent holds, for nothing (2026-09-04).
    func testEncodingIsByteStableAcrossManyEncodesAndManyKeys() {
        let local = LocalAttributes(
            xattrs: [
                "com.apple.TextEncoding": Data("utf-8;134217984".utf8),
                "com.apple.quarantine": Data("0081;".utf8),
                "user.one": Data([1]),
                "user.two": Data([2]),
                "user.three": Data([3]),
                "zzz.last": Data([9, 9]),
            ],
            tagData: Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]))
        guard let first = local.encoded() else { return XCTFail("nothing encoded") }
        for _ in 0..<200 {
            XCTAssertEqual(LocalAttributes(xattrs: local.xattrs, tagData: local.tagData).encoded(), first)
        }
        XCTAssertEqual(LocalAttributes.decode(first), local)
    }
}
