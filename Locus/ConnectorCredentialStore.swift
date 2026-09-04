import Foundation
import Security

enum ConnectorCredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .invalidCredential:
            "The saved connector credential is invalid."
        }
    }
}

/// Dedicated Keychain storage for connector secrets. The backend receives only
/// public connection ids and normalized event data; this payload is never sent
/// over the agent socket or written to the run database.
final class ConnectorCredentialStore {
    static let shared = ConnectorCredentialStore()
    private let service = "io.sparktales.locus.connector"
    private let updateItem: (CFDictionary, CFDictionary) -> OSStatus
    private let addItem: (CFDictionary) -> OSStatus

    init(
        updateItem: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
        addItem: @escaping (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) {
        self.updateItem = updateItem
        self.addItem = addItem
    }

    func save(_ value: [String: String], for connectionID: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
        ]
        // Updating preserves the last usable credential if Keychain is locked
        // or a refresh fails. Delete-then-add would lose it on either failure.
        let updated = updateItem(query as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw ConnectorCredentialStoreError.keychain(updated)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = addItem(item as CFDictionary)
        if status == errSecDuplicateItem {
            // Another save may have created it after our initial lookup.
            status = updateItem(query as CFDictionary, [
                kSecValueData as String: data,
            ] as CFDictionary)
        }
        guard status == errSecSuccess else { throw ConnectorCredentialStoreError.keychain(status) }
    }

    func load(for connectionID: String) throws -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ConnectorCredentialStoreError.keychain(status)
        }
        guard let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw ConnectorCredentialStoreError.invalidCredential
        }
        return value
    }

    func delete(for connectionID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectorCredentialStoreError.keychain(status)
        }
    }
}
