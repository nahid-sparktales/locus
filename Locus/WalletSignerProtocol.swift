import CryptoKit
import Foundation

enum WalletChain: String, Codable, CaseIterable, Sendable {
    case evm
    case solana
    case sui
}

enum WalletExternalConnectorID: String, Codable, CaseIterable, Hashable, Sendable {
    case metamask
    case phantom
    case slush
}

/// Public ownership metadata. Connector session material deliberately has no
/// representation here; it remains in the Direct-only connector runtime's
/// private WebKit or native SDK storage.
enum WalletAccountOwnership: Codable, Equatable, Sendable {
    case locusVault
    case external(connectorID: WalletExternalConnectorID)
    case connectorManaged(connectorID: WalletExternalConnectorID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case connectorID
    }

    private enum Kind: String, Codable {
        case locusVault = "locus_vault"
        case external
        case connectorManaged = "connector_managed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .locusVault:
            self = .locusVault
        case .external:
            self = .external(connectorID: try container.decode(
                WalletExternalConnectorID.self, forKey: .connectorID
            ))
        case .connectorManaged:
            self = .connectorManaged(connectorID: try container.decode(
                WalletExternalConnectorID.self, forKey: .connectorID
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .locusVault:
            try container.encode(Kind.locusVault, forKey: .kind)
        case .external(let connectorID):
            try container.encode(Kind.external, forKey: .kind)
            try container.encode(connectorID, forKey: .connectorID)
        case .connectorManaged(let connectorID):
            try container.encode(Kind.connectorManaged, forKey: .kind)
            try container.encode(connectorID, forKey: .connectorID)
        }
    }

    var connectorID: WalletExternalConnectorID? {
        switch self {
        case .locusVault:
            nil
        case .external(let connectorID), .connectorManaged(let connectorID):
            connectorID
        }
    }

    var requiresWalletOwnedConfirmation: Bool {
        if case .external = self { return true }
        return false
    }

    var isConnectorManaged: Bool {
        if case .connectorManaged = self { return true }
        return false
    }
}

struct WalletAccount: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let chain: WalletChain
    let address: String
    /// Optional base64-encoded public-key bytes for standards that require the
    /// key as well as its derived address (currently Sui Wallet Standard).
    /// This is public account metadata, never recovery or signing material.
    let publicKeyBase64: String?
    let label: String
    let networkIDs: [String]
    let ownership: WalletAccountOwnership

    init(
        id: String,
        chain: WalletChain,
        address: String,
        publicKeyBase64: String? = nil,
        label: String,
        networkIDs: [String] = [],
        ownership: WalletAccountOwnership = .locusVault
    ) {
        self.id = id
        self.chain = chain
        self.address = address
        self.publicKeyBase64 = publicKeyBase64
        self.label = label
        self.networkIDs = networkIDs
        self.ownership = ownership
    }

    private enum CodingKeys: String, CodingKey {
        case id, chain, address, publicKeyBase64, label, networkIDs, ownership
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chain = try container.decode(WalletChain.self, forKey: .chain)
        address = try container.decode(String.self, forKey: .address)
        publicKeyBase64 = try container.decodeIfPresent(
            String.self, forKey: .publicKeyBase64
        )
        label = try container.decode(String.self, forKey: .label)
        networkIDs = try container.decodeIfPresent([String].self, forKey: .networkIDs) ?? []
        ownership = try container.decodeIfPresent(
            WalletAccountOwnership.self, forKey: .ownership
        ) ?? .locusVault
    }
}

/// Decodes the signer core's snake-case public account payload without
/// changing the camel-case representation used by the Swift/XPC protocol and
/// persisted account files.
enum WalletDerivedAccountsDecoder {
    private struct Payload: Decodable {
        let accounts: [DerivedAccount]
    }

    private struct DerivedAccount: Decodable {
        let id: String
        let chain: WalletChain
        let address: String
        let publicKeyBase64: String?
        let label: String
        let networkIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id, chain, address, label
            case publicKeyBase64 = "public_key_base64"
            case networkIDs = "network_ids"
        }

        var walletAccount: WalletAccount {
            WalletAccount(
                id: id, chain: chain, address: address,
                publicKeyBase64: publicKeyBase64, label: label,
                networkIDs: networkIDs
            )
        }
    }

    static func decode(_ data: Data) throws -> [WalletAccount] {
        try JSONDecoder().decode(Payload.self, from: data)
            .accounts.map(\.walletAccount)
    }
}

struct WalletTypedArgument: Codable, Equatable, Sendable {
    let type: String
    let value: String
}

/// A reviewed swap route contains only semantic, network-bound asset IDs and
/// bounded execution parameters. Calldata, transaction bytes, arbitrary
/// router commands, and caller-selected payer flags are not representable.
struct WalletExactInputSwapRoute: Codable, Equatable, Sendable {
    let protocolVersion: WalletUniversalRouterSwapProtocol
    let pathAssetIDs: [String]
    let feeTiers: [UInt32]
    let minimumHopPriceX36: [String]
    let quotedOutputBaseUnits: String
    let slippageBPS: Int
    let deadlineUnixSeconds: String
    let quoteEvidence: WalletUniswapQuoteEvidence?

    init(
        protocolVersion: WalletUniversalRouterSwapProtocol,
        pathAssetIDs: [String],
        feeTiers: [UInt32],
        minimumHopPriceX36: [String],
        quotedOutputBaseUnits: String,
        slippageBPS: Int,
        deadlineUnixSeconds: String,
        quoteEvidence: WalletUniswapQuoteEvidence? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.pathAssetIDs = pathAssetIDs
        self.feeTiers = feeTiers
        self.minimumHopPriceX36 = minimumHopPriceX36
        self.quotedOutputBaseUnits = quotedOutputBaseUnits
        self.slippageBPS = slippageBPS
        self.deadlineUnixSeconds = deadlineUnixSeconds
        self.quoteEvidence = quoteEvidence
    }
}

/// Public, non-secret evidence returned by the independently verified on-chain
/// quote path. The evidence is bound into the semantic action and therefore
/// into the signer reconstruction; it never contains provider credentials or
/// caller-supplied calldata.
struct WalletUniswapQuoteEvidence: Codable, Equatable, Sendable {
    let blockNumber: String
    let blockHash: String
    let quoteContractAddress: String
    let quoteContractRuntimeCodeHash: String
    let perHopOutputBaseUnits: [String]
    let gasEstimate: String
    let quotedAt: Date
    let expiresAt: Date
    let agreeingProviderCount: Int
}

struct WalletUniswapQuoteRequest: Codable, Equatable, Sendable {
    let networkID: String
    let universalRouterContractID: String
    let inputAssetID: String
    let outputAssetID: String
    let amountInBaseUnits: String
    let slippageBPS: Int
    let recipient: String
    let requiredProtocolVersion: WalletUniversalRouterSwapProtocol?
    let requiredPathAssetIDs: [String]?
    let requiredFeeTiers: [UInt32]?
    let requiredDeadlineUnixSeconds: String?

    init(
        networkID: String,
        universalRouterContractID: String,
        inputAssetID: String,
        outputAssetID: String,
        amountInBaseUnits: String,
        slippageBPS: Int,
        recipient: String,
        requiredProtocolVersion: WalletUniversalRouterSwapProtocol? = nil,
        requiredPathAssetIDs: [String]? = nil,
        requiredFeeTiers: [UInt32]? = nil,
        requiredDeadlineUnixSeconds: String? = nil
    ) {
        self.networkID = networkID
        self.universalRouterContractID = universalRouterContractID
        self.inputAssetID = inputAssetID
        self.outputAssetID = outputAssetID
        self.amountInBaseUnits = amountInBaseUnits
        self.slippageBPS = slippageBPS
        self.recipient = recipient
        self.requiredProtocolVersion = requiredProtocolVersion
        self.requiredPathAssetIDs = requiredPathAssetIDs
        self.requiredFeeTiers = requiredFeeTiers
        self.requiredDeadlineUnixSeconds = requiredDeadlineUnixSeconds
    }
}

struct WalletUniswapQuote: Codable, Equatable, Sendable {
    let action: WalletSemanticAction
    let quotedAt: Date
    let expiresAt: Date
}

/// Provider-local result used only while two independently configured RPCs
/// are compared. The coordinator discards it unless the block identity,
/// contract identities, route outputs, and gas evidence agree exactly.
struct WalletUniswapProviderQuote: Equatable, Sendable {
    let blockNumber: UInt64
    let blockHash: String
    let protocolVersion: WalletUniversalRouterSwapProtocol
    let pathAssetIDs: [String]
    let feeTiers: [UInt32]
    let perHopOutputBaseUnits: [String]
    let quoteContractAddress: String
    let quoteContractRuntimeCodeHash: String
    let gasEstimate: String
}

