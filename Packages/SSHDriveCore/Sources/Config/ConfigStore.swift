import Foundation
import Logging

/// `config.json` in the app-group container (DESIGN.md section 3). Written only by the
/// agent; the CLI reaches it through XPC and the extension never opens it at all.
public struct ConfigFile: Codable, Equatable, Sendable {
    /// Bumped whenever the on-disk shape changes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// This install's identity, used to name our own upload temp files and conflict
    /// copies (section 5.5). Eight lowercase hex characters.
    public var macID: String
    public var locations: [Location]

    public init(schemaVersion: Int = ConfigFile.currentSchemaVersion, macID: String, locations: [Location] = []) {
        self.schemaVersion = schemaVersion
        self.macID = macID
        self.locations = locations
    }

    public static func newMacID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

public enum ConfigStoreError: Error, LocalizedError {
    case schemaTooNew(found: Int, understood: Int)
    case unknownLocation(String)
    case ambiguousLocation(String, [String])

    public var errorDescription: String? {
        switch self {
        case let .schemaTooNew(found, understood):
            return "config.json is at schema version \(found); this build understands \(understood)."
        case let .unknownLocation(name):
            return "No location matches \"\(name)\"."
        case let .ambiguousLocation(name, matches):
            return "\"\(name)\" matches \(matches.joined(separator: ", "))."
        }
    }
}

/// Reads and writes `config.json`. Not thread-safe by itself: the agent owns one
/// instance and serialises access on its own queue.
public final class ConfigStore {
    private let url: URL
    private var cached: ConfigFile?

    public init(url: URL) {
        self.url = url
    }

    public convenience init() throws {
        self.init(url: try GroupContainer.configURL())
    }

    /// Loads the file, creating a fresh one on first run.
    public func load() throws -> ConfigFile {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = ConfigFile(macID: ConfigFile.newMacID())
            try save(fresh)
            return fresh
        }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ConfigFile.self, from: data)
        guard file.schemaVersion <= ConfigFile.currentSchemaVersion else {
            throw ConfigStoreError.schemaTooNew(
                found: file.schemaVersion, understood: ConfigFile.currentSchemaVersion)
        }
        cached = file
        return file
    }

    /// Writes atomically, so a crash mid-write never leaves a half-parsed config.
    public func save(_ file: ConfigFile) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
        cached = file
    }

    @discardableResult
    public func mutate(_ body: (inout ConfigFile) throws -> Void) throws -> ConfigFile {
        var file = try load()
        try body(&file)
        try save(file)
        return file
    }

    /// Resolves a `<name>` the way section 8 says: nickname, then host, then id prefix.
    public func location(named name: String) throws -> Location {
        let file = try load()
        if let exact = file.locations.first(where: { $0.nickname == name || $0.host == name }) {
            return exact
        }
        let prefixed = file.locations.filter { $0.id.lowercased().hasPrefix(name.lowercased()) }
        switch prefixed.count {
        case 0: throw ConfigStoreError.unknownLocation(name)
        case 1: return prefixed[0]
        default:
            throw ConfigStoreError.ambiguousLocation(name, prefixed.map(\.displayName))
        }
    }

    /// Drops the in-memory copy. The agent calls this after an external edit; nothing in
    /// milestone 1 makes one.
    public func invalidate() {
        cached = nil
    }
}
