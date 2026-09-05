import Foundation
import Config
import SFTP
import SSHProcess

/// Where the remote helper of section 6.4 tier 2 has got to, as the report has to say it.
///
/// The report is one sentence per feature and the user reads it as the truth about the
/// server, so "not running" and "cannot run" are different states and must never be
/// printed as the same one. `add` reaches this type in the window where the tier has been
/// chosen and the binary is still going up the wire (2026-09-05); `status` reaches it a
/// moment later with the stream up.
public enum HelperState: Equatable, Sendable {
    /// The stream is up: its own version, the directory it runs from, and the mechanism
    /// its `ready` line named.
    case running(version: String, directory: String, mechanism: String)
    /// The server can run it and the deployment has not settled yet. Never an `upgrade:`
    /// line: there is nothing for the user to do.
    case deploying
    /// The server cannot run it, with the concrete reason: no shell, no writable
    /// directory, an unsupported `uname`, a refused channel, or a runtime drop.
    case unavailable(String)
    /// `sshdrive set <name> helper off`.
    case off

    public var isRunning: Bool { if case .running = self { return true } else { return false } }
}

/// The capability report of DESIGN.md section 8.1.
///
/// "Every line in the report follows one shape so all permutations read the same way: a
/// level glyph, the feature name, the level in use, and, whenever the level is not the
/// best one, an indented `upgrade:` line naming the concrete requirement."
///
/// The catalogue is data, not prose: eight features, each with its levels best-first, the
/// level in use, and the sentence that names the next one. `--json` emits exactly these
/// objects, and the CLI renders the same values as text, so the two can never disagree.
///
/// It lives in `AgentCore` rather than beside the agent's plumbing so the rendering can be
/// unit-tested from a recorded probe and a recorded extension set, which is what
/// 2026-09-05's false "the server cannot run the remote helper" cost us.
public struct CapabilityReport {

    public struct Feature {
        public var name: String
        /// The level actually in use.
        public var level: String
        /// The best level this feature has.
        public var best: String
        /// `●` best available, `◐` a fallback is in use, `○` off entirely.
        public var glyph: String
        /// Named only when the level is not the best one.
        public var upgrade: String?
        /// A runtime downgrade, a user-forced setting, or ACL evidence (section 8.1).
        public var note: String?
        /// In place of `upgrade:` where the fix is a setting rather than a server change.
        public var consider: String?

        public var asJSON: [String: Any] {
            var out: [String: Any] = [
                "feature": name, "level": level, "best": best, "glyph": glyph,
            ]
            if let upgrade { out["upgrade"] = upgrade }
            if let note { out["note"] = note }
            if let consider { out["consider"] = consider }
            return out
        }
    }

    public var features: [Feature]
    public var probedAt: Date
    /// True when the values came from `capabilities.json` rather than a live probe.
    public var cached: Bool
    public var serverFreeSpace: String?
    /// Every extension name the server advertised in SSH_FXP_VERSION, as recorded at
    /// connect. Shown by `--json` so an "it did not advertise it" line can be checked
    /// against the server rather than believed (2026-09-05).
    public var advertisedExtensions: [String] = []

    public var optimalCount: Int { features.filter { $0.glyph == "●" }.count }

    public var asJSON: [String: Any] {
        var out: [String: Any] = [
            "features": features.map(\.asJSON),
            "probedAt": probedAt.timeIntervalSince1970,
            "cached": cached,
            "optimal": optimalCount,
            "total": features.count,
        ]
        if let serverFreeSpace { out["serverFreeSpace"] = serverFreeSpace }
        if !advertisedExtensions.isEmpty { out["sftpExtensions"] = advertisedExtensions }
        return out
    }

    /// The fixed, short ignore list of section 6.4, printed under the change-detection
    /// line whenever the helper is the running tier ("the list is printed on the
    /// change-detection line of `sshdrive status`").
    public static let helperIgnores = [".sshdrive-upload-*", ".*.swp", "*~", ".#*", "4913"]

    /// What `add` and `status` print while the helper is on its way up. No `upgrade:`
    /// line goes with it: nothing is wrong and nothing is asked of the user.
    public static let deployingNote =
        "the helper is being deployed on this connection; `sshdrive status` shows it once "
        + "it is up"

