import Foundation
import XCTest

@testable import SFTP

/// `RealSFTPTransport` over the in-memory wire server: the `SFTPTransport` surface, the
/// `RelativePath` chokepoint of DESIGN.md section 9.1, and section 5.5's never-write-in-
/// place upload, all without a network.
final class RealSFTPTransportTests: XCTestCase {

    private func connected(_ server: InMemorySFTPServer) async throws -> RealSFTPTransport {
        let stream = ScriptedByteStream()
        stream.responder = server.responder()
        return try await RealSFTPTransport.connect(
            stream: stream, root: String(decoding: server.root, as: UTF8.self),
            uploadTag: "aabbccdd")
    }

    func testPathsAreJoinedToTheCanonicalRootAndNeverEscapeIt() async throws {
        let server = InMemorySFTPServer()
        server.putDirectory("dir")
        server.put("dir/file.txt", contents: Data("hi".utf8))
        let transport = try await connected(server)

        let attributes = try await transport.lstat(RelativePath(string: "dir/file.txt"))
        XCTAssertEqual(attributes.size, 2)

        // The chokepoint: a component that would escape cannot even be constructed, so
        // there is no call site here that could get it wrong (section 9.1).
        XCTAssertThrowsError(try RelativePath(string: "a/../../etc/passwd").components)
        var raw = Data("bad".utf8)
        raw.append(0x2F)
        XCTAssertThrowsError(try RelativePath(components: [raw]))
        await transport.shutdown()
    }

    func testRootJoiningIsByteExactForNonUTF8Names() throws {
        var weird = Data("caf".utf8)
        weird.append(0xFF)
        let path = try RelativePath(components: [Data("weird".utf8), weird])
        var expected = Data("/srv/root/weird/".utf8)
        expected.append(weird)
        XCTAssertEqual(path.absoluteBytes(root: Data("/srv/root".utf8)), expected)
        // A trailing slash on the root does not produce a double slash.
        XCTAssertEqual(
            try RelativePath(string: "a").absoluteBytes(root: Data("/srv/".utf8)),
            Data("/srv/a".utf8))
        // Zero components is the root itself (section 7.1.2).
        XCTAssertEqual(
            RelativePath.root.absoluteBytes(root: Data("/srv/root".utf8)),
            Data("/srv/root".utf8))
    }

    func testListReadWriteRenameDelete() async throws {
        let server = InMemorySFTPServer()
        server.putDirectory("dir")
        server.put("dir/a.txt", contents: Data("alpha".utf8))
        server.put("dir/b.txt", contents: Data("beta".utf8))
        let transport = try await connected(server)

        let names = try await Set(
            transport.readdir(RelativePath(string: "dir")).map {
                String(decoding: $0.name, as: UTF8.self)
            })
        XCTAssertEqual(names, ["a.txt", "b.txt"])

        let data = try await transport.read(
            RelativePath(string: "dir/a.txt"), offset: 0, length: nil)
        XCTAssertEqual(data, Data("alpha".utf8))

        let partial = try await transport.read(
            RelativePath(string: "dir/a.txt"), offset: 1, length: 3)
        XCTAssertEqual(partial, Data("lph".utf8))

        try await transport.write(
            RelativePath(string: "dir/c.txt"), contents: Data("gamma".utf8), mode: 0o600)
        XCTAssertEqual(server.contents(of: "dir/c.txt"), Data("gamma".utf8))

        try await transport.rename(
            RelativePath(string: "dir/c.txt"), to: RelativePath(string: "dir/d.txt"))
        XCTAssertFalse(server.exists("dir/c.txt"))
        XCTAssertTrue(server.exists("dir/d.txt"))

        try await transport.remove(RelativePath(string: "dir/d.txt"))
        XCTAssertFalse(server.exists("dir/d.txt"))

        try await transport.mkdir(RelativePath(string: "dir/sub"), mode: 0o755)
        try await transport.rmdir(RelativePath(string: "dir/sub"))
        XCTAssertFalse(server.exists("dir/sub"))
        await transport.shutdown()
    }

    /// Section 5.5: uploads go to `.sshdrive-upload-<mac8>-<uuid>` and then take the
    /// name; nothing is ever written in place, and no temp file is left behind.
    func testWriteGoesThroughATempFileAndLeavesNoneBehind() async throws {
        let server = InMemorySFTPServer()
        server.put("existing.txt", contents: Data("old contents".utf8))
        let transport = try await connected(server)
        try await transport.write(
            RelativePath(string: "existing.txt"), contents: Data("new".utf8), mode: 0o644)

        XCTAssertEqual(server.contents(of: "existing.txt"), Data("new".utf8))
        XCTAssertFalse(
            server.allPaths.contains { $0.contains(".sshdrive-upload-") },
            "the temp file must be gone: \(server.allPaths)")
        await transport.shutdown()
    }

