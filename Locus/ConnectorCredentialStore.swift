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
protocol ConnectorCredentialStoring: Sendable {
    func save(_ value: [String: String], for connectionID: String) throws
    func load(for connectionID: String) throws -> [String: String]?
    func delete(for connectionID: String) throws
}

/// The production adapter keeps the original service, Keychain operations,
/// and authentication behavior. Security framework access is thread-safe.
final class ConnectorCredentialStore: ConnectorCredentialStoring {
    static let shared = ConnectorCredentialStore()
    private let service = AppEdition.current.keychainService("connector")
    private let updateItem: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    private let addItem: @Sendable (CFDictionary) -> OSStatus

    init(
        updateItem: @escaping @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        addItem: @escaping @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
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

/// Per-fixture event-connector secrets. There is no Keychain or disk fallback.
final class InMemoryConnectorCredentialStore: ConnectorCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]

    func save(_ value: [String: String], for connectionID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[connectionID] = value
    }

    func load(for connectionID: String) throws -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return values[connectionID]
    }

    func delete(for connectionID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: connectionID)
    }
}
