import Foundation
import XCTest

import AgentCore
import SFTP
import SSHProcess
@testable import ServerModel

/// The fake host's own fidelity: its `sha256sum`, and its sweep held against a real `find`
/// running the same `RemoteSweep.script` on a real tree.
///
/// The resilience suite trusts the fake host to answer the agent's scripts the way a
/// server would. The sweep is the one answer with real semantics in it - batches, depth,
/// prunes, the time window and two output formats - so it is checked here against the
/// thing it imitates, through the shipping script and the shipping reader.
final class FakeRemoteHostScenarios: XCTestCase {

    private var scratch: [URL] = []
    private var servers: [FakeSSHD] = []

    override func tearDown() async throws {
        for server in servers { server.shutdown() }
        servers = []
        for directory in scratch { try? FileManager.default.removeItem(at: directory) }
        scratch = []
    }

    // MARK: sha256sum

    /// FIPS 180-4's published vectors: the empty string, "abc", and the two-block message.
    func testTheDigestMatchesThePublishedVectors() {
        XCTAssertEqual(
            SHA256Digest.hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            SHA256Digest.hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256Digest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(
            SHA256Digest.hex(Data(repeating: UInt8(ascii: "a"), count: 1_000)),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    // MARK: The sweep against a real find

    /// A full sweep (no window) of shallow and recursive roots with an exclusion, in both
    /// output formats, finds exactly what GNU `find` finds running the same script.
    func testTheFakeSweepAgreesWithARealFind() async throws {
        if let reason = FakeSSHD.unavailabilityReason(for: .debian) {
            throw XCTSkip(reason)
        }
        let files = ["a.txt", "b/c.txt", "b/d/e.txt", "x/keep.txt", "x/skip/y.txt", "x/deep/z.txt"]
        let tree = try makeTree(files)
        let host = FakeRemoteHost(profile: .debian, root: "/srv/data", clock: SystemTimeSource())
        defer { host.tearDown() }
        for directory in ["b", "b/d", "x", "x/skip", "x/deep"] { host.makeDirectory(directory) }
        for file in files { host.writeFile(file, text: "") }

        // BSD `find` (macOS) has no `-printf`, so there the real side of that format has
        // nothing to compare against and only the `-print0` format is checked.
        for printf in Self.localFindTakesPrintf ? [false, true] : [false] {
            let plan = SweepPlan(
                shallowRoots: [".", "./b"], recursiveRoots: ["./x"], excluded: ["./x/skip"],
                flavour: .gnu, takesCmin: true, takesPrintf: printf, windowMinutes: nil)
            let real = try await realSweep(root: tree, plan: plan)
            let fake = try await fakeSweep(host, plan: plan)
            XCTAssertFalse(real.truncated)
            XCTAssertFalse(fake.truncated)
            XCTAssertNotNil(fake.serverTime)
            let found = Set(fake.hits.map { String(decoding: $0.path, as: UTF8.self) })
            XCTAssertEqual(
                found,
                [".", "./a.txt", "./b", "./b/c.txt", "./b/d", "./x", "./x/keep.txt",
                 "./x/deep", "./x/deep/z.txt"],
                "shallow roots one level deep, the recursive root whole, the exclusion pruned")
            XCTAssertEqual(
                Set(fake.hits.map { "\(String(decoding: $0.path, as: UTF8.self)) \($0.type ?? "-")" }),
                Set(real.hits.map { "\(String(decoding: $0.path, as: UTF8.self)) \($0.type ?? "-")" }),
                "printf \(printf)")
        }
    }

    /// The window is applied to the change time on the server's clock: a file changed
    /// inside it is reported, one changed before it is not, and the directory whose
    /// listing gained a name is reported with it.
    func testTheFakeSweepAppliesTheWindowToTheChangeTime() async throws {
        let time = OffsetTime()
        let host = FakeRemoteHost(profile: .debian, root: "/srv/data", clock: time)
        defer { host.tearDown() }
        host.makeDirectory("old-dir")
        host.writeFile("old-dir/old.txt", text: "old")
        time.offset += 600
        host.writeFile("new.txt", text: "new")
        host.changeMode("old-dir/old.txt", to: 0o600)

        let plan = SweepPlan(
            shallowRoots: ["."], recursiveRoots: ["./old-dir"], flavour: .gnu, takesCmin: true,
            takesPrintf: true, windowMinutes: 5)
        let outcome = try await fakeSweep(host, plan: plan)
        let paths = Set(outcome.hits.map { String(decoding: $0.path, as: UTF8.self) })
        XCTAssertEqual(paths, [".", "./new.txt", "./old-dir/old.txt"])
        XCTAssertEqual(outcome.serverTime, Int64(host.serverNow))

        let mmin = SweepPlan(
            shallowRoots: ["."], recursiveRoots: ["./old-dir"], flavour: .busybox,
            takesCmin: false, takesPrintf: false, windowMinutes: 5)
        let busybox = try await fakeSweep(host, plan: mmin)
        XCTAssertEqual(
            Set(busybox.hits.map { String(decoding: $0.path, as: UTF8.self) }),
            [".", "./new.txt"], "-mmin misses the chmod, as SQ-005 says it does")
    }

    // MARK: Helpers

    private func makeTree(_ files: [String]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-fakehost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratch.append(directory)
        for name in files {
            let path = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path.path, contents: Data())
        }
        return directory
    }

    /// Whether the `find` a local `sh` resolves accepts `-printf`: GNU's does, BSD's
    /// answers `unknown primary or operator` and exits 1.
    private static let localFindTakesPrintf: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "find / -maxdepth 0 -printf ''"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private func realSweep(root: URL, plan: SweepPlan) async throws -> RemoteSweep.Outcome {
        let server = try FakeSSHD(profile: .debian)
        servers.append(server)
        let sentinel = Sentinel()
        let script = RemoteSweep.script(canonicalRoot: root.path, plan: plan, sentinel: sentinel)
        let channel = try await server.openExecChannel(script: script, readinessDeadline: 30)
        defer { channel.close() }
        let outcome = await RemoteSweep.collect(
            stream: channel.stream, sentinel: sentinel, usesPrintf: plan.usesPrintf,
            deadline: Date().addingTimeInterval(30))
        channel.endInput()
        return outcome
    }

    private func fakeSweep(_ host: FakeRemoteHost, plan: SweepPlan) async throws
        -> RemoteSweep.Outcome
    {
        guard case .connected(let master) = host.connect() else {
            XCTFail("the fake host refused a connection")
            throw CancellationError()
        }
        defer { master.shutdown() }
        let sentinel = Sentinel()
        let script = RemoteSweep.script(canonicalRoot: host.root, plan: plan, sentinel: sentinel)
        let channel = try await master.openExecChannel(script: script, readinessDeadline: 30)
        defer { channel.close() }
        return await RemoteSweep.collect(
            stream: channel.stream, sentinel: sentinel, usesPrintf: plan.usesPrintf,
            deadline: host.clock.deadline(after: 30), clock: host.clock)
    }
}

/// The system clock, moved by hand: what a server's clock does between two sweeps.
private final class OffsetTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _offset: Double = 0
    var offset: Double {
        get { lock.withLock { _offset } }
        set { lock.withLock { _offset = newValue } }
    }
    func now() -> Double { Date().timeIntervalSince1970 + offset }
    func sleep(seconds: Double) async { await SystemTimeSource().sleep(seconds: seconds) }
}