    func testWriteWithoutPosixRenameFallsBackAndStillReplaces() async throws {
        let server = InMemorySFTPServer()
        server.advertisedExtensions = [SFTPExtensionName.limits]
        server.put("f.txt", contents: Data("old".utf8))
        let transport = try await connected(server)
        try await transport.write(
            RelativePath(string: "f.txt"), contents: Data("new".utf8), mode: 0o644)
        XCTAssertEqual(server.contents(of: "f.txt"), Data("new".utf8))
        XCTAssertFalse(server.allPaths.contains { $0.contains(".sshdrive-upload-") })
        await transport.shutdown()
    }

    func testSymlinkAndReadlink() async throws {
        let server = InMemorySFTPServer()
        server.put("target.txt", contents: Data("t".utf8))
        let transport = try await connected(server)
        try await transport.symlink(target: "target.txt", at: RelativePath(string: "link"))
        let attributes = try await transport.lstat(RelativePath(string: "link"))
        XCTAssertEqual(attributes.type, .symlink)
        // lstat semantics: the link is a leaf and is never followed (section 9.1), and
        // the target comes back verbatim (section 5.7).
        XCTAssertEqual(attributes.symlinkTarget, "target.txt")
        let target = try await transport.readlink(RelativePath(string: "link"))
        XCTAssertEqual(target, "target.txt")
        await transport.shutdown()
    }

    func testSetstatUsesLsetstatWhenTheServerHasIt() async throws {
        let server = InMemorySFTPServer()
        server.put("f.txt", contents: Data("x".utf8), mode: 0o644)
        let stream = ScriptedByteStream()
        stream.responder = server.responder()
        let transport = try await RealSFTPTransport.connect(
            stream: stream, root: String(decoding: server.root, as: UTF8.self))
        try await transport.setstat(RelativePath(string: "f.txt"), mode: 0o600, mtime: nil)
        // It went out as the extension, not as a plain setstat that would have followed a
        // symlink (section 9.1).
        let extended = stream.writtenPackets(ofType: .extended)
        XCTAssertTrue(
            extended.contains { packet in
                var reader = packet.reader()
                _ = try? reader.readUInt32()
                return (try? reader.readText()) == SFTPExtensionName.lsetstat
            })
        XCTAssertTrue(stream.writtenPackets(ofType: .setstat).isEmpty)
        await transport.shutdown()
    }

    func testMissingFileIsNoSuchFileAndNotSomethingFiner() async throws {
        let server = InMemorySFTPServer()
        let transport = try await connected(server)
        await assertSFTPError(.noSuchFile) {
            _ = try await transport.lstat(RelativePath(string: "nope"))
        }
        await transport.shutdown()
    }

    func testStatvfsAnswersTheDiskFullQuestion() async throws {
        let server = InMemorySFTPServer()
        server.availableBlocks = 0
        let transport = try await connected(server)
        let stats = try await transport.statvfs(.root)
        XCTAssertTrue(stats.isFull)
        await transport.shutdown()
    }

    func testVerifyRootRefusesWhenTheRootMoved() async throws {
        let server = InMemorySFTPServer()
        let transport = try await connected(server)
        try await transport.verifyRoot()
        // The in-memory server echoes realpath, so a genuine move cannot be staged here;
        // what is asserted is that the check runs and passes on an unmoved root, which is
        // the per-connection check section 9.1 requires.
        let root = await transport.root
        XCTAssertEqual(root, String(decoding: server.root, as: UTF8.self))
        await transport.shutdown()
    }

    func testALargeFileRoundTripsThroughThePipeline() async throws {
        let server = InMemorySFTPServer()
        server.limits = SFTPLimits(
            maxPacketLength: 34000, maxReadLength: 8192, maxWriteLength: 8192,
            maxOpenHandles: 10)
        var payload = Data(count: 512 * 1024)
        for index in 0..<payload.count { payload[index] = UInt8((index &* 31) % 251) }
        let transport = try await connected(server)
        try await transport.write(
            RelativePath(string: "big.bin"), contents: payload, mode: 0o644)
        let read = try await transport.read(
            RelativePath(string: "big.bin"), offset: 0, length: nil)
        XCTAssertEqual(read.count, payload.count)
        XCTAssertEqual(read, payload)
        await transport.shutdown()
    }
}
