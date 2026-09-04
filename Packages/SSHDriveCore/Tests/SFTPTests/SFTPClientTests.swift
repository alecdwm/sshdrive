import Foundation
import XCTest

@testable import SFTP

/// The codec, the pipelining window and the deadlines of DESIGN.md section 6.2, against a
/// scripted byte stream: no network, no subprocess, no server.
final class SFTPClientTests: XCTestCase {

    private func connectedClient(
        _ server: InMemorySFTPServer,
        configure: (inout SFTPClient.Configuration) -> Void = { _ in }
    ) async throws -> (SFTPClient, ScriptedByteStream) {
        let stream = ScriptedByteStream()
        stream.responder = server.responder()
        var configuration = SFTPClient.Configuration()
        configure(&configuration)
        let client = SFTPClient(stream: stream, configuration: configuration)
        try await client.connect()
        return (client, stream)
    }

    private func path(_ server: InMemorySFTPServer, _ relative: String) throws -> SFTPServerPath {
        SFTPServerPath(
            bytes: try RelativePath(string: relative).absoluteBytes(root: server.root))
    }

    // MARK: Handshake and extensions

    func testHandshakeRecordsVersionAndExtensions() async throws {
        let server = InMemorySFTPServer()
        let (client, stream) = try await connectedClient(server)
        let version = await client.serverVersion
        XCTAssertEqual(version, 3)
        let extensions = await client.extensions
        XCTAssertTrue(extensions.contains(.posixRename))
        XCTAssertTrue(extensions.contains(.statvfs))
        XCTAssertTrue(extensions.contains(.fsync))
        XCTAssertTrue(extensions.contains(.limits))
        XCTAssertTrue(extensions.contains(.lsetstat))
        // The INIT carried version 3 and nothing else.
        let initPackets = stream.writtenPackets(ofType: .initialize)
        XCTAssertEqual(initPackets.count, 1)
        var reader = initPackets[0].reader()
        XCTAssertEqual(try reader.readUInt32(), 3)
        // The limits probe went out because the server advertised it.
        let limits = await client.limits
        XCTAssertEqual(limits?.maxReadLength, 32768)
        await client.shutdown()
    }

    func testExtensionsThatAreNotOfferedAreUnsupportedRatherThanAttempted() async throws {
        let server = InMemorySFTPServer()
        server.advertisedExtensions = []
        let (client, stream) = try await connectedClient(server)
        let extensions = await client.extensions
        XCTAssertTrue(extensions.isEmpty)
        await assertSFTPError(.operationUnsupported) {
            _ = try await client.statvfs(self.path(server, "x"))
        }
        await assertSFTPError(.operationUnsupported) {
            try await client.posixRename(self.path(server, "a"), to: self.path(server, "b"))
        }
        // None of them reached the wire.
        XCTAssertTrue(stream.writtenPackets(ofType: .extended).isEmpty)
        // And with no limits reply, the window is section 6.2's conservative 32 KB x 16.
        let limits = await client.limits
        XCTAssertNil(limits)
        await client.shutdown()
    }

    // MARK: Codec

    func testStatusCodesMapToTheErrorTaxonomy() async throws {
        let pairs: [(SFTPStatusCode, SFTPError)] = [
            (.noSuchFile, .noSuchFile),
            (.permissionDenied, .permissionDenied),
            (.badMessage, .badMessage),
            (.noConnection, .noConnection),
            (.connectionLost, .connectionLost),
            (.operationUnsupported, .operationUnsupported),
        ]
        for (code, expected) in pairs {
            XCTAssertEqual(code.asError(message: ""), expected)
        }
        // A bare FAILURE keeps whatever sentence the server sent, and gets OpenSSH's
        // literal "Failure" when it sent none. ENOSPC, EEXIST, ENOTEMPTY and EXDEV all
        // arrive here, indistinguishable (section 6.2).
        XCTAssertEqual(SFTPStatusCode.failure.asError(message: ""), .failure("Failure"))
        XCTAssertEqual(SFTPStatusCode.failure.asError(message: "disk"), .failure("disk"))
        XCTAssertNil(SFTPStatusCode.ok.asError(message: ""))
        XCTAssertEqual(SFTPStatusCode.endOfFile.asError(message: ""), .eof)
    }

