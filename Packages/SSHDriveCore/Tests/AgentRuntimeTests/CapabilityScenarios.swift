import AgentCore
import AgentRuntime
import AgentRuntimeTestSupport
import Config
import Foundation
import SFTP
import ServerModel
import Testing

/// Suite N on the agent's side: what the capability report of DESIGN.md section 8.1 is
/// allowed to say about a server (`docs/testing-architecture.md` section 5).
///
/// Half of section 8.1's catalogue is a claim about the **server**, and every line of it
/// is read by the user as the truth about their machine. Two failures are recorded here
/// rather than argued about: a helper that was still going up the wire being reported as a
/// server that "cannot run the remote helper" (2026-09-05), and `fsync@openssh.com` being
/// offered as an `upgrade:` to a Tailscale SSH node, which is Go `pkg/sftp` and has never
/// advertised it in any version (2026-09-08).
extension AgentScenarios {

    @Suite struct CapabilityScenarios {

        /// **N1** - never blame a server for our state.
        ///
        /// Quirks: `SQ-077` (the helper's stream does not survive its connection, and
        /// *nothing* about that is a statement about whether the server can run one),
        /// `SQ-079` (a channel that did not open because the master died is not a refusal
        /// either). Both are our state wearing a server's clothes.
        ///
        /// The window `add` writes its one report in is the window where the ladder has
        /// chosen tier 2 from the probe and the binary is still going up the wire. The
        /// report written there used to reach for the sweep branch's "the server cannot
        /// run the remote helper", which was false for every server that could - and the
        /// first real cask install printed it, ten seconds before `sshdrive status` said
        /// `helper 0.1.0`. So `deploying` is its own state: the sweep level, a `note:`
        /// saying the binary is on its way, and **no `upgrade:` line**, because there is
        /// nothing for the user to do.
        ///
        /// The second half is the one that keeps it fixed: that sentence must be
        /// unreachable from any state of ours. Section 6.4's list of things that really do
        /// mean "not on this server" is no shell, no exec channel, an unsupported arch,
        /// `noexec`, and a hash mismatch after a redeploy - all of them refusals the
        /// server or the account made.
        @Test func n1TheDeployingWindowNeverBlamesTheServer() async throws {
            let harness = try AgentHarness()
            harness.launcher.succeed(probe: Self.shellProbe)
            let location = try await harness.addLocation(nickname: "nas", watchMode: .auto)
            let runtime = try await harness.manager.runtime(for: location)
            // A ladder that has chosen tier 2 and has not deployed anything yet: exactly
            // where `add` writes its report.
            let detector = ChangeDetector(
                locationID: location.id, runtime: runtime, location: location,
                capabilities: Self.helperCapable, environment: harness.environment)
            #expect(await detector.currentTier() == .helper)

            let report = try await LocationCommands.capabilityReport(
                location: location, runtime: runtime, forceProbe: false, detector: detector)
            let change = try #require(report.features.first { $0.name == "change detection" })
            #expect(change.note == CapabilityReport.deployingNote, "N1: it says `deploying`")
            #expect(change.upgrade == nil, "N1: and no `upgrade:` line goes with it")
            let rename = try #require(report.features.first { $0.name == "rename detection" })
            #expect(rename.note == CapabilityReport.deployingNote)
            #expect(rename.upgrade == nil)
            #expect(
                !Self.text(report).contains(Self.blameSentence),
                "N1: no line of the report blames the server while we are still deploying")

            // The other side of the same rule: the sentence is reachable, and only from a
            // server that really did refuse. A `ForceCommand internal-sftp` account has no
            // shell, so there is no exec channel to deploy over and none of section 6.4's
            // named reasons applies - this is the one state the generic sentence is for,
            // and the ladder is at tier 0 because of it.
            harness.launcher.succeed(probe: Self.shelllessProbe)
            let shellless = try await harness.addLocation(nickname: "sftponly", host: "other")
            let refusedRuntime = try await harness.manager.runtime(for: shellless)
            let pollOnly = ChangeDetector(
                locationID: shellless.id, runtime: refusedRuntime, location: shellless,
                capabilities: ChangeDetectionLadder.ServerCapabilities(),
                environment: harness.environment)
            #expect(await pollOnly.currentTier() == .poll)
            let refused = try await LocationCommands.capabilityReport(
                location: shellless, runtime: refusedRuntime, forceProbe: false,
                detector: pollOnly)
            #expect(
                Self.text(refused).contains(Self.blameSentence),
                "N1: a real refusal is what the sentence is for")

