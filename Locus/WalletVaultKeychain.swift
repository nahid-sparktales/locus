import Foundation
import Security

/// The signer is an XPC service, where the legacy file-based Keychain may need
/// UI to validate the service's code-signing ACL and fail with
/// `errSecInteractionNotAllowed`. Its provisioning-authorized access group
/// lets it use the noninteractive data-protection Keychain instead.
enum WalletVaultKeychainQuery {
    static let accessGroup = "4X4RJA7GMD.io.sparktales.locus.WalletSigner"

    static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func add(
        service: String,
        account: String,
        keyData: Data
    ) -> [String: Any] {
        var query = base(service: service, account: account)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return query
    }
}
