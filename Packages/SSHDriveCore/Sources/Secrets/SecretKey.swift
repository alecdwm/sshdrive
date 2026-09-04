import Foundation

/// The destination an `ssh` process is authenticating to, as `ssh -G` resolves it
/// (DESIGN.md section 4.2). Never the alias the user typed: `nas` and
/// `nas.tail1234.ts.net` resolve to the same `hostname` and therefore share one item.
public struct SSHDestination: Hashable, Sendable, CustomStringConvertible {
    public var user: String
    /// Lowercased, as `ssh` itself prints it in the password prompt.
    public var hostname: String
    public var port: Int

    public init(user: String, hostname: String, port: Int) {
        self.user = user
        self.hostname = hostname.lowercased()
        self.port = port
    }

    public var description: String { "\(user)@\(hostname):\(port)" }
}

/// Keychain items are keyed by the prompt's identity, and shared by every location that
/// names the same one (DESIGN.md sections 3, 4.2). There is no location id in a key:
/// keying passwords by `<user>@<hostname>:<port>` is what makes `ProxyJump` work with
/// password auth on both hops, because each hop's prompt names its own host.
///
/// Section 4.2's table lists exactly two kinds of stored answer. Everything else it
/// classifies - the host-key question, the user-presence notice, a PIN, a one-time code -
/// is answered without the keychain or refused, and so has no key.
public enum SecretKey: Hashable, Sendable, CustomStringConvertible {
    /// `password:<user>@<hostname>:<port>`.
    case password(SSHDestination)
    /// `passphrase:<keypath>`, the path exactly as `ssh` prints it in the prompt, which
    /// is the absolute path `ssh -G` resolved (`~` already expanded).
    case passphrase(path: String)

    /// The `kSecAttrAccount` string. This is the wire form: it is what `list`, `show` and
    /// `sshdrive debug secrets` print and what a keychain item is filed under.
    public var account: String {
        switch self {
        case .password(let destination):
            return "password:\(destination.user)@\(destination.hostname):\(destination.port)"
        case .passphrase(let path):
            return "passphrase:\(path)"
        }
    }

    public init?(account: String) {
        if account.hasPrefix("passphrase:") {
            let path = String(account.dropFirst("passphrase:".count))
            guard !path.isEmpty else { return nil }
            self = .passphrase(path: path)
            return
        }
        guard account.hasPrefix("password:") else { return nil }
        let body = String(account.dropFirst("password:".count))
        // user may not contain "@"; hostname may not contain ":". Split from the right so
        // a hostname with no "@" and a user with no ":" both survive.
        guard let atIndex = body.lastIndex(of: "@") else { return nil }
        let user = String(body[body.startIndex..<atIndex])
        let rest = String(body[body.index(after: atIndex)...])
        guard let colonIndex = rest.lastIndex(of: ":"),
            let port = Int(rest[rest.index(after: colonIndex)...])
        else { return nil }
        let hostname = String(rest[rest.startIndex..<colonIndex])
        guard !user.isEmpty, !hostname.isEmpty else { return nil }
        self = .password(SSHDestination(user: user, hostname: hostname, port: port))
    }

    public var description: String { account }

    /// What `sshdrive list` and `sshdrive show` say about an item that exists
    /// (section 4.2: "password stored for alec@nas", "passphrase stored for
    /// ~/.ssh/id_nas").
    public var report: String {
        switch self {
        case .password(let destination):
            return "password stored for \(destination.user)@\(destination.hostname)"
        case .passphrase(let path):
            return "passphrase stored for \(SecretKey.abbreviate(path))"
        }
    }

    /// `$HOME`-relative spelling for display only; the key itself always carries the
    /// absolute path `ssh` printed.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