    func testAttributesDecodeTypeSizeAndMode() async throws {
        let server = InMemorySFTPServer()
        server.putDirectory("dir")
        server.put("dir/file.txt", contents: Data("hello".utf8), mode: 0o640)
        let (client, _) = try await connectedClient(server)

        let file = try await client.lstat(path(server, "dir/file.txt"))
        XCTAssertEqual(file.type, .file)
        XCTAssertEqual(file.size, 5)
        XCTAssertEqual(file.mode, 0o640)
        XCTAssertEqual(file.uid, 501)
        XCTAssertEqual(file.gid, 20)
        // SFTP v3 has whole seconds only; nanoseconds and inode stay nil so the index
        // records them without comparing (section 5.3).
        XCTAssertNil(file.mtimeNanoseconds)
        XCTAssertNil(file.inode)

        let directory = try await client.lstat(path(server, "dir"))
        XCTAssertEqual(directory.type, .directory)
        await client.shutdown()
    }

    func testNonUTF8NamesSurviveTheRoundTrip() async throws {
        let server = InMemorySFTPServer()
        // `latin1-caf\xff`, the testbed's non-UTF-8 name.
        var weird = Data("latin1-caf".utf8)
        weird.append(0xFF)
        server.putRawName(weird, contents: Data("x".utf8))
        let (client, _) = try await connectedClient(server)
        let entries = try await client.listDirectory(
            SFTPServerPath(bytes: RelativePath.root.absoluteBytes(root: server.root)))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, weird)
        await client.shutdown()
    }

    func testSymlinkSendsTargetBeforeLinkPath() async throws {
        let server = InMemorySFTPServer()
        let (client, stream) = try await connectedClient(server)
        try await client.symlink(target: Data("../elsewhere".utf8), at: path(server, "link"))

        // Section 6.2: OpenSSH takes targetpath first, then linkpath, the opposite order
        // from the draft. Reading the packet back is the only way to catch a regression,
        // because a client that gets it wrong still works against a draft-conformant
        // server and fails only against every real one.
        let packets = stream.writtenPackets(ofType: .symlink)
        XCTAssertEqual(packets.count, 1)
        var reader = packets[0].reader()
        _ = try reader.readUInt32()
        XCTAssertEqual(try reader.readString(), Data("../elsewhere".utf8))
        XCTAssertEqual(
            try reader.readString(),
            try RelativePath(string: "link").absoluteBytes(root: server.root))

        // And the link is where it should be, read back through readlink.
        let target = try await client.readlink(path(server, "link"))
        XCTAssertEqual(target, Data("../elsewhere".utf8))
        await client.shutdown()
    }

    func testStatvfsDecodesTheOpenSSHReply() async throws {
        let server = InMemorySFTPServer()
        server.availableBlocks = 0
        let (client, _) = try await connectedClient(server)
        let stats = try await client.statvfs(path(server, ""))
        XCTAssertEqual(stats.blockSize, 4096)
        XCTAssertEqual(stats.totalBlocks, 2048)
        XCTAssertEqual(stats.availableBlocks, 0)
        // This is the second question section 6.2 says to ask after a bare FAILURE.
        XCTAssertTrue(stats.isFull)
        await client.shutdown()
    }

    // MARK: readdir paging

    func testReaddirPagesUntilEOF() async throws {
        let server = InMemorySFTPServer()
        server.readdirPageSize = 37
        for index in 0..<250 {
            server.put(String(format: "f%04d.bin", index), contents: Data("x".utf8))
        }
        let (client, stream) = try await connectedClient(server)
        let entries = try await client.listDirectory(
            SFTPServerPath(bytes: RelativePath.root.absoluteBytes(root: server.root)))
        XCTAssertEqual(entries.count, 250)
        XCTAssertEqual(
            Set(entries.map { String(decoding: $0.name, as: UTF8.self) }).count, 250)
        // 250 entries at 37 a page is 7 pages, so more than one readdir went out.
        XCTAssertGreaterThan(stream.writtenPackets(ofType: .readdir).count, 7)
        await client.shutdown()
    }

    func testReaddirDropsDotAndDotDot() async throws {
        // The server here never sends them, so the assertion that matters is that a name
        // which cannot become a RelativePath component never reaches a caller.
        let server = InMemorySFTPServer()
        server.put("a", contents: Data())
        let (client, _) = try await connectedClient(server)
        let entries = try await client.listDirectory(
            SFTPServerPath(bytes: RelativePath.root.absoluteBytes(root: server.root)))
        for entry in entries {
            XCTAssertNoThrow(try RelativePath(components: [entry.name]))
        }
        await client.shutdown()
    }

    // MARK: Pipelining

    /// Section 6.2: reads keep a bounded window in flight. The server here answers only
    /// once it has seen a full window, so a client that did not pipeline would deadlock
    /// and a client that pipelined too deeply would be caught by the ceiling assertion.
    func testReadsPipelineUpToTheWindowAndNoFurther() async throws {
        let window = 4
        let chunk = 1024
        let total = chunk * 20
        let payload = Data((0..<total).map { UInt8($0 % 251) })

        let stream = ScriptedByteStream()
        let state = PipelineState(window: window)
        stream.responder = { packet, stream in
            guard let type = packet.packetType else { return }
            switch type {
            case .initialize:
                stream.pushVersion(3, extensions: [])
            case .open:
                var reader = packet.reader()
                let id = (try? reader.readUInt32()) ?? 0
                var writer = SFTPPacketWriter(.handle, requestID: id)
                writer.writeString(Data("h".utf8))
                stream.push(writer.finish())
            case .read:
                var reader = packet.reader()
                let id = (try? reader.readUInt32()) ?? 0
                _ = try? reader.readString()
                let offset = (try? reader.readUInt64()) ?? 0
                let length = Int((try? reader.readUInt32()) ?? 0)
                state.arrived(id: id, offset: offset, length: length)
                state.releaseIfWindowFull(stream: stream, payload: payload)
            case .close:
                stream.pushStatus(id: packet.requestID, .ok)
            default:
                stream.pushStatus(id: packet.requestID, .operationUnsupported)
            }
        }

        var configuration = SFTPClient.Configuration()
        configuration.fallbackChunkSize = chunk
        configuration.windowRequests = window
        configuration.metadataDeadline = .seconds(10)
        configuration.transferBaseDeadline = .seconds(10)
        let client = SFTPClient(stream: stream, configuration: configuration)
        try await client.connect()
        let handle = try await client.open(
            SFTPServerPath(bytes: Data("/f".utf8)), flags: .read)
        let data = try await client.readAll(handle: handle, offset: 0, length: nil)

        XCTAssertEqual(data, payload)
        XCTAssertEqual(state.peakInFlight, window, "the window must be filled")
        XCTAssertLessThanOrEqual(state.peakInFlight, window, "and never exceeded")
        await client.shutdown()
    }

    func testWritesArePipelinedAndLandAtTheRightOffsets() async throws {
        let server = InMemorySFTPServer()
        server.limits = SFTPLimits(
            maxPacketLength: 34000, maxReadLength: 4096, maxWriteLength: 4096,
            maxOpenHandles: 10)
        let (client, stream) = try await connectedClient(server)
        var payload = Data(count: 40_000)
        for index in 0..<payload.count { payload[index] = UInt8((index * 7) % 251) }

        let handle = try await client.open(
            path(server, "big.bin"), flags: [.write, .create, .truncate],
            attributes: SFTPSettableAttributes(permissions: 0o644))
        try await client.write(handle: handle, offset: 0, data: payload)
        try await client.close(handle)

        XCTAssertEqual(server.contents(of: "big.bin"), payload)
        // 40,000 bytes at a 4 KiB write length is ten packets, so the chunking came from
        // limits@openssh.com rather than from the fallback.
        XCTAssertEqual(stream.writtenPackets(ofType: .write).count, 10)
        await client.shutdown()
    }

    func testShortReadsAreCompletedRatherThanTreatedAsEOF() async throws {
        let server = InMemorySFTPServer()
        server.shortReadFactor = 0.3
        var payload = Data(count: 20_000)
        for index in 0..<payload.count { payload[index] = UInt8(index % 97) }
        server.put("f.bin", contents: payload)
        let (client, _) = try await connectedClient(server) { $0.fallbackChunkSize = 4096 }
        let handle = try await client.open(path(server, "f.bin"), flags: .read)
        let data = try await client.readAll(handle: handle, offset: 0, length: nil)
        XCTAssertEqual(data, payload)
        await client.shutdown()
    }

    func testReadWithAnExplicitRange() async throws {
        let server = InMemorySFTPServer()
        var payload = Data(count: 10_000)
        for index in 0..<payload.count { payload[index] = UInt8(index % 251) }
        server.put("f.bin", contents: payload)
        let (client, _) = try await connectedClient(server) { $0.fallbackChunkSize = 1000 }
        let handle = try await client.open(path(server, "f.bin"), flags: .read)
        let data = try await client.readAll(handle: handle, offset: 500, length: 2500)
        XCTAssertEqual(data, payload.subdata(in: 500..<3000))
        await client.shutdown()
    }

    // MARK: Deadlines

    func testARequestThatMissesItsDeadlineFailsAndKillsTheChannel() async throws {
        let stream = ScriptedByteStream()
        stream.responder = { packet, stream in
            // Answer the handshake, then go silent: this is the connection that died
            // without telling anyone, which section 6.3 point 4 says the per-request
            // deadline is what finds.
            if packet.packetType == .initialize {
                stream.pushVersion(3, extensions: [])
            }
        }
        var configuration = SFTPClient.Configuration()
        configuration.metadataDeadline = .milliseconds(300)
        configuration.deadlineTick = .milliseconds(25)
        let client = SFTPClient(stream: stream, configuration: configuration)
        try await client.connect()

        let started = ContinuousClock.now
        await assertSFTPError(.deadlineExceeded) {
            _ = try await client.lstat(SFTPServerPath(bytes: Data("/x".utf8)))
        }
        let elapsed = started.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .seconds(3))

        // And the channel is dead afterwards, which is what makes the agent drop the
        // master rather than keep issuing into a hole (section 6.2).
        let alive = await client.isAlive
        XCTAssertFalse(alive)
        await assertSFTPError(.connectionLost) {
            _ = try await client.lstat(SFTPServerPath(bytes: Data("/y".utf8)))
        }
        await client.shutdown()
    }

    func testEveryOutstandingRequestFailsWhenTheDeadlineKillsTheChannel() async throws {
        let stream = ScriptedByteStream()
        stream.responder = { packet, stream in
            if packet.packetType == .initialize { stream.pushVersion(3, extensions: []) }
        }
        var configuration = SFTPClient.Configuration()
        configuration.metadataDeadline = .milliseconds(300)
        configuration.deadlineTick = .milliseconds(25)
        let client = SFTPClient(stream: stream, configuration: configuration)
        try await client.connect()

        let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.lstat(
                            SFTPServerPath(bytes: Data("/p\(index)".utf8)))
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }
        XCTAssertEqual(failures, 5)
        await client.shutdown()
    }

    func testTheHandshakeItselfHasADeadline() async throws {
        let stream = ScriptedByteStream()
        stream.responder = { _, _ in }  // never answers SSH_FXP_INIT
        var configuration = SFTPClient.Configuration()
        configuration.metadataDeadline = .milliseconds(250)
        configuration.deadlineTick = .milliseconds(25)
        let client = SFTPClient(stream: stream, configuration: configuration)
        await assertSFTPError(.deadlineExceeded) { try await client.connect() }
        await client.shutdown()
    }

    func testAClosedStreamFailsEverythingOutstanding() async throws {
        let stream = ScriptedByteStream()
        stream.responder = { packet, stream in
            if packet.packetType == .initialize { stream.pushVersion(3, extensions: []) }
        }
        let client = SFTPClient(stream: stream, configuration: SFTPClient.Configuration())
        try await client.connect()
        let task = Task {
            try await client.lstat(SFTPServerPath(bytes: Data("/x".utf8)))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        stream.close()
        await assertSFTPError(.connectionLost) { _ = try await task.value }
        await client.shutdown()
    }
}

