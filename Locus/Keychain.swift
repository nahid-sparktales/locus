import Foundation
import Security

/// Keychain storage for provider API keys.
///
/// A key never goes into UserDefaults or the agent's config file: it lives in
/// the login keychain and is handed to the local agent process in memory.
enum Keychain {
    /// The single pre-accounts endpoint key. Kept for the one-time migration
    /// that turns it into a provider account.
    static let remoteAPIKeyAccount = "remote-api-key"

    /// One entry per provider account, so two accounts for the same provider
    /// never share a secret.
    static func providerAccountKey(_ id: UUID) -> String {
        "\(providerAccountPrefix)\(id.uuidString)"
    }

    static let providerAccountPrefix = "provider-account-"

    private static let service = "io.sparktales.locus"

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(account: account) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available without unlocking on every app launch, but never
            // synced to iCloud or another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func has(account: String) -> Bool {
        get(account: account)?.isEmpty == false
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every account name Locus has stored. Used to sweep up keys whose
    /// account was deleted while the app was not running to see it.
    static func allAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let entries = item as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Deletes provider-account keys with no matching account — the residue of
    /// a crash between writing the key and saving the account list.
    static func removeOrphanedProviderKeys(keeping liveAccounts: Set<String>) {
        for account in allAccounts()
        where account.hasPrefix(providerAccountPrefix) && !liveAccounts.contains(account) {
            remove(account: account)
        }
    }
}