    /// Builds the catalogue from one probe, the recorded SFTP extension set and the
    /// location's settings.
    ///
    /// - Parameter helper: where tier 2 has got to. `.running` is the only state that
    ///   describes the change-detection and rename lines as the helper's, because the
    ///   ladder offers the tier from the probe before anything has been deployed and a
    ///   report written in that window would claim events from a helper that has not
    ///   started. `.deploying` says so plainly rather than reaching for the sweep
    ///   branch's "the server cannot run the remote helper", which was false for every
    ///   server that could (2026-09-05).
    public static func make(
        probe: ServerProbe.Result,
        extensions: SFTPServerExtensions,
        location: Location,
        allowsExecChannel: Bool,
        probedAt: Date,
        cached: Bool,
        freeSpace: String? = nil,
        advertisedExtensions: [String] = [],
        activeTier: String? = nil,
        helper: HelperState = .unavailable("the server cannot run the remote helper")
    ) -> CapabilityReport {
        let shell = probe.hasShellAccess && allowsExecChannel
        var features: [Feature] = []

        // 1. Change detection: helper · sweep · poll.
        features.append(changeDetection(
            probe: probe, location: location, shell: shell, activeTier: activeTier,
            helper: helper))

        // 2. Rename detection: rename events (helper) · delete+create.
        let helperRunning = helper.isRunning
        var rename = Feature(
            name: "rename detection",
            level: helperRunning
                ? "helper move events"
                : "delete + create (identifiers not preserved on remote renames)",
            best: "helper move events", glyph: helperRunning ? "●" : "◐",
            upgrade: helperRunning ? nil : "the helper, which needs shell access")
        if case .deploying = helper {
            rename.upgrade = nil
            rename.note = deployingNote
        }
        features.append(rename)

        // 3. Change evidence: ns-mtime + inode (helper or GNU sweep) · size + mtime.
        let gnuSweep = helperRunning || (shell && probe.findTakesPrintf)
        features.append(Feature(
            name: "change evidence",
            level: gnuSweep ? "ns-mtime + inode" : "size + mtime (same-second rewrites of equal size are missed)",
            best: "ns-mtime + inode",
            glyph: gnuSweep ? "●" : "◐",
            upgrade: gnuSweep ? nil
                : (shell
                    ? "a `find` that takes -printf (GNU findutils), or the helper"
                    : "shell access")))

        // 4. Permissions: mapped (`id` available) · everything writable.
        features.append(permissions(probe: probe, location: location, shell: shell))

        // 5. Atomic overwrite: posix-rename@openssh.com · remove+rename.
        let posix = extensions.contains(.posixRename)
        features.append(Feature(
            name: "atomic overwrite",
            level: posix ? "posix-rename@openssh.com" : "remove + rename (brief window where the file is absent)",
            best: "posix-rename@openssh.com",
            glyph: posix ? "●" : "◐",
            upgrade: posix ? nil
                : "posix-rename@openssh.com (OpenSSH >= 4.9) - server did not advertise it"))

        // 6. Durable writes: fsync@openssh.com · none.
        let fsync = extensions.contains(.fsync)
        features.append(Feature(
            name: "durable writes",
            level: fsync ? "fsync@openssh.com" : "none; uploads are complete when the server acknowledges the write",
            best: "fsync@openssh.com",
            glyph: fsync ? "●" : "◐",
            upgrade: fsync ? nil : "fsync@openssh.com (OpenSSH >= 6.3)"))

        // 7. Transfer sizing: limits@openssh.com · conservative 32 KB requests.
        let limits = extensions.contains(.limits)
        features.append(Feature(
            name: "transfer sizing",
            level: limits ? "limits@openssh.com" : "conservative 32 KB requests",
            best: "limits@openssh.com",
            glyph: limits ? "●" : "◐",
            upgrade: limits ? nil : "limits@openssh.com (OpenSSH >= 8.5)"))

        // 8. Collision-safe create: server-enforced · lstat preflight.
        // "a server whose plain `rename` refuses to overwrite, as OpenSSH does". A server
        // that advertises OpenSSH's own extensions is one; `set create-check lstat` forces
        // the preflight regardless (section 5.5, section 8).
        let forced = location.createCheck == .lstat
        let serverEnforced = !forced && !extensions.isEmpty
        features.append(Feature(
            name: "collision-safe create",
            level: serverEnforced
                ? "server-enforced"
                : "lstat preflight, one extra round trip per create/rename",
            best: "server-enforced",
            glyph: serverEnforced ? "●" : "◐",
            upgrade: serverEnforced ? nil
                : (forced ? nil : "a server whose plain rename refuses to overwrite, as OpenSSH does"),
            note: forced ? "forced by create-check lstat" : nil))

        return CapabilityReport(
            features: features, probedAt: probedAt, cached: cached, serverFreeSpace: freeSpace,
            advertisedExtensions: advertisedExtensions)
    }

