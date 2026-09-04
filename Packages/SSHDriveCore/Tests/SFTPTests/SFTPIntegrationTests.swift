import Foundation
import XCTest

@testable import SFTP

/// The real client against the real thing: `/usr/bin/ssh -s <alias> sftp` to the spike
/// testbed's `deb` (2201, Debian, OpenSSH 9.2) and `alp` (2206, Alpine, busybox/musl,
/// OpenSSH 9.7). See `testbed/README.md` for the aliases and the accounts.
///
/// Gated on `SSHDRIVE_TESTBED=1` because the testbed answers only the build VM
/// (192.168.64.1 is the Mac's vmnet gateway) and nothing else can reach it.
///
/// Nothing here waits for EOF without a deadline: every request the client makes carries
/// one (section 6.2), which is what the README's `bashbg` trap is about.
final class SFTPIntegrationTests: XCTestCase {

    private static let debian = "spike-deb"
    private static let alpine = "spike-alp"

    private var opened: [SFTPSubprocess] = []

    override func tearDown() async throws {
        for process in opened { await process.terminate() }
        opened = []
    }

    private func requireTestbed() throws {
        guard ProcessInfo.processInfo.environment["SSHDRIVE_TESTBED"] == "1" else {
            throw XCTSkip("set SSHDRIVE_TESTBED=1 on the build VM to run these")
        }
    }

    /// Connects and roots the transport at the account's home directory, which is what
    /// `realpath` of a bare "." resolves to.
    private func connect(_ alias: String) async throws -> (RealSFTPTransport, SFTPSubprocess) {
        let process = try SFTPSubprocess.sshSubsystem(
            destination: alias, options: ["-o", "BatchMode=yes"])
        opened.append(process)
        do {
            var configuration = SFTPClient.Configuration()
            configuration.metadataDeadline = .seconds(30)
            configuration.transferBaseDeadline = .seconds(30)
            let transport = try await RealSFTPTransport.connect(
                stream: process.stream, root: ".", configuration: configuration)
            return (transport, process)
        } catch {
            XCTFail("could not open the SFTP subsystem on \(alias): \(error); ssh said: \(process.diagnostics)")
            throw error
        }
    }

    /// A scratch directory of our own under the account's home, removed afterwards.
    private func makeScratch(_ transport: RealSFTPTransport) async throws -> RelativePath {
        let name = "sshdrive-itest-\(UUID().uuidString.prefix(8).lowercased())"
        let path = try RelativePath(string: name)
        try await transport.mkdir(path, mode: 0o755)
        return path
    }

    private func removeScratch(_ transport: RealSFTPTransport, _ path: RelativePath) async {
        let entries = (try? await transport.readdir(path)) ?? []
        for entry in entries {
            guard let child = try? path.appending(component: entry.name) else { continue }
            if entry.attributes.type == .directory {
                await removeScratch(transport, child)
            } else {
                try? await transport.remove(child)
            }
        }
        try? await transport.rmdir(path)
    }

    // MARK: The extensions probe

    func testExtensionsProbeOnBothServers() async throws {
        try requireTestbed()
        for alias in [Self.debian, Self.alpine] {
            let (transport, _) = try await connect(alias)
            let client = transport.client
            let names = await client.serverExtensionNames
            let limits = await client.limits
            let version = await client.serverVersion
            print("[\(alias)] SFTP v\(version) extensions: \(names.joined(separator: " "))")
            print("[\(alias)] limits: \(String(describing: limits))")

            let extensions = await transport.extensions
            // Section 6.2 names these five. They are what OpenSSH's own sftp-server
            // offers, on Debian's 9.2 and Alpine's 9.7 alike.
            XCTAssertTrue(extensions.contains(.posixRename), "\(alias) posix-rename")
            XCTAssertTrue(extensions.contains(.statvfs), "\(alias) statvfs")
            XCTAssertTrue(extensions.contains(.fsync), "\(alias) fsync")
            XCTAssertTrue(extensions.contains(.limits), "\(alias) limits")
            XCTAssertTrue(extensions.contains(.lsetstat), "\(alias) lsetstat")
            XCTAssertNotNil(limits, "\(alias) answered limits@openssh.com")
            await transport.shutdown()
        }
    }

    // MARK: The core operations

    func testListReadWriteRenameDeleteStatOnDebian() async throws {
        try requireTestbed()
        try await exerciseCoreOperations(Self.debian)
    }

    func testListReadWriteRenameDeleteStatOnAlpine() async throws {
        try requireTestbed()
        try await exerciseCoreOperations(Self.alpine)
    }

