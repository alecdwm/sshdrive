import Foundation

/// A random 128-bit value printed by a script before its own output, so the agent can
/// discard whatever the account's rc files wrote first (DESIGN.md section 9.2), and by
/// the login-shell snapshot for the same reason plus a closing marker (section 6.1).
///
/// One per channel, per run. It is never derived from anything: a predictable sentinel
/// could be printed by the server.
public struct Sentinel: Sendable, Equatable, CustomStringConvertible {
    /// 32 lower-case hex characters.
    public let hex: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 16)
        // arc4random_buf never fails and needs no file descriptor, which matters in a
        // launchd agent spawned before anything has raised its descriptor limit.
        arc4random_buf(&bytes, bytes.count)
        hex = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// For tests and for replaying a recorded channel.
    public init(hex: String) { self.hex = hex }

    public var description: String { hex }

    /// The bytes a script prints: the sentinel followed by NUL.
    public var marker: [UInt8] { Array(hex.utf8) + [0] }

    /// The first eight hex digits, for a temp-file name on the server.
    public var short: String { String(hex.prefix(8)) }
}

/// Splits a channel's raw stdout into "the rc noise in front" and "our output".
///
/// Fed incrementally, because the noise and the sentinel routinely arrive in different
/// reads and the sentinel itself can be split across two. Everything before the opening
/// marker is kept, capped, as `prefix`: `sshdrive status` prints it so the user can find
/// the rc file that produced it (section 9.2).
///
/// The same parser serves the login-shell snapshot (section 6.1), which prints the marker
/// a second time at the end. `sawClosingSentinel` is what lets the reader stop without
/// waiting for EOF, which an rc file that leaves a background child holding stdout never
/// delivers (`deb-shells`' `bashbg` account).
public struct SentinelParser: Sendable {
    public let sentinel: Sentinel
    /// How much of the pre-sentinel noise to keep for diagnostics.
    public let prefixLimit: Int

    private let marker: [UInt8]
    private var carry: [UInt8] = []
    private var opened = false
    private var closed = false
    private var prefixBytes: [UInt8] = []
    private var payloadBytes: [UInt8] = []

    public init(sentinel: Sentinel, prefixLimit: Int = 4096) {
        self.sentinel = sentinel
        self.prefixLimit = prefixLimit
        self.marker = sentinel.marker
    }

    /// True once the opening sentinel has been seen; everything in `payload` is the
    /// script's own output.
    public var sawOpeningSentinel: Bool { opened }
    /// True once the closing sentinel has been seen.
    public var sawClosingSentinel: Bool { closed }
    /// The bytes received before the sentinel, for `status`.
    public var prefix: Data { Data(prefixBytes) }
    public var prefixText: String { String(decoding: prefixBytes, as: UTF8.self) }
    /// The script's own output, sentinels removed.
    public var payload: Data { Data(payloadBytes) }

    /// True when the first bytes are an SFTP `SSH_FXP_VERSION` packet rather than our
    /// sentinel: a `ForceCommand internal-sftp` account answers an exec channel with SFTP
    /// framing, and the probe must report "no shell access (ForceCommand)" rather than
    /// "shell output unusable" (section 9.2).
    public var looksLikeSFTPVersion: Bool {
        let bytes = opened ? payloadBytes : (prefixBytes + carry)
        guard bytes.count >= 5 else { return false }
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        // 2 == SSH_FXP_VERSION, and a VERSION packet is small.
        return bytes[4] == 2 && length >= 5 && length < 4096
    }

    /// Feeds more raw stdout. Bytes after the closing sentinel are dropped.
    public mutating func append(_ data: Data) {
        append(bytes: [UInt8](data))
    }

    public mutating func append(bytes data: [UInt8]) {
        guard !closed else { return }
        if opened {
            appendPayload(data)
            return
        }
        var buffer = carry + data
        if let index = Self.find(marker, in: buffer) {
            var head = Array(buffer[buffer.startIndex ..< index])
            // The snapshot's opening printf writes NUL + sentinel + NUL, so a NUL
            // immediately in front of the marker is ours, not the rc file's.
            if head.last == 0 { head.removeLast() }
            addPrefix(head)
            opened = true
            carry = []
            appendPayload(Array(buffer[(index + marker.count)...]))
            return
        }
        // Nothing yet. Hold back marker.count - 1 bytes in case the marker straddles the
        // next read; everything older than that can only ever be noise.
        let hold = min(buffer.count, marker.count - 1)
        let settled = Array(buffer[buffer.startIndex ..< (buffer.count - hold)])
        addPrefix(settled)
        carry = Array(buffer.suffix(hold))
        buffer = []
    }

    /// Call at EOF, or when giving up: the parser holds back the last few bytes in case
    /// the marker straddles the next read, and at end of stream those bytes are part of
    /// the noise the user needs to see.
    public mutating func finish() {
        guard !opened, !carry.isEmpty else { carry = []; return }
        addPrefix(carry)
        carry = []
    }

    private mutating func addPrefix(_ bytes: [UInt8]) {
        guard prefixBytes.count < prefixLimit, !bytes.isEmpty else { return }
        prefixBytes.append(contentsOf: bytes.prefix(prefixLimit - prefixBytes.count))
    }

    private mutating func appendPayload(_ data: [UInt8]) {
        guard !closed, !data.isEmpty else { return }
        let rescanFrom = max(0, payloadBytes.count - (marker.count - 1))
        payloadBytes.append(contentsOf: data)
        guard let index = Self.find(marker, in: payloadBytes, from: rescanFrom) else { return }
        var end = index
        if end > 0, payloadBytes[end - 1] == 0 { end -= 1 }
        payloadBytes = Array(payloadBytes[payloadBytes.startIndex ..< end])
        closed = true
    }

    /// The payload split on NUL, with the trailing empty element dropped: `env -0` output,
    /// `find -print0` output and NUL-terminated helper records are all this shape.
    public var nulRecords: [Data] {
        var out: [Data] = []
        var current: [UInt8] = []
        for byte in payloadBytes {
            if byte == 0 { out.append(Data(current)); current = [] } else { current.append(byte) }
        }
        if !current.isEmpty { out.append(Data(current)) }
        return out
    }

    /// `env -0` output as a dictionary. A record with no `=` is dropped; a value may
    /// contain `=` and does, routinely (`LS_COLORS`).
    public var environment: [String: String] {
        var out: [String: String] = [:]
        for record in nulRecords {
            let text = String(decoding: record, as: UTF8.self)
            guard let split = text.firstIndex(of: "=") else { continue }
            out[String(text[text.startIndex ..< split])] = String(text[text.index(after: split)...])
        }
        return out
    }

    /// True when the channel was refused because the account has no shell.
    ///
    /// Two shapes, both measured against the testbed on 2026-09-04: an account whose sshd
    /// answers an exec request with `internal-sftp`'s own refusal prints
    /// `This service allows sftp connections only.` in plain text (`deb-shells`'
    /// `forcesftp`), and one that hands the exec channel straight to the subsystem answers
    /// with `SSH_FXP_VERSION` framing. Section 9.2 describes only the second; the first is
    /// what OpenSSH 9.2 actually does for `ForceCommand internal-sftp`. Either way the
    /// probe must report "no shell access (ForceCommand)", not "shell output unusable".
    public var looksLikeForceCommandRefusal: Bool {
        if looksLikeSFTPVersion { return true }
        let text = String(decoding: opened ? payloadBytes : (prefixBytes + carry), as: UTF8.self)
            .lowercased()
        return text.contains("this service allows sftp connections only")
            || text.contains("allows sftp connections only")
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = max(0, from)
        while i <= last {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
