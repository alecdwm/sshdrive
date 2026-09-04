import Foundation

/// The `[user@]host[:port]` sugar `sshdrive add` accepts (DESIGN.md sections 4, 8).
///
/// `ssh` itself does not parse this form - `ssh -G alec@10.0.0.1:2222` resolves the host
/// to the literal `10.0.0.1:2222` - so the parts are split here and stored as the
/// location's own overrides, which reach `ssh` as `-o User=` and `-o Port=` (section 6.1).
/// The host may equally be a `~/.ssh/config` alias, which is the whole point of section
/// 4.1: an alias is passed through untouched so its host block still applies.
public struct LocationDestination: Equatable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case noHost(String)
        case emptyUser(String)
        case badPort(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "A destination is required: [user@]host-or-alias[:port]."
            case .noHost(let text):
                return "\"\(text)\" has no host; write it as [user@]host-or-alias[:port]."
            case .emptyUser(let text):
                return "\"\(text)\" has an empty user before the \"@\"."
            case .badPort(let text):
                return "\"\(text)\" has a port that is not between 1 and 65535."
            }
        }
    }

    /// `alec@nas:2222`, `nas`, `[::1]:22`, `alec@[fe80::1]`.
    ///
    /// The bracket form is `ssh`'s own spelling for an IPv6 literal and is the only way a
    /// colon in the host can be told from a port separator, which is why a bare `::1`
    /// without brackets is read as host `:` port… no: an unbracketed literal keeps every
    /// colon, because the port split only fires when the tail after the **last** colon
    /// parses as a number and there is exactly one colon. Two colons mean IPv6.
    public static func parse(_ text: String) throws -> LocationDestination {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { throw ParseError.empty }

        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let candidate = String(rest[rest.startIndex ..< at])
            guard !candidate.isEmpty else { throw ParseError.emptyUser(text) }
            user = candidate
            rest = String(rest[rest.index(after: at)...])
        }

        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw ParseError.noHost(text) }
            let host = String(rest[rest.index(after: rest.startIndex) ..< close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let value = Int(after.dropFirst()), (1...65535).contains(value) else {
                    throw ParseError.badPort(text)
                }
                port = value
            } else if !after.isEmpty {
                throw ParseError.noHost(text)
            }
            guard !host.isEmpty else { throw ParseError.noHost(text) }
            return LocationDestination(user: user, host: host, port: port)
        }

        // One colon is host:port. More than one is an unbracketed IPv6 literal, which is
        // taken whole: there is no port to find in it.
        if rest.filter({ $0 == ":" }).count == 1, let colon = rest.lastIndex(of: ":") {
            let tail = String(rest[rest.index(after: colon)...])
            guard let value = Int(tail), (1...65535).contains(value) else {
                throw ParseError.badPort(text)
            }
            port = value
            rest = String(rest[rest.startIndex ..< colon])
        }
        guard !rest.isEmpty else { throw ParseError.noHost(text) }
        return LocationDestination(user: user, host: rest, port: port)
    }
}

/// The keys `sshdrive set <name> <key> <value>` takes (DESIGN.md section 8).
///
/// Milestone 3 implements every one of them except the two whose machinery arrives later
/// (`watch-mode` and `helper` are section 6.4's, milestones 6 and 9), which are still
/// stored so the value survives to the milestone that reads it.
public enum LocationSettingKey: String, CaseIterable, Sendable {
    case nickname
    case cacheTTL = "cache-ttl"
    case remotePath = "remote-path"
    case host
    case port
    case user
    case identity
    case watchMode = "watch-mode"
    case helper
    case permissions
    case createCheck = "create-check"

    /// "nickname and remote-path re-create the domain … so they are refused while uploads
    /// are pending and warn that the cache is dropped otherwise" (section 8). The sidebar
    /// name is fixed at domain creation unless S9 says otherwise, and S9 has not been
    /// answered, so the documented behaviour is what runs.
    public var recreatesDomain: Bool { self == .nickname || self == .remotePath }

