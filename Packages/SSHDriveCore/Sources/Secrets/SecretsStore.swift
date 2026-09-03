import Foundation
import Config
import Logging

/// Keychain items are keyed by the prompt's identity, and shared by every location that
/// names the same one (DESIGN.md sections 3, 4.2).
public enum SecretKey {
    /// "password:<user>@<hostname>:<port>", with user, hostname and port as resolved by
    /// `ssh -G`, never the alias.
    public static func password(user: String, hostname: String, port: Int) -> String {
        "password:\(user)@\(hostname):\(port)"
    }

    /// "passphrase:<keypath>".
    public static func passphrase(keyPath: String) -> String {
        "passphrase:\(keyPath)"
    }
}

/// The keychain wrapper. Only the agent has the `keychain-access-groups` entitlement, so
/// only the agent ever holds an instance of this (sections 2, 3.1).
public protocol SecretsStore: AnyObject, Sendable {
    func secret(forKey key: String) throws -> String?
    func setSecret(_ value: String, forKey key: String) throws
    func removeSecret(forKey key: String) throws
}

/// TODO milestone 2 (Transport): the real implementation, against the data-protection
/// keychain under access group RWGDZAYBM8.org.shirls.sshdrive, reached with
/// `kSecUseDataProtectionKeychain` and `kSecAttrAccessGroup`, and driven by the askpass
/// token protocol of section 4.2. Nothing in milestone 1 has a secret to store: the fake
/// backend needs no authentication.
public final class KeychainSecretsStore: SecretsStore {
    public let accessGroup: String
    /// The service every item is filed under.
    public static let service = "org.shirls.sshdrive"

    public init(accessGroup: String = "RWGDZAYBM8.org.shirls.sshdrive") {
        self.accessGroup = accessGroup
    }

    public func secret(forKey key: String) throws -> String? {
        // TODO milestone 2: SecItemCopyMatching with kSecClassGenericPassword,
        // kSecAttrService = service, kSecAttrAccount = key, kSecAttrAccessGroup =
        // accessGroup, kSecUseDataProtectionKeychain = true.
        Log.agent.debug("KeychainSecretsStore.secret is a milestone 2 stub")
        return nil
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        // TODO milestone 2: SecItemAdd, then SecItemUpdate on errSecDuplicateItem, with
        // kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock so the login agent can
        // read it without the screen being unlocked.
        Log.agent.debug("KeychainSecretsStore.setSecret is a milestone 2 stub")
    }

    public func removeSecret(forKey key: String) throws {
        // TODO milestone 2: SecItemDelete. `sshdrive remove` deletes each item the
        // location names that no remaining location also names (section 8).
        Log.agent.debug("KeychainSecretsStore.removeSecret is a milestone 2 stub")
    }
}

/// An in-memory store, for tests and for the fake backend.
public final class InMemorySecretsStore: SecretsStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(forKey key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func removeSecret(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}