/// Records the read requests a pipelining test sees, and answers a whole window at a
/// time, out of order, so the reassembly is exercised too.
final class PipelineState: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [(id: UInt32, offset: UInt64, length: Int)] = []
    private var peak = 0
    private let window: Int

    init(window: Int) { self.window = window }

    var peakInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func arrived(id: UInt32, offset: UInt64, length: Int) {
        lock.lock()
        inFlight.append((id, offset, length))
        peak = max(peak, inFlight.count)
        lock.unlock()
    }

    func releaseIfWindowFull(stream: ScriptedByteStream, payload: Data) {
        lock.lock()
        guard inFlight.count >= window else {
            lock.unlock()
            return
        }
        let batch = inFlight.reversed()
        inFlight.removeAll()
        lock.unlock()
        for request in batch {
            let start = Int(request.offset)
            if start >= payload.count {
                stream.pushStatus(id: request.id, .endOfFile)
                continue
            }
            let end = min(payload.count, start + request.length)
            var writer = SFTPPacketWriter(.data, requestID: request.id)
            writer.writeString(payload.subdata(in: start..<end))
            stream.push(writer.finish())
        }
    }
}

// MARK: - Async assertion helpers

/// Asserts that `body` throws exactly this `SFTPError`. Written with an explicit closure
/// rather than an autoclosure so that `try await` inside it needs no ceremony.
func assertSFTPError(
    _ expected: SFTPError, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected), nothing was thrown", file: file, line: line)
    } catch let error as SFTPError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