    /// "host, user, port and identity change what the stored secrets are keyed on or which
    /// key is offered, so they re-run the collect connection exactly as passwd does"
    /// (section 8, section 4.2).
    public var requiresCollectConnection: Bool {
        switch self {
        case .host, .user, .port, .identity: return true
        default: return false
        }
    }

    /// A new root invalidates every path in the index (section 8).
    public var dropsIndex: Bool { self == .remotePath }

    public static var allNames: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }
}

public enum LocationSettingError: Error, LocalizedError, Equatable {
    case unknownKey(String)
    case badValue(key: String, value: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key):
            return "Unknown setting \"\(key)\". Known settings: \(LocationSettingKey.allNames)."
        case let .badValue(key, value, expected):
            return "\"\(value)\" is not a valid \(key); expected \(expected)."
        }
    }
}

extension LocationSettingKey {

    /// Validates a value and writes it into the location, leaving everything else alone.
    ///
    /// Kept beside the parser and away from the agent so the whole `set` surface can be
    /// unit-tested without an XPC connection or a server.
    public func apply(_ value: String, to location: inout Location) throws {
        switch self {
        case .nickname:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "a non-empty name")
            }
            location.nickname = trimmed

        case .cacheTTL:
            guard let ttl = CacheTTL(rawValue: value) else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value,
                    expected: CacheTTL.allCases.map(\.rawValue).joined(separator: "|"))
            }
            location.cacheTTL = ttl

        case .remotePath:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "a path on the server")
            }
            location.remotePath = trimmed

        case .host:
            let destination = try LocationDestination.parse(value)
            location.host = destination.host
            if let user = destination.user { location.user = user }
            if let port = destination.port { location.port = port }

        case .port:
            guard let port = Int(value), (1...65535).contains(port) else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "a port between 1 and 65535")
            }
            location.port = port

        case .user:
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "an account name")
            }
            location.user = trimmed

        case .identity:
            let path = (value as NSString).expandingTildeInPath
            guard !path.isEmpty else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "a path to a key file")
            }
            location.identityFile = path
            // Section 4: `--identity` means the override plus `IdentitiesOnly=yes`, so the
            // named key is the only one offered and a touch key in `~/.ssh` never gets its
            // turn ahead of it (section 4.2).
            if !location.sshOptions.contains("IdentitiesOnly=yes") {
                location.sshOptions += ["-o", "IdentitiesOnly=yes"]
            }

        case .watchMode:
            guard let mode = WatchMode(rawValue: value) else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value,
                    expected: WatchMode.allCases.map(\.rawValue).joined(separator: "|"))
            }
            location.watchMode = mode

        case .helper:
            switch value.lowercased() {
            case "on", "true", "yes": location.helper = true
            case "off", "false", "no": location.helper = false
            default:
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "on|off")
            }

        case .permissions:
            guard let mode = PermissionsMode(rawValue: value) else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "mode|none")
            }
            location.permissions = mode

        case .createCheck:
            guard let check = CreateCheck(rawValue: value) else {
                throw LocationSettingError.badValue(
                    key: rawValue, value: value, expected: "auto|lstat")
            }
            location.createCheck = check
        }
    }

    public static func named(_ key: String) throws -> LocationSettingKey {
        // `cacheTTL` and `cache-ttl` both reach the same setting: the CLI spells it with
        // the dash, the JSON with the camel case, and a user will type either.
        let normalised = key.replacingOccurrences(of: "_", with: "-").lowercased()
        if let direct = LocationSettingKey(rawValue: normalised) { return direct }
        switch normalised {
        case "cachettl": return .cacheTTL
        case "remotepath", "path": return .remotePath
        case "watchmode": return .watchMode
        case "createcheck": return .createCheck
        case "identityfile": return .identity
        default: throw LocationSettingError.unknownKey(key)
        }
    }
}
