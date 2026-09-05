import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Recovery-secret wire models intentionally live in the signer target rather
/// than the shared protocol source compiled into the main Locus process.
private struct WalletVaultCreation: Codable, Equatable, Sendable {
    let words: [String]
    let verificationIndices: [Int]
    var purpose: WalletVaultCreationPurpose = .create
}

private struct WalletBackupConfirmation: Codable, Equatable, Sendable {
    let wordsByIndex: [Int: String]
}

private struct WalletVaultRestoreRequest: Codable, Equatable, Sendable {
    let words: [String]
}

@_silgen_name("locus_wallet_generate_vault_json")
private func rustGenerateVault() -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_restore_vault_json")
private func rustRestoreVault(_ phrase: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_derive_accounts_json")
private func rustDeriveAccounts(_ entropyHex: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_evm_transaction_json")
private func rustPrepareEVMTransaction(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_evm_transaction_json")
private func rustSignEVMTransaction(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_structured_authorization_json")
private func rustSignStructuredAuthorization(
    _ entropyHex: UnsafePointer<CChar>,
    _ requestJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_solana_native_transfer_json")
private func rustPrepareSolanaNativeTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_solana_native_transfer_json")
private func rustSignSolanaNativeTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_solana_spl_transfer_json")
private func rustPrepareSolanaSPLTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_solana_spl_transfer_json")
private func rustSignSolanaSPLTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_solana_core_transfer_json")
private func rustPrepareSolanaCoreTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_solana_core_transfer_json")
private func rustSignSolanaCoreTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_sui_native_transfer_json")
private func rustPrepareSuiNativeTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_sui_native_transfer_json")
private func rustSignSuiNativeTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_sui_coin_transfer_json")
private func rustPrepareSuiCoinTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_sui_coin_transfer_json")
private func rustSignSuiCoinTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_prepare_sui_object_transfer_json")
private func rustPrepareSuiObjectTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_sign_sui_object_transfer_json")
private func rustSignSuiObjectTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_derive_solana_associated_token_json")
private func rustDeriveSolanaAssociatedToken(
    _ requestJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_encode_contract_call_json")
private func rustEncodeContractCall(_ requestJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_string_free")
private func rustFreeString(_ value: UnsafeMutablePointer<CChar>)

private struct RustGeneratedVault: Decodable {
    let entropyHex: String
    let words: [String]
}

private struct RustPreparedEVM: Decodable {
    let from: String
    let digest: String
}

private struct RustSignedEVM: Decodable {
    let from: String
    let digest: String
    let rawTransaction: String
    let transactionHash: String
}

private struct RustStructuredAuthorizationRequest: Encodable {
    let format: String
    let canonicalMessage: String
    let expectedAddress: String
}

private struct RustSignedStructuredAuthorization: Decodable {
    let address: String
    let messageDigest: String
    let signature: String
    let signatureEncoding: WalletStructuredAuthorizationSignatureEncoding
}

private struct RustPreparedSolana: Decodable {
    let from: String
    let canonicalMessageDigest: String
}

private struct RustSignedSolana: Decodable {
    let from: String
    let canonicalMessageDigest: String
    let transactionID: String
    let signedTransaction: String
}

private struct RustPreparedSui: Decodable {
    let from: String
    let chainIdentifier: String
    let transactionDigest: String
    let signingDigest: String
    let transactionBCS: String
}

private struct RustSignedSui: Decodable {
    let from: String
    let chainIdentifier: String
    let transactionDigest: String
    let signingDigest: String
    let transactionBCS: String
    let signature: String
}

private struct RustEncodedContractCall: Decodable {
    let input: String
}

private struct RustContractCallRequest: Encodable {
    let normalizedABI: String
    let function: String
    let arguments: [WalletTypedArgument]
}

private struct RustEVMTransaction: Encodable {
    let chainID: UInt64
    let nonce: UInt64
    let gasLimit: UInt64
    let maxFeePerGas: String
    let maxPriorityFeePerGas: String
    let to: String
    let value: String
    let input: String
}

private struct RustSolanaNativeTransfer: Encodable {
    let feePayer: String
    let recipient: String
    let recentBlockhash: String
    let amountBaseUnits: String
    let computeUnitLimit: UInt32
    let computeUnitPriceMicroLamports: String
}

private struct RustSolanaSPLTransfer: Encodable {
    let feePayer: String
    let sourceTokenAccount: String
    let mint: String
    let destinationTokenAccount: String
    let recipientOwner: String
    let tokenProgramID: String
    let associatedTokenProgramID: String
    let createDestinationAssociatedAccount: Bool
    let recentBlockhash: String
    let amountBaseUnits: String
    let decimals: UInt8
    let computeUnitLimit: UInt32
    let computeUnitPriceMicroLamports: String
}

private struct RustSolanaCoreTransfer: Encodable {
    let feePayer: String
    let asset: String
    let recipient: String
    let recentBlockhash: String
    let computeUnitLimit: UInt32
    let computeUnitPriceMicroLamports: String
}

private struct RustSolanaAssociatedTokenRequest: Encodable {
    let owner: String
    let mint: String
    let tokenProgramID: String
}

private struct RustSolanaAssociatedTokenAddress: Decodable {
    let address: String
    let bump: UInt8
}

private struct RustSuiNativeTransfer: Encodable {
    let chainIdentifier: String
    let sender: String
    let recipient: String
    let gasObjectID: String
    let gasObjectVersion: UInt64
    let gasObjectDigest: String
    let gasBalanceBaseUnits: String
    let amountBaseUnits: String
    let referenceGasPriceBaseUnits: String
    let gasPriceBaseUnits: String
    let gasBudgetBaseUnits: String
    let currentEpoch: UInt64
    let expirationEpoch: UInt64
}

private struct RustSuiCoinTransfer: Encodable {
    let chainIdentifier: String
    let sender: String
    let recipient: String
    let coinType: String
    let coinObjectID: String
    let coinObjectVersion: UInt64
    let coinObjectDigest: String
    let coinBalanceBaseUnits: String
    let gasObjectID: String
    let gasObjectVersion: UInt64
    let gasObjectDigest: String
    let gasBalanceBaseUnits: String
    let amountBaseUnits: String
    let referenceGasPriceBaseUnits: String
    let gasPriceBaseUnits: String
    let gasBudgetBaseUnits: String
    let currentEpoch: UInt64
    let expirationEpoch: UInt64
}

private struct RustSuiObjectTransfer: Encodable {
    let chainIdentifier: String
    let sender: String
    let recipient: String
    let objectID: String
    let objectVersion: UInt64
    let objectDigest: String
    let objectType: String
    let hasPublicTransfer: Bool
    let gasObjectID: String
    let gasObjectVersion: UInt64
    let gasObjectDigest: String
    let gasBalanceBaseUnits: String
    let referenceGasPriceBaseUnits: String
    let gasPriceBaseUnits: String
    let gasBudgetBaseUnits: String
    let currentEpoch: UInt64
    let expirationEpoch: UInt64
}

private struct StoredEVMIntent {
    let transaction: WalletEVMTransactionFields
    var prepared: WalletPreparedTransaction
    var explicitlyApproved = false
}

private struct StoredSolanaIntent {
    let packet: WalletSolanaPreparationPacket
    var prepared: WalletPreparedTransaction
    var explicitlyApproved = false
}

private struct StoredSuiIntent {
    let packet: WalletSuiPreparationPacket
    let rust: RustPreparedSui
    var prepared: WalletPreparedTransaction
    var simulation: WalletSuiSimulationPacket?
    var explicitlyApproved = false
}

private struct SignerActivePolicy {
    let policy: WalletSessionPolicy
    var spentBaseUnits: String

    var status: WalletActivePolicyStatus {
        WalletActivePolicyStatus(policy: policy, spentBaseUnits: spentBaseUnits)
    }
}

private final class WalletRecoveryCeremonyContext {
    let id: String
    let mode: WalletRecoveryCeremonyMode
    let listener: NSXPCListener
    let delegate: WalletRecoveryBrokerListenerDelegate

    init(
        id: String,
        mode: WalletRecoveryCeremonyMode,
        listener: NSXPCListener,
        delegate: WalletRecoveryBrokerListenerDelegate
    ) {
        self.id = id
        self.mode = mode
        self.listener = listener
        self.delegate = delegate
    }
}

private enum SignerUnsignedInteger {
    static func normalize(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = normalize(lhs), let right = normalize(rhs) else { return nil }
        if left.count != right.count {
            return left.count < right.count ? .orderedAscending : .orderedDescending
        }
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    static func multiply(_ lhs: String, _ rhs: String) -> String? {
        guard let left = normalize(lhs), let right = normalize(rhs) else { return nil }
        if left == "0" || right == "0" { return "0" }
        let a = left.reversed().map { Int(String($0))! }
        let b = right.reversed().map { Int(String($0))! }
        var product = Array(repeating: 0, count: a.count + b.count)
        for (leftIndex, leftDigit) in a.enumerated() {
            for (rightIndex, rightDigit) in b.enumerated() {
                product[leftIndex + rightIndex] += leftDigit * rightDigit
            }
        }
        for index in 0..<(product.count - 1) {
            product[index + 1] += product[index] / 10
            product[index] %= 10
        }
        while product.last == 0 { product.removeLast() }
        return product.reversed().map(String.init).joined()
    }

    static func add(_ lhs: String, _ rhs: String) -> String? {
        guard let left = normalize(lhs), let right = normalize(rhs) else { return nil }
        var a = left.reversed().map { Int(String($0))! }
        let b = right.reversed().map { Int(String($0))! }
        if a.count < b.count { a.append(contentsOf: repeatElement(0, count: b.count - a.count)) }
        var carry = 0
        for index in 0..<a.count {
            let total = a[index] + (index < b.count ? b[index] : 0) + carry
            a[index] = total % 10
            carry = total / 10
        }
        if carry > 0 { a.append(carry) }
        return a.reversed().map(String.init).joined()
    }

    static func subtract(_ lhs: String, _ rhs: String) -> String? {
        guard let left = normalize(lhs), let right = normalize(rhs),
              compare(left, right) != .orderedAscending else { return nil }
        var a = left.reversed().map { Int(String($0))! }
        let b = right.reversed().map { Int(String($0))! }
        var borrow = 0
        for index in 0..<a.count {
            var digit = a[index] - borrow - (index < b.count ? b[index] : 0)
            if digit < 0 {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            a[index] = digit
        }
        guard borrow == 0 else { return nil }
        while a.count > 1, a.last == 0 { a.removeLast() }
        return a.reversed().map(String.init).joined()
    }

    static func solanaPriorityFee(
        computeUnitLimit: UInt32,
        priceMicroLamports: String
    ) -> String? {
        guard computeUnitLimit > 0, computeUnitLimit <= 1_400_000,
              UInt64(priceMicroLamports) != nil,
              let microLamports = multiply(
                  String(computeUnitLimit), priceMicroLamports
              ), let normalized = normalize(microLamports) else { return nil }
        guard normalized != "0" else { return "0" }
        if normalized.count <= 6 { return "1" }
        let split = normalized.index(normalized.endIndex, offsetBy: -6)
        let whole = String(normalized[..<split])
        let remainder = normalized[split...]
        return remainder.allSatisfy({ $0 == "0" })
            ? whole : add(whole, "1")
    }

    static func lessThanOrEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let comparison = compare(lhs, rhs) else { return false }
        return comparison != .orderedDescending
    }
}

private final class WalletOwnerAuthenticationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false

    func store(_ succeeded: Bool) {
        lock.lock()
        self.succeeded = succeeded
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }
}

private struct WalletOwnerAuthenticator {
    func authenticate(reason: String) throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &policyError
        ) else {
            throw WalletVaultStore.StoreError.authentication
        }

        let completion = WalletOwnerAuthenticationResult()
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        ) { succeeded, _ in
            completion.store(succeeded)
            semaphore.signal()
        }
        semaphore.wait()
        guard completion.load() else {
            throw WalletVaultStore.StoreError.authentication
        }
    }
}

private final class WalletVaultStore {
    enum StoreError: LocalizedError {
        case random
        case keychain(OSStatus)
        case malformedVault
        case authentication

        var errorDescription: String? {
            switch self {
            case .random: "Secure random generation failed."
            case .keychain(errSecMissingEntitlement):
                "The vault key could not be stored because this build's Keychain "
                    + "configuration is invalid (\(errSecMissingEntitlement))."
            case .keychain(errSecInteractionNotAllowed):
                "The vault key could not be stored because macOS blocked secure "
                    + "storage for this build. Unlock your Mac and try again; if "
                    + "the error remains, install a properly signed build "
                    + "(\(errSecInteractionNotAllowed))."
            case .keychain(let status): "Keychain operation failed (\(status))."
            case .malformedVault: "The encrypted Locus Vault cannot be read."
            case .authentication: "Local authentication was not completed."
            }
        }
    }

    private let productionService = "io.sparktales.locus.WalletSigner.wrap.v2"
    private let productionAccount = "locus-mainnet-vault"
    private let legacyService = "io.sparktales.locus.WalletSigner.wrap.v1"
    private let legacyAccount = "locus-vault"
    private let fileManager = FileManager.default
    private let authenticator = WalletOwnerAuthenticator()

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LocusWalletSigner", isDirectory: true)
    }

    var vaultURL: URL { directory.appendingPathComponent("vault-mainnet-v2.aesgcm") }
    var accountsURL: URL { directory.appendingPathComponent("accounts-mainnet-v2.json") }
    var legacyVaultURL: URL { directory.appendingPathComponent("vault-v1.aesgcm") }
    var legacyAccountsURL: URL { directory.appendingPathComponent("accounts-v1.json") }
    var exists: Bool { fileManager.fileExists(atPath: vaultURL.path) }
    var legacyExists: Bool { fileManager.fileExists(atPath: legacyVaultURL.path) }

    func create(entropy: Data, accounts: [WalletAccount]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var keyData = Data(count: 32)
        let status = keyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw StoreError.random }
        defer { keyData.resetBytes(in: 0..<keyData.count) }

        SecItemDelete(productionQuery() as CFDictionary)
        let query = WalletVaultKeychainQuery.add(
            service: productionService,
            account: productionAccount,
            keyData: keyData
        )
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }

        do {
            let sealed = try AES.GCM.seal(entropy, using: SymmetricKey(data: keyData))
            guard let combined = sealed.combined else { throw StoreError.malformedVault }
            try combined.write(to: vaultURL, options: [.atomic])
            try JSONEncoder().encode(accounts).write(to: accountsURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsURL.path)
        } catch {
            SecItemDelete(productionQuery() as CFDictionary)
            try? fileManager.removeItem(at: vaultURL)
            try? fileManager.removeItem(at: accountsURL)
            throw error
        }
    }

    func decrypt(reason: String) throws -> Data {
        try authenticator.authenticate(reason: reason)
        var query = productionQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let keyData = result as? Data else {
            throw status == errSecUserCanceled || status == errSecAuthFailed
                ? StoreError.authentication : StoreError.keychain(status)
        }
        var mutableKey = keyData
        defer { mutableKey.resetBytes(in: 0..<mutableKey.count) }
        let sealedData = try Data(contentsOf: vaultURL)
        let box = try AES.GCM.SealedBox(combined: sealedData)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }

    func accounts() throws -> [WalletAccount] {
        let url = exists ? accountsURL : legacyAccountsURL
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([WalletAccount].self, from: Data(contentsOf: url))
    }

    func delete(reason: String) throws {
        var key = try decrypt(reason: reason)
        key.resetBytes(in: 0..<key.count)
        try? fileManager.removeItem(at: vaultURL)
        try? fileManager.removeItem(at: accountsURL)
        let status = SecItemDelete(productionQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    func deleteLegacy(reason: String) throws {
        var query = legacyQuery()
        let context = LAContext()
        context.localizedReason = reason
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard copyStatus == errSecSuccess, var keyData = result as? Data else {
            throw copyStatus == errSecUserCanceled || copyStatus == errSecAuthFailed
                ? StoreError.authentication : StoreError.keychain(copyStatus)
        }
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        let sealedData = try Data(contentsOf: legacyVaultURL)
        let box = try AES.GCM.SealedBox(combined: sealedData)
        var entropy = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        entropy.resetBytes(in: 0..<entropy.count)
        try? fileManager.removeItem(at: legacyVaultURL)
        try? fileManager.removeItem(at: legacyAccountsURL)
        let status = SecItemDelete(legacyQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private func productionQuery() -> [String: Any] {
        baseQuery(service: productionService, account: productionAccount)
    }

    private func legacyQuery() -> [String: Any] {
        baseQuery(service: legacyService, account: legacyAccount)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        WalletVaultKeychainQuery.base(service: service, account: account)
    }
}

final class WalletSignerService: NSObject, WalletSignerXPCProtocol, WalletRecoverySignerXPCProtocol {
    private static let protocolVersion = 3
    private static let maximumPreparedIntents = 32
    private static let maximumActivePolicies = 32
    private let queue = DispatchQueue(label: "io.sparktales.locus.wallet-signer")
    private let store = WalletVaultStore()
    private var launchGate: WalletLaunchGate?
    private var reviewRegistry: WalletReviewRegistry?
    private let bundledReviewCeiling: WalletReviewRegistry?
    private let immutableReviewCeiling: WalletSignedReviewCeiling?
    private var verifiedReleaseAuthority: WalletVerifiedReleaseAuthority?
    private let activationPublicKey: Curve25519.Signing.PublicKey?
    private var activeActivationDigest: String?
    private var activationExpiryTimer: DispatchSourceTimer?
    private let regionCode: String
    private var pendingEntropy: Data?
    private var pendingWords: [String] = []
    private var pendingIndices: [Int] = []
    private var pendingPurpose: WalletVaultCreationPurpose = .create
    private var unlockedEntropy: Data?
    private var activeSessionID: String?
    private var preparedIntents: [String: StoredEVMIntent] = [:]
    private var preparedSolanaIntents: [String: StoredSolanaIntent] = [:]
    private var preparedSuiIntents: [String: StoredSuiIntent] = [:]
    private var activePolicies: [String: SignerActivePolicy] = [:]
    private var pendingPresenceIntents: Set<String> = []
    private var consumedAuthorizationKeys: [String: Date] = [:]
    private var policyPresencePending = false
    private var recoveryCeremony: WalletRecoveryCeremonyContext?

    override init() {
        let ceiling = Self.loadReviewRegistry()
        launchGate = nil
        reviewRegistry = ceiling
        bundledReviewCeiling = ceiling
        immutableReviewCeiling = WalletSignedReviewCeiling.loadBundled()
        activationPublicKey = Self.loadActivationPublicKey()
        regionCode = (Locale.current.region?.identifier ?? "ZZ").uppercased()
        super.init()
    }

    func invalidateConnection() {
        queue.async {
            self.lockInMemory()
            self.clearRecoveryCeremony()
        }
    }

    func status(reply: @escaping (Data) -> Void) {
        queue.async { reply(self.encoded(self.currentStatus())) }
    }

    func applyReleaseActivation(_ request: Data, reply: @escaping (Data) -> Void) {
        // Protocol v3's legacy selector confers no release authority. Production
        // activation requires the independently verified version-2 history.
        reply(self.error("Wallet activation requires verified transition history."))
    }

    func releaseAuthorityStatus(reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                reply(self.encoded(WalletReleaseAuthorityStatus(
                    installationID: try WalletSignerReleaseAuthorityStore.installationID(),
                    checkpoint: try WalletSignerReleaseAuthorityStore.load())))
            } catch { reply(self.error(error.localizedDescription)) }
        }
    }

    func applyReleaseHistory(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                guard request.count <= WalletReleaseHistoryVerifier.maximumHistoryBytes,
                      let publicKey = self.activationPublicKey,
                      let ceiling = self.immutableReviewCeiling,
                      let identity = WalletInstalledReleaseIdentity.current(
                        signerBundle: .main
                      ) else {
                    throw WalletReleaseActivationError.identityMismatch
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let signed = try decoder.decode(
                    WalletReleaseHistoryRequest.self, from: request
                )
                let accepted = try WalletSignerReleaseAuthorityStore.load()
                let installation = try WalletSignerReleaseAuthorityStore.installationID()
                let verified = try WalletReleaseHistoryVerifier.verify(signed, ceiling: ceiling,
                    key: publicKey, identity: identity, previous: accepted, installationID: installation)
                try WalletSignerReleaseAuthorityStore.store(verified.checkpoint)
                let admitted = (try? verified.requireAdmission(installationID: installation)) != nil
                self.launchGate = admitted ? verified.launchGate : nil
                self.reviewRegistry = verified.reviewRegistry
                let authorityChanged = self.verifiedReleaseAuthority?.checkpoint != verified.checkpoint
                self.verifiedReleaseAuthority = verified
                let digest = verified.checkpoint.digest
                if self.activeActivationDigest != digest || authorityChanged {
                    self.clearActivationBoundAuthority()
                    self.activeActivationDigest = digest
                    self.activationExpiryTimer?.cancel()
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + max(0, verified.authorityExpiresAt.timeIntervalSinceNow))
                    timer.setEventHandler { [weak self] in
                        guard self?.activeActivationDigest == digest else { return }
                        self?.clearActivationBoundAuthority()
                        self?.launchGate = nil
                        self?.activeActivationDigest = nil
                    }
                    self.activationExpiryTimer = timer
                    timer.resume()
                }
                reply(self.encoded(WalletReleaseAuthorityStatus(installationID: installation,
                    checkpoint: verified.checkpoint)))
            } catch {
                reply(self.error(error.localizedDescription))
            }
        }
    }

    func beginRecoveryCeremony(
        _ request: Data,
        reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void
    ) {
        queue.async {
            do {
                let ceremony = try JSONDecoder().decode(
                    WalletRecoveryCeremonyRequest.self, from: request
                )
                guard self.recoveryCeremony == nil, self.pendingEntropy == nil else {
                    return reply(self.error("Another recovery ceremony is already active."), nil)
                }
                #if DEBUG
                let presentationOnly = ceremony.allowPresentationOverExistingVaultForUITesting
                #else
                let presentationOnly = false
                #endif
                switch ceremony.mode {
                case .create, .restore:
                    guard presentationOnly || (!self.store.exists && !self.store.legacyExists) else {
                        return reply(self.error("A Locus Vault already exists."), nil)
                    }
                case .rotateForMainnet:
                    guard presentationOnly || (self.store.legacyExists && !self.store.exists) else {
                        return reply(self.error("No preview vault requires mainnet rotation."), nil)
                    }
                }
                self.lockInMemory()
                let id = UUID().uuidString.lowercased()
                let listener = NSXPCListener.anonymous()
                let delegate = WalletRecoveryBrokerListenerDelegate(owner: self, ceremonyID: id)
                listener.delegate = delegate
                self.recoveryCeremony = WalletRecoveryCeremonyContext(
                    id: id, mode: ceremony.mode, listener: listener, delegate: delegate
                )
                listener.resume()
                reply(
                    self.encoded(WalletRecoveryCeremonyHandle(id: id, mode: ceremony.mode)),
                    listener.endpoint
                )
            } catch {
                reply(self.error("Recovery ceremony could not start: \(error.localizedDescription)"), nil)
            }
        }
    }

    func cancelRecoveryCeremony(_ ceremonyID: String, reply: @escaping (Data) -> Void) {
        queue.async {
            guard self.recoveryCeremony?.id == ceremonyID else {
                return reply(self.error("The recovery ceremony is no longer active."))
            }
            self.lockInMemory()
            self.clearRecoveryCeremony()
            reply(self.encoded(self.currentStatus()))
        }
    }

    func authorizeSession(_ reason: String, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                guard self.store.exists else {
                    throw self.signerError(self.store.legacyExists
                        ? "Rotate the private-alpha vault before using mainnet signing."
                        : "Create or restore a Locus Vault first.")
                }
                self.lockInMemory()
                self.unlockedEntropy = try self.store.decrypt(reason: reason)
                self.activeSessionID = UUID().uuidString.lowercased()
                reply(self.encoded(self.currentStatus()))
            } catch {
                self.lockInMemory()
                reply(self.error(error.localizedDescription))
            }
        }
    }

    func listAccounts(reply: @escaping (Data) -> Void) {
        queue.async {
            do { reply(self.encoded(try self.store.accounts())) }
            catch { reply(self.error(error.localizedDescription)) }
        }
    }

    func encodeEVMContract(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletContractEncodingRequest> =
                    try self.authorized(request)
                if authorized.payload.action.type == .contractCall,
                   authorized.source != .agent {
                    throw self.signerError(
                        "Connected peers cannot register or encode general contract calls."
                    )
                }
                reply(self.encoded(try self.authoritativeContractEncoding(authorized.payload)))
            } catch {
                reply(self.error("Contract encoding failed: \(error.localizedDescription)"))
            }
        }
    }

    func signStructuredAuthorization(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletStructuredAuthorizationRequest> =
                    try self.authorized(request)
                let authorization = authorized.payload
                guard self.unlockedEntropy != nil,
                      let account = try self.store.accounts().first(where: {
                          $0.id == authorization.accountID
                              && $0.ownership == .locusVault
                      }) else {
                    throw self.signerError("The Locus Vault account is unavailable.")
                }
                switch authorized.source.kind {
                case .browser, .embeddedBrowser:
                    guard authorized.source.origin == authorization.origin else {
                        throw self.signerError(
                            "The sign-in origin changed before signer authorization."
                        )
                    }
                case .walletConnectPeer:
                    guard authorized.source.peerID?.isEmpty == false,
                          authorized.source.origin == nil
                            || authorized.source.origin == authorization.origin else {
                        throw self.signerError(
                            "The WalletConnect peer binding changed before signer authorization."
                        )
                    }
                case .agent, .humanUI:
                    break
                }
                try self.authorizeStructuredSignIn(authorization)
                let canonical = try WalletStructuredAuthorization.canonicalMessage(
                    authorization, account: account
                )
                let key = self.authorizationReplayKey(authorization)
                let now = Date()
                self.consumedAuthorizationKeys = self.consumedAuthorizationKeys.filter {
                    $0.value > now
                }
                guard self.consumedAuthorizationKeys[key] == nil,
                      self.pendingPresenceIntents.insert("authorization:\(key)").inserted else {
                    throw self.signerError(
                        "This structured authorization was already used or is awaiting approval."
                    )
                }
                let sessionID = authorized.sessionID
                self.requireUserPresence(
                    reason: "Approve \(authorization.format == .siwe ? "Ethereum" : "Solana") sign-in for \(authorization.domain)"
                ) { result in
                    self.pendingPresenceIntents.remove("authorization:\(key)")
                    guard self.activeSessionID == sessionID,
                          let entropy = self.unlockedEntropy else {
                        return reply(self.error(
                            "Structured authorization failed: Locus Vault locked while approval was pending."
                        ))
                    }
                    switch result {
                    case .failure(let error):
                        reply(self.error(
                            "Structured authorization failed: \(error.localizedDescription)"
                        ))
                    case .success:
                        do {
                            let signedAt = Date()
                            try self.authorizeStructuredSignIn(authorization)
                            try WalletStructuredAuthorization.validate(
                                authorization, account: account, now: signedAt
                            )
                            guard self.consumedAuthorizationKeys[key] == nil else {
                                throw self.signerError(
                                    "This structured authorization was already consumed."
                                )
                            }
                            // Consume before signing. A failed response cannot
                            // be retried into a second authorization prompt.
                            self.consumedAuthorizationKeys[key] = authorization.expirationTime
                            let signed = try self.rustStructuredAuthorization(
                                format: authorization.format,
                                canonicalMessage: canonical,
                                expectedAddress: account.address,
                                entropy: entropy
                            )
                            let addressMatches = account.chain == .evm
                                ? signed.address.caseInsensitiveCompare(account.address) == .orderedSame
                                : signed.address == account.address
                            guard addressMatches else {
                                throw self.signerError(
                                    "The signing core used a different account."
                                )
                            }
                            reply(self.encoded(WalletStructuredAuthorizationResult(
                                request: authorization,
                                canonicalMessage: canonical,
                                messageDigest: signed.messageDigest,
                                signature: signed.signature,
                                signatureEncoding: signed.signatureEncoding,
                                signedAt: signedAt
                            )))
                        } catch {
                            reply(self.error(
                                "Structured authorization failed: \(error.localizedDescription)"
                            ))
                        }
                    }
                }
            } catch {
                reply(self.error(
                    "Structured authorization failed: \(error.localizedDescription)"
                ))
            }
        }
    }

    func prepareEVM(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletEVMPreparationPacket> =
                    try self.authorized(request)
                let packet = authorized.payload
                guard packet.request.source == authorized.source else {
                    throw self.signerError("The request source changed before signer preparation.")
                }
                guard let entropy = self.unlockedEntropy else {
                    throw self.signerError("Locus Vault is locked.")
                }
                self.expireIntents()
                guard self.preparedIntents.count < Self.maximumPreparedIntents else {
                    throw self.signerError("Too many wallet intents are pending for this session.")
                }
                let intent: StoredEVMIntent
                switch packet.request.action.type {
                case .nativeTransfer:
                    intent = try self.prepareNativeTransfer(packet: packet, entropy: entropy)
                case .contractCall, .fungibleTokenTransfer, .nftTransfer,
                     .exactInputSwap, .swapAllowanceSetup:
                    intent = try self.prepareContractCall(packet: packet, entropy: entropy)
                case .reviewedCall, .standardizedSignIn,
                     .reviewedTypedAuthorization:
                    throw self.signerError(
                        "The requested semantic action has no reviewed signer adapter."
                    )
                }
                self.preparedIntents[intent.prepared.id] = intent
                reply(self.encoded(intent.prepared))
            } catch {
                reply(self.error("Transaction preparation failed: \(error.localizedDescription)"))
            }
        }
    }

    func simulateEVM(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletEVMRecheckPacket> =
                    try self.authorized(request)
                let recheck = authorized.payload
                var intent = try self.validatedIntent(for: recheck)
                guard intent.prepared.source == authorized.source else {
                    throw self.signerError("The request source changed before transaction recheck.")
                }
                intent.prepared = self.rechecked(intent.prepared, using: recheck)
                self.preparedIntents[recheck.intentID] = intent
                reply(self.encoded(intent.prepared))
            } catch {
                reply(self.error("Transaction recheck failed: \(error.localizedDescription)"))
            }
        }
    }

    func confirmEVM(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<String> = try self.authorized(request)
                guard let intent = self.preparedIntents[authorized.payload],
                      intent.prepared.expiresAt > Date(),
                      intent.prepared.source == authorized.source else {
                    throw self.signerError("The prepared transaction is missing, expired, or belongs to another source.")
                }
                if WalletNetworkCatalog.descriptor(id: intent.prepared.networkID)?.environment == .mainnet {
                    guard self.pendingPresenceIntents.insert(authorized.payload).inserted else {
                        throw self.signerError("User presence is already pending for this transaction.")
                    }
                    self.requireUserPresence(
                        reason: "Approve this exact Locus Vault mainnet transaction"
                    ) { result in
                        self.pendingPresenceIntents.remove(authorized.payload)
                        guard self.activeSessionID == authorized.sessionID,
                              self.unlockedEntropy != nil else {
                            return reply(self.error("Transaction confirmation failed: Locus Vault locked while approval was pending."))
                        }
                        switch result {
                        case .failure(let error):
                            reply(self.error("Transaction confirmation failed: \(error.localizedDescription)"))
                        case .success:
                            guard var current = self.preparedIntents[authorized.payload],
                                  current.prepared == intent.prepared,
                                  current.prepared.expiresAt > Date() else {
                                return reply(self.error("Transaction confirmation failed: the intent changed or expired."))
                            }
                            current.explicitlyApproved = true
                            self.preparedIntents[authorized.payload] = current
                            reply(self.encoded(current.prepared))
                        }
                    }
                    return
                }
                var approved = intent
                approved.explicitlyApproved = true
                self.preparedIntents[authorized.payload] = approved
                reply(self.encoded(approved.prepared))
            } catch {
                reply(self.error("Transaction confirmation failed: \(error.localizedDescription)"))
            }
        }
    }

    func executeEVM(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletEVMRecheckPacket> =
                    try self.authorized(request)
                guard let entropy = self.unlockedEntropy else {
                    throw self.signerError("Locus Vault is locked.")
                }
                let recheck = authorized.payload
                let validated = try self.validatedIntent(for: recheck)
                guard validated.prepared.source == authorized.source else {
                    throw self.signerError("The transaction belongs to another request source.")
                }
                let automaticPolicyID: String?
                if validated.explicitlyApproved {
                    automaticPolicyID = nil
                } else {
                    let currentPolicyID = try self.validAutomaticPolicyID(for: validated.prepared)
                    guard currentPolicyID == validated.prepared.policyID else {
                        throw self.signerError(
                            "The autonomous policy changed after transaction preparation."
                        )
                    }
                    automaticPolicyID = currentPolicyID
                }
                // Consume before signing. If signing or broadcasting later
                // fails, this exact intent can never be replayed.
                guard let intent = self.preparedIntents.removeValue(forKey: recheck.intentID) else {
                    return reply(self.error("The prepared transaction was already consumed."))
                }
                try self.reserveCanaryBudget(for: intent.prepared)
                let signed = try self.rustSign(transaction: intent.transaction, entropy: entropy)
                guard signed.digest.caseInsensitiveCompare(intent.prepared.digest) == .orderedSame,
                      signed.from.caseInsensitiveCompare(try self.evmAddress()) == .orderedSame else {
                    return reply(self.error("The signing core returned mismatched transaction material."))
                }
                if let policyID = automaticPolicyID {
                    try self.reserveBudget(for: intent.prepared, policyID: policyID)
                }
                reply(self.encoded(WalletEVMSignedTransaction(
                    intentID: recheck.intentID,
                    digest: signed.digest,
                    rawTransaction: signed.rawTransaction,
                    transactionHash: signed.transactionHash
                )))
            } catch {
                reply(self.error("Transaction execution failed: \(error.localizedDescription)"))
            }
        }
    }

    func prepareSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSolanaPreparationPacket> =
                    try self.authorized(request)
                let packet = authorized.payload
                guard packet.request.source == authorized.source else {
                    throw self.signerError("The request source changed before Solana preparation.")
                }
                guard let entropy = self.unlockedEntropy else {
                    throw self.signerError("Locus Vault is locked.")
                }
                self.expireIntents()
                guard self.preparedIntents.count + self.preparedSolanaIntents.count
                        < Self.maximumPreparedIntents else {
                    throw self.signerError("Too many wallet intents are pending for this session.")
                }
                guard let descriptor = WalletNetworkCatalog.descriptor(id: packet.request.networkID),
                      descriptor.chain == .solana,
                      descriptor.identity.kind == .solanaGenesisHash,
                      descriptor.identity.value == packet.genesisHash else {
                    throw self.signerError("The Solana genesis identity does not match the request.")
                }
                try self.authorizeNetwork(
                    descriptor.id, chain: .solana,
                    capability: self.capability(for: packet.request.action.type)
                )
                let intent: StoredSolanaIntent
                switch packet.request.action.type {
                case .nativeTransfer:
                    intent = try self.prepareSolanaNativeTransfer(
                        packet: packet, entropy: entropy
                    )
                case .fungibleTokenTransfer:
                    intent = try self.prepareSolanaSPLTransfer(
                        packet: packet, entropy: entropy
                    )
                case .nftTransfer:
                    intent = try self.prepareSolanaCoreTransfer(
                        packet: packet, entropy: entropy
                    )
                default:
                    throw self.signerError(
                        "That Solana semantic action has no reviewed signer adapter."
                    )
                }
                self.preparedSolanaIntents[intent.prepared.id] = intent
                reply(self.encoded(intent.prepared))
            } catch {
                reply(self.error("Solana preparation failed: \(error.localizedDescription)"))
            }
        }
    }

    func deriveSolanaAssociatedToken(
        _ request: Data,
        reply: @escaping (Data) -> Void
    ) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSolanaAssociatedTokenRequest> =
                    try self.authorized(request)
                guard self.unlockedEntropy != nil else {
                    throw self.signerError("Locus Vault is locked.")
                }
                let value = authorized.payload
                guard let descriptor = WalletNetworkCatalog.descriptor(
                    id: value.networkID
                ), descriptor.chain == .solana,
                   Self.isSolanaAddress(value.owner),
                   Self.isSolanaAddress(value.mint),
                   WalletSolanaTokenProgram.allCases.contains(where: {
                     $0.programID == value.tokenProgramID
                   }) else {
                    throw self.signerError(
                        "The associated-token request uses an unreviewed program."
                    )
                }
                try self.authorizeNetwork(
                    descriptor.id, chain: .solana,
                    capability: .fungibleTokenTransfer
                )
                let derived = try self.rustAssociatedTokenAddress(
                    owner: value.owner, mint: value.mint,
                    tokenProgramID: value.tokenProgramID
                )
                reply(self.encoded(WalletSolanaAssociatedTokenAddress(
                    address: derived.address, bump: derived.bump
                )))
            } catch {
                reply(self.error(
                    "Associated-token derivation failed: \(error.localizedDescription)"
                ))
            }
        }
    }

    func simulateSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSolanaRecheckPacket> =
                    try self.authorized(request)
                let recheck = authorized.payload
                var intent = try self.validatedSolanaIntent(for: recheck)
                guard intent.prepared.source == authorized.source else {
                    throw self.signerError("The request source changed before Solana recheck.")
                }
                intent.prepared = self.recheckedSolana(intent.prepared, using: recheck)
                self.preparedSolanaIntents[recheck.intentID] = intent
                reply(self.encoded(intent.prepared))
            } catch {
                reply(self.error("Solana simulation failed: \(error.localizedDescription)"))
            }
        }
    }

    func confirmSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<String> = try self.authorized(request)
                guard let intent = self.preparedSolanaIntents[authorized.payload],
                      intent.prepared.expiresAt > Date(),
                      intent.prepared.source == authorized.source else {
                    throw self.signerError(
                        "The prepared Solana transaction is missing, expired, or belongs to another source."
                    )
                }
                if WalletNetworkCatalog.descriptor(
                    id: intent.prepared.networkID
                )?.environment == .mainnet {
                    guard self.pendingPresenceIntents.insert(authorized.payload).inserted else {
                        throw self.signerError(
                            "User presence is already pending for this transaction."
                        )
                    }
                    self.requireUserPresence(
                        reason: "Approve this exact Locus Vault Solana mainnet transaction"
                    ) { result in
                        self.pendingPresenceIntents.remove(authorized.payload)
                        guard self.activeSessionID == authorized.sessionID,
                              self.unlockedEntropy != nil else {
                            return reply(self.error(
                                "Solana confirmation failed: Locus Vault locked while approval was pending."
                            ))
                        }
                        switch result {
                        case .failure(let error):
                            reply(self.error(
                                "Solana confirmation failed: \(error.localizedDescription)"
                            ))
                        case .success:
                            guard var current = self.preparedSolanaIntents[authorized.payload],
                                  current.prepared == intent.prepared,
                                  current.prepared.expiresAt > Date() else {
                                return reply(self.error(
                                    "Solana confirmation failed: the intent changed or expired."
                                ))
                            }
                            current.explicitlyApproved = true
                            self.preparedSolanaIntents[authorized.payload] = current
                            reply(self.encoded(current.prepared))
                        }
                    }
                    return
                }
                var approved = intent
                approved.explicitlyApproved = true
                self.preparedSolanaIntents[authorized.payload] = approved
                reply(self.encoded(approved.prepared))
            } catch {
                reply(self.error("Solana confirmation failed: \(error.localizedDescription)"))
            }
        }
    }

    func executeSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSolanaRecheckPacket> =
                    try self.authorized(request)
                guard let entropy = self.unlockedEntropy else {
                    throw self.signerError("Locus Vault is locked.")
                }
                let recheck = authorized.payload
                let validated = try self.validatedSolanaIntent(for: recheck)
                guard validated.prepared.source == authorized.source else {
                    throw self.signerError(
                        "The Solana transaction belongs to another request source."
                    )
                }
                let automaticPolicyID: String?
                if validated.explicitlyApproved {
                    automaticPolicyID = nil
                } else {
                    let currentPolicyID = try self.validAutomaticPolicyID(
                        for: validated.prepared
                    )
                    guard currentPolicyID == validated.prepared.policyID else {
                        throw self.signerError(
                            "The autonomous policy changed after Solana preparation."
                        )
                    }
                    automaticPolicyID = currentPolicyID
                }
                guard let intent = self.preparedSolanaIntents.removeValue(
                    forKey: recheck.intentID
                ) else {
                    return reply(self.error(
                        "The prepared Solana transaction was already consumed."
                    ))
                }
                try self.reserveCanaryBudget(for: intent.prepared)
                let signed = try self.rustSignSolana(
                    packet: intent.packet, entropy: entropy
                )
                let vaultAddress = try self.solanaAddress()
                guard signed.from == vaultAddress,
                      signed.canonicalMessageDigest == intent.prepared.digest else {
                    return reply(self.error(
                        "The signing core returned mismatched Solana transaction material."
                    ))
                }
                if let policyID = automaticPolicyID {
                    try self.reserveBudget(for: intent.prepared, policyID: policyID)
                }
                reply(self.encoded(WalletSolanaSignedTransaction(
                    intentID: recheck.intentID,
                    transactionID: signed.transactionID,
                    canonicalMessageDigest: signed.canonicalMessageDigest,
                    signedTransaction: signed.signedTransaction
                )))
            } catch {
                reply(self.error("Solana execution failed: \(error.localizedDescription)"))
            }
        }
    }

    func prepareSui(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSuiPreparationPacket> =
                    try self.authorized(request)
                let packet = authorized.payload
                guard packet.request.source == authorized.source else {
                    throw self.signerError("The request source changed before Sui preparation.")
                }
                guard let entropy = self.unlockedEntropy else {
                    throw self.signerError("Locus Vault is locked.")
                }
                self.expireIntents()
                guard self.preparedIntents.count + self.preparedSolanaIntents.count
                        + self.preparedSuiIntents.count < Self.maximumPreparedIntents else {
                    throw self.signerError("Too many wallet intents are pending for this session.")
                }
                guard let descriptor = WalletNetworkCatalog.descriptor(id: packet.request.networkID),
                      descriptor.chain == .sui,
                      descriptor.identity.kind == .suiChainIdentifier,
                      descriptor.identity.value == packet.chainIdentifier else {
                    throw self.signerError("The Sui chain identity does not match the request.")
                }
                try self.authorizeNetwork(
                    descriptor.id, chain: .sui,
                    capability: self.capability(for: packet.request.action.type)
                )
                let intent: StoredSuiIntent
                switch packet.request.action.type {
                case .nativeTransfer:
                    intent = try self.prepareSuiNativeTransfer(
                        packet: packet, entropy: entropy
                    )
                case .fungibleTokenTransfer:
                    intent = try self.prepareSuiCoinTransfer(
                        packet: packet, entropy: entropy
                    )
                case .nftTransfer:
                    intent = try self.prepareSuiObjectTransfer(
                        packet: packet, entropy: entropy
                    )
                default:
                    throw self.signerError(
                        "That Sui semantic action has no reviewed signer adapter."
                    )
                }
                self.preparedSuiIntents[intent.prepared.id] = intent
                reply(self.encoded(WalletSuiUnsignedIntent(
                    prepared: intent.prepared,
                    transactionBCS: intent.rust.transactionBCS
                )))
            } catch {
                reply(self.error("Sui preparation failed: \(error.localizedDescription)"))
            }
        }
    }

    func simulateSui(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSuiSimulationPacket> =
                    try self.authorized(request)
                var intent = try self.validatedSuiIntent(
                    for: authorized.payload
                )
                guard intent.prepared.source == authorized.source else {
                    throw self.signerError(
                        "The request source changed before Sui simulation."
                    )
                }
                intent.prepared = self.recheckedSui(
                    intent.prepared, using: authorized.payload
                )
                if intent.simulation == nil { intent.simulation = authorized.payload }
                self.preparedSuiIntents[intent.prepared.id] = intent
                reply(self.encoded(intent.prepared))
            } catch {
                reply(self.error("Sui simulation failed: \(error.localizedDescription)"))
            }
        }
    }

    func confirmSui(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<String> = try self.authorized(request)
                guard let intent = self.preparedSuiIntents[authorized.payload],
                      intent.prepared.expiresAt > Date(),
                      intent.prepared.simulationSucceeded,
                      intent.prepared.source == authorized.source else {
                    throw self.signerError(
                        "The prepared Sui transaction is missing, unsimulated, expired, or belongs to another source."
                    )
                }
                if WalletNetworkCatalog.descriptor(
                    id: intent.prepared.networkID
                )?.environment == .mainnet {
                    guard self.pendingPresenceIntents.insert(authorized.payload).inserted else {
                        throw self.signerError(
                            "User presence is already pending for this transaction."
                        )
                    }
                    self.requireUserPresence(
                        reason: "Approve this exact Locus Vault Sui mainnet transaction"
                    ) { result in
                        self.pendingPresenceIntents.remove(authorized.payload)
                        guard self.activeSessionID == authorized.sessionID,
                              self.unlockedEntropy != nil else {
                            return reply(self.error(
                                "Sui confirmation failed: Locus Vault locked while approval was pending."
                            ))
                        }
                        switch result {
                        case .failure(let error):
                            reply(self.error(
                                "Sui confirmation failed: \(error.localizedDescription)"
                            ))
                        case .success:
                            guard var current = self.preparedSuiIntents[authorized.payload],
                                  current.prepared == intent.prepared,
                                  current.prepared.expiresAt > Date() else {
                                return reply(self.error(
                                    "Sui confirmation failed: the intent changed or expired."
                                ))
                            }
                            current.explicitlyApproved = true
                            self.preparedSuiIntents[authorized.payload] = current
                            reply(self.encoded(current.prepared))
                        }
                    }
                    return
                }
                var approved = intent
                approved.explicitlyApproved = true
                self.preparedSuiIntents[authorized.payload] = approved
                reply(self.encoded(approved.prepared))
            } catch {
                reply(self.error("Sui confirmation failed: \(error.localizedDescription)"))
            }
        }
    }

    func executeSui(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSuiRecheckPacket> =
                    try self.authorized(request)
                guard let entropy = self.unlockedEntropy else {
                    throw self.signerError("Locus Vault is locked.")
                }
                let recheck = authorized.payload
                let validated = try self.validatedSuiIntent(for: recheck)
                guard validated.prepared.source == authorized.source,
                      validated.explicitlyApproved else {
                    throw self.signerError(
                        "The Sui transaction lacks exact approval for this request source."
                    )
                }
                guard let intent = self.preparedSuiIntents.removeValue(
                    forKey: recheck.simulation.intentID
                ) else {
                    return reply(self.error(
                        "The prepared Sui transaction was already consumed."
                    ))
                }
                try self.reserveCanaryBudget(for: intent.prepared)
                let signed = try self.rustSignSui(
                    packet: intent.packet, entropy: entropy
                )
                guard signed.from == intent.packet.sender,
                      signed.chainIdentifier == intent.packet.chainIdentifier,
                      signed.transactionDigest == intent.rust.transactionDigest,
                      signed.signingDigest == intent.rust.signingDigest,
                      signed.transactionBCS == intent.rust.transactionBCS else {
                    return reply(self.error(
                        "The signing core returned mismatched Sui transaction material."
                    ))
                }
                reply(self.encoded(WalletSuiSignedTransaction(
                    intentID: recheck.simulation.intentID,
                    transactionDigest: signed.transactionDigest,
                    transactionBytes: signed.transactionBCS,
                    signature: signed.signature
                )))
            } catch {
                reply(self.error("Sui execution failed: \(error.localizedDescription)"))
            }
        }
    }

    func activatePolicy(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSessionPolicy> =
                    try self.authorized(request)
                guard authorized.source == .agent else {
                    throw self.signerError("Browser origins cannot activate autonomous policies.")
                }
                let policy = authorized.payload
                try self.validatePolicy(policy)
                guard !self.policyPresencePending else {
                    throw self.signerError("Another policy activation is awaiting user presence.")
                }
                self.policyPresencePending = true
                self.requireUserPresence(
                    reason: "Activate this Locus Vault autonomous spending rule"
                ) { result in
                    self.policyPresencePending = false
                    guard self.activeSessionID == authorized.sessionID,
                          self.unlockedEntropy != nil else {
                        return reply(self.error("Policy activation failed: Locus Vault locked while approval was pending."))
                    }
                    switch result {
                    case .failure(let error):
                        reply(self.error("Policy activation failed: \(error.localizedDescription)"))
                    case .success:
                        do {
                            try self.validatePolicy(policy)
                            self.expirePolicies()
                            guard self.activePolicies[policy.id] != nil
                                    || self.activePolicies.count < Self.maximumActivePolicies else {
                                throw self.signerError("Too many wallet policies are active for this session.")
                            }
                            self.activePolicies[policy.id] = SignerActivePolicy(
                                policy: policy, spentBaseUnits: "0"
                            )
                            reply(self.encoded(self.policyStatuses()))
                        } catch {
                            reply(self.error("Policy activation failed: \(error.localizedDescription)"))
                        }
                    }
                }
            } catch {
                reply(self.error("Policy activation failed: \(error.localizedDescription)"))
            }
        }
    }

    func listPolicies(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized = try self.authorizedSession(request)
                guard authorized.source == .agent else {
                    throw self.signerError("Browser origins cannot inspect autonomous policies.")
                }
                self.expirePolicies()
                reply(self.encoded(self.policyStatuses()))
            } catch {
                reply(self.error("Policy listing failed: \(error.localizedDescription)"))
            }
        }
    }

    func clearPolicies(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized = try self.authorizedSession(request)
                guard authorized.source == .agent else {
                    throw self.signerError("Browser origins cannot clear autonomous policies.")
                }
                self.activePolicies.removeAll(keepingCapacity: false)
                reply(self.encoded([WalletActivePolicyStatus]()))
            } catch {
                reply(self.error("Policy clearing failed: \(error.localizedDescription)"))
            }
        }
    }

    func lock(reply: @escaping (Data) -> Void) {
        queue.async {
            self.lockInMemory()
            self.clearRecoveryCeremony()
            reply(self.encoded(self.currentStatus()))
        }
    }

    func deleteVault(_ confirmation: String, reply: @escaping (Data) -> Void) {
        queue.async {
            guard confirmation == "DELETE LOCUS VAULT" else {
                return reply(self.error("Type DELETE LOCUS VAULT to confirm deletion."))
            }
            do {
                self.lockInMemory()
                try self.store.delete(reason: "Delete the encrypted Locus Vault")
                self.clearPending()
                reply(self.encoded(self.currentStatus()))
            } catch {
                reply(self.error("Vault deletion failed: \(error.localizedDescription)"))
            }
        }
    }

    func deleteRecoveryVault(_ confirmation: String, reply: @escaping (Data) -> Void) {
        queue.async {
            guard confirmation == "DELETE RECOVERY VAULT" else {
                return reply(self.error("Type DELETE RECOVERY VAULT to confirm deletion."))
            }
            guard self.store.legacyExists else {
                return reply(self.error("No recovery-only vault exists."))
            }
            do {
                try self.store.deleteLegacy(reason: "Delete the recovery-only private-alpha vault")
                reply(self.encoded(self.currentStatus()))
            } catch {
                reply(self.error("Recovery vault deletion failed: \(error.localizedDescription)"))
            }
        }
    }

    fileprivate func recoveryCreationMaterial(
        ceremonyID: String, reply: @escaping (Data) -> Void
    ) {
        queue.async {
            guard let ceremony = self.recoveryCeremony,
                  ceremony.id == ceremonyID,
                  let purpose = ceremony.mode.creationPurpose else {
                return reply(self.error("This recovery ceremony cannot create a phrase."))
            }
            self.beginVaultCeremony(purpose: purpose, reply: reply)
        }
    }

    fileprivate func recoveryConfirmBackup(
        ceremonyID: String, confirmationData: Data, reply: @escaping (Data) -> Void
    ) {
        queue.async {
            guard self.recoveryCeremony?.id == ceremonyID,
                  self.recoveryCeremony?.mode.creationPurpose != nil else {
                return reply(self.error("The recovery ceremony is no longer active."))
            }
            do {
                let confirmation = try JSONDecoder().decode(
                    WalletBackupConfirmation.self, from: confirmationData
                )
                guard let entropy = self.pendingEntropy,
                      self.pendingWords.count == 24,
                      self.pendingIndices.count == 6,
                      self.pendingIndices.allSatisfy({ (0..<24).contains($0) }),
                      confirmation.wordsByIndex.count == 6,
                      Set(confirmation.wordsByIndex.keys) == Set(self.pendingIndices) else {
                    return reply(self.error("The recovery confirmation request was invalid."))
                }
                let mismatchedPositions = self.pendingIndices.filter { index in
                    self.pendingWords[index].precomposedStringWithCanonicalMapping
                        .caseInsensitiveCompare(
                            confirmation.wordsByIndex[index, default: ""]
                                .precomposedStringWithCanonicalMapping
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        ) != .orderedSame
                }
                guard mismatchedPositions.isEmpty else {
                    let positions = mismatchedPositions
                        .map { String($0 + 1) }
                        .joined(separator: ", ")
                    return reply(self.error(
                        "The words at positions \(positions) did not match. Check them and try again."
                    ))
                }
                let accounts = try self.deriveAccounts(entropy: entropy)
                try self.store.create(entropy: entropy, accounts: accounts)
                self.clearPending()
                self.lockInMemory()
                reply(self.encoded(self.currentStatus()))
            } catch {
                reply(self.error("Vault activation failed: \(error.localizedDescription)"))
            }
        }
    }

    fileprivate func recoveryRestore(
        ceremonyID: String, requestData: Data, reply: @escaping (Data) -> Void
    ) {
        queue.async {
            guard self.recoveryCeremony?.id == ceremonyID,
                  self.recoveryCeremony?.mode == .restore,
                  !self.store.exists, !self.store.legacyExists,
                  self.pendingEntropy == nil else {
                return reply(self.error("The recovery ceremony is no longer active."))
            }
            do {
                let restore = try JSONDecoder().decode(
                    WalletVaultRestoreRequest.self, from: requestData
                )
                guard restore.words.count == 24,
                      restore.words.allSatisfy({ word in
                          !word.isEmpty && word.utf8.count <= 16
                              && word.utf8.allSatisfy { (97...122).contains($0) }
                      }) else {
                    throw self.signerError("Enter exactly 24 lowercase English recovery words.")
                }
                var phrase = restore.words.joined(separator: " ")
                defer { phrase.replaceSubrange(phrase.startIndex..<phrase.endIndex, with: "") }
                guard let pointer = phrase.withCString({ rustRestoreVault($0) }) else {
                    throw self.signerError("The signing core could not validate the recovery phrase.")
                }
                defer { rustFreeString(pointer) }
                let data = Data(String(cString: pointer).utf8)
                if let failure = try? JSONDecoder().decode(
                    WalletSignerErrorPayload.self, from: data
                ) {
                    throw self.signerError(failure.error)
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let restored = try decoder.decode(RustGeneratedVault.self, from: data)
                guard restored.words == restore.words,
                      var entropy = Data(hex: restored.entropyHex), entropy.count == 32 else {
                    throw self.signerError("The recovery phrase did not canonicalize safely.")
                }
                defer { entropy.resetBytes(in: 0..<entropy.count) }
                let accounts = try self.deriveAccounts(entropy: entropy)
                try self.store.create(entropy: entropy, accounts: accounts)
                self.lockInMemory()
                reply(self.encoded(self.currentStatus()))
            } catch {
                reply(self.error("Vault restoration failed: \(error.localizedDescription)"))
            }
        }
    }

    fileprivate func recoveryCancel(
        ceremonyID: String, reply: @escaping (Data) -> Void
    ) {
        queue.async {
            guard self.recoveryCeremony?.id == ceremonyID else {
                return reply(self.error("The recovery ceremony is no longer active."))
            }
            self.clearPending()
            self.lockInMemory()
            reply(self.encoded(self.currentStatus()))
        }
    }

    fileprivate func recoveryConnectionEnded(ceremonyID: String) {
        queue.async {
            guard self.recoveryCeremony?.id == ceremonyID else { return }
            self.clearPending()
            self.lockInMemory()
            self.recoveryCeremony?.listener.invalidate()
            self.recoveryCeremony = nil
        }
    }

    private func beginVaultCeremony(
        purpose: WalletVaultCreationPurpose,
        reply: @escaping (Data) -> Void
    ) {
        if pendingEntropy != nil {
            guard pendingPurpose == purpose else {
                return reply(error("Another recovery ceremony is already in progress."))
            }
            return reply(encoded(WalletVaultCreation(
                words: pendingWords,
                verificationIndices: pendingIndices,
                purpose: purpose
            )))
        }
        guard let pointer = rustGenerateVault() else {
            return reply(error("The signing core did not generate a vault."))
        }
        defer { rustFreeString(pointer) }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let generated = try decoder.decode(
                RustGeneratedVault.self,
                from: Data(String(cString: pointer).utf8)
            )
            guard generated.words.count == 24,
                  let entropy = Data(hex: generated.entropyHex), entropy.count == 32 else {
                return reply(error("The signing core returned invalid BIP-39 material."))
            }
            pendingEntropy = entropy
            pendingWords = generated.words
            pendingIndices = Array(0..<24).shuffled().prefix(6).sorted()
            pendingPurpose = purpose
            reply(encoded(WalletVaultCreation(
                words: generated.words,
                verificationIndices: pendingIndices,
                purpose: purpose
            )))
        } catch {
            reply(self.error("Vault generation failed: \(error.localizedDescription)"))
        }
    }

    private func currentStatus() -> WalletSignerStatus {
        let state: WalletVaultState
        if activeSessionID != nil { state = .unlocked }
        else if pendingEntropy != nil { state = .awaitingBackup }
        else if store.exists { state = .locked }
        else if store.legacyExists { state = .rotationRequired }
        else { state = .missing }
        return WalletSignerStatus(
            protocolVersion: Self.protocolVersion,
            vaultState: state,
            sessionID: activeSessionID,
            accounts: (try? store.accounts()) ?? [],
            recoveryOnlyVaultAvailable: store.legacyExists
        )
    }

    private func deriveAccounts(entropy: Data) throws -> [WalletAccount] {
        var entropyHex = entropy.map { String(format: "%02x", $0) }.joined()
        defer { entropyHex.replaceSubrange(entropyHex.startIndex..<entropyHex.endIndex, with: "") }
        guard let pointer = entropyHex.withCString({ rustDeriveAccounts($0) }) else {
            throw NSError(domain: "WalletSigner", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The signing core is unavailable."])
        }
        defer { rustFreeString(pointer) }
        let data = Data(String(cString: pointer).utf8)
        if let failure = try? JSONDecoder().decode(WalletSignerErrorPayload.self, from: data) {
            throw NSError(domain: "WalletSigner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: failure.error])
        }
        do {
            return try WalletDerivedAccountsDecoder.decode(data)
        } catch {
            throw NSError(
                domain: "WalletSigner", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Wallet account derivation failed because the signing core "
                        + "returned invalid public account metadata."
                ]
            )
        }
    }

    private func prepareNativeTransfer(
        packet: WalletEVMPreparationPacket,
        entropy: Data
    ) throws -> StoredEVMIntent {
        try authorizeNetwork(
            packet.request.networkID, capability: .nativeTransfer
        )
        try authorizeReviewedAdapter(
            WalletReviewedAdapters.ethereumNativeTransfer,
            networkID: packet.request.networkID
        )
        guard let expectedChainID = Self.evmChainID(for: packet.request.networkID),
              packet.transaction.chainID == expectedChainID,
              packet.request.action.type == .nativeTransfer,
              packet.request.action.contractID == nil,
              packet.request.action.function == nil,
              packet.request.action.arguments.isEmpty,
              let recipient = packet.request.action.recipient,
              let amount = packet.request.action.amountBaseUnits.flatMap(SignerUnsignedInteger.normalize),
              packet.transaction.to.caseInsensitiveCompare(recipient) == .orderedSame,
              SignerUnsignedInteger.normalize(packet.transaction.value) == amount,
              packet.transaction.input.lowercased() == "0x",
              packet.transaction.gasLimit > 0,
              packet.simulationSucceeded,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30 else {
            throw signerError("The RPC evidence does not match a fresh network-bound native transfer.")
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .evm
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account,
              account.address.caseInsensitiveCompare(packet.fromAddress) == .orderedSame,
              SignerUnsignedInteger.lessThanOrEqual(
                  packet.transaction.maxPriorityFeePerGas, packet.transaction.maxFeePerGas
              ),
              let fee = SignerUnsignedInteger.multiply(
                  String(packet.transaction.gasLimit), packet.transaction.maxFeePerGas
              ),
              fee == SignerUnsignedInteger.normalize(packet.feeQuoteBaseUnits),
              SignerUnsignedInteger.lessThanOrEqual(fee, packet.request.maximumFeeBaseUnits) else {
            throw signerError("The account or fee evidence does not match the requested transaction.")
        }
        let rust = try rustPrepare(transaction: packet.transaction, entropy: entropy)
        guard rust.from.caseInsensitiveCompare(account.address) == .orderedSame else {
            throw signerError("The vault derivation does not match the requested account.")
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        var prepared = WalletPreparedTransaction(
            id: intentID,
            digest: rust.digest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source,
            action: packet.request.action,
            summary: "Send \(amount) wei on \(packet.request.networkID) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):eth-debit", kind: "debit",
                assetID: "\(packet.request.networkID)/slip44:60",
                amountBaseUnits: amount, from: account.address, to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.ethereumNativeTransfer,
            budgetAssetID: "\(packet.request.networkID)/slip44:60", spendBaseUnits: amount,
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee, simulation: packet.simulation,
            simulationSucceeded: true, nonce: String(packet.transaction.nonce),
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        if packet.request.source.kind == .agent,
           let policyID = try? validAutomaticPolicyID(for: prepared) {
            prepared.policyDecision = "allowed_by_session_policy"
            prepared.policyID = policyID
        }
        return StoredEVMIntent(transaction: packet.transaction, prepared: prepared)
    }

    private func prepareSolanaNativeTransfer(
        packet: WalletSolanaPreparationPacket,
        entropy: Data
    ) throws -> StoredSolanaIntent {
        let action = packet.request.action
        guard action.type == .nativeTransfer,
              action.assetID == nil, action.tokenID == nil,
              action.inputAssetID == nil, action.outputAssetID == nil,
              action.minimumOutputBaseUnits == nil, action.adapterID == nil,
              action.authorizationFormat == nil, action.metadataDigest == nil,
              action.contractID == nil,
              action.function == nil, action.arguments.isEmpty,
              action.valueBaseUnits == nil,
              let recipient = action.recipient,
              let amount = action.amountBaseUnits.flatMap(SignerUnsignedInteger.normalize),
              let amountValue = UInt64(amount), amountValue > 0,
              String(amountValue) == amount,
              packet.version == .legacy,
              packet.computeUnitLimit > 0,
              packet.computeUnitLimit <= 1_400_000,
              let computePrice = SignerUnsignedInteger.normalize(
                  packet.computeUnitPriceMicroLamports
              ), computePrice == packet.computeUnitPriceMicroLamports,
              UInt64(computePrice) != nil,
              let priorityFee = SignerUnsignedInteger.solanaPriorityFee(
                  computeUnitLimit: packet.computeUnitLimit,
                  priceMicroLamports: computePrice
              ), priorityFee == SignerUnsignedInteger.normalize(
                  packet.priorityFeeBaseUnits
              ),
              packet.maximumFeeBaseUnits == packet.request.maximumFeeBaseUnits,
              let fee = SignerUnsignedInteger.normalize(packet.feeQuoteBaseUnits),
              let baseFee = SignerUnsignedInteger.subtract(fee, priorityFee),
              baseFee != "0",
              SignerUnsignedInteger.lessThanOrEqual(
                  fee, packet.request.maximumFeeBaseUnits
              ),
              packet.lastValidBlockHeight > 0,
              packet.simulationSucceeded,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30 else {
            throw signerError(
                "The RPC evidence does not match a fresh reviewed SOL transfer."
            )
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .solana
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account, account.address == packet.feePayer,
              Self.isSolanaAddress(recipient), recipient != account.address,
              recipient != Self.solanaSystemProgramID else {
            throw signerError("The requested Solana account roles are invalid.")
        }
        let expectedAccounts = [
            WalletSolanaResolvedAccount(
                address: account.address, isSigner: true, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
            WalletSolanaResolvedAccount(
                address: recipient, isSigner: false, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
        ]
        let expectedInstruction = WalletSolanaReviewedInstruction(
            programID: Self.solanaSystemProgramID,
            adapterID: WalletReviewedAdapters.solanaNativeTransfer,
            semanticOperation: WalletActionKind.nativeTransfer.rawValue,
            accounts: expectedAccounts,
            canonicalArguments: ["lamports": amount]
        )
        let resolvedDigest = Self.solanaResolvedAccountsDigest(
            feePayer: account.address, recipient: recipient
        )
        guard packet.instructions == [expectedInstruction],
              packet.resolvedAccountsDigest == resolvedDigest else {
            throw signerError(
                "The Solana programs, account privileges, or arguments are outside the reviewed adapter."
            )
        }
        try authorizeReviewedAdapter(
            WalletReviewedAdapters.solanaNativeTransfer,
            networkID: packet.request.networkID
        )
        let rust = try rustPrepareSolana(packet: packet, entropy: entropy)
        guard rust.from == account.address,
              rust.canonicalMessageDigest == packet.canonicalMessageDigest else {
            throw signerError(
                "The signer-rebuilt Solana message differs from provider preparation."
            )
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        var prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.canonicalMessageDigest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source, action: action,
            summary: "Send \(amount) lamports on \(packet.request.networkID) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):sol-debit", kind: "debit",
                assetID: "\(packet.request.networkID)/slip44:501",
                amountBaseUnits: amount, from: account.address,
                to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.solanaNativeTransfer,
            budgetAssetID: "\(packet.request.networkID)/slip44:501",
            spendBaseUnits: amount,
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee,
            simulation: packet.simulation, simulationSucceeded: true,
            nonce: packet.recentBlockhash,
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        if packet.request.source.kind == .agent,
           let policyID = try? validAutomaticPolicyID(for: prepared) {
            prepared.policyDecision = "allowed_by_session_policy"
            prepared.policyID = policyID
        }
        return StoredSolanaIntent(packet: packet, prepared: prepared)
    }

    private func prepareSuiNativeTransfer(
        packet: WalletSuiPreparationPacket,
        entropy: Data
    ) throws -> StoredSuiIntent {
        let action = packet.request.action
        guard action.type == .nativeTransfer,
              action.assetID == nil, action.tokenID == nil,
              action.inputAssetID == nil, action.outputAssetID == nil,
              action.minimumOutputBaseUnits == nil, action.adapterID == nil,
              action.authorizationFormat == nil, action.metadataDigest == nil,
              action.contractID == nil, action.function == nil,
              action.arguments.isEmpty, action.valueBaseUnits == nil,
              packet.assetID == packet.request.networkID
                + "/coin:0x2::sui::SUI",
              packet.coinType == WalletSuiAssetIdentity.nativeCoinType,
              packet.coinObject == nil,
              packet.coinBalanceBaseUnits == nil,
              packet.coinCheckpointSequence == nil,
              packet.coinCheckpointTimestamp == nil,
              packet.transferredObject == nil,
              packet.objectHasPublicTransfer == nil,
              packet.objectCheckpointSequence == nil,
              packet.objectCheckpointTimestamp == nil,
              let recipient = action.recipient,
              let amount = action.amountBaseUnits.flatMap(SignerUnsignedInteger.normalize),
              let amountValue = UInt64(amount), amountValue > 0,
              String(amountValue) == amount,
              WalletSuiAddress.isCanonical(packet.sender),
              WalletSuiAddress.isCanonical(recipient),
              packet.sender != recipient,
              packet.gasObject.type == "0x2::coin::Coin<0x2::sui::SUI>",
              WalletSuiAddress.isCanonical(packet.gasObject.objectID),
              packet.gasObject.version > 0,
              WalletSolanaBase58.decode(packet.gasObject.digest, exactLength: 32) != nil,
              let gasBalance = SignerUnsignedInteger.normalize(
                  packet.gasBalanceBaseUnits
              ), UInt64(gasBalance) != nil, gasBalance == packet.gasBalanceBaseUnits,
              let gasBudget = SignerUnsignedInteger.normalize(
                  packet.gasBudgetBaseUnits
              ), let gasBudgetValue = UInt64(gasBudget), gasBudgetValue > 0,
              gasBudget == packet.request.maximumFeeBaseUnits,
              let referenceGasPrice = SignerUnsignedInteger.normalize(
                  packet.referenceGasPriceBaseUnits
              ), let referenceGasPriceValue = UInt64(referenceGasPrice),
              referenceGasPriceValue > 0,
              packet.gasPriceBaseUnits == referenceGasPrice,
              packet.currentEpoch == packet.expirationEpoch,
              packet.checkpointSequence > 0,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30,
              packet.checkpointTimestamp <= Date().addingTimeInterval(120),
              packet.checkpointTimestamp >= Date().addingTimeInterval(-15 * 60),
              let required = SignerUnsignedInteger.add(amount, gasBudget),
              SignerUnsignedInteger.lessThanOrEqual(required, gasBalance) else {
            throw signerError(
                "The provider evidence does not match a fresh reviewed native SUI transfer."
            )
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .sui
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account, account.address == packet.sender else {
            throw signerError("The requested Sui account roles are invalid.")
        }
        try authorizeReviewedAdapter(
            WalletReviewedAdapters.suiNativeTransfer,
            networkID: packet.request.networkID
        )
        let rust = try rustPrepareSui(packet: packet, entropy: entropy)
        guard rust.from == account.address,
              rust.chainIdentifier == packet.chainIdentifier,
              WalletSolanaBase58.decode(rust.transactionDigest, exactLength: 32) != nil,
              rust.signingDigest.hasPrefix("blake2b256:"),
              rust.signingDigest.count == 75,
              let transactionBCS = Data(base64Encoded: rust.transactionBCS),
              !transactionBCS.isEmpty,
              transactionBCS.base64EncodedString() == rust.transactionBCS else {
            throw signerError(
                "The signer-rebuilt Sui transaction is not canonical."
            )
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        let prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.transactionDigest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source, action: action,
            summary: "Send \(amount) MIST on \(packet.request.networkID) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):sui-debit", kind: "debit",
                assetID: "\(packet.request.networkID)/coin:0x2::sui::SUI",
                amountBaseUnits: amount, from: account.address,
                to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.suiNativeTransfer,
            budgetAssetID: "\(packet.request.networkID)/coin:0x2::sui::SUI",
            spendBaseUnits: amount,
            maximumFeeBaseUnits: gasBudget,
            feeQuoteBaseUnits: "0",
            simulation: "Awaiting exact Sui effects",
            simulationSucceeded: false,
            nonce: "\(packet.gasObject.objectID)@\(packet.gasObject.version)",
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        return StoredSuiIntent(
            packet: packet, rust: rust, prepared: prepared, simulation: nil
        )
    }

    private func prepareSuiCoinTransfer(
        packet: WalletSuiPreparationPacket,
        entropy: Data
    ) throws -> StoredSuiIntent {
        let action = packet.request.action
        guard action.type == .fungibleTokenTransfer,
              let assetID = action.assetID,
              let identity = WalletSuiAssetIdentity.parse(assetID),
              identity.networkID == packet.request.networkID,
              identity.coinType != WalletSuiAssetIdentity.nativeCoinType,
              packet.assetID == identity.canonicalID,
              packet.coinType == identity.coinType,
              packet.transferredObject == nil,
              packet.objectHasPublicTransfer == nil,
              packet.objectCheckpointSequence == nil,
              packet.objectCheckpointTimestamp == nil,
              action.tokenID == nil, action.inputAssetID == nil,
              action.outputAssetID == nil, action.minimumOutputBaseUnits == nil,
              action.adapterID == nil, action.authorizationFormat == nil,
              action.metadataDigest == nil, action.contractID == nil,
              action.function == nil, action.arguments.isEmpty,
              action.valueBaseUnits == nil,
              let recipient = action.recipient,
              let amount = action.amountBaseUnits.flatMap(SignerUnsignedInteger.normalize),
              let amountValue = UInt64(amount), amountValue > 0,
              String(amountValue) == amount,
              WalletSuiAddress.isCanonical(packet.sender),
              WalletSuiAddress.isCanonical(recipient), packet.sender != recipient,
              let coinObject = packet.coinObject,
              coinObject.type == "0x2::coin::Coin<\(identity.coinType)>",
              WalletSuiAddress.isCanonical(coinObject.objectID),
              coinObject.version > 0,
              WalletSolanaBase58.decode(coinObject.digest, exactLength: 32) != nil,
              let coinBalance = packet.coinBalanceBaseUnits.flatMap(
                  SignerUnsignedInteger.normalize
              ), UInt64(coinBalance) != nil,
              coinBalance == packet.coinBalanceBaseUnits,
              SignerUnsignedInteger.lessThanOrEqual(amount, coinBalance),
              let coinCheckpoint = packet.coinCheckpointSequence,
              coinCheckpoint > 0, coinCheckpoint <= packet.checkpointSequence,
              let coinTimestamp = packet.coinCheckpointTimestamp,
              coinTimestamp <= packet.checkpointTimestamp,
              coinTimestamp <= Date().addingTimeInterval(120),
              coinTimestamp >= Date().addingTimeInterval(-15 * 60),
              packet.gasObject.type == "0x2::coin::Coin<0x2::sui::SUI>",
              WalletSuiAddress.isCanonical(packet.gasObject.objectID),
              packet.gasObject.objectID != coinObject.objectID,
              packet.gasObject.version > 0,
              WalletSolanaBase58.decode(packet.gasObject.digest, exactLength: 32) != nil,
              let gasBalance = SignerUnsignedInteger.normalize(
                  packet.gasBalanceBaseUnits
              ), UInt64(gasBalance) != nil, gasBalance == packet.gasBalanceBaseUnits,
              let gasBudget = SignerUnsignedInteger.normalize(
                  packet.gasBudgetBaseUnits
              ), let gasBudgetValue = UInt64(gasBudget), gasBudgetValue > 0,
              gasBudget == packet.request.maximumFeeBaseUnits,
              SignerUnsignedInteger.lessThanOrEqual(gasBudget, gasBalance),
              let referenceGasPrice = SignerUnsignedInteger.normalize(
                  packet.referenceGasPriceBaseUnits
              ), let referenceGasPriceValue = UInt64(referenceGasPrice),
              referenceGasPriceValue > 0,
              packet.gasPriceBaseUnits == referenceGasPrice,
              packet.currentEpoch == packet.expirationEpoch,
              packet.checkpointSequence > 0,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30,
              packet.checkpointTimestamp <= Date().addingTimeInterval(120),
              packet.checkpointTimestamp >= Date().addingTimeInterval(-15 * 60) else {
            throw signerError(
                "The provider evidence does not match a fresh reviewed Sui Coin transfer."
            )
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .sui
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account, account.address == packet.sender else {
            throw signerError("The requested Sui Coin account roles are invalid.")
        }
        try authorizeReviewedAdapter(
            WalletReviewedAdapters.suiCoinTransfer,
            networkID: packet.request.networkID
        )
        if WalletNetworkCatalog.descriptor(
            id: packet.request.networkID
        )?.environment == .mainnet {
            guard reviewRegistry?.assets.contains(where: {
                $0.id == identity.canonicalID && $0.networkID == identity.networkID
                    && $0.chain == .sui && $0.kind == .fungibleToken
                    && $0.reference == identity.coinType && $0.trust == .curated
            }) == true else {
                throw signerError(
                    "The Sui Coin type is absent from the signed review manifest."
                )
            }
        }
        let rust = try rustPrepareSui(packet: packet, entropy: entropy)
        guard rust.from == account.address,
              rust.chainIdentifier == packet.chainIdentifier,
              WalletSolanaBase58.decode(rust.transactionDigest, exactLength: 32) != nil,
              rust.signingDigest.hasPrefix("blake2b256:"),
              rust.signingDigest.count == 75,
              let transactionBCS = Data(base64Encoded: rust.transactionBCS),
              !transactionBCS.isEmpty,
              transactionBCS.base64EncodedString() == rust.transactionBCS else {
            throw signerError(
                "The signer-rebuilt Sui Coin transaction is not canonical."
            )
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        let symbol = identity.coinType.components(separatedBy: "::").last ?? "Coin"
        let prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.transactionDigest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source, action: action,
            summary: "Send \(amount) \(symbol) on \(packet.request.networkID) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):sui-coin-debit", kind: "token_transfer",
                assetID: identity.canonicalID, amountBaseUnits: amount,
                from: account.address, to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.suiCoinTransfer,
            budgetAssetID: identity.canonicalID,
            spendBaseUnits: amount,
            maximumFeeBaseUnits: gasBudget,
            feeQuoteBaseUnits: "0",
            simulation: "Awaiting exact Sui Coin effects",
            simulationSucceeded: false,
            nonce: "\(coinObject.objectID)@\(coinObject.version):\(packet.gasObject.objectID)@\(packet.gasObject.version)",
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        return StoredSuiIntent(
            packet: packet, rust: rust, prepared: prepared, simulation: nil
        )
    }

    private func prepareSuiObjectTransfer(
        packet: WalletSuiPreparationPacket,
        entropy: Data
    ) throws -> StoredSuiIntent {
        let action = packet.request.action
        guard action.type == .nftTransfer,
              let assetID = action.assetID,
              let identity = WalletSuiObjectIdentity.parse(assetID),
              identity.networkID == packet.request.networkID,
              packet.assetID == identity.canonicalID,
              packet.coinType.isEmpty,
              packet.coinObject == nil, packet.coinBalanceBaseUnits == nil,
              packet.coinCheckpointSequence == nil,
              packet.coinCheckpointTimestamp == nil,
              action.tokenID == identity.objectID,
              action.amountBaseUnits == "1",
              action.inputAssetID == nil, action.outputAssetID == nil,
              action.minimumOutputBaseUnits == nil, action.adapterID == nil,
              action.authorizationFormat == nil, action.metadataDigest == nil,
              action.contractID == nil, action.function == nil,
              action.arguments.isEmpty, action.valueBaseUnits == nil,
              let recipient = action.recipient,
              WalletSuiAddress.isCanonical(packet.sender),
              WalletSuiAddress.isCanonical(recipient), packet.sender != recipient,
              let object = packet.transferredObject,
              object.objectID == identity.objectID,
              WalletSuiAddress.isCanonical(object.objectID), object.version > 0,
              WalletSolanaBase58.decode(object.digest, exactLength: 32) != nil,
              WalletSuiAssetIdentity.isCanonicalCoinType(object.type),
              object.type != WalletSuiAssetIdentity.nativeCoinType,
              packet.objectHasPublicTransfer == true,
              let objectCheckpoint = packet.objectCheckpointSequence,
              objectCheckpoint > 0, objectCheckpoint <= packet.checkpointSequence,
              let objectTimestamp = packet.objectCheckpointTimestamp,
              objectTimestamp <= packet.checkpointTimestamp,
              objectTimestamp <= Date().addingTimeInterval(120),
              objectTimestamp >= Date().addingTimeInterval(-15 * 60),
              packet.gasObject.type == "0x2::coin::Coin<0x2::sui::SUI>",
              WalletSuiAddress.isCanonical(packet.gasObject.objectID),
              packet.gasObject.objectID != object.objectID,
              packet.gasObject.version > 0,
              WalletSolanaBase58.decode(packet.gasObject.digest, exactLength: 32) != nil,
              let gasBalance = SignerUnsignedInteger.normalize(
                  packet.gasBalanceBaseUnits
              ), UInt64(gasBalance) != nil, gasBalance == packet.gasBalanceBaseUnits,
              let gasBudget = SignerUnsignedInteger.normalize(
                  packet.gasBudgetBaseUnits
              ), let gasBudgetValue = UInt64(gasBudget), gasBudgetValue > 0,
              gasBudget == packet.request.maximumFeeBaseUnits,
              SignerUnsignedInteger.lessThanOrEqual(gasBudget, gasBalance),
              let referenceGasPrice = SignerUnsignedInteger.normalize(
                  packet.referenceGasPriceBaseUnits
              ), let referenceGasPriceValue = UInt64(referenceGasPrice),
              referenceGasPriceValue > 0,
              packet.gasPriceBaseUnits == referenceGasPrice,
              packet.currentEpoch == packet.expirationEpoch,
              packet.checkpointSequence > 0,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30,
              packet.checkpointTimestamp <= Date().addingTimeInterval(120),
              packet.checkpointTimestamp >= Date().addingTimeInterval(-15 * 60) else {
            throw signerError(
                "The provider evidence does not match a fresh reviewed Sui object transfer."
            )
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .sui
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account, account.address == packet.sender else {
            throw signerError("The requested Sui object account roles are invalid.")
        }
        try authorizeReviewedAdapter(
            WalletReviewedAdapters.suiObjectTransfer,
            networkID: packet.request.networkID
        )
        if WalletNetworkCatalog.descriptor(
            id: packet.request.networkID
        )?.environment == .mainnet {
            guard reviewRegistry?.assets.contains(where: {
                $0.id == identity.canonicalID && $0.networkID == identity.networkID
                    && $0.chain == .sui
                    && ($0.kind == .nft || $0.kind == .collectible)
                    && $0.reference == identity.objectID && $0.trust == .curated
            }) == true else {
                throw signerError(
                    "The Sui object is absent from the signed review manifest."
                )
            }
        }
        let rust = try rustPrepareSui(packet: packet, entropy: entropy)
        guard rust.from == account.address,
              rust.chainIdentifier == packet.chainIdentifier,
              WalletSolanaBase58.decode(rust.transactionDigest, exactLength: 32) != nil,
              rust.signingDigest.hasPrefix("blake2b256:"),
              rust.signingDigest.count == 75,
              let transactionBCS = Data(base64Encoded: rust.transactionBCS),
              !transactionBCS.isEmpty,
              transactionBCS.base64EncodedString() == rust.transactionBCS else {
            throw signerError(
                "The signer-rebuilt Sui object transaction is not canonical."
            )
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        let prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.transactionDigest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source, action: action,
            summary: "Send Sui object \(identity.objectID) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):sui-object-transfer", kind: "nft_transfer",
                assetID: identity.canonicalID, amountBaseUnits: "1",
                from: account.address, to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.suiObjectTransfer,
            budgetAssetID: identity.canonicalID, spendBaseUnits: "1",
            maximumFeeBaseUnits: gasBudget, feeQuoteBaseUnits: "0",
            simulation: "Awaiting exact Sui object ownership effects",
            simulationSucceeded: false,
            nonce: "\(object.objectID)@\(object.version):\(packet.gasObject.objectID)@\(packet.gasObject.version)",
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        return StoredSuiIntent(
            packet: packet, rust: rust, prepared: prepared, simulation: nil
        )
    }

    private func prepareSolanaCoreTransfer(
        packet: WalletSolanaPreparationPacket,
        entropy: Data
    ) throws -> StoredSolanaIntent {
        let action = packet.request.action
        guard action.type == .nftTransfer,
              let assetID = action.assetID,
              let identity = WalletSolanaCollectibleIdentity.parse(assetID),
              identity.networkID == packet.request.networkID,
              identity.standard == .core,
              action.tokenID == identity.address,
              action.amountBaseUnits == "1",
              action.inputAssetID == nil, action.outputAssetID == nil,
              action.minimumOutputBaseUnits == nil, action.adapterID == nil,
              action.authorizationFormat == nil, action.metadataDigest == nil,
              action.contractID == nil, action.function == nil,
              action.arguments.isEmpty, action.valueBaseUnits == nil,
              let recipient = action.recipient,
              packet.version == .legacy,
              packet.computeUnitLimit > 0,
              packet.computeUnitLimit <= 1_400_000,
              let computePrice = SignerUnsignedInteger.normalize(
                  packet.computeUnitPriceMicroLamports
              ), computePrice == packet.computeUnitPriceMicroLamports,
              UInt64(computePrice) != nil,
              let priorityFee = SignerUnsignedInteger.solanaPriorityFee(
                  computeUnitLimit: packet.computeUnitLimit,
                  priceMicroLamports: computePrice
              ), priorityFee == SignerUnsignedInteger.normalize(
                  packet.priorityFeeBaseUnits
              ),
              packet.maximumFeeBaseUnits == packet.request.maximumFeeBaseUnits,
              let fee = SignerUnsignedInteger.normalize(packet.feeQuoteBaseUnits),
              let baseFee = SignerUnsignedInteger.subtract(fee, priorityFee),
              baseFee != "0",
              SignerUnsignedInteger.lessThanOrEqual(
                fee, packet.request.maximumFeeBaseUnits
              ),
              packet.lastValidBlockHeight > 0,
              packet.simulationSucceeded,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30,
              packet.instructions.count == 1,
              let instruction = packet.instructions.first,
              instruction.programID == Self.solanaCoreProgramID,
              instruction.adapterID == WalletReviewedAdapters.solanaCoreTransfer,
              instruction.semanticOperation == WalletActionKind.nftTransfer.rawValue,
              let assetDataDigest = instruction.canonicalArguments[
                "asset_data_digest"
              ],
              assetDataDigest.hasPrefix("sha256:"), assetDataDigest.count == 71,
              assetDataDigest.dropFirst(7).utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw signerError(
                "The RPC evidence does not match a fresh reviewed Core transfer."
            )
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .solana
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account, account.address == packet.feePayer,
              Self.isSolanaAddress(recipient), recipient != account.address,
              identity.address != account.address, identity.address != recipient,
              identity.address != Self.solanaCoreProgramID,
              recipient != Self.solanaCoreProgramID else {
            throw signerError("The requested Core account roles are invalid.")
        }
        let authorityKind = instruction.canonicalArguments[
            "update_authority_kind"
        ]
        let authorityAddress = instruction.canonicalArguments[
            "update_authority"
        ]
        guard (authorityKind == "none" && authorityAddress == "")
                || (authorityKind == "address"
                    && authorityAddress.map(Self.isSolanaAddress) == true) else {
            throw signerError("The Core update-authority evidence is invalid.")
        }
        let expectedAccounts = [
            WalletSolanaResolvedAccount(
                address: account.address, isSigner: true, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
            WalletSolanaResolvedAccount(
                address: identity.address, isSigner: false, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
            WalletSolanaResolvedAccount(
                address: recipient, isSigner: false, isWritable: false,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
        ]
        let expectedArguments = [
            "asset_data_digest": assetDataDigest,
            "asset_id": assetID,
            "collection": "none",
            "compression": "none",
            "plugins": "none",
            "recipient": recipient,
            "update_authority": authorityAddress ?? "",
            "update_authority_kind": authorityKind ?? "",
        ]
        let resolvedDigest = Self.solanaCoreResolvedAccountsDigest(
            feePayer: account.address, asset: identity.address,
            recipient: recipient, assetDataDigest: assetDataDigest
        )
        guard instruction.accounts == expectedAccounts,
              instruction.canonicalArguments == expectedArguments,
              packet.resolvedAccountsDigest == resolvedDigest else {
            throw signerError(
                "The Core programs, privileges, or plugin-free asset evidence are outside the reviewed adapter."
            )
        }
        try authorizeReviewedAdapter(
            WalletReviewedAdapters.solanaCoreTransfer,
            networkID: packet.request.networkID
        )
        guard reviewRegistry?.assets.contains(where: {
            $0.id == identity.canonicalID && $0.networkID == identity.networkID
                && $0.chain == .solana
                && ($0.kind == .nft || $0.kind == .collectible)
                && $0.reference == identity.address
                && ($0.decimals == nil || $0.decimals == 0)
                && $0.trust == .curated
        }) == true else {
            throw signerError(
                "The Core asset is absent from the signed review manifest."
            )
        }
        let rust = try rustPrepareSolana(packet: packet, entropy: entropy)
        guard rust.from == account.address,
              rust.canonicalMessageDigest == packet.canonicalMessageDigest else {
            throw signerError(
                "The signer-rebuilt Core message differs from provider preparation."
            )
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        let prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.canonicalMessageDigest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source, action: action,
            summary: "Send Core asset \(identity.address) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):core-transfer", kind: "nft_transfer",
                assetID: assetID, amountBaseUnits: "1",
                from: account.address, to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.solanaCoreTransfer,
            budgetAssetID: assetID, spendBaseUnits: "1",
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee, simulation: packet.simulation,
            simulationSucceeded: true,
            nonce: "\(packet.recentBlockhash):\(assetDataDigest)",
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        return StoredSolanaIntent(packet: packet, prepared: prepared)
    }

    private func prepareSolanaSPLTransfer(
        packet: WalletSolanaPreparationPacket,
        entropy: Data
    ) throws -> StoredSolanaIntent {
        let action = packet.request.action
        guard action.type == .fungibleTokenTransfer,
              let assetID = action.assetID,
              let identity = WalletSolanaAssetIdentity.parse(assetID),
              identity.networkID == packet.request.networkID,
              action.tokenID == nil, action.inputAssetID == nil,
              action.outputAssetID == nil, action.minimumOutputBaseUnits == nil,
              action.adapterID == nil, action.authorizationFormat == nil,
              action.metadataDigest == nil, action.contractID == nil,
              action.function == nil, action.arguments.isEmpty,
              action.valueBaseUnits == nil,
              let recipient = action.recipient,
              let amount = action.amountBaseUnits.flatMap(SignerUnsignedInteger.normalize),
              let amountValue = UInt64(amount), amountValue > 0,
              String(amountValue) == amount,
              packet.version == .legacy,
              packet.computeUnitLimit > 0,
              packet.computeUnitLimit <= 1_400_000,
              let computePrice = SignerUnsignedInteger.normalize(
                  packet.computeUnitPriceMicroLamports
              ), computePrice == packet.computeUnitPriceMicroLamports,
              UInt64(computePrice) != nil,
              let priorityFee = SignerUnsignedInteger.solanaPriorityFee(
                  computeUnitLimit: packet.computeUnitLimit,
                  priceMicroLamports: computePrice
              ), priorityFee == SignerUnsignedInteger.normalize(
                  packet.priorityFeeBaseUnits
              ),
              packet.maximumFeeBaseUnits == packet.request.maximumFeeBaseUnits,
              let fee = SignerUnsignedInteger.normalize(packet.feeQuoteBaseUnits),
              let baseFee = SignerUnsignedInteger.subtract(fee, priorityFee),
              baseFee != "0",
              SignerUnsignedInteger.lessThanOrEqual(
                  fee, packet.request.maximumFeeBaseUnits
              ),
              packet.lastValidBlockHeight > 0,
              packet.simulationSucceeded,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30 else {
            throw signerError(
                "The RPC evidence does not match a fresh reviewed SPL token transfer."
            )
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .solana
                && $0.networkIDs.contains(packet.request.networkID)
        }
        let tokenProgramID = identity.program.programID
        let adapterID = identity.program == .token2022
            ? WalletReviewedAdapters.solanaToken2022TransferChecked
            : WalletReviewedAdapters.solanaSPLTransferChecked
        guard let account, account.address == packet.feePayer,
              Self.isSolanaAddress(recipient), recipient != account.address,
              (1...2).contains(packet.instructions.count),
              let instruction = packet.instructions.last,
              instruction.programID == tokenProgramID,
              instruction.adapterID == adapterID,
              instruction.semanticOperation
                == WalletActionKind.fungibleTokenTransfer.rawValue,
              let source = instruction.canonicalArguments["source_token_account"],
              let mint = instruction.canonicalArguments["mint"],
              let destination = instruction.canonicalArguments[
                  "destination_token_account"
              ],
              let decimalsText = instruction.canonicalArguments["decimals"],
              let decimals = UInt8(decimalsText),
              identity.mint == mint,
              Self.isSolanaAddress(source), Self.isSolanaAddress(destination) else {
            throw signerError("The requested SPL account roles are invalid.")
        }
        let mintExtensions = try canonicalTokenExtensionArgument(
            instruction.canonicalArguments["mint_extensions"],
            required: identity.program == .token2022
        )
        let sourceExtensions = try canonicalTokenExtensionArgument(
            instruction.canonicalArguments["source_extensions"],
            required: identity.program == .token2022
        )
        let destinationExtensions = try canonicalTokenExtensionArgument(
            instruction.canonicalArguments["destination_extensions"],
            required: identity.program == .token2022
        )
        try requireSafeTokenExtensions(
            program: identity.program, mint: mintExtensions,
            source: sourceExtensions, destination: destinationExtensions
        )
        var expectedArguments: [String: String] = [
            "amount": amount,
            "asset_id": assetID,
            "decimals": String(decimals),
            "destination_owner": recipient,
            "destination_token_account": destination,
            "mint": mint,
            "source_token_account": source,
        ]
        if identity.program == .token2022 {
            expectedArguments["mint_extensions"] = mintExtensions.joined(
                separator: ","
            )
            expectedArguments["source_extensions"] = sourceExtensions.joined(
                separator: ","
            )
            expectedArguments["destination_extensions"] =
                destinationExtensions.joined(separator: ",")
        }
        guard instruction.canonicalArguments == expectedArguments else {
            throw signerError(
                "The reviewed token arguments or extension evidence changed."
            )
        }
        let createsDestinationAssociatedAccount = packet.instructions.count == 2
        var distinctAddresses = [
            account.address, source, mint, destination, recipient,
            tokenProgramID,
        ]
        if createsDestinationAssociatedAccount {
            distinctAddresses.append(Self.solanaSystemProgramID)
            distinctAddresses.append(Self.solanaAssociatedTokenProgramID)
        }
        guard Set(distinctAddresses).count == distinctAddresses.count else {
            throw signerError("The requested SPL account roles are not distinct.")
        }
        let expectedAccounts = [
            WalletSolanaResolvedAccount(
                address: account.address, isSigner: true, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
            WalletSolanaResolvedAccount(
                address: source, isSigner: false, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
            WalletSolanaResolvedAccount(
                address: mint, isSigner: false, isWritable: false,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
            WalletSolanaResolvedAccount(
                address: destination, isSigner: false, isWritable: true,
                lookupTableAddress: nil, lookupTableSlot: nil
            ),
        ]
        if createsDestinationAssociatedAccount {
            let derived = try rustAssociatedTokenAddress(
                owner: recipient, mint: mint,
                tokenProgramID: tokenProgramID
            )
            guard derived.address == destination,
                  identity.program != .token2022
                    || destinationExtensions == ["immutableOwner"],
                  let creation = packet.instructions.first,
                  creation.programID == Self.solanaAssociatedTokenProgramID,
                  creation.adapterID
                    == WalletReviewedAdapters.solanaAssociatedTokenCreateIdempotent,
                  creation.semanticOperation
                    == "create_associated_token_account_idempotent",
                  creation.accounts == [
                    WalletSolanaResolvedAccount(
                        address: account.address, isSigner: true, isWritable: true,
                        lookupTableAddress: nil, lookupTableSlot: nil
                    ),
                    WalletSolanaResolvedAccount(
                        address: destination, isSigner: false, isWritable: true,
                        lookupTableAddress: nil, lookupTableSlot: nil
                    ),
                    WalletSolanaResolvedAccount(
                        address: recipient, isSigner: false, isWritable: false,
                        lookupTableAddress: nil, lookupTableSlot: nil
                    ),
                    WalletSolanaResolvedAccount(
                        address: mint, isSigner: false, isWritable: false,
                        lookupTableAddress: nil, lookupTableSlot: nil
                    ),
                    WalletSolanaResolvedAccount(
                        address: Self.solanaSystemProgramID,
                        isSigner: false, isWritable: false,
                        lookupTableAddress: nil, lookupTableSlot: nil
                    ),
                    WalletSolanaResolvedAccount(
                        address: tokenProgramID,
                        isSigner: false, isWritable: false,
                        lookupTableAddress: nil, lookupTableSlot: nil
                    ),
                  ],
                  creation.canonicalArguments == [
                    "associated_token_account": destination,
                    "destination_owner": recipient,
                    "mint": mint,
                    "token_program_id": tokenProgramID,
                  ] else {
                throw signerError(
                    "The associated-token account does not match the signer-derived reviewed instruction."
                )
            }
            try authorizeReviewedAdapter(
                WalletReviewedAdapters.solanaAssociatedTokenCreateIdempotent,
                networkID: packet.request.networkID
            )
        }
        let resolvedDigest = Self.solanaSPLResolvedAccountsDigest(
            feePayer: account.address, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: destination, recipientOwner: recipient,
            createsDestinationAssociatedAccount:
                createsDestinationAssociatedAccount,
            tokenProgramID: tokenProgramID,
            mintExtensions: mintExtensions,
            sourceExtensions: sourceExtensions,
            destinationExtensions: destinationExtensions
        )
        guard instruction.accounts == expectedAccounts,
              packet.resolvedAccountsDigest == resolvedDigest else {
            throw signerError(
                "The SPL programs, account privileges, or arguments are outside the reviewed adapter."
            )
        }
        try authorizeReviewedAdapter(
            adapterID,
            networkID: packet.request.networkID
        )
        let rust = try rustPrepareSolana(packet: packet, entropy: entropy)
        guard rust.from == account.address,
              rust.canonicalMessageDigest == packet.canonicalMessageDigest else {
            throw signerError(
                "The signer-rebuilt SPL message differs from provider preparation."
            )
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        var prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.canonicalMessageDigest,
            networkID: packet.request.networkID,
            accountID: packet.request.accountID,
            source: packet.request.source, action: action,
            summary: "Send \(amount) units of \(assetID) to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):spl-transfer", kind: "token_transfer",
                assetID: assetID, amountBaseUnits: amount,
                from: account.address, to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: adapterID,
            budgetAssetID: assetID, spendBaseUnits: amount,
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee,
            simulation: packet.simulation, simulationSucceeded: true,
            nonce: packet.recentBlockhash,
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        if packet.request.source.kind == .agent,
           let policyID = try? validAutomaticPolicyID(for: prepared) {
            prepared.policyDecision = "allowed_by_session_policy"
            prepared.policyID = policyID
        }
        return StoredSolanaIntent(packet: packet, prepared: prepared)
    }

    private func prepareContractCall(
        packet: WalletEVMPreparationPacket,
        entropy: Data
    ) throws -> StoredEVMIntent {
        let action = packet.request.action
        guard let expectedChainID = Self.evmChainID(for: packet.request.networkID),
              packet.transaction.chainID == expectedChainID,
              let entry = packet.contractRegistryEntry,
              let encoded = packet.encodedContractCall,
              let observedCodeHash = packet.observedRuntimeCodeHash,
              entry.networkID == packet.request.networkID,
              packet.transaction.to.caseInsensitiveCompare(entry.checksumAddress) == .orderedSame,
              observedCodeHash.caseInsensitiveCompare(entry.runtimeCodeHash) == .orderedSame,
              packet.transaction.gasLimit > 0,
              packet.simulationSucceeded,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30 else {
            throw signerError("The RPC evidence does not match a fresh registered network call.")
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .evm
                && $0.networkIDs.contains(packet.request.networkID)
        }
        guard let account,
              account.address.caseInsensitiveCompare(packet.fromAddress) == .orderedSame else {
            throw signerError("The requested EVM account does not match the vault account.")
        }
        let nativeValue: String
        switch action.type {
        case .contractCall:
            guard action.recipient == nil, action.amountBaseUnits == nil,
                  action.contractID == entry.id,
                  let value = action.valueBaseUnits.flatMap(SignerUnsignedInteger.normalize) else {
                throw signerError("The registered call does not match its semantic request.")
            }
            nativeValue = value
        case .fungibleTokenTransfer, .nftTransfer:
            guard WalletEVMAssetAdapter.resolve(
                action: action, registryEntry: entry,
                accountAddress: account.address
            ) != nil else {
                throw signerError("The token or NFT action is outside its reviewed standard adapter.")
            }
            nativeValue = "0"
        case .exactInputSwap:
            guard action.contractID == entry.id,
                  WalletReviewedAdapters.validatedID(for: entry)
                    == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                  reviewedSwapRouteIsSigned(
                    action, networkID: entry.networkID
                  ),
                  WalletUniversalRouterV2V3Adapter.contractAction(
                    for: action, accountAddress: account.address,
                    networkID: entry.networkID
                  ) != nil else {
                throw signerError(
                    "The swap action is outside its reviewed exact-input adapter."
                )
            }
            nativeValue = "0"
        case .swapAllowanceSetup:
            guard let setup = action.swapAllowanceSetup,
                  let configuration = reviewRegistry?.uniswapConfiguration(
                    networkID: entry.networkID,
                    universalRouterContractID:
                        setup.binding.universalRouterContractID
                  ),
                  reviewedSwapRouteIsSigned(
                    setup.binding.exactInputSwapAction(),
                    networkID: entry.networkID
                  ),
                  WalletSwapAllowanceAdapter.resolve(
                    action: action, registryEntry: entry,
                    configuration: configuration
                  ) != nil else {
                throw signerError(
                    "The allowance is not a finite setup derived from an active reviewed swap."
                )
            }
            nativeValue = "0"
        default:
            throw signerError("This registered transaction kind is not implemented.")
        }
        guard SignerUnsignedInteger.normalize(packet.transaction.value) == nativeValue else {
            throw signerError("The registered transaction carries an unexpected native value.")
        }
        let capability: WalletNetworkCapability = switch action.type {
        case .fungibleTokenTransfer: .fungibleTokenTransfer
        case .nftTransfer: .nftTransfer
        case .exactInputSwap, .swapAllowanceSetup: .exactInputSwap
        default:
            switch WalletReviewedAdapters.validatedID(for: entry) {
            case WalletReviewedAdapters.erc20: .fungibleTokenTransfer
            case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
                 WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn:
                .exactInputSwap
            default: .reviewedCall
            }
        }
        try authorizeNetwork(packet.request.networkID, capability: capability)
        let encodingRequest = WalletContractEncodingRequest(
            action: action, registryEntry: entry, accountID: packet.request.accountID
        )
        let authoritative = try authoritativeContractEncoding(encodingRequest)
        guard authoritative == encoded,
              authoritative.input.caseInsensitiveCompare(packet.transaction.input) == .orderedSame else {
            throw signerError("The transaction calldata does not match signer ABI encoding.")
        }
        guard SignerUnsignedInteger.lessThanOrEqual(
                  packet.transaction.maxPriorityFeePerGas, packet.transaction.maxFeePerGas
              ),
              let fee = SignerUnsignedInteger.multiply(
                  String(packet.transaction.gasLimit), packet.transaction.maxFeePerGas
              ),
              fee == SignerUnsignedInteger.normalize(packet.feeQuoteBaseUnits),
              SignerUnsignedInteger.lessThanOrEqual(fee, packet.request.maximumFeeBaseUnits) else {
            throw signerError("The account or fee evidence does not match the registered call.")
        }
        let rust = try rustPrepare(transaction: packet.transaction, entropy: entropy)
        guard rust.from.caseInsensitiveCompare(account.address) == .orderedSame else {
            throw signerError("The vault derivation does not match the requested account.")
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        let decoded = decodedContractEffects(
            intentID: intentID, action: action,
            entry: entry, account: account, nativeValue: nativeValue
        )
        let semanticCall = WalletEVMAssetAdapter.resolve(
            action: action, registryEntry: entry, accountAddress: account.address
        )
        let allowanceCall = action.swapAllowanceSetup.flatMap { setup in
            reviewRegistry?.uniswapConfiguration(
                networkID: entry.networkID,
                universalRouterContractID: setup.binding.universalRouterContractID
            ).flatMap {
                WalletSwapAllowanceAdapter.resolve(
                    action: action, registryEntry: entry, configuration: $0
                )
            }
        }
        let function = action.type == .exactInputSwap
            ? "execute(bytes,bytes[],uint256)"
            : action.function ?? semanticCall?.function
                ?? allowanceCall?.function ?? ""
        let identity = WalletContractIdentity(
            registryID: entry.id, address: entry.checksumAddress, label: entry.label,
            function: function, abiDigest: entry.abiDigest,
            runtimeCodeHash: entry.runtimeCodeHash
        )
        var prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.digest, networkID: packet.request.networkID,
            accountID: packet.request.accountID, source: packet.request.source,
            action: action,
            summary: action.type == .fungibleTokenTransfer
                ? "Send reviewed \(entry.label) tokens on \(packet.request.networkID)"
                : action.type == .nftTransfer
                    ? "Transfer reviewed \(entry.label) collectible on \(packet.request.networkID)"
                    : action.type == .exactInputSwap
                        ? "Swap exact input through reviewed \(entry.label) on \(packet.request.networkID)"
                    : action.type == .swapAllowanceSetup
                        ? "Set up an exact finite swap allowance through reviewed \(entry.label) on \(packet.request.networkID)"
                        : "Call \(entry.label).\(function) on \(packet.request.networkID)",
            effects: decoded.effects, riskFlags: decoded.riskFlags, contract: identity,
            adapterID: decoded.adapterID, budgetAssetID: decoded.budgetAssetID,
            spendBaseUnits: decoded.spendBaseUnits,
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee, simulation: packet.simulation,
            simulationSucceeded: true, nonce: String(packet.transaction.nonce),
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        if action.type != .swapAllowanceSetup,
           packet.request.source.kind == .agent,
           let policyID = try? validAutomaticPolicyID(for: prepared) {
            prepared.policyDecision = "allowed_by_session_policy"
            prepared.policyID = policyID
        }
        return StoredEVMIntent(transaction: packet.transaction, prepared: prepared)
    }

    private func authoritativeContractEncoding(
        _ request: WalletContractEncodingRequest
    ) throws -> WalletEncodedContractCall {
        let action = request.action
        let entry = request.registryEntry
        guard Self.evmChainID(for: entry.networkID) != nil,
              Self.isEVMAddress(entry.checksumAddress),
              entry.runtimeCodeHash.count == 66,
              entry.runtimeCodeHash.hasPrefix("0x"),
              entry.runtimeCodeHash.dropFirst(2).allSatisfy(\.isHexDigit),
              entry.normalizedABI.utf8.count <= 256 * 1024,
              let abiData = entry.normalizedABI.data(using: .utf8) else {
            throw signerError("The semantic call is outside the registered ABI boundary.")
        }
        let function: String
        let arguments: [WalletTypedArgument]
        switch action.type {
        case .contractCall:
            guard action.contractID == entry.id,
                  let requestedFunction = action.function,
                  action.arguments.count <= 64 else {
                throw signerError("The semantic call is outside the registered ABI boundary.")
            }
            function = requestedFunction
            arguments = action.arguments
        case .fungibleTokenTransfer, .nftTransfer:
            guard let accountID = request.accountID,
                  let account = try store.accounts().first(where: {
                      $0.id == accountID && $0.chain == .evm
                          && $0.networkIDs.contains(entry.networkID)
                  }),
                  let semantic = WalletEVMAssetAdapter.resolve(
                      action: action, registryEntry: entry,
                      accountAddress: account.address
                  ) else {
                throw signerError("The semantic asset transfer is outside its reviewed adapter.")
            }
            function = semantic.function
            arguments = semantic.arguments
        case .exactInputSwap:
            guard action.contractID == entry.id,
                  WalletReviewedAdapters.validatedID(for: entry)
                    == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                  reviewedSwapRouteIsSigned(
                    action, networkID: entry.networkID
                  ),
                  let accountID = request.accountID,
                  let account = try store.accounts().first(where: {
                      $0.id == accountID && $0.chain == .evm
                          && $0.networkIDs.contains(entry.networkID)
                  }),
                  let materialized = WalletUniversalRouterV2V3Adapter.contractAction(
                    for: action, accountAddress: account.address,
                    networkID: entry.networkID
                  ) else {
                throw signerError(
                    "The semantic swap is outside its reviewed EVM adapter."
                )
            }
            function = materialized.function ?? ""
            arguments = materialized.arguments
        case .swapAllowanceSetup:
            guard let setup = action.swapAllowanceSetup,
                  let configuration = reviewRegistry?.uniswapConfiguration(
                    networkID: entry.networkID,
                    universalRouterContractID:
                        setup.binding.universalRouterContractID
                  ),
                  reviewedSwapRouteIsSigned(
                    setup.binding.exactInputSwapAction(),
                    networkID: entry.networkID
                  ),
                  let materialized = WalletSwapAllowanceAdapter.resolve(
                    action: action, registryEntry: entry,
                    configuration: configuration
                  ) else {
                throw signerError(
                    "The allowance setup is outside the signed Uniswap configuration."
                )
            }
            function = materialized.function
            arguments = materialized.arguments
        default:
            throw signerError("The semantic call has no reviewed EVM adapter.")
        }
        guard entry.permittedFunctions.contains(function) else {
            throw signerError("The semantic function is not permitted by the registry.")
        }
        let digest = "sha256:" + SHA256.hash(data: abiData)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == entry.abiDigest else {
            throw signerError("The registered ABI digest does not match its normalized ABI.")
        }
        let rustRequest = RustContractCallRequest(
            normalizedABI: entry.normalizedABI, function: function, arguments: arguments
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(rustRequest)
        guard var json = String(data: data, encoding: .utf8) else {
            throw signerError("The registered contract call could not be encoded.")
        }
        defer { json.replaceSubrange(json.startIndex..<json.endIndex, with: "") }
        guard let pointer = json.withCString({ rustEncodeContractCall($0) }) else {
            throw signerError("The signing core contract encoder is unavailable.")
        }
        defer { rustFreeString(pointer) }
        let result = Data(String(cString: pointer).utf8)
        if let failure = try? JSONDecoder().decode(WalletSignerErrorPayload.self, from: result) {
            throw signerError(failure.error)
        }
        let decoded = try JSONDecoder().decode(RustEncodedContractCall.self, from: result)
        guard let index = entry.permittedFunctions.firstIndex(of: function),
              entry.permittedSelectors.indices.contains(index),
              decoded.input.lowercased().hasPrefix(entry.permittedSelectors[index].lowercased()) else {
            throw signerError("The signer-produced selector is not permitted by the registry.")
        }
        return WalletEncodedContractCall(input: decoded.input.lowercased())
    }

    private func decodedContractEffects(
        intentID: String,
        action: WalletSemanticAction,
        entry: WalletContractRegistryEntry,
        account: WalletAccount,
        nativeValue: String
    ) -> (effects: [WalletDecodedEffect], riskFlags: [WalletRiskFlag],
          adapterID: String?, budgetAssetID: String, spendBaseUnits: String) {
        let tokenAsset = "\(entry.networkID)/erc20:\(entry.checksumAddress.lowercased())"
        let reviewedAdapterID = WalletReviewedAdapters.validatedID(for: entry)
        var effects: [WalletDecodedEffect] = []
        var riskFlags: [WalletRiskFlag] = [.unknownEffect]
        var adapterID: String?
        var budgetAssetID = "\(entry.networkID)/contract:\(entry.checksumAddress.lowercased())"
        var spendBaseUnits = "0"
        if let setup = action.swapAllowanceSetup,
           let configuration = reviewRegistry?.uniswapConfiguration(
                networkID: entry.networkID,
                universalRouterContractID: setup.binding.universalRouterContractID
           ),
           let semantic = WalletSwapAllowanceAdapter.resolve(
                action: action, registryEntry: entry,
                configuration: configuration
           ) {
            let spender = setup.stage == .permit2ToUniversalRouter
                ? setup.binding.universalRouterAddress
                : setup.binding.permit2Address
            effects = [WalletDecodedEffect(
                id: "\(intentID):swap-allowance",
                kind: setup.approvalAmountBaseUnits == "0"
                    ? "approval_revoke" : "approval",
                assetID: semantic.assetID,
                amountBaseUnits: setup.approvalAmountBaseUnits,
                from: account.address, to: nil, spender: spender
            )]
            riskFlags = []
            adapterID = semantic.adapterID
            budgetAssetID = semantic.assetID
            spendBaseUnits = setup.approvalAmountBaseUnits
        } else if let semantic = WalletEVMAssetAdapter.resolve(
            action: action, registryEntry: entry, accountAddress: account.address
        ), action.type == .fungibleTokenTransfer,
           let amount = SignerUnsignedInteger.normalize(action.amountBaseUnits ?? "") {
            effects = [WalletDecodedEffect(
                id: "\(intentID):erc20-transfer", kind: "token_transfer",
                assetID: semantic.assetID, amountBaseUnits: amount,
                from: account.address, to: action.recipient, spender: nil
            )]
            riskFlags = []
            adapterID = semantic.adapterID
            budgetAssetID = semantic.assetID
            spendBaseUnits = amount
        } else if let semantic = WalletEVMAssetAdapter.resolve(
            action: action, registryEntry: entry, accountAddress: account.address
        ), action.type == .nftTransfer {
            let tokenID = action.tokenID ?? ""
            effects = [WalletDecodedEffect(
                id: "\(intentID):nft-transfer", kind: "nft_transfer",
                assetID: "\(semantic.assetID)/\(tokenID)", amountBaseUnits: "1",
                from: account.address, to: action.recipient, spender: nil
            )]
            riskFlags = []
            adapterID = semantic.adapterID
            budgetAssetID = "\(semantic.assetID)/\(tokenID)"
            spendBaseUnits = "1"
        } else if action.function == "transfer(address,uint256)", action.arguments.count == 2,
           action.arguments[0].type == "address", action.arguments[1].type == "uint256",
           Self.isEVMAddress(action.arguments[0].value),
           let amount = SignerUnsignedInteger.normalize(action.arguments[1].value) {
            effects = [WalletDecodedEffect(
                id: "\(intentID):erc20-transfer", kind: "token_transfer", assetID: tokenAsset,
                amountBaseUnits: amount, from: account.address, to: action.arguments[0].value,
                spender: nil
            )]
            riskFlags = []
            adapterID = reviewedAdapterID == WalletReviewedAdapters.erc20
                ? WalletReviewedAdapters.erc20 : nil
            budgetAssetID = tokenAsset
            spendBaseUnits = amount
        } else if action.function == "approve(address,uint256)", action.arguments.count == 2,
                  action.arguments[0].type == "address", action.arguments[1].type == "uint256",
                  Self.isEVMAddress(action.arguments[0].value),
                  let amount = SignerUnsignedInteger.normalize(action.arguments[1].value) {
            effects = [WalletDecodedEffect(
                id: "\(intentID):erc20-approval", kind: amount == "0" ? "approval_revoke" : "approval",
                assetID: tokenAsset, amountBaseUnits: amount, from: account.address, to: nil,
                spender: action.arguments[0].value
            )]
            riskFlags = amount == Self.maximumUInt256Decimal ? [.unlimitedApproval] : []
            adapterID = reviewedAdapterID == WalletReviewedAdapters.erc20
                ? WalletReviewedAdapters.erc20 : nil
            budgetAssetID = tokenAsset
            spendBaseUnits = amount
        } else if let swapAction = action.type == .exactInputSwap
                    ? WalletUniversalRouterV2V3Adapter.contractAction(
                        for: action, accountAddress: account.address,
                        networkID: entry.networkID
                      ) : action,
                  let swap = Self.reviewedUniversalRouterSwap(
            adapterID: reviewedAdapterID, action: swapAction,
            accountAddress: account.address, networkID: entry.networkID
        ) {
            effects = [
                WalletDecodedEffect(
                    id: "\(intentID):uniswap-spend", kind: "token_swap_exact_in",
                    assetID: swap.inputAssetID, amountBaseUnits: swap.amountIn,
                    from: account.address, to: entry.checksumAddress, spender: nil
                ),
                WalletDecodedEffect(
                    id: "\(intentID):uniswap-minimum-receive", kind: "minimum_receive",
                    assetID: swap.outputAssetID, amountBaseUnits: swap.minimumAmountOut,
                    from: entry.checksumAddress, to: swap.recipient, spender: nil
                ),
            ]
            riskFlags = []
            adapterID = reviewedAdapterID
            budgetAssetID = swap.inputAssetID
            spendBaseUnits = swap.amountIn
        } else {
            effects = [WalletDecodedEffect(
                id: "\(intentID):contract-call", kind: "contract_call",
                assetID: budgetAssetID, amountBaseUnits: "0", from: account.address,
                to: entry.checksumAddress, spender: nil
            )]
        }
        if nativeValue != "0" {
            effects.append(WalletDecodedEffect(
                id: "\(intentID):native-value", kind: "native_value",
                assetID: "\(entry.networkID)/slip44:60",
                amountBaseUnits: nativeValue, from: account.address,
                to: entry.checksumAddress, spender: nil
            ))
            // Reviewed token and swap adapters cover no native-value side
            // effect. Such calls remain available only by exact confirmation.
            riskFlags.append(.unknownEffect)
            adapterID = nil
        }
        return (effects, riskFlags, adapterID, budgetAssetID, spendBaseUnits)
    }

    private static let maximumUInt256Decimal =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    private static func reviewedUniversalRouterSwap(
        adapterID: String?,
        action: WalletSemanticAction,
        accountAddress: String,
        networkID: String
    ) -> WalletUniversalRouterV2Swap? {
        switch adapterID {
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn:
            WalletUniversalRouterV2Adapter.decode(
                action: action, accountAddress: accountAddress,
                networkID: networkID
            )
        case WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn:
            WalletUniversalRouterV2V3Adapter.decode(
                action: action, accountAddress: accountAddress,
                networkID: networkID
            )
        default:
            nil
        }
    }

    private func reviewedSwapRouteIsSigned(
        _ action: WalletSemanticAction,
        networkID: String,
        now: Date = Date()
    ) -> Bool {
        guard let route = action.swapRoute,
              let evidence = route.quoteEvidence,
              let contractID = action.contractID,
              let reviewRegistry,
              let configuration = reviewRegistry.uniswapConfiguration(
                networkID: networkID,
                universalRouterContractID: contractID
              ),
              evidence.quotedAt <= now.addingTimeInterval(5),
              evidence.expiresAt > now,
              evidence.expiresAt.timeIntervalSince(evidence.quotedAt) <= 60.5,
              let deadline = UInt64(route.deadlineUnixSeconds),
              deadline <= UInt64(max(0, evidence.quotedAt.timeIntervalSince1970)) + 600,
              route.slippageBPS <= 500,
              evidence.perHopOutputBaseUnits.count == route.pathAssetIDs.count - 1,
              evidence.perHopOutputBaseUnits.last == route.quotedOutputBaseUnits,
              evidence.gasEstimate != "0",
              evidence.blockHash.count == 66,
              evidence.blockHash.hasPrefix("0x"),
              evidence.blockHash.dropFirst(2).allSatisfy(\.isHexDigit) else {
            return false
        }
        #if DEBUG
        guard evidence.agreeingProviderCount >= 1 else { return false }
        #else
        guard evidence.agreeingProviderCount >= 2 else { return false }
        #endif
        let quoteRole: WalletReviewedUniswapContractRole =
            route.protocolVersion == .v2 ? .v2Router : .v3QuoterV2
        guard let quoteContract = configuration.contract(quoteRole),
              quoteContract.address.caseInsensitiveCompare(
                evidence.quoteContractAddress
              ) == .orderedSame,
              quoteContract.runtimeCodeHash.caseInsensitiveCompare(
                evidence.quoteContractRuntimeCodeHash
              ) == .orderedSame,
              Set(route.pathAssetIDs).count == route.pathAssetIDs.count else {
            return false
        }
        let hopCount = route.pathAssetIDs.count - 1
        guard (route.protocolVersion == .v2 && route.feeTiers.isEmpty)
                || (route.protocolVersion == .v3
                    && route.feeTiers.count == hopCount) else { return false }
        for index in 0..<hopCount {
            let lhs = route.pathAssetIDs[index]
            let rhs = route.pathAssetIDs[index + 1]
            let expectedFee = route.protocolVersion == .v3
                ? route.feeTiers[index] : nil
            guard configuration.pools.contains(where: { pool in
                pool.protocolVersion == route.protocolVersion
                    && pool.feeTier == expectedFee
                    && ((pool.token0AssetID == lhs && pool.token1AssetID == rhs)
                        || (pool.token0AssetID == rhs && pool.token1AssetID == lhs))
            }) else { return false }
            if index + 1 < hopCount,
               !configuration.allowedIntermediaryAssetIDs.contains(rhs) {
                return false
            }
        }
        return route.pathAssetIDs.allSatisfy { assetID in
            guard let identity = WalletEVMAssetIdentity.parse(assetID),
                  identity.networkID == networkID,
                  identity.standard == .erc20,
                  let asset = reviewRegistry.assets.first(where: {
                      $0.id == assetID
                  }),
                  asset.chain == .evm, asset.kind == .fungibleToken,
                  asset.trust == .curated,
                  asset.reference?.caseInsensitiveCompare(
                    identity.contractAddress
                  ) == .orderedSame else { return false }
            return reviewRegistry.containsExactAsset(asset)
        }
    }

    private func validatePolicy(_ policy: WalletSessionPolicy) throws {
        try authorizeNetwork(policy.networkID, capability: .autonomousPolicy)
        let accounts = try store.accounts()
        guard let descriptor = WalletNetworkCatalog.descriptor(id: policy.networkID) else {
            throw signerError("The policy network is not recognized.")
        }
        let validRecipient: (String) -> Bool = switch descriptor.chain {
        case .evm: Self.isEVMAddress
        case .solana: Self.isSolanaAddress
        case .sui: { _ in false }
        }
        guard !policy.id.isEmpty, policy.id.count <= 128,
              accounts.contains(where: {
                  $0.id == policy.accountID && $0.chain == descriptor.chain
                      && $0.networkIDs.contains(policy.networkID)
              }),
              policy.expiresAt > Date(),
              policy.expiresAt <= Date().addingTimeInterval(8 * 60 * 60),
              !policy.allowedRecipients.isEmpty,
              policy.allowedRecipients.count <= 32,
              policy.allowedRecipients.allSatisfy(validRecipient),
              policy.allowedAssetIDs.count == 1,
              policy.allowedAdapterIDs.count == 1,
              policy.allowedActionKinds?.isEmpty == false,
              policy.allowedContractIDs.count <= 1,
              SignerUnsignedInteger.normalize(policy.maximumTransactionBaseUnits) != nil,
              SignerUnsignedInteger.normalize(policy.maximumSessionBaseUnits) != nil,
              SignerUnsignedInteger.normalize(policy.maximumFeeBaseUnits) != nil,
              SignerUnsignedInteger.lessThanOrEqual(
                  policy.maximumTransactionBaseUnits, policy.maximumSessionBaseUnits
              ) else {
            throw signerError(
                "Wallet policies require one reviewed adapter and asset, explicit chain-valid counterparties, bounded base-unit budgets, and an expiry within eight hours."
            )
        }
        let adapterID = policy.allowedAdapterIDs.first!
        let swapAdapterIDs: Set<String> = [
            WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
            WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
        ]
        if swapAdapterIDs.contains(adapterID) {
            guard policy.allowedActionKinds == [.exactInputSwap],
                  let maximumSlippage = policy.maximumSlippageBPS,
                  (0...5_000).contains(maximumSlippage),
                  let minimumOutput = policy.minimumOutputBaseUnits,
                  SignerUnsignedInteger.normalize(minimumOutput) == minimumOutput,
                  minimumOutput != "0" else {
                throw signerError(
                    "Swap policies require an exact-input action, slippage limit, and positive minimum-output floor."
                )
            }
        }
        let nativeEVMPolicy = descriptor.chain == .evm
            && adapterID == WalletReviewedAdapters.ethereumNativeTransfer
            && policy.allowedAssetIDs == ["\(policy.networkID)/slip44:60"]
            && policy.allowedContractIDs.isEmpty
        let nativeSolanaPolicy = descriptor.chain == .solana
            && adapterID == WalletReviewedAdapters.solanaNativeTransfer
            && policy.allowedAssetIDs == ["\(policy.networkID)/slip44:501"]
            && policy.allowedContractIDs.isEmpty
        let solanaTokenPolicy = descriptor.chain == .solana
            && [WalletReviewedAdapters.solanaSPLTransferChecked,
                WalletReviewedAdapters.solanaToken2022TransferChecked].contains(
                    adapterID
                )
            && policy.allowedAssetIDs.allSatisfy {
                guard let identity = WalletSolanaAssetIdentity.parse($0) else {
                    return false
                }
                return identity.networkID == policy.networkID
                    && (identity.program == .spl
                        ? adapterID == WalletReviewedAdapters.solanaSPLTransferChecked
                        : adapterID
                            == WalletReviewedAdapters.solanaToken2022TransferChecked)
            }
            && policy.allowedContractIDs.isEmpty
        let contractPolicy = descriptor.chain == .evm && [
            WalletReviewedAdapters.erc20,
            WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
            WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
        ].contains(adapterID)
            && policy.allowedContractIDs.count == 1
            && policy.allowedAssetIDs.allSatisfy {
                Self.isERC20AssetID($0, networkID: policy.networkID)
            }
        guard nativeEVMPolicy || nativeSolanaPolicy || solanaTokenPolicy
                || contractPolicy else {
            throw signerError("The policy does not match a supported reviewed adapter shape.")
        }
    }

    private func validAutomaticPolicyID(for transaction: WalletPreparedTransaction) throws -> String {
        expirePolicies()
        guard transaction.source.kind == .agent,
              transaction.action.type != .swapAllowanceSetup,
              let adapterID = transaction.adapterID,
              [WalletReviewedAdapters.ethereumNativeTransfer,
               WalletReviewedAdapters.solanaNativeTransfer,
               WalletReviewedAdapters.solanaSPLTransferChecked,
               WalletReviewedAdapters.solanaToken2022TransferChecked,
               WalletReviewedAdapters.erc20,
               WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
               WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn]
                .contains(adapterID),
              transaction.riskFlags.isEmpty,
              let counterparties = policyCounterparties(for: transaction),
              !counterparties.isEmpty else {
            throw signerError("This transaction has no reviewed autonomous effect adapter.")
        }
        for active in activePolicies.values.sorted(by: { $0.policy.id < $1.policy.id }) {
            let policy = active.policy
            let contractMatches = transaction.contract.map {
                policy.allowedContractIDs.contains($0.registryID)
            } ?? policy.allowedContractIDs.isEmpty
            let swapPolicyMatches: Bool
            if [WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
                WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn]
                .contains(adapterID) {
                let outputs = transaction.effects.filter {
                    $0.kind == "minimum_receive"
                }
                swapPolicyMatches = transaction.action.type == .exactInputSwap
                    && transaction.action.swapRoute.map { route in
                        policy.maximumSlippageBPS.map {
                            route.slippageBPS <= $0
                        } == true
                    } == true
                    && policy.minimumOutputBaseUnits.map { minimum in
                        outputs.count == 1
                            && SignerUnsignedInteger.lessThanOrEqual(
                                minimum, outputs[0].amountBaseUnits
                            )
                    } == true
            } else {
                swapPolicyMatches = true
            }
            guard policy.accountID == transaction.accountID,
                  policy.networkID == transaction.networkID,
                  policy.allowedActionKinds?.contains(transaction.action.type) == true,
                  policy.allowedAssetIDs.contains(transaction.budgetAssetID),
                  policy.allowedAdapterIDs.contains(adapterID),
                  counterparties.allSatisfy({ counterparty in
                      policy.allowedRecipients.contains(where: {
                          $0.caseInsensitiveCompare(counterparty) == .orderedSame
                      })
                  }),
                  contractMatches, swapPolicyMatches,
                  SignerUnsignedInteger.lessThanOrEqual(
                      transaction.spendBaseUnits, policy.maximumTransactionBaseUnits
                  ),
                  SignerUnsignedInteger.lessThanOrEqual(
                      transaction.maximumFeeBaseUnits, policy.maximumFeeBaseUnits
                  ),
                  SignerUnsignedInteger.lessThanOrEqual(
                      transaction.feeQuoteBaseUnits, transaction.maximumFeeBaseUnits
                  ),
                  let total = SignerUnsignedInteger.add(
                      active.spentBaseUnits, transaction.spendBaseUnits
                  ), SignerUnsignedInteger.lessThanOrEqual(total, policy.maximumSessionBaseUnits) else {
                continue
            }
            return policy.id
        }
        throw signerError("No active signer policy covers this exact transaction.")
    }

    private func policyCounterparties(for transaction: WalletPreparedTransaction) -> [String]? {
        switch transaction.adapterID {
        case WalletReviewedAdapters.ethereumNativeTransfer,
             WalletReviewedAdapters.solanaNativeTransfer,
             WalletReviewedAdapters.solanaSPLTransferChecked,
             WalletReviewedAdapters.solanaToken2022TransferChecked:
            return transaction.action.recipient.map { [$0] }
        case WalletReviewedAdapters.erc20:
            let values = transaction.effects.compactMap { effect -> String? in
                if effect.kind == "token_transfer" { return effect.to }
                if effect.kind == "approval" || effect.kind == "approval_revoke" {
                    return effect.spender
                }
                return nil
            }
            return values
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
             WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn:
            guard transaction.action.type == .exactInputSwap,
                  let deadlineText = transaction.action.swapRoute?
                    .deadlineUnixSeconds,
                  let deadline = UInt64(deadlineText),
                  deadline >= UInt64(max(0, Date().timeIntervalSince1970.rounded(.down))) else {
                return nil
            }
            return transaction.effects.filter { $0.kind == "minimum_receive" }.compactMap(\.to)
        default:
            return nil
        }
    }

    private func reserveBudget(for transaction: WalletPreparedTransaction, policyID: String) throws {
        guard policyID == transaction.policyID,
              var active = activePolicies[policyID],
              let total = SignerUnsignedInteger.add(
                  active.spentBaseUnits, transaction.spendBaseUnits
              ), SignerUnsignedInteger.lessThanOrEqual(
                  total, active.policy.maximumSessionBaseUnits
              ) else {
            throw signerError("The autonomous policy budget changed before signing.")
        }
        active.spentBaseUnits = total
        activePolicies[policyID] = active
    }

    private func expirePolicies() {
        let now = Date()
        activePolicies = activePolicies.filter { $0.value.policy.expiresAt > now }
    }

    private func expireIntents() {
        let now = Date()
        preparedIntents = preparedIntents.filter { $0.value.prepared.expiresAt > now }
        preparedSolanaIntents = preparedSolanaIntents.filter {
            $0.value.prepared.expiresAt > now
        }
        preparedSuiIntents = preparedSuiIntents.filter {
            $0.value.prepared.expiresAt > now
        }
    }

    private func policyStatuses() -> [WalletActivePolicyStatus] {
        activePolicies.values.map(\.status).sorted { $0.policy.expiresAt < $1.policy.expiresAt }
    }

    private static func isEVMAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static let solanaSystemProgramID =
        "11111111111111111111111111111111"
    private static let solanaAssociatedTokenProgramID =
        "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
    private static let solanaCoreProgramID =
        "CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d"

    private static func isSolanaAddress(_ value: String) -> Bool {
        WalletSolanaBase58.decode(value, exactLength: 32) != nil
    }

    private func canonicalTokenExtensionArgument(
        _ value: String?,
        required: Bool
    ) throws -> [String] {
        if !required {
            guard value == nil else {
                throw signerError(
                    "Classic SPL evidence cannot contain Token-2022 extensions."
                )
            }
            return []
        }
        guard let value else {
            throw signerError("Token-2022 extension evidence is missing.")
        }
        let parsed = value.isEmpty ? [] : value.split(
            separator: ",", omittingEmptySubsequences: false
        ).map(String.init)
        guard parsed.allSatisfy(Self.validSolanaExtensionName),
              parsed == Array(Set(parsed)).sorted() else {
            throw signerError("Token-2022 extension evidence is not canonical.")
        }
        return parsed
    }

    private func requireSafeTokenExtensions(
        program: WalletSolanaTokenProgram,
        mint: [String],
        source: [String],
        destination: [String]
    ) throws {
        if program == .spl {
            guard mint.isEmpty, source.isEmpty, destination.isEmpty else {
                throw signerError("Classic SPL extension evidence is invalid.")
            }
            return
        }
        let safeMint: Set<String> = ["metadataPointer", "tokenMetadata"]
        let safeAccount: Set<String> = ["immutableOwner"]
        guard Set(mint).isSubset(of: safeMint),
              Set(source).isSubset(of: safeAccount),
              Set(destination).isSubset(of: safeAccount) else {
            throw signerError(
                "The Token-2022 extensions change reviewed transfer semantics."
            )
        }
    }

    private static func validSolanaExtensionName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0)
        }
    }

    private static func solanaResolvedAccountsDigest(
        feePayer: String,
        recipient: String
    ) -> String {
        let value = Data(
            "legacy|\(solanaSystemProgramID)|\(feePayer):signer:writable|\(recipient):nonsigner:writable"
                .utf8
        )
        return "sha256:" + SHA256.hash(data: value).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func solanaSPLResolvedAccountsDigest(
        feePayer: String,
        sourceTokenAccount: String,
        mint: String,
        destinationTokenAccount: String,
        recipientOwner: String,
        createsDestinationAssociatedAccount: Bool = false,
        tokenProgramID: String = WalletSolanaTokenProgram.spl.programID,
        mintExtensions: [String] = [],
        sourceExtensions: [String] = [],
        destinationExtensions: [String] = []
    ) -> String {
        var description =
            "legacy|\(tokenProgramID)|\(feePayer):signer:writable|\(sourceTokenAccount):nonsigner:writable|\(mint):nonsigner:readonly|\(destinationTokenAccount):nonsigner:writable|owner:\(recipientOwner)"
        if createsDestinationAssociatedAccount {
            description += "|create_ata:\(solanaAssociatedTokenProgramID)"
        }
        if tokenProgramID == WalletSolanaTokenProgram.token2022.programID {
            description += "|mint_exts:\(mintExtensions.joined(separator: ","))"
            description += "|source_exts:\(sourceExtensions.joined(separator: ","))"
            description += "|destination_exts:\(destinationExtensions.joined(separator: ","))"
        }
        let value = Data(description.utf8)
        return "sha256:" + SHA256.hash(data: value).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func solanaCoreResolvedAccountsDigest(
        feePayer: String,
        asset: String,
        recipient: String,
        assetDataDigest: String
    ) -> String {
        let value = Data(
            "legacy|\(solanaCoreProgramID)|\(feePayer):signer:writable|\(asset):nonsigner:writable|\(recipient):nonsigner:readonly|standalone:true|plugins:none|asset_data:\(assetDataDigest)"
                .utf8
        )
        return "sha256:" + SHA256.hash(data: value).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func evmChainID(for networkID: String) -> UInt64? {
        switch networkID {
        case "eip155:1": 1
        case "eip155:11155111": 11_155_111
        default: nil
        }
    }

    private func capability(for action: WalletActionKind) -> WalletNetworkCapability {
        switch action {
        case .nativeTransfer: .nativeTransfer
        case .fungibleTokenTransfer: .fungibleTokenTransfer
        case .nftTransfer: .nftTransfer
        case .exactInputSwap, .swapAllowanceSetup: .exactInputSwap
        case .contractCall, .reviewedCall: .reviewedCall
        case .standardizedSignIn, .reviewedTypedAuthorization: .externalWallet
        }
    }

    private func authorizeNetwork(
        _ networkID: String,
        chain: WalletChain = .evm,
        capability: WalletNetworkCapability
    ) throws {
        guard let descriptor = WalletNetworkCatalog.descriptor(id: networkID),
              descriptor.chain == chain else {
            throw signerError("The signer does not recognize this network identity.")
        }
        guard descriptor.staticallyReviewedCapabilities.contains(capability) else {
            throw signerError("That chain adapter is not compiled as reviewed authority in this build.")
        }
        guard descriptor.environment == .mainnet else { return }
        try requireCurrentActivation()
        guard let launchGate else {
            throw signerError(
                "Mainnet signing requires a verified release activation for this build."
            )
        }
        do {
            try launchGate.authorize(
                networkID: networkID, capability: capability,
                regionCode: regionCode
            )
        } catch {
            throw signerError(error.localizedDescription)
        }
    }

    private func authorizeReviewedAdapter(
        _ adapterID: String,
        networkID: String
    ) throws {
        guard WalletReviewedAdapters.staticallySupportedIDs.contains(adapterID),
              let descriptor = WalletNetworkCatalog.descriptor(id: networkID) else {
            throw signerError("The signer does not recognize this reviewed adapter.")
        }
        guard descriptor.environment == .mainnet else { return }
        guard reviewRegistry?.containsAdapter(adapterID) == true else {
            throw signerError(
                "Mainnet signing is disabled because the adapter is absent from the signed review manifest."
            )
        }
    }

    private func authorizeStructuredSignIn(
        _ request: WalletStructuredAuthorizationRequest
    ) throws {
        guard let descriptor = WalletNetworkCatalog.descriptor(id: request.networkID),
              (request.format == .siwe && descriptor.chain == .evm)
                || (request.format == .siws && descriptor.chain == .solana),
              reviewRegistry?.containsSignInAdapter(
                  format: request.format, networkID: request.networkID
              ) == true else {
            throw signerError(
                "This standardized sign-in adapter is absent from the signed review manifest."
            )
        }
        guard descriptor.environment == .mainnet else { return }
        do {
            try requireCurrentActivation()
            guard let launchGate else {
                throw WalletLaunchGateError.capabilityNotReviewed
            }
            try launchGate.authorize(
                networkID: request.networkID,
                capability: .standardizedSignIn,
                regionCode: regionCode
            )
        } catch {
            throw signerError(error.localizedDescription)
        }
    }

    private func authorizationReplayKey(
        _ request: WalletStructuredAuthorizationRequest
    ) -> String {
        [
            request.format.rawValue,
            request.networkID,
            request.accountID,
            request.domain.lowercased(),
            request.nonce,
        ].joined(separator: "|")
    }

    private func rustStructuredAuthorization(
        format: WalletStructuredAuthorizationFormat,
        canonicalMessage: String,
        expectedAddress: String,
        entropy: Data
    ) throws -> RustSignedStructuredAuthorization {
        let request = RustStructuredAuthorizationRequest(
            format: format.coreIdentifier,
            canonicalMessage: canonicalMessage,
            expectedAddress: expectedAddress
        )
        return try rustSolanaCall(
            request: request,
            entropy: entropy,
            function: rustSignStructuredAuthorization
        )
    }

    private func requireUserPresence(
        reason: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let context = LAContext()
        context.localizedReason = reason
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication, error: &evaluationError
        ) else {
            completion(.failure(evaluationError ?? signerError("User presence is unavailable.")))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) {
            success, error in
            self.queue.async {
                if success { completion(.success(())) }
                else { completion(.failure(error ?? self.signerError("User presence was not confirmed."))) }
            }
        }
    }

    private static func loadLaunchGate(bundle: Bundle = .main) -> WalletLaunchGate? {
        guard let publicKeyText = bundle.object(
            forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
        ) as? String,
        let publicKeyData = Data(base64Encoded: publicKeyText),
        let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
        let manifestText = bundle.object(
            forInfoDictionaryKey: "LocusWalletCapabilityManifestBase64"
        ) as? String,
        let manifestData = Data(base64Encoded: manifestText) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            WalletSignedCapabilityManifest.self, from: manifestData
        ) else { return nil }
        return try? WalletLaunchGate(signedManifest: signed, publicKey: publicKey)
    }

    private static func loadActivationPublicKey(
        bundle: Bundle = .main
    ) -> Curve25519.Signing.PublicKey? {
        guard let text = bundle.object(
            forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
        ) as? String,
        let data = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    private static func loadReviewRegistry(
        bundle: Bundle = .main
    ) -> WalletReviewRegistry? {
        guard let publicKeyText = bundle.object(
            forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
        ) as? String,
        let publicKeyData = Data(base64Encoded: publicKeyText),
        let publicKey = try? Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyData
        ),
        let manifestText = bundle.object(
            forInfoDictionaryKey: "LocusWalletReviewManifestBase64"
        ) as? String,
        let manifestData = Data(base64Encoded: manifestText) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            WalletSignedReviewManifest.self, from: manifestData
        ) else { return nil }
        return try? WalletReviewRegistry(
            signedManifest: signed, publicKey: publicKey
        )
    }

    private static func isERC20AssetID(_ value: String, networkID: String) -> Bool {
        let prefix = "\(networkID)/erc20:"
        guard value.hasPrefix(prefix) else { return false }
        return isEVMAddress(String(value.dropFirst(prefix.count)))
    }

    private func validatedIntent(for recheck: WalletEVMRecheckPacket) throws -> StoredEVMIntent {
        expireIntents()
        guard let intent = preparedIntents[recheck.intentID] else {
            throw signerError("The prepared transaction is missing or already consumed.")
        }
        let codeHashMatches: Bool
        if let expected = intent.prepared.contract?.runtimeCodeHash {
            codeHashMatches = recheck.observedRuntimeCodeHash?.caseInsensitiveCompare(expected)
                == .orderedSame
        } else {
            codeHashMatches = recheck.observedRuntimeCodeHash == nil
        }
        guard codeHashMatches,
              intent.prepared.expiresAt > Date(),
              recheck.chainID == intent.transaction.chainID,
              recheck.pendingNonce == intent.transaction.nonce,
              recheck.simulationSucceeded,
              abs(recheck.observedAt.timeIntervalSinceNow) <= 30,
              let currentFee = SignerUnsignedInteger.normalize(recheck.feeQuoteBaseUnits),
              SignerUnsignedInteger.lessThanOrEqual(
                  currentFee, intent.prepared.maximumFeeBaseUnits
              ) else {
            throw signerError("Nonce, chain, fee, simulation, or expiry changed after preparation.")
        }
        return intent
    }

    private func validatedSolanaIntent(
        for recheck: WalletSolanaRecheckPacket
    ) throws -> StoredSolanaIntent {
        expireIntents()
        guard let intent = preparedSolanaIntents[recheck.intentID],
              intent.prepared.expiresAt > Date(),
              recheck.genesisHash == intent.packet.genesisHash,
              recheck.currentBlockHeight <= intent.packet.lastValidBlockHeight,
              recheck.resolvedAccountsDigest == intent.packet.resolvedAccountsDigest,
              recheck.simulationSucceeded,
              abs(recheck.observedAt.timeIntervalSinceNow) <= 30,
              let fee = SignerUnsignedInteger.normalize(recheck.feeQuoteBaseUnits),
              fee == intent.packet.feeQuoteBaseUnits,
              SignerUnsignedInteger.lessThanOrEqual(
                  fee, intent.prepared.maximumFeeBaseUnits
              ) else {
            throw signerError(
                "Solana genesis, blockhash, accounts, fee, simulation, or expiry changed after preparation."
            )
        }
        return intent
    }

    private func validatedSuiIntent(
        for simulation: WalletSuiSimulationPacket
    ) throws -> StoredSuiIntent {
        expireIntents()
        guard let intent = preparedSuiIntents[simulation.intentID] else {
            throw signerError("The prepared Sui transaction is missing or consumed.")
        }
        let initialEffectsMatch = intent.simulation.map {
            $0.effectsDigest == simulation.effectsDigest
                && $0.assetID == simulation.assetID
                && $0.coinType == simulation.coinType
                && $0.coinObjectID == simulation.coinObjectID
                && $0.transferredObjectInput
                    == simulation.transferredObjectInput
                && $0.transferredObjectOutput
                    == simulation.transferredObjectOutput
                && $0.objectHasPublicTransfer
                    == simulation.objectHasPublicTransfer
                && $0.senderDebitBaseUnits == simulation.senderDebitBaseUnits
                && $0.senderGasDebitBaseUnits
                    == simulation.senderGasDebitBaseUnits
                && $0.recipientCreditBaseUnits == simulation.recipientCreditBaseUnits
                && $0.computationCost == simulation.computationCost
                && $0.storageCost == simulation.storageCost
                && $0.storageRebate == simulation.storageRebate
                && $0.nonRefundableStorageFee
                    == simulation.nonRefundableStorageFee
                && $0.actualFeeBaseUnits == simulation.actualFeeBaseUnits
        } ?? true
        guard initialEffectsMatch,
              intent.prepared.expiresAt > Date(),
              simulation.chainIdentifier == intent.packet.chainIdentifier,
              simulation.checkpointSequence >= intent.packet.checkpointSequence,
              simulation.checkpointTimestamp >= intent.packet.checkpointTimestamp,
              simulation.checkpointTimestamp <= Date().addingTimeInterval(120),
              simulation.checkpointTimestamp >= Date().addingTimeInterval(-15 * 60),
              simulation.currentEpoch == intent.packet.currentEpoch,
              simulation.referenceGasPriceBaseUnits
                == intent.packet.referenceGasPriceBaseUnits,
              simulation.transactionDigest == intent.rust.transactionDigest,
              WalletSolanaBase58.decode(simulation.effectsDigest, exactLength: 32) != nil,
              simulation.sender == intent.packet.sender,
              simulation.recipient == intent.packet.request.action.recipient,
              simulation.assetID == intent.packet.assetID,
              simulation.coinType == intent.packet.coinType,
              simulation.amountBaseUnits
                == intent.packet.request.action.amountBaseUnits,
              simulation.gasObjectID == intent.packet.gasObject.objectID,
              abs(simulation.observedAt.timeIntervalSinceNow) <= 30,
              let computation = SignerUnsignedInteger.normalize(
                  simulation.computationCost
              ), computation == simulation.computationCost,
              let storage = SignerUnsignedInteger.normalize(simulation.storageCost),
              storage == simulation.storageCost,
              SignerUnsignedInteger.normalize(simulation.nonRefundableStorageFee)
                == simulation.nonRefundableStorageFee,
              let rebate = SignerUnsignedInteger.normalize(simulation.storageRebate),
              rebate == simulation.storageRebate,
              let gross = SignerUnsignedInteger.add(computation, storage),
              let fee = SignerUnsignedInteger.subtract(gross, rebate), fee != "0",
              fee == simulation.actualFeeBaseUnits,
              SignerUnsignedInteger.lessThanOrEqual(
                  fee, intent.prepared.maximumFeeBaseUnits
              ) else {
            throw signerError(
                "Sui chain, checkpoint, object effects, amount, or fee changed after preparation."
            )
        }
        switch intent.prepared.action.type {
        case .nativeTransfer:
            guard simulation.coinType == WalletSuiAssetIdentity.nativeCoinType,
                  simulation.coinObjectID == nil,
                  simulation.transferredObjectInput == nil,
                  simulation.transferredObjectOutput == nil,
                  simulation.objectHasPublicTransfer == nil,
                  simulation.senderGasDebitBaseUnits == nil,
                  simulation.recipientCreditBaseUnits == simulation.amountBaseUnits,
                  SignerUnsignedInteger.add(simulation.amountBaseUnits, fee)
                    == simulation.senderDebitBaseUnits else {
                throw signerError(
                    "Sui native-transfer effects changed after preparation."
                )
            }
        case .fungibleTokenTransfer:
            guard let identity = WalletSuiAssetIdentity.parse(simulation.assetID),
                  identity.coinType == simulation.coinType,
                  identity.coinType != WalletSuiAssetIdentity.nativeCoinType,
                  simulation.coinObjectID == intent.packet.coinObject?.objectID,
                  simulation.transferredObjectInput == nil,
                  simulation.transferredObjectOutput == nil,
                  simulation.objectHasPublicTransfer == nil,
                  simulation.senderDebitBaseUnits == simulation.amountBaseUnits,
                  simulation.senderGasDebitBaseUnits == fee,
                  simulation.recipientCreditBaseUnits == simulation.amountBaseUnits else {
                throw signerError(
                    "Sui Coin-transfer effects changed after preparation."
                )
            }
        case .nftTransfer:
            guard simulation.coinType.isEmpty,
                  simulation.coinObjectID == nil,
                  let expectedObject = intent.packet.transferredObject,
                  simulation.transferredObjectInput == expectedObject,
                  let output = simulation.transferredObjectOutput,
                  output.objectID == expectedObject.objectID,
                  output.type == expectedObject.type,
                  output.version > expectedObject.version,
                  WalletSolanaBase58.decode(output.digest, exactLength: 32) != nil,
                  simulation.objectHasPublicTransfer == true,
                  simulation.amountBaseUnits == "1",
                  simulation.senderDebitBaseUnits == "0",
                  simulation.senderGasDebitBaseUnits == fee,
                  simulation.recipientCreditBaseUnits == "1" else {
                throw signerError(
                    "Sui object-transfer effects changed after preparation."
                )
            }
        default:
            throw signerError("The prepared Sui semantic action is unavailable.")
        }
        return intent
    }

    private func validatedSuiIntent(
        for recheck: WalletSuiRecheckPacket
    ) throws -> StoredSuiIntent {
        let intent = try validatedSuiIntent(for: recheck.simulation)
        let coinMatches: Bool
        if let expectedObject = intent.packet.coinObject,
           let expectedBalance = intent.packet.coinBalanceBaseUnits,
           let preparedCheckpoint = intent.packet.coinCheckpointSequence,
           let preparedTimestamp = intent.packet.coinCheckpointTimestamp {
            coinMatches = recheck.coinObject == expectedObject
                && recheck.coinBalanceBaseUnits == expectedBalance
                && recheck.coinCheckpointSequence.map { $0 >= preparedCheckpoint } == true
                && recheck.coinCheckpointTimestamp.map {
                    $0 >= preparedTimestamp
                        && $0 <= Date().addingTimeInterval(120)
                        && $0 >= Date().addingTimeInterval(-15 * 60)
                } == true
                && recheck.coinCheckpointSequence.map {
                    recheck.simulation.checkpointSequence >= $0
                } == true
                && recheck.coinCheckpointTimestamp.map {
                    recheck.simulation.checkpointTimestamp >= $0
                } == true
        } else {
            coinMatches = recheck.coinObject == nil
                && recheck.coinBalanceBaseUnits == nil
                && recheck.coinCheckpointSequence == nil
                && recheck.coinCheckpointTimestamp == nil
        }
        let objectMatches: Bool
        if let expectedObject = intent.packet.transferredObject,
           let preparedCheckpoint = intent.packet.objectCheckpointSequence,
           let preparedTimestamp = intent.packet.objectCheckpointTimestamp {
            objectMatches = recheck.transferredObject == expectedObject
                && recheck.objectHasPublicTransfer == true
                && recheck.objectCheckpointSequence.map {
                    $0 >= preparedCheckpoint
                } == true
                && recheck.objectCheckpointTimestamp.map {
                    $0 >= preparedTimestamp
                        && $0 <= Date().addingTimeInterval(120)
                        && $0 >= Date().addingTimeInterval(-15 * 60)
                } == true
                && recheck.objectCheckpointSequence.map {
                    recheck.simulation.checkpointSequence >= $0
                } == true
                && recheck.objectCheckpointTimestamp.map {
                    recheck.simulation.checkpointTimestamp >= $0
                } == true
        } else {
            objectMatches = recheck.transferredObject == nil
                && recheck.objectHasPublicTransfer == nil
                && recheck.objectCheckpointSequence == nil
                && recheck.objectCheckpointTimestamp == nil
        }
        guard coinMatches, objectMatches,
              recheck.gasObject == intent.packet.gasObject,
              recheck.gasBalanceBaseUnits == intent.packet.gasBalanceBaseUnits,
              recheck.gasCheckpointSequence >= intent.packet.checkpointSequence,
              recheck.gasCheckpointTimestamp >= intent.packet.checkpointTimestamp,
              recheck.gasCheckpointTimestamp <= Date().addingTimeInterval(120),
              recheck.gasCheckpointTimestamp >= Date().addingTimeInterval(-15 * 60),
              recheck.currentEpoch == intent.packet.currentEpoch,
              recheck.referenceGasPriceBaseUnits
                == intent.packet.referenceGasPriceBaseUnits,
              recheck.simulation.checkpointSequence
                >= recheck.gasCheckpointSequence,
              recheck.simulation.checkpointTimestamp
                >= recheck.gasCheckpointTimestamp else {
            throw signerError(
                "The selected Sui gas object changed version, digest, type, or balance."
            )
        }
        return intent
    }

    private func rechecked(
        _ prepared: WalletPreparedTransaction,
        using recheck: WalletEVMRecheckPacket
    ) -> WalletPreparedTransaction {
        WalletPreparedTransaction(
            id: prepared.id, digest: prepared.digest, networkID: prepared.networkID,
            accountID: prepared.accountID, source: prepared.source,
            action: prepared.action, summary: prepared.summary,
            effects: prepared.effects, riskFlags: prepared.riskFlags, contract: prepared.contract,
            adapterID: prepared.adapterID, budgetAssetID: prepared.budgetAssetID,
            spendBaseUnits: prepared.spendBaseUnits,
            maximumFeeBaseUnits: prepared.maximumFeeBaseUnits,
            feeQuoteBaseUnits: recheck.feeQuoteBaseUnits,
            simulation: recheck.simulation, simulationSucceeded: recheck.simulationSucceeded,
            nonce: prepared.nonce, createdAt: prepared.createdAt, expiresAt: prepared.expiresAt,
            policyDecision: prepared.policyDecision, policyID: prepared.policyID
        )
    }

    private func recheckedSolana(
        _ prepared: WalletPreparedTransaction,
        using recheck: WalletSolanaRecheckPacket
    ) -> WalletPreparedTransaction {
        WalletPreparedTransaction(
            id: prepared.id, digest: prepared.digest,
            networkID: prepared.networkID, accountID: prepared.accountID,
            source: prepared.source, action: prepared.action,
            summary: prepared.summary, effects: prepared.effects,
            riskFlags: prepared.riskFlags, contract: nil,
            adapterID: prepared.adapterID,
            budgetAssetID: prepared.budgetAssetID,
            spendBaseUnits: prepared.spendBaseUnits,
            maximumFeeBaseUnits: prepared.maximumFeeBaseUnits,
            feeQuoteBaseUnits: recheck.feeQuoteBaseUnits,
            simulation: recheck.simulation,
            simulationSucceeded: recheck.simulationSucceeded,
            nonce: prepared.nonce, createdAt: prepared.createdAt,
            expiresAt: prepared.expiresAt,
            policyDecision: prepared.policyDecision, policyID: prepared.policyID
        )
    }

    private func recheckedSui(
        _ prepared: WalletPreparedTransaction,
        using simulation: WalletSuiSimulationPacket
    ) -> WalletPreparedTransaction {
        WalletPreparedTransaction(
            id: prepared.id, digest: prepared.digest,
            networkID: prepared.networkID, accountID: prepared.accountID,
            source: prepared.source, action: prepared.action,
            summary: prepared.summary, effects: prepared.effects,
            riskFlags: prepared.riskFlags, contract: nil,
            adapterID: prepared.adapterID,
            budgetAssetID: prepared.budgetAssetID,
            spendBaseUnits: prepared.spendBaseUnits,
            maximumFeeBaseUnits: prepared.maximumFeeBaseUnits,
            feeQuoteBaseUnits: simulation.actualFeeBaseUnits,
            simulation: "Success · effects \(simulation.effectsDigest)",
            simulationSucceeded: true,
            nonce: prepared.nonce, createdAt: prepared.createdAt,
            expiresAt: prepared.expiresAt,
            policyDecision: prepared.policyDecision, policyID: prepared.policyID
        )
    }

    private func rustPrepare(
        transaction: WalletEVMTransactionFields,
        entropy: Data
    ) throws -> RustPreparedEVM {
        try rustTransactionCall(
            transaction: transaction, entropy: entropy, function: rustPrepareEVMTransaction
        )
    }

    private func rustSign(
        transaction: WalletEVMTransactionFields,
        entropy: Data
    ) throws -> RustSignedEVM {
        try rustTransactionCall(
            transaction: transaction, entropy: entropy, function: rustSignEVMTransaction
        )
    }

    private func rustPrepareSolana(
        packet: WalletSolanaPreparationPacket,
        entropy: Data
    ) throws -> RustPreparedSolana {
        switch packet.request.action.type {
        case .nativeTransfer:
            return try rustSolanaNativeCall(
                packet: packet, entropy: entropy,
                function: rustPrepareSolanaNativeTransfer
            )
        case .fungibleTokenTransfer:
            return try rustSolanaSPLCall(
                packet: packet, entropy: entropy,
                function: rustPrepareSolanaSPLTransfer
            )
        case .nftTransfer:
            return try rustSolanaCoreCall(
                packet: packet, entropy: entropy,
                function: rustPrepareSolanaCoreTransfer
            )
        default:
            throw signerError("The Solana signer adapter is unavailable.")
        }
    }

    private func rustSignSolana(
        packet: WalletSolanaPreparationPacket,
        entropy: Data
    ) throws -> RustSignedSolana {
        switch packet.request.action.type {
        case .nativeTransfer:
            return try rustSolanaNativeCall(
                packet: packet, entropy: entropy,
                function: rustSignSolanaNativeTransfer
            )
        case .fungibleTokenTransfer:
            return try rustSolanaSPLCall(
                packet: packet, entropy: entropy,
                function: rustSignSolanaSPLTransfer
            )
        case .nftTransfer:
            return try rustSolanaCoreCall(
                packet: packet, entropy: entropy,
                function: rustSignSolanaCoreTransfer
            )
        default:
            throw signerError("The Solana signer adapter is unavailable.")
        }
    }

    private func rustPrepareSui(
        packet: WalletSuiPreparationPacket,
        entropy: Data
    ) throws -> RustPreparedSui {
        switch packet.request.action.type {
        case .nativeTransfer:
            return try rustSuiNativeCall(
                packet: packet, entropy: entropy,
                function: rustPrepareSuiNativeTransfer
            )
        case .fungibleTokenTransfer:
            return try rustSuiCoinCall(
                packet: packet, entropy: entropy,
                function: rustPrepareSuiCoinTransfer
            )
        case .nftTransfer:
            return try rustSuiObjectCall(
                packet: packet, entropy: entropy,
                function: rustPrepareSuiObjectTransfer
            )
        default:
            throw signerError("The Sui signer adapter is unavailable.")
        }
    }

    private func rustSignSui(
        packet: WalletSuiPreparationPacket,
        entropy: Data
    ) throws -> RustSignedSui {
        switch packet.request.action.type {
        case .nativeTransfer:
            return try rustSuiNativeCall(
                packet: packet, entropy: entropy,
                function: rustSignSuiNativeTransfer
            )
        case .fungibleTokenTransfer:
            return try rustSuiCoinCall(
                packet: packet, entropy: entropy,
                function: rustSignSuiCoinTransfer
            )
        case .nftTransfer:
            return try rustSuiObjectCall(
                packet: packet, entropy: entropy,
                function: rustSignSuiObjectTransfer
            )
        default:
            throw signerError("The Sui signer adapter is unavailable.")
        }
    }

    private func rustSuiNativeCall<Result: Decodable>(
        packet: WalletSuiPreparationPacket,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> Result {
        guard let recipient = packet.request.action.recipient,
              let amount = packet.request.action.amountBaseUnits else {
            throw signerError("The semantic SUI transfer is incomplete.")
        }
        let request = RustSuiNativeTransfer(
            chainIdentifier: packet.chainIdentifier,
            sender: packet.sender, recipient: recipient,
            gasObjectID: packet.gasObject.objectID,
            gasObjectVersion: packet.gasObject.version,
            gasObjectDigest: packet.gasObject.digest,
            gasBalanceBaseUnits: packet.gasBalanceBaseUnits,
            amountBaseUnits: amount,
            referenceGasPriceBaseUnits: packet.referenceGasPriceBaseUnits,
            gasPriceBaseUnits: packet.gasPriceBaseUnits,
            gasBudgetBaseUnits: packet.gasBudgetBaseUnits,
            currentEpoch: packet.currentEpoch,
            expirationEpoch: packet.expirationEpoch
        )
        return try rustSuiEncodedCall(
            request: request, entropy: entropy, function: function
        )
    }

    private func rustSuiCoinCall<Result: Decodable>(
        packet: WalletSuiPreparationPacket,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> Result {
        guard let recipient = packet.request.action.recipient,
              let amount = packet.request.action.amountBaseUnits,
              let coinObject = packet.coinObject,
              let coinBalance = packet.coinBalanceBaseUnits else {
            throw signerError("The semantic Sui Coin transfer is incomplete.")
        }
        let request = RustSuiCoinTransfer(
            chainIdentifier: packet.chainIdentifier,
            sender: packet.sender, recipient: recipient,
            coinType: packet.coinType,
            coinObjectID: coinObject.objectID,
            coinObjectVersion: coinObject.version,
            coinObjectDigest: coinObject.digest,
            coinBalanceBaseUnits: coinBalance,
            gasObjectID: packet.gasObject.objectID,
            gasObjectVersion: packet.gasObject.version,
            gasObjectDigest: packet.gasObject.digest,
            gasBalanceBaseUnits: packet.gasBalanceBaseUnits,
            amountBaseUnits: amount,
            referenceGasPriceBaseUnits: packet.referenceGasPriceBaseUnits,
            gasPriceBaseUnits: packet.gasPriceBaseUnits,
            gasBudgetBaseUnits: packet.gasBudgetBaseUnits,
            currentEpoch: packet.currentEpoch,
            expirationEpoch: packet.expirationEpoch
        )
        return try rustSuiEncodedCall(
            request: request, entropy: entropy, function: function
        )
    }

    private func rustSuiObjectCall<Result: Decodable>(
        packet: WalletSuiPreparationPacket,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> Result {
        guard let recipient = packet.request.action.recipient,
              let object = packet.transferredObject,
              let hasPublicTransfer = packet.objectHasPublicTransfer else {
            throw signerError("The semantic Sui object transfer is incomplete.")
        }
        let request = RustSuiObjectTransfer(
            chainIdentifier: packet.chainIdentifier,
            sender: packet.sender, recipient: recipient,
            objectID: object.objectID, objectVersion: object.version,
            objectDigest: object.digest, objectType: object.type,
            hasPublicTransfer: hasPublicTransfer,
            gasObjectID: packet.gasObject.objectID,
            gasObjectVersion: packet.gasObject.version,
            gasObjectDigest: packet.gasObject.digest,
            gasBalanceBaseUnits: packet.gasBalanceBaseUnits,
            referenceGasPriceBaseUnits: packet.referenceGasPriceBaseUnits,
            gasPriceBaseUnits: packet.gasPriceBaseUnits,
            gasBudgetBaseUnits: packet.gasBudgetBaseUnits,
            currentEpoch: packet.currentEpoch,
            expirationEpoch: packet.expirationEpoch
        )
        return try rustSuiEncodedCall(
            request: request, entropy: entropy, function: function
        )
    }

    private func rustSuiEncodedCall<Request: Encodable, Result: Decodable>(
        request: Request,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> Result {
        var entropyHex = entropy.map { String(format: "%02x", $0) }.joined()
        defer {
            entropyHex.replaceSubrange(
                entropyHex.startIndex..<entropyHex.endIndex, with: ""
            )
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        guard var json = String(data: data, encoding: .utf8) else {
            throw signerError("The reviewed Sui transfer could not be encoded.")
        }
        defer { json.replaceSubrange(json.startIndex..<json.endIndex, with: "") }
        guard let pointer = entropyHex.withCString({ entropyPointer in
            json.withCString { jsonPointer in function(entropyPointer, jsonPointer) }
        }) else { throw signerError("The signing core is unavailable.") }
        defer { rustFreeString(pointer) }
        let result = Data(String(cString: pointer).utf8)
        if let failure = try? JSONDecoder().decode(
            WalletSignerErrorPayload.self, from: result
        ) {
            throw signerError(failure.error)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Result.self, from: result)
    }

    private func rustSolanaNativeCall<T: Decodable>(
        packet: WalletSolanaPreparationPacket,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        guard let recipient = packet.request.action.recipient,
              let amount = packet.request.action.amountBaseUnits else {
            throw signerError("The semantic SOL transfer is incomplete.")
        }
        let request = RustSolanaNativeTransfer(
            feePayer: packet.feePayer, recipient: recipient,
            recentBlockhash: packet.recentBlockhash,
            amountBaseUnits: amount,
            computeUnitLimit: packet.computeUnitLimit,
            computeUnitPriceMicroLamports:
                packet.computeUnitPriceMicroLamports
        )
        return try rustSolanaCall(
            request: request, entropy: entropy, function: function
        )
    }

    private func rustSolanaSPLCall<T: Decodable>(
        packet: WalletSolanaPreparationPacket,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        guard let recipient = packet.request.action.recipient,
              let amount = packet.request.action.amountBaseUnits,
              let assetID = packet.request.action.assetID,
              let identity = WalletSolanaAssetIdentity.parse(assetID),
              identity.networkID == packet.request.networkID,
              (1...2).contains(packet.instructions.count),
              let arguments = packet.instructions.last?.canonicalArguments,
              let source = arguments["source_token_account"],
              let mint = arguments["mint"],
              let destination = arguments["destination_token_account"],
              let decimalsText = arguments["decimals"],
              let decimals = UInt8(decimalsText) else {
            throw signerError("The semantic SPL transfer is incomplete.")
        }
        let request = RustSolanaSPLTransfer(
            feePayer: packet.feePayer, sourceTokenAccount: source,
            mint: mint, destinationTokenAccount: destination,
            recipientOwner: recipient,
            tokenProgramID: identity.program.programID,
            associatedTokenProgramID: Self.solanaAssociatedTokenProgramID,
            createDestinationAssociatedAccount: packet.instructions.count == 2,
            recentBlockhash: packet.recentBlockhash,
            amountBaseUnits: amount, decimals: decimals,
            computeUnitLimit: packet.computeUnitLimit,
            computeUnitPriceMicroLamports:
                packet.computeUnitPriceMicroLamports
        )
        return try rustSolanaCall(
            request: request, entropy: entropy, function: function
        )
    }

    private func rustSolanaCoreCall<T: Decodable>(
        packet: WalletSolanaPreparationPacket,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        guard let recipient = packet.request.action.recipient,
              let assetID = packet.request.action.assetID,
              let identity = WalletSolanaCollectibleIdentity.parse(assetID),
              identity.networkID == packet.request.networkID,
              identity.standard == .core else {
            throw signerError("The semantic Core transfer is incomplete.")
        }
        let request = RustSolanaCoreTransfer(
            feePayer: packet.feePayer, asset: identity.address,
            recipient: recipient, recentBlockhash: packet.recentBlockhash,
            computeUnitLimit: packet.computeUnitLimit,
            computeUnitPriceMicroLamports:
                packet.computeUnitPriceMicroLamports
        )
        return try rustSolanaCall(
            request: request, entropy: entropy, function: function
        )
    }

    private func rustAssociatedTokenAddress(
        owner: String,
        mint: String,
        tokenProgramID: String
    ) throws -> RustSolanaAssociatedTokenAddress {
        let request = RustSolanaAssociatedTokenRequest(
            owner: owner, mint: mint, tokenProgramID: tokenProgramID
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        guard var json = String(data: data, encoding: .utf8) else {
            throw signerError("The associated-token request could not be encoded.")
        }
        defer { json.replaceSubrange(json.startIndex..<json.endIndex, with: "") }
        guard let pointer = json.withCString({ rustDeriveSolanaAssociatedToken($0) })
        else { throw signerError("The signing core is unavailable.") }
        defer { rustFreeString(pointer) }
        let result = Data(String(cString: pointer).utf8)
        if let failure = try? JSONDecoder().decode(
            WalletSignerErrorPayload.self, from: result
        ) {
            throw signerError(failure.error)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RustSolanaAssociatedTokenAddress.self, from: result)
    }

    private func rustSolanaCall<Request: Encodable, Result: Decodable>(
        request: Request,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> Result {
        var entropyHex = entropy.map { String(format: "%02x", $0) }.joined()
        defer {
            entropyHex.replaceSubrange(
                entropyHex.startIndex..<entropyHex.endIndex, with: ""
            )
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        guard var json = String(data: data, encoding: .utf8) else {
            throw signerError("The reviewed Solana transfer could not be encoded.")
        }
        defer { json.replaceSubrange(json.startIndex..<json.endIndex, with: "") }
        guard let pointer = entropyHex.withCString({ entropyPointer in
            json.withCString { jsonPointer in function(entropyPointer, jsonPointer) }
        }) else { throw signerError("The signing core is unavailable.") }
        defer { rustFreeString(pointer) }
        let result = Data(String(cString: pointer).utf8)
        if let failure = try? JSONDecoder().decode(
            WalletSignerErrorPayload.self, from: result
        ) {
            throw signerError(failure.error)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Result.self, from: result)
    }

    private func rustTransactionCall<T: Decodable>(
        transaction: WalletEVMTransactionFields,
        entropy: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        var entropyHex = entropy.map { String(format: "%02x", $0) }.joined()
        defer { entropyHex.replaceSubrange(entropyHex.startIndex..<entropyHex.endIndex, with: "") }
        let rustTransaction = RustEVMTransaction(
            chainID: transaction.chainID, nonce: transaction.nonce,
            gasLimit: transaction.gasLimit, maxFeePerGas: transaction.maxFeePerGas,
            maxPriorityFeePerGas: transaction.maxPriorityFeePerGas,
            to: transaction.to, value: transaction.value, input: transaction.input
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(rustTransaction)
        guard var json = String(data: data, encoding: .utf8) else {
            throw signerError("The transaction could not be encoded.")
        }
        defer { json.replaceSubrange(json.startIndex..<json.endIndex, with: "") }
        guard let pointer = entropyHex.withCString({ entropyPointer in
            json.withCString { jsonPointer in function(entropyPointer, jsonPointer) }
        }) else { throw signerError("The signing core is unavailable.") }
        defer { rustFreeString(pointer) }
        let result = Data(String(cString: pointer).utf8)
        if let failure = try? JSONDecoder().decode(WalletSignerErrorPayload.self, from: result) {
            throw signerError(failure.error)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: result)
    }

    private func evmAddress() throws -> String {
        guard let address = try store.accounts().first(where: { $0.chain == .evm })?.address else {
            throw signerError("The EVM account is missing.")
        }
        return address
    }

    private func solanaAddress() throws -> String {
        guard let address = try store.accounts().first(
            where: { $0.chain == .solana }
        )?.address else {
            throw signerError("The Solana account is missing.")
        }
        return address
    }

    private func signerError(_ message: String) -> NSError {
        NSError(domain: "WalletSigner", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func authorized<Payload: Codable & Equatable & Sendable>(
        _ request: Data
    ) throws -> WalletAuthorizedRequest<Payload> {
        let authorized = try JSONDecoder().decode(WalletAuthorizedRequest<Payload>.self, from: request)
        guard authorized.protocolVersion == Self.protocolVersion,
              let activeSessionID,
              unlockedEntropy != nil,
              authorized.sessionID == activeSessionID,
              validSource(authorized.source) else {
            throw signerError("The wallet session is missing, stale, or belongs to another client.")
        }
        return authorized
    }

    private func authorizedSession(_ request: Data) throws -> WalletSessionRequest {
        let authorized = try JSONDecoder().decode(WalletSessionRequest.self, from: request)
        guard authorized.protocolVersion == Self.protocolVersion,
              let activeSessionID,
              unlockedEntropy != nil,
              authorized.sessionID == activeSessionID,
              validSource(authorized.source) else {
            throw signerError("The wallet session is missing, stale, or belongs to another client.")
        }
        return authorized
    }

    private func validSource(_ source: WalletRequestSource) -> Bool {
        switch source.kind {
        case .agent:
            return source.origin == nil && source.peerID == nil
        case .humanUI:
            return source.origin == nil && source.peerID == nil
        case .browser, .embeddedBrowser:
            guard let origin = source.origin,
                  let components = URLComponents(string: origin),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = components.host?.lowercased(), !host.isEmpty,
                  components.path.isEmpty, components.query == nil, components.fragment == nil else {
                return false
            }
            let standardPort = (scheme == "https" && components.port == 443)
                || (scheme == "http" && components.port == 80)
            let port = components.port.map { standardPort ? "" : ":\($0)" } ?? ""
            return origin == "\(scheme)://\(host)\(port)"
        case .walletConnectPeer:
            guard let peerID = source.peerID,
                  !peerID.isEmpty, peerID.utf8.count <= 512 else { return false }
            return source.origin.map { $0.utf8.count <= 2_048 } ?? true
        }
    }

    private func lockInMemory() {
        if var entropy = unlockedEntropy { entropy.resetBytes(in: 0..<entropy.count) }
        unlockedEntropy = nil
        activeSessionID = nil
        preparedIntents.removeAll(keepingCapacity: false)
        preparedSolanaIntents.removeAll(keepingCapacity: false)
        preparedSuiIntents.removeAll(keepingCapacity: false)
        activePolicies.removeAll(keepingCapacity: false)
        pendingPresenceIntents.removeAll(keepingCapacity: false)
        policyPresencePending = false
    }

    private func reserveCanaryBudget(for transaction: WalletPreparedTransaction) throws {
        guard let network = WalletNetworkCatalog.descriptor(id: transaction.networkID)
        else { throw WalletReleaseActivationError.malformed }
        try authorizeNetwork(transaction.networkID, chain: network.chain,
            capability: capability(for: transaction.action.type))
        try WalletCanaryBudget.reserve(transaction: transaction, ownership: .locusVault,
            connector: nil, manifest: verifiedReleaseAuthority?.budgetManifest(),
            sourceRevision: verifiedReleaseAuthority?.checkpoint.signedTransition.envelope.candidateID ?? "",
            signerOwned: true, enforcePermanentLimits: true)
    }

    private func requireCurrentActivation() throws {
        guard let activeActivationDigest,
              let authority = verifiedReleaseAuthority,
              let accepted = try WalletSignerReleaseAuthorityStore.load(),
              accepted == authority.checkpoint,
              accepted.digest == activeActivationDigest,
              accepted.signedTransition.envelope.expiresAt > Date(),
              accepted.revision == launchGate?.effectiveManifest?.revision else {
            clearActivationBoundAuthority()
            launchGate = nil
            throw WalletReleaseActivationError.rollback
        }
        try authority.requireAdmission(installationID: WalletSignerReleaseAuthorityStore.installationID())
    }

    private func clearActivationBoundAuthority() {
        // Invalidate callbacks awaiting user presence before replacing grants.
        // A callback may only resume the same authenticated signing session.
        activeSessionID = nil
        if var entropy = unlockedEntropy { entropy.resetBytes(in: 0..<entropy.count) }
        unlockedEntropy = nil
        preparedIntents.removeAll(keepingCapacity: false)
        preparedSolanaIntents.removeAll(keepingCapacity: false)
        preparedSuiIntents.removeAll(keepingCapacity: false)
        activePolicies.removeAll(keepingCapacity: false)
        pendingPresenceIntents.removeAll(keepingCapacity: false)
        policyPresencePending = false
    }

    private func clearPending() {
        if var entropy = pendingEntropy { entropy.resetBytes(in: 0..<entropy.count) }
        pendingEntropy = nil
        pendingWords.removeAll(keepingCapacity: false)
        pendingIndices.removeAll(keepingCapacity: false)
        pendingPurpose = .create
    }

    private func clearRecoveryCeremony() {
        clearPending()
        recoveryCeremony?.listener.invalidate()
        recoveryCeremony = nil
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? error("The signer could not encode its response.")
    }

    private func error(_ message: String) -> Data {
        (try? JSONEncoder().encode(WalletSignerErrorPayload(error: message))) ?? Data()
    }
}

private final class WalletRecoveryBroker: NSObject, WalletRecoveryBrokerXPCProtocol {
    private weak var owner: WalletSignerService?
    private let ceremonyID: String

    init(owner: WalletSignerService, ceremonyID: String) {
        self.owner = owner
        self.ceremonyID = ceremonyID
    }

    func creationMaterial(_ ceremonyID: String, reply: @escaping (Data) -> Void) {
        guard ceremonyID == self.ceremonyID, let owner else {
            return reply(Self.error("The one-time recovery channel is stale."))
        }
        owner.recoveryCreationMaterial(ceremonyID: ceremonyID, reply: reply)
    }

    func confirmBackup(
        _ ceremonyID: String, confirmation: Data, reply: @escaping (Data) -> Void
    ) {
        guard ceremonyID == self.ceremonyID, let owner else {
            return reply(Self.error("The one-time recovery channel is stale."))
        }
        owner.recoveryConfirmBackup(
            ceremonyID: ceremonyID, confirmationData: confirmation, reply: reply
        )
    }

    func restoreVault(
        _ ceremonyID: String, request: Data, reply: @escaping (Data) -> Void
    ) {
        guard ceremonyID == self.ceremonyID, let owner else {
            return reply(Self.error("The one-time recovery channel is stale."))
        }
        owner.recoveryRestore(ceremonyID: ceremonyID, requestData: request, reply: reply)
    }

    func cancel(_ ceremonyID: String, reply: @escaping (Data) -> Void) {
        guard ceremonyID == self.ceremonyID, let owner else {
            return reply(Self.error("The one-time recovery channel is stale."))
        }
        owner.recoveryCancel(ceremonyID: ceremonyID, reply: reply)
    }

    private static func error(_ message: String) -> Data {
        (try? JSONEncoder().encode(WalletSignerErrorPayload(error: message))) ?? Data()
    }
}

private final class WalletRecoveryBrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private weak var owner: WalletSignerService?
    private let ceremonyID: String
    private let lock = NSLock()
    private var acceptedConnection = false

    init(owner: WalletSignerService, ceremonyID: String) {
        self.owner = owner
        self.ceremonyID = ceremonyID
    }

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !acceptedConnection, let owner else {
            return false
        }
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.recoveryApplication)
        acceptedConnection = true
        let broker = WalletRecoveryBroker(owner: owner, ceremonyID: ceremonyID)
        connection.exportedInterface = NSXPCInterface(with: WalletRecoveryBrokerXPCProtocol.self)
        connection.exportedObject = broker
        connection.interruptionHandler = { [weak owner] in
            owner?.recoveryConnectionEnded(ceremonyID: self.ceremonyID)
        }
        connection.invalidationHandler = { [weak owner] in
            owner?.recoveryConnectionEnded(ceremonyID: self.ceremonyID)
        }
        connection.resume()
        return true
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
