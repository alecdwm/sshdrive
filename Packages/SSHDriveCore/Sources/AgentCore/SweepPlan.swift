import Foundation

/// One tier 1 sweep, as a plan: which roots go to which `find`, in which flavour's
/// dialect, over which window, and the POSIX `sh` body that runs it (DESIGN.md sections
/// 6.4 and 9.2).
///
/// Nothing here talks to a server. The plan is built from what the probe measured and
/// turned into a script body plus a list of values; `RemoteScript` embeds the values
/// through `set --` and the body reads them as `"$@"`, so a directory named `$(rm -rf ~)`
/// never reaches a shell as text (section 9.2).
public struct SweepPlan: Sendable, Equatable {

    /// One `find` invocation's worth of roots. Section 6.4: two invocations, because
    /// `-maxdepth` applies to every starting point of one `find`, "and each is run in
    /// batches of at most 64 KB of root arguments, since the roots reach `find` as its
    /// argv and a few thousand `materialized` roots would otherwise brush a kernel's
    /// argument limit."
    public struct Batch: Sendable, Equatable {
        /// Remote paths, exactly as `find` will see them in its argv.
        public var roots: [String]
        /// False adds `-maxdepth 1`: the working-set roots are listed one level deep, the
        /// pin roots are walked whole.
        public var recursive: Bool

        public init(roots: [String], recursive: Bool) {
            self.roots = roots
            self.recursive = recursive
        }
    }

    /// Section 6.4's 64 KB of root arguments per invocation.
    public static let argumentByteBudget = 64 * 1024

    /// The GNU format, byte for byte. Section 6.4: with it "every hit arrives with its
    /// type, size, nanosecond mtime, inode, mode and owner and needs no follow-up `stat`".
    /// The field order is what `SweepParser` reads: path, type, size, mtime, inode, mode,
    /// uid, gid.
    public static let gnuPrintfFormat = #"%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0"#

    public var batches: [Batch]
    public var flavour: FindFlavour
    /// Nil is unbounded: a full sweep with no stored server stamp, which reports every
    /// file under the roots (section 6.4).
    public var windowMinutes: Int?
    /// Excluded subtrees, pruned with `-path <glob> -prune`. Already glob-escaped.
    public var excluded: [String]
    /// False means the busybox `-mmin` fallback, which misses `chmod`, `chown` and
    /// preserved-mtime writes; `status` says so.
    public var usesCmin: Bool
    /// What the probe measured, kept because `usesPrintf` is `takesPrintf` narrowed to the
    /// one flavour that has `-printf`.
    public var takesPrintf: Bool

    public init(shallowRoots: [String], recursiveRoots: [String], excluded: [String] = [],
                flavour: FindFlavour, takesCmin: Bool, takesPrintf: Bool, windowMinutes: Int?) {
        self.batches =
            SweepPlan.batched(shallowRoots, recursive: false) + SweepPlan.batched(recursiveRoots, recursive: true)
        self.flavour = flavour
        self.windowMinutes = windowMinutes
        self.excluded = excluded.map(SweepPlan.escapeGlob)
        // The probe is the authority, but busybox is checked again here. Section 6.4:
        // "busybox has no `-cmin` at all - not a pre-1.34 quirk ... every build measured:
        // BusyBox v1.36.1 as shipped by current Alpine answers `find: unrecognized:
        // -cmin`." A probe that got that wrong would not lose one field, it would make
        // every sweep on that server exit non-zero with nothing on stdout.
        self.usesCmin = takesCmin && flavour != .busybox
        self.takesPrintf = takesPrintf
    }

    /// True when the sweep asks for the `-printf` record rather than `-print0`, so every
    /// hit arrives complete and needs no follow-up `stat` over SFTP (sections 6.4, 5.3).
    /// Only GNU `find` has `-printf`; BSD and busybox get bare paths.
    public var usesPrintf: Bool { takesPrintf && flavour == .gnu }

