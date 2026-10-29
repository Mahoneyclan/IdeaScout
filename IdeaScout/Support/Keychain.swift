// Keychain.swift
// Stores API keys in the iPhone Keychain, the only place IdeaScout keeps secrets (never in source,
// UserDefaults or the database). Used by Settings (SecretField), AppSettings.makeClient and the welcome flow.

import Foundation
import Security

/// Stores secrets (API key, tokens) in the iPhone Keychain rather than in code or settings.
enum Keychain {
    /// The Keychain "service" that groups all of IdeaScout's entries. Tests pass a different service
    /// so they never touch the user's real keys.
    static var service: String { TestMode.isUITesting ? TestMode.keychainService : "com.mahoney.IdeaScout" }

    /// One entry per secret. The raw value is the Keychain account name, so renaming a case would
    /// lose the saved key for existing users.
    enum Key: String, CaseIterable {
        /// The Anthropic (Claude) key.
        case claudeAPIKey
        /// One key per other cloud provider, matching `AIProvider.keychainKey`.
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
        // Security: "after first unlock" so background refresh can read keys while the phone is locked;
        // "this device only" so keys never leave the phone, not even inside encrypted backups or on a
        // new iPhone restored from one (the user re-enters them there).
        query[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// The protection class used for every saved secret.
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Security: run once at launch, before any key is read.
    /// - A fresh install has empty UserDefaults, but iOS keeps Keychain entries after an app is deleted, so
    ///   keys from a previous install (possibly a previous owner of the phone) would reappear. They're removed.
    /// - Keys saved by older versions used a class that could travel in backups; they're re-saved with
    ///   `accessibility`, so existing users keep their keys without re-entering them.
    /// - Parameters:
    ///   - defaults: The app's settings store (tests pass their own).
    ///   - service: The Keychain service to clean and migrate (tests pass their own).
    static func prepareOnLaunch(defaults: UserDefaults = .standard, service: String = Keychain.service) {
        let installKey = "keychain.installMarker"
        if defaults.object(forKey: installKey) == nil {
            let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
            if isFreshInstall(domain: domain) { removeAll(service: service) }
            defaults.set(true, forKey: installKey)
        }
        let migratedKey = "keychain.thisDeviceOnly"
        if !defaults.bool(forKey: migratedKey) {
            migrateAccessibility(service: service)
            defaults.set(true, forKey: migratedKey)
        }
    }

    /// A fresh install has no saved settings at all; an existing install always has some.
    /// - Parameter domain: The app's UserDefaults domain, or `nil` if it has none.
    /// - Returns: `true` if there are no saved settings.
    static func isFreshInstall(domain: [String: Any]?) -> Bool { (domain ?? [:]).isEmpty }

    /// Deletes every IdeaScout secret, including keys the app no longer uses.
    static func removeAll(service: String = Keychain.service) {
        for account in Key.allCases.map(\.rawValue) + ["productHuntToken"] { delete(account: account, service: service) }
    }

    /// Re-saves every existing secret so it uses the current `accessibility` class.
    static func migrateAccessibility(service: String = Keychain.service) {
        for key in Key.allCases {
            if let value = get(key, service: service) { set(value, for: key, service: service) }
        }
    }

    /// Removes an entry by its raw name (used for keys the app no longer has, e.g. the old Product Hunt token).
    /// - Parameters:
    ///   - account: The entry's account name.
    ///   - service: The Keychain service; tests pass their own.
    /// - Note: Deleting an entry that doesn't exist is not an error.
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
