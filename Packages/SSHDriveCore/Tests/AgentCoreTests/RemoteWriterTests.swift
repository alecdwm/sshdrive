import XCTest
import Config
import SFTP

@testable import AgentCore

/// DESIGN.md section 5.5's write matrix, against the fake backend: the temp-file plus
/// rename upload with its mode and mtime restore, the create-versus-overwrite rule, the
/// conflict copy, the in-flight set, stale temp files, and the delete rules.
final class RemoteWriterTests: XCTestCase {

    private func path(_ text: String) throws -> RelativePath { try RelativePath(string: text) }

    private func makeWriter(
        _ transport: any SFTPTransport, createCheck: CreateCheck = .auto
    ) -> RemoteWriter {
        RemoteWriter(
            transport: transport,
            options: RemoteWriter.Options(
                macID: "aabbccdd", localHostName: "test-mac", createCheck: createCheck))
    }

    private func source(_ text: String) -> @Sendable () throws -> Data {
        // One chunk then EOF, which is the contract `writeExclusive` reads.
        let box = Box(Data(text.utf8))
        return { box.take() }
    }

    private final class Box: @unchecked Sendable {
        private var data: Data?
        private let lock = NSLock()
        init(_ data: Data) { self.data = data }
        func take() -> Data {
            lock.lock()
            defer { lock.unlock() }
            let out = data ?? Data()
            data = nil
            return out
        }
    }

    private func seededTree() async throws -> FakeTransport {
        let transport = FakeTransport(root: "/srv/fake", uid: 501, gid: 20)
        try await transport.apply(.createDirectory(path: try path("Docs"), mode: 0o755))
        try await transport.apply(
            .createFile(path: try path("Docs/note.txt"), contents: Data("old".utf8), mode: 0o644))
        return transport
    }

    // MARK: The upload protocol

    func testACreateLandsThroughATempFileAndLeavesNothingBehind() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/new.txt")

        let outcome = try await writer.upload(
            to: target, mode: 0o644, modificationDate: 1_700_000_000,
            replacingExisting: false, base: nil, currentGeneration: 0, window: 4,
            source: source("hello"), progress: { _ in })

        guard case let .landed(attributes) = outcome else { return XCTFail("expected a landing") }
        XCTAssertEqual(attributes.size, 5)
        // Section 5.5: the mtime the system passed in, truncated to whole seconds, is set
        // back after the rename and read out by the post-upload `lstat`.
        XCTAssertEqual(attributes.mtime, 1_700_000_000)
        XCTAssertEqual(attributes.mode & 0o777, 0o644)
        let landedBytes = try await transport.read(target, offset: 0, length: nil)
        XCTAssertEqual(landedBytes, Data("hello".utf8))