    private static func changeDetection(
        probe: ServerProbe.Result, location: Location, shell: Bool, activeTier: String?,
        helper: HelperState
    ) -> Feature {
        let best = "helper (push, ~1s)"
        // The running tier, at its own best level. Section 8.1's example line is
        // `helper 1.2.0 at ~/.cache/sshdrive (push, ~1s)`; the mechanism comes from the
        // helper's own `ready` line, so a kqueue build says what it really does.
        if case let .running(version, directory, mechanism) = helper {
            let shape = mechanism.contains("kqueue") ? "kqueue + 60s sweep" : "push, ~1s"
            return Feature(
                name: "change detection",
                level: "helper \(version) at \(directory) (\(shape))",
                best: best, glyph: "●",
                note: "ignores: " + helperIgnores.joined(separator: "  "))
        }
        // A user-forced watch-mode below the best available shows ◐ with `note: forced by
        // watch-mode <x>` and no `upgrade:` line (section 8.1). Poll is also where a
        // location with no shell at all lands.
        // The ladder, not the probe, is the authority on which tier is running once the
        // location has been up: a sweep that failed drops to poll for the session even
        // though the probe still says the shell is there (section 6.4).
        if location.watchMode == .poll || !shell || activeTier == "poll" {
            var note: String?
            if location.watchMode == .poll {
                note = "forced by watch-mode poll"
            } else if case let .unavailable(reason) = helper, activeTier == "poll" {
                note = reason
            } else if !probe.failure.isEmpty {
                note = probe.failure
            }
            return Feature(
                name: "change detection",
                level: "poll (SFTP readdir every 60s while active)",
                best: best, glyph: "◐",
                upgrade: location.watchMode == .poll
                    ? nil
                    : "shell access on the server enables the helper (push); plain shell "
                        + "access enables remote sweep",
                note: note)
        }
        let sweepLevel = probe.findTakesCmin
            ? "sweep (find -cmin over the root set)"
            : "sweep (find -mmin over the root set; a rename or chmod moves ctime, not mtime, "
                + "so those are missed until the next full sweep)"
        // Section 8.1: "A runtime downgrade ... shows the level in use with ◐ and a
        // `note:` line giving the reason and time, in addition to the `upgrade:` line."
        var note: String
        var upgrade: String? = "the remote helper (push events, real renames)"
        switch helper {
        case .running:
            note = ""  // handled above
        case .deploying:
            note = deployingNote
            upgrade = nil
        case .off:
            note = "helper off (user setting); `sshdrive set \(location.displayName) helper on` "
                + "turns it back on"
        case let .unavailable(reason):
            note = reason
        }
        if location.watchMode == .sweep {
            note = "forced by watch-mode sweep"
            upgrade = nil
        }
        return Feature(
            name: "change detection", level: sweepLevel, best: best, glyph: "◐",
            upgrade: upgrade, note: note)
    }

    private static func permissions(
        probe: ServerProbe.Result, location: Location, shell: Bool
    ) -> Feature {
        if location.permissions == .none {
            return Feature(
                name: "permissions", level: "everything shown writable",
                best: "mapped to Finder capabilities", glyph: "◐", upgrade: nil,
                note: "forced by permissions none")
        }
        guard shell, probe.identity.isKnown else {
            return Feature(
                name: "permissions",
                level: "everything shown writable; permission errors appear after upload",
                best: "mapped to Finder capabilities", glyph: "◐",
                upgrade: "shell access")
        }
        return Feature(
            name: "permissions", level: "mapped (\(probe.description))",
            best: "mapped to Finder capabilities", glyph: "●")
    }
}
