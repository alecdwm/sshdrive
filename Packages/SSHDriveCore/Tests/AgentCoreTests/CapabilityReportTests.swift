import XCTest
import Config
import SFTP

@testable import AgentCore

/// DESIGN.md section 8.1's report, rendered from a recorded probe and a recorded SFTP
/// extension set.
///
/// Written after the first real install (2026-09-05): `sshdrive add` printed "4/8
/// optimal", "the server cannot run the remote helper" and "upgrade: fsync@openssh.com"
/// for a Debian server that ran the helper ten seconds later. The first two were this
/// type reading a helper state it had not been given; the extension lines are here so a
/// recorded set can never quietly become an empty one again.
final class CapabilityReportTests: XCTestCase {

    /// A Debian 12 server as the probe finds it: shell, GNU find, an identity.
    private func debianProbe() -> ServerProbe.Result {
        var probe = ServerProbe.Result()
        probe.uname = "Linux x86_64"
        probe.home = "/home/alec"
        probe.identity = ServerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [1000])
        probe.description = "uid=1000(alec) gid=1000 groups=1000"
        probe.findFlavour = "gnu"
        probe.findTakesCmin = true
        probe.findTakesPrintf = true
        probe.checksumTool = "/usr/bin/sha256sum"
        probe.cacheDirectory = "/home/alec/.cache/sshdrive"
        return probe
    }

    private func location() -> Location {
        Location(id: "L1", nickname: "shirls", host: "shirls")
    }

    private func feature(_ report: CapabilityReport, _ name: String) -> CapabilityReport.Feature {
        guard let found = report.features.first(where: { $0.name == name }) else {
            XCTFail("no \(name) line in the report")
            return CapabilityReport.Feature(name: name, level: "", best: "", glyph: "")
        }
        return found
    }

    /// What OpenSSH 9.2 actually advertises, as `SFTPExtensionNames` records it.
    private var openSSH: SFTPServerExtensions {
        SFTPExtensionNames.parse([
            "posix-rename@openssh.com", "statvfs@openssh.com", "fstatvfs@openssh.com",
            "hardlink@openssh.com", "fsync@openssh.com", "lsetstat@openssh.com",
            "limits@openssh.com", "expand-path@openssh.com", "copy-data",
            "users-groups-by-id@openssh.com",
        ])
    }

    /// The recorded set is what `capabilities.json` round-trips, so the report and the
    /// cache have to agree name for name.
    func testTheRecordedExtensionSetRoundTrips() {
        let recorded = openSSH
        XCTAssertTrue(recorded.contains(.fsync))
        XCTAssertTrue(recorded.contains(.limits))
        XCTAssertEqual(
            SFTPExtensionNames.parse(SFTPExtensionNames.list(recorded)), recorded,
            "capabilities.json must not lose an extension on the way out and back")
    }

    /// An OpenSSH server with the helper running is the top of every ladder: 8/8.
    func testAnOpenSSHServerWithTheHelperRunningIsFullyOptimal() {
        let report = CapabilityReport.make(
            probe: debianProbe(), extensions: openSSH, location: location(),
            allowsExecChannel: true, probedAt: Date(), cached: false,
            activeTier: "helper",
            helper: .running(version: "0.1.0", directory: "/home/alec/.cache/sshdrive",
                             mechanism: "inotify"))
        XCTAssertEqual(report.optimalCount, 8, report.features.map(\.level).joined(separator: " | "))
        XCTAssertNil(feature(report, "durable writes").upgrade)
        XCTAssertNil(feature(report, "transfer sizing").upgrade)
        XCTAssertEqual(feature(report, "change detection").glyph, "●")
        XCTAssertTrue(feature(report, "change detection").level.contains("helper 0.1.0"))
        XCTAssertEqual(feature(report, "rename detection").level, "helper move events")
    }

    /// The two lines the owner's report showed: they follow the recorded set and nothing
    /// else, so a server that really does not advertise them says so and one that does
    /// never can.
    func testFsyncAndLimitsFollowTheRecordedSet() {
        let without = SFTPExtensionNames.parse([
            "posix-rename@openssh.com", "statvfs@openssh.com", "lsetstat@openssh.com",
        ])
        let report = CapabilityReport.make(
            probe: debianProbe(), extensions: without, location: location(),
            allowsExecChannel: true, probedAt: Date(), cached: false,
            activeTier: "helper",
            helper: .running(version: "0.1.0", directory: "/home/alec/.cache/sshdrive",
                             mechanism: "inotify"))
        XCTAssertEqual(report.optimalCount, 6)
        XCTAssertEqual(feature(report, "durable writes").upgrade, "fsync@openssh.com (OpenSSH >= 6.3)")
        XCTAssertEqual(feature(report, "transfer sizing").upgrade, "limits@openssh.com (OpenSSH >= 8.5)")
        // Still an OpenSSH-shaped server: `rename` refuses to overwrite.
        XCTAssertEqual(feature(report, "collision-safe create").glyph, "●")
    }

    /// An empty set is what an offline report used to be handed instead of the recorded
    /// one: four lines go down at once, which is how the bug announced itself.
    func testAnEmptyExtensionSetCostsFourLines() {
        let report = CapabilityReport.make(
            probe: debianProbe(), extensions: [], location: location(),
            allowsExecChannel: true, probedAt: Date(), cached: true,
            activeTier: "helper",
            helper: .running(version: "0.1.0", directory: "/d", mechanism: "inotify"))
        XCTAssertEqual(report.optimalCount, 4)
        for name in ["atomic overwrite", "durable writes", "transfer sizing", "collision-safe create"] {
            XCTAssertEqual(feature(report, name).glyph, "◐", name)
        }
    }

    /// The bug itself: a report taken while the helper is still going up the wire must
    /// never blame the server.
    func testADeployingHelperIsNeverReportedAsAServerThatCannotRunIt() {
        let report = CapabilityReport.make(
            probe: debianProbe(), extensions: openSSH, location: location(),
            allowsExecChannel: true, probedAt: Date(), cached: false,
            activeTier: "helper", helper: .deploying)
        let change = feature(report, "change detection")
        XCTAssertEqual(change.note, CapabilityReport.deployingNote)
        XCTAssertNil(change.upgrade, "there is nothing for the user to do while it deploys")
        XCTAssertFalse(change.note!.contains("cannot run"))
        let rename = feature(report, "rename detection")
        XCTAssertNil(rename.upgrade)
        XCTAssertEqual(rename.note, CapabilityReport.deployingNote)
        // Six of eight: the two helper lines are the only ones still to come.
        XCTAssertEqual(report.optimalCount, 6)
    }

    /// A server that genuinely cannot run it still says so, with the concrete reason.
    func testAServerThatCannotRunTheHelperKeepsItsReason() {
        var probe = debianProbe()
        probe.cacheDirectory = ""
        probe.cacheNote = "cache directory is noexec"
        let report = CapabilityReport.make(
            probe: probe, extensions: openSSH, location: location(),
            allowsExecChannel: true, probedAt: Date(), cached: false,
            activeTier: "sweep", helper: .unavailable("cache directory is noexec"))
        let change = feature(report, "change detection")
        XCTAssertEqual(change.note, "cache directory is noexec")
        XCTAssertEqual(change.upgrade, "the remote helper (push events, real renames)")
        XCTAssertTrue(change.level.hasPrefix("sweep (find -cmin"))
    }

    /// `sshdrive set <name> helper off` is a setting, not a server limitation.
    func testHelperOffIsReportedAsASetting() {
        var location = self.location()
        location.helper = false
        let report = CapabilityReport.make(
            probe: debianProbe(), extensions: openSSH, location: location,
            allowsExecChannel: true, probedAt: Date(), cached: false,
            activeTier: "sweep", helper: .off)
        XCTAssertTrue(feature(report, "change detection").note!.hasPrefix("helper off (user setting)"))
    }

    /// No shell at all: section 5.4's SFTP-only rule, and no helper sentence pretending
    /// otherwise.
    func testAnAccountWithoutAShellFallsToPoll() {
        var probe = ServerProbe.Result()
        probe.failure = "the account has no shell access"
        let report = CapabilityReport.make(
            probe: probe, extensions: openSSH, location: location(),
            allowsExecChannel: false, probedAt: Date(), cached: false,
            helper: .unavailable("the account has no shell access"))
        let change = feature(report, "change detection")
        XCTAssertTrue(change.level.hasPrefix("poll"))
        XCTAssertEqual(change.note, "the account has no shell access")
        XCTAssertEqual(feature(report, "permissions").upgrade, "shell access")
    }
}
