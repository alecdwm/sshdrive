import Foundation
import XCTest

import AgentCore
import SFTP
import SSHProcess
@testable import ServerModel

/// Suite H's server half: the `find` flavour probe and the sweep it selects
/// (`docs/design/testing.md`).
///
/// This box has GNU findutils and no busybox, so a busybox server's `find` is a generated
/// shim that behaves the way BusyBox 1.36.1 was **measured** to - `-cmin` and `-printf`
/// rejected with rc 1, `--version` printing an error and exiting **0**. The shell that
/// runs the script is a real one either way; the busybox *ash* rows, which need the
/// busybox binary itself, skip by name.
///
/// A profile with a `clockOffset` gets a `date` shim beside it (`SQ-054`), which is the
/// only way a clock-skewed server can be run at all: Docker has no time namespace, so no
/// container and no testbed service will ever disagree with our clock. Everything else -
/// the shell, the script, `find`, the trees, their mtimes and the kill that truncates a
/// sweep - is real.
final class SweepScenarios: XCTestCase {

    private var servers: [FakeSSHD] = []
    /// Real directory trees on this box, which is what a sweep really walks.
    private var scratch: [URL] = []

    override func tearDown() async throws {
        for server in servers { server.shutdown() }
        servers = []
        for directory in scratch { try? FileManager.default.removeItem(at: directory) }
        scratch = []
    }

    private func sshd(_ profile: ServerProfile) throws -> FakeSSHD {
        if let reason = FakeSSHD.unavailabilityReason(for: profile) {
            throw XCTSkip("\(profile.name): \(reason)")
        }
        let server = try FakeSSHD(profile: profile)
        servers.append(server)
        return server
    }

    /// A busybox-`find` server whose script shell is dash. The flavour is what these
    /// scenarios are about; the busybox *shell* rows are `ShellScenarios`' and skip
    /// wherever the binary is missing.
    private var busyboxServer: ServerProfile {
        ServerProfile.alpine.with(name: "alp (busybox find, dash shell)", loginShell: .dash)
    }