    // MARK: Batching

    /// Splits roots into invocations of at most `argumentByteBudget` bytes of argv.
    ///
    /// Each root is charged its UTF-8 length plus one, which is the NUL the kernel copies
    /// with it; that is the thing the limit is actually on. A single root longer than the
    /// whole budget still gets a batch of its own - dropping it would silently stop
    /// watching a directory, which is worse than one oversized `execve`.
    private static func batched(_ roots: [String], recursive: Bool) -> [Batch] {
        var batches: [Batch] = []
        var current: [String] = []
        var used = 0
        for root in roots {
            let cost = root.utf8.count + 1
            if !current.isEmpty, used + cost > argumentByteBudget {
                batches.append(Batch(roots: current, recursive: recursive))
                current = []
                used = 0
            }
            current.append(root)
            used += cost
        }
        if !current.isEmpty { batches.append(Batch(roots: current, recursive: recursive)) }
        return batches
    }

    // MARK: Glob escaping

    /// Section 6.4: "`-path` takes a glob, so `*`, `?`, `[` and `\` in an excluded path
    /// are backslash-escaped before the pattern is embedded: `-path 't/[x]'` does not match
    /// a directory named `[x]` (verified on GNU `find`), and an exclusion that silently
    /// stopped applying would put an excluded subtree back under the recursive watch."
    ///
    /// The backslash goes first, or it would escape the escapes added after it.
    public static func escapeGlob(_ path: String) -> String {
        var out = String()
        out.reserveCapacity(path.count)
        for character in path {
            switch character {
            case "\\", "*", "?", "[":
                out.append("\\")
                out.append(character)
            default:
                out.append(character)
            }
        }
        return out
    }

    // MARK: The script

    /// The POSIX `sh` body for the exec channel, and the values it reads as `"$@"`.
    ///
    /// Nothing from the user is in the body. Section 9.2: "a directory on a shared NAS
    /// named `$(rm -rf ~)` must never reach that shell", so every root and every excluded
    /// glob is in `arguments`, which `RemoteScript` single-quotes into one `set --`, and
    /// the body only ever refers to `"$@"` and to positional parameters it has shifted.
    ///
    /// **The argument layout.** `RemoteScript` passes one `set --` list for the whole
    /// script, so the body has to find its own way through it:
    ///
    ///     [excluded globs..., batch1 count, batch1 roots..., batch2 count, batch2 roots..., …]
    ///
    /// The excluded globs come first and have no count in front of them, because the body
    /// needs them in hand before the first `find` runs and there are exactly as many
    /// `__sd_xN="$1"; shift` lines generated as there are globs. The batches then follow in
    /// the count-led form: a count, that many roots, the next count, and so on, walked with
    /// `shift`. Whether a batch is recursive is not in the arguments at all - it is baked
    /// into the generated `find` line for that batch, which is ours and not the user's.
    ///
    /// **How one batch is isolated.** POSIX `sh` has no arrays and `shift` only drops from
    /// the front, so a batch's roots are rotated to the back (`set -- "$@" "$1"; shift`,
    /// `n` times) and the rest is then shifted off the front, leaving exactly that batch's
    /// roots in `"$@"`. That happens inside a subshell, so the parent's list survives for
    /// the next batch, and the parent then shifts the batch off in the ordinary way.
    ///
    /// The server's own clock is printed first, before any `find` runs. Section 6.4: "`N`
    /// is computed from the **server's** clock, never the Mac's ... Measured on the Mac's
    /// clock, a server running a few minutes behind would silently miss every change until
    /// the 30-minute insurance sweep."
    ///
    /// Every invocation ends in `|| true`. One unreadable root makes `find` exit non-zero,
    /// and losing the whole sweep for it would mean losing every other root's changes too.
    public func script() -> (body: String, arguments: [String]) {
        var arguments: [String] = []
        var lines: [String] = []

        // The server's clock, then a NUL, in two printfs: a single `printf '%s\000'` is
        // fine but the split form is what RemoteScript uses for the sentinel and there is
        // no reason for two spellings. An empty substitution - no `date` - leaves an empty
        // first record, which the parser reports as an unknown server time rather than as
        // the epoch.
        lines.append("printf '%s' \"$(date +%s 2>/dev/null)\"")
        lines.append("printf '\\000'")

        for (offset, glob) in excluded.enumerated() {
            arguments.append(glob)
            lines.append("__sd_x\(offset + 1)=\"$1\"")
            lines.append("shift")
        }

        for (offset, batch) in batches.enumerated() {
            arguments.append(String(batch.roots.count))
            arguments.append(contentsOf: batch.roots)
            lines.append("# batch \(offset + 1): \(batch.recursive ? "recursive" : "shallow")")
            lines.append("__sd_n=$1")
            lines.append("shift")
            lines.append("(")
            // Rotate this batch's roots to the back, then shift the remaining batches off
            // the front. What is left is exactly this batch.
            lines.append("  __sd_i=0")
            lines.append("  while [ \"$__sd_i\" -lt \"$__sd_n\" ]; do")
            lines.append("    set -- \"$@\" \"$1\"")
            lines.append("    shift")
            lines.append("    __sd_i=$((__sd_i + 1))")
            lines.append("  done")
            lines.append("  while [ $# -gt \"$__sd_n\" ]; do shift; done")
            lines.append("  set -- \"$@\" \(expression(recursive: batch.recursive))")
            lines.append("  find \"$@\" || true")
            lines.append(") || true")
            lines.append("__sd_i=0")
            lines.append("while [ \"$__sd_i\" -lt \"$__sd_n\" ]; do")
            lines.append("  shift")
            lines.append("  __sd_i=$((__sd_i + 1))")
            lines.append("done")
        }

        return (lines.joined(separator: "\n") + "\n", arguments)
    }

