import Foundation
import XCTest

import AgentCore
import SSHProcess
@testable import ServerModel

/// Suite H's server half: the `find` flavour probe and the sweep it selects
/// (`docs/testing-architecture.md` section 5).
///
/// This box has GNU findutils and no busybox, so a busybox server's `find` is a generated
/// shim that behaves the way BusyBox 1.36.1 was **measured** to - `-cmin` and `-printf`
/// rejected with rc 1, `--version` printing an error and exiting **0**. The shell that
/// runs the script is a real one either way; the busybox *ash* rows, which need the
/// busybox binary itself, skip by name.
final class SweepScenarios: XCTestCase {

    private var servers: [FakeSSHD] = []

    override func tearDown() async throws {
        for server in servers { server.shutdown() }
        servers = []
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
        // has no BSD to measure (`docs/testing-architecture.md` section 4.1).
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
}
