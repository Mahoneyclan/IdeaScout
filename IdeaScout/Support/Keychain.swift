import Foundation
import Security

/// Stores secrets (API key, tokens) in the iPhone Keychain rather than in code or settings.
enum Keychain {
    static let service = "com.mahoney.IdeaScout"

    enum Key: String {
        case claudeAPIKey, productHuntToken
    }

    static func get(_ key: Key, service: String = Keychain.service) -> String? {
        var query = baseQuery(key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func set(_ value: String?, for key: Key, service: String = Keychain.service) -> Bool {
        SecItemDelete(baseQuery(key, service: service) as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return true }
        var query = baseQuery(key, service: service)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock  // readable during background refresh
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ key: Key, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
}
