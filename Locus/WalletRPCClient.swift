import CryptoKit
import Foundation

enum WalletRPCError: LocalizedError {
    case invalidEndpoint
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case wrongChain(String)
    case simulation(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The wallet RPC URL is not a valid HTTPS address."
        case .invalidResponse(let message): "The wallet RPC returned an invalid response: \(message)"
        case .rpc(_, let message): "Wallet RPC error: \(message)"
        case .wrongChain(let value): "The configured RPC returned the wrong chain identity: \(value)."
        case .simulation(let message): "Transaction simulation failed: \(message)"
        }
    }
}

enum WalletEthereumQuantity {
    static func decimalToHex(_ value: String) -> String? {
        guard var digits = WalletBaseUnits.normalize(value) else { return nil }
        if digits == "0" { return "0x0" }
        let alphabet = Array("0123456789abcdef")
        var result = ""
        while digits != "0" {
            var quotient = ""
            var remainder = 0
            for character in digits {
                guard let digit = character.wholeNumberValue else { return nil }
                let current = remainder * 10 + digit
                if !quotient.isEmpty || current / 16 > 0 {
                    quotient.append(String(current / 16))
                }
                remainder = current % 16
            }
            result.append(alphabet[remainder])
            digits = quotient.isEmpty ? "0" : quotient
        }
        return "0x" + String(result.reversed())
    }

    static func hexToDecimal(_ value: String) -> String? {
        let raw = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard !raw.isEmpty, raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        var result = "0"
        for character in raw.lowercased() {
            guard let digit = Int(String(character), radix: 16),
                  let shifted = WalletBaseUnits.multiply(result, "16"),
                  let next = WalletBaseUnits.add(shifted, String(digit)) else { return nil }
            result = next
        }
        return result
    }

    static func hexToUInt64(_ value: String) -> UInt64? {
        let raw = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(raw, radix: 16)
    }
}