    private func records(
        _ server: FakeSSHD, body: String, arguments: [String] = [], expecting: Int,
        timeout: TimeInterval = 20
    ) async throws -> [String] {
        let script = RemoteScript(arguments: arguments, body: body)
        let channel = try await server.openExecChannel(script: script, readinessDeadline: timeout)
        defer { channel.close() }
        let payload = try await channel.readPayload(until: expecting, timeout: timeout)
        return payload.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - H1: the flavour probe

    /// **H1** (`SQ-001`, `SQ-002`, `SQ-003`): busybox `find --version` prints an error and
    /// **exits 0**, so a flavour probe keyed on the exit status calls every busybox server
    /// GNU - and every sweep on it then fails outright with nothing on stdout. Ours reads
    /// the `busybox` banner and the `-cmin` answer, and this runs the shipping
    /// `ServerProbe.script` to prove it.
    func testH1_theFlavourProbeReadsTheBannerAndNeverTheExitStatus() async throws {
        let server = try sshd(busyboxServer)

        // The trap itself, measured: `--version` fails and still exits 0.
        let exitStatus = try await records(
            server, body: "find --version >/dev/null 2>&1; printf '%s\\000' \"$?\"", expecting: 1)
        XCTAssertEqual(exitStatus.first, "0",
                       "SQ-002: a probe keyed on this would call a busybox server GNU")

        let probe = try await records(
            server, body: ServerProbe.script, expecting: ServerProbe.recordCount, timeout: 25)
        XCTAssertGreaterThanOrEqual(probe.count, ServerProbe.recordCount)
        XCTAssertEqual(probe[6], "no", "SQ-001: `find -cmin` is not accepted")
        XCTAssertEqual(probe[7], "no", "SQ-003: nor is `-printf`")
        XCTAssertTrue(probe[8].lowercased().contains("busybox"),
                      "SQ-002: the banner is what the probe reads: \(probe[8])")
        XCTAssertEqual(
            ServerProbe.flavour(fromVersionText: probe[8], takesCmin: probe[6] == "yes"),
            "busybox",
            "SQ-002: banner plus the -cmin answer, never the exit status")

        // And the control: the same probe against the host's own `find`. A GNU-`find`
        // profile is only a GNU control where this box actually has GNU findutils; on a
        // BSD host it is a **BSD** control, and the probe must say so rather than be told
        // to lie - `.bsd` is a flavour `ServerModel` carries precisely because the testbed
        // has no BSD to measure (`docs/design/testing.md`).
        let gnu = try sshd(.debian)
        let gnuProbe = try await records(
            gnu, body: ServerProbe.script, expecting: ServerProbe.recordCount, timeout: 25)
        let hostIsGNU = gnuProbe[8].lowercased().contains("gnu findutils")
        XCTAssertEqual(
            ServerProbe.flavour(fromVersionText: gnuProbe[8], takesCmin: gnuProbe[6] == "yes"),
            hostIsGNU ? "gnu" : "bsd",
            "the unshimmed profile is classified by what this box's `find` really is")
        XCTAssertNotEqual(
            ServerProbe.flavour(fromVersionText: gnuProbe[8], takesCmin: gnuProbe[6] == "yes"),
            "busybox",
            "SQ-002: and it is never mistaken for busybox, which is the classification that costs a sweep")
        if hostIsGNU {
            XCTAssertEqual(gnuProbe[6], "yes", "GNU find takes -cmin")
            XCTAssertEqual(gnuProbe[7], "yes", "SQ-003: and -printf")
        } else {
            print("H1: the GNU control row is a BSD one on this box - `find` here is \(gnuProbe[8])")
        }
    }

    // MARK: - H2 / SQ-004: the second refusal

    /// **H2** (`SQ-004`): a busybox `-cmin` does not lose a field, it **fails the whole
    /// sweep** - `find: unrecognized: -cmin`, rc 1, nothing on stdout. So `SweepPlan`
    /// refuses `-cmin` and `-printf` on a busybox flavour a *second* time even when the
    /// probe claims them, and this runs both plans against a real busybox `find` to show
    /// what the second refusal is worth.
    func testH2_aWronglyClaimedCminFailsTheWholeSweepAndSweepPlanRefusesItAnyway() async throws {
        let server = try sshd(busyboxServer)

        // The plan is the second line of defence: a probe that got it wrong changes
        // nothing, because the flavour overrides the claim.
        let claimed = SweepPlan(
            shallowRoots: ["."], recursiveRoots: [], flavour: .busybox,
            takesCmin: true, takesPrintf: true, windowMinutes: 60)
        XCTAssertFalse(claimed.usesCmin, "SQ-004: refused a second time on a busybox flavour")
        XCTAssertFalse(claimed.usesPrintf, "SQ-003")

        // What it is worth: the plan the probe would have built runs `-cmin` for real, and
        // the whole sweep comes back with nothing at all.
        let wrong = SweepPlan(
            shallowRoots: ["."], recursiveRoots: [], flavour: .gnu,
            takesCmin: true, takesPrintf: true, windowMinutes: 60)
        let wrongScript = wrong.script()
        let wrongOut = try await records(
            server, body: wrongScript.body, arguments: wrongScript.arguments, expecting: 3)
        XCTAssertLessThanOrEqual(
            wrongOut.filter { $0.hasPrefix("./") || $0.hasPrefix(".") && $0.count > 1 }.count, 0,
            "SQ-004: `-cmin` took the whole sweep with it, not one field")

        // And the plan we actually build returns records.
        let rightScript = claimed.script()
        let rightOut = try await records(
            server, body: rightScript.body, arguments: rightScript.arguments, expecting: 2)
        XCTAssertGreaterThanOrEqual(
            rightOut.count, 2, "the `-mmin` sweep runs and reports its server clock and paths")
        XCTAssertNotNil(Int(rightOut[0]), "the first record is the server's own clock")
    }

    // MARK: - H3: what the fallback costs

    /// **H3** (`SQ-005`): `-mmin` **misses a ctime-only change**. A `chmod` on a file whose
    /// mtime was set back to 2020 is found by GNU `-cmin` and missed by `-mmin`, which is
    /// the whole cost of the busybox fallback - measured here on a real `find` rather than
    /// asserted from the manual.
    func testH3_mminMissesACtimeOnlyChangeAndCminFindsIt() async throws {
        let server = try sshd(.debian)
        let body = """
            __d=$(mktemp -d "${TMPDIR:-/tmp}/sshdrive-sweep-XXXXXX")
            : > "$__d/aged"
            touch -t 202001010000 "$__d/aged"
            chmod 600 "$__d/aged"
            printf '%s\\000' "$(find "$__d" -name aged -cmin -60 | wc -l | tr -d ' ')"
            printf '%s\\000' "$(find "$__d" -name aged -mmin -60 | wc -l | tr -d ' ')"
            rm -rf "$__d"
            """
        let out = try await records(server, body: body, expecting: 2)
        XCTAssertEqual(out[0], "1", "SQ-005: `-cmin` sees the chmod, because ctime moved")
        XCTAssertEqual(out[1], "0", "SQ-005: `-mmin` does not, because mtime did not")

        // Which is exactly what the sweep on a busybox server loses, and what `status`
        // has to carry as a note.
        let busybox = SweepPlan(
            shallowRoots: ["."], recursiveRoots: [], flavour: .busybox,
            takesCmin: false, takesPrintf: false, windowMinutes: 60)
        XCTAssertTrue(busybox.script().body.contains("-mmin -60"))
        let gnu = SweepPlan(
            shallowRoots: ["."], recursiveRoots: [], flavour: .gnu,
            takesCmin: true, takesPrintf: true, windowMinutes: 60)
        XCTAssertTrue(gnu.script().body.contains("-cmin -60"))
    }

    /// **H6** (`SQ-007`, `SQ-050`): `find` has no portable `--`, so a top-level directory
    /// named `-name` would be read as an option and take the whole sweep with it. Every
    /// root is spelled `./name`, and the six weird names of the testbed's `weird/` tree go
    /// through `set --` single-quoted, each returning its own file and creating no `pwned`
    /// file. Run against a real shell and a real `find`, which is the only way the quoting
    /// rule means anything.
    func testH6_everyRootIsSpelledDotSlashAndTheWeirdNamesSurviveTheQuotingRule() async throws {
        let server = try sshd(.debian)
        let weird = ["$(echo pwned)", "quote'name", "space in name", "*star*",
                     "[bracket]", "back\\slash", "-name"]
        var body = """
            __d=$(mktemp -d "${TMPDIR:-/tmp}/sshdrive-sweep-XXXXXX")
            cd "$__d" || exit 1
            __seed=$1; shift
            __i=0
            while [ "$__i" -lt "$__seed" ]; do
              mkdir -p -- "./$1" && : > "./$1/inside.txt"
              shift
              __i=$((__i + 1))
            done

            """
        let plan = SweepPlan(
            shallowRoots: weird.map { "./\($0)" }, recursiveRoots: [], flavour: .gnu,
            takesCmin: true, takesPrintf: false, windowMinutes: 60)
        let script = plan.script()
        for root in plan.batches.flatMap(\.roots) {
            XCTAssertTrue(root.hasPrefix("./"), "SQ-007: every root is spelled ./name")
        }
        body += script.body
        body += """

            printf '%s\\000' "$(ls -1 | grep -c '^pwned$' | tr -d ' ')"
            cd / && rm -rf "$__d"
            """
        let out = try await records(
            server, body: body, arguments: [String(weird.count)] + weird + script.arguments,
            expecting: 64)
        XCTAssertEqual(out.last(where: { !$0.isEmpty }), "0",
                       "SQ-050: no `pwned` file: the single-quoting held under a real shell")
        for name in weird {
            XCTAssertTrue(
                out.contains { $0.contains("\(name)/inside.txt") },
                "SQ-007/SQ-050: `\(name)` was swept as a root and returned its own file")
        }
    }

    // MARK: - H4 / H5 / H7: the harness those three share

    /// A real directory with real files in it. Nothing about these sweeps is in memory:
    /// `find` walks this tree, reads these mtimes and prints these paths.
    private func makeTree(_ files: [String] = []) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshdrive-sweep-\(UUID().uuidString)")
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

    /// A tree whose `-print0` output is at least `bytes` long, so a sweep of it outruns the
    /// channel's own buffer. Built cheaply: three nested directories with long names, so
    /// every record is most of a kilobyte and a few thousand files are already megabytes.
    /// The files are made with `open(2)` rather than `FileManager`, which at this count is
    /// the difference between half a second and several.
    ///
    /// **The names are sized from the box, not written out** (`SQ-085`). `PATH_MAX` is 4096
    /// on Linux and **1024** on macOS, and a fixed 240-byte segment nested three deep is
    /// over the Darwin limit with the temporary directory in front of it: every `open` then
    /// fails `ENAMETOOLONG`, the tree is empty, the sweep returns nothing, and the scenario
    /// passes its control assertion over an empty directory and never truncates. So the
    /// budget is `PATH_MAX` less the root and a margin, split between the three segments and
    /// the filename, and the file count is whatever reaches `bytes` at that record length.
    private func makeDeepTree(bytes: Int) throws -> (root: URL, sweepRoot: String, files: Int) {
        let root = try makeTree()
        // Four components below the root, plus a separator each, plus a margin for the
        // `./`-spelled root `find` prints and the index prefix on every filename.
        let budget = HostTools.pathMax - root.path.count - 64
        let component = max(24, min(240, budget / 4))
        let segment = String(repeating: "d", count: component)
        let deep = root.appendingPathComponent(segment)
            .appendingPathComponent(segment)
            .appendingPathComponent(segment)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let filler = String(repeating: "n", count: max(8, component - 10))
        // What one `-print0` record costs: the deep directory, the filename and the NUL.
        let record = deep.path.count + 1 + filler.count + 8
        let fileCount = max(1, bytes / record + 1)
        for index in 0..<fileCount {
            let path = "\(deep.path)/\(index)-\(filler).txt"
            let descriptor = open(path, O_CREAT | O_WRONLY, 0o644)
            XCTAssertGreaterThanOrEqual(
                descriptor, 0,
                "SQ-085: the deep tree must fit this box's PATH_MAX (\(HostTools.pathMax)); "
                    + "\(path.count) bytes failed with errno \(errno)")
            if descriptor >= 0 { close(descriptor) }
        }
        return (root, "./\(segment)/\(segment)/\(segment)", fileCount)
    }

    /// A real mtime in the past, which is the only thing `-mmin` has to go on (`SQ-005`).
    private func backdate(_ url: URL, bySeconds seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    /// The plan a probe of this profile would build: the flavour and its two answers come
    /// off the profile rather than being written out per test, so a busybox row cannot
    /// quietly become a GNU one (`SQ-001`, `SQ-003`).
    private func plan(
        _ profile: ServerProfile, shallow: [String] = ["."], recursive: [String] = [],
        windowMinutes: Int?
    ) -> SweepPlan {
        let flavour: FindFlavour
        switch profile.findFlavour {
        case .gnu: flavour = .gnu
        case .bsd: flavour = .bsd
        case .busybox, .busyboxNoCmin: flavour = .busybox
        }
        return SweepPlan(
            shallowRoots: shallow, recursiveRoots: recursive, flavour: flavour,
            takesCmin: profile.findFlavour.takesCmin,
            takesPrintf: profile.findFlavour.takesPrintf,
            windowMinutes: windowMinutes)
    }

    /// One cycle's sweep, through the **shipping** script and the shipping reader:
    /// `RemoteSweep.script` builds it, `FakeSSHD` runs it under the heartbeat wrapper on a
    /// real shell, and `RemoteSweep.collect` reads it. Nothing here re-implements a rule
    /// the agent owns; `killAfter` is the one addition, and it kills a real process group.
    private func sweep(
        _ server: FakeSSHD, root: URL, plan: SweepPlan, timeout: TimeInterval = 30,
        killAfter: TimeInterval? = nil
    ) async throws -> RemoteSweep.Outcome {
        let sentinel = Sentinel()
        let script = RemoteSweep.script(canonicalRoot: root.path, plan: plan, sentinel: sentinel)
        let channel = try await server.openExecChannel(script: script, readinessDeadline: timeout)
        defer { channel.close() }
        let started = Date()
        if let killAfter {
            // A real `SIGKILL` to the real process group the session runs in: the shell,
            // its wrapper and `find` all die at once, mid-write. Our end of the pipe is
            // left open, so what the pipe already holds is still read - a real prefix of
            // a real sweep, not a struct with a field cleared by hand.
            try await Task.sleep(nanoseconds: UInt64(killAfter * 1_000_000_000))
            kill(-channel.processGroup, SIGKILL)
        }
        let outcome = await RemoteSweep.collect(
            stream: channel.stream, sentinel: sentinel, usesPrintf: plan.usesPrintf,
            batches: plan.batches.count, started: started,
            deadline: started.addingTimeInterval(timeout))
        channel.endInput()
        return outcome
    }

    private func paths(_ outcome: RemoteSweep.Outcome) -> [String] {
        outcome.hits.map { String(decoding: $0.path, as: UTF8.self) }
    }

    // MARK: - H4: the window is elapsed time

    /// **H4** (`SQ-054`, `SQ-081`, and `SQ-001`/`SQ-003`/`SQ-005` for the busybox half): the
    /// sweep window is **elapsed time**, and neither clock's absolute value enters it.
    ///
    /// `N = ceil((now - localTimeOfStamp) / 60) + 1`: the stored value is the *server's*
    /// `date +%s` from the last applied sweep, and our own clock is used for exactly one
    /// thing - how long ago that was - which both clocks agree on however far apart they
    /// are set. A server five minutes behind, one five minutes ahead and one in step
    /// therefore get the same window for the same elapsed time (`SweepWindow.forCycle`).
    ///
    /// **This is the case a container could never provide** (`SQ-054`): Docker has no time
    /// namespace, every container shares the host's clock, and no testbed service will ever
    /// disagree with ours by a second. So the skew is the profile's, applied by a `date`
    /// shim on the session's `PATH`; everything else here - the shell, the script, `find`,
    /// the files and their mtimes - is real, and the model is the only coverage this case
    /// will ever get.
    ///
    /// Confidence: the arithmetic and the "never the Mac's clock" rule are
    /// docs/design/change-detection.md's, and the unskewed path is measured against `deb`
    /// and `alp`. The skew itself is **inferred**, never measured on a server: `SQ-054`
    /// says why it cannot be.
    func testH4_theSweepWindowIsElapsedTimeAndNeitherClocksAbsoluteValueEnters() async throws {
        // Two flavours and two directions of skew. One takes `-cmin`, the busybox one falls
        // back to `-mmin`, and the window arithmetic is the same for both.
        //
        // **The `-cmin` half runs against the flavour this box's own `find` really is**
        // (`SQ-081`): findutils on Linux, BSD on a Mac, and both take `-cmin`, which is the
        // only switch this row turns on. Pinning it to `.gnu` would make a scenario about
        // the sweep *window* fail on every box without findutils - for `-printf`, which it
        // never asks about - and shimming a `find` here would take the real one out of the
        // scenario, which is the point of it. A box whose `find` takes no time test at all
        // has nothing to run and skips by name.
        let timeTested = try HostTools.flavourTakingCmin()
        let behind = ServerProfile.debian
            .with(name: "deb (\(timeTested.rawValue) find, clock five minutes behind)",
                  findFlavour: timeTested, clockOffset: -300)
        let ahead = busyboxServer
            .with(name: "alp (busybox find, clock five minutes ahead)", clockOffset: 300)

        var stamps: [String: (stamp: Int64, takenAt: Double)] = [:]
        for profile in [behind, ahead] {
            let server = try sshd(profile)
            let root = try makeTree(["before.txt"])

            // Cycle 1: the full sweep a fresh index runs, whose only job here is to bring
            // back the server's own clock.
            let takenAt = Date().timeIntervalSince1970
            let first = try await sweep(server, root: root, plan: plan(profile, windowMinutes: nil))
            XCTAssertFalse(first.truncated, "\(profile.name): the sweep ended on its sentinel")
            let stamp = try XCTUnwrap(first.serverTime, "\(profile.name): the stamp is record 0")
            stamps[profile.name] = (stamp, takenAt)

            // The skew is real, and it is the *server's* clock the sweep read: this is the
            // assertion a container cannot host (`SQ-054`).
            XCTAssertEqual(
                Double(stamp) - takenAt, profile.clockOffset, accuracy: 5,
                "\(profile.name): SQ-054 - the sweep's stamp is the server's clock, offset and all")

            // A change, made between the cycles.
            let changed = root.appendingPathComponent("changed.txt")
            _ = FileManager.default.createFile(atPath: changed.path, contents: Data("x".utf8))

            // Cycle 2's window: elapsed time on our clock, applied to the server's stamp.
            let now = Date().timeIntervalSince1970
            let window = SweepWindow.forCycle(
                lastAppliedServerTime: stamp, takenAt: takenAt, now: now, full: false)
            let expected = Int((max(0, now - takenAt) / 60).rounded(.up)) + 1
            XCTAssertEqual(
                window.minutes, expected,
                "\(profile.name): N = ceil((now - localTimeOfStamp)/60) + 1")
            XCTAssertFalse(
                window.clockWentBackwards,
                "\(profile.name): a skew is not a clock that moved; nothing here went backwards")

            // And the change is found, on both flavours.
            let second = try await sweep(
                server, root: root, plan: plan(profile, windowMinutes: window.minutes))
            XCTAssertFalse(second.truncated)
            XCTAssertTrue(
                paths(second).contains { $0.hasSuffix("changed.txt") },
                "\(profile.name): the change is inside the window the elapsed-time rule built")
        }

        // The two servers' clocks really are ten minutes apart...
        let one = try XCTUnwrap(stamps[behind.name])
        let other = try XCTUnwrap(stamps[ahead.name])
        XCTAssertEqual(
            Double(other.stamp - one.stamp), 600, accuracy: 10,
            "SQ-054: five minutes behind and five minutes ahead")

        // ...and for one and the same elapsed time the window is identical, because no
        // absolute value enters it. Five minutes on from each stored pair:
        let now = Date().timeIntervalSince1970
        var minutes: Set<Int> = []
        for (stamp, _) in [one, other] + [(stamp: Int64(now), takenAt: now)] {
            let window = SweepWindow.forCycle(
                lastAppliedServerTime: stamp, takenAt: now - 300, now: now, full: false)
            XCTAssertEqual(window.minutes, 6, "five minutes elapsed is a six-minute window")
            XCTAssertFalse(window.clockWentBackwards)
            minutes.insert(window.minutes ?? -1)
        }
        XCTAssertEqual(
            minutes.count, 1,
            "SQ-054: behind, ahead and in step give one window; the skew is not in the answer")

        // The bite-proof: the arithmetic this rule replaced. Measuring the server's own
        // stamp against the **Mac's** wall clock folds the whole skew into the window.
        //
        // On a server running ahead, a stamp taken a moment ago is in our future, so the
        // window reads as time having gone backwards and clamps to a single minute -
        // while nothing has moved at all, and the honest rule says so.
        let mixedOnAFreshStamp = SweepWindow.compute(
            lastAppliedServerTime: other.stamp, serverNow: Int64(now), full: false)
        XCTAssertTrue(
            mixedOnAFreshStamp.clockWentBackwards,
            "the Mac's clock against a server five minutes ahead reads as a clock that moved")
        XCTAssertEqual(mixedOnAFreshStamp.minutes, 1, "and clamps to one minute")
        let honestOnTheSameStamp = SweepWindow.forCycle(
            lastAppliedServerTime: other.stamp, takenAt: other.takenAt, now: now, full: false)
        XCTAssertFalse(
            honestOnTheSameStamp.clockWentBackwards,
            "a skew is not a clock that moved, and the elapsed-time rule does not confuse them")

        // Five minutes on, the same fold is what loses the changes: the stored stamp is
        // what the server's clock said five minutes ago, and measuring it against ours
        // gives a window far short of the five minutes that really elapsed.
        let storedFiveMinutesAgo = other.stamp - 300
        let mixedFiveMinutesOn = SweepWindow.compute(
            lastAppliedServerTime: storedFiveMinutesAgo, serverNow: Int64(now), full: false)
        XCTAssertLessThan(
            mixedFiveMinutesOn.minutes ?? 0, 6,
            "the skew is folded in and five minutes of changes fall outside the window")
        XCTAssertEqual(
            SweepWindow.forCycle(
                lastAppliedServerTime: storedFiveMinutesAgo, takenAt: now - 300, now: now,
                full: false).minutes,
            6,
            "where the elapsed-time rule asks for the six minutes that really passed")
        let mixedOnTheServerThatIsBehind = SweepWindow.compute(
            lastAppliedServerTime: one.stamp - 300, serverNow: Int64(now), full: false)
        XCTAssertGreaterThanOrEqual(
            mixedOnTheServerThatIsBehind.minutes ?? 0, 10,
            "and on a server five minutes behind it is twice as wide as the elapsed time")

        // What the clamp costs, against a real `find` and a real mtime: a change four
        // minutes old is inside the six-minute window the elapsed-time rule builds and
        // outside the one-minute window the Mac's clock builds. `-mmin` is what makes the
        // demonstration possible at all (`SQ-005`): a backdated mtime is in the past,
        // where a `chmod`'s ctime never can be.
        let server = try sshd(ahead)
        let root = try makeTree(["aged.txt"])
        try backdate(root.appendingPathComponent("aged.txt"), bySeconds: 240)
        let missed = try await sweep(
            server, root: root, plan: plan(ahead, windowMinutes: mixedFiveMinutesOn.minutes))
        XCTAssertFalse(
            paths(missed).contains { $0.hasSuffix("aged.txt") },
            "the mixed-clock window misses the change entirely")
        let found = try await sweep(server, root: root, plan: plan(ahead, windowMinutes: 6))
        XCTAssertTrue(
            paths(found).contains { $0.hasSuffix("aged.txt") },
            "the elapsed-time window finds it, on a server whose clock says something else")
    }

    // MARK: - H5: a truncated sweep stores nothing

    /// **H5** (`SQ-016`, `SQ-005`, `SQ-001`): a sweep whose **closing sentinel never
    /// arrives** stores `serverTime: nil`, and the next cycle's window still covers what
    /// the truncated one missed.
    ///
    /// The truncation is real: a tree whose output is larger than the channel will buffer
    /// is swept, nothing reads it, so `find` is still writing - and the session's whole
    /// process group is then `SIGKILL`ed, the shell, the heartbeat wrapper and `find`
    /// together, which is what a connection dying under a sweep does. What the channel
    /// already holds is then read through the shipping `RemoteSweep.collect`, so the
    /// prefix, the missing marker and the `serverTime: nil` are all the product's own.
    ///
    /// Why the marker and not EOF: an account whose rc file leaves a background child
    /// holding stdout never sends EOF at all (`SQ-016`), so the closing sentinel is the
    /// only end-of-sweep there is - and a stream that ends without it is a prefix, however
    /// complete the first record looks.
    ///
    /// Confidence: the rule is docs/design/change-detection.md's ("stored once the
    /// sweep's results have been applied, never before") and `ChangeDetector` stores on
    /// `serverTime != nil && !truncated`; what is asserted here is the outcome that rule
    /// reads, produced by a real killed sweep.
    func testH5_aTruncatedSweepStoresNothingAndTheNextWindowStillCoversIt() async throws {
        let profile = busyboxServer
        let server = try sshd(profile)

        // Enough output that the sweep is **certainly** still writing when the kill lands:
        // the channel buffers 4 MB before it stops draining (docs/design/sftp.md's
        // backpressure on `PipeByteStream`), so this tree prints half as much again in
        // `-print0` records.
        // That is also the realistic shape of a truncated sweep - it is the big trees that
        // get cut off, not the small ones.
        let tree = try makeDeepTree(bytes: 6 * 1024 * 1024)
        let sweepPlan = plan(profile, shallow: [tree.sweepRoot], windowMinutes: nil)

        // The control: the same tree, swept to its end, has a server time.
        let whole = try await sweep(server, root: tree.root, plan: sweepPlan)
        XCTAssertFalse(whole.truncated)
        XCTAssertNotNil(whole.serverTime, "record 0 is the server's clock, printed first")
        XCTAssertEqual(paths(whole).filter { $0.hasSuffix(".txt") }.count, tree.files)

        // And the truncated one.
        let cut = try await sweep(
            server, root: tree.root, plan: sweepPlan, killAfter: 0.3)
        XCTAssertTrue(cut.truncated, "the closing sentinel never arrived")
        XCTAssertNil(
            cut.serverTime,
            "SQ-016: a stream that ended without its marker stores nothing, stamp included")
        XCTAssertGreaterThan(cut.bytes, 0, "the kill landed mid-sweep, not before it")
        XCTAssertGreaterThan(
            cut.hits.count, 0,
            "records were parsed, so record 0 - the stamp - had arrived in full and was still not stored")
        XCTAssertLessThan(
            cut.hits.count, tree.files, "and the sweep is a prefix: it never reached the end")

        // The next cycle. Nothing was stored, so the window is still measured from the
        // stamp the *last applied* sweep left - five minutes back - and it covers the
        // change the truncated cycle never got as far as reporting.
        let now = Date().timeIntervalSince1970
        let lastApplied = Int64(now + profile.clockOffset) - 300
        let next = SweepWindow.forCycle(
            lastAppliedServerTime: lastApplied, takenAt: now - 300, now: now, full: false)
        XCTAssertEqual(next.minutes, 6, "five minutes since the last *applied* sweep")

        // Had the truncated cycle stored its own stamp, the window would be one minute -
        // and this is what that costs, against a real `find`: a change four minutes old
        // is found by the first and missed by the second.
        let hadItStored = SweepWindow.forCycle(
            lastAppliedServerTime: try XCTUnwrap(whole.serverTime), takenAt: now, now: now,
            full: false)
        XCTAssertEqual(hadItStored.minutes, 1, "the window the truncated cycle would have left")

        let missedTree = try makeTree(["aged.txt"])
        try backdate(missedTree.appendingPathComponent("aged.txt"), bySeconds: 240)
        let covered = try await sweep(
            server, root: missedTree, plan: plan(profile, windowMinutes: next.minutes))
        XCTAssertTrue(
            paths(covered).contains { $0.hasSuffix("aged.txt") },
            "the next window still covers what the truncated sweep missed")
        let lost = try await sweep(
            server, root: missedTree, plan: plan(profile, windowMinutes: hadItStored.minutes))
        XCTAssertFalse(
            paths(lost).contains { $0.hasSuffix("aged.txt") },
            "SQ-005: storing a truncated sweep's stamp would step the window over it")
    }

    // MARK: - H7: a non-UTF-8 root goes to tier 0

    /// **H7** (`SQ-055`, `SQ-007`): a root named `latin1-caf\xff` is **dropped from the
    /// `find` argv** and **listed at tier 0 in the same cycle**. Both halves are asserted,
    /// because either one alone is a bug: dropped and not listed is a directory nothing
    /// watches, listed and not dropped is a sweep argument that cannot be spelled.
    ///
    /// `set --` is a String pipeline end to end (docs/design/security.md), so there is
    /// no spelling of these bytes that reaches `find`. The bite-proof is the tempting
    /// fix: the lossy `String(decoding:as:)` conversion *succeeds*, substituting U+FFFD,
    /// and the root that comes out names a directory that exists on no server - `find`
    /// answers `No such file or directory`, the real directory is never walked, and
    /// nothing says so. It is
    /// run here against a real `find` on a real directory whose name really does hold a
    /// `0xFF` byte.
    ///
    /// The tier-0 half runs over the SFTP **wire**, where the path is bytes and no String
    /// is involved: `readdir` on the same root returns the file inside it. That half, and
    /// the pure `partitionRoots` half above it, run on every box; the real-`find` half needs
    /// the name to exist on the local filesystem, which **APFS refuses** (`SQ-080`), so on a
    /// Mac the row skips from that point with the reason named.
    ///
    /// Confidence: the rule is docs/design/change-detection.md tier 1 verbatim ("such a
    /// root is left out of the `find` argv and listed at tier 0 in the same cycle
    /// instead"); that names on a server need not be valid UTF-8 is
    /// docs/design/names-and-attributes.md's, measured on the testbed's `weird/` tree.
    func testH7_aNonUTF8RootIsDroppedFromTheArgvAndListedAtTierZeroInTheSameCycle() async throws {
        var rawName = Data("latin1-caf".utf8)
        rawName.append(0xFF)
        XCTAssertNil(String(data: rawName, encoding: .utf8), "the premise: these bytes are not UTF-8")

        // The split the agent makes, which is `SweepPlan`'s rule and not the detector's.
        let partition = SweepPlan.partitionRoots(
            shallow: [rawName, Data("plain".utf8)], recursive: [])
        XCTAssertEqual(
            partition.shallow, ["./plain"],
            "SQ-055: the non-UTF-8 root is absent from the roots `find` is given")
        XCTAssertEqual(partition.recursive, [])
        XCTAssertEqual(
            partition.tierZero, [rawName],
            "SQ-055: and it is in the tier 0 list - the same cycle, the same cadence")

        // Absent from the argv itself, not merely from the list it was built from.
        let good = plan(.debian, shallow: partition.shallow, windowMinutes: nil)
        let script = good.script()
        for argument in script.arguments {
            XCTAssertFalse(
                argument.contains("latin1"),
                "SQ-055: no spelling of the non-UTF-8 root reaches `set --`")
            XCTAssertFalse(
                argument.unicodeScalars.contains("\u{FFFD}"),
                "SQ-055: and least of all a lossy one")
        }

        // The tier-0 half, over the SFTP **wire**, where a path is bytes and no String is in
        // the way: the root tier 1 could not take is listed, in the same cycle.
        let sftpServer = FakeSFTPServer(profile: .debian)
        sftpServer.putRawDirectory(rawName, containing: ["inside.txt"])
        let transport = try await RealSFTPTransport.connect(
            stream: sftpServer.makeStream(), root: sftpServer.root)
        let entries = try await transport.readdir(RelativePath(components: [rawName]))
        XCTAssertTrue(
            entries.contains { $0.name == Data("inside.txt".utf8) },
            "SQ-055: tier 0 lists the root tier 1 had to drop, and loses only the walk")

        // Everything from here needs the name to exist on **this box's** filesystem, and
        // that is where a Mac stops (`SQ-080`): APFS answers `mkdir` with `EILSEQ` for these
        // bytes, so the directory the rest of this row is about cannot be created at all.
        // The rule keeps every one of those assertions on Linux; nothing below is weakened,
        // and nothing below is faked here.
        try XCTSkipUnless(HostTools.filesystemTakesNonUTF8Names, HostTools.nonUTF8NameSkipReason)

        // The same `find` question as `H4`: the roots that *can* travel are swept by this
        // box's own `find`, so the plan has to be the flavour it really is (`SQ-081`).
        let hostFlavour = try HostTools.flavourTakingCmin()

        // Now the same thing against a real `find`, on a real tree holding a real
        // `latin1-caf\xff` directory beside an ordinary one.
        let onThisBox = ServerProfile.debian.with(findFlavour: hostFlavour)
        let server = try sshd(onThisBox)
        let root = try makeTree(["plain/visible.txt"])
        try makeRawDirectory(rawName, in: root, containing: "inside.txt")

        let swept = try await sweep(
            server, root: root,
            plan: plan(onThisBox, shallow: partition.shallow, windowMinutes: nil))
        XCTAssertFalse(swept.truncated)
        XCTAssertTrue(
            paths(swept).contains { $0.hasSuffix("plain/visible.txt") },
            "SQ-007: the roots that can travel are swept as usual")
        XCTAssertFalse(
            paths(swept).contains { $0.contains("inside.txt") },
            "SQ-055: and the one that cannot is simply not there - tier 0 has it")

        // The bite-proof: the lossy conversion, run for real.
        let lossyRoot = "./" + String(decoding: rawName, as: UTF8.self)
        XCTAssertNotEqual(
            Data(lossyRoot.dropFirst(2).utf8), rawName,
            "U+FFFD is a different name: three bytes where the server has one")
        let lossy = plan(onThisBox, shallow: [lossyRoot, "./plain"], windowMinutes: nil)
        let lossyOutcome = try await sweep(server, root: root, plan: lossy)
        XCTAssertTrue(
            paths(lossyOutcome).contains { $0.hasSuffix("plain/visible.txt") },
            "the sweep survives - `|| true` keeps one bad root from taking the rest")
        XCTAssertFalse(
            paths(lossyOutcome).contains { $0.contains("inside.txt") },
            "SQ-055: and the real directory was never walked, silently, which is the bug")

    }

    /// A directory whose name is not valid UTF-8, created with the POSIX calls: there is
    /// no `String` for these bytes, so `FileManager` cannot make one
    /// (docs/design/names-and-attributes.md).
    private func makeRawDirectory(_ name: Data, in parent: URL, containing child: String) throws {
        var bytes = Array(parent.path.utf8)
        bytes.append(0x2F)
        bytes.append(contentsOf: name)
        var directoryPath = bytes.map { CChar(bitPattern: $0) }
        directoryPath.append(0)
        XCTAssertEqual(mkdir(directoryPath, 0o755), 0, "mkdir failed, errno \(errno)")

        var childBytes = bytes
        childBytes.append(0x2F)
        childBytes.append(contentsOf: Array(child.utf8))
        var childPath = childBytes.map { CChar(bitPattern: $0) }
        childPath.append(0)
        let descriptor = open(childPath, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "open failed, errno \(errno)")
        if descriptor >= 0 { close(descriptor) }
    }
}
