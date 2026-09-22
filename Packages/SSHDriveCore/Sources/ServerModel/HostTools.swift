import Foundation
import SSHProcess

/// What the **box the tests run on** provides, as distinct from what a `ServerProfile` says
/// a server provides.
///
/// `ServerModel` runs real shells, a real `find` and a real filesystem, so a handful of the
/// scenarios are bounded by the host rather than by the model. Those bounds are measured
/// here, once per process, and named — never assumed, and never worked around by quietly
/// weakening the assertion that met them. A scenario that cannot run on this box skips with
/// the sentence this type returns (docs/design/testing.md, the same rule as
/// `ScriptShell.skipReason`).
///
/// Three of them bound what the Darwin half of the suite can cover:
/// - `SQ-080`: APFS refuses a filename that is not valid UTF-8, so `H7`'s premise cannot
///   exist on a Mac at all.
/// - `SQ-081`: macOS's `/usr/bin/find` is BSD, not GNU findutils, so a row calibrated to
///   `-printf` has no `find` to run against there.
/// - `SQ-085`: `PATH_MAX` is 1024 on macOS against 4096 on Linux, so a harness tree deep
///   enough to outrun a channel's buffer must be sized from the box, not written out.
public enum HostTools {

    // MARK: - `find`

    /// The flavour of **this box's own** `find`, decided by what it accepts rather than by
    /// what it prints (`SQ-002` is the whole reason a banner is not the test): `-printf` is
    /// GNU findutils' alone, `-cmin` is GNU's and BSD's, and neither is busybox's.
    ///
    /// `nil` where the box has no usable `find` at all.
    public static let findFlavour: ServerFindFlavour? = probeFindFlavour()

    /// The flavour a sweep row should use when it only needs *a* `find` that takes a time
    /// test, and does not care which: `-cmin` is what every such row turns on, and GNU and
    /// BSD both have it.
    ///
    /// This is what keeps `H4` - a scenario about the sweep **window**, not about a `find`
    /// flavour - running on a box with either one, rather than skipping on the Mac for a
    /// reason that has nothing to do with what it asserts.
    public static func flavourTakingCmin() throws -> ServerFindFlavour {
        guard let host = findFlavour, host.takesCmin else {
            throw ServerModelUnavailable(
                reason: "SQ-081: this box's `find` takes no `-cmin` "
                    + "(\(findFlavour?.rawValue ?? "no find at all")), so a windowed sweep cannot "
                    + "be run here")
        }
        return host
    }

    private static func probeFindFlavour() -> ServerFindFlavour? {
        guard let find = ["/usr/bin/find", "/bin/find"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let environment = ProcessInfo.processInfo.environment

        func accepts(_ arguments: [String]) -> Bool {
            guard let result = try? Spawn.capture(
                executable: find, argv: [find] + arguments, environment: environment, timeout: 10)
            else { return false }
            return result.exit.status == 0
        }

        // A directory of our own rather than `.`: the working directory of a test process
        // is not ours to walk, and `-maxdepth 0` keeps even this to one `stat`.
        let probe = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sd-find-\(shortID())")
        try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        let path = probe.path

        guard accepts([path, "-maxdepth", "0"]) else { return nil }
        if accepts([path, "-maxdepth", "0", "-printf", ""]) { return .gnu }
        if accepts([path, "-maxdepth", "0", "-cmin", "-1"]) { return .bsd }
        return .busybox
    }

    // MARK: - The filesystem

    /// The longest path this box's filesystem calls will take. 1024 on macOS, 4096 on
    /// Linux (`SQ-085`): a harness that writes a tree deep enough to outrun a channel's
    /// buffer has to size its names from this, or it silently creates nothing and the
    /// scenario passes over an empty directory.
    public static var pathMax: Int { Int(PATH_MAX) }

    /// Whether this box's filesystem will hold a filename whose bytes are not valid UTF-8.
    ///
    /// `SQ-080`: APFS will not - `mkdir` answers `EILSEQ` - so a non-UTF-8 sweep root
    /// cannot be made to exist on a Mac at all, and `H7`'s real-filesystem half
    /// can only ever run on Linux. Measured rather than assumed, because the answer belongs
    /// to the filesystem `$TMPDIR` is on and not to the OS.
    public static let filesystemTakesNonUTF8Names: Bool = probeNonUTF8Names()

    /// The sentence a scenario that needs such a name skips with.
    public static let nonUTF8NameSkipReason =
        "SQ-080: this box's filesystem refuses a filename that is not valid UTF-8 (APFS answers "
        + "EILSEQ), so a non-UTF-8 sweep root cannot be made to exist here. The rule "
        + "itself - that such a root is dropped from the `find` argv and listed at tier 0 in the "
        + "same cycle - keeps its full coverage on Linux, where the name can be created."

    private static func probeNonUTF8Names() -> Bool {
        var bytes = Array((NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sd-raw-\(shortID())-").utf8)
        bytes.append(0xFF)
        var path = bytes.map { CChar(bitPattern: $0) }
        path.append(0)
        guard mkdir(path, 0o755) == 0 else { return false }
        _ = rmdir(path)
        return true
    }

    /// Eight hex digits, which is all a temporary name here needs. Deliberately not a
    /// UUID string: a `sockaddr_un` path is limited to 104 bytes and macOS's `$TMPDIR` is
    /// about fifty of them, so a 36-character component is most of the budget on its own.
    static func shortID() -> String {
        String(format: "%08x", UInt32.random(in: 0 ... UInt32.max))
    }
}