    private func exerciseCoreOperations(_ alias: String) async throws {
        let (transport, _) = try await connect(alias)
        let scratch = try await makeScratch(transport)

        // list: the seeded tree is there
        let home = try await transport.readdir(.root)
        let homeNames = Set(home.map { String(decoding: $0.name, as: UTF8.self) })
        XCTAssertTrue(homeNames.contains("data"), "\(alias) home: \(homeNames)")

        // write, then read back
        let payload = Data((0..<40_000).map { UInt8($0 % 251) })
        let file = try scratch.appending(component: "written.bin")
        try await transport.write(file, contents: payload, mode: 0o640)
        let read = try await transport.read(file, offset: 0, length: nil)
        XCTAssertEqual(read.count, payload.count, "\(alias) size")
        XCTAssertEqual(read, payload, "\(alias) contents")

        // a ranged read
        let ranged = try await transport.read(file, offset: 100, length: 50)
        XCTAssertEqual(ranged, payload.subdata(in: 100..<150), "\(alias) ranged read")

        // stat: the mode survived, and the temp file is gone
        let attributes = try await transport.lstat(file)
        XCTAssertEqual(attributes.type, .file)
        XCTAssertEqual(attributes.size, Int64(payload.count))
        XCTAssertEqual(attributes.mode, 0o640, "\(alias) mode restored after the rename")
        let listed = try await transport.readdir(scratch)
        XCTAssertEqual(listed.count, 1, "\(alias) no upload temp file left behind")

        // rename, non-overwriting
        let renamed = try scratch.appending(component: "renamed.bin")
        try await transport.rename(file, to: renamed)
        await assertSFTPError(.noSuchFile) { _ = try await transport.lstat(file) }
        // A plain rename onto an existing name must fail; that is what section 5.5's
        // create path relies on.
        try await transport.write(file, contents: Data("x".utf8), mode: 0o644)
        do {
            try await transport.rename(renamed, to: file)
            XCTFail("\(alias): a plain rename must not overwrite")
        } catch let error as SFTPError {
            // OpenSSH reports EEXIST as a bare FAILURE (section 6.2), so this is all the
            // wire can say. Asking a second question is what the agent does next.
            XCTAssertEqual(error, .failure("Failure"), "\(alias) rename onto existing")
        }
        // posix-rename does overwrite.
        try await transport.posixRename(renamed, to: file)
        let after = try await transport.read(file, offset: 0, length: nil)
        XCTAssertEqual(after.count, payload.count, "\(alias) posix-rename replaced")

        // setstat
        try await transport.setstat(file, mode: 0o600, mtime: 1_600_000_000)
        let restatted = try await transport.lstat(file)
        XCTAssertEqual(restatted.mode, 0o600)
        XCTAssertEqual(restatted.mtime, 1_600_000_000)

        // symlink and readlink, and lstat not following it
        let link = try scratch.appending(component: "link")
        try await transport.symlink(target: "written.bin", at: link)
        let linkStat = try await transport.lstat(link)
        XCTAssertEqual(linkStat.type, .symlink, "\(alias) lstat does not follow a link")
        XCTAssertEqual(linkStat.symlinkTarget, "written.bin")

        // mkdir / rmdir, and the not-empty case
        let sub = try scratch.appending(component: "sub")
        try await transport.mkdir(sub, mode: 0o755)
        try await transport.write(
            try sub.appending(component: "inside"), contents: Data("i".utf8), mode: 0o644)
        do {
            try await transport.rmdir(sub)
            XCTFail("\(alias): rmdir of a non-empty directory must fail")
        } catch let error as SFTPError {
            // ENOTEMPTY is a bare FAILURE too; the readdir above is the second question.
            XCTAssertEqual(error, .failure("Failure"))
        }

        // statvfs, and realpath of the root
        let stats = try await transport.statvfs(.root)
        XCTAssertGreaterThan(stats.totalBlocks, 0)
        try await transport.verifyRoot()

        // delete
        try await transport.remove(link)
        try await transport.remove(file)
        await assertSFTPError(.noSuchFile) { _ = try await transport.lstat(file) }

        await removeScratch(transport, scratch)
        await transport.shutdown()
    }

    // MARK: readdir paging and byte-exact names