        let names = try await transport.readdir(try path("Docs")).map {
            String(decoding: $0.name, as: UTF8.self)
        }
        XCTAssertFalse(names.contains { $0.hasPrefix(".sshdrive-upload-") })
    }

    func testAnExecutableCreateKeepsItsModeThroughTheRename() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/run.sh")
        _ = try await writer.upload(
            to: target, mode: 0o755, modificationDate: nil, replacingExisting: false,
            base: nil, currentGeneration: 0, window: 4, source: source("#!/bin/sh\n"),
            progress: { _ in })
        let attributes = try await transport.lstat(target)
        XCTAssertEqual(attributes.mode & 0o777, 0o755)
    }

    func testACreateOntoATakenNameIsAConfirmedCollisionAndCleansUp() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")

        do {
            _ = try await writer.upload(
                to: target, mode: 0o644, modificationDate: nil, replacingExisting: false,
                base: nil, currentGeneration: 0, window: 4, source: source("new"),
                progress: { _ in })
            XCTFail("expected a collision")
        } catch let error as RemoteWriteError {
            XCTAssertEqual(error, .filenameCollision("Docs/note.txt"))
        }

        // The original is untouched and no temp file is left behind.
        let untouched = try await transport.read(target, offset: 0, length: nil)
        XCTAssertEqual(untouched, Data("old".utf8))
        let names = try await transport.readdir(try path("Docs")).map {
            String(decoding: $0.name, as: UTF8.self)
        }
        XCTAssertFalse(names.contains { $0.hasPrefix(".sshdrive-upload-") })
    }

    func testAReplacementOverwritesThroughPosixRename() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")
        let before = try await transport.lstat(target)

        let outcome = try await writer.upload(
            to: target, mode: 0o644, modificationDate: nil, replacingExisting: true,
            base: RemoteWriter.BaseVersion(
                size: before.size, mtime: before.mtime, generation: 0),
            currentGeneration: 0, window: 4, source: source("replaced"), progress: { _ in })

        guard case .landed = outcome else { return XCTFail("expected a landing") }
        let replaced = try await transport.read(target, offset: 0, length: nil)
        XCTAssertEqual(replaced, Data("replaced".utf8))
    }

    func testAServerWithoutPosixRenameStillReplaces() async throws {
        let transport = try await seededTree()
        await transport.setExtensions([.statvfs, .fsync])
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")
        let before = try await transport.lstat(target)

        _ = try await writer.upload(
            to: target, mode: 0o644, modificationDate: nil, replacingExisting: true,
            base: RemoteWriter.BaseVersion(
                size: before.size, mtime: before.mtime, generation: 0),
            currentGeneration: 0, window: 4, source: source("replaced"), progress: { _ in })
        let replacedWithoutPosix = try await transport.read(target, offset: 0, length: nil)
        XCTAssertEqual(replacedWithoutPosix, Data("replaced".utf8))
    }

    // MARK: The conflict check and the conflict copy

    func testASizeThatMovedSinceTheBaseVersionMakesAConflictCopy() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")
        let before = try await transport.lstat(target)

        // The server changed under the user: the base version the system passed us no
        // longer describes what is there.
        try await transport.apply(
            .write(path: target, contents: Data("remote wins".utf8)))

        let outcome = try await writer.upload(
            to: target, mode: 0o644, modificationDate: nil, replacingExisting: true,
            base: RemoteWriter.BaseVersion(
                size: before.size, mtime: before.mtime, generation: 0),
            currentGeneration: 0, window: 4, source: source("local edit"), progress: { _ in })

        guard case let .conflicted(copy, copyAttributes, remote) = outcome else {
            return XCTFail("expected a conflict")
        }
        // The destination is untouched and still holds the remote content.
        let remoteBytes = try await transport.read(target, offset: 0, length: nil)
        XCTAssertEqual(remoteBytes, Data("remote wins".utf8))
        XCTAssertEqual(remote.size, Int64("remote wins".utf8.count))
        // The temp file, which already held the local content, became the copy.
        let copyBytes = try await transport.read(copy, offset: 0, length: nil)
        XCTAssertEqual(copyBytes, Data("local edit".utf8))
        XCTAssertEqual(copyAttributes.size, Int64("local edit".utf8.count))
        XCTAssertTrue(copy.description.hasPrefix("Docs/note (conflicted copy from test-mac "))
        XCTAssertTrue(copy.description.hasSuffix(").txt"))
    }

    func testAGenerationThatMovedIsAConflictThatTheLstatAloneCannotSee() async throws {
        // Section 5.3: a remote rewrite of equal size within the same second is visible
        // only through the inode or nanosecond evidence that bumped the generation, and a
        // check that read the `lstat` alone would let this save overwrite that change.
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")
        let before = try await transport.lstat(target)

        let outcome = try await writer.upload(
            to: target, mode: 0o644, modificationDate: nil, replacingExisting: true,
            base: RemoteWriter.BaseVersion(
                size: before.size, mtime: before.mtime, generation: 0),
            currentGeneration: 1, window: 4, source: source("local edit"), progress: { _ in })

        guard case .conflicted = outcome else { return XCTFail("expected a conflict") }
    }

    func testAMatchingBaseVersionIsNotAConflict() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")
        let before = try await transport.lstat(target)
        let outcome = try await writer.upload(
            to: target, mode: 0o644, modificationDate: nil, replacingExisting: true,
            base: RemoteWriter.BaseVersion(
                size: before.size, mtime: before.mtime, generation: 7),
            currentGeneration: 7, window: 4, source: source("fine"), progress: { _ in })
        guard case .landed = outcome else { return XCTFail("expected a landing") }
    }

    func testTheConflictCopyNameCarriesTheMacAndKeepsTheExtension() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = RemoteWriter.conflictCopyName(
            for: "report.tar.gz", hostName: "Alecs-Mac", date: date,
            calendar: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(
            name, "report.tar (conflicted copy from Alecs-Mac 2023-11-14 at 22.13.20).gz")
    }

    func testAConflictCopyOfADotfileKeepsItsLeadingDot() {
        let date = Date(timeIntervalSince1970: 0)
        let name = RemoteWriter.conflictCopyName(
            for: ".profile", hostName: "mac", date: date,
            calendar: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(name.hasPrefix(".profile (conflicted copy from mac "))
    }

    func testASecondConflictInTheSameSecondGetsACounterRatherThanEatingTheFirst() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/note.txt")
        let before = try await transport.lstat(target)
        let base = RemoteWriter.BaseVersion(
            size: before.size, mtime: before.mtime, generation: 0)

        var copies: [String] = []
        for text in ["first", "second"] {
            let outcome = try await writer.upload(
                to: target, mode: 0o644, modificationDate: nil, replacingExisting: true,
                base: base, currentGeneration: 1, window: 4, source: source(text),
                progress: { _ in })
            guard case let .conflicted(copy, _, _) = outcome else {
                return XCTFail("expected a conflict")
            }
            copies.append(copy.description)
        }
        XCTAssertEqual(Set(copies).count, 2)
        let firstCopy = try await transport.read(try path(copies[0]), offset: 0, length: nil)
        let secondCopy = try await transport.read(try path(copies[1]), offset: 0, length: nil)
        XCTAssertEqual(firstCopy, Data("first".utf8))
        XCTAssertEqual(secondCopy, Data("second".utf8))
    }

    // MARK: The in-flight set

    func testTheInFlightSetIsEmptyOnceTheUploadHasLanded() async throws {
        // Section 5.5: the differ skips paths with an upload in flight, and the set is
        // also what tells a live temp file from a stale one, so it has to empty.
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let target = try path("Docs/slow.txt")
        _ = try await writer.upload(
            to: target, mode: 0o644, modificationDate: nil, replacingExisting: false,
            base: nil, currentGeneration: 0, window: 2, source: source("bytes"),
            progress: { _ in })
        let stillInFlight = await writer.inFlightPaths()
        XCTAssertTrue(stillInFlight.isEmpty)
        let live = await writer.isInFlight(target)
        XCTAssertFalse(live)
    }

    // MARK: Stale temp files

    func testOurOwnTempFilesAreSweptAndOtherMacsAreLeftForThirtyDays() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let ours = ".sshdrive-upload-aabbccdd-\(UUID().uuidString.lowercased())"
        let freshOther = ".sshdrive-upload-11223344-\(UUID().uuidString.lowercased())"
        let oldOther = ".sshdrive-upload-11223344-\(UUID().uuidString.lowercased())"
        for name in [ours, freshOther, oldOther] {
            try await transport.apply(
                .createFile(
                    path: try path("Docs").appending(component: name), contents: Data(),
                    mode: 0o600))
        }
        // Only the ages differ; the entry list is what the sweep reads.
        let entries = try await transport.readdir(try path("Docs")).map { entry -> SFTPDirectoryEntry in
            var copy = entry
            if String(decoding: entry.name, as: UTF8.self) == oldOther {
                copy.attributes.mtime = Int64(now.timeIntervalSince1970) - 31 * 86400
            } else {
                copy.attributes.mtime = Int64(now.timeIntervalSince1970) - 60
            }
            return copy
        }

        let removed = await writer.sweepTemporaries(
            in: try path("Docs"), entries: entries, now: now)
        let removedNames = Set(removed.map { $0.description })
        XCTAssertTrue(removedNames.contains("Docs/\(ours)"))
        XCTAssertTrue(removedNames.contains("Docs/\(oldOther)"))
        XCTAssertFalse(removedNames.contains("Docs/\(freshOther)"))

        let left = try await transport.readdir(try path("Docs")).map {
            String(decoding: $0.name, as: UTF8.self)
        }
        XCTAssertTrue(left.contains(freshOther))
        XCTAssertTrue(left.contains("note.txt"))
    }

    // MARK: Renames and moves

    func testARenameAcrossDirectoriesMovesTheFile() async throws {
        let transport = try await seededTree()
        try await transport.apply(.createDirectory(path: try path("Other"), mode: 0o755))
        let writer = makeWriter(transport)
        try await writer.move(try path("Docs/note.txt"), to: try path("Other/moved.txt"))
        let moved = try await transport.read(try path("Other/moved.txt"), offset: 0, length: nil)
        XCTAssertEqual(moved, Data("old".utf8))
        await XCTAssertThrowsSFTP { try await transport.lstat(try self.path("Docs/note.txt")) }
    }

    func testARenameOntoATakenNameIsAConfirmedCollision() async throws {
        let transport = try await seededTree()
        try await transport.apply(
            .createFile(path: try path("Docs/other.txt"), contents: Data("x".utf8), mode: 0o644))
        let writer = makeWriter(transport)
        do {
            try await writer.move(try path("Docs/note.txt"), to: try path("Docs/other.txt"))
            XCTFail("expected a collision")
        } catch let error as RemoteWriteError {
            XCTAssertEqual(error, .filenameCollision("Docs/other.txt"))
        }
        // Neither file moved.
        let other = try await transport.read(try path("Docs/other.txt"), offset: 0, length: nil)
        XCTAssertEqual(other, Data("x".utf8))
    }

    func testACaseOnlyRenameIsRedoneWithPosixRenameRatherThanRefused() async throws {
        // Section 5.5: on a case-insensitive server `link` fails with EEXIST and the
        // confirming `lstat` finds a file at the destination, which the plain rule would
        // report as a collision for a legitimate rename.
        let transport = CaseInsensitiveFake(root: "/srv/fake")
        try await transport.apply(.createDirectory(path: try path("Docs"), mode: 0o755))
        try await transport.apply(
            .createFile(path: try path("Docs/Makefile"), contents: Data("all:".utf8), mode: 0o644))
        let writer = makeWriter(transport)

        try await writer.move(try path("Docs/Makefile"), to: try path("Docs/makefile"))
        let names = try await transport.readdir(try path("Docs")).map {
            String(decoding: $0.name, as: UTF8.self)
        }
        XCTAssertEqual(names, ["makefile"])
    }

    // MARK: Deletes

    func testANonEmptyDirectoryIsRefusedUnlessTheDeleteIsRecursive() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        do {
            try await writer.delete(try path("Docs"), isDirectory: true, recursive: false)
            XCTFail("expected the delete to be rejected")
        } catch let error as RemoteWriteError {
            XCTAssertEqual(error, .deletionRejected("Docs"))
        }
        // Still there.
        _ = try await transport.lstat(try path("Docs/note.txt"))
    }

    func testARecursiveDeleteWalksTheServerAndTakesTheWholeSubtree() async throws {
        let transport = try await seededTree()
        try await transport.apply(.createDirectory(path: try path("Docs/deep"), mode: 0o755))
        try await transport.apply(
            .createFile(path: try path("Docs/deep/x"), contents: Data("x".utf8), mode: 0o644))
        let writer = makeWriter(transport)
        try await writer.delete(try path("Docs"), isDirectory: true, recursive: true)
        await XCTAssertThrowsSFTP { try await transport.lstat(try self.path("Docs")) }
    }

    func testAnEmptyDirectoryIsRemovedWithoutTheRecursiveOption() async throws {
        let transport = try await seededTree()
        try await transport.apply(.createDirectory(path: try path("Empty"), mode: 0o755))
        let writer = makeWriter(transport)
        try await writer.delete(try path("Empty"), isDirectory: true, recursive: false)
        await XCTAssertThrowsSFTP { try await transport.lstat(try self.path("Empty")) }
    }

    func testDeletingSomethingAlreadyGoneSucceeds() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        try await writer.delete(try path("Docs/ghost.txt"), isDirectory: false, recursive: false)
    }

    // MARK: Permissions

    func testAWriteIntoADirectoryTheAccountCannotWriteFailsWithPermissionDenied() async throws {
        let transport = try await seededTree()
        await transport.refuseWrites(under: [try path("Docs")])
        let writer = makeWriter(transport)
        do {
            _ = try await writer.upload(
                to: try path("Docs/new.txt"), mode: 0o644, modificationDate: nil,
                replacingExisting: false, base: nil, currentGeneration: 0, window: 4,
                source: source("nope"), progress: { _ in })
            XCTFail("expected permission denied")
        } catch let error as SFTPError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }

    // MARK: chmod +x

    func testTheExecutableChangeTouchesOnlyTheExecuteBits() {
        XCTAssertEqual(
            RemoteWriter.modeAfterExecutableChange(current: 0o644, userExecutable: true), 0o755)
        XCTAssertEqual(
            RemoteWriter.modeAfterExecutableChange(current: 0o600, userExecutable: true), 0o700)
        XCTAssertEqual(
            RemoteWriter.modeAfterExecutableChange(current: 0o755, userExecutable: false), 0o644)
        XCTAssertEqual(
            RemoteWriter.modeAfterExecutableChange(current: 0o640, userExecutable: true), 0o750)
    }

    // MARK: Symlinks through the writer

    func testCreatingALinkWithAnEscapingTargetNeverReachesTheServer() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let roots = SymlinkPolicy.Roots(canonical: "/srv/fake")
        do {
            _ = try await writer.makeSymlink(
                target: "../../etc/passwd", at: try path("Docs/escape"), roots: roots)
            XCTFail("expected the target to be refused")
        } catch let error as RemoteWriteError {
            XCTAssertEqual(error, .escapingSymlinkTarget)
        }
        await XCTAssertThrowsSFTP { try await transport.lstat(try self.path("Docs/escape")) }
    }

    func testCreatingALinkWithARelativeTargetInsideTheShareIsAccepted() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let roots = SymlinkPolicy.Roots(canonical: "/srv/fake")
        let stored = try await writer.makeSymlink(
            target: "note.txt", at: try path("Docs/link"), roots: roots)
        XCTAssertEqual(stored, "note.txt")
        let target = try await transport.readlink(try path("Docs/link"))
        XCTAssertEqual(target, "note.txt")
    }

    // MARK: The rename-semantics probe

    func testTheProbeFindsOpenSSHRefusesAndLeavesNothingInTheRoot() async throws {
        let transport = try await seededTree()
        let writer = makeWriter(transport)
        let refuses = await writer.probeRenameSemantics()
        XCTAssertTrue(refuses)
        let names = try await transport.readdir(.root).map {
            String(decoding: $0.name, as: UTF8.self)
        }
        XCTAssertFalse(names.contains { $0.hasPrefix(".sshdrive-upload-") })
    }

    func testAServerWhoseRenameOverwritesMakesEveryCreateLstatFirst() async throws {
        let transport = OverwritingRenameFake(root: "/srv/fake")
        try await transport.apply(.createDirectory(path: try path("Docs"), mode: 0o755))
        try await transport.apply(
            .createFile(path: try path("Docs/note.txt"), contents: Data("old".utf8), mode: 0o644))
        let writer = makeWriter(transport)
        let refuses = await writer.probeRenameSemantics()
        XCTAssertFalse(refuses)

        // Without the preflight this create would silently replace the file, because the
        // server's rename does not refuse (section 5.5).
        do {
            _ = try await writer.upload(
                to: try path("Docs/note.txt"), mode: 0o644, modificationDate: nil,
                replacingExisting: false, base: nil as RemoteWriter.BaseVersion?,
                currentGeneration: 0, window: 4,
                source: source("clobber"), progress: { _ in })
            XCTFail("expected a collision")
        } catch let error as RemoteWriteError {
            XCTAssertEqual(error, .filenameCollision("Docs/note.txt"))
        }
        let kept = try await transport.read(try path("Docs/note.txt"), offset: 0, length: nil as Int?)
        XCTAssertEqual(kept, Data("old".utf8))
    }
}