    /// The `find` expression appended after the roots, in the order section 6.4 states it:
    /// the depth limit, then the prunes, then the type test, then the time test, then the
    /// output.
    ///
    /// The prunes come **before** the type test and are `-o`-joined, so a pruned directory
    /// is never descended into and never printed: `-a` binds tighter than `-o`, so the
    /// output action belongs to the last branch only.
    ///
    /// Both files and directories are matched (section 6.4): "a directory's ctime changes
    /// on create, delete and rename inside it, but an in-place edit changes only the file's
    /// own, so the file test is needed too." There is no `-xdev`: a NAS root routinely
    /// contains separate mounts, and containment comes from not following links (section
    /// 9.1), not from staying on one filesystem.
    private func expression(recursive: Bool) -> String {
        var parts: [String] = []
        if !recursive { parts.append("-maxdepth 1") }
        for offset in excluded.indices {
            parts.append("-path \"$__sd_x\(offset + 1)\" -prune -o")
        }
        parts.append("'(' -type d -o -type f ')'")
        if let windowMinutes {
            // `-cmin` (change time) rather than `-mmin`: ctime moves whenever mtime does,
            // and also on chmod, chown and on writes that preserve mtime (rsync -t, cp -p,
            // touch -r), all of which change our content or metadata version (section 5.3).
            // busybox has none, so it takes -mmin and loses those cases, which `status`
            // reports as a note. An integer of our own is the only literal in this string.
            parts.append("\(usesCmin ? "-cmin" : "-mmin") -\(max(1, windowMinutes))")
        }
        parts.append(usesPrintf ? "-printf '\(SweepPlan.gnuPrintfFormat)'" : "-print0")
        return parts.joined(separator: " ")
    }
}

/// Which `find` the probe found. The three differ in exactly two places that matter here:
/// `-cmin` (busybox has none) and `-printf` (only GNU has it).
public enum FindFlavour: String, Sendable {
    case gnu
    case bsd
    case busybox
}
