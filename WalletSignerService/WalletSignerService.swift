import CryptoKit
import Foundation
import LocalAuthentication
import Security

@_silgen_name("locus_wallet_generate_vault_json")
private func rustGenerateVault() -> UnsafeMutablePointer<CChar>?

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

private enum SignerUnsignedInteger {
    static func normalize(_ value: String) -> String? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
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

    private let service = "io.sparktales.locus.WalletSigner.wrap.v1"
    private let account = "locus-vault"
    private let fileManager = FileManager.default

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LocusWalletSigner", isDirectory: true)
    }

    var vaultURL: URL { directory.appendingPathComponent("vault-v1.aesgcm") }
    var accountsURL: URL { directory.appendingPathComponent("accounts-v1.json") }
    var exists: Bool { fileManager.fileExists(atPath: vaultURL.path) }

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

        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
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
            SecItemDelete(baseQuery() as CFDictionary)
            try? fileManager.removeItem(at: vaultURL)
            try? fileManager.removeItem(at: accountsURL)
            throw error
        }
    }

    func decrypt(reason: String) throws -> Data {
        var query = baseQuery()
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
        guard fileManager.fileExists(atPath: accountsURL.path) else { return [] }
        return try JSONDecoder().decode([WalletAccount].self, from: Data(contentsOf: accountsURL))
    }

    func delete(reason: String) throws {
        var key = try decrypt(reason: reason)
        key.resetBytes(in: 0..<key.count)
        try? fileManager.removeItem(at: vaultURL)
        try? fileManager.removeItem(at: accountsURL)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class WalletSignerService: NSObject, WalletSignerXPCProtocol {
    private let queue = DispatchQueue(label: "io.sparktales.locus.wallet-signer")
    private let store = WalletVaultStore()
    private var pendingEntropy: Data?
    private var pendingWords: [String] = []
    private var pendingIndices: [Int] = []
    private var unlockedEntropy: Data?
    private var activeSessionID: String?
    private var preparedIntents: [String: StoredEVMIntent] = [:]
    private var activePolicies: [String: SignerActivePolicy] = [:]

    func status(reply: @escaping (Data) -> Void) {
        queue.async { reply(self.encoded(self.currentStatus())) }
    }

    func beginCreateVault(reply: @escaping (Data) -> Void) {
        queue.async {
            guard !self.store.exists else {
                return reply(self.error("A Locus Vault already exists."))
            }
            if self.pendingEntropy != nil {
                return reply(self.encoded(WalletVaultCreation(
                    words: self.pendingWords,
                    verificationIndices: self.pendingIndices
                )))
            }
            guard let pointer = rustGenerateVault() else {
                return reply(self.error("The signing core did not generate a vault."))
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
                    return reply(self.error("The signing core returned invalid BIP-39 material."))
                }
                self.pendingEntropy = entropy
                self.pendingWords = generated.words
                self.pendingIndices = Array(0..<24).shuffled().prefix(6).sorted()
                reply(self.encoded(WalletVaultCreation(
                    words: generated.words,
                    verificationIndices: self.pendingIndices
                )))
            } catch {
                reply(self.error("Vault generation failed: \(error.localizedDescription)"))
            }
        }
    }

    func confirmBackup(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let confirmation = try JSONDecoder().decode(WalletBackupConfirmation.self, from: request)
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
                reply(self.encoded(self.currentStatus()))
            } catch {
                reply(self.error("Vault activation failed: \(error.localizedDescription)"))
            }
        }
    }

    func cancelCreateVault(reply: @escaping (Data) -> Void) {
        queue.async {
            self.clearPending()
            reply(self.encoded(self.currentStatus()))
        }
    }

    func authorizeSession(_ reason: String, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
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
            guard self.unlockedEntropy != nil else {
                return reply(self.error("Locus Vault is locked."))
            }
            do {
                let request = try JSONDecoder().decode(WalletContractEncodingRequest.self, from: request)
                reply(self.encoded(try self.authoritativeContractEncoding(request)))
            } catch {
                reply(self.error("Contract encoding failed: \(error.localizedDescription)"))
            }
        }
    }

    func prepareEVM(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            guard let entropy = self.unlockedEntropy else {
                return reply(self.error("Locus Vault is locked."))
            }
            do {
                let packet = try JSONDecoder().decode(WalletEVMPreparationPacket.self, from: request)
                let intent: StoredEVMIntent
                switch packet.request.action.type {
                case .nativeTransfer:
                    intent = try self.prepareNativeTransfer(packet: packet, entropy: entropy)
                case .contractCall:
                    intent = try self.prepareContractCall(packet: packet, entropy: entropy)
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
                let recheck = try JSONDecoder().decode(WalletEVMRecheckPacket.self, from: request)
                var intent = try self.validatedIntent(for: recheck)
                intent.prepared = self.rechecked(intent.prepared, using: recheck)
                self.preparedIntents[recheck.intentID] = intent
                reply(self.encoded(intent.prepared))
            } catch {
                reply(self.error("Transaction recheck failed: \(error.localizedDescription)"))
            }
        }
    }

    func confirmEVM(_ intentID: String, reply: @escaping (Data) -> Void) {
        queue.async {
            guard var intent = self.preparedIntents[intentID],
                  intent.prepared.expiresAt > Date() else {
                return reply(self.error("The prepared transaction is missing or expired."))
            }
            intent.explicitlyApproved = true
            self.preparedIntents[intentID] = intent
            reply(self.encoded(intent.prepared))
        }
    }

    func executeEVM(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            guard let entropy = self.unlockedEntropy else {
                return reply(self.error("Locus Vault is locked."))
            }
            do {
                let recheck = try JSONDecoder().decode(WalletEVMRecheckPacket.self, from: request)
                let validated = try self.validatedIntent(for: recheck)
                let automaticPolicyID: String?
                if validated.explicitlyApproved {
                    automaticPolicyID = nil
                } else {
                    automaticPolicyID = try self.validAutomaticPolicyID(for: validated.prepared)
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

    func activatePolicy(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            guard self.unlockedEntropy != nil else {
                return reply(self.error("Locus Vault is locked."))
            }
            do {
                let policy = try JSONDecoder().decode(WalletSessionPolicy.self, from: request)
                try self.validatePolicy(policy)
                self.activePolicies[policy.id] = SignerActivePolicy(
                    policy: policy, spentBaseUnits: "0"
                )
                reply(self.encoded(self.policyStatuses()))
            } catch {
                reply(self.error("Policy activation failed: \(error.localizedDescription)"))
            }
        }
    }

    func listPolicies(reply: @escaping (Data) -> Void) {
        queue.async {
            self.expirePolicies()
            reply(self.encoded(self.policyStatuses()))
        }
    }

    func clearPolicies(reply: @escaping (Data) -> Void) {
        queue.async {
            self.activePolicies.removeAll(keepingCapacity: false)
            reply(self.encoded([WalletActivePolicyStatus]()))
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

    private func currentStatus() -> WalletSignerStatus {
        let state: WalletVaultState
        if activeSessionID != nil { state = .unlocked }
        else if pendingEntropy != nil { state = .awaitingBackup }
        else { state = store.exists ? .locked : .missing }
        return WalletSignerStatus(
            protocolVersion: 1,
            vaultState: state,
            sessionID: activeSessionID,
            accounts: (try? store.accounts()) ?? []
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
        guard packet.request.networkID == "eip155:11155111",
              packet.transaction.chainID == 11_155_111,
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
            throw signerError("The RPC evidence does not match a fresh Sepolia native transfer.")
        }
        let account = try store.accounts().first {
            $0.id == packet.request.accountID && $0.chain == .evm
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
            action: packet.request.action,
            summary: "Send \(amount) wei on Sepolia to \(recipient)",
            effects: [WalletDecodedEffect(
                id: "\(intentID):eth-debit", kind: "debit", assetID: "slip44:60",
                amountBaseUnits: amount, from: account.address, to: recipient, spender: nil
            )],
            riskFlags: [], contract: nil, adapterID: "native-eth-transfer-v1",
            budgetAssetID: "slip44:60", spendBaseUnits: amount,
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee, simulation: packet.simulation,
            simulationSucceeded: true, nonce: String(packet.transaction.nonce),
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        if let policyID = try? validAutomaticPolicyID(for: prepared) {
            prepared.policyDecision = "allowed_by_session_policy"
            prepared.policyID = policyID
        }
        return StoredEVMIntent(transaction: packet.transaction, prepared: prepared)
    }

    private func prepareContractCall(
        packet: WalletEVMPreparationPacket,
        entropy: Data
    ) throws -> StoredEVMIntent {
        guard packet.request.networkID == "eip155:11155111",
              packet.transaction.chainID == 11_155_111,
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
            throw signerError("The RPC evidence does not match a fresh registered Sepolia call.")
        }
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
        let prepared = WalletPreparedTransaction(
            id: intentID, digest: rust.digest, networkID: packet.request.networkID,
            accountID: packet.request.accountID, action: packet.request.action,
            summary: "Call \(entry.label).\(packet.request.action.function ?? "unknown") on Sepolia",
            effects: decoded.effects, riskFlags: decoded.riskFlags, contract: identity,
            adapterID: decoded.adapterID, budgetAssetID: decoded.budgetAssetID,
            spendBaseUnits: decoded.spendBaseUnits,
            maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: fee, simulation: packet.simulation,
            simulationSucceeded: true, nonce: String(packet.transaction.nonce),
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "exact_confirmation_required", policyID: nil
        )
        // Contract policies are intentionally unavailable until their effect
        // adapter and budget semantics pass a separate security gate.
        return StoredEVMIntent(transaction: packet.transaction, prepared: prepared)
    }

    private func authoritativeContractEncoding(
        _ request: WalletContractEncodingRequest
    ) throws -> WalletEncodedContractCall {
        let action = request.action
        let entry = request.registryEntry
        guard action.type == .contractCall,
              entry.networkID == "eip155:11155111",
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
        let tokenAsset = "eip155:11155111/erc20:\(entry.checksumAddress.lowercased())"
        var effects: [WalletDecodedEffect] = []
        var riskFlags: [WalletRiskFlag] = [.unknownEffect]
        var adapterID: String?
        var budgetAssetID = "eip155:11155111/contract:\(entry.checksumAddress.lowercased())"
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
            adapterID = entry.reviewedAdapterID == "erc20-v1" ? "erc20-v1" : nil
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
            adapterID = entry.reviewedAdapterID == "erc20-v1" ? "erc20-v1" : nil
            budgetAssetID = tokenAsset
            spendBaseUnits = amount
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
        }
        return (effects, riskFlags, adapterID, budgetAssetID, spendBaseUnits)
    }

    private static let maximumUInt256Decimal =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    private func validatePolicy(_ policy: WalletSessionPolicy) throws {
        let accounts = try store.accounts()
        guard !policy.id.isEmpty,
              policy.networkID == "eip155:11155111",
              accounts.contains(where: { $0.id == policy.accountID && $0.chain == .evm }),
              policy.expiresAt > Date(),
              policy.expiresAt <= Date().addingTimeInterval(8 * 60 * 60),
              policy.allowedAssetIDs == ["slip44:60"],
              policy.allowedAdapterIDs == ["native-eth-transfer-v1"],
              policy.allowedContractIDs.isEmpty,
              !policy.allowedRecipients.isEmpty,
              policy.allowedRecipients.allSatisfy(Self.isEVMAddress),
              SignerUnsignedInteger.normalize(policy.maximumTransactionBaseUnits) != nil,
              SignerUnsignedInteger.normalize(policy.maximumSessionBaseUnits) != nil,
              SignerUnsignedInteger.normalize(policy.maximumFeeBaseUnits) != nil,
              SignerUnsignedInteger.lessThanOrEqual(
                  policy.maximumTransactionBaseUnits, policy.maximumSessionBaseUnits
              ) else {
            throw signerError(
                "Phase-one policies must be Sepolia native-ETH budgets for explicit recipient addresses and expire within eight hours."
            )
        }
    }

    private func validAutomaticPolicyID(for transaction: WalletPreparedTransaction) throws -> String {
        expirePolicies()
        guard transaction.adapterID == "native-eth-transfer-v1",
              transaction.budgetAssetID == "slip44:60",
              transaction.riskFlags.isEmpty,
              let recipient = transaction.action.recipient else {
            throw signerError("This transaction has no reviewed autonomous effect adapter.")
        }
        for active in activePolicies.values.sorted(by: { $0.policy.id < $1.policy.id }) {
            let policy = active.policy
            guard policy.accountID == transaction.accountID,
                  policy.networkID == transaction.networkID,
                  policy.allowedAssetIDs.contains(transaction.budgetAssetID),
                  policy.allowedAdapterIDs.contains("native-eth-transfer-v1"),
                  policy.allowedRecipients.contains(where: {
                      $0.caseInsensitiveCompare(recipient) == .orderedSame
                  }),
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

    private func policyStatuses() -> [WalletActivePolicyStatus] {
        activePolicies.values.map(\.status).sorted { $0.policy.expiresAt < $1.policy.expiresAt }
    }

    private static func isEVMAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private func validatedIntent(for recheck: WalletEVMRecheckPacket) throws -> StoredEVMIntent {
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
            accountID: prepared.accountID, action: prepared.action, summary: prepared.summary,
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

    private func lockInMemory() {
        if var entropy = unlockedEntropy { entropy.resetBytes(in: 0..<entropy.count) }
        unlockedEntropy = nil
        activeSessionID = nil
        preparedIntents.removeAll(keepingCapacity: false)
        activePolicies.removeAll(keepingCapacity: false)
    }

    private func clearPending() {
        if var entropy = pendingEntropy { entropy.resetBytes(in: 0..<entropy.count) }
        pendingEntropy = nil
        pendingWords.removeAll(keepingCapacity: false)
        pendingIndices.removeAll(keepingCapacity: false)
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? error("The signer could not encode its response.")
    }

    private func error(_ message: String) -> Data {
        (try? JSONEncoder().encode(WalletSignerErrorPayload(error: message))) ?? Data()
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
