import Foundation

import Logging
import SFTP
import SSHProcess

/// The capability probe of DESIGN.md section 8.1, run on every connection.
///
/// "It consists of the SFTP `extensions` list from the SFTP init reply, whether that reply
/// arrived clean or behind rc-file output (section 9.2), whether an exec channel opens and
/// delivers its sentinel, and one shell script (section 9.2) that reports `uname -sm`,
/// `id -u` and `id -G` (two commands: POSIX `id` accepts only one of `-u`, `-g`, `-G` per
/// invocation), `$HOME` as the account spells it (section 5.7), the `find` flavour and
/// whether it takes `-cmin`, the presence of `sha256sum`/`shasum`, and a writable,
/// executable cache directory."
///
/// One exec channel and one script for all of it, because an exec channel is the scarcest
/// thing the channel budget has (section 6.1): on a `MaxSessions 2` server there is
/// exactly one, and the sweep and the helper want it too.
///
/// Where there is no shell - a `ForceCommand internal-sftp` account, or a `MaxSessions 1`
/// server that cannot afford the channel at all - everything below `uname` stays unknown
/// and section 5.4's SFTP-only rule applies: full capabilities, and permission errors
/// learned from the sync error list.
public enum ServerProbe {

    /// What the probe found. The identity half is section 5.4's; the rest is section 8.1's
    /// capability report.
    public struct Result: Sendable {
        public init() {}
        public var identity: ServerIdentity = .unknown
        /// What the account printed before our sentinel, which section 9.2 says `status`
        /// shows.
        public var shellPrefix: String = ""
        /// Empty when the probe worked. Non-empty means no shell access.
        public var failure: String = ""
        /// `id`'s own line, for `sshdrive show`.
        public var description: String = ""

        /// `uname -s` and `uname -m`, e.g. "Linux x86_64". Empty when there is no shell.
        public var uname: String = ""
        /// `$HOME` as the account spells it (section 5.7).
        public var home: String = ""
        /// "gnu", "busybox", "bsd" or "" - what `find` is.
        public var findFlavour: String = ""
        public var findTakesCmin = false
        public var findTakesPrintf = false
        /// `sha256sum`, `shasum`, or empty. The helper's verification needs one (6.4).
        public var checksumTool: String = ""
        /// A writable, executable directory for the helper, or empty with `cacheNote`
        /// saying why.
        public var cacheDirectory: String = ""
        public var cacheNote: String = ""

        public var hasShellAccess: Bool { failure.isEmpty }
    }

    /// NUL-delimited records so nothing a shell prints can be confused with a value, and
    /// `id` invoked three separate ways so a busybox `id` that does not take `-G` still
    /// yields the primary pair. POSIX `sh` only: this runs under dash and busybox ash as
    /// often as under bash.
    public static let script = """
        printf '%s\\000' "$(uname -s 2>/dev/null) $(uname -m 2>/dev/null)"
        printf '%s\\000' "$(id -u 2>/dev/null)"
        printf '%s\\000' "$(id -g 2>/dev/null)"
        printf '%s\\000' "$(id -G 2>/dev/null)"
        printf '%s\\000' "$(id -un 2>/dev/null)"
        printf '%s\\000' "$HOME"
        if find . -maxdepth 0 -cmin -60 >/dev/null 2>&1; then printf '%s\\000' yes
        else printf '%s\\000' no; fi
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then printf '%s\\000' yes
        else printf '%s\\000' no; fi
        printf '%s\\000' "$(find --version 2>/dev/null | head -1; busybox 2>/dev/null | head -1)"
        printf '%s\\000' "$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null)"
        probe_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sshdrive"
        if mkdir -p "$probe_dir" 2>/dev/null; then
          probe_file="$probe_dir/.sshdrive-probe.$$"
          probe_rc=0
          printf '#!/bin/sh\\nexit 7\\n' > "$probe_file" 2>/dev/null || probe_rc=1
          if [ "$probe_rc" = 0 ]; then
            chmod 755 "$probe_file" 2>/dev/null || probe_rc=1
          fi
          if [ "$probe_rc" = 0 ]; then
            "$probe_file" >/dev/null 2>&1
            [ "$?" = 7 ] || probe_rc=2
          fi
          rm -f "$probe_file" 2>/dev/null
          case "$probe_rc" in
            0) printf '%s\\000' "exec $probe_dir" ;;
            2) printf '%s\\000' "noexec $probe_dir" ;;
            *) printf '%s\\000' "unwritable $probe_dir" ;;
          esac
        else
          printf '%s\\000' "nodir $probe_dir"
        fi
        """