enum WalletActionKind: String, Codable, Sendable {
    case nativeTransfer = "native_transfer"
    case fungibleTokenTransfer = "fungible_token_transfer"
    case nftTransfer = "nft_transfer"
    case exactInputSwap = "exact_input_swap"
    case swapAllowanceSetup = "swap_allowance_setup"
    case reviewedCall = "reviewed_call"
    case standardizedSignIn = "standardized_sign_in"
    case reviewedTypedAuthorization = "reviewed_typed_authorization"
    /// Protocol-v1 compatibility. New clients use `reviewedCall` and a
    /// manifest-pinned adapter, while the signer continues to reject unknown
    /// selectors and calldata.
    case contractCall = "contract_call"
}

enum WalletRequestSourceKind: String, Codable, Sendable {
    case humanUI = "human_ui"
    case agent
    case embeddedBrowser = "embedded_browser"
    case walletConnectPeer = "wallet_connect_peer"
    /// Protocol-v1 browser sessions decode to this value and retain their
    /// original exact-confirmation semantics during migration.
    case browser
}

struct WalletRequestSource: Codable, Equatable, Sendable {
    let kind: WalletRequestSourceKind
    let origin: String?
    let peerID: String?
    let displayName: String?

    init(
        kind: WalletRequestSourceKind,
        origin: String?,
        peerID: String? = nil,
        displayName: String? = nil
    ) {
        self.kind = kind
        self.origin = origin
        self.peerID = peerID
        self.displayName = displayName
    }

    static let human = Self(kind: .humanUI, origin: nil)
    static let agent = Self(kind: .agent, origin: nil)

    static func browser(origin: String) -> Self {
        Self(kind: .browser, origin: origin)
    }

    static func embeddedBrowser(origin: String) -> Self {
        Self(kind: .embeddedBrowser, origin: origin)
    }

    static func walletConnect(peerID: String, origin: String?, displayName: String?) -> Self {
        Self(
            kind: .walletConnectPeer, origin: origin,
            peerID: peerID, displayName: displayName
        )
    }
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
    var assetID: String? = nil
    var tokenID: String? = nil
    var inputAssetID: String? = nil
    var outputAssetID: String? = nil
    var minimumOutputBaseUnits: String? = nil
    var adapterID: String? = nil
    var authorizationFormat: String? = nil
    var metadataDigest: String? = nil
    var swapRoute: WalletExactInputSwapRoute? = nil
    var swapAllowanceSetup: WalletSwapAllowanceSetup? = nil

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

    static func fungibleTokenTransfer(
        assetID: String,
        recipient: String,
        amountBaseUnits: String
    ) -> Self {
        Self(
            type: .fungibleTokenTransfer, recipient: recipient,
            amountBaseUnits: amountBaseUnits, contractID: nil, function: nil,
            arguments: [], valueBaseUnits: nil, assetID: assetID
        )
    }

    static func nftTransfer(assetID: String, tokenID: String, recipient: String) -> Self {
        Self(
            type: .nftTransfer, recipient: recipient, amountBaseUnits: "1",
            contractID: nil, function: nil, arguments: [], valueBaseUnits: nil,
            assetID: assetID, tokenID: tokenID
        )
    }

    static func exactInputSwap(
        adapterID: String,
        contractID: String? = nil,
        inputAssetID: String,
        outputAssetID: String,
        amountInBaseUnits: String,
        minimumOutputBaseUnits: String,
        recipient: String,
        route: WalletExactInputSwapRoute? = nil
    ) -> Self {
        Self(
            type: .exactInputSwap, recipient: recipient,
            amountBaseUnits: amountInBaseUnits, contractID: contractID, function: nil,
            arguments: [], valueBaseUnits: nil, inputAssetID: inputAssetID,
            outputAssetID: outputAssetID,
            minimumOutputBaseUnits: minimumOutputBaseUnits,
            adapterID: adapterID, swapRoute: route
        )
    }

    static func swapAllowanceSetup(
        contractID: String,
        adapterID: String,
        setup: WalletSwapAllowanceSetup
    ) -> Self {
        Self(
            type: .swapAllowanceSetup,
            recipient: setup.stage == .permit2ToUniversalRouter
                ? setup.binding.universalRouterAddress : setup.binding.permit2Address,
            amountBaseUnits: setup.approvalAmountBaseUnits,
            contractID: contractID, function: nil, arguments: [],
            valueBaseUnits: nil, inputAssetID: setup.binding.inputAssetID,
            adapterID: adapterID, swapAllowanceSetup: setup
        )
    }
}

enum WalletSwapAllowanceStage: String, Codable, Sendable {
    case erc20Reset = "erc20_reset"
    case erc20ToPermit2 = "erc20_to_permit2"
    case permit2ToUniversalRouter = "permit2_to_universal_router"
}

struct WalletSwapAllowanceBinding: Codable, Equatable, Sendable {
    let networkID: String
    let universalRouterContractID: String
    let universalRouterAddress: String
    let permit2Address: String
    let inputAssetID: String
    let outputAssetID: String
    let amountInBaseUnits: String
    let minimumOutputBaseUnits: String
    let recipient: String
    let route: WalletExactInputSwapRoute

    func exactInputSwapAction() -> WalletSemanticAction {
        .exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: universalRouterContractID,
            inputAssetID: inputAssetID,
            outputAssetID: outputAssetID,
            amountInBaseUnits: amountInBaseUnits,
            minimumOutputBaseUnits: minimumOutputBaseUnits,
            recipient: recipient,
            route: route
        )
    }

    func digest() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

struct WalletSwapAllowanceSetup: Codable, Equatable, Sendable {
    let stage: WalletSwapAllowanceStage
    let binding: WalletSwapAllowanceBinding
    let bindingDigest: String
    let approvalAmountBaseUnits: String
    let expirationUnixSeconds: String?
}

struct WalletPrepareRequest: Codable, Equatable, Sendable {
    let networkID: String
    let accountID: String
    let source: WalletRequestSource
    let action: WalletSemanticAction
    let maximumFeeBaseUnits: String
}

enum WalletStructuredAuthorizationFormat: String, Codable, CaseIterable, Sendable {
    case siwe = "eip4361"
    case siws = "sign_in_with_solana"

    var coreIdentifier: String {
        switch self {
        case .siwe: "siwe"
        case .siws: "siws"
        }
    }

    init?(toolValue: String) {
        switch toolValue.lowercased() {
        case "siwe", "eip4361": self = .siwe
        case "siws", "sign_in_with_solana": self = .siws
        default: return nil
        }
    }
}

/// Structured sign-in request for protocol v3. A caller supplies reviewed
/// fields, never an arbitrary message. Both the app and signer independently
/// validate these fields and reconstruct the canonical bytes to sign.
struct WalletStructuredAuthorizationRequest: Codable, Equatable, Sendable {
    let format: WalletStructuredAuthorizationFormat
    let domain: String
    let origin: String
    let networkID: String
    let accountID: String
    let address: String
    let statement: String?
    let uri: String
    let nonce: String
    let issuedAt: Date
    let expirationTime: Date
    let notBefore: Date?
    let requestID: String?
    let resources: [String]
}

enum WalletStructuredAuthorizationSignatureEncoding: String, Codable, Sendable {
    case eip191Hex = "eip191_hex"
    case base58
}

struct WalletStructuredAuthorizationResult: Codable, Equatable, Sendable {
    let request: WalletStructuredAuthorizationRequest
    let canonicalMessage: String
    let messageDigest: String
    let signature: String
    let signatureEncoding: WalletStructuredAuthorizationSignatureEncoding
    let signedAt: Date
}

struct WalletAuthorizedRequest<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let sessionID: String
    let source: WalletRequestSource
    let payload: Payload
}

struct WalletSessionRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let sessionID: String
    let source: WalletRequestSource
}

enum WalletRiskFlag: String, Codable, Equatable, Sendable {
    case unlimitedApproval = "unlimited_approval"
    case unknownEffect = "unknown_effect"
    case undecodableCall = "undecodable_call"
    case codeHashMismatch = "code_hash_mismatch"
    case staleQuote = "stale_quote"
    case networkIdentityMismatch = "network_identity_mismatch"
    case providerDisagreement = "provider_disagreement"
    case staleBlockhash = "stale_blockhash"
    case staleObjectVersion = "stale_object_version"
    case lookupTableSubstitution = "lookup_table_substitution"
    case packageUpgrade = "package_upgrade"
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
    let source: WalletRequestSource
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

typealias WalletPreparedIntent = WalletPreparedTransaction

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
    var allowedActionKinds: Set<WalletActionKind>? = nil
    var maximumSlippageBPS: Int? = nil
    var minimumOutputBaseUnits: String? = nil
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

/// Adapter classification is derived from the normalized ABI and the exact
/// permitted function set. A registry caller cannot turn an arbitrary ABI into
/// a reviewed adapter by supplying a label.
enum WalletReviewedAdapters {
    static let ethereumNativeTransfer = "native-eth-transfer-v1"
    static let solanaNativeTransfer = "solana-system-transfer-v1"
    static let solanaSPLTransferChecked = "solana-spl-transfer-checked-v1"
    static let solanaToken2022TransferChecked =
        "solana-token-2022-transfer-checked-v1"
    static let solanaAssociatedTokenCreateIdempotent =
        "solana-associated-token-create-idempotent-v1"
    static let solanaCoreTransfer = "solana-mpl-core-transfer-v1"
    static let suiNativeTransfer = "sui-native-transfer-v1"
    static let suiCoinTransfer = "sui-coin-transfer-v1"
    static let suiObjectTransfer = "sui-object-transfer-v1"
    static let erc20 = "erc20-v1"
    static let erc721SafeTransfer = "erc721-safe-transfer-v1"
    static let erc1155SafeTransfer = "erc1155-safe-transfer-v1"
    static let uniswapUniversalRouterV2ExactIn =
        "uniswap-universal-router-v2-exact-in-v1"
    static let uniswapUniversalRouterV2V3ExactIn =
        "uniswap-universal-router-v2-v3-exact-in-v2"
    static let uniswapPermit2AllowanceSetup =
        "uniswap-permit2-allowance-setup-v1"
    static let staticallySupportedIDs: Set<String> = [
        ethereumNativeTransfer, solanaNativeTransfer, solanaSPLTransferChecked,
        solanaToken2022TransferChecked,
        solanaAssociatedTokenCreateIdempotent,
        solanaCoreTransfer,
        suiNativeTransfer, suiCoinTransfer, suiObjectTransfer,
        erc20, erc721SafeTransfer, erc1155SafeTransfer,
        uniswapUniversalRouterV2ExactIn,
        uniswapUniversalRouterV2V3ExactIn,
        uniswapPermit2AllowanceSetup,
    ]

