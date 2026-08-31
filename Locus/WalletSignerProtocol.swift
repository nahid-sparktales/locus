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
    case fungibleTokenTransfer = "fungible_token_transfer"
    case nftTransfer = "nft_transfer"
    case exactInputSwap = "exact_input_swap"
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
        inputAssetID: String,
        outputAssetID: String,
        amountInBaseUnits: String,
        minimumOutputBaseUnits: String,
        recipient: String
    ) -> Self {
        Self(
            type: .exactInputSwap, recipient: recipient,
            amountBaseUnits: amountInBaseUnits, contractID: nil, function: nil,
            arguments: [], valueBaseUnits: nil, inputAssetID: inputAssetID,
            outputAssetID: outputAssetID,
            minimumOutputBaseUnits: minimumOutputBaseUnits, adapterID: adapterID
        )
    }
}

struct WalletPrepareRequest: Codable, Equatable, Sendable {
    let networkID: String
    let accountID: String
    let source: WalletRequestSource
    let action: WalletSemanticAction
    let maximumFeeBaseUnits: String
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
    static let erc20 = "erc20-v1"
    static let erc721SafeTransfer = "erc721-safe-transfer-v1"
    static let erc1155SafeTransfer = "erc1155-safe-transfer-v1"
    static let uniswapUniversalRouterV2ExactIn =
        "uniswap-universal-router-v2-exact-in-v1"
    static let staticallySupportedIDs: Set<String> = [
        ethereumNativeTransfer, solanaNativeTransfer,
        erc20, erc721SafeTransfer, erc1155SafeTransfer,
        uniswapUniversalRouterV2ExactIn,
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
            return uniswapUniversalRouterV2ExactIn
        }
        return nil
    }

    static func validatedID(for entry: WalletContractRegistryEntry) -> String? {
        guard let claimed = entry.reviewedAdapterID,
              claimed == classify(
                normalizedABI: entry.normalizedABI,
                permittedFunctions: entry.permittedFunctions
              ) else { return nil }
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

struct WalletUniversalRouterV2Swap: Equatable, Sendable {
    let inputAssetID: String
    let outputAssetID: String
    let amountIn: String
    let minimumAmountOut: String
    let recipient: String
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
            inputAssetID: "\(networkID)/erc20:\(path[0].lowercased())",
            outputAssetID: "\(networkID)/erc20:\(path[path.count - 1].lowercased())",
            amountIn: amountIn, minimumAmountOut: minimumOut, recipient: recipient
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

struct WalletSuiObjectReference: Codable, Equatable, Sendable {
    let objectID: String
    let version: UInt64
    let digest: String
    let type: String
}

struct WalletSuiReviewedCommand: Codable, Equatable, Sendable {
    let adapterID: String
    let packageID: String
    let module: String
    let function: String
    let typeArguments: [String]
    let canonicalArguments: [String: String]
}

struct WalletSuiPreparationPacket: Codable, Equatable, Sendable {
    let request: WalletPrepareRequest
    let chainIdentifier: String
    let sender: String
    let gasObjects: [WalletSuiObjectReference]
    let inputObjects: [WalletSuiObjectReference]
    let commands: [WalletSuiReviewedCommand]
    let gasBudgetBaseUnits: String
    let gasPriceBaseUnits: String
    let simulation: String
    let simulationSucceeded: Bool
    let expectedEffectsDigest: String
    let observedAt: Date
}

struct WalletSuiRecheckPacket: Codable, Equatable, Sendable {
    let intentID: String
    let chainIdentifier: String
    let objectReferences: [WalletSuiObjectReference]
    let gasPriceBaseUnits: String
    let simulation: String
    let simulationSucceeded: Bool
    let effectsDigest: String
    let observedAt: Date
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

/// The Objective-C-compatible boundary uses Data, while every payload inside
/// that Data is a specific Codable type. NSDictionary is deliberately avoided:
/// selector spelling and allowed classes cannot silently widen the protocol.
@objc protocol WalletSignerXPCProtocol {
    func status(reply: @escaping (Data) -> Void)
    func beginRecoveryCeremony(
        _ request: Data,
        reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void
    )
    func cancelRecoveryCeremony(_ ceremonyID: String, reply: @escaping (Data) -> Void)
    func authorizeSession(_ reason: String, reply: @escaping (Data) -> Void)
    func listAccounts(reply: @escaping (Data) -> Void)
    func encodeEVMContract(_ request: Data, reply: @escaping (Data) -> Void)
    func prepareEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func simulateEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func confirmEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func executeEVM(_ request: Data, reply: @escaping (Data) -> Void)
    func prepareSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func simulateSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func confirmSolana(_ request: Data, reply: @escaping (Data) -> Void)
    func executeSolana(_ request: Data, reply: @escaping (Data) -> Void)
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

/// The main app may only ask the isolated view service to present a ceremony.
/// Secret inputs and phrase display stay in that process and travel directly
/// to the signer broker endpoint.
@objc protocol WalletRecoveryServiceXPCProtocol {
    func presentCeremony(
        _ handle: Data,
        signerEndpoint: NSXPCListenerEndpoint,
        reply: @escaping (Data) -> Void
    )
}
