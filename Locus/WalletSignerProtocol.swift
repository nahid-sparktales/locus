import Foundation

enum WalletChain: String, Codable, CaseIterable, Sendable {
    case evm
    case solana
    case sui
}

struct WalletAccount: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let chain: WalletChain
    let address: String
    let label: String
    let networkIDs: [String]

    init(id: String, chain: WalletChain, address: String, label: String, networkIDs: [String] = []) {
        self.id = id
        self.chain = chain
        self.address = address
        self.label = label
        self.networkIDs = networkIDs
    }
}

struct WalletTypedArgument: Codable, Equatable, Sendable {
    let type: String
    let value: String
}

enum WalletActionKind: String, Codable, Sendable {
    case nativeTransfer = "native_transfer"
    case contractCall = "contract_call"
}

/// Semantic transaction input. This wire type intentionally has no raw
/// calldata, digest, decoded-effect, or caller-supplied safety fields.
struct WalletSemanticAction: Codable, Equatable, Sendable {
    let type: WalletActionKind
    let recipient: String?
    let amountBaseUnits: String?
    let contractID: String?
    let function: String?
    let arguments: [WalletTypedArgument]
    let valueBaseUnits: String?

    static func nativeTransfer(recipient: String, amountBaseUnits: String) -> Self {
        Self(type: .nativeTransfer, recipient: recipient, amountBaseUnits: amountBaseUnits,
             contractID: nil, function: nil, arguments: [], valueBaseUnits: nil)
    }

    static func contractCall(
        contractID: String,
        function: String,
        arguments: [WalletTypedArgument],
        valueBaseUnits: String = "0"
    ) -> Self {
        Self(type: .contractCall, recipient: nil, amountBaseUnits: nil,
             contractID: contractID, function: function, arguments: arguments,
             valueBaseUnits: valueBaseUnits)
    }
}

struct WalletPrepareRequest: Codable, Equatable, Sendable {
    let networkID: String
    let accountID: String
    let action: WalletSemanticAction
    let maximumFeeBaseUnits: String
}

enum WalletRiskFlag: String, Codable, Equatable, Sendable {
    case unlimitedApproval = "unlimited_approval"
    case unknownEffect = "unknown_effect"
    case undecodableCall = "undecodable_call"
    case codeHashMismatch = "code_hash_mismatch"
    case staleQuote = "stale_quote"
}

struct WalletDecodedEffect: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let assetID: String
    let amountBaseUnits: String
    let from: String?
    let to: String?
    let spender: String?
}

struct WalletContractIdentity: Codable, Equatable, Sendable {
    let registryID: String
    let address: String
    let label: String
    let function: String
    let abiDigest: String
    let runtimeCodeHash: String
}

struct WalletPreparedTransaction: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let digest: String
    let networkID: String
    let accountID: String
    let action: WalletSemanticAction
    let summary: String
    let effects: [WalletDecodedEffect]
    let riskFlags: [WalletRiskFlag]
    let contract: WalletContractIdentity?
    let adapterID: String?
    let budgetAssetID: String
    let spendBaseUnits: String
    let maximumFeeBaseUnits: String
    let feeQuoteBaseUnits: String
    let simulation: String
    let simulationSucceeded: Bool
    let nonce: String
    let createdAt: Date
    let expiresAt: Date
    var policyDecision: String
    var policyID: String?
}

struct WalletSessionPolicy: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let accountID: String
    let networkID: String
    let allowedAssetIDs: Set<String>
    let allowedRecipients: Set<String>
    let allowedContractIDs: Set<String>
    let allowedAdapterIDs: Set<String>
    let maximumTransactionBaseUnits: String
    let maximumSessionBaseUnits: String
    let maximumFeeBaseUnits: String
    let expiresAt: Date
}

struct WalletActivePolicyStatus: Codable, Equatable, Identifiable, Sendable {
    var id: String { policy.id }
    let policy: WalletSessionPolicy
    let spentBaseUnits: String
}