    private struct FunctionShape: Equatable {
        let inputs: [String]
        let stateMutability: String
    }

    private static let erc20Functions: [String: FunctionShape] = [
        "approve(address,uint256)": FunctionShape(
            inputs: ["address", "uint256"], stateMutability: "nonpayable"
        ),
        "transfer(address,uint256)": FunctionShape(
            inputs: ["address", "uint256"], stateMutability: "nonpayable"
        ),
    ]
    private static let universalRouterFunctions: [String: FunctionShape] = [
        "execute(bytes,bytes[],uint256)": FunctionShape(
            inputs: ["bytes", "bytes[]", "uint256"], stateMutability: "payable"
        ),
    ]
    private static let permit2Functions: [String: FunctionShape] = [
        "approve(address,address,uint160,uint48)": FunctionShape(
            inputs: ["address", "address", "uint160", "uint48"],
            stateMutability: "nonpayable"
        ),
    ]
    private static let erc721Functions: [String: FunctionShape] = [
        "safeTransferFrom(address,address,uint256)": FunctionShape(
            inputs: ["address", "address", "uint256"], stateMutability: "nonpayable"
        ),
    ]
    private static let erc1155Functions: [String: FunctionShape] = [
        "safeTransferFrom(address,address,uint256,uint256,bytes)": FunctionShape(
            inputs: ["address", "address", "uint256", "uint256", "bytes"],
            stateMutability: "nonpayable"
        ),
    ]

    static func classify(normalizedABI: String, permittedFunctions: [String]) -> String? {
        guard let definitions = functionDefinitions(in: normalizedABI) else { return nil }
        let permitted = Set(permittedFunctions)
        if !permitted.isEmpty, permitted.isSubset(of: Set(erc20Functions.keys)),
           permitted.allSatisfy({ definitions[$0] == erc20Functions[$0] }) {
            return erc20
        }
        if permitted == Set(erc721Functions.keys),
           permitted.allSatisfy({ definitions[$0] == erc721Functions[$0] }) {
            return erc721SafeTransfer
        }
        if permitted == Set(erc1155Functions.keys),
           permitted.allSatisfy({ definitions[$0] == erc1155Functions[$0] }) {
            return erc1155SafeTransfer
        }
        if permitted == Set(universalRouterFunctions.keys),
           permitted.allSatisfy({ definitions[$0] == universalRouterFunctions[$0] }) {
            return uniswapUniversalRouterV2V3ExactIn
        }
        if permitted == Set(permit2Functions.keys),
           permitted.allSatisfy({ definitions[$0] == permit2Functions[$0] }) {
            return uniswapPermit2AllowanceSetup
        }
        return nil
    }

    static func validatedID(for entry: WalletContractRegistryEntry) -> String? {
        guard let claimed = entry.reviewedAdapterID else { return nil }
        let classified = classify(
            normalizedABI: entry.normalizedABI,
            permittedFunctions: entry.permittedFunctions
        )
        // Preserve the authority of an existing signed v1 adapter. The same
        // router ABI identifies both versions, but only the v2 adapter may
        // decode the newer V2/V3 command payloads.
        if claimed == uniswapUniversalRouterV2ExactIn,
           classified == uniswapUniversalRouterV2V3ExactIn {
            return claimed
        }
        guard claimed == classified else { return nil }
        return claimed
    }

    private static func functionDefinitions(in normalizedABI: String) -> [String: FunctionShape]? {
        guard normalizedABI.utf8.count <= 256 * 1024,
              let data = normalizedABI.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var definitions: [String: FunctionShape] = [:]
        for item in items where item["type"] as? String == "function" {
            guard let name = item["name"] as? String,
                  let stateMutability = item["stateMutability"] as? String,
                  let inputs = item["inputs"] as? [[String: Any]],
                  inputs.count <= 64 else { return nil }
            let types = inputs.compactMap { $0["type"] as? String }
            guard types.count == inputs.count else { return nil }
            let signature = "\(name)(\(types.joined(separator: ",")))"
            // Ambiguous duplicate definitions are never adapter-reviewed.
            guard definitions[signature] == nil else { return nil }
            definitions[signature] = FunctionShape(
                inputs: types, stateMutability: stateMutability
            )
        }
        return definitions
    }
}

enum WalletEVMAssetStandard: String, Codable, Sendable {
    case erc20
    case erc721
    case erc1155
}

/// Canonical EVM asset IDs are network-bound and contain no display metadata:
/// `eip155:1/erc20:0x…`, `eip155:1/erc721:0x…[/token-id]`, or
/// `eip155:1/erc1155:0x…/token-id`.
struct WalletEVMAssetIdentity: Codable, Equatable, Sendable {
    let networkID: String
    let standard: WalletEVMAssetStandard
    let contractAddress: String
    let tokenID: String?

    var collectionID: String {
        "\(networkID)/\(standard.rawValue):\(contractAddress.lowercased())"
    }

    var canonicalID: String {
        tokenID.map { "\(collectionID)/\($0)" } ?? collectionID
    }