            // Bite-proof. The logic as it stood before 2026-09-05, in one line: anything
            // that is not a running stream is the sweep branch's refusal. Fed the very
            // state the scenario above is about, it produces the false sentence and an
            // `upgrade:` line telling the user to get shell access they already have.
            let asItWas: HelperState = .unavailable(Self.blameSentence)  // "not running" => "cannot run"
            let old = CapabilityReport.make(
                probe: Self.shellProbe, extensions: [], location: location,
                allowsExecChannel: true, probedAt: Date(), cached: false,
                activeTier: "helper", helper: asItWas)
            #expect(Self.text(old).contains(Self.blameSentence), "the bug, reproduced")
            let oldChange = try #require(old.features.first { $0.name == "change detection" })
            #expect(oldChange.upgrade != nil, "and it asked the user to do something about it")

            await harness.manager.dropRuntime(locationID: location.id)
            await harness.manager.dropRuntime(locationID: shellless.id)
        }

        /// **N5** - the report names the server, and `fsync`/`limits` are server facts.
        ///
        /// Quirks: `SQ-036` (the identification string is printed only at `DEBUG1`, so the
        /// collect connection is the only `ssh` that can read it), `SQ-024` (Go `pkg/sftp`
        /// advertises exactly three extensions and no version advertises `fsync` or
        /// `limits`), `SQ-025` (OpenSSH's own `sftp-server` advertises both), `SQ-026`
        /// (Alpine's `internal-sftp` advertises the same set, so nothing degrades there).
        ///
        /// `upgrade: fsync@openssh.com (OpenSSH >= 6.3)` on a Tailscale SSH node asked the
        /// user to replace their SSH server for something no version of the software they
        /// run has ever had. Where the software is **known and is not OpenSSH** the line
        /// keeps its level and states the fact instead; where it is merely unidentified
        /// nothing changes, because an unidentified server may well be an old OpenSSH.
        ///
        /// The wire half - that the fingerprint really is those three names and that the
        /// `debug1:` lines are stripped before the exit classifier sees them - is `K12`
        /// and `N2` in `Tests/ServerModelTests/SFTPWireScenarios.swift`, and is not
        /// repeated here. This is the *report* the two produce.
        @Test func n5TheReportNamesTheServerAndStatesItsFacts() async throws {
            let harness = try AgentHarness()
            let tailscale = try await harness.addLocation(nickname: "ts", host: "ts-node")
            Self.cacheProbe(of: .tailscaleSSH, locationID: tailscale.id)

            let rows = try await harness.control("status", ["name": "ts"])
            let row = try #require((rows["locations"] as? [[String: Any]])?.first)
            let capabilities = try #require(row["capabilities"] as? [String: Any])
            let software = try #require(capabilities["software"] as? [String: Any])
            #expect(software["banner"] as? String == "Tailscale", "N5: SQ-036's string, named")
            #expect(software["sftp"] as? String == "Go pkg/sftp", "N5: SQ-024's fingerprint")
            #expect(software["openSSH"] as? Bool == false)

            for (feature, extensionName) in [
                ("durable writes", "fsync@openssh.com"), ("transfer sizing", "limits@openssh.com"),
            ] {
                let line = try #require(Self.feature(feature, in: capabilities))
                #expect(line["glyph"] as? String == "◐", "N5: the level is still the fallback")
                #expect(
                    line["upgrade"] == nil,
                    "N5: never an `upgrade:` telling a Tailscale user to replace their SSH server")
                let note = try #require(line["note"] as? String)
                #expect(note.contains(extensionName))
                #expect(note.contains("OpenSSH extension"))
                #expect(note.contains("Tailscale"), "N5: it says *which* server does not have it")
            }
            // And the advertised list is in the JSON, so "it did not advertise it" is
            // checkable from the user's own machine rather than believed.
            #expect(
                capabilities["sftpExtensions"] as? [String] == ServerProfile.tailscaleSSH.extensions)

            // The contrast: OpenSSH's own `sftp-server`, where both are simply there.
            for (nickname, profile) in [
                ("deb", ServerProfile.debian), ("owner", ServerProfile.ownerDebian),
            ] {
                let location = try await harness.addLocation(nickname: nickname, host: nickname)
                Self.cacheProbe(of: profile, locationID: location.id)
                let rows = try await harness.control("status", ["name": nickname])
                let row = try #require((rows["locations"] as? [[String: Any]])?.first)
                let capabilities = try #require(row["capabilities"] as? [String: Any])
                #expect(
                    (capabilities["software"] as? [String: Any])?["openSSH"] as? Bool == true,
                    "SQ-025: anything carrying fsync/lsetstat/limits is OpenSSH")
                for feature in ["durable writes", "transfer sizing"] {
                    let line = try #require(Self.feature(feature, in: capabilities))
                    #expect(line["glyph"] as? String == "●", "SQ-025: \(feature) is at its best")
                    #expect(line["note"] == nil, "and there is no fact to state about it")
                    #expect(line["upgrade"] == nil)
                }
            }

            // "Not OpenSSH" and "not identified" are different answers. A server we have
            // not identified keeps section 8.1's original wording, because for all we know
            // it *is* an old OpenSSH that could be upgraded.
            let unknown = try await harness.addLocation(nickname: "mystery", host: "mystery")
            CapabilityCache.storeProbe(
                Self.shellProbe, extensions: [.posixRename],
                advertised: ["posix-rename@openssh.com"], locationID: unknown.id)
            let mystery = try await harness.control("status", ["name": "mystery"])
            let mysteryRow = try #require((mystery["locations"] as? [[String: Any]])?.first)
            let mysteryCapabilities = try #require(mysteryRow["capabilities"] as? [String: Any])
            #expect(
                mysteryCapabilities["software"] == nil,
                "N5: nothing at all rather than a line reading `unknown`")
            let durable = try #require(Self.feature("durable writes", in: mysteryCapabilities))
            #expect(
                (durable["upgrade"] as? String)?.contains("fsync@openssh.com") == true,
                "N5: an unidentified server keeps the upgrade line")
            #expect(durable["note"] == nil)
        }

        // MARK: fixtures

        /// The sentence that may only ever come from a server's own refusal.
        static let blameSentence = "the server cannot run the remote helper"

        /// A server the probe found a shell, a GNU `find` and a cache directory on: the
        /// shape every line of the report has something to say about.
        static var shellProbe: ServerProbe.Result {
            var probe = ServerProbe.Result()
            probe.uname = "Linux x86_64"
            probe.home = "/home/alec"
            probe.description = "uid=1000(alec) gid=1000(alec) groups=1000(alec)"
            probe.identity = ServerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [1000])
            probe.findFlavour = "gnu"
            probe.findTakesCmin = true
            probe.findTakesPrintf = true
            probe.checksumTool = "sha256sum"
            probe.cacheDirectory = "/home/alec/.cache/sshdrive"
            return probe
        }

        /// A `ForceCommand internal-sftp` account: the probe got no shell, so there is no
        /// exec channel, no sweep and no helper - a refusal the *server* made.
        static var shelllessProbe: ServerProbe.Result {
            var probe = ServerProbe.Result()
            probe.failure = "no shell access (ForceCommand)"
            return probe
        }

        /// A server that can run the helper as far as the probe can tell, so `auto` offers
        /// tier 2 and the deployment is the only thing that can refute it.
        static let helperCapable = ChangeDetectionLadder.ServerCapabilities(
            hasExecChannel: true, hasFind: true, takesCmin: true, takesPrintf: true,
            helperAvailable: true, helperEnabledForLocation: true)

        /// `capabilities.json` as one connection to this server would have left it: the
        /// probe, the extension set it advertised, and the identification string the
        /// collect connection read (`SQ-036`).
        static func cacheProbe(of profile: ServerProfile, locationID: String) {
            CapabilityCache.storeProbe(
                shellProbe, extensions: SFTPExtensionNames.parse(profile.extensions),
                advertised: profile.extensions, locationID: locationID)
            CapabilityCache.storeServerVersion(profile.identificationString, locationID: locationID)
        }

        static func feature(_ name: String, in capabilities: [String: Any]) -> [String: Any]? {
            (capabilities["features"] as? [[String: Any]])?.first { $0["feature"] as? String == name }
        }

        /// Every word the report would print, as one string: the levels, the `upgrade:`
        /// lines and the `note:` lines together, because "unreachable" has to mean from
        /// any of them.
        static func text(_ report: CapabilityReport) -> String {
            report.features.map {
                [$0.name, $0.level, $0.upgrade ?? "", $0.note ?? "", $0.consider ?? ""]
                    .joined(separator: " ")
            }.joined(separator: "\n")
        }
    }
}