actor WalletSepoliaRPCClient {
    static let defaultEndpoint = "https://ethereum-sepolia-rpc.publicnode.com"
    static let mainnetDefaultEndpoint = "https://ethereum-rpc.publicnode.com"
    static let chainID: UInt64 = 11_155_111

    private var endpoint: URL
    private let networkID: String
    private let networkName: String
    private let expectedChainID: UInt64
    private let session: URLSession
    private var nextID = 1

    init(endpoint: String = WalletSepoliaRPCClient.defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = Self.validatedEndpoint(endpoint)
            ?? URL(string: WalletSepoliaRPCClient.defaultEndpoint)!
        networkID = WalletNetworkCatalog.ethereumSepolia.canonicalID
        networkName = "Ethereum Sepolia"
        expectedChainID = Self.chainID
        self.session = session
    }

    init(
        network: WalletNetworkDescriptor,
        endpoint: String? = nil,
        session: URLSession = .shared
    ) throws {
        guard network.chain == .evm,
              network.identity.kind == .eip155ChainID,
              let chainID = UInt64(network.identity.value) else {
            throw WalletRPCError.wrongChain(network.identity.value)
        }
        let fallback = network.canonicalID == WalletNetworkCatalog.ethereumMainnet.canonicalID
            ? Self.mainnetDefaultEndpoint : Self.defaultEndpoint
        guard let resolved = Self.validatedEndpoint(endpoint ?? fallback) else {
            throw WalletRPCError.invalidEndpoint
        }
        self.endpoint = resolved
        networkID = network.canonicalID
        networkName = network.displayName
        expectedChainID = chainID
        self.session = session
    }

    #if DEBUG
    /// The only plain-HTTP construction path is compiled solely into Debug
    /// products for the isolated Anvil integration target. Production and
    /// Release builds contain no initializer that accepts loopback HTTP.
    init(testLoopbackEndpoint value: String, session: URLSession = .shared) throws {
        guard let url = URL(string: value), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            throw WalletRPCError.invalidEndpoint
        }
        endpoint = url
        networkID = WalletNetworkCatalog.ethereumSepolia.canonicalID
        networkName = "Ethereum Sepolia local validator"
        expectedChainID = Self.chainID
        self.session = session
    }
    #endif

    func configure(endpoint value: String) throws {
        guard let url = Self.validatedEndpoint(value) else { throw WalletRPCError.invalidEndpoint }
        endpoint = url
    }

    func health() async throws -> String {
        let chain = try await verifiedChainID()
        let block = try await stringResult(method: "eth_blockNumber")
        return "\(networkName) · chain \(chain) · block \(WalletEthereumQuantity.hexToDecimal(block) ?? block)"
    }

    func prepare(
        request: WalletPrepareRequest,
        fromAddress: String,
        contract: WalletContractRegistryEntry? = nil,
        encodedContract: WalletEncodedContractCall? = nil
    ) async throws -> WalletEVMPreparationPacket {
        guard request.networkID == networkID else {
            throw WalletRPCError.wrongChain(request.networkID)
        }
        let recipient: String
        let amount: String
        let input: String
        let observedRuntimeCodeHash: String?
        switch request.action.type {
        case .nativeTransfer:
            guard contract == nil, encodedContract == nil,
                  let requestedRecipient = request.action.recipient,
                  Self.isAddress(requestedRecipient),
                  let requestedAmount = request.action.amountBaseUnits.flatMap(WalletBaseUnits.normalize) else {
                throw WalletGateway.Error.invalidArguments("The native transfer is malformed.")
            }
            recipient = requestedRecipient
            amount = requestedAmount
            input = "0x"
            observedRuntimeCodeHash = nil
        case .contractCall:
            guard let contract, let encodedContract,
                  contract.networkID == request.networkID,
                  request.action.contractID == contract.id,
                  request.action.function.map(contract.permittedFunctions.contains) == true,
                  Self.isAddress(contract.checksumAddress),
                  encodedContract.input.hasPrefix("0x"), encodedContract.input.count >= 10,
                  let nativeValue = request.action.valueBaseUnits.flatMap(WalletBaseUnits.normalize) else {
                throw WalletGateway.Error.invalidArguments(
                    "The registered contract call is missing authoritative signer encoding."
                )
            }
            let currentCodeHash = try await runtimeCodeHash(address: contract.checksumAddress)
            guard currentCodeHash.caseInsensitiveCompare(contract.runtimeCodeHash) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The contract runtime code changed after registry approval."
                )
            }
            recipient = contract.checksumAddress
            amount = nativeValue
            input = encodedContract.input
            observedRuntimeCodeHash = currentCodeHash
        case .fungibleTokenTransfer, .nftTransfer:
            guard let contract, let encodedContract,
                  contract.networkID == request.networkID,
                  WalletEVMAssetAdapter.resolve(
                      action: request.action, registryEntry: contract,
                      accountAddress: fromAddress
                  ) != nil,
                  Self.isAddress(contract.checksumAddress),
                  encodedContract.input.hasPrefix("0x"), encodedContract.input.count >= 10 else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed token or NFT transfer is missing its verified standard adapter."
                )
            }
            let currentCodeHash = try await runtimeCodeHash(address: contract.checksumAddress)
            guard currentCodeHash.caseInsensitiveCompare(contract.runtimeCodeHash) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The asset contract runtime code changed after registry approval."
                )
            }
            recipient = contract.checksumAddress
            amount = "0"
            input = encodedContract.input
            observedRuntimeCodeHash = currentCodeHash
        case .exactInputSwap:
            guard let contract, let encodedContract,
                  contract.networkID == request.networkID,
                  request.action.contractID == contract.id,
                  request.action.adapterID
                    == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                  WalletReviewedAdapters.validatedID(for: contract)
                    == request.action.adapterID,
                  Self.isAddress(contract.checksumAddress),
                  encodedContract.input.hasPrefix("0x"),
                  encodedContract.input.count >= 10 else {
                throw WalletGateway.Error.invalidArguments(
                    "The exact-input swap is missing its reviewed router adapter."
                )
            }
            let currentCodeHash = try await runtimeCodeHash(
                address: contract.checksumAddress
            )
            guard currentCodeHash.caseInsensitiveCompare(
                contract.runtimeCodeHash
            ) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The swap router runtime code changed after registry approval."
                )
            }
            recipient = contract.checksumAddress
            amount = "0"
            input = encodedContract.input
            observedRuntimeCodeHash = currentCodeHash
        case .swapAllowanceSetup:
            guard let contract, let encodedContract,
                  contract.networkID == request.networkID,
                  request.action.contractID == contract.id,
                  request.action.swapAllowanceSetup != nil,
                  [WalletReviewedAdapters.erc20,
                   WalletReviewedAdapters.uniswapPermit2AllowanceSetup]
                    .contains(WalletReviewedAdapters.validatedID(for: contract)),
                  Self.isAddress(contract.checksumAddress),
                  encodedContract.input.hasPrefix("0x"),
                  encodedContract.input.count >= 10 else {
                throw WalletGateway.Error.invalidArguments(
                    "The allowance setup is missing its exact reviewed adapter."
                )
            }
            let currentCodeHash = try await runtimeCodeHash(
                address: contract.checksumAddress
            )
            guard currentCodeHash.caseInsensitiveCompare(
                contract.runtimeCodeHash
            ) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The allowance contract runtime code changed after registry approval."
                )
            }
            recipient = contract.checksumAddress
            amount = "0"
            input = encodedContract.input
            observedRuntimeCodeHash = currentCodeHash
        case .reviewedCall, .standardizedSignIn,
             .reviewedTypedAuthorization:
            throw WalletGateway.Error.invalidArguments(
                "This semantic action requires a reviewed chain adapter."
            )
        }
        _ = try await verifiedChainID()
        let nonceHex = try await stringResult(
            method: "eth_getTransactionCount", params: [fromAddress, "pending"]
        )
        guard let nonce = WalletEthereumQuantity.hexToUInt64(nonceHex) else {
            throw WalletRPCError.invalidResponse("invalid account nonce")
        }
        let fees = try await feeSuggestion()
        guard let valueHex = WalletEthereumQuantity.decimalToHex(amount),
              let maxFeeHex = WalletEthereumQuantity.decimalToHex(fees.maxFeePerGas),
              let priorityHex = WalletEthereumQuantity.decimalToHex(fees.priorityFeePerGas) else {
            throw WalletRPCError.invalidResponse("fee conversion failed")
        }
        var call: [String: Any] = [
            "from": fromAddress,
            "to": recipient,
            "value": valueHex,
            "data": input,
            "maxFeePerGas": maxFeeHex,
            "maxPriorityFeePerGas": priorityHex,
        ]
        _ = try await stringResult(method: "eth_call", params: [call, "pending"])
        let gasHex = try await stringResult(method: "eth_estimateGas", params: [call, "pending"])
        guard let estimatedGas = WalletEthereumQuantity.hexToUInt64(gasHex) else {
            throw WalletRPCError.invalidResponse("invalid gas estimate")
        }
        // A small deterministic buffer prevents a harmless state change between
        // simulation and submission from consuming the entire estimate.
        let gasLimit = estimatedGas.addingReportingOverflow(estimatedGas / 5)
        guard !gasLimit.overflow,
              let feeQuote = WalletBaseUnits.multiply(String(gasLimit.partialValue), fees.maxFeePerGas),
              WalletBaseUnits.lessThanOrEqual(feeQuote, request.maximumFeeBaseUnits) else {
            throw WalletGateway.Error.policyDenied("The simulated maximum fee exceeds the requested fee ceiling.")
        }
        call["gas"] = WalletEthereumQuantity.decimalToHex(String(gasLimit.partialValue))
        return WalletEVMPreparationPacket(
            request: request,
            fromAddress: fromAddress,
            transaction: WalletEVMTransactionFields(
                chainID: expectedChainID,
                nonce: nonce,
                gasLimit: gasLimit.partialValue,
                maxFeePerGas: fees.maxFeePerGas,
                maxPriorityFeePerGas: fees.priorityFeePerGas,
                to: recipient,
                value: amount,
                input: input
            ),
            feeQuoteBaseUnits: feeQuote,
            simulation: "eth_call succeeded; estimated gas \(estimatedGas)",
            simulationSucceeded: true,
            contractRegistryEntry: contract,
            encodedContractCall: encodedContract,
            observedRuntimeCodeHash: observedRuntimeCodeHash,
            observedAt: Date()
        )
    }

    func recheck(intentID: String, packet: WalletEVMPreparationPacket) async throws -> WalletEVMRecheckPacket {
        _ = try await verifiedChainID()
        let nonceHex = try await stringResult(
            method: "eth_getTransactionCount", params: [packet.fromAddress, "pending"]
        )
        guard let nonce = WalletEthereumQuantity.hexToUInt64(nonceHex) else {
            throw WalletRPCError.invalidResponse("invalid account nonce")
        }
        let transaction = packet.transaction
        let call: [String: Any] = [
            "from": packet.fromAddress,
            "to": transaction.to,
            "value": WalletEthereumQuantity.decimalToHex(transaction.value) ?? "",
            "data": transaction.input,
            "gas": WalletEthereumQuantity.decimalToHex(String(transaction.gasLimit)) ?? "",
            "maxFeePerGas": WalletEthereumQuantity.decimalToHex(transaction.maxFeePerGas) ?? "",
            "maxPriorityFeePerGas": WalletEthereumQuantity.decimalToHex(transaction.maxPriorityFeePerGas) ?? "",
        ]
        _ = try await stringResult(method: "eth_call", params: [call, "pending"])
        let gasHex = try await stringResult(method: "eth_estimateGas", params: [call, "pending"])
        guard let gas = WalletEthereumQuantity.hexToUInt64(gasHex), gas <= transaction.gasLimit,
              let feeQuote = WalletBaseUnits.multiply(
                  String(transaction.gasLimit), transaction.maxFeePerGas
              ) else {
            throw WalletRPCError.simulation("the refreshed gas estimate exceeds the prepared limit")
        }
        let observedRuntimeCodeHash: String?
        if let contract = packet.contractRegistryEntry {
            let current = try await runtimeCodeHash(address: contract.checksumAddress)
            guard current.caseInsensitiveCompare(contract.runtimeCodeHash) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The contract runtime code changed after transaction preparation."
                )
            }
            observedRuntimeCodeHash = current
        } else {
            observedRuntimeCodeHash = nil
        }
        return WalletEVMRecheckPacket(
            intentID: intentID,
            chainID: expectedChainID,
            pendingNonce: nonce,
            feeQuoteBaseUnits: feeQuote,
            simulation: "Refreshed eth_call succeeded; estimated gas \(gas)",
            simulationSucceeded: true,
            observedRuntimeCodeHash: observedRuntimeCodeHash,
            observedAt: Date()
        )
    }

    func broadcast(rawTransaction: String) async throws -> String {
        try await stringResult(method: "eth_sendRawTransaction", params: [rawTransaction])
    }

    func balance(address: String) async throws -> String {
        let value = try await stringResult(method: "eth_getBalance", params: [address, "latest"])
        guard let decimal = WalletEthereumQuantity.hexToDecimal(value) else {
            throw WalletRPCError.invalidResponse("invalid balance")
        }
        return decimal
    }

    func assetBalance(identity: WalletEVMAssetIdentity, address: String) async throws -> String {
        guard identity.networkID == networkID, Self.isAddress(address) else {
            throw WalletGateway.Error.invalidArguments("The EVM asset balance request is malformed.")
        }
        _ = try await verifiedChainID()
        let data: String
        switch identity.standard {
        case .erc20:
            data = "0x70a08231" + Self.addressWord(address)
        case .erc721:
            if let tokenID = identity.tokenID {
                data = "0x6352211e" + (try Self.unsignedWord(tokenID))
                let owner = try await stringResult(
                    method: "eth_call",
                    params: [["to": identity.contractAddress, "data": data], "latest"]
                )
                guard let resolvedOwner = Self.addressFromABIResult(owner) else {
                    throw WalletRPCError.invalidResponse("ERC-721 ownerOf returned an invalid address")
                }
                return resolvedOwner.caseInsensitiveCompare(address) == .orderedSame ? "1" : "0"
            }
            data = "0x70a08231" + Self.addressWord(address)
        case .erc1155:
            guard let tokenID = identity.tokenID else {
                throw WalletGateway.Error.invalidArguments("An ERC-1155 balance requires a token ID.")
            }
            data = "0x00fdd58e" + Self.addressWord(address) + (try Self.unsignedWord(tokenID))
        }
        let result = try await stringResult(
            method: "eth_call",
            params: [["to": identity.contractAddress, "data": data], "latest"]
        )
        guard result.count <= 66,
              let decimal = WalletEthereumQuantity.hexToDecimal(result) else {
            throw WalletRPCError.invalidResponse("The token balance is not one ABI uint256 value")
        }
        return decimal
    }

    func tokenBalances(
        provider: WalletProviderKind,
        address: String
    ) async throws -> [WalletEVMDiscoveredAsset] {
        guard provider == .alchemy, Self.isAddress(address) else {
            throw WalletProviderCoordinatorError.noProvider(networkID)
        }
        _ = try await verifiedChainID()
        var pageKey: String?
        var seenPageKeys: Set<String> = []
        var seenContracts: Set<String> = []
        var assets: [WalletEVMDiscoveredAsset] = []
        for _ in 0..<50 {
            var options: [String: Any] = ["maxCount": 100]
            if let pageKey { options["pageKey"] = pageKey }
            let result = try await rpc(
                method: "alchemy_getTokenBalances",
                params: [address, "erc20", options]
            )
            guard let object = result as? [String: Any],
                  let returnedAddress = object["address"] as? String,
                  returnedAddress.caseInsensitiveCompare(address) == .orderedSame,
                  let balances = object["tokenBalances"] as? [[String: Any]],
                  balances.count <= 100 else {
                throw WalletRPCError.invalidResponse(
                    "alchemy_getTokenBalances returned a malformed page"
                )
            }
            for balance in balances {
                guard balance["error"] == nil || balance["error"] is NSNull,
                      let contract = balance["contractAddress"] as? String,
                      Self.isAddress(contract),
                      seenContracts.insert(contract.lowercased()).inserted,
                      let quantity = balance["tokenBalance"] as? String,
                      quantity.count <= 66, quantity.hasPrefix("0x"),
                      quantity.dropFirst(2).allSatisfy(\.isHexDigit),
                      let baseUnits = WalletEthereumQuantity.hexToDecimal(quantity),
                      let identity = WalletEVMAssetIdentity.parse(
                          "\(networkID)/erc20:\(contract.lowercased())"
                      ) else {
                    throw WalletRPCError.invalidResponse(
                        "alchemy_getTokenBalances returned malformed token evidence"
                    )
                }
                if baseUnits != "0" {
                    assets.append(WalletEVMDiscoveredAsset(
                        identity: identity, balanceBaseUnits: baseUnits
                    ))
                }
            }
            guard assets.count <= 5_000 else {
                throw WalletRPCError.invalidResponse(
                    "alchemy_getTokenBalances exceeded the wallet asset limit"
                )
            }
            if object["pageKey"] == nil || object["pageKey"] is NSNull {
                return assets.sorted { $0.id < $1.id }
            }
            guard let next = object["pageKey"] as? String,
                  !next.isEmpty, next.utf8.count <= 512,
                  next.unicodeScalars.allSatisfy({
                      $0.isASCII && $0.value >= 0x21 && $0.value != 0x7f
                  }), seenPageKeys.insert(next).inserted else {
                throw WalletRPCError.invalidResponse(
                    "alchemy_getTokenBalances returned an invalid page key"
                )
            }
            pageKey = next
        }
        throw WalletRPCError.invalidResponse(
            "alchemy_getTokenBalances pagination was truncated"
        )
    }

    func nftBalances(
        provider: WalletProviderKind,
        address: String
    ) async throws -> WalletEVMNFTSnapshot {
        guard provider == .alchemy, Self.isAddress(address) else {
            throw WalletProviderCoordinatorError.noProvider(networkID)
        }
        _ = try await verifiedChainID()
        var pageKey: String?
        var seenPageKeys: Set<String> = []
        var seenAssets: Set<String> = []
        var assets: [WalletEVMDiscoveredAsset] = []
        var snapshotBlock: UInt64?
        var snapshotHash: String?
        var expectedTotal: UInt64?
        for _ in 0..<50 {
            guard let url = alchemyNFTURL(owner: address, pageKey: pageKey) else {
                throw WalletProviderCoordinatorError.noProvider(networkID)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 1_048_576,
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  object["error"] == nil,
                  let owned = object["ownedNfts"] as? [[String: Any]],
                  owned.count <= 100,
                  let validAt = object["validAt"] as? [String: Any],
                  let blockNumber = Self.exactUInt64(validAt["blockNumber"]),
                  let blockHash = Self.validHash(validAt["blockHash"]),
                  let total = Self.exactUInt64(object["totalCount"]),
                  total <= 1_000_000 else {
                throw WalletRPCError.invalidResponse(
                    "Alchemy NFT ownership returned malformed snapshot evidence"
                )
            }
            if let snapshotBlock {
                guard snapshotBlock == blockNumber,
                      snapshotHash?.caseInsensitiveCompare(blockHash) == .orderedSame,
                      expectedTotal == total else {
                    throw WalletRPCError.invalidResponse(
                        "Alchemy NFT ownership changed during pagination"
                    )
                }
            } else {
                snapshotBlock = blockNumber
                snapshotHash = blockHash.lowercased()
                expectedTotal = total
            }
            for item in owned {
                guard let contract = item["contract"] as? [String: Any],
                      let contractAddress = contract["address"] as? String,
                      Self.isAddress(contractAddress),
                      let rawType = item["tokenType"] as? String,
                      contract["tokenType"] as? String == rawType,
                      let standard = Self.nftStandard(rawType),
                      let tokenID = item["tokenId"] as? String,
                      let balance = item["balance"] as? String,
                      let normalizedBalance = WalletBaseUnits.normalize(balance),
                      normalizedBalance == balance, normalizedBalance != "0",
                      standard != .erc721 || normalizedBalance == "1",
                      let identity = WalletEVMAssetIdentity.parse(
                          "\(networkID)/\(standard.rawValue):\(contractAddress.lowercased())/\(tokenID)"
                      ), identity.tokenID == tokenID,
                      seenAssets.insert(identity.canonicalID).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "Alchemy NFT ownership returned malformed asset evidence"
                    )
                }
                assets.append(WalletEVMDiscoveredAsset(
                    identity: identity, balanceBaseUnits: normalizedBalance
                ))
            }
            guard assets.count <= 5_000 else {
                throw WalletRPCError.invalidResponse(
                    "Alchemy NFT ownership exceeded the wallet asset limit"
                )
            }
            if object["pageKey"] == nil || object["pageKey"] is NSNull {
                guard UInt64(assets.count) <= total,
                      let snapshotBlock, let snapshotHash else {
                    throw WalletRPCError.invalidResponse(
                        "Alchemy NFT ownership returned inconsistent totals"
                    )
                }
                return WalletEVMNFTSnapshot(
                    assets: assets.sorted { $0.id < $1.id },
                    blockNumber: snapshotBlock, blockHash: snapshotHash
                )
            }
            guard let next = object["pageKey"] as? String,
                  !next.isEmpty, next.utf8.count <= 512,
                  next.unicodeScalars.allSatisfy({
                      $0.isASCII && $0.value >= 0x21 && $0.value != 0x7f
                  }), seenPageKeys.insert(next).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Alchemy NFT ownership returned an invalid page key"
                )
            }
            pageKey = next
        }
        throw WalletRPCError.invalidResponse(
            "Alchemy NFT ownership pagination was truncated"
        )
    }

    func indexedTransfers(
        provider: WalletProviderKind,
        address: String,
        limit: Int = 250
    ) async throws -> [WalletEVMIndexedTransfer] {
        guard Self.isAddress(address), (1...500).contains(limit) else {
            throw WalletGateway.Error.invalidArguments(
                "The indexed activity request is malformed."
            )
        }
        _ = try await verifiedChainID()
        switch provider {
        case .alchemy:
            return try await alchemyTransfers(address: address, limit: limit)
        case .quickNode:
            return try await quickNodeNativeTransfers(address: address, limit: limit)
        case .userDefined, .local:
            throw WalletProviderCoordinatorError.noProvider(networkID)
        }
    }

    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry {
        guard draft.networkID == networkID, Self.isAddress(draft.address),
              !draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.id.count <= 128,
              !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.label.count <= 128,
              !draft.permittedFunctions.isEmpty, draft.permittedFunctions.count <= 64,
              draft.abiJSON.utf8.count <= 256 * 1024 else {
            throw WalletGateway.Error.invalidArguments(
                "A network-bound registry ID, contract address, label, ABI, and at least one canonical function are required."
            )
        }
        _ = try await verifiedChainID()
        guard let abiData = draft.abiJSON.data(using: .utf8),
              JSONSerialization.isValidJSONObject(try JSONSerialization.jsonObject(with: abiData)) else {
            throw WalletGateway.Error.invalidArguments("The contract ABI must be valid JSON.")
        }
        let abiObject = try JSONSerialization.jsonObject(with: abiData)
        let normalizedABIData = try JSONSerialization.data(
            withJSONObject: abiObject, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let normalizedABI = String(data: normalizedABIData, encoding: .utf8) else {
            throw WalletGateway.Error.invalidArguments("The contract ABI could not be normalized.")
        }
        let abiDigest = "sha256:" + SHA256.hash(data: normalizedABIData)
            .map { String(format: "%02x", $0) }.joined()
        let checksumAddress = try await checksumAddress(draft.address)
        let runtimeCodeHash = try await runtimeCodeHash(address: checksumAddress)
        let functions = Array(Set(draft.permittedFunctions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !functions.isEmpty, functions.allSatisfy(Self.isCanonicalFunctionSignature) else {
            throw WalletGateway.Error.invalidArguments(
                "Permitted methods must use canonical signatures such as transfer(address,uint256)."
            )
        }
        var selectors: [String] = []
        for function in functions {
            let encoded = "0x" + function.utf8.map { String(format: "%02x", $0) }.joined()
            let digest = try await stringResult(method: "web3_sha3", params: [encoded])
            guard digest.count == 66 else {
                throw WalletRPCError.invalidResponse("web3_sha3 returned an invalid selector digest")
            }
            selectors.append(String(digest.prefix(10)).lowercased())
        }
        let reviewedAdapterID = WalletReviewedAdapters.classify(
            normalizedABI: normalizedABI, permittedFunctions: functions
        )
        if let requestedAdapterID = draft.reviewedAdapterID,
           requestedAdapterID != reviewedAdapterID {
            throw WalletGateway.Error.invalidArguments(
                "The requested adapter does not match the verified ABI and permitted methods."
            )
        }
        return WalletContractRegistryEntry(
            id: draft.id.trimmingCharacters(in: .whitespacesAndNewlines),
            networkID: draft.networkID,
            checksumAddress: checksumAddress,
            label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedABI: normalizedABI,
            abiDigest: abiDigest,
            runtimeCodeHash: runtimeCodeHash.lowercased(),
            permittedFunctions: functions,
            permittedSelectors: selectors,
            reviewedAdapterID: reviewedAdapterID,
            verifiedAt: Date()
        )
    }

    func publicRead(method: String, params: [Any]) async throws -> Any {
        let allowed = Set([
            "eth_blockNumber", "eth_getBalance", "eth_getCode",
            "eth_getBlockByNumber",
            "eth_getTransactionByHash", "eth_getTransactionReceipt",
            "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_feeHistory",
        ])
        guard allowed.contains(method), params.count <= 4 else {
            throw WalletGateway.Error.invalidArguments("That browser RPC method is not supported.")
        }
        _ = try await verifiedChainID()
        return try await rpc(method: method, params: params)
    }

    func runtimeCodeHash(address: String) async throws -> String {
        let code = try await stringResult(method: "eth_getCode", params: [address, "latest"])
        guard code != "0x", code != "0x0" else {
            throw WalletGateway.Error.invalidArguments("No runtime bytecode exists at that network address.")
        }
        return try await stringResult(method: "web3_sha3", params: [code]).lowercased()
    }

    private func alchemyTransfers(
        address: String,
        limit: Int
    ) async throws -> [WalletEVMIndexedTransfer] {
        var values: [WalletEVMIndexedTransfer] = []
        for direction in ["fromAddress", "toAddress"] {
            var pageKey: String?
            repeat {
                var parameters: [String: Any] = [
                    "fromBlock": "0x0",
                    "toBlock": "latest",
                    direction: address,
                    "category": ["external", "internal", "erc20", "erc721", "erc1155"],
                    "withMetadata": true,
                    "excludeZeroValue": false,
                    "order": "desc",
                    "maxCount": "0x64",
                ]
                if let pageKey { parameters["pageKey"] = pageKey }
                let result = try await rpc(
                    method: "alchemy_getAssetTransfers", params: [parameters]
                )
                guard let object = result as? [String: Any],
                      let transfers = object["transfers"] as? [[String: Any]],
                      transfers.count <= 100 else {
                    throw WalletRPCError.invalidResponse(
                        "alchemy_getAssetTransfers returned a malformed page"
                    )
                }
                for transfer in transfers {
                    values.append(contentsOf: Self.parseAlchemyTransfer(
                        transfer, networkID: networkID
                    ))
                    if values.count >= limit * 2 { break }
                }
                pageKey = object["pageKey"] as? String
                if pageKey?.isEmpty == true { pageKey = nil }
                if pageKey?.count ?? 0 > 512 {
                    throw WalletRPCError.invalidResponse(
                        "alchemy_getAssetTransfers returned an invalid page key"
                    )
                }
            } while pageKey != nil && values.count < limit * 2
        }
        return Self.deduplicated(values, limit: limit)
    }

    private func quickNodeNativeTransfers(
        address: String,
        limit: Int
    ) async throws -> [WalletEVMIndexedTransfer] {
        let native = WalletNetworkCatalog.descriptor(id: networkID)
        var transfers: [WalletEVMIndexedTransfer] = []
        var page = 1
        var totalPages = 1
        repeat {
            let result = try await rpc(
                method: "qn_getTransactionsByAddress",
                params: [["address": address, "page": page, "perPage": min(limit, 100)]]
            )
            guard let object = result as? [String: Any],
                  let items = object["paginatedItems"] as? [[String: Any]],
                  items.count <= 100 else {
                throw WalletRPCError.invalidResponse(
                    "qn_getTransactionsByAddress returned a malformed page"
                )
            }
            if let count = object["totalPages"] as? NSNumber,
               CFGetTypeID(count) != CFBooleanGetTypeID() {
                totalPages = min(max(1, count.intValue), 5)
            }
            transfers.append(contentsOf: items.compactMap { item -> WalletEVMIndexedTransfer? in
                guard item["contractAddress"] == nil
                        || (item["contractAddress"] as? String)?.isEmpty == true,
                      let hash = Self.validHash(item["transactionHash"]),
                      let block = Self.normalizedBlock(item["blockNumber"]),
                      let from = item["fromAddress"] as? String, Self.isAddress(from),
                      let to = item["toAddress"] as? String, Self.isAddress(to),
                      let amount = Self.normalizedProviderAmount(item["value"]),
                      let date = Self.providerDate(item["blockTimestamp"]) else { return nil }
                return WalletEVMIndexedTransfer(
                    id: "\(hash):native", transactionHash: hash,
                    blockNumber: block, occurredAt: date,
                    from: from.lowercased(), to: to.lowercased(),
                    assetID: native?.nativeAssetID ?? "\(networkID)/slip44:60",
                    amountBaseUnits: amount, assetKind: .native,
                    assetReference: nil, assetName: native?.displayName ?? "Native asset",
                    assetSymbol: native?.nativeSymbol ?? "ETH",
                    assetDecimals: native?.nativeDecimals
                )
            })
            page += 1
        } while page <= totalPages && transfers.count < limit
        return Self.deduplicated(transfers, limit: limit)
    }

    private static func parseAlchemyTransfer(
        _ item: [String: Any],
        networkID: String
    ) -> [WalletEVMIndexedTransfer] {
        guard let hash = validHash(item["hash"]),
              let block = normalizedBlock(item["blockNum"]),
              let from = item["from"] as? String, isAddress(from),
              let to = item["to"] as? String, isAddress(to),
              let category = item["category"] as? String,
              let date = providerDate((item["metadata"] as? [String: Any])?["blockTimestamp"])
        else { return [] }
        let raw = item["rawContract"] as? [String: Any] ?? [:]
        let contract = (raw["address"] as? String)?.lowercased()
        let symbol = sanitizedMetadata(item["asset"], fallback: "UNKNOWN", limit: 32)
        let unique = sanitizedMetadata(item["uniqueId"], fallback: hash, limit: 256)
        let native = WalletNetworkCatalog.descriptor(id: networkID)
        if category == "external" || category == "internal" {
            guard let amount = normalizedProviderAmount(raw["value"]) else { return [] }
            return [WalletEVMIndexedTransfer(
                id: unique, transactionHash: hash, blockNumber: block,
                occurredAt: date, from: from.lowercased(), to: to.lowercased(),
                assetID: native?.nativeAssetID ?? "\(networkID)/slip44:60",
                amountBaseUnits: amount, assetKind: .native,
                assetReference: nil, assetName: native?.displayName ?? "Native asset",
                assetSymbol: native?.nativeSymbol ?? symbol,
                assetDecimals: native?.nativeDecimals
            )]
        }
        guard let contract, isAddress(contract) else { return [] }
        if category == "erc20" {
            guard let amount = normalizedProviderAmount(raw["value"]) else { return [] }
            let decimals = normalizedProviderInteger(raw["decimal"]).flatMap(Int.init)
            return [WalletEVMIndexedTransfer(
                id: unique, transactionHash: hash, blockNumber: block,
                occurredAt: date, from: from.lowercased(), to: to.lowercased(),
                assetID: "\(networkID)/erc20:\(contract)",
                amountBaseUnits: amount, assetKind: .fungibleToken,
                assetReference: contract, assetName: "Unknown token",
                assetSymbol: symbol, assetDecimals: decimals
            )]
        }
        if category == "erc721" {
            guard let tokenID = normalizedProviderInteger(
                item["tokenId"] ?? item["erc721TokenId"]
            ) else { return [] }
            return [WalletEVMIndexedTransfer(
                id: unique, transactionHash: hash, blockNumber: block,
                occurredAt: date, from: from.lowercased(), to: to.lowercased(),
                assetID: "\(networkID)/erc721:\(contract)/\(tokenID)",
                amountBaseUnits: "1", assetKind: .nft,
                assetReference: contract, assetName: "Unknown collectible",
                assetSymbol: symbol, assetDecimals: nil
            )]
        }
        if category == "erc1155",
           let metadata = item["erc1155Metadata"] as? [[String: Any]],
           metadata.count <= 100 {
            return metadata.enumerated().compactMap { index, value in
                guard let tokenID = normalizedProviderInteger(value["tokenId"]),
                      let amount = normalizedProviderAmount(value["value"]) else { return nil }
                return WalletEVMIndexedTransfer(
                    id: "\(unique):\(index)", transactionHash: hash,
                    blockNumber: block, occurredAt: date,
                    from: from.lowercased(), to: to.lowercased(),
                    assetID: "\(networkID)/erc1155:\(contract)/\(tokenID)",
                    amountBaseUnits: amount, assetKind: .nft,
                    assetReference: contract, assetName: "Unknown collectible",
                    assetSymbol: symbol, assetDecimals: nil
                )
            }
        }
        return []
    }

    private static func deduplicated(
        _ values: [WalletEVMIndexedTransfer],
        limit: Int
    ) -> [WalletEVMIndexedTransfer] {
        var seen: Set<String> = []
        return values.sorted { $0.occurredAt > $1.occurredAt }.filter {
            seen.insert($0.id).inserted
        }.prefix(limit).map { $0 }
    }

    private static func validHash(_ value: Any?) -> String? {
        guard let value = value as? String, value.count == 66,
              value.hasPrefix("0x"), value.dropFirst(2).allSatisfy(\.isHexDigit) else {
            return nil
        }
        return value.lowercased()
    }

    private static func exactUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.decimalValue >= 0,
              number.decimalValue == Decimal(number.uint64Value) else { return nil }
        return number.uint64Value
    }

    private static func nftStandard(_ value: String) -> WalletEVMAssetStandard? {
        switch value {
        case "ERC721": .erc721
        case "ERC1155": .erc1155
        default: nil
        }
    }

    private static func normalizedBlock(_ value: Any?) -> String? {
        normalizedProviderInteger(value)
    }

    private static func normalizedProviderAmount(_ value: Any?) -> String? {
        normalizedProviderInteger(value)
    }

    private static func normalizedProviderInteger(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        if text.lowercased().hasPrefix("0x") {
            return WalletEthereumQuantity.hexToDecimal(text)
        }
        return WalletBaseUnits.normalize(text)
    }

    private static func providerDate(_ value: Any?) -> Date? {
        guard let value = value as? String, value.count <= 64 else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func sanitizedMetadata(
        _ value: Any?, fallback: String, limit: Int
    ) -> String {
        guard let value = value as? String else { return fallback }
        let sanitized = value.unicodeScalars.filter {
            ($0.value >= 0x20 && $0.value != 0x7f) || $0.value == 0x09
        }.prefix(limit)
        let result = String(String.UnicodeScalarView(sanitized))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    private func checksumAddress(_ value: String) async throws -> String {
        let lowercase = String(value.dropFirst(2)).lowercased()
        let encoded = "0x" + lowercase.utf8.map { String(format: "%02x", $0) }.joined()
        let digest = try await stringResult(method: "web3_sha3", params: [encoded])
        return try Self.checksummedAddress(value, keccakHash: digest)
    }

    private func alchemyNFTURL(owner: String, pageKey: String?) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host.hasSuffix(".alchemy.com"),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2, path[0] == "v2" else { return nil }
        let apiKey = String(path[1])
        guard !apiKey.isEmpty, apiKey.utf8.count <= 512,
              apiKey.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                    || (97...122).contains(byte) || byte == 45 || byte == 95
              }) else { return nil }
        components.path = "/nft/v3/\(apiKey)/getNFTsForOwner"
        var items = [
            URLQueryItem(name: "owner", value: owner),
            URLQueryItem(name: "withMetadata", value: "false"),
            URLQueryItem(name: "pageSize", value: "100"),
        ]
        if let pageKey {
            items.append(URLQueryItem(name: "pageKey", value: pageKey))
        }
        components.queryItems = items
        return components.url
    }

    static func checksummedAddress(_ value: String, keccakHash digest: String) throws -> String {
        guard isAddress(value) else {
            throw WalletGateway.Error.invalidArguments("The contract address is malformed.")
        }
        let lowercase = String(value.dropFirst(2)).lowercased()
        let hash = String(digest.dropFirst(2)).lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw WalletRPCError.invalidResponse("web3_sha3 returned an invalid address checksum")
        }
        let checksum = zip(lowercase, hash).map { addressCharacter, hashCharacter -> Character in
            guard addressCharacter.isLetter,
                  let nibble = Int(String(hashCharacter), radix: 16), nibble >= 8 else {
                return addressCharacter
            }
            return Character(String(addressCharacter).uppercased())
        }
        return "0x" + String(checksum)
    }

    private static func addressWord(_ address: String) -> String {
        String(repeating: "0", count: 24) + address.dropFirst(2).lowercased()
    }

    private static func unsignedWord(_ decimal: String) throws -> String {
        guard let encoded = WalletEthereumQuantity.decimalToHex(decimal) else {
            throw WalletGateway.Error.invalidArguments("The token ID is not an unsigned integer.")
        }
        let raw = String(encoded.dropFirst(2))
        guard raw.count <= 64 else {
            throw WalletGateway.Error.invalidArguments("The token ID exceeds uint256.")
        }
        return String(repeating: "0", count: 64 - raw.count) + raw
    }

    private static func addressFromABIResult(_ value: String) -> String? {
        let raw = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard raw.count == 64, raw.prefix(24).allSatisfy({ $0 == "0" }),
              raw.suffix(40).allSatisfy(\.isHexDigit) else { return nil }
        return "0x" + String(raw.suffix(40))
    }

    private func verifiedChainID() async throws -> UInt64 {
        let value = try await stringResult(method: "eth_chainId")
        guard let chain = WalletEthereumQuantity.hexToUInt64(value) else {
            throw WalletRPCError.invalidResponse("invalid chain ID")
        }
        guard chain == expectedChainID else { throw WalletRPCError.wrongChain(String(chain)) }
        return chain
    }

    private func feeSuggestion() async throws -> (maxFeePerGas: String, priorityFeePerGas: String) {
        let block = try await dictionaryResult(method: "eth_getBlockByNumber", params: ["latest", false])
        guard let baseHex = block["baseFeePerGas"] as? String,
              let base = WalletEthereumQuantity.hexToDecimal(baseHex) else {
            throw WalletRPCError.invalidResponse("latest block has no base fee")
        }
        let priorityHex: String
        do { priorityHex = try await stringResult(method: "eth_maxPriorityFeePerGas") }
        catch { priorityHex = "0x3b9aca00" } // 1 gwei, only if this optional RPC method is absent.
        guard let priority = WalletEthereumQuantity.hexToDecimal(priorityHex),
              let doubledBase = WalletBaseUnits.multiply(base, "2"),
              let maxFee = WalletBaseUnits.add(doubledBase, priority) else {
            throw WalletRPCError.invalidResponse("fee suggestion is malformed")
        }
        return (maxFee, priority)
    }

    private func stringResult(method: String, params: [Any] = []) async throws -> String {
        let result = try await rpc(method: method, params: params)
        guard let value = result as? String else {
            throw WalletRPCError.invalidResponse("\(method) did not return a string")
        }
        return value
    }

    private func dictionaryResult(method: String, params: [Any]) async throws -> [String: Any] {
        let result = try await rpc(method: method, params: params)
        guard let value = result as? [String: Any] else {
            throw WalletRPCError.invalidResponse("\(method) did not return an object")
        }
        return value
    }

    private func rpc(method: String, params: [Any]) async throws -> Any {
        let id = nextID
        nextID = nextID == Int.max ? 1 : nextID + 1
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        guard body.count <= 256 * 1024 else {
            throw WalletRPCError.invalidResponse("request exceeded the 256 KiB wallet limit")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WalletRPCError.invalidResponse("HTTP request failed")
        }
        guard data.count <= 1_048_576 else {
            throw WalletRPCError.invalidResponse("response exceeded the 1 MiB wallet limit")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WalletRPCError.invalidResponse("response is not JSON-RPC")
        }
        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              CFGetTypeID(responseID) != CFBooleanGetTypeID(),
              responseID.decimalValue == Decimal(id) else {
            throw WalletRPCError.invalidResponse("JSON-RPC version or response ID did not match the request")
        }
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw WalletRPCError.invalidResponse("response must contain exactly one of result or error")
        }
        if hasError {
            guard let error = object["error"] as? [String: Any],
                  let code = error["code"] as? NSNumber,
                  CFGetTypeID(code) != CFBooleanGetTypeID(),
                  code.decimalValue == Decimal(code.intValue),
                  let rawMessage = error["message"] as? String else {
                throw WalletRPCError.invalidResponse("error payload was malformed")
            }
            let message = String(rawMessage.prefix(512))
            throw WalletRPCError.rpc(
                code: code.intValue,
                message: message
            )
        }
        guard let result = object["result"] else {
            throw WalletRPCError.invalidResponse("result payload was missing")
        }
        return result
    }

    private static func validatedEndpoint(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private static func isAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func isCanonicalFunctionSignature(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace),
              let open = value.firstIndex(of: "("), value.last == ")", open != value.startIndex else {
            return false
        }
        let name = value[..<open]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