    static func parse(_ value: String) -> WalletEVMAssetIdentity? {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        let networkID = String(pieces[0])
        let chainComponent = String(networkID.dropFirst("eip155:".count))
        guard networkID.hasPrefix("eip155:"),
              let chainID = UInt64(chainComponent), chainID > 0,
              chainComponent == String(chainID) else { return nil }
        let asset = pieces[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard asset.count == 2,
              let standard = WalletEVMAssetStandard(rawValue: String(asset[0])) else { return nil }
        let address = String(asset[1]).lowercased()
        guard address.count == 42, address.hasPrefix("0x"),
              address.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        let tokenID = pieces.count == 3 ? normalizedUnsigned(String(pieces[2])) : nil
        guard pieces.count != 3 || tokenID != nil,
              standard != .erc20 || tokenID == nil,
              standard != .erc1155 || tokenID != nil else { return nil }
        return WalletEVMAssetIdentity(
            networkID: networkID, standard: standard,
            contractAddress: address, tokenID: tokenID
        )
    }

    private static func normalizedUnsigned(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

struct WalletEVMReviewedSemanticCall: Equatable, Sendable {
    let adapterID: String
    let assetID: String
    let function: String
    let arguments: [WalletTypedArgument]
}

/// Converts only fully semantic token/NFT actions into reviewed standard calls.
/// Callers cannot supply a selector, calldata, sender, or arbitrary bytes.
enum WalletEVMAssetAdapter {
    static func resolve(
        action: WalletSemanticAction,
        registryEntry: WalletContractRegistryEntry,
        accountAddress: String
    ) -> WalletEVMReviewedSemanticCall? {
        guard let assetID = action.assetID,
              let identity = WalletEVMAssetIdentity.parse(assetID),
              identity.networkID == registryEntry.networkID,
              identity.contractAddress.caseInsensitiveCompare(
                  registryEntry.checksumAddress
              ) == .orderedSame,
              isAddress(accountAddress),
              let recipient = action.recipient, isAddress(recipient),
              action.contractID == nil, action.function == nil,
              action.arguments.isEmpty, action.valueBaseUnits == nil,
              let adapterID = WalletReviewedAdapters.validatedID(for: registryEntry) else {
            return nil
        }
        switch (action.type, identity.standard, adapterID) {
        case (.fungibleTokenTransfer, .erc20, WalletReviewedAdapters.erc20):
            guard identity.tokenID == nil,
                  action.tokenID == nil,
                  let amount = normalizedUnsigned(action.amountBaseUnits), amount != "0" else {
                return nil
            }
            return WalletEVMReviewedSemanticCall(
                adapterID: adapterID, assetID: identity.collectionID,
                function: "transfer(address,uint256)",
                arguments: [
                    WalletTypedArgument(type: "address", value: recipient),
                    WalletTypedArgument(type: "uint256", value: amount),
                ]
            )
        case (.nftTransfer, .erc721, WalletReviewedAdapters.erc721SafeTransfer):
            guard action.amountBaseUnits == "1",
                  let tokenID = normalizedUnsigned(action.tokenID),
                  identity.tokenID == nil || identity.tokenID == tokenID else { return nil }
            return WalletEVMReviewedSemanticCall(
                adapterID: adapterID, assetID: identity.collectionID,
                function: "safeTransferFrom(address,address,uint256)",
                arguments: [
                    WalletTypedArgument(type: "address", value: accountAddress),
                    WalletTypedArgument(type: "address", value: recipient),
                    WalletTypedArgument(type: "uint256", value: tokenID),
                ]
            )
        case (.nftTransfer, .erc1155, WalletReviewedAdapters.erc1155SafeTransfer):
            guard action.amountBaseUnits == "1",
                  let tokenID = normalizedUnsigned(action.tokenID),
                  identity.tokenID == tokenID else { return nil }
            return WalletEVMReviewedSemanticCall(
                adapterID: adapterID, assetID: identity.collectionID,
                function: "safeTransferFrom(address,address,uint256,uint256,bytes)",
                arguments: [
                    WalletTypedArgument(type: "address", value: accountAddress),
                    WalletTypedArgument(type: "address", value: recipient),
                    WalletTypedArgument(type: "uint256", value: tokenID),
                    WalletTypedArgument(type: "uint256", value: "1"),
                    WalletTypedArgument(type: "bytes", value: "0x"),
                ]
            )
        default:
            return nil
        }
    }

    private static func normalizedUnsigned(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func isAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }
}

enum WalletSwapAllowanceAdapter {
    static func resolve(
        action: WalletSemanticAction,
        registryEntry: WalletContractRegistryEntry,
        configuration: WalletReviewedUniswapConfiguration,
        now: Date = Date()
    ) -> WalletEVMReviewedSemanticCall? {
        guard action.type == .swapAllowanceSetup,
              action.function == nil, action.arguments.isEmpty,
              action.valueBaseUnits == nil,
              let setup = action.swapAllowanceSetup,
              setup.binding.digest() == setup.bindingDigest,
              setup.binding.networkID == registryEntry.networkID,
              setup.binding.universalRouterContractID
                == configuration.universalRouterContractID,
              setup.binding.universalRouterAddress.caseInsensitiveCompare(
                configuration.contract(.universalRouter)?.address ?? ""
              ) == .orderedSame,
              setup.binding.permit2Address.caseInsensitiveCompare(
                configuration.contract(.permit2)?.address ?? ""
              ) == .orderedSame,
              (setup.binding.route.quoteEvidence?.expiresAt ?? .distantPast) > now,
              setup.binding.amountInBaseUnits != "0",
              normalizedUnsigned(setup.binding.amountInBaseUnits)
                == setup.binding.amountInBaseUnits,
              normalizedUnsigned(setup.approvalAmountBaseUnits)
                == setup.approvalAmountBaseUnits,
              action.amountBaseUnits == setup.approvalAmountBaseUnits,
              action.inputAssetID == setup.binding.inputAssetID,
              let input = WalletEVMAssetIdentity.parse(setup.binding.inputAssetID),
              input.networkID == registryEntry.networkID,
              input.standard == .erc20, input.tokenID == nil else { return nil }

        switch setup.stage {
        case .erc20Reset, .erc20ToPermit2:
            guard registryEntry.checksumAddress.caseInsensitiveCompare(
                input.contractAddress
            ) == .orderedSame,
            WalletReviewedAdapters.validatedID(for: registryEntry)
                == WalletReviewedAdapters.erc20,
            action.adapterID == WalletReviewedAdapters.erc20,
            setup.expirationUnixSeconds == nil,
            setup.stage == .erc20Reset
                ? setup.approvalAmountBaseUnits == "0"
                : setup.approvalAmountBaseUnits
                    == setup.binding.amountInBaseUnits else { return nil }
            return WalletEVMReviewedSemanticCall(
                adapterID: WalletReviewedAdapters.erc20,
                assetID: input.canonicalID,
                function: "approve(address,uint256)",
                arguments: [
                    WalletTypedArgument(
                        type: "address", value: setup.binding.permit2Address
                    ),
                    WalletTypedArgument(
                        type: "uint256", value: setup.approvalAmountBaseUnits
                    ),
                ]
            )
        case .permit2ToUniversalRouter:
            guard registryEntry.id == configuration.permit2ContractID,
                  registryEntry.checksumAddress.caseInsensitiveCompare(
                    setup.binding.permit2Address
                  ) == .orderedSame,
                  WalletReviewedAdapters.validatedID(for: registryEntry)
                    == WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
                  action.adapterID
                    == WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
                  setup.approvalAmountBaseUnits
                    == setup.binding.amountInBaseUnits,
                  setup.expirationUnixSeconds
                    == setup.binding.route.deadlineUnixSeconds else { return nil }
            return WalletEVMReviewedSemanticCall(
                adapterID: WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
                assetID: input.canonicalID,
                function: "approve(address,address,uint160,uint48)",
                arguments: [
                    WalletTypedArgument(type: "address", value: input.contractAddress),
                    WalletTypedArgument(
                        type: "address", value: setup.binding.universalRouterAddress
                    ),
                    WalletTypedArgument(
                        type: "uint160", value: setup.approvalAmountBaseUnits
                    ),
                    WalletTypedArgument(
                        type: "uint48", value: setup.binding.route.deadlineUnixSeconds
                    ),
                ]
            )
        }
    }

    private static func normalizedUnsigned(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 78,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

struct WalletUniversalRouterV2Swap: Equatable, Sendable {
    let protocolVersion: WalletUniversalRouterSwapProtocol
    let inputAssetID: String
    let outputAssetID: String
    let amountIn: String
    let minimumAmountOut: String
    let recipient: String
    let pathAssetIDs: [String]
    let feeTiers: [UInt32]
    let minimumHopPriceX36: [String]
    let deadlineUnixSeconds: String
}

enum WalletUniversalRouterSwapProtocol: String, Codable, Equatable, Sendable {
    case v2
    case v3
}

enum WalletReviewedUniswapContractRole: String, Codable, CaseIterable, Sendable {
    case v2Router = "v2_router"
    case v2Factory = "v2_factory"
    case v3Factory = "v3_factory"
    case v3QuoterV2 = "v3_quoter_v2"
    case universalRouter = "universal_router"
    case permit2
}

struct WalletReviewedUniswapContractIdentity: Codable, Equatable, Sendable {
    let role: WalletReviewedUniswapContractRole
    let address: String
    let runtimeCodeHash: String
}

struct WalletReviewedUniswapPoolIdentity: Codable, Equatable, Sendable {
    let protocolVersion: WalletUniversalRouterSwapProtocol
    let address: String
    let runtimeCodeHash: String
    let token0AssetID: String
    let token1AssetID: String
    let feeTier: UInt32?
}

/// Every address which can influence quote or settlement is attributable to a
/// signed review manifest. Only acyclic all-V2 or all-V3 paths are enumerable.
struct WalletReviewedUniswapConfiguration: Codable, Equatable, Sendable {
    let networkID: String
    let universalRouterContractID: String
    let permit2ContractID: String
    let contracts: [WalletReviewedUniswapContractIdentity]
    let pools: [WalletReviewedUniswapPoolIdentity]
    let allowedIntermediaryAssetIDs: Set<String>
    let allowedFeeTiers: Set<UInt32>
    let maximumHops: Int
    let zeroFirstApprovalAssetIDs: Set<String>

    func contract(_ role: WalletReviewedUniswapContractRole)
        -> WalletReviewedUniswapContractIdentity? {
        contracts.first { $0.role == role }
    }
}

extension WalletReviewedUniswapConfiguration {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(networkID, forKey: .networkID)
        try values.encode(universalRouterContractID, forKey: .universalRouterContractID)
        try values.encode(permit2ContractID, forKey: .permit2ContractID)
        try values.encode(contracts, forKey: .contracts)
        try values.encode(pools, forKey: .pools)
        try values.encode(allowedIntermediaryAssetIDs.sorted(), forKey: .allowedIntermediaryAssetIDs)
        try values.encode(allowedFeeTiers.sorted(), forKey: .allowedFeeTiers)
        try values.encode(maximumHops, forKey: .maximumHops)
        try values.encode(zeroFirstApprovalAssetIDs.sorted(), forKey: .zeroFirstApprovalAssetIDs)
    }
}


enum WalletUniversalRouterV2Adapter {
    /// Decodes one Universal Router v2 `V2_SWAP_EXACT_IN` command. Composite
    /// programs, allow-revert, Permit2 commands, exact-output swaps, and native
    /// wrapping are intentionally outside this adapter.
    static func decode(
        action: WalletSemanticAction,
        accountAddress: String,
        networkID: String = "eip155:11155111",
        now: Date = Date()
    ) -> WalletUniversalRouterV2Swap? {
        guard action.function == "execute(bytes,bytes[],uint256)",
              action.arguments.count == 3,
              action.arguments[0].type == "bytes",
              action.arguments[0].value.lowercased() == "0x08",
              action.arguments[1].type == "bytes[]",
              let encodedInput = singleBytesArray(action.arguments[1].value),
              action.arguments[2].type == "uint256",
              let deadline = UInt64(normalizedDecimal(action.arguments[2].value) ?? "") else {
            return nil
        }
        let timestamp = UInt64(max(0, now.timeIntervalSince1970.rounded(.down)))
        guard deadline >= timestamp, deadline <= timestamp + 20 * 60 else { return nil }

        let raw = encodedInput.lowercased().hasPrefix("0x")
            ? String(encodedInput.dropFirst(2)) : encodedInput
        guard raw.count >= 8 * 64, raw.count.isMultiple(of: 64),
              raw.allSatisfy(\.isHexDigit) else { return nil }
        let words = stride(from: 0, to: raw.count, by: 64).map { offset -> String in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 64)
            return String(raw[start..<end])
        }
        guard words.count >= 8,
              let recipient = address(fromABIWord: words[0]),
              let amountIn = decimal(fromABIWord: words[1]), amountIn != "0",
              let minimumOut = decimal(fromABIWord: words[2]), minimumOut != "0",
              decimal(fromABIWord: words[3]) == "160",
              decimal(fromABIWord: words[4]) == "1",
              let pathCountText = decimal(fromABIWord: words[5]),
              let pathCount = Int(pathCountText), (2...4).contains(pathCount),
              words.count == 6 + pathCount else { return nil }
        let path = words[6...].compactMap(address(fromABIWord:))
        guard path.count == pathCount,
              path.first?.caseInsensitiveCompare(path.last ?? "") != .orderedSame,
              recipient.caseInsensitiveCompare(accountAddress) == .orderedSame else { return nil }
        return WalletUniversalRouterV2Swap(
            protocolVersion: .v2,
            inputAssetID: "\(networkID)/erc20:\(path[0].lowercased())",
            outputAssetID: "\(networkID)/erc20:\(path[path.count - 1].lowercased())",
            amountIn: amountIn, minimumAmountOut: minimumOut,
            recipient: recipient,
            pathAssetIDs: path.map {
                "\(networkID)/erc20:\($0.lowercased())"
            }, feeTiers: [], minimumHopPriceX36: [],
            deadlineUnixSeconds: String(deadline)
        )
    }

    private static func singleBytesArray(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[", trimmed.last == "]" else { return nil }
        let inner = trimmed.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty, !inner.contains(","),
              inner.lowercased().hasPrefix("0x"),
              inner.dropFirst(2).count.isMultiple(of: 2),
              inner.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return inner
    }

    private static func normalizedDecimal(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func decimal(fromABIWord word: String) -> String? {
        guard word.count == 64, word.allSatisfy(\.isHexDigit) else { return nil }
        var result = "0"
        for character in word.lowercased() {
            guard let digit = Int(String(character), radix: 16),
                  let next = multiplyAndAdd(result, multiplier: 16, addend: digit) else {
                return nil
            }
            result = next
        }
        return result
    }

    private static func multiplyAndAdd(
        _ value: String, multiplier: Int, addend: Int
    ) -> String? {
        guard multiplier >= 0, addend >= 0, !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var carry = addend
        var digits: [Int] = []
        for character in value.reversed() {
            guard let digit = character.wholeNumberValue else { return nil }
            let total = digit * multiplier + carry
            digits.append(total % 10)
            carry = total / 10
        }
        while carry > 0 {
            digits.append(carry % 10)
            carry /= 10
        }
        return digits.reversed().map(String.init).joined()
    }

    private static func address(fromABIWord word: String) -> String? {
        guard word.count == 64,
              word.prefix(24).allSatisfy({ $0 == "0" }),
              word.suffix(40).allSatisfy(\.isHexDigit) else { return nil }
        let value = "0x" + String(word.suffix(40))
        return value.count == 42 ? value : nil
    }
}

enum WalletUniversalRouterV2V3Adapter {
    /// Materializes a semantic exact-input request into the sole reviewed
    /// Universal Router call shape. The resulting typed arguments are still
    /// encoded by the isolated Rust ABI encoder and decoded again below before
    /// signing; callers cannot provide or override them.
    static func contractAction(
        for action: WalletSemanticAction,
        accountAddress: String,
        networkID: String,
        now: Date = Date()
    ) -> WalletSemanticAction? {
        guard action.type == .exactInputSwap,
              action.adapterID == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
              let contractID = action.contractID, !contractID.isEmpty,
              action.function == nil, action.arguments.isEmpty,
              action.valueBaseUnits == nil, action.assetID == nil,
              action.tokenID == nil, action.authorizationFormat == nil,
              action.metadataDigest == nil,
              let amountIn = normalizedDecimal(action.amountBaseUnits ?? ""),
              amountIn != "0",
              let minimumOut = normalizedDecimal(
                action.minimumOutputBaseUnits ?? ""
              ), minimumOut != "0",
              let recipient = action.recipient,
              recipient.caseInsensitiveCompare(accountAddress) == .orderedSame,
              let route = action.swapRoute,
              (2...4).contains(route.pathAssetIDs.count),
              action.inputAssetID == route.pathAssetIDs.first,
              action.outputAssetID == route.pathAssetIDs.last,
              let quotedOutput = normalizedDecimal(
                route.quotedOutputBaseUnits
              ), quotedOutput == route.quotedOutputBaseUnits,
              quotedOutput != "0", (0...5_000).contains(route.slippageBPS),
              decimalLessThanOrEqual(amountIn, maximumUInt256Decimal),
              decimalLessThanOrEqual(minimumOut, maximumUInt256Decimal),
              decimalLessThanOrEqual(quotedOutput, maximumUInt256Decimal),
              decimalLessThanOrEqual(minimumOut, quotedOutput),
              let minimumScaled = multiplyAndAdd(
                minimumOut, multiplier: 10_000, addend: 0
              ),
              let requiredScaled = multiplyAndAdd(
                quotedOutput, multiplier: 10_000 - route.slippageBPS,
                addend: 0
              ),
              let nextMinimum = multiplyAndAdd(
                minimumOut, multiplier: 1, addend: 1
              ),
              let nextMinimumScaled = multiplyAndAdd(
                nextMinimum, multiplier: 10_000, addend: 0
              ),
              decimalLessThanOrEqual(minimumScaled, requiredScaled),
              !decimalLessThanOrEqual(nextMinimumScaled, requiredScaled),
              let deadline = normalizedDecimal(route.deadlineUnixSeconds),
              deadline == route.deadlineUnixSeconds else { return nil }

        let identities = route.pathAssetIDs.compactMap(
            WalletEVMAssetIdentity.parse
        )
        guard identities.count == route.pathAssetIDs.count,
              zip(identities, route.pathAssetIDs).allSatisfy({ identity, assetID in
                  identity.networkID == networkID && identity.standard == .erc20
                      && identity.tokenID == nil
                      && identity.canonicalID == assetID
              }) else { return nil }
        let tokenAddresses = identities.map(\.contractAddress)
        let normalizedAddresses = tokenAddresses.map { $0.lowercased() }
        guard Set(normalizedAddresses).count == normalizedAddresses.count,
              tokenAddresses.allSatisfy(isAddress) else { return nil }
        let hopCount = tokenAddresses.count - 1
        let prices = route.minimumHopPriceX36.compactMap(normalizedDecimal)
        guard prices.count == route.minimumHopPriceX36.count,
              prices == route.minimumHopPriceX36,
              prices.isEmpty || prices.count == hopCount,
              prices.allSatisfy({ $0 != "0" }) else { return nil }

        let command: String
        let pathWords: [String]
        switch route.protocolVersion {
        case .v2:
            guard route.feeTiers.isEmpty else { return nil }
            command = "0x08"
            guard let countWord = abiWord(decimal: String(tokenAddresses.count)) else {
                return nil
            }
            pathWords = [countWord] + tokenAddresses.compactMap(abiAddressWord)
            guard pathWords.count == tokenAddresses.count + 1 else { return nil }
        case .v3:
            guard route.feeTiers.count == hopCount,
                  route.feeTiers.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }) else {
                return nil
            }
            command = "0x00"
            var packed = String(tokenAddresses[0].dropFirst(2)).lowercased()
            for index in route.feeTiers.indices {
                packed += String(format: "%06x", route.feeTiers[index])
                packed += String(tokenAddresses[index + 1].dropFirst(2)).lowercased()
            }
            let paddedCount = ((packed.count + 63) / 64) * 64
            packed += String(repeating: "0", count: paddedCount - packed.count)
            guard let lengthWord = abiWord(
                decimal: String((20 + hopCount * 23))
            ) else { return nil }
            pathWords = [lengthWord] + stride(
                from: 0, to: packed.count, by: 64
            ).map { offset in
                let start = packed.index(packed.startIndex, offsetBy: offset)
                let end = packed.index(start, offsetBy: 64)
                return String(packed[start..<end])
            }
        }
        let pricesOffset = (6 + pathWords.count) * 32
        guard let recipientWord = abiAddressWord(recipient),
              let amountWord = abiWord(decimal: amountIn),
              let minimumWord = abiWord(decimal: minimumOut),
              let pathOffsetWord = abiWord(decimal: "192"),
              let payerWord = abiWord(decimal: "1"),
              let pricesOffsetWord = abiWord(decimal: String(pricesOffset)),
              let priceCountWord = abiWord(decimal: String(prices.count)) else {
            return nil
        }
        let priceWords = prices.compactMap { abiWord(decimal: $0) }
        guard priceWords.count == prices.count else { return nil }
        let encodedInput = ([
            recipientWord, amountWord, minimumWord, pathOffsetWord, payerWord,
            pricesOffsetWord,
        ] + pathWords + [priceCountWord] + priceWords).joined()
        let materialized = WalletSemanticAction.contractCall(
            contractID: contractID,
            function: "execute(bytes,bytes[],uint256)",
            arguments: [
                WalletTypedArgument(type: "bytes", value: command),
                WalletTypedArgument(type: "bytes[]", value: "[0x\(encodedInput)]"),
                WalletTypedArgument(type: "uint256", value: deadline),
            ]
        )
        return decode(
            action: materialized, accountAddress: accountAddress,
            networkID: networkID, now: now
        ) == nil ? nil : materialized
    }

    /// Decodes exactly one current Universal Router V2 or V3 exact-input
    /// command. The input must use the six-field per-hop-price ABI introduced
    /// for the v2.2 router deployment. Permit commands, native wrapping,
    /// allow-revert, sub-plans, exact-output, and non-canonical ABI layouts are
    /// not accepted by this adapter version.
    static func decode(
        action: WalletSemanticAction,
        accountAddress: String,
        networkID: String = "eip155:1",
        now: Date = Date()
    ) -> WalletUniversalRouterV2Swap? {
        guard action.function == "execute(bytes,bytes[],uint256)",
              action.arguments.count == 3,
              action.arguments[0].type == "bytes",
              let protocolVersion = command(action.arguments[0].value),
              action.arguments[1].type == "bytes[]",
              let encodedInput = singleBytesArray(action.arguments[1].value),
              action.arguments[2].type == "uint256",
              let deadline = UInt64(normalizedDecimal(action.arguments[2].value) ?? ""),
              isAddress(accountAddress) else { return nil }
        let timestamp = UInt64(max(0, now.timeIntervalSince1970.rounded(.down)))
        guard deadline >= timestamp, deadline <= timestamp + 20 * 60 else {
            return nil
        }

        let raw = encodedInput.lowercased().hasPrefix("0x")
            ? String(encodedInput.dropFirst(2)) : encodedInput
        guard raw.count >= 10 * 64, raw.count.isMultiple(of: 64),
              raw.allSatisfy(\.isHexDigit) else { return nil }
        let words = stride(from: 0, to: raw.count, by: 64).map { offset -> String in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 64)
            return String(raw[start..<end])
        }
        guard let recipient = address(fromABIWord: words[0]),
              let amountIn = decimal(fromABIWord: words[1]), amountIn != "0",
              let minimumOut = decimal(fromABIWord: words[2]), minimumOut != "0",
              decimal(fromABIWord: words[3]) == "192",
              decimal(fromABIWord: words[4]) == "1",
              let pricesOffsetText = decimal(fromABIWord: words[5]),
              let pricesOffset = Int(pricesOffsetText),
              pricesOffset.isMultiple(of: 32),
              recipient.caseInsensitiveCompare(accountAddress) == .orderedSame else {
            return nil
        }

        let route: [String]
        let routeFees: [UInt32]
        let hopCount: Int
        let priceWordIndex: Int
        switch protocolVersion {
        case .v2:
            guard let pathCountText = decimal(fromABIWord: words[6]),
                  let pathCount = Int(pathCountText), (2...4).contains(pathCount),
                  words.count >= 8 + pathCount else { return nil }
            let parsed = words[7..<(7 + pathCount)]
                .compactMap(address(fromABIWord:))
            guard parsed.count == pathCount else { return nil }
            route = parsed
            routeFees = []
            hopCount = pathCount - 1
            priceWordIndex = 7 + pathCount
        case .v3:
            guard let byteCountText = decimal(fromABIWord: words[6]),
                  let byteCount = Int(byteCountText), byteCount >= 43,
                  (byteCount - 20).isMultiple(of: 23) else { return nil }
            hopCount = (byteCount - 20) / 23
            guard (1...3).contains(hopCount) else { return nil }
            let pathWords = (byteCount + 31) / 32
            guard words.count >= 8 + pathWords else { return nil }
            let paddedPath = words[7..<(7 + pathWords)].joined()
            let pathHexCount = byteCount * 2
            let pathEnd = paddedPath.index(
                paddedPath.startIndex, offsetBy: pathHexCount
            )
            guard paddedPath[pathEnd...].allSatisfy({ $0 == "0" }) else {
                return nil
            }
            let path = String(paddedPath[..<pathEnd])
            guard let parsed = v3Route(path, hopCount: hopCount) else {
                return nil
            }
            route = parsed.addresses
            routeFees = parsed.fees
            priceWordIndex = 7 + pathWords
        }
        guard pricesOffset == priceWordIndex * 32,
              words.indices.contains(priceWordIndex),
              let priceCountText = decimal(fromABIWord: words[priceWordIndex]),
              let priceCount = Int(priceCountText),
              priceCount == 0 || priceCount == hopCount,
              words.count == priceWordIndex + 1 + priceCount else { return nil }
        let prices: [String]
        if priceCount > 0 {
            prices = words[(priceWordIndex + 1)...]
                .compactMap(decimal(fromABIWord:))
            guard prices.count == priceCount,
                  prices.allSatisfy({ $0 != "0" }) else { return nil }
        } else { prices = [] }
        guard route.count == hopCount + 1,
              Set(route.map { $0.lowercased() }).count == route.count,
              zip(route, route.dropFirst()).allSatisfy({ pair in
                  pair.0.caseInsensitiveCompare(pair.1) != .orderedSame
              }),
              route.first?.caseInsensitiveCompare(route.last ?? "")
                != .orderedSame else { return nil }
        return WalletUniversalRouterV2Swap(
            protocolVersion: protocolVersion,
            inputAssetID: "\(networkID)/erc20:\(route[0].lowercased())",
            outputAssetID: "\(networkID)/erc20:\(route[route.count - 1].lowercased())",
            amountIn: amountIn, minimumAmountOut: minimumOut,
            recipient: recipient,
            pathAssetIDs: route.map {
                "\(networkID)/erc20:\($0.lowercased())"
            }, feeTiers: routeFees, minimumHopPriceX36: prices,
            deadlineUnixSeconds: String(deadline)
        )
    }

    private static func command(
        _ value: String
    ) -> WalletUniversalRouterSwapProtocol? {
        switch value.lowercased() {
        case "0x08": .v2
        case "0x00": .v3
        default: nil
        }
    }

    private static func v3Route(
        _ path: String, hopCount: Int
    ) -> (addresses: [String], fees: [UInt32])? {
        guard path.count == (20 + hopCount * 23) * 2 else { return nil }
        var cursor = path.startIndex
        func take(_ count: Int) -> String? {
            guard let end = path.index(
                cursor, offsetBy: count, limitedBy: path.endIndex
            ) else { return nil }
            defer { cursor = end }
            return String(path[cursor..<end])
        }
        guard let first = take(40), isRawAddress(first) else { return nil }
        var route = ["0x" + first.lowercased()]
        var fees: [UInt32] = []
        for _ in 0..<hopCount {
            guard let feeHex = take(6),
                  let fee = UInt32(feeHex, radix: 16),
                  fee > 0, fee <= 1_000_000,
                  let token = take(40), isRawAddress(token) else { return nil }
            fees.append(fee)
            route.append("0x" + token.lowercased())
        }
        return cursor == path.endIndex ? (route, fees) : nil
    }

    private static func singleBytesArray(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[", trimmed.last == "]" else { return nil }
        let inner = trimmed.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty, !inner.contains(","),
              inner.lowercased().hasPrefix("0x"),
              inner.dropFirst(2).count.isMultiple(of: 2),
              inner.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return inner
    }

    private static func normalizedDecimal(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 78,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func abiAddressWord(_ value: String) -> String? {
        guard isAddress(value) else { return nil }
        return String(repeating: "0", count: 24)
            + String(value.dropFirst(2)).lowercased()
    }

    private static func abiWord(decimal value: String) -> String? {
        guard let normalized = normalizedDecimal(value) else { return nil }
        var digits = normalized.utf8.map { Int($0 - 48) }
        var hexadecimal = ""
        repeat {
            var quotient: [Int] = []
            var remainder = 0
            for digit in digits {
                let next = remainder * 10 + digit
                if !quotient.isEmpty || next / 16 != 0 {
                    quotient.append(next / 16)
                }
                remainder = next % 16
            }
            hexadecimal.append(String(remainder, radix: 16))
            digits = quotient
        } while !digits.isEmpty
        guard hexadecimal.count <= 64 else { return nil }
        return String(repeating: "0", count: 64 - hexadecimal.count)
            + String(hexadecimal.reversed())
    }

    private static func decimal(fromABIWord word: String) -> String? {
        guard word.count == 64, word.allSatisfy(\.isHexDigit) else { return nil }
        var result = "0"
        for character in word.lowercased() {
            guard let digit = Int(String(character), radix: 16),
                  let next = multiplyAndAdd(
                    result, multiplier: 16, addend: digit
                  ) else { return nil }
            result = next
        }
        return result
    }

    private static func multiplyAndAdd(
        _ value: String, multiplier: Int, addend: Int
    ) -> String? {
        guard multiplier >= 0, addend >= 0, !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var carry = addend
        var digits: [Int] = []
        for character in value.reversed() {
            guard let digit = character.wholeNumberValue else { return nil }
            let total = digit * multiplier + carry
            digits.append(total % 10)
            carry = total / 10
        }
        while carry > 0 {
            digits.append(carry % 10)
            carry /= 10
        }
        return digits.reversed().map(String.init).joined()
    }

    private static func decimalLessThanOrEqual(
        _ lhs: String, _ rhs: String
    ) -> Bool {
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return lhs <= rhs
    }

    private static let maximumUInt256Decimal =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    private static func address(fromABIWord word: String) -> String? {
        guard word.count == 64,
              word.prefix(24).allSatisfy({ $0 == "0" }) else { return nil }
        let raw = String(word.suffix(40)).lowercased()
        return isRawAddress(raw) ? "0x" + raw : nil
    }

    private static func isRawAddress(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
            && value.contains(where: { $0 != "0" })
    }

    private static func isAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x")
            && isRawAddress(String(value.dropFirst(2)))
    }
}

struct WalletContractEncodingRequest: Codable, Equatable, Sendable {
    let action: WalletSemanticAction
    let registryEntry: WalletContractRegistryEntry
    var accountID: String? = nil
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

enum WalletSolanaTransactionVersion: String, Codable, Sendable {
    case legacy
    case v0
    case v1
}

struct WalletSolanaResolvedAccount: Codable, Equatable, Sendable {
    let address: String
    let isSigner: Bool
    let isWritable: Bool
    let lookupTableAddress: String?
    let lookupTableSlot: UInt64?
}

struct WalletSolanaReviewedInstruction: Codable, Equatable, Sendable {
    let programID: String
    let adapterID: String
    let semanticOperation: String
    let accounts: [WalletSolanaResolvedAccount]
    let canonicalArguments: [String: String]
}

struct WalletSolanaPreparationPacket: Codable, Equatable, Sendable {
    let request: WalletPrepareRequest
    let genesisHash: String
    let version: WalletSolanaTransactionVersion
    let recentBlockhash: String
    let lastValidBlockHeight: UInt64
    let contextSlot: UInt64
    let feePayer: String
    let computeUnitLimit: UInt32
    let computeUnitPriceMicroLamports: String
    let priorityFeeBaseUnits: String
    let feeQuoteBaseUnits: String
    let maximumFeeBaseUnits: String
    let canonicalMessageDigest: String
    let resolvedAccountsDigest: String
    let instructions: [WalletSolanaReviewedInstruction]
    let simulation: String
    let simulationSucceeded: Bool
    let observedAt: Date
}

struct WalletSolanaRecheckPacket: Codable, Equatable, Sendable {
    let intentID: String
    let genesisHash: String
    let currentBlockHeight: UInt64
    let resolvedAccountsDigest: String
    let feeQuoteBaseUnits: String
    let simulation: String
    let simulationSucceeded: Bool
    let observedAt: Date
}

struct WalletSolanaSignedTransaction: Codable, Equatable, Sendable {
    let intentID: String
    let transactionID: String
    let canonicalMessageDigest: String
    let signedTransaction: String
}

struct WalletSolanaAssociatedTokenRequest: Codable, Equatable, Sendable {
    let networkID: String
    let owner: String
    let mint: String
    let tokenProgramID: String
}

struct WalletSolanaAssociatedTokenAddress: Codable, Equatable, Sendable {
    let address: String
    let bump: UInt8
}

struct WalletSuiObjectReference: Codable, Equatable, Sendable {
    let objectID: String
    let version: UInt64
    let digest: String
    let type: String
}

struct WalletSuiPreparationPacket: Codable, Equatable, Sendable {
    let request: WalletPrepareRequest
    let chainIdentifier: String
    let checkpointSequence: UInt64
    let checkpointTimestamp: Date
    let sender: String
    let assetID: String
    let coinType: String
    let coinObject: WalletSuiObjectReference?
    let coinBalanceBaseUnits: String?
    let coinCheckpointSequence: UInt64?
    let coinCheckpointTimestamp: Date?
    let transferredObject: WalletSuiObjectReference?
    let objectHasPublicTransfer: Bool?
    let objectCheckpointSequence: UInt64?
    let objectCheckpointTimestamp: Date?
    let gasObject: WalletSuiObjectReference
    let gasBalanceBaseUnits: String
    let gasBudgetBaseUnits: String
    let referenceGasPriceBaseUnits: String
    let gasPriceBaseUnits: String
    let currentEpoch: UInt64
    let expirationEpoch: UInt64
    let observedAt: Date
}

struct WalletSuiUnsignedIntent: Codable, Equatable, Sendable {
    let prepared: WalletPreparedTransaction
    let transactionBCS: String
}

struct WalletSuiSimulationPacket: Codable, Equatable, Sendable {
    let intentID: String
    let chainIdentifier: String
    let checkpointSequence: UInt64
    let checkpointTimestamp: Date
    let currentEpoch: UInt64
    let referenceGasPriceBaseUnits: String
    let transactionDigest: String
    let effectsDigest: String
    let sender: String
    let recipient: String
    let assetID: String
    let coinType: String
    let coinObjectID: String?
    let transferredObjectInput: WalletSuiObjectReference?
    let transferredObjectOutput: WalletSuiObjectReference?
    let objectHasPublicTransfer: Bool?
    let amountBaseUnits: String
    let senderDebitBaseUnits: String
    let senderGasDebitBaseUnits: String?
    let recipientCreditBaseUnits: String
    let gasObjectID: String
    let computationCost: String
    let storageCost: String
    let storageRebate: String
    let nonRefundableStorageFee: String
    let actualFeeBaseUnits: String
    let observedAt: Date
}

struct WalletSuiRecheckPacket: Codable, Equatable, Sendable {
    let simulation: WalletSuiSimulationPacket
    let coinObject: WalletSuiObjectReference?
    let coinBalanceBaseUnits: String?
    let coinCheckpointSequence: UInt64?
    let coinCheckpointTimestamp: Date?
    let transferredObject: WalletSuiObjectReference?
    let objectHasPublicTransfer: Bool?
    let objectCheckpointSequence: UInt64?
    let objectCheckpointTimestamp: Date?
    let gasObject: WalletSuiObjectReference
    let gasBalanceBaseUnits: String
    let gasCheckpointSequence: UInt64
    let gasCheckpointTimestamp: Date
    let currentEpoch: UInt64
    let referenceGasPriceBaseUnits: String
}

struct WalletSuiSignedTransaction: Codable, Equatable, Sendable {
    let intentID: String
    let transactionDigest: String
    let transactionBytes: String
    let signature: String
}

enum WalletVaultState: String, Codable, Sendable {
    case missing
    case awaitingBackup
    case rotationRequired = "rotation_required"
    case locked
    case unlocked
}

struct WalletSignerStatus: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let vaultState: WalletVaultState
    let sessionID: String?
    let accounts: [WalletAccount]
    var recoveryOnlyVaultAvailable: Bool = false
}

enum WalletVaultCreationPurpose: String, Codable, Sendable {
    case create
    case rotateForMainnet = "rotate_for_mainnet"
}

enum WalletRecoveryCeremonyMode: String, Codable, Equatable, Sendable {
    case create
    case rotateForMainnet = "rotate_for_mainnet"
    case restore

