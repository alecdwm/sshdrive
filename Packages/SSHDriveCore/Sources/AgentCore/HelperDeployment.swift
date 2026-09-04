import Foundation

/// The decisions the helper's deployment makes, with the I/O taken out (DESIGN.md section
/// 6.4 tier 2, steps 1 and 2).
///
/// Every rule here is one sentence of section 6.4, and every one of them is a decision
/// rather than a round trip, which is why they are values and not part of the deployer:
///
/// - upload "if `sha256sum`/`shasum` of the remote copy does not match the hash embedded
///   in the app";
/// - "Where the server has neither tool, verification is the remote file's size against
///   the embedded binary plus running it with `--version`";
/// - "The upload goes to a temp name and is renamed into place like every other upload,
///   never written over the existing file";
/// - "Versions other than ours whose mtime is older than seven days are removed: two Macs
///   sharing one account may run different app versions, and each keeps its own file
///   without deleting the other's while it is in use."
public enum HelperDeployment {

    /// Section 6.4: "Versions other than ours whose mtime is older than seven days are
    /// removed".
    public static let staleAfter: TimeInterval = 7 * 24 * 3600

    /// The prefix of the relay FIFOs the wrapper makes (`RemoteScript.stdinRelay`). One is
    /// left behind whenever the wrapper is killed before its EXIT trap runs - which is
    /// every abrupt client kill, and the whole case the wrapper exists for - so they are
    /// swept on every deployment rather than trusted to clean themselves up. A FIFO with
    /// no reader is inert, so there is no age rule: if it is there and nothing is using
    /// it, it is litter (2026-09-05).
    public static let relayPrefix = ".sshdrive-helper-in-"

    /// One file the server has in the helper directory.
    public struct RemoteFile: Equatable, Sendable {
        public var name: String
        public var size: Int64
        /// Server mtime, whole seconds.
        public var mtime: Int64

        public init(name: String, size: Int64, mtime: Int64) {
            self.name = name
            self.size = size
            self.mtime = mtime
        }
    }

    /// What the deployer should do about the copy on the server.
    public enum Verdict: Equatable, Sendable {
        /// Nothing to do: the bytes there are ours.
        case keep
        /// Upload, with the sentence `status` prints if it fails.
        case upload(reason: String)
    }

    /// What was learned about the remote copy before deciding.
    public struct RemoteEvidence: Equatable, Sendable {
        /// Nil when the file is not there at all.
        public var size: Int64?
        /// From `sha256sum`/`shasum` on the server, where there is one.
        public var sha256: String?
        /// From running it with `--version`, which prints the digest of its own
        /// executable. Present on a server with no checksum tool, and the reason that
        /// fallback is a real check rather than a size comparison (2026-09-05, section 13).
        public var reportedDigest: String?
        /// The version string the binary printed, for `status`.
        public var reportedVersion: String?

        public init(size: Int64? = nil, sha256: String? = nil,
                    reportedDigest: String? = nil, reportedVersion: String? = nil) {
            self.size = size
            self.sha256 = sha256
            self.reportedDigest = reportedDigest
            self.reportedVersion = reportedVersion
        }
    }

    public static func verdict(for binary: HelperManifest.Binary, evidence: RemoteEvidence) -> Verdict {
        guard let size = evidence.size else {
            return .upload(reason: "the helper is not on the server yet")
        }
        // The hash decides wherever there is one, from either source: a digest the binary
        // computed of itself is the same claim as one `sha256sum` made about it, and a
        // corrupted binary fails both.
        if let hash = evidence.sha256 ?? evidence.reportedDigest {
            return hash.caseInsensitiveCompare(binary.sha256) == .orderedSame
                ? .keep
                : .upload(reason: "the copy on the server does not match this build")
        }
        guard size == binary.size else {
            return .upload(reason: "the copy on the server is \(size) bytes, not \(binary.size)")
        }
        // Size matched and nothing could vouch for the contents. Section 6.4's fallback is
        // "size plus running it with `--version`"; with no answer from either tool the
        // honest thing is to replace it rather than to run it.
        return .upload(reason: "the server could not verify the helper's contents")
    }

    /// The temp name an upload goes to. Section 5.5's shape, so a half-written helper is
    /// as recognisable as a half-written file of the user's, and the same
    /// `.sshdrive-upload-*` ignore rule covers it inside the helper directory too.
    public static func temporaryName(macID: String, uuid: String = UUID().uuidString) -> String {
        ".sshdrive-upload-\(macID.prefix(8))-\(uuid)"
    }

    /// Which files in the helper directory to delete.
    ///
    /// Ours is kept whatever its age. Another version is kept until it is seven days
    /// untouched, because another Mac on the same account may be running it right now.
    /// Anything that is not a helper of ours is never touched: the directory may be
    /// `$XDG_CACHE_HOME/sshdrive` on a shared account.
    public static func stale(
        _ files: [RemoteFile], keeping keep: Set<String>, serverNow: Int64,
        staleAfter: TimeInterval = HelperDeployment.staleAfter
    ) -> [String] {
        files.filter { file in
            guard !keep.contains(file.name) else { return false }
            if file.name.hasPrefix(relayPrefix) { return true }
            guard file.name.hasPrefix("sshdrive-helper-") else { return false }
            return Double(serverNow - file.mtime) > staleAfter
        }
        .map(\.name)
        .sorted()
    }

    /// Reads `sshdrive-helper 0.1.0 linux/aarch64 sha256=<hex>`, which is what the binary
    /// prints for `--version`. Anything else is a binary that is not ours, or is not a
    /// binary, and answers nil rather than a guess.
    public static func parseVersionLine(_ line: String) -> (version: String, target: HelperTarget, digest: String)? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4, fields[0] == "sshdrive-helper" else { return nil }
        let pair = fields[2].split(separator: "/", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { return nil }
        guard fields[3].hasPrefix("sha256=") else { return nil }
        let digest = String(fields[3].dropFirst("sha256=".count))
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return (fields[1], HelperTarget(os: pair[0], arch: pair[1]), digest)
    }
}
