import Foundation
import Security
import Logging

/// Something the keychain refused. `status` is the raw `OSStatus` so the CLI can print
/// the exact code; the common ones get a sentence.
public struct SecretsError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        switch status {
        case errSecMissingEntitlement:
            return
                "\(operation) failed: missing entitlement. Only the agent, as the app bundle's main executable with an embedded provisioning profile, carries keychain-access-groups (section 3.1)."
        default:
            return "\(operation) failed: \(detail) (\(status))"
        }
    }
}

/// The keychain wrapper. Only the agent has the `keychain-access-groups` entitlement, so
/// only the agent ever holds an instance of this (sections 2, 3.1).
///
/// Keys are `SecretKey.account` strings; the string form is the API because the same
/// items are named by the CLI, by `list`/`show` and by the debug hooks.
public protocol SecretsStore: AnyObject, Sendable {
    func secret(forKey key: String) throws -> String?
    func setSecret(_ value: String, forKey key: String) throws
    func removeSecret(forKey key: String) throws
    /// Every account this store holds, for `list`, `show` and `sshdrive remove`.
    func accounts() throws -> [String]
}

extension SecretsStore {
    public func secret(for key: SecretKey) throws -> String? { try secret(forKey: key.account) }
    public func setSecret(_ value: String, for key: SecretKey) throws {
        try setSecret(value, forKey: key.account)
    }
    public func removeSecret(for key: SecretKey) throws { try removeSecret(forKey: key.account) }
    /// The accounts that parse as section 4.2 keys, in a stable order.
    public func keys() throws -> [SecretKey] {
        try accounts().compactMap(SecretKey.init(account:)).sorted { $0.account < $1.account }
    }
}

/// The data-protection keychain, under the shared access group, exactly as the S1(d2)
/// hook proved reachable from the launchd-started agent (docs/spikes/results.md,
/// 2026-09-04 signed pass): `kSecUseDataProtectionKeychain = true` plus
/// `kSecAttrAccessGroup = RWGDZAYBM8.org.shirls.sshdrive`.
///
/// `kSecAttrAccessible` is `kSecAttrAccessibleAfterFirstUnlock`: the agent is a login
/// agent and must read a passphrase to bring a mount up at login, before any keychain
/// prompt could be answered, and section 4.2 requires passphrases to be stored even when
/// a key agent also holds the key so exactly that works.
public final class KeychainSecretsStore: SecretsStore, @unchecked Sendable {
    public let accessGroup: String
    /// The service every item is filed under.
    public static let service = "org.shirls.sshdrive"

    public init(accessGroup: String = "RWGDZAYBM8.org.shirls.sshdrive") {
        self.accessGroup = accessGroup
    }

    private func base(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretsStore.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func secret(forKey key: String) throws -> String? {
        var query = base(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8)
            else { return nil }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretsError(status: status, operation: "reading the keychain item")
        }
    }

    public func setSecret(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        var attributes = base(account: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(
                base(account: key) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecretsError(status: updateStatus, operation: "updating the keychain item")
            }
        default:
            throw SecretsError(status: status, operation: "storing the keychain item")
        }
    }

    public func removeSecret(forKey key: String) throws {
        let status = SecItemDelete(base(account: key) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw SecretsError(status: status, operation: "deleting the keychain item")
        }
    }

    public func accounts() throws -> [String] {
        var query = base(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw SecretsError(status: status, operation: "listing keychain items")
        }
    }
}

/// An in-memory store, for tests, for the fake backend, and for the collect connection's
/// in-flight answers, which are only written to the keychain once the connection has
/// succeeded (section 4.2).
public final class InMemorySecretsStore: SecretsStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) {
        storage = initial
    }

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

    public func accounts() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}
