import Foundation
import Config
import SFTP
import SSHProcess

/// The capability report of DESIGN.md section 8.1.
///
/// "Every line in the report follows one shape so all permutations read the same way: a
/// level glyph, the feature name, the level in use, and, whenever the level is not the
/// best one, an indented `upgrade:` line naming the concrete requirement."
///
/// The catalogue is data, not prose: eight features, each with its levels best-first, the
/// level in use, and the sentence that names the next one. `--json` emits exactly these
/// objects, and the CLI renders the same values as text, so the two can never disagree.
struct CapabilityReport {

    struct Feature {
        var name: String
        /// The level actually in use.
        var level: String
        /// The best level this feature has.
        var best: String
        /// `●` best available, `◐` a fallback is in use, `○` off entirely.
        var glyph: String
        /// Named only when the level is not the best one.
        var upgrade: String?
        /// A runtime downgrade, a user-forced setting, or ACL evidence (section 8.1).
        var note: String?
        /// In place of `upgrade:` where the fix is a setting rather than a server change.
        var consider: String?

        var asJSON: [String: Any] {
            var out: [String: Any] = [
                "feature": name, "level": level, "best": best, "glyph": glyph,
            ]
            if let upgrade { out["upgrade"] = upgrade }
            if let note { out["note"] = note }
            if let consider { out["consider"] = consider }
            return out
        }
    }

    var features: [Feature]
    var probedAt: Date
    /// True when the values came from `capabilities.json` rather than a live probe.
    var cached: Bool
    var serverFreeSpace: String?

    var optimalCount: Int { features.filter { $0.glyph == "●" }.count }

    var asJSON: [String: Any] {
        var out: [String: Any] = [
            "features": features.map(\.asJSON),
            "probedAt": probedAt.timeIntervalSince1970,
            "cached": cached,
            "optimal": optimalCount,
            "total": features.count,
        ]
        if let serverFreeSpace { out["serverFreeSpace"] = serverFreeSpace }
        return out
    }

    /// Builds the catalogue from one probe and the location's settings.
    ///
    /// - Parameter helperAvailable: false for the whole of v1 so far - the remote helper is
    ///   milestone 9, and until it ships `auto` tops out at sweep (section 6.4, section 12).
    ///   Change detection therefore reports `◐ sweep` with a `note:` saying why, which is
    ///   exactly section 8.1's rule for "the helper is not the active tier on a server with
    ///   shell access".
    static func make(
        probe: ServerProbe.Result,
        extensions: SFTPServerExtensions,
        location: Location,
        budget: ChannelBudget,
        probedAt: Date,
        cached: Bool,
        helperAvailable: Bool = false,
        freeSpace: String? = nil,
        activeTier: String? = nil,
        downgradeNote: String? = nil
    ) -> CapabilityReport {
        let shell = probe.hasShellAccess && budget.allowsExecChannel
        var features: [Feature] = []

        // 1. Change detection: helper · sweep · poll.
        features.append(changeDetection(
            probe: probe, location: location, shell: shell, helperAvailable: helperAvailable,
            activeTier: activeTier, downgradeNote: downgradeNote))

        // 2. Rename detection: rename events (helper) · delete+create.
        features.append(Feature(
            name: "rename detection",
            level: "delete + create (identifiers not preserved on remote renames)",
            best: "helper move events", glyph: "◐",
            upgrade: "the helper, which needs shell access",
            note: shell ? "the remote helper is not in this release" : nil))

        // 3. Change evidence: ns-mtime + inode (helper or GNU sweep) · size + mtime.
        let gnuSweep = shell && probe.findTakesPrintf
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
            features: features, probedAt: probedAt, cached: cached, serverFreeSpace: freeSpace)
    }

    private static func changeDetection(
        probe: ServerProbe.Result, location: Location, shell: Bool, helperAvailable: Bool,
        activeTier: String? = nil, downgradeNote: String? = nil
    ) -> Feature {
        let best = "helper (push, ~1s)"
        // Section 8.1: "A runtime downgrade ... shows the level in use with ◐ and a
        // `note:` line giving the reason and time, in addition to the `upgrade:` line."
        // The ladder, not the probe, is the authority on which tier is running once the
        // location has been up: a sweep that failed drops to poll for the session even
        // though the probe still says the shell is there (section 6.4).
        let running = activeTier ?? (shell && location.watchMode != .poll ? "sweep" : "poll")
        guard shell, running != "poll" else {
            return Feature(
                name: "change detection",
                level: "poll (SFTP readdir every 60s while active)",
                best: best, glyph: "◐",
                upgrade: location.watchMode == .poll
                    ? nil
                    : "shell access on the server enables the helper (push); plain shell "
                        + "access enables remote sweep",
                note: downgradeNote
                    ?? (location.watchMode == .poll
                        ? "forced by watch-mode poll"
                        : (probe.failure.isEmpty ? nil : probe.failure)))
        }
        // A user-forced watch-mode below the best available shows ◐ with `note: forced by
        // watch-mode <x>` and no `upgrade:` line (section 8.1).
        if location.watchMode == .poll {
            return Feature(
                name: "change detection",
                level: "poll (SFTP readdir every 60s while active)",
                best: best, glyph: "◐", upgrade: nil,
                note: "forced by watch-mode poll")
        }
        let sweepLevel = probe.findTakesCmin
            ? "sweep (find -cmin over the root set)"
            : "sweep (find -mmin over the root set; a rename or chmod moves ctime, not mtime, "
                + "so those are missed until the next full sweep)"
        var note: String
        if !location.helper {
            note = "helper off (user setting); `sshdrive set \(location.displayName) helper on` turns it back on"
        } else if !helperAvailable {
            note = "the remote helper ships in a later release, so auto tops out at sweep"
        } else if probe.cacheDirectory.isEmpty {
            note = probe.cacheNote.isEmpty ? "no writable directory for helper" : probe.cacheNote
        } else {
            note = "helper unsupported: \(probe.uname.isEmpty ? "unknown" : probe.uname)"
        }
        if location.watchMode == .sweep { note = "forced by watch-mode sweep" }
        if let downgradeNote { note = downgradeNote }
        return Feature(
            name: "change detection", level: sweepLevel, best: best, glyph: "◐",
            upgrade: location.watchMode == .sweep ? nil : "the remote helper (push events, real renames)",
            note: note)
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
