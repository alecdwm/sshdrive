import XCTest
@testable import AgentCore
import SFTP
@testable import SSHProcess

/// Spike S7's tier 1 half, against the real testbed (DESIGN.md section 6.4): the `find`
/// sweep over an exec channel, its two `find` flavours, the server-clock window, and the
/// claim that it coexists with SFTP traffic on one connection. Gated on
/// `SSHDRIVE_TESTBED=1`.
final class TestbedSweepTests: XCTestCase {

    private var masters: [SSHMaster] = []

    override func tearDown() async throws {
        for master in masters { await master.shutdown() }
        masters = []
        Testbed.reapHopChildren()
    }

    private func master(host: String, user: String? = nil) async throws -> SSHMaster {
        let master = try Testbed.master(host: host, user: user)
        masters.append(master)
        try await master.connect()
        return master
    }

    /// The account's home, which every `RelativePath` in these tests is relative to.
    private func home(on master: SSHMaster) async throws -> String {
        let (payload, _) = try await Testbed.runScript(
            on: master, body: "printf '%s\\000' \"$HOME\"", timeout: 20)
        return String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    private func gnuPlan(roots: [String], windowMinutes: Int?) -> SweepPlan {
        SweepPlan(
            shallowRoots: [], recursiveRoots: roots, excluded: [],
            flavour: .gnu, takesCmin: true, takesPrintf: true, windowMinutes: windowMinutes)
    }

    // MARK: The sweep itself

    /// One sweep, end to end: the server's own clock first, then a `-printf` record per
    /// hit carrying everything section 5.3 wants and needing no follow-up `stat`.
    func testGnuSweepCarriesTheServerClockAndFullRecords() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let root = try await home(on: master)

        let before = Int64(Date().timeIntervalSince1970)
        let outcome = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: gnuPlan(roots: ["./data/tree/d0000"], windowMinutes: nil), timeout: 120)
        let after = Int64(Date().timeIntervalSince1970)

        XCTAssertFalse(outcome.truncated, "the closing sentinel must end the read")
        // The window comes from the server's clock, never the Mac's (section 6.4). The
        // testbed's containers share the host's clock, so what this proves is that the
        // value the agent stores is the one the *script* printed.
        let serverTime = try XCTUnwrap(outcome.serverTime)
        XCTAssertGreaterThanOrEqual(serverTime, before - 5)
        XCTAssertLessThanOrEqual(serverTime, after + 5)

