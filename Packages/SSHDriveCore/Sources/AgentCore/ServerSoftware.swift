import Foundation

/// Which SSH server the location is talking to, as far as the agent can honestly tell
/// (docs/design/cli.md).
///
/// Half of the capability catalogue is a claim about the *server*, and two of its lines
/// must not be printed as though every server were an OpenSSH that has not been upgraded
/// yet. `fsync@openssh.com` and `limits@openssh.com` are OpenSSH's own extensions; a
/// server whose SFTP service is not OpenSSH's `sftp-server` will never advertise them
/// however new it is, and telling that user to want OpenSSH >= 8.5 is simply wrong. So the
/// report says what the server *is* and phrases those two lines as facts rather than
/// upgrades.
///
/// Two independent pieces of evidence, because neither is available everywhere:
///
/// - **The identification string.** `remote software version <x>`, which only a
///   `LogLevel` above `ERROR` prints and only a real connection sees - never a mux
///   client, which talks to the master's socket (docs/design/ssh.md). The collect
///   connection (docs/design/secrets.md) captures it once, at `add`, and
///   `capabilities.json` keeps it.
/// - **The SFTP extension fingerprint,** which every connection has for free. OpenSSH's
///   `sftp-server` advertises a long list including `fsync@openssh.com` and
///   `lsetstat@openssh.com`; Go's `pkg/sftp` advertises exactly `hardlink@openssh.com`,
///   `posix-rename@openssh.com` and `statvfs@openssh.com` and nothing else, which is what
///   a Tailscale SSH node answers.
public struct ServerSoftware: Equatable, Sendable {

    /// What the identification string said it was.
    public enum Flavour: String, Equatable, Sendable {
        case openSSH
        case tailscale
        case other
        case unknown
    }

    /// The identification string verbatim, or empty when it was never captured.
    public let banner: String
    public let flavour: Flavour
    /// `OpenSSH sftp-server`, `Go pkg/sftp`, or nil when the fingerprint says neither.
    public let sftpImplementation: String?

    /// Exactly what Go's `pkg/sftp` advertises, and the whole of it.
    public static let goSFTPExtensions: Set<String> = [
        "hardlink@openssh.com", "posix-rename@openssh.com", "statvfs@openssh.com",
    ]
    /// Extensions only OpenSSH's own `sftp-server` has ever shipped.
    public static let openSSHOnlyExtensions: Set<String> = [
        "fsync@openssh.com", "lsetstat@openssh.com", "limits@openssh.com",
        "expand-path@openssh.com", "users-groups-by-id@openssh.com",
    ]

    public static let unknown = ServerSoftware(banner: nil, advertisedExtensions: [])

    public init(banner: String?, advertisedExtensions: [String]) {
        let text = (banner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.banner = text
        if text.isEmpty {
            flavour = .unknown
        } else if text.hasPrefix("OpenSSH") {
            flavour = .openSSH
        } else if text.hasPrefix("Tailscale") {
            flavour = .tailscale
        } else {
            flavour = .other
        }
        let advertised = Set(advertisedExtensions)
        if !advertised.isEmpty, advertised == ServerSoftware.goSFTPExtensions {
            sftpImplementation = "Go pkg/sftp"
        } else if !advertised.isDisjoint(with: ServerSoftware.openSSHOnlyExtensions) {
            sftpImplementation = "OpenSSH sftp-server"
        } else {
            sftpImplementation = nil
        }
    }

    /// Whether the server is OpenSSH. `nil` is "we do not know", which is not the same
    /// answer and must not be printed as one: an unknown server keeps the plain
    /// `upgrade:` wording, because for all we know it *is* an old OpenSSH.
    public var isOpenSSH: Bool? {
        switch flavour {
        case .openSSH: return true
        case .tailscale, .other: return false
        case .unknown:
            switch sftpImplementation {
            case "Go pkg/sftp": return false
            case "OpenSSH sftp-server": return true
            default: return nil
            }
        }
    }

    /// True only when we can say so: a server we have not identified is never described
    /// as one that cannot have OpenSSH's extensions.
    public var isKnownNotOpenSSH: Bool { isOpenSSH == false }

    /// What to call the server in one or two words: the banner where there is one, and
    /// otherwise what the fingerprint alone can say.
    public var name: String {
        if !banner.isEmpty { return banner }
        switch sftpImplementation {
        case "Go pkg/sftp": return "this server (Go pkg/sftp)"
        case "OpenSSH sftp-server": return "OpenSSH"
        default: return ""
        }
    }

    /// The `status` line: `Tailscale   SFTP: Go pkg/sftp`. Empty when nothing is known,
    /// so the caller prints no line at all rather than one saying "unknown".
    public var summary: String {
        var parts: [String] = []
        if !banner.isEmpty { parts.append(banner) }
        if let sftpImplementation { parts.append("SFTP: \(sftpImplementation)") }
        return parts.joined(separator: "   ")
    }

    public var isKnown: Bool { !summary.isEmpty }

    public var asJSON: [String: Any] {
        var out: [String: Any] = ["flavour": flavour.rawValue]
        if !banner.isEmpty { out["banner"] = banner }
        if let sftpImplementation { out["sftp"] = sftpImplementation }
        if let isOpenSSH { out["openSSH"] = isOpenSSH }
        return out
    }
}