    /// How many NUL-delimited records the script above prints.
    public static let recordCount = 11

    public static func run(master: SSHMaster, timeout: TimeInterval = 25) async -> Result {
        var result = Result()
        let remote = RemoteScript(body: script)
        let channel: ExecChannel
        do {
            channel = try await master.openExecChannel(script: remote, readinessDeadline: timeout)
        } catch let error as SSHProcessError {
            // Section 9.2: a ForceCommand account answers with a plain sentence or with
            // SFTP framing, and is reported as "no shell access", never as unusable
            // output. Either way the identity is unknown and section 5.4's SFTP-only rule
            // takes over.
            result.failure = "\(error.localizedDescription)"
            return result
        } catch {
            result.failure = "\(error)"
            return result
        }
        defer { channel.close() }

        result.shellPrefix = String(decoding: channel.prefix, as: UTF8.self)

        var payload = Data()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while Date() < deadline {
                let chunk = try await channel.stream.read(upTo: 16 * 1024, deadline: deadline)
                if chunk.isEmpty { break }
                payload.append(chunk)
                if payload.filter({ $0 == 0 }).count >= recordCount { break }
            }
        } catch {
            result.failure = "the shell did not answer in time"
            return result
        }

        let records = payload.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        func record(_ index: Int) -> String { index < records.count ? records[index] : "" }

        result.uname = record(0)
        guard records.count >= 4, let uid = UInt32(record(1)), let gid = UInt32(record(2)) else {
            result.failure = "the shell did not answer `id`"
            return result
        }
        let groups = Set(record(3).split(separator: " ").compactMap { UInt32($0) })
        result.identity = ServerIdentity(uid: uid, gid: gid, supplementaryGroups: groups)
        let name = record(4)
        result.description =
            "uid=\(uid)\(name.isEmpty ? "" : "(\(name))") gid=\(gid) groups=\(groups.sorted().map(String.init).joined(separator: ","))"
        result.home = record(5)
        result.findTakesCmin = record(6) == "yes"
        result.findTakesPrintf = record(7) == "yes"
        result.findFlavour = flavour(fromVersionText: record(8), takesCmin: result.findTakesCmin)
        result.checksumTool = record(9)

        let cache = record(10).split(separator: " ", maxSplits: 1).map(String.init)
        switch cache.first ?? "" {
        case "exec":
            result.cacheDirectory = cache.count > 1 ? cache[1] : ""
        case "noexec":
            result.cacheNote = "cache directory is noexec"
        case "unwritable", "nodir":
            result.cacheNote = "no writable directory for helper"
        default:
            result.cacheNote = "no writable directory for helper"
        }

        Log.agent.notice(
            "server probe: \(result.uname, privacy: .public), \(result.description, privacy: .public), find \(result.findFlavour, privacy: .public)"
        )
        return result
    }

    /// GNU `find` prints `find (GNU findutils) 4.x`; busybox prints its own banner and no
    /// `--version` at all. No busybox build has `-cmin` (2026-09-04, testbed, section 6.4),
    /// so "no `--version` and no `-cmin`" is the busybox signature and everything else
    /// without a GNU banner is treated as BSD.
    public static func flavour(fromVersionText text: String, takesCmin: Bool) -> String {
        let lower = text.lowercased()
        if lower.contains("gnu findutils") { return "gnu" }
        if lower.contains("busybox") { return "busybox" }
        if !takesCmin { return "busybox" }
        return "bsd"
    }
}