        // 20 files plus the directory itself.
        XCTAssertEqual(outcome.hits.count, 21, "d0000 holds f000..f019 and itself")
        let file = try XCTUnwrap(
            outcome.hits.first { $0.path == Data("./data/tree/d0000/f000.bin".utf8) })
        XCTAssertEqual(file.type, "f")
        XCTAssertEqual(file.size, 2048, "the seeded files are 2 KiB")
        XCTAssertNotNil(file.inode)
        XCTAssertNotNil(file.mtimeNanoseconds)
        XCTAssertEqual(file.mode, 0o644)
        XCTAssertNotNil(file.uid)
        let directory = try XCTUnwrap(outcome.hits.first { $0.type == "d" })
        XCTAssertEqual(directory.path, Data("./data/tree/d0000".utf8))
    }

    /// The window really bounds the answer, and it is minutes on the *server's* clock.
    func testTheWindowBoundsWhatTheSweepReports() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let root = try await home(on: master)

        // Nothing under the seeded tree has changed in the last minute.
        let narrow = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: gnuPlan(roots: ["./data/tree/d0001"], windowMinutes: 1), timeout: 120)
        XCTAssertEqual(narrow.hits.count, 0, "a one-minute window over an old tree finds nothing")

        // Touch one file and it is the only hit.
        _ = try await Testbed.runScript(
            on: master, body: "touch \"$HOME/data/tree/d0001/f000.bin\"; printf 'ok\\000'",
            timeout: 20)
        let after = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: gnuPlan(roots: ["./data/tree/d0001"], windowMinutes: 1), timeout: 120)
        // The file and its parent directory: a `touch` moves the file's ctime, and the
        // directory's own ctime is untouched, so exactly one hit.
        XCTAssertEqual(after.hits.count, 1)
        XCTAssertEqual(after.hits.first?.path, Data("./data/tree/d0001/f000.bin".utf8))
    }

    /// Section 6.4's reason for `-cmin` over `-mmin`, measured rather than asserted: a
    /// `chmod` on a file whose mtime is old moves ctime and not mtime, so `-cmin` finds it
    /// and `-mmin` does not. Every busybox server loses exactly this.
    func testCminCatchesAChmodThatMminMisses() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let root = try await home(on: master)
        let body = """
            __d="$HOME/data/s7-cmin"
            rm -rf "$__d"; mkdir -p "$__d"; : > "$__d/probe.txt"
            touch -t 202001010000 "$__d/probe.txt"
            chmod 700 "$__d/probe.txt"
            printf 'ready\\000'
            """
        _ = try await Testbed.runScript(on: master, body: body, timeout: 30)

        let cmin = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: SweepPlan(
                shallowRoots: [], recursiveRoots: ["./data/s7-cmin"], excluded: [],
                flavour: .gnu, takesCmin: true, takesPrintf: true, windowMinutes: 2),
            timeout: 60)
        let mmin = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: SweepPlan(
                shallowRoots: [], recursiveRoots: ["./data/s7-cmin"], excluded: [],
                // Not a busybox server, but the busybox *shape*: no -cmin, no -printf.
                flavour: .busybox, takesCmin: false, takesPrintf: false, windowMinutes: 2),
            timeout: 60)

        XCTAssertTrue(
            cmin.hits.contains { $0.path == Data("./data/s7-cmin/probe.txt".utf8) },
            "-cmin must see the chmod")
        XCTAssertFalse(
            mmin.hits.contains { $0.path == Data("./data/s7-cmin/probe.txt".utf8) },
            "-mmin must miss it: that is the cost section 6.4 records for every busybox")
        _ = try await Testbed.runScript(
            on: master, body: "rm -rf \"$HOME/data/s7-cmin\"; printf 'x\\000'", timeout: 20)
    }

    /// busybox `find` has no `-cmin` and no `-printf` at all (BusyBox 1.36.1, measured
    /// 2026-09-04), so a plan built for it must run and parse with bare paths.
    func testBusyboxSweepRunsWithMminAndBarePaths() async throws {
        try Testbed.skipUnlessEnabled()
        for host in ["spike-alp", "spike-alp-nocmin"] {
            let master = try await master(host: host)
            let root = try await home(on: master)
            let plan = SweepPlan(
                shallowRoots: [], recursiveRoots: ["./data"], excluded: [],
                flavour: .busybox, takesCmin: true, takesPrintf: true, windowMinutes: nil)
            // Even asked for them, a busybox plan must refuse both: the flavour is the
            // guard against a probe that got it wrong, and a busybox `-cmin` fails the
            // whole sweep rather than losing a field.
            XCTAssertFalse(plan.usesCmin, "\(host): busybox has no -cmin")
            XCTAssertFalse(plan.usesPrintf, "\(host): busybox has no -printf")

            let outcome = try await RemoteSweep.run(
                master: master, canonicalRoot: root, plan: plan, timeout: 120)
            XCTAssertFalse(outcome.truncated, "\(host): the sweep must finish")
            XCTAssertNotNil(outcome.serverTime, "\(host): `date +%s` first, always")
            XCTAssertGreaterThan(outcome.hits.count, 100, "\(host): the data tree")
            XCTAssertTrue(
                outcome.hits.allSatisfy { $0.type == nil && $0.size == nil },
                "\(host): a -print0 sweep carries paths and nothing else")
        }
    }

    /// Section 9.2's quoting rule, at the scale the sweep uses it: the testbed's `weird/`
    /// tree exists for this. A directory named `$(echo pwned)` must be a path.
    func testAwkwardRootsAndAwkwardOutputSurviveTheSweep() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let root = try await home(on: master)
        let roots = [
            "./data/weird/$(echo pwned)", "./data/weird/quote'name",
            "./data/weird/space in name", "./data/weird/*star*",
            "./data/weird/[bracket]", "./data/weird/back\\slash",
        ]
        let outcome = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: gnuPlan(roots: roots, windowMinutes: nil), timeout: 120)

        XCTAssertFalse(outcome.truncated)
        // Each of those directories holds `inside.txt`, so every root must come back with
        // its own hit rather than being expanded, globbed or executed.
        for name in roots {
            let wanted = Data((name + "/inside.txt").utf8)
            XCTAssertTrue(
                outcome.hits.contains { $0.path == wanted },
                "\(name)/inside.txt is missing; the root did not reach find as a path")
        }
        // And nothing ran: the substitution would have made a file of its own.
        let (payload, _) = try await Testbed.runScript(
            on: master, body: "ls \"$HOME\" | grep -c pwned || true; printf '\\000'", timeout: 20)
        XCTAssertEqual(
            String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "0")
    }

    /// The sweep runs on an exec channel while both SFTP channels are busy, which is the
    /// first question S7 asks. One connection, three channels, all at once.
    func testSweepCoexistsWithTwoSFTPChannelsOnOneConnection() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let root = try await home(on: master)

        let metadataChannel = try await master.openSFTPChannel()
        defer { metadataChannel.close() }
        let bulkChannel = try await master.openSFTPChannel()
        defer { bulkChannel.close() }
        let metadata = try await RealSFTPTransport.connect(
            stream: metadataChannel.stream, root: root, uploadTag: "s7000000")
        let bulk = try await RealSFTPTransport.connect(
            stream: bulkChannel.stream, root: root, uploadTag: "s7000000")

        // Real traffic on both SFTP channels for the length of the sweep, so the exec
        // channel is not merely opened beside two idle ones.
        let listings = Counter()
        let traffic = Task {
            while !Task.isCancelled {
                _ = try await metadata.readdir(try RelativePath(string: "data/tree/d0004"))
                _ = try await bulk.readdir(try RelativePath(string: "data/tree/d0003"))
                await listings.bump()
            }
        }
        // Wait for the first round, so "rounds during the sweep" is measured against a
        // loop that is already running rather than one that has not started.
        var settle = 0
        while await listings.value == 0, settle < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            settle += 1
        }
        let before = await listings.value
        let outcome = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            // The whole data tree, unbounded: 15,000 files, so the sweep is long enough
            // for the SFTP channels to be visibly serving through it rather than merely
            // open.
            plan: gnuPlan(roots: ["./data"], windowMinutes: nil), timeout: 180)
        let after = await listings.value
        traffic.cancel()

        XCTAssertFalse(outcome.truncated, "the sweep must finish beside two SFTP channels")
        XCTAssertGreaterThan(outcome.hits.count, 15_000, "the seeded data tree is 15,011 files")
        XCTAssertGreaterThan(
            after, before, "both SFTP channels must have served a listing during the sweep")
        XCTAssertNil(metadataChannel.exitStatus(), "the metadata channel must still be open")
        XCTAssertNil(bulkChannel.exitStatus(), "the bulk channel must still be open")
        let running = await master.isRunning
        XCTAssertTrue(running)
        // And both channels still work afterwards.
        _ = try await metadata.lstat(.root)
        _ = try await bulk.lstat(.root)
    }

    /// A counter the traffic task and the test body share.
    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    /// `bashbg` leaves a background child holding stdout, so EOF never arrives. The sweep
    /// reads to its own closing sentinel and must return in seconds, not at the timeout
    /// (section 9.2, and the trap testbed/README.md records).
    func testSweepReturnsOnABashbgAccountWhereEOFNeverArrives() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-shells", user: "bashbg")
        let root = try await home(on: master)
        let started = Date()
        let outcome = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: gnuPlan(roots: ["."], windowMinutes: 1), timeout: 60)
        XCTAssertFalse(outcome.truncated, "the closing sentinel, not EOF, ends the read")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 45, "it must not wait out the timeout")
    }

    /// A root that does not exist makes `find` exit non-zero. Section 6.4's `|| true` is
    /// what stops one such root losing every other root's changes.
    func testOneUnreadableRootDoesNotLoseTheRestOfTheSweep() async throws {
        try Testbed.skipUnlessEnabled()
        let master = try await master(host: "spike-deb")
        let root = try await home(on: master)
        let outcome = try await RemoteSweep.run(
            master: master, canonicalRoot: root,
            plan: gnuPlan(
                roots: ["./data/tree/d0002", "./data/there-is-no-such-directory"],
                windowMinutes: nil),
            timeout: 120)
        XCTAssertFalse(outcome.truncated)
        XCTAssertEqual(outcome.hits.count, 21, "d0002's twenty files and itself still arrive")
    }
}