// MARK: - Doubles

/// A fake whose plain `rename` overwrites, which is the non-OpenSSH server section 5.5
/// warns about.
final actor OverwritingRenameFake: SFTPTransport {
    private let inner: FakeTransport
    init(root: String) { inner = FakeTransport(root: root) }

    func apply(_ mutation: FakeMutation) async throws { try await inner.apply(mutation) }

    var extensions: SFTPServerExtensions { get async { await inner.extensions } }
    func realpath(_ path: RelativePath) async throws -> String { try await inner.realpath(path) }
    func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        try await inner.lstat(path)
    }
    func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        try await inner.readdir(path)
    }
    func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        try await inner.read(path, offset: offset, length: length)
    }
    func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        try await inner.write(path, contents: contents, mode: mode)
    }
    func writeExclusive(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await inner.writeExclusive(
            path, mode: mode, window: window, source: source, progress: progress)
    }
    func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        try await inner.mkdir(path, mode: mode)
    }
    func remove(_ path: RelativePath) async throws { try await inner.remove(path) }
    func rmdir(_ path: RelativePath) async throws { try await inner.rmdir(path) }
    /// The whole point of this double.
    func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await inner.posixRename(source, to: destination)
    }
    func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await inner.posixRename(source, to: destination)
    }
    func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        try await inner.setstat(path, mode: mode, mtime: mtime)
    }
    func symlink(target: String, at path: RelativePath) async throws {
        try await inner.symlink(target: target, at: path)
    }
    func readlink(_ path: RelativePath) async throws -> String { try await inner.readlink(path) }
    func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        try await inner.statvfs(path)
    }
}

