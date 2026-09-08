import Foundation
import XCTest

import AgentCore
@testable import ServerModel

/// The profile table itself: that the testbed's twelve services and the owner's own two
/// servers are all here, that each carries the values `docs/quirks/servers.md` measured,
/// and that every quirk `ServerModel` claims to implement is a row of that file.
///
/// "A quirk with no scenario is a quirk nothing is defending" (`docs/quirks/README.md`);
/// this is the other half - a rule with no quirk row is a rule nobody measured.
final class ServerProfileScenarios: XCTestCase {

    /// `docs/quirks/servers.md`, found relative to this file.
    private var catalog: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ServerModelTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // SSHDriveCore
                .deletingLastPathComponent()   // Packages
                .deletingLastPathComponent()   // repo root
            return try String(
                contentsOf: root.appendingPathComponent("docs/quirks/servers.md"),
                encoding: .utf8)
        }
    }

    /// Every id `ServerModel` keys a rule on is a row of the Markdown catalog. This is
    /// `scripts/check-quirks.sh`'s first assertion, run from the suite so it cannot rot
    /// while the script is still to be written (`docs/testing-architecture.md` step 11).
    func testEveryQuirkTheModelImplementsIsARowOfTheCatalog() throws {
        let text = try catalog
        var missing: [String] = []
        for id in ServerQuirks.implemented where !text.contains("| \(id.rawValue) |") {
            missing.append(id.rawValue)
        }
        XCTAssertEqual(missing, [], "these ids are keyed on in Sources/ServerModel but are not in docs/quirks/servers.md")
        XCTAssertEqual(
            Set(ServerQuirks.implemented).count, ServerQuirks.implemented.count,
            "ids are stable and never reused, so the list holds no duplicates")
    }

    /// Every quirk a profile claims to carry is one the model implements.
    func testEveryProfileCitesOnlyImplementedQuirks() {
        let implemented = Set(ServerQuirks.implemented)
        for profile in ServerProfile.testbed + [.ownerDebian, .ownerTailscale, .openSSH9_6,
                                                .freeBSD, .synologyDSM] {
            for id in profile.quirks {
                XCTAssertTrue(implemented.contains(id),
                              "\(profile.name) cites \(id), which no rule keys on")
            }
        }
    }

    /// The testbed's twelve services are twelve constants
    /// (`docs/testing-architecture.md` section 4.1), and the ports are `testbed/README.md`'s.
    func testTheTwelveTestbedServicesAreTwelveProfiles() {
        XCTAssertEqual(ServerProfile.testbed.count, 12)
        let published = ServerProfile.testbed.compactMap(\.port).sorted()
        XCTAssertEqual(published, [2201, 2202, 2203, 2204, 2205, 2206, 2207, 2208, 2210],
                       "the nine published ports; bastion-b, inner and ts-ssh have none")
        XCTAssertNil(ServerProfile.tailscaleSSH.port,
                     "ts-ssh is on the tailnet and has no port at all")
    }

    /// The owner's **two real server shapes**: a Debian running OpenSSH 9.2p1 (their first
    /// cask install, results 2026-09-05) and a Tailscale SSH node on x86_64 Debian, whose
    /// tier 2 stream died 255 fifteen seconds after `ready` (results 2026-09-08). The
    /// testbed's `ts-ssh` exists to reproduce the second.
    func testTheOwnersTwoServersAreModelledAndDifferInEveryWayThatMatters() {
        XCTAssertEqual(ServerProfile.ownerDebian.identificationString,
                       "OpenSSH_9.2p1 Debian-2+deb12u10")
        XCTAssertEqual(ServerProfile.ownerDebian.sftp, .opensshInternal)
        XCTAssertEqual(ServerProfile.ownerDebian.extensions, SFTPExtensionSets.openSSH9_2)
        XCTAssertEqual(ServerProfile.ownerDebian.sessionGrouping, .ownProcessGroup)

        XCTAssertEqual(ServerProfile.ownerTailscale.identificationString, "Tailscale")
        XCTAssertEqual(ServerProfile.ownerTailscale.sftp, .goPkgSFTP)
        XCTAssertEqual(ServerProfile.ownerTailscale.extensions, SFTPExtensionSets.goPkgSFTP)
        XCTAssertEqual(ServerProfile.ownerTailscale.sessionGrouping, .sharedWith("tailscaled"))
        XCTAssertEqual(ServerProfile.ownerTailscale.auth, AuthShape.none,
                       "SQ-061: the tailnet ACL is the auth")
    }

    /// `SQ-021`, `SQ-009`, `SQ-008`, `SQ-054`: the values a scenario reads off a profile.
    func testTheMeasuredValuesAreTheOnesTheCatalogRecords() {
        XCTAssertEqual(ServerProfile.debianMaxSessions.maxSessions, 2, "SQ-021")
        XCTAssertEqual(ServerProfile.debian.maxSessions, 10, "the OpenSSH default")
        XCTAssertEqual(ServerProfile.debian.clientAliveInterval, 15,
                       "testbed/README.md: set only on `deb`, 15 s / 3")
        for profile in ServerProfile.testbed where profile.name != "deb" {
            XCTAssertNil(profile.clientAliveInterval, "\(profile.name): unset everywhere else")
        }
        for profile in ServerProfile.testbed {
            XCTAssertFalse(profile.reapsOrphans,
                           "\(profile.name): SQ-008 - no server measured reaps a background child")
        }
        // SQ-054: a container cannot be clock-skewed, so every testbed profile is at zero
        // and the model is the only place a skew will ever exist.
        for profile in ServerProfile.testbed {
            XCTAssertEqual(profile.clockOffset, 0, "\(profile.name): SQ-054")
        }
        XCTAssertEqual(ServerProfile.synologyDSM.clockOffset, -300,
                       "SQ-054: the model is the only coverage a skewed clock will ever get")
    }

    /// `SQ-001`-`SQ-003`: the flavour table, including the `--version`-exits-0 trap.
    func testTheFindFlavourTableMatchesWhatWasMeasured() {
        XCTAssertFalse(ServerFindFlavour.busybox.takesCmin, "SQ-001")
        XCTAssertFalse(ServerFindFlavour.busybox.takesPrintf, "SQ-003")
        XCTAssertEqual(ServerFindFlavour.busybox.versionBanner.exitStatus, 0, "SQ-002")
        XCTAssertTrue(ServerFindFlavour.busybox.versionBanner.line.isEmpty,
                      "SQ-002: it prints on stderr, so stdout is empty")
        XCTAssertTrue(ServerFindFlavour.gnu.takesCmin)
        XCTAssertTrue(ServerFindFlavour.gnu.takesPrintf)
        XCTAssertTrue(ServerFindFlavour.bsd.takesCmin)
        XCTAssertFalse(ServerFindFlavour.bsd.takesPrintf,
                       "only GNU has -printf; BSD is modelled and never measured")
        XCTAssertFalse(ServerFindFlavour.busyboxNoCmin.takesCmin, "SQ-001")
    }

    /// `SQ-013`, `SQ-014`, `SQ-016`: the shell shapes, and which of them break what.
    func testTheShellShapesCarryTheirMeasuredConsequences() {
        XCTAssertTrue(ServerProfile.debianBackgroundHolder.loginShell.holdsStdoutOpen, "SQ-016")
        XCTAssertFalse(ServerProfile.debianShells.loginShell.holdsStdoutOpen)
        XCTAssertFalse(ServerProfile.debianForceCommand.hasShellAccess, "SQ-013")
        XCTAssertTrue(ServerProfile.debian.hasShellAccess)
        XCTAssertTrue(ServerProfile.debianExternalSFTP.sftpStreamCarriesRCNoise,
                      "SQ-014: an external sftp-server behind a noisy rc corrupts VERSION")
        XCTAssertFalse(ServerProfile.debianExternalSFTPQuiet.sftpStreamCarriesRCNoise)
        XCTAssertFalse(ServerProfile.alpine.sftpStreamCarriesRCNoise,
                       "SQ-026: internal-sftp is served in-process, so no rc can reach it")
        for shell in LoginShell.allCases where shell != .bashQuiet && shell != .none {
            XCTAssertFalse(shell.rcNoise.isEmpty,
                           "SQ-015: \(shell.rawValue) prints on non-interactive startup")
        }
    }

    /// `SQ-060`, `SQ-047`, `SQ-048`, `SQ-062`: the captured OpenSSH 10.2 prompt strings,
    /// exact, **trailing spaces included**. A character wrong here is a scenario that
    /// proves nothing.
    func testThePromptStringsAreTheCapturedOnes() {
        XCTAssertEqual(OpenSSHPrompts.password(user: "alec", host: "nas"),
                       "alec@nas's password: ")
        XCTAssertEqual(OpenSSHPrompts.keyboardInteractive(user: "kbd", host: "nas"),
                       "(kbd@nas) Password: ")
        XCTAssertTrue(OpenSSHPrompts.hostKey(host: "nas")
            .hasSuffix("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        // SQ-048: `%.100s` truncates, so the prompt text alone can never be the key.
        let longPath = "/Users/alec/" + String(repeating: "d/", count: 60) + "id_ed25519"
        let prompt = OpenSSHPrompts.passphrase(keyPath: longPath)
        XCTAssertEqual(prompt.count, "Enter passphrase for key '': ".count + 100)
        XCTAssertFalse(prompt.contains(longPath), "SQ-048: it is a prefix, not the path")
    }

    /// `SQ-024`-`SQ-026`: the three extension sets, which is what `status` reads and what
    /// the server fingerprint is built from.
    func testTheThreeExtensionSetsAreTheMeasuredOnes() {
        XCTAssertEqual(SFTPExtensionSets.goPkgSFTP.count, 3, "SQ-024: exactly three")
        XCTAssertFalse(SFTPExtensionSets.goPkgSFTP.contains("fsync@openssh.com"))
        XCTAssertFalse(SFTPExtensionSets.goPkgSFTP.contains("limits@openssh.com"))
        for name in ["fsync@openssh.com", "lsetstat@openssh.com", "limits@openssh.com",
                     "expand-path@openssh.com"] {
            XCTAssertTrue(SFTPExtensionSets.openSSH9_2.contains(name),
                          "SQ-025: \(name) is what says OpenSSH")
        }
        XCTAssertEqual(SFTPExtensionSets.alpineInternalSFTP, SFTPExtensionSets.openSSH9_2,
                       "SQ-026: internal-sftp offers the same set as the external server")
        XCTAssertEqual(
            ServerSoftware(banner: "Tailscale", advertisedExtensions: SFTPExtensionSets.goPkgSFTP)
                .isOpenSSH, false)
        XCTAssertEqual(
            ServerSoftware(banner: "OpenSSH_9.2p1", advertisedExtensions: SFTPExtensionSets.openSSH9_2)
                .isOpenSSH, true)
    }
}
