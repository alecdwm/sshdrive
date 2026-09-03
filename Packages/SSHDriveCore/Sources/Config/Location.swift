import Foundation

/// How long a fetched file may sit in the local replica before the eviction loop may
/// take it (DESIGN.md section 7). Milestone 7 implements the loop; the value is carried
/// from milestone 1 so the model does not change under it.
public enum CacheTTL: String, Codable, CaseIterable, Sendable {
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case twelveHours = "12h"
    case oneDay = "1d"
    case oneWeek = "1w"
    case oneMonth = "1mo"
    case never = "never"

    public var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 900
        case .oneHour: return 3600
        case .twelveHours: return 43200
        case .oneDay: return 86400
        case .oneWeek: return 604800
        case .oneMonth: return 2_592_000
        case .never: return nil
        }
    }
}

/// Whether server mode bits become Finder capabilities (DESIGN.md section 5.4).
public enum PermissionsMode: String, Codable, CaseIterable, Sendable {
    case mode
    case none
}

/// Change-detection tier selection (DESIGN.md section 6.4). Milestones 6 and 9.
public enum WatchMode: String, Codable, CaseIterable, Sendable {
    case auto
    case poll
    case sweep
    case helper
}

/// Whether an lstat preflight runs before every create and rename (DESIGN.md section 5.5).
public enum CreateCheck: String, Codable, CaseIterable, Sendable {
    case auto
    case lstat
}

/// Which backend a location runs on. Milestone 1 has only the fake one; `sftp` arrives
/// with the transport in milestone 2. The field is stored so a fake location survives an
/// agent restart and so `status` can never mistake one for a real mount.
public enum LocationBackend: String, Codable, Sendable {
    case sftp
    case fake
}

/// One location (DESIGN.md section 4). The id doubles as the File Provider domain
/// identifier. No secret is ever stored here: `secrets` only names the keychain items
/// that exist.
public struct Location: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var nickname: String?
    /// Exactly what the user typed: an ssh_config alias or a hostname.
    public var host: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var sshOptions: [String]
    /// Default is the SFTP realpath of "." (the account's home).
    public var remotePath: String?
    /// Keychain item keys: "password:<user>@<hostname>:<port>", "passphrase:<keypath>".
    public var secrets: [String]
    /// Set by `add` when only the key agent could authenticate (section 4.2).
    public var agentDependent: Bool
    public var cacheTTL: CacheTTL
    public var permissions: PermissionsMode
    public var watchMode: WatchMode
    public var helper: Bool
    public var createCheck: CreateCheck
    /// Whether a File Provider domain currently exists for it.
    public var mounted: Bool
    public var backend: LocationBackend

    public init(
        id: String = UUID().uuidString,
        nickname: String? = nil,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = [],
        remotePath: String? = nil,
        secrets: [String] = [],
        agentDependent: Bool = false,
        cacheTTL: CacheTTL = .oneHour,
        permissions: PermissionsMode = .mode,
        watchMode: WatchMode = .auto,
        helper: Bool = true,
        createCheck: CreateCheck = .auto,
        mounted: Bool = false,
        backend: LocationBackend = .sftp
    ) {
        self.id = id
        self.nickname = nickname
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.remotePath = remotePath
        self.secrets = secrets
        self.agentDependent = agentDependent
        self.cacheTTL = cacheTTL
        self.permissions = permissions
        self.watchMode = watchMode
        self.helper = helper
        self.createCheck = createCheck
        self.mounted = mounted
        self.backend = backend
    }

    /// nickname ?? host. Whether it is prefixed with "SSH Drive - " is decided by spike
    /// S3, which records whether the system prefixes the app name itself (section 4).
    public var displayName: String { nickname ?? host }

    /// `<name>` on the CLI resolves nickname, then host, then id prefix (section 8).
    public func matches(name: String) -> Bool {
        if let nickname, nickname == name { return true }
        if host == name { return true }
        return id.lowercased().hasPrefix(name.lowercased())
    }

    // Defaults for fields added after a config was first written.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        host = try c.decode(String.self, forKey: .host)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        sshOptions = try c.decodeIfPresent([String].self, forKey: .sshOptions) ?? []
        remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath)
        secrets = try c.decodeIfPresent([String].self, forKey: .secrets) ?? []
        agentDependent = try c.decodeIfPresent(Bool.self, forKey: .agentDependent) ?? false
        cacheTTL = try c.decodeIfPresent(CacheTTL.self, forKey: .cacheTTL) ?? .oneHour
        permissions = try c.decodeIfPresent(PermissionsMode.self, forKey: .permissions) ?? .mode
        watchMode = try c.decodeIfPresent(WatchMode.self, forKey: .watchMode) ?? .auto
        helper = try c.decodeIfPresent(Bool.self, forKey: .helper) ?? true
        createCheck = try c.decodeIfPresent(CreateCheck.self, forKey: .createCheck) ?? .auto
        mounted = try c.decodeIfPresent(Bool.self, forKey: .mounted) ?? false
        backend = try c.decodeIfPresent(LocationBackend.self, forKey: .backend) ?? .sftp
    }
}
