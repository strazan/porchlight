import Foundation
import Security

/// Where Porchlight keeps its secrets: the relay secret, the Cloudflare token, the offline
/// queue key.
protocol SecretStore {
    func read(_ account: String) -> String?
    /// Whether the value was saved. An empty value deletes it.
    @discardableResult
    func write(_ account: String, _ value: String) -> Bool
}

/// Generic passwords in the login Keychain, under the app's bundle identifier.
struct KeychainSecrets: SecretStore {
    private let service = Bundle.main.bundleIdentifier ?? "sh.porchlight.Porchlight"

    func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ account: String, _ value: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Secrets that last only as long as the app: for sample data, which mustn't touch the Keychain.
final class MemorySecrets: SecretStore {
    private var values: [String: String] = [:]

    func read(_ account: String) -> String? { values[account] }

    @discardableResult
    func write(_ account: String, _ value: String) -> Bool {
        values[account] = value.isEmpty ? nil : value
        return true
    }
}

/// The secrets Porchlight keeps.
enum SecretAccount {
    static let relaySecret = "relaySecret"
    static let cloudflareToken = "cloudflareToken"
    static let queueKey = "queueKey"
}
