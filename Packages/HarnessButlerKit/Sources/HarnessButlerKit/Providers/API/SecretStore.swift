import Foundation
import Security
import Synchronization

public enum SecretStoreError: Error, Equatable, Sendable {
    case locked
    case failed(OSStatus)

    public var message: String {
        switch self {
        case .locked: "The Keychain is locked"
        case .failed(let status):
            "Keychain error \(status)" + ((SecCopyErrorMessageString(status, nil) as String?).map { ": \($0)" } ?? "")
        }
    }
}

/// Where Admin keys live (U-3: Keychain only). One secret per subscription ID.
public protocol SecretStore: Sendable {
    func read(account: String) throws(SecretStoreError) -> String?
    func write(_ secret: String, account: String) throws(SecretStoreError)
    func delete(account: String) throws(SecretStoreError)
}

/// Generic-password items in the login Keychain. The item's access list trusts this app, so
/// reads don't prompt for a signed build; a key read once is kept in memory for the session so
/// a rebuilt (re-signed) app asks at most once per launch.
public final class KeychainSecretStore: SecretStore {
    public static let adminKeyService = "ai.aegisventures.harnessbutler.admin-key"

    let service: String
    private let cache = Mutex<[String: String]>([:])

    public init(service: String = KeychainSecretStore.adminKeyService) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(account: String) throws(SecretStoreError) -> String? {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { return nil }
            cache.withLock { $0[account] = secret }
            return secret
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed: throw .locked
        default: throw .failed(status)
        }
    }

    public func write(_ secret: String, account: String) throws(SecretStoreError) {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Harness Butler admin key"
            add[kSecAttrDescription as String] = "Admin API key used to read organization spend"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw status == errSecInteractionNotAllowed ? .locked : .failed(status) }
        case errSecInteractionNotAllowed:
            throw .locked
        default:
            throw .failed(update)
        }
        cache.withLock { $0[account] = secret }
    }

    public func delete(account: String) throws(SecretStoreError) {
        cache.withLock { $0[account] = nil }
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .failed(status) }
    }
}

/// For tests and demo modes: never touches the Keychain.
public final class InMemorySecretStore: SecretStore {
    private let secrets: Mutex<[String: String]>

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = Mutex(secrets)
    }

    public func read(account: String) throws(SecretStoreError) -> String? { secrets.withLock { $0[account] } }
    public func write(_ secret: String, account: String) throws(SecretStoreError) { secrets.withLock { $0[account] = secret } }
    public func delete(account: String) throws(SecretStoreError) { _ = secrets.withLock { $0.removeValue(forKey: account) } }
    public var count: Int { secrets.withLock { $0.count } }
}