    var creationPurpose: WalletVaultCreationPurpose? {
        switch self {
        case .create: .create
        case .rotateForMainnet: .rotateForMainnet
        case .restore: nil
        }
    }
}

struct WalletRecoveryCeremonyRequest: Codable, Equatable, Sendable {
    let mode: WalletRecoveryCeremonyMode
    var allowPresentationOverExistingVaultForUITesting = false
}

struct WalletRecoveryCeremonyHandle: Codable, Equatable, Sendable {
    let id: String
    let mode: WalletRecoveryCeremonyMode
}

enum WalletRecoveryCeremonyOutcome: String, Codable, Equatable, Sendable {
    case completed
    case canceled
    case failed
}

/// The only recovery-service result returned to the main Locus process. It
/// contains ceremony state and public account metadata, never phrase words or
/// entropy.
struct WalletRecoveryCeremonyResult: Codable, Equatable, Sendable {
    let ceremonyID: String
    let outcome: WalletRecoveryCeremonyOutcome
    let signerStatus: WalletSignerStatus?
    let error: String?
}

struct WalletSignerErrorPayload: Codable, Equatable, Sendable {
    let error: String
}

#if !LOCUS_APP_STORE
struct WalletReleaseActivationStatus: Codable, Equatable, Sendable {
    let revision: Int
    let envelopeSHA256: String
    let expiresAt: Date
    let enabledNetworkIDs: Set<String>
}
#endif

/// Code-signing requirements enforced by NSXPCConnection before either side
/// accepts privileged wallet messages. Foundation performs this check from the
/// connection's audit token, so sandboxed helpers never need to open and
/// inspect a peer executable by PID.
enum WalletXPCCodeSigningRequirement {
    static let hostApplication = requirement(identifier: "io.sparktales.locus")
    static let signerService = requirement(identifier: "io.sparktales.locus.WalletSigner")
    static let connectionService = requirement(
        identifier: "io.sparktales.locus.WalletConnections"
    )
    static let recoveryApplication = requirement(identifier: "io.sparktales.locus.WalletRecovery")
    static let signerBootstrapClient: String = {
        #if DEBUG
        return "(identifier \"io.sparktales.locus\" or identifier \"io.sparktales.locus.WalletRecovery\")"
        #else
        return "(identifier \"io.sparktales.locus\" or identifier \"io.sparktales.locus.WalletRecovery\") "
            + "and anchor apple generic and certificate leaf[subject.OU] = \"4X4RJA7GMD\""
        #endif
    }()

