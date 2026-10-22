// Keychain.swift
// Stores API keys in the iPhone Keychain, the only place IdeaScout keeps secrets (never in source,
// UserDefaults or the database). Used by Settings (SecretField), AppSettings.makeClient and the welcome flow.

import Foundation
import Security

/// Stores secrets (API key, tokens) in the iPhone Keychain rather than in code or settings.
enum Keychain {
    /// The Keychain "service" that groups all of IdeaScout's entries. Tests pass a different service
    /// so they never touch the user's real keys.
    static let service = "com.mahoney.IdeaScout"

    /// One entry per secret. The raw value is the Keychain account name, so renaming a case would
    /// lose the saved key for existing users.
    enum Key: String {
        case claudeAPIKey
        case openaiAPIKey, geminiAPIKey, grokAPIKey, deepseekAPIKey, qwenAPIKey, glmAPIKey, kimiAPIKey, mimoAPIKey
    }

    /// Reads a secret.
    /// - Parameters:
    ///   - key: Which secret to read.
    ///   - service: The Keychain service; tests override it.
    /// - Returns: The saved value, or `nil` if nothing (or only an empty string) is saved.
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

    /// Saves or removes a secret. The old entry is always deleted first, so saving replaces it.
    /// - Parameters:
    ///   - value: The new value; `nil` or blank text removes the entry.
    ///   - key: Which secret to write.
    ///   - service: The Keychain service; tests override it.
    /// - Returns: `true` if the save (or removal) succeeded.
    @discardableResult
    static func set(_ value: String?, for key: Key, service: String = Keychain.service) -> Bool {
        SecItemDelete(baseQuery(key, service: service) as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return true }
        var query = baseQuery(key, service: service)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock  // readable during background refresh (which can run while the phone is locked, after the first unlock)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Removes an entry by its raw name (used for keys the app no longer has, e.g. the old Product Hunt token).
    static func delete(account: String, service: String = Keychain.service) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    /// The fields that identify one entry: a generic password, in our service, under the key's account name.
    private static func baseQuery(_ key: Key, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
}