/// A fake that behaves like a case-insensitive server: a plain `rename` onto a name that
/// differs only by case fails, `realpath` folds case, and `posix-rename` works.
final actor CaseInsensitiveFake: SFTPTransport {
    private let inner: FakeTransport
    private let root: String
    init(root: String) {
        inner = FakeTransport(root: root)
        self.root = root
    }

    func apply(_ mutation: FakeMutation) async throws { try await inner.apply(mutation) }

    var extensions: SFTPServerExtensions { get async { await inner.extensions } }
    /// Case-folded, so the two spellings resolve to one file - which is exactly the
    /// question section 5.5 tells the agent to ask.
    func realpath(_ path: RelativePath) async throws -> String {
        path.absolute(root: root).lowercased()
    }
    func lstat(_ path: RelativePath) async throws -> SFTPFileAttributes {
        do { return try await inner.lstat(path) } catch {
            return try await inner.lstat(try folded(path))
        }
    }
    private func folded(_ path: RelativePath) throws -> RelativePath {
        // Only the last component is folded, which is all these tests need.
        guard let parent = path.parent, let last = path.lastComponent else { return path }
        let text = String(decoding: last, as: UTF8.self)
        let candidates = [text.lowercased(), text.capitalized, text.uppercased()]
        for candidate in candidates {
            if let attempt = try? parent.appending(component: candidate) { return attempt }
        }
        return path
    }
    func readdir(_ path: RelativePath) async throws -> [SFTPDirectoryEntry] {
        try await inner.readdir(path)
    }
    func read(_ path: RelativePath, offset: UInt64, length: Int?) async throws -> Data {
        try await inner.read(path, offset: offset, length: length)
    }
    func write(_ path: RelativePath, contents: Data, mode: UInt32) async throws {
        try await inner.write(path, contents: contents, mode: mode)
    }
    func writeExclusive(
        _ path: RelativePath, mode: UInt32, window: Int,
        source: @Sendable @escaping () throws -> Data,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await inner.writeExclusive(
            path, mode: mode, window: window, source: source, progress: progress)
    }
    func mkdir(_ path: RelativePath, mode: UInt32) async throws {
        try await inner.mkdir(path, mode: mode)
    }
    func remove(_ path: RelativePath) async throws { try await inner.remove(path) }
    func rmdir(_ path: RelativePath) async throws { try await inner.rmdir(path) }
    /// `link` + `unlink` on a case-insensitive filesystem: EEXIST, as a bare FAILURE.
    func rename(_ source: RelativePath, to destination: RelativePath) async throws {
        if (try? await lstat(destination)) != nil { throw SFTPError.failure("Failure") }
        try await inner.rename(source, to: destination)
    }
    func posixRename(_ source: RelativePath, to destination: RelativePath) async throws {
        try await inner.posixRename(source, to: destination)
    }
    func setstat(_ path: RelativePath, mode: UInt32?, mtime: Int64?) async throws {
        try await inner.setstat(path, mode: mode, mtime: mtime)
    }
    func symlink(target: String, at path: RelativePath) async throws {
        try await inner.symlink(target: target, at: path)
    }
    func readlink(_ path: RelativePath) async throws -> String { try await inner.readlink(path) }
    func statvfs(_ path: RelativePath) async throws -> SFTPFilesystemStats {
        try await inner.statvfs(path)
    }
}



func XCTAssertThrowsSFTP(
    _ body: @escaping () async throws -> Any, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await body()
        XCTFail("expected the call to throw", file: file, line: line)
    } catch {
        // Any refusal is enough here: the tests that care about *which* one say so.
    }
}