    func testReaddirPagesTenThousandFiles() async throws {
        try requireTestbed()
        let (transport, _) = try await connect(Self.debian)
        let started = Date()
        let entries = try await transport.readdir(RelativePath(string: "data/many"))
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "[deb] readdir data/many: %d entries in %.2f s", entries.count, elapsed))
        XCTAssertEqual(entries.count, 10_000)
        XCTAssertEqual(Set(entries.map { $0.name }).count, 10_000)
        XCTAssertTrue(entries.allSatisfy { $0.attributes.type == .file })
        await transport.shutdown()
    }

    func testWeirdNamesComeBackAsBytes() async throws {
        try requireTestbed()
        let (transport, _) = try await connect(Self.debian)
        let entries = try await transport.readdir(RelativePath(string: "data/weird"))
        XCTAssertGreaterThanOrEqual(entries.count, 9)
        // Every name the server reports must survive the section 9.1 constructor, and a
        // name that is not valid UTF-8 must not have been mangled on the way (section
        // 5.4). `latin1-caf\xff` is the one the testbed seeds for this.
        var sawNonUTF8 = false
        var sawNewline = false
        for entry in entries {
            XCTAssertNoThrow(try RelativePath(components: [entry.name]))
            if String(data: entry.name, encoding: .utf8) == nil { sawNonUTF8 = true }
            if entry.name.contains(0x0A) { sawNewline = true }
            // And each one can be descended into byte for byte.
            let inside = try RelativePath(string: "data/weird")
                .appending(component: entry.name)
                .appending(component: "inside.txt")
            let attributes = try await transport.lstat(inside)
            XCTAssertEqual(attributes.type, .file, "\(entry.name as NSData)")
        }
        XCTAssertTrue(sawNonUTF8, "the non-UTF-8 name must survive as bytes")
        XCTAssertTrue(sawNewline, "the name containing a newline must survive")
        await transport.shutdown()
    }

    // MARK: Throughput (spike S2)

    /// A large sequential read through the pipeline. Uses the opt-in `data/big/1g.bin`
    /// when it is there and a file of our own when it is not; the numbers go into the
    /// test log rather than into an assertion, because a container on the same Mac is a
    /// floor, not a measurement of a NAS (testbed/README.md).
    func testLargeSequentialRead() async throws {
        try requireTestbed()
        let (transport, _) = try await connect(Self.debian)

        var target = try RelativePath(string: "data/big/1g.bin")
        var scratch: RelativePath?
        var size: Int64
        if let attributes = try? await transport.lstat(target), attributes.type == .file {
            size = attributes.size
        } else {
            let directory = try await makeScratch(transport)
            scratch = directory
            target = try directory.appending(component: "sequential.bin")
            let block = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
            var payload = Data()
            for _ in 0..<64 { payload.append(block) }
            let uploadStarted = Date()
            try await transport.write(target, contents: payload, mode: 0o644)
            let uploadElapsed = Date().timeIntervalSince(uploadStarted)
            size = Int64(payload.count)
            print(
                String(
                    format: "[deb] pipelined write %.0f MiB in %.2f s = %.1f MiB/s",
                    Double(size) / 1_048_576, uploadElapsed,
                    Double(size) / 1_048_576 / max(uploadElapsed, 0.001)))
        }

        let counter = ByteCounter()
        let started = Date()
        let read = try await transport.readStreaming(target, offset: 0, length: nil) {
            _, data in
            counter.add(data.count)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(Int64(read), size)
        XCTAssertEqual(counter.total, Int(size))
        let megabytes = Double(size) / 1_048_576
        print(
            String(
                format: "[deb] pipelined read %.0f MiB in %.2f s = %.1f MiB/s",
                megabytes, elapsed, megabytes / max(elapsed, 0.001)))

        // The same file through `sftp(1)`, over the same link, for spike S2's comparison.
        // The 1 GB half of S2 needs the opt-in `data/big/1g.bin`; this is the part that
        // runs on a default testbed. Recorded, never asserted (testbed/README.md: a
        // container on the same Mac is a floor, not a NAS).
        let remote = String(decoding: target.bytes, as: UTF8.self)
        if let theirs = Self.timeSftpGet(remote) {
            print(
                String(
                    format: "[S2] %.0f MiB: sshdrive %.2f s (%.1f MiB/s); sftp(1) %.2f s (%.1f MiB/s)",
                    megabytes, elapsed, megabytes / max(elapsed, 0.001),
                    theirs, megabytes / max(theirs, 0.001)))
        }

        if let scratch { await removeScratch(transport, scratch) }
        await transport.shutdown()
    }

    /// Spike S2's throughput comparison against `sftp(1)`, on the opt-in 1 GB file only.
    /// Recorded, never asserted.
    func testThroughputAgainstSftpOneGigabyteFile() async throws {
        try requireTestbed()
        let (transport, _) = try await connect(Self.debian)
        let target = try RelativePath(string: "data/big/1g.bin")
        guard let attributes = try? await transport.lstat(target), attributes.type == .file
        else {
            await transport.shutdown()
            throw XCTSkip(
                "data/big/1g.bin is not seeded; set BIG_FILE=1 on the deb service to run this")
        }
        let megabytes = Double(attributes.size) / 1_048_576

        let counter = ByteCounter()
        let started = Date()
        _ = try await transport.readStreaming(target, offset: 0, length: nil) { _, data in
            counter.add(data.count)
        }
        let ours = Date().timeIntervalSince(started)
        await transport.shutdown()

        let theirs = Self.timeSftpGet("data/big/1g.bin")
        let theirsDescription =
            theirs.map { String(format: "%.1f s (%.1f MiB/s)", $0, megabytes / max($0, 0.001)) }
            ?? "did not run"
        let ourDescription = String(
            format: "%.1f s (%.1f MiB/s)", ours, megabytes / max(ours, 0.001))
        print("[S2] 1 GB read: sshdrive \(ourDescription); sftp(1) \(theirsDescription)")
    }

    /// `sftp -b - spike-deb` fetching the same file to /dev/null, timed.
    private static func timeSftpGet(_ remotePath: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = ["-q", "-b", "-", "-o", "BatchMode=yes", debian]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        do {
            try process.run()
        } catch {
            return nil
        }
        input.fileHandleForWriting.write(Data("get \(remotePath) /dev/null\n".utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Date().timeIntervalSince(started)
    }
}

/// Counts bytes handed to a streaming read from whichever task delivers them.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add(_ bytes: Int) {
        lock.lock()
        count += bytes
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
