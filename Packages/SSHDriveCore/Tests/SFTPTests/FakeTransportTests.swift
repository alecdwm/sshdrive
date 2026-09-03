import XCTest
@testable import SFTP

final class FakeTransportTests: XCTestCase {

    private func seeded() async throws -> FakeTransport {
        let transport = FakeTransport()
        try await transport.seedSample(fileCount: 3)
        return transport
    }

    func testListsAndFetches() async throws {
        let transport = try await seeded()
        let names = try await Set(
            transport.readdir(.root).map { String(decoding: $0.name, as: UTF8.self) })
        XCTAssertEqual(names, ["Documents", "Media", "README.txt", "run.sh"])

        let contents = try await transport.read(
            RelativePath(string: "README.txt"), offset: 0, length: nil)
        XCTAssertTrue(String(decoding: contents, as: UTF8.self).hasPrefix("SSH Drive"))
    }

    func testRenameIsNonOverwriting() async throws {
        let transport = try await seeded()
        let source = try RelativePath(string: "README.txt")
        let destination = try RelativePath(string: "run.sh")
        do {
            try await transport.rename(source, to: destination)
            XCTFail("a plain rename must not overwrite")
        } catch let error as SFTPError {
            // EEXIST reaches the wire as a bare FAILURE (section 6.2).
            XCTAssertEqual(error, .failure("Failure"))
        }
        // posix-rename does overwrite.
        try await transport.posixRename(source, to: destination)
        let attributes = try await transport.lstat(destination)
        XCTAssertEqual(attributes.type, .file)
        await XCTAssertThrowsSFTPError(.noSuchFile) { _ = try await transport.lstat(source) }
    }

    func testRmdirRefusesNonEmptyDirectory() async throws {
        let transport = try await seeded()
        await XCTAssertThrowsSFTPError(.failure("Failure")) {
            try await transport.rmdir(RelativePath(string: "Documents"))
        }
        try await transport.rmdir(RelativePath(string: "Media"))
    }

    func testMutationHookStandsInForARemoteChange() async throws {
        let transport = try await seeded()
        let path = try RelativePath(string: "Documents/new.txt")
        try await transport.apply(.createFile(path: path, contents: Data("hi".utf8), mode: 0o644))
        let attributes = try await transport.lstat(path)
        XCTAssertEqual(attributes.size, 2)

        try await transport.apply(.delete(path: path, recursive: false))
        await XCTAssertThrowsSFTPError(.noSuchFile) { _ = try await transport.lstat(path) }
    }

    func testInvisibleRewriteMovesOnlyNanosecondMtimeAndInode() async throws {
        let transport = try await seeded()
        let path = try RelativePath(string: "README.txt")
        let before = try await transport.lstat(path)
        let replacement = Data(repeating: 0x41, count: Int(before.size))
        try await transport.apply(.rewriteInvisibly(path: path, contents: replacement))
        let after = try await transport.lstat(path)
        // This is exactly the change SFTP cannot see, and the reason for the generation
        // column (section 5.3).
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.mtime, before.mtime)
        XCTAssertNotEqual(after.mtimeNanoseconds, before.mtimeNanoseconds)
        XCTAssertNotEqual(after.inode, before.inode)
    }

    func testSymlinkIsALeaf() async throws {
        let transport = try await seeded()
        let link = try RelativePath(string: "link")
        try await transport.symlink(target: "Documents/Reports", at: link)
        let attributes = try await transport.lstat(link)
        XCTAssertEqual(attributes.type, .symlink)
        let target = try await transport.readlink(link)
        XCTAssertEqual(target, "Documents/Reports")
    }
}

/// Asserts that an async body throws a particular SFTPError.
func XCTAssertThrowsSFTPError(
    _ expected: SFTPError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as SFTPError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
