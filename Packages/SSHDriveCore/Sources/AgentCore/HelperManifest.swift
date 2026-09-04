import Foundation

/// The manifest that ships beside the helper binaries in
/// `SSH Drive.app/Contents/Resources/helper/` (DESIGN.md sections 3 and 10.1).
///
/// Section 10.1: CI "collects the Linux job's artifacts, and records every hash into the
/// app's manifest". Section 6.4 then uses those hashes to decide whether the copy on the
/// server is ours before anything is started from it, and section 9 makes that a security
/// property rather than a convenience: the binary "is verified before every launch, by
/// SHA-256 against a hash embedded in the app".
public struct HelperManifest: Codable, Equatable, Sendable {

    public struct Binary: Codable, Equatable, Sendable {
        /// `linux`, `darwin`, `freebsd`.
        public var os: String
        /// `x86_64`, `aarch64`, `armv7`.
        public var arch: String
        /// The file name inside `Contents/Resources/helper/`, which is also the name the
        /// binary is given on the server: `sshdrive-helper-<version>-<os>-<arch>`
        /// (section 3).
        public var file: String
        public var sha256: String
        public var size: Int64

        public init(os: String, arch: String, file: String, sha256: String, size: Int64) {
            self.os = os
            self.arch = arch
            self.file = file
            self.sha256 = sha256
            self.size = size
        }
    }

    /// Tied to the app release (section 6.4: "The version is tied to the app release").
    public var version: String
    public var binaries: [Binary]

    public init(version: String, binaries: [Binary]) {
        self.version = version
        self.binaries = binaries
    }

    public static let fileName = "manifest.json"

    /// Every file name this version owns, so the cleanup below can tell one of ours from
    /// another Mac's.
    public var fileNames: Set<String> { Set(binaries.map(\.file)) }

    /// The binary for what `uname -sm` said, or nil - which section 6.4 makes an ordinary
    /// outcome rather than an error: "A platform outside that list is the one case where a
    /// server with shell access stays at the sweep tier, and `status` asks for an issue
    /// with the `uname -sm` output".
    public func binary(forUname uname: String) -> Binary? {
        guard let target = HelperTarget(uname: uname) else { return nil }
        return binaries.first { $0.os == target.os && $0.arch == target.arch }
    }

    public static func decode(_ data: Data) throws -> HelperManifest {
        try JSONDecoder().decode(HelperManifest.self, from: data)
    }
}

/// `uname -sm` mapped onto the target triple halves the manifest is keyed on.
///
/// The spellings are the ones real servers print, not the ones Rust uses: FreeBSD says
/// `amd64` where Rust says `x86_64`, macOS says `arm64` where Rust says `aarch64`, and a
/// 32-bit Synology says `armv7l`. Getting this wrong does not fail loudly - it silently
/// leaves every NAS at the sweep tier - so the table is explicit and tested.
public struct HelperTarget: Equatable, Sendable {
    public var os: String
    public var arch: String

    public init(os: String, arch: String) {
        self.os = os
        self.arch = arch
    }

    public init?(uname: String) {
        let parts = uname.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { return nil }
        guard let os = HelperTarget.os(parts[0]), let arch = HelperTarget.arch(parts[1]) else {
            return nil
        }
        self.os = os
        self.arch = arch
    }

    static func os(_ value: String) -> String? {
        switch value.lowercased() {
        case "linux": return "linux"
        case "darwin": return "darwin"
        case "freebsd": return "freebsd"
        default: return nil
        }
    }

    static func arch(_ value: String) -> String? {
        switch value.lowercased() {
        case "x86_64", "amd64": return "x86_64"
        case "aarch64", "arm64": return "aarch64"
        case "armv7l", "armv7", "armv7hl": return "armv7"
        default: return nil
        }
    }
}