    private static func requirement(identifier: String) -> String {
        #if DEBUG
        // Contributor and CI debug builds may be ad-hoc signed. The embedded
        // service namespace still scopes lookup to this application bundle.
        return "identifier \"\(identifier)\""
        #else
        return "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"4X4RJA7GMD\""
        #endif
    }
}

enum WalletRecoveryProcessMessageKind: String, Codable, Equatable, Sendable {
    case start
    case cancel
    case presented
    case terminal
}

/// A bounded, status-only message used between Locus and WalletRecovery.app.
/// Only `start` may carry a ceremony mode; only `terminal` may carry a public
/// recovery result. Recovery words, entropy, and signer endpoints have no
/// representation in this protocol.
struct WalletRecoveryProcessMessage: Codable, Equatable, Sendable {
    static let protocolVersion = 1

    let protocolVersion: Int
    let invocationID: String
    let kind: WalletRecoveryProcessMessageKind
    let mode: WalletRecoveryCeremonyMode?
    let result: WalletRecoveryCeremonyResult?
    var allowPresentationOverExistingVaultForUITesting = false

    init(
        invocationID: String,
        kind: WalletRecoveryProcessMessageKind,
        mode: WalletRecoveryCeremonyMode? = nil,
        result: WalletRecoveryCeremonyResult? = nil,
        allowPresentationOverExistingVaultForUITesting: Bool = false
    ) {
        protocolVersion = Self.protocolVersion
        self.invocationID = invocationID
        self.kind = kind
        self.mode = mode
        self.result = result
        self.allowPresentationOverExistingVaultForUITesting =
            allowPresentationOverExistingVaultForUITesting
    }