struct WalletContractRegistryDraft: Codable, Equatable, Sendable {
    let id: String
    let networkID: String
    let address: String
    let label: String
    let abiJSON: String
    let permittedFunctions: [String]
    let reviewedAdapterID: String?
}

struct WalletContractRegistryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let networkID: String
    let checksumAddress: String
    let label: String
    let normalizedABI: String
    let abiDigest: String
    let runtimeCodeHash: String
    let permittedFunctions: [String]
    let permittedSelectors: [String]
    let reviewedAdapterID: String?
    let verifiedAt: Date
}

struct WalletContractEncodingRequest: Codable, Equatable, Sendable {
    let action: WalletSemanticAction
    let registryEntry: WalletContractRegistryEntry
}

struct WalletEncodedContractCall: Codable, Equatable, Sendable {
    let input: String
}

struct WalletEVMTransactionFields: Codable, Equatable, Sendable {
    let chainID: UInt64
    let nonce: UInt64
    let gasLimit: UInt64
    let maxFeePerGas: String
    let maxPriorityFeePerGas: String
    let to: String
    let value: String
    let input: String
}

struct WalletEVMPreparationPacket: Codable, Equatable, Sendable {
    let request: WalletPrepareRequest
    let fromAddress: String
    let transaction: WalletEVMTransactionFields
    let feeQuoteBaseUnits: String
    let simulation: String
    let simulationSucceeded: Bool
    let contractRegistryEntry: WalletContractRegistryEntry?
    let encodedContractCall: WalletEncodedContractCall?
    let observedRuntimeCodeHash: String?
    let observedAt: Date
}

struct WalletEVMRecheckPacket: Codable, Equatable, Sendable {
    let intentID: String
    let chainID: UInt64
    let pendingNonce: UInt64
    let feeQuoteBaseUnits: String
    let simulation: String
    let simulationSucceeded: Bool
    let observedRuntimeCodeHash: String?
    let observedAt: Date
}

struct WalletEVMSignedTransaction: Codable, Equatable, Sendable {
    let intentID: String
    let digest: String
    let rawTransaction: String
    let transactionHash: String
}

enum WalletVaultState: String, Codable, Sendable {
    case missing
    case awaitingBackup
    case locked
    case unlocked
}

struct WalletSignerStatus: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let vaultState: WalletVaultState
    let sessionID: String?
    let accounts: [WalletAccount]
}

struct WalletVaultCreation: Codable, Equatable, Sendable {
    let words: [String]
    /// Six zero-based word positions selected with secure randomness.
    let verificationIndices: [Int]
}

struct WalletBackupConfirmation: Codable, Equatable, Sendable {
    let wordsByIndex: [Int: String]
}

struct WalletSignerErrorPayload: Codable, Equatable, Sendable {
    let error: String
}

/// The Objective-C-compatible boundary uses Data, while every payload inside
/// that Data is a specific Codable type. NSDictionary is deliberately avoided:
/// selector spelling and allowed classes cannot silently widen the protocol.
@objc protocol WalletSignerXPCProtocol {
    func status(reply: @escaping (Data) -> Void)
    func beginCreateVault(reply: @escaping (Data) -> Void)
    func confirmBackup(_ request: Data, reply: @escaping (Data) -> Void)
    func cancelCreateVault(reply: @escaping (Data) -> Void)
    func authorizeSession(_ reason: String, reply: @escaping (Data) -> Void)
    func listAccounts(reply: @escaping (Data) -> Void)
    func encodeEVMContract(_ request: Data, reply: @escaping (Data) -> Void)
    func prepareEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func simulateEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func confirmEVM(_ intentID: String, reply: @escaping (Data) -> Void)
    func executeEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func activatePolicy(_ request: Data, reply: @escaping (Data) -> Void)
    func listPolicies(reply: @escaping (Data) -> Void)
    func clearPolicies(reply: @escaping (Data) -> Void)
    func lock(reply: @escaping (Data) -> Void)
    func deleteVault(_ confirmation: String, reply: @escaping (Data) -> Void)
}
