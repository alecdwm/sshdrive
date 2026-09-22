import Foundation

/// The "Server free space" line of `sshdrive status` (docs/design/cli.md), as a value
/// taken at probe time.
///
/// `statvfs@openssh.com` is a **wire call**, and `sshdrive status` may not make one: a
/// status command that dialled a server the user has not touched would wait behind
/// the breaker's connect attempt - up to the 60 s authentication deadline - and, worse,
/// *start* one where there was none. `status --probe` is the way to ask for a connection
/// on purpose, and nothing else in the command may.
///
/// So the number is captured where a connection already exists and a round trip is
/// already being spent - the capability probe, which runs on every
/// connection and on `--probe` - and kept in `capabilities.json` beside the probe.
/// `status` renders whatever is there, with its age when it is old enough for the age to
/// matter, and "unknown" when no probe has ever run.
public struct ServerFreeSpace: Sendable, Equatable {
    /// Bytes available to this account, as `statvfs` reported them.
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    /// Wall clock, seconds since 1970, from the agent's own clock so a scenario can drive
    /// it.
    public var capturedAt: Double

    /// Older than this and the line says when it was taken. An hour, because free space
    /// on a server other people write to is a figure the user reads as "now", and a
    /// mount that has been up since yesterday would otherwise report yesterday's disk as
    /// today's without saying so.
    public static let staleAfterSeconds: Double = 3600

    /// What `status` prints when no probe has ever run for this location.
    public static let unknownSentence = "unknown"

    public init(freeBytes: UInt64, totalBytes: UInt64, capturedAt: Double) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.capturedAt = capturedAt
    }

    /// The `statvfs` reply, or nil when it says nothing. A server that answers a total of
    /// zero blocks has told us nothing, and "0 bytes of 0 bytes" reads as a full disk.
    public static func from(
        availableBlocks: UInt64, blockSize: UInt64, totalBlocks: UInt64, at capturedAt: Double
    ) -> ServerFreeSpace? {
        let total = totalBlocks &* blockSize
        guard total > 0 else { return nil }
        return ServerFreeSpace(
            freeBytes: availableBlocks &* blockSize, totalBytes: total, capturedAt: capturedAt)
    }

    public func isStale(now: Double) -> Bool {
        now - capturedAt >= ServerFreeSpace.staleAfterSeconds
    }

    /// `1.8 TB of 4.0 TB`, and `1.8 TB of 4.0 TB (as of 3h ago)` once it is old enough
    /// that the user should not read it as this minute's figure.
    public func sentence(now: Double) -> String {
        let sizes =
            ByteCountFormatter.string(fromByteCount: Int64(clamping: freeBytes), countStyle: .file)
            + " of "
            + ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
        guard isStale(now: now) else { return sizes }
        return "\(sizes) (as of \(ServerFreeSpace.age(seconds: now - capturedAt)))"
    }

    /// The same shape the CLI prints a probe timestamp in ("probed 3m ago"), computed
    /// here so the agent owns every value in the report and `--json` and the text cannot
    /// disagree (docs/design/cli.md).
    public static func age(seconds: Double) -> String {
        let whole = Int(max(0, seconds.rounded()))
        if whole < 60 { return "\(whole)s ago" }
        if whole < 3600 { return "\(whole / 60)m ago" }
        if whole < 86400 { return "\(whole / 3600)h ago" }
        return "\(whole / 86400)d ago"
    }
}