    var isStructurallyValid: Bool {
        guard protocolVersion == Self.protocolVersion,
              UUID(uuidString: invocationID) != nil else { return false }
        switch kind {
        case .start:
            return mode != nil && result == nil
        case .cancel, .presented:
            return mode == nil && result == nil
        case .terminal:
            return mode == nil && result != nil
        }
    }
}

enum WalletRecoveryProcessFrameError: LocalizedError, Equatable {
    case empty
    case oversized
    case malformed

    var errorDescription: String? {
        switch self {
        case .empty: "The recovery helper sent an empty message."
        case .oversized: "The recovery helper sent an oversized message."
        case .malformed: "The recovery helper sent a malformed message."
        }
    }
}

struct WalletRecoveryProcessFrameDecoder {
    static let maximumPayloadBytes = 64 * 1_024
    private(set) var bufferedData = Data()

    static func encode(_ message: WalletRecoveryProcessMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty else { throw WalletRecoveryProcessFrameError.empty }
        guard payload.count <= maximumPayloadBytes else {
            throw WalletRecoveryProcessFrameError.oversized
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    mutating func append(_ data: Data) throws -> [WalletRecoveryProcessMessage] {
        bufferedData.append(data)
        var messages: [WalletRecoveryProcessMessage] = []
        while bufferedData.count >= MemoryLayout<UInt32>.size {
            let length = bufferedData.prefix(4).reduce(UInt32.zero) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0 else { throw WalletRecoveryProcessFrameError.empty }
            guard length <= Self.maximumPayloadBytes else {
                throw WalletRecoveryProcessFrameError.oversized
            }
            let frameLength = 4 + Int(length)
            guard bufferedData.count >= frameLength else { break }
            let payload = bufferedData.subdata(in: 4..<frameLength)
            bufferedData.removeSubrange(0..<frameLength)
            guard let message = try? JSONDecoder().decode(
                WalletRecoveryProcessMessage.self, from: payload
            ), message.isStructurallyValid else {
                throw WalletRecoveryProcessFrameError.malformed
            }
            messages.append(message)
        }
        guard bufferedData.count <= Self.maximumPayloadBytes + 4 else {
            throw WalletRecoveryProcessFrameError.oversized
        }
        return messages
    }
}

/// The Objective-C-compatible boundary uses Data, while every payload inside
/// that Data is a specific Codable type. NSDictionary is deliberately avoided:
/// selector spelling and allowed classes cannot silently widen the protocol.
@objc protocol WalletSignerXPCProtocol {
    func status(reply: @escaping (Data) -> Void)
    #if !LOCUS_APP_STORE
    func applyReleaseActivation(_ request: Data, reply: @escaping (Data) -> Void)
    func releaseAuthorityStatus(reply: @escaping (Data) -> Void)
    func applyReleaseHistory(_ request: Data, reply: @escaping (Data) -> Void)
    #endif
    func authorizeSession(_ reason: String, reply: @escaping (Data) -> Void)
    func listAccounts(reply: @escaping (Data) -> Void)
    func encodeEVMContract(_ request: Data, reply: @escaping (Data) -> Void)
    func signStructuredAuthorization(_ request: Data, reply: @escaping (Data) -> Void)
    func prepareEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func simulateEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func confirmEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func executeEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func prepareSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func simulateSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func confirmSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func executeSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func deriveSolanaAssociatedToken(
        _ request: Data, reply: @escaping (Data) -> Void
    )
    func prepareSui(_ request: Data, reply: @escaping (Data) -> Void)
    func simulateSui(_ request: Data, reply: @escaping (Data) -> Void)
    func confirmSui(_ request: Data, reply: @escaping (Data) -> Void)
    func executeSui(_ request: Data, reply: @escaping (Data) -> Void)
    func activatePolicy(_ request: Data, reply: @escaping (Data) -> Void)
    func listPolicies(_ request: Data, reply: @escaping (Data) -> Void)
    func clearPolicies(_ request: Data, reply: @escaping (Data) -> Void)
    func lock(reply: @escaping (Data) -> Void)
    func deleteVault(_ confirmation: String, reply: @escaping (Data) -> Void)
    func deleteRecoveryVault(_ confirmation: String, reply: @escaping (Data) -> Void)
}

/// The public service listener exports only this bootstrap interface. Each
/// method returns an anonymous endpoint which independently verifies the
/// caller before exposing its narrower privileged interface.
@objc protocol WalletSignerBootstrapXPCProtocol {
    func connectHost(reply: @escaping (NSXPCListenerEndpoint?) -> Void)
    func connectRecovery(reply: @escaping (NSXPCListenerEndpoint?) -> Void)
}

/// Recovery-only signer access. The main application cannot connect to this
/// endpoint because the anonymous listener requires WalletRecovery.app's
/// signature.
@objc protocol WalletRecoverySignerXPCProtocol {
    func status(reply: @escaping (Data) -> Void)
    func beginRecoveryCeremony(
        _ request: Data,
        reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void
    )
    func cancelRecoveryCeremony(_ ceremonyID: String, reply: @escaping (Data) -> Void)
    func lock(reply: @escaping (Data) -> Void)
}

/// This interface exists only on the signer's anonymous, one-time listener.
/// The listener accepts the signed WalletRecovery service and rejects Locus,
/// web content, agents, and unrelated local processes.
@objc protocol WalletRecoveryBrokerXPCProtocol {
    func creationMaterial(_ ceremonyID: String, reply: @escaping (Data) -> Void)
    func confirmBackup(
        _ ceremonyID: String, confirmation: Data, reply: @escaping (Data) -> Void
    )
    func restoreVault(
        _ ceremonyID: String, request: Data, reply: @escaping (Data) -> Void
    )
    func cancel(_ ceremonyID: String, reply: @escaping (Data) -> Void)
}
