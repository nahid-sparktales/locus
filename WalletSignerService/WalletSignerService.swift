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

@_silgen_name("locus_wallet_encode_contract_call_json")
private func rustEncodeContractCall(_ requestJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_string_free")
private func rustFreeString(_ value: UnsafeMutablePointer<CChar>)

private struct RustGeneratedVault: Decodable {
    let entropyHex: String
    let words: [String]
}

private struct RustAccounts: Decodable {
    let accounts: [WalletAccount]
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

private struct StoredEVMIntent {
    let transaction: WalletEVMTransactionFields
    var prepared: WalletPreparedTransaction
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

    static func lessThanOrEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let comparison = compare(lhs, rhs) else { return false }
        return comparison != .orderedDescending
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

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessError
        ) else { throw StoreError.authentication }

        SecItemDelete(productionQuery() as CFDictionary)
        var query = productionQuery()
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessControl as String] = access
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
        var query = productionQuery()
        let context = LAContext()
        context.localizedReason = reason
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
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
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class WalletSignerService: NSObject, WalletSignerXPCProtocol {
    private static let protocolVersion = 2
    private static let maximumPreparedIntents = 32
    private static let maximumActivePolicies = 32
    private let queue = DispatchQueue(label: "io.sparktales.locus.wallet-signer")
    private let store = WalletVaultStore()
    private let launchGate: WalletLaunchGate?
    private let regionCode: String
    private var pendingEntropy: Data?
    private var pendingWords: [String] = []
    private var pendingIndices: [Int] = []
    private var pendingPurpose: WalletVaultCreationPurpose = .create
    private var unlockedEntropy: Data?
    private var activeSessionID: String?
    private var preparedIntents: [String: StoredEVMIntent] = [:]
    private var activePolicies: [String: SignerActivePolicy] = [:]
    private var pendingPresenceIntents: Set<String> = []
    private var policyPresencePending = false
    private var recoveryCeremony: WalletRecoveryCeremonyContext?

    override init() {
        launchGate = Self.loadLaunchGate()
        regionCode = (Locale.current.region?.identifier ?? "ZZ").uppercased()
        super.init()
    }

    func invalidateConnection() {
        queue.async {
            self.lockInMemory()
            self.clearPending()
        }
    }

    func status(reply: @escaping (Data) -> Void) {
        queue.async { reply(self.encoded(self.currentStatus())) }
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
                switch ceremony.mode {
                case .create, .restore:
                    guard !self.store.exists, !self.store.legacyExists else {
                        return reply(self.error("A Locus Vault already exists."), nil)
                    }
                case .rotateForMainnet:
                    guard self.store.legacyExists, !self.store.exists else {
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
            self.clearPending()
            self.lockInMemory()
            self.recoveryCeremony?.listener.invalidate()
            self.recoveryCeremony = nil
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
                guard authorized.source == .agent else {
                    throw self.signerError("Browser requests cannot register or encode contract calls.")
                }
                reply(self.encoded(try self.authoritativeContractEncoding(authorized.payload)))
            } catch {
                reply(self.error("Contract encoding failed: \(error.localizedDescription)"))
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
                case .contractCall:
                    intent = try self.prepareContractCall(packet: packet, entropy: entropy)
                case .fungibleTokenTransfer, .nftTransfer, .exactInputSwap, .reviewedCall,
                     .standardizedSignIn, .reviewedTypedAuthorization:
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
                throw self.signerError("The reviewed Solana transaction builder is not active in this build.")
            } catch {
                reply(self.error("Solana preparation failed: \(error.localizedDescription)"))
            }
        }
    }

    func simulateSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(error("Solana simulation failed: no reviewed Solana intent is active."))
    }

    func confirmSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(error("Solana confirmation failed: no reviewed Solana intent is active."))
    }

    func executeSolana(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(error("Solana execution failed: no reviewed Solana intent is active."))
    }

    func prepareSui(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let authorized: WalletAuthorizedRequest<WalletSuiPreparationPacket> =
                    try self.authorized(request)
                let packet = authorized.payload
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
                throw self.signerError("The reviewed Sui transaction builder is not active in this build.")
            } catch {
                reply(self.error("Sui preparation failed: \(error.localizedDescription)"))
            }
        }
    }

    func simulateSui(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(error("Sui simulation failed: no reviewed Sui intent is active."))
    }

    func confirmSui(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(error("Sui confirmation failed: no reviewed Sui intent is active."))
    }

    func executeSui(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(error("Sui execution failed: no reviewed Sui intent is active."))
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
                      confirmation.wordsByIndex.count == 6,
                      Set(confirmation.wordsByIndex.keys) == Set(self.pendingIndices),
                      confirmation.wordsByIndex.allSatisfy({ index, word in
                          self.pendingWords[index].caseInsensitiveCompare(
                              word.trimmingCharacters(in: .whitespacesAndNewlines)
                          ) == .orderedSame
                      }) else {
                    return reply(self.error("The six recovery words did not match."))
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RustAccounts.self, from: data).accounts
    }

    private func prepareNativeTransfer(
        packet: WalletEVMPreparationPacket,
        entropy: Data
    ) throws -> StoredEVMIntent {
        try authorizeNetwork(
            packet.request.networkID, capability: .nativeTransfer
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
            riskFlags: [], contract: nil, adapterID: "native-eth-transfer-v1",
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

    private func prepareContractCall(
        packet: WalletEVMPreparationPacket,
        entropy: Data
    ) throws -> StoredEVMIntent {
        guard let expectedChainID = Self.evmChainID(for: packet.request.networkID),
              packet.transaction.chainID == expectedChainID,
              packet.request.action.type == .contractCall,
              packet.request.action.recipient == nil,
              packet.request.action.amountBaseUnits == nil,
              let entry = packet.contractRegistryEntry,
              let encoded = packet.encodedContractCall,
              let observedCodeHash = packet.observedRuntimeCodeHash,
              entry.networkID == packet.request.networkID,
              packet.request.action.contractID == entry.id,
              packet.transaction.to.caseInsensitiveCompare(entry.checksumAddress) == .orderedSame,
              observedCodeHash.caseInsensitiveCompare(entry.runtimeCodeHash) == .orderedSame,
              let nativeValue = packet.request.action.valueBaseUnits.flatMap(
                  SignerUnsignedInteger.normalize
              ),
              SignerUnsignedInteger.normalize(packet.transaction.value) == nativeValue,
              packet.transaction.gasLimit > 0,
              packet.simulationSucceeded,
              abs(packet.observedAt.timeIntervalSinceNow) <= 30 else {
            throw signerError("The RPC evidence does not match a fresh registered network call.")
        }
        let capability: WalletNetworkCapability = switch WalletReviewedAdapters.validatedID(for: entry) {
        case WalletReviewedAdapters.erc20: .fungibleTokenTransfer
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn: .exactInputSwap
        default: .reviewedCall
        }
        try authorizeNetwork(packet.request.networkID, capability: capability)
        let encodingRequest = WalletContractEncodingRequest(
            action: packet.request.action, registryEntry: entry
        )
        let authoritative = try authoritativeContractEncoding(encodingRequest)
        guard authoritative == encoded,
              authoritative.input.caseInsensitiveCompare(packet.transaction.input) == .orderedSame else {
            throw signerError("The transaction calldata does not match signer ABI encoding.")
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
            throw signerError("The account or fee evidence does not match the registered call.")
        }
        let rust = try rustPrepare(transaction: packet.transaction, entropy: entropy)
        guard rust.from.caseInsensitiveCompare(account.address) == .orderedSame else {
            throw signerError("The vault derivation does not match the requested account.")
        }
        let now = Date()
        let intentID = UUID().uuidString.lowercased()
        let decoded = decodedContractEffects(
            intentID: intentID, action: packet.request.action,
            entry: entry, account: account, nativeValue: nativeValue
        )
        let identity = WalletContractIdentity(
            registryID: entry.id, address: entry.checksumAddress, label: entry.label,
            function: packet.request.action.function ?? "", abiDigest: entry.abiDigest,
            runtimeCodeHash: entry.runtimeCodeHash
        )
        var prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.digest, networkID: packet.request.networkID,
            accountID: packet.request.accountID, source: packet.request.source,
            action: packet.request.action,
            summary: "Call \(entry.label).\(packet.request.action.function ?? "unknown") on \(packet.request.networkID)",
            effects: decoded.effects, riskFlags: decoded.riskFlags, contract: identity,
            adapterID: decoded.adapterID, budgetAssetID: decoded.budgetAssetID,
            spendBaseUnits: decoded.spendBaseUnits,
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

    private func authoritativeContractEncoding(
        _ request: WalletContractEncodingRequest
    ) throws -> WalletEncodedContractCall {
        let action = request.action
        let entry = request.registryEntry
        guard action.type == .contractCall,
              Self.evmChainID(for: entry.networkID) != nil,
              Self.isEVMAddress(entry.checksumAddress),
              entry.runtimeCodeHash.count == 66,
              entry.runtimeCodeHash.hasPrefix("0x"),
              entry.runtimeCodeHash.dropFirst(2).allSatisfy(\.isHexDigit),
              action.contractID == entry.id,
              let function = action.function,
              entry.permittedFunctions.contains(function),
              action.arguments.count <= 64,
              entry.normalizedABI.utf8.count <= 256 * 1024,
              let abiData = entry.normalizedABI.data(using: .utf8) else {
            throw signerError("The semantic call is outside the registered ABI boundary.")
        }
        let digest = "sha256:" + SHA256.hash(data: abiData)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == entry.abiDigest else {
            throw signerError("The registered ABI digest does not match its normalized ABI.")
        }
        let rustRequest = RustContractCallRequest(
            normalizedABI: entry.normalizedABI, function: function, arguments: action.arguments
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
        if action.function == "transfer(address,uint256)", action.arguments.count == 2,
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
        } else if reviewedAdapterID == WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
                  let swap = WalletUniversalRouterV2Adapter.decode(
                    action: action, accountAddress: account.address,
                    networkID: entry.networkID
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
            adapterID = WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn
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
                id: "\(intentID):native-value", kind: "native_value", assetID: "slip44:60",
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

    private func validatePolicy(_ policy: WalletSessionPolicy) throws {
        try authorizeNetwork(policy.networkID, capability: .autonomousPolicy)
        let accounts = try store.accounts()
        guard !policy.id.isEmpty, policy.id.count <= 128,
              Self.evmChainID(for: policy.networkID) != nil,
              accounts.contains(where: {
                  $0.id == policy.accountID && $0.chain == .evm
                      && $0.networkIDs.contains(policy.networkID)
              }),
              policy.expiresAt > Date(),
              policy.expiresAt <= Date().addingTimeInterval(8 * 60 * 60),
              !policy.allowedRecipients.isEmpty,
              policy.allowedRecipients.count <= 32,
              policy.allowedRecipients.allSatisfy(Self.isEVMAddress),
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
                "Wallet policies require one reviewed adapter and asset, explicit EVM counterparties, bounded base-unit budgets, and an expiry within eight hours."
            )
        }
        let adapterID = policy.allowedAdapterIDs.first!
        let nativePolicy = adapterID == "native-eth-transfer-v1"
            && policy.allowedAssetIDs == ["\(policy.networkID)/slip44:60"]
            && policy.allowedContractIDs.isEmpty
        let contractPolicy = [
            WalletReviewedAdapters.erc20,
            WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
        ].contains(adapterID)
            && policy.allowedContractIDs.count == 1
            && policy.allowedAssetIDs.allSatisfy {
                Self.isERC20AssetID($0, networkID: policy.networkID)
            }
        guard nativePolicy || contractPolicy else {
            throw signerError("The policy does not match a supported reviewed adapter shape.")
        }
    }

    private func validAutomaticPolicyID(for transaction: WalletPreparedTransaction) throws -> String {
        expirePolicies()
        guard transaction.source.kind == .agent,
              let adapterID = transaction.adapterID,
              ["native-eth-transfer-v1", WalletReviewedAdapters.erc20,
               WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn].contains(adapterID),
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
                  contractMatches,
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
        case "native-eth-transfer-v1":
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
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn:
            guard transaction.action.arguments.count == 3,
                  let deadline = UInt64(transaction.action.arguments[2].value),
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
    }

    private func policyStatuses() -> [WalletActivePolicyStatus] {
        activePolicies.values.map(\.status).sorted { $0.policy.expiresAt < $1.policy.expiresAt }
    }

    private static func isEVMAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
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
        case .exactInputSwap: .exactInputSwap
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
        guard let launchGate else {
            throw signerError(
                "Mainnet signing is disabled because no valid signed capability manifest is bundled."
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
    private static let recoveryBundleIdentifier = "io.sparktales.locus.WalletRecovery"
    private static let teamIdentifier = "4X4RJA7GMD"
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
        guard !acceptedConnection, let owner, Self.isTrustedRecoveryService(connection) else {
            return false
        }
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

    private static func isTrustedRecoveryService(_ connection: NSXPCConnection) -> Bool {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier),
        ] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              information[kSecCodeInfoIdentifier as String] as? String
                == recoveryBundleIdentifier else { return false }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        #if DEBUG
        return team == nil || team == teamIdentifier
        #else
        return team == teamIdentifier
        #endif
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
