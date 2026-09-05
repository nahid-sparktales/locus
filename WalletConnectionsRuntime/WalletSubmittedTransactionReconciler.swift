import CryptoKit
import Foundation

enum WalletSubmittedTransactionReconciliation: Equatable, Sendable {
    case pending
    case confirmed(blockNumber: String, finalized: Bool)
    case failed(String)
}

/// Fetches connector-submitted transactions from an independently configured
/// public provider and proves their finalized semantics match the exact action
/// retained in the public activity record. A transaction is never promoted to
/// successful merely because its identifier exists or its receipt says success.
enum WalletSubmittedTransactionReconciler {
    static func reconcile(
        transactionID: String,
        networkID: String,
        account: WalletAccount,
        expectedAction: WalletSemanticAction,
        expectedSemanticDigest: String,
        expectedContractAddress: String? = nil,
        expectedEVMTransactionDigest: String? = nil,
        expectedEVMMaximumFeeBaseUnits: String? = nil,
        reviewRegistry: WalletReviewRegistry? = nil,
        bundle: Bundle = .main,
        session: URLSession = .shared
    ) async throws -> WalletSubmittedTransactionReconciliation {
        guard account.ownership.connectorID != nil,
              account.networkIDs.contains(networkID),
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.chain == account.chain,
              try semanticDigest(expectedAction) == expectedSemanticDigest else {
            throw WalletConnectionProtocolError.bindingMismatch
        }
        switch network.chain {
        case .evm:
            guard let expectedEVMTransactionDigest, isDigest(expectedEVMTransactionDigest),
                  let expectedEVMMaximumFeeBaseUnits else {
                throw WalletRPCError.invalidResponse("The reviewed EVM transaction commitment is unavailable; this activity cannot be confirmed.")
            }
            return try await evm(
                transactionID: transactionID, network: network,
                account: account, expectedAction: expectedAction,
                expectedTransactionDigest: expectedEVMTransactionDigest,
                expectedMaximumFeeBaseUnits: expectedEVMMaximumFeeBaseUnits,
                expectedContractAddress: expectedContractAddress, reviewRegistry: reviewRegistry, bundle: bundle,
                session: session
            )
        case .solana:
            return try await solana(
                transactionID: transactionID, network: network,
                account: account, expectedAction: expectedAction, bundle: bundle,
                session: session
            )
        case .sui:
            return try await sui(
                transactionID: transactionID, network: network,
                account: account, expectedAction: expectedAction, bundle: bundle,
                session: session
            )
        }
    }

    private static func evm(
        transactionID: String,
        network: WalletNetworkDescriptor,
        account: WalletAccount,
        expectedAction: WalletSemanticAction,
        expectedTransactionDigest: String,
        expectedMaximumFeeBaseUnits: String,
        expectedContractAddress: String?,
        reviewRegistry: WalletReviewRegistry?,
        bundle: Bundle,
        session: URLSession
    ) async throws -> WalletSubmittedTransactionReconciliation {
        guard transactionID.count == 66, transactionID.hasPrefix("0x"),
              transactionID.dropFirst(2).allSatisfy(\.isHexDigit),
              let configuration = WalletBundledProviderConfiguration.ethereum(
                network: network, bundle: bundle
              ) else {
            throw WalletGateway.Error.invalidArguments(
                "The external EVM transaction identifier or provider is invalid."
            )
        }
        let coordinator = try WalletEVMProviderCoordinator(
            network: network, configuration: configuration, session: session
        )
        let raw = try await coordinator.publicRead(
            method: "eth_getTransactionByHash", params: [transactionID]
        )
        if raw is NSNull { return .pending }
        let receiptRaw = try await coordinator.publicRead(
            method: "eth_getTransactionReceipt", params: [transactionID]
        )
        if receiptRaw is NSNull { return .pending }
        guard let transaction = raw as? [String: Any],
              let receipt = receiptRaw as? [String: Any] else {
            throw WalletRPCError.invalidResponse("The submitted EVM evidence is malformed.")
        }
        let review = reviewRegistry ?? WalletReviewRegistry.loadBundled(from: bundle)
        let reviewedSwapConfiguration = expectedAction.contractID.flatMap {
            review?.uniswapConfiguration(
                networkID: network.id, universalRouterContractID: $0
            )
        }
        let result = try reconcileEVMObservedTransaction(
            transactionID: transactionID, network: network, account: account,
            expectedAction: expectedAction, expectedContractAddress: expectedContractAddress,
            transaction: transaction, receipt: receipt,
            expectedEVMTransactionDigest: expectedTransactionDigest,
            expectedEVMMaximumFeeBaseUnits: expectedMaximumFeeBaseUnits,
            uniswapConfiguration: reviewedSwapConfiguration
        )
        if case .confirmed = result, expectedAction.type != .nativeTransfer {
            guard let review, let block = receipt["blockNumber"] as? String,
                  let target = transaction["to"] as? String else {
                throw WalletRPCError.invalidResponse("Reviewed settlement code identities are unavailable.")
            }
            var identities: [String: String] = [:]
            var contractAddresses = [target.lowercased()]
            if let route = expectedAction.swapRoute {
                contractAddresses += route.pathAssetIDs.compactMap {
                    WalletEVMAssetIdentity.parse($0)?.contractAddress.lowercased()
                }
                guard let reviewedSwapConfiguration else {
                    throw WalletRPCError.invalidResponse("Reviewed swap settlement identities are unavailable.")
                }
                for pool in reviewedSwapConfiguration.pools where route.pathAssetIDs.contains(pool.token0AssetID)
                    && route.pathAssetIDs.contains(pool.token1AssetID) {
                    identities[pool.address.lowercased()] = pool.runtimeCodeHash
                }
            }
            for address in contractAddresses {
                let entries = review.evmContracts.filter {
                    $0.networkID == network.id && $0.checksumAddress.lowercased() == address
                }
                guard entries.count == 1, let entry = entries.first else {
                    throw WalletRPCError.invalidResponse("A settlement token or target is missing its exact reviewed code identity.")
                }
                identities[address] = entry.runtimeCodeHash
            }
            guard identities.count <= 16 else {
                throw WalletRPCError.invalidResponse("Settlement code identity evidence is excessive.")
            }
            for (address, expected) in identities.sorted(by: { $0.key < $1.key }) {
                let rawCode = try await coordinator.publicRead(method: "eth_getCode", params: [address, block])
                guard let text = rawCode as? String, let code = codeBytes(text),
                      "0x" + WalletKeccak256.hash(code).map({ String(format: "%02x", $0) }).joined() == expected.lowercased() else {
                    throw WalletRPCError.invalidResponse("Settlement code changed from its reviewed identity.")
                }
            }
        }
        if case .confirmed = result {
            guard let block = receipt["blockNumber"] as? String,
                  let mined = try await coordinator.publicRead(
                    method: "eth_getBlockByNumber", params: [block, false]
                  ) as? [String: Any],
                  mined["hash"] as? String == receipt["blockHash"] as? String,
                  mined["number"] as? String == block,
                  let hashes = mined["transactions"] as? [String], hashes.count <= 4096,
                  hashes.filter({ $0.lowercased() == transactionID.lowercased() }).count == 1 else {
                throw WalletRPCError.invalidResponse("The mined transaction is no longer in the observed canonical block.")
            }
        }
        return result
    }

    /// Pure verification over a single mined transaction and its receipt. The
    /// optional commitment is a fixture seam for existing effect-only tests;
    /// the production entry point above always requires and supplies it. It
    /// deliberately does not infer effects from block-wide balance differences:
    /// another transaction in the same block must never satisfy this request.
    static func reconcileEVMObservedTransaction(
        transactionID: String,
        network: WalletNetworkDescriptor,
        account: WalletAccount,
        expectedAction: WalletSemanticAction,
        expectedContractAddress: String?,
        transaction: [String: Any],
        receipt: [String: Any],
        expectedEVMTransactionDigest: String? = nil,
        expectedEVMMaximumFeeBaseUnits: String? = nil,
        uniswapConfiguration: WalletReviewedUniswapConfiguration? = nil
    ) throws -> WalletSubmittedTransactionReconciliation {
        guard network.chain == .evm, account.chain == .evm,
              account.networkIDs.contains(network.id),
              transaction.count <= 32,
              let hash = transaction["hash"] as? String,
              isHash(hash),
              hash.caseInsensitiveCompare(transactionID) == .orderedSame,
              let from = transaction["from"] as? String,
              from.caseInsensitiveCompare(account.address) == .orderedSame,
              let to = transaction["to"] as? String,
              abiAddressWord(to) != nil,
              let value = transaction["value"] as? String,
              let input = transaction["input"] as? String,
              let chainID = transaction["chainId"] as? String,
              WalletEthereumQuantity.hexToDecimal(chainID) == network.identity.value else {
            throw WalletRPCError.invalidResponse(
                "The submitted EVM transaction response is malformed."
            )
        }
        let submitted = WalletConnectorDappRequest.EVMTransaction(
            from: from, to: to, valueHex: value, dataHex: input
        )
        let matches: Bool
        switch expectedAction.type {
        case .exactInputSwap:
            matches = expectedContractAddress.map {
                to.caseInsensitiveCompare($0) == .orderedSame
            } == true && WalletDappTransactionDecoder.evmUniversalRouterSwap(
                submitted, networkID: network.id, account: account,
                routerContractID: expectedAction.contractID ?? "",
                routerAddress: expectedContractAddress ?? "",
                now: expectedAction.swapRoute?.quoteEvidence?.quotedAt ?? Date()
            ).map { raw in
                guard let route = expectedAction.swapRoute else { return false }
                return raw.protocolVersion == route.protocolVersion
                    && raw.pathAssetIDs == route.pathAssetIDs
                    && raw.feeTiers == route.feeTiers
                    && raw.minimumHopPriceX36 == route.minimumHopPriceX36
                    && raw.deadlineUnixSeconds == route.deadlineUnixSeconds
                    && raw.inputAssetID == expectedAction.inputAssetID
                    && raw.outputAssetID == expectedAction.outputAssetID
                    && raw.amountIn == expectedAction.amountBaseUnits
                    && raw.minimumAmountOut
                        == expectedAction.minimumOutputBaseUnits
                    && raw.recipient.caseInsensitiveCompare(
                        expectedAction.recipient ?? ""
                    ) == .orderedSame
            } == true
        case .swapAllowanceSetup:
            matches = expectedContractAddress.map {
                to.caseInsensitiveCompare($0) == .orderedSame
            } == true && WalletEthereumQuantity.hexToDecimal(value) == "0"
                && allowanceCalldataMatches(
                input, expectedAction: expectedAction
            )
        default:
            let actual = try WalletDappTransactionDecoder.evm(
                submitted, networkID: network.id, account: account
            )
            matches = actionsMatch(expectedAction, actual, chain: .evm)
        }
        guard matches else {
            return .failed("The finalized EVM transaction does not match the reviewed action.")
        }
        if expectedEVMTransactionDigest != nil || expectedEVMMaximumFeeBaseUnits != nil {
            guard let expectedEVMTransactionDigest, let expectedEVMMaximumFeeBaseUnits,
                  try evmCommitmentMatches(transaction: transaction, receipt: receipt,
                    digest: expectedEVMTransactionDigest, maximumFeeBaseUnits: expectedEVMMaximumFeeBaseUnits) else {
                return .failed("The EVM nonce, transaction fields or fee effects changed from exact review.")
            }
        }
        guard receipt.count <= 32,
              let receiptHash = receipt["transactionHash"] as? String,
              receiptHash.caseInsensitiveCompare(transactionID) == .orderedSame,
              (receipt["from"] as? String)?.caseInsensitiveCompare(from) == .orderedSame,
              (receipt["to"] as? String)?.caseInsensitiveCompare(to) == .orderedSame,
              let status = receipt["status"] as? String,
              let block = receipt["blockNumber"] as? String,
              WalletEthereumQuantity.hexToUInt64(block) != nil,
              transaction["blockNumber"] as? String == block,
              let blockHash = receipt["blockHash"] as? String, isHash(blockHash),
              transaction["blockHash"] as? String == blockHash,
              let index = receipt["transactionIndex"] as? String,
              WalletEthereumQuantity.hexToUInt64(index) != nil,
              transaction["transactionIndex"] as? String == index else {
            throw WalletRPCError.invalidResponse("The submitted EVM receipt is malformed.")
        }
        guard status.lowercased() == "0x1" else {
            return .failed("The external EVM transaction reverted.")
        }
        let logs = try receiptLogs(
            receipt, transactionID: transactionID, block: block,
            blockHash: blockHash, transactionIndex: index
        )
        guard evmEffectsMatch(
            logs, account: account.address, action: expectedAction,
            contractAddress: to, configuration: uniswapConfiguration
        ) else {
            return .failed("The EVM receipt does not prove the exact reviewed transaction effects.")
        }
        return .confirmed(blockNumber: block, finalized: false)
    }

    private struct EVMLog: Equatable {
        let address: String
        let topics: [String]
        let words: [String]
    }

    /// Public reconciliation evidence only: callers retain this digest and the
    /// reviewed maximum fee, never this input transaction or unsigned bytes.
    static func evmTransactionCommitment(
        _ fields: WalletExternalEVMTransaction,
        maximumFeeBaseUnits: String
    ) throws -> String {
        struct Commitment: Encodable {
            let domain = "locus-reviewed-external-evm-transaction-v1"
            let transactionType = 2
            let from: String
            let to: String
            let chainID: String
            let nonce: String
            let value: String
            let calldataSHA256: String
            let gasLimit: String
            let maxFeePerGas: String
            let maxPriorityFeePerGas: String
            let maximumFeeBaseUnits: String
            let accessList: [String] = []
        }
        guard abiAddressWord(fields.from) != nil, abiAddressWord(fields.to) != nil,
              let chainID = canonicalQuantity(fields.chainIDHex),
              let nonce = canonicalQuantity(fields.nonceHex), UInt64(nonce) != nil,
              let value = canonicalQuantity(fields.valueHex),
              let gas = canonicalQuantity(fields.gasHex), let gasLimit = UInt64(gas), gasLimit > 0,
              let maximumFee = canonicalQuantity(fields.maxFeePerGasHex),
              let priority = canonicalQuantity(fields.maxPriorityFeePerGasHex),
              WalletBaseUnits.lessThanOrEqual(priority, maximumFee),
              maximumFeeBaseUnits.count <= 78,
              WalletBaseUnits.normalize(maximumFeeBaseUnits) == maximumFeeBaseUnits,
              maximumFeeBaseUnits != "0",
              let maximumCost = WalletBaseUnits.multiply(gas, maximumFee),
              WalletBaseUnits.lessThanOrEqual(maximumCost, maximumFeeBaseUnits),
              fields.dataHex.count <= 256 * 1024 + 2,
              let calldata = fields.dataHex == "0x" ? Data() : codeBytes(fields.dataHex) else {
            throw WalletRPCError.invalidResponse("The reviewed EVM transaction commitment is malformed or exceeds its maximum fee.")
        }
        let commitment = Commitment(from: fields.from.lowercased(), to: fields.to.lowercased(),
            chainID: chainID, nonce: nonce, value: value,
            calldataSHA256: SHA256.hash(data: calldata).map { String(format: "%02x", $0) }.joined(),
            gasLimit: gas, maxFeePerGas: maximumFee, maxPriorityFeePerGas: priority,
            maximumFeeBaseUnits: maximumFeeBaseUnits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(commitment)).map { String(format: "%02x", $0) }.joined()
    }

    private static func evmCommitmentMatches(
        transaction: [String: Any], receipt: [String: Any],
        digest: String, maximumFeeBaseUnits: String
    ) throws -> Bool {
        guard isDigest(digest), transaction["type"] as? String == "0x2",
              let accessList = transaction["accessList"] as? [Any], accessList.isEmpty,
              transaction["authorizationList"] == nil, transaction["blobVersionedHashes"] == nil,
              transaction["maxFeePerBlobGas"] == nil,
              let from = transaction["from"] as? String, let to = transaction["to"] as? String,
              let value = transaction["value"] as? String, let data = transaction["input"] as? String,
              let gas = transaction["gas"] as? String, let maximum = transaction["maxFeePerGas"] as? String,
              let priority = transaction["maxPriorityFeePerGas"] as? String,
              let nonce = transaction["nonce"] as? String, let chain = transaction["chainId"] as? String else { return false }
        let fields = WalletExternalEVMTransaction(from: from, to: to, valueHex: value, dataHex: data,
            gasHex: gas, maxFeePerGasHex: maximum, maxPriorityFeePerGasHex: priority,
            nonceHex: nonce, chainIDHex: chain)
        guard try evmTransactionCommitment(fields, maximumFeeBaseUnits: maximumFeeBaseUnits) == digest,
              let gasLimit = canonicalQuantity(gas),
              let maximumFee = canonicalQuantity(maximum),
              let usedHex = receipt["gasUsed"] as? String, let used = canonicalQuantity(usedHex), used != "0",
              let effectiveHex = receipt["effectiveGasPrice"] as? String,
              let effective = canonicalQuantity(effectiveHex),
              WalletBaseUnits.lessThanOrEqual(used, gasLimit),
              WalletBaseUnits.lessThanOrEqual(effective, maximumFee),
              let total = WalletBaseUnits.multiply(used, effective),
              WalletBaseUnits.lessThanOrEqual(total, maximumFeeBaseUnits) else { return false }
        if let gasPrice = transaction["gasPrice"] {
            guard let text = gasPrice as? String, canonicalQuantity(text) == effective else { return false }
        }
        return true
    }

    private static func canonicalQuantity(_ value: String) -> String? {
        guard value.hasPrefix("0x"), (3...66).contains(value.count),
              let decimal = WalletEthereumQuantity.hexToDecimal(value),
              let canonical = WalletEthereumQuantity.decimalToHex(decimal),
              canonical == value.lowercased() else { return nil }
        return decimal
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private struct TokenMovement: Equatable {
        let token: String
        let from: String
        let to: String
        let amount: String
    }

    private static func event(_ signature: String) -> String {
        "0x" + WalletKeccak256.hash(Data(signature.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static let transferEvent = event("Transfer(address,address,uint256)")
    private static let approvalEvent = event("Approval(address,address,uint256)")
    private static let singleEvent = event("TransferSingle(address,address,address,uint256,uint256)")
    private static let batchEvent = event("TransferBatch(address,address,address,uint256[],uint256[])")
    private static let permit2ApprovalEvent = event("Approval(address,address,address,uint160,uint48)")
    private static let v2SwapEvent = event("Swap(address,uint256,uint256,uint256,uint256,address)")
    private static let v3SwapEvent = event("Swap(address,address,int256,int256,uint160,uint128,int24)")

    private static func isHash(_ value: String) -> Bool {
        value.count == 66 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func codeBytes(_ value: String) -> Data? {
        guard value.hasPrefix("0x"), value.count > 2, value.count <= 512 * 1024 + 2,
              value.dropFirst(2).count.isMultiple(of: 2) else { return nil }
        let text = value.dropFirst(2)
        var data = Data()
        var index = text.startIndex
        while index != text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    private static func receiptLogs(
        _ receipt: [String: Any], transactionID: String,
        block: String, blockHash: String, transactionIndex: String
    ) throws -> [EVMLog] {
        guard let raw = receipt["logs"] as? [[String: Any]], raw.count <= 256 else {
            throw WalletRPCError.invalidResponse("The EVM receipt has missing or excessive logs.")
        }
        var seen: Set<UInt64> = []
        var previous: UInt64?
        var byteCount = 0
        return try raw.map { log in
            guard log.count <= 16,
                  let address = log["address"] as? String, abiAddressWord(address) != nil,
                  let topics = log["topics"] as? [String], (1...4).contains(topics.count),
                  topics.allSatisfy(isHash),
                  let data = log["data"] as? String, data.hasPrefix("0x"),
                  data.dropFirst(2).count.isMultiple(of: 64),
                  data.dropFirst(2).allSatisfy(\.isHexDigit),
                  let removed = log["removed"] as? NSNumber,
                  CFGetTypeID(removed) == CFBooleanGetTypeID(), !removed.boolValue,
                  (log["transactionHash"] as? String)?.caseInsensitiveCompare(transactionID) == .orderedSame,
                  log["blockHash"] as? String == blockHash,
                  log["blockNumber"] as? String == block,
                  log["transactionIndex"] as? String == transactionIndex,
                  let indexText = log["logIndex"] as? String,
                  let index = WalletEthereumQuantity.hexToUInt64(indexText),
                  seen.insert(index).inserted,
                  previous.map({ index > $0 }) ?? true else {
                throw WalletRPCError.invalidResponse("An EVM event was malformed, replayed or bound to another transaction.")
            }
            byteCount += data.utf8.count + topics.count * 66
            guard byteCount <= 128 * 1024 else {
                throw WalletRPCError.invalidResponse("EVM receipt event data is excessive.")
            }
            previous = index
            let body = data.dropFirst(2).lowercased()
            let words = stride(from: 0, to: body.count, by: 64).map { offset in
                let start = body.index(body.startIndex, offsetBy: offset)
                return String(body[start..<body.index(start, offsetBy: 64)])
            }
            return EVMLog(address: address.lowercased(), topics: topics.map { $0.lowercased() }, words: words)
        }
    }

    private static func topicAddress(_ value: String) -> String? {
        guard isHash(value), value.dropFirst(2).prefix(24) == String(repeating: "0", count: 24) else { return nil }
        return "0x" + value.suffix(40).lowercased()
    }

    private static func decimalWord(_ value: String) -> String? {
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return WalletEthereumQuantity.hexToDecimal("0x" + value)
    }

    private static func evmEffectsMatch(
        _ logs: [EVMLog], account: String, action: WalletSemanticAction,
        contractAddress: String, configuration: WalletReviewedUniswapConfiguration?
    ) -> Bool {
        let account = account.lowercased()
        let target = contractAddress.lowercased()
        let transfers = logs.filter { isTransferEvent($0.topics.first) }
        switch action.type {
        case .nativeTransfer:
            return transfers.isEmpty
        case .fungibleTokenTransfer:
            guard transfers.count == 1, let movement = tokenMovement(transfers[0]) else { return false }
            return movement == TokenMovement(token: target, from: account,
                to: action.recipient?.lowercased() ?? "", amount: action.amountBaseUnits ?? "")
        case .nftTransfer:
            guard transfers.count == 1, let log = transfers.first,
                  log.address == target, let identity = action.assetID.flatMap(WalletEVMAssetIdentity.parse),
                  let tokenID = action.tokenID else { return false }
            if identity.standard == .erc721 {
                return log.topics.count == 4 && log.words.isEmpty && log.topics[0] == transferEvent
                    && topicAddress(log.topics[1]) == account
                    && topicAddress(log.topics[2]) == action.recipient?.lowercased()
                    && decimalWord(String(log.topics[3].dropFirst(2))) == tokenID
            }
            return identity.standard == .erc1155 && log.topics.count == 4 && log.words.count == 2
                && log.topics[0] == singleEvent && topicAddress(log.topics[1]) == account
                && topicAddress(log.topics[2]) == account
                && topicAddress(log.topics[3]) == action.recipient?.lowercased()
                && decimalWord(log.words[0]) == tokenID && decimalWord(log.words[1]) == "1"
        case .swapAllowanceSetup:
            guard transfers.isEmpty, let setup = action.swapAllowanceSetup else { return false }
            let approvals = logs.filter { $0.topics.first == approvalEvent || $0.topics.first == permit2ApprovalEvent }
            guard approvals.count == 1, let log = approvals.first, log.address == target else { return false }
            if setup.stage != .permit2ToUniversalRouter {
                return log.topics.count == 3 && log.words.count == 1 && log.topics[0] == approvalEvent
                    && topicAddress(log.topics[1]) == account
                    && topicAddress(log.topics[2]) == setup.binding.permit2Address.lowercased()
                    && decimalWord(log.words[0]) == setup.approvalAmountBaseUnits
            }
            return log.topics.count == 4 && log.words.count == 2 && log.topics[0] == permit2ApprovalEvent
                && topicAddress(log.topics[1]) == account
                && topicAddress(log.topics[2]) == WalletEVMAssetIdentity.parse(setup.binding.inputAssetID)?.contractAddress.lowercased()
                && topicAddress(log.topics[3]) == setup.binding.universalRouterAddress.lowercased()
                && decimalWord(log.words[0]) == setup.approvalAmountBaseUnits
                && decimalWord(log.words[1]) == setup.expirationUnixSeconds
        case .exactInputSwap:
            return swapEffectsMatch(logs, account: account, action: action, router: target, configuration: configuration)
        default:
            return false
        }
    }

    private static func tokenMovement(_ log: EVMLog) -> TokenMovement? {
        guard log.topics.count == 3, log.topics[0] == transferEvent, log.words.count == 1,
              let from = topicAddress(log.topics[1]), let to = topicAddress(log.topics[2]),
              let amount = decimalWord(log.words[0]) else { return nil }
        return .init(token: log.address, from: from, to: to, amount: amount)
    }

    private static func isTransferEvent(_ topic: String?) -> Bool {
        topic == transferEvent || topic == singleEvent || topic == batchEvent
    }

    private static func signedWord(_ word: String) -> (negative: Bool, magnitude: String)? {
        guard let value = decimalWord(word), let first = word.first,
              let high = UInt8(String(first), radix: 16) else { return nil }
        if high < 8 { return (false, value) }
        guard let magnitude = WalletBaseUnits.subtract(
            "115792089237316195423570985008687907853269984665640564039457584007913129639936", value
        ) else { return nil }
        return (true, magnitude)
    }

    private static func swapEffectsMatch(
        _ logs: [EVMLog], account: String, action: WalletSemanticAction,
        router: String, configuration: WalletReviewedUniswapConfiguration?
    ) -> Bool {
        guard let route = action.swapRoute, let configuration,
              configuration.universalRouterContractID == action.contractID,
              configuration.contract(.universalRouter)?.address.lowercased() == router,
              (2...4).contains(route.pathAssetIDs.count),
              Set(route.pathAssetIDs).count == route.pathAssetIDs.count,
              route.minimumHopPriceX36.count == route.pathAssetIDs.count - 1,
              route.protocolVersion == .v2 ? route.feeTiers.isEmpty : route.feeTiers.count == route.pathAssetIDs.count - 1,
              let amount = action.amountBaseUnits, let minimum = action.minimumOutputBaseUnits,
              let recipient = action.recipient?.lowercased() else { return false }
        var pools: [WalletReviewedUniswapPoolIdentity] = []
        let tokens = route.pathAssetIDs.compactMap { WalletEVMAssetIdentity.parse($0)?.contractAddress.lowercased() }
        guard tokens.count == route.pathAssetIDs.count else { return false }
        for hop in 0..<(tokens.count - 1) {
            let candidates = configuration.pools.filter {
                $0.protocolVersion == route.protocolVersion
                    && Set([$0.token0AssetID, $0.token1AssetID]) == Set([route.pathAssetIDs[hop], route.pathAssetIDs[hop + 1]])
                    && (route.protocolVersion == .v2 || $0.feeTier == route.feeTiers[hop])
            }
            guard candidates.count == 1, let pool = candidates.first else { return false }
            pools.append(pool)
        }
        let swaps = logs.filter { $0.topics.first == v2SwapEvent || $0.topics.first == v3SwapEvent }
        guard swaps.count == pools.count else { return false }
        var expectedMovements: [TokenMovement] = []
        var input = amount
        for hop in pools.indices {
            let pool = pools[hop]
            let events = swaps.filter { $0.address == pool.address.lowercased() }
            guard events.count == 1, let log = events.first, log.topics.count == 3,
                  topicAddress(log.topics[1]) == router else { return false }
            let to = hop == pools.count - 1 ? recipient
                : (route.protocolVersion == .v2 ? pools[hop + 1].address.lowercased() : router)
            guard topicAddress(log.topics[2]) == to else { return false }
            let zeroForOne = pool.token0AssetID == route.pathAssetIDs[hop]
            let output: String
            if route.protocolVersion == .v2 {
                guard log.topics[0] == v2SwapEvent, log.words.count == 4,
                      decimalWord(log.words[zeroForOne ? 0 : 1]) == input,
                      decimalWord(log.words[zeroForOne ? 1 : 0]) == "0",
                      decimalWord(log.words[zeroForOne ? 2 : 3]) == "0",
                      let received = decimalWord(log.words[zeroForOne ? 3 : 2]) else { return false }
                output = received
            } else {
                guard log.topics[0] == v3SwapEvent, log.words.count == 5,
                      let debit = signedWord(log.words[zeroForOne ? 0 : 1]), !debit.negative, debit.magnitude == input,
                      let credit = signedWord(log.words[zeroForOne ? 1 : 0]), credit.negative else { return false }
                output = credit.magnitude
            }
            guard output != "0",
                  let outputScaled = WalletBaseUnits.multiply(output, "1" + String(repeating: "0", count: 36)),
                  let inputFloor = WalletBaseUnits.multiply(input, route.minimumHopPriceX36[hop]),
                  WalletBaseUnits.lessThanOrEqual(inputFloor, outputScaled) else { return false }
            if hop == 0 || route.protocolVersion == .v3 {
                expectedMovements.append(.init(token: tokens[hop], from: hop == 0 ? account : router,
                    to: pool.address.lowercased(), amount: input))
            }
            expectedMovements.append(.init(token: tokens[hop + 1], from: pool.address.lowercased(), to: to, amount: output))
            input = output
        }
        guard WalletBaseUnits.lessThanOrEqual(minimum, input) else { return false }
        let rawTransfers = logs.filter { isTransferEvent($0.topics.first) }
        var movements = rawTransfers.compactMap(tokenMovement)
        guard movements.count == rawTransfers.count, movements.count == expectedMovements.count else { return false }
        for expected in expectedMovements {
            guard let index = movements.firstIndex(of: expected) else { return false }
            movements.remove(at: index)
        }
        return movements.isEmpty
    }

    private static func solana(
        transactionID: String,
        network: WalletNetworkDescriptor,
        account: WalletAccount,
        expectedAction: WalletSemanticAction,
        bundle: Bundle,
        session: URLSession
    ) async throws -> WalletSubmittedTransactionReconciliation {
        guard WalletSolanaBase58.decode(transactionID, exactLength: 64) != nil,
              let configuration = WalletSolanaProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletGateway.Error.invalidArguments(
                "The external Solana signature or provider is invalid."
            )
        }
        let coordinator = try WalletSolanaProviderCoordinator(
            network: network, configuration: configuration, session: session
        )
        let raw = try await coordinator.publicRead(method: "getTransaction", params: [
            transactionID,
            [
                "commitment": "finalized", "encoding": "base64",
                "maxSupportedTransactionVersion": 0,
            ],
        ])
        if raw is NSNull { return .pending }
        guard let result = raw as? [String: Any], result.count <= 16,
              let slot = unsigned(result["slot"]),
              let transaction = result["transaction"] as? [Any],
              transaction.count == 2,
              transaction[1] as? String == "base64",
              let transactionBase64 = transaction[0] as? String,
              let bytes = Data(base64Encoded: transactionBase64),
              bytes.base64EncodedString() == transactionBase64,
              submittedSolanaSignature(bytes) == transactionID,
              let meta = result["meta"] as? [String: Any],
              meta.keys.contains("err") else {
            throw WalletRPCError.invalidResponse(
                "The submitted Solana transaction response is malformed."
            )
        }
        if let error = meta["err"], !(error is NSNull) {
            return .failed("The external Solana transaction failed.")
        }
        let actual = try await WalletDappTransactionDecoder.solana(
            .init(
                transactionBase64: transactionBase64,
                accountAddress: account.address, minimumContextSlot: slot
            ),
            networkID: network.id, account: account, bundle: bundle,
            allowsSubmittedSignature: true
        )
        guard actionsMatch(expectedAction, actual, chain: .solana) else {
            return .failed("The finalized Solana transaction does not match the reviewed action.")
        }
        return .confirmed(blockNumber: String(slot), finalized: true)
    }

    private static func sui(
        transactionID: String,
        network: WalletNetworkDescriptor,
        account: WalletAccount,
        expectedAction: WalletSemanticAction,
        bundle: Bundle,
        session: URLSession
    ) async throws -> WalletSubmittedTransactionReconciliation {
        guard WalletSolanaBase58.decode(transactionID, exactLength: 32) != nil,
              let configuration = WalletSuiProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletGateway.Error.invalidArguments(
                "The external Sui digest or provider is invalid."
            )
        }
        let coordinator = try WalletSuiProviderCoordinator(
            network: network, configuration: configuration, session: session
        )
        let all = try await coordinator.activity(owner: account.address)
        let records = all.filter { $0.transactionDigest == transactionID }
        guard !records.isEmpty else { return .pending }
        guard records.allSatisfy({ $0.successful }) else {
            return .failed("The external Sui transaction failed.")
        }
        guard records.allSatisfy({ $0.sender == account.address }),
              suiEffectsMatch(records, expectedAction: expectedAction, network: network) else {
            return .failed("The finalized Sui transaction does not match the reviewed action.")
        }
        let checkpoint = records.map(\.checkpointSequence).max() ?? 0
        return .confirmed(blockNumber: String(checkpoint), finalized: true)
    }

    private static func suiEffectsMatch(
        _ records: [WalletSuiIndexedActivity],
        expectedAction: WalletSemanticAction,
        network: WalletNetworkDescriptor
    ) -> Bool {
        guard let recipient = expectedAction.recipient,
              let amount = expectedAction.amountBaseUnits else { return false }
        switch expectedAction.type {
        case .nativeTransfer, .fungibleTokenTransfer:
            let assetID = expectedAction.type == .nativeTransfer
                ? network.nativeAssetID : expectedAction.assetID
            return records.contains {
                $0.identity?.canonicalID == assetID && $0.isInbound == false
                    && $0.counterpartyAddress == recipient
                    && $0.counterpartyAmountBaseUnits == amount
            }
        case .nftTransfer:
            return records.contains {
                $0.objectIdentity?.canonicalID == expectedAction.assetID
                    && $0.objectIdentity?.objectID == expectedAction.tokenID
                    && $0.isInbound == false
                    && $0.counterpartyAddress == recipient
                    && amount == "1"
            }
        default:
            return false
        }
    }

    private static func actionsMatch(
        _ expected: WalletSemanticAction,
        _ actual: WalletSemanticAction,
        chain: WalletChain
    ) -> Bool {
        guard expected.type == actual.type,
              expected.amountBaseUnits == actual.amountBaseUnits,
              expected.tokenID == actual.tokenID else { return false }
        let recipientMatches: Bool
        if chain == .evm {
            recipientMatches = expected.recipient?.caseInsensitiveCompare(
                actual.recipient ?? ""
            ) == .orderedSame
        } else {
            recipientMatches = expected.recipient == actual.recipient
        }
        let assetMatches: Bool
        if chain == .evm {
            assetMatches = expected.assetID?.lowercased() == actual.assetID?.lowercased()
        } else {
            assetMatches = expected.assetID == actual.assetID
        }
        return recipientMatches && assetMatches
    }

    private static func allowanceCalldataMatches(
        _ calldata: String,
        expectedAction: WalletSemanticAction
    ) -> Bool {
        guard let setup = expectedAction.swapAllowanceSetup,
              setup.binding.digest() == setup.bindingDigest,
              let amount = abiUnsignedWord(setup.approvalAmountBaseUnits),
              let permit2 = abiAddressWord(setup.binding.permit2Address),
              let router = abiAddressWord(setup.binding.universalRouterAddress)
        else { return false }
        let expected: String
        switch setup.stage {
        case .erc20Reset, .erc20ToPermit2:
            expected = "0x095ea7b3" + permit2 + amount
        case .permit2ToUniversalRouter:
            guard let input = WalletEVMAssetIdentity.parse(
                    setup.binding.inputAssetID
                  ),
                  let token = abiAddressWord(input.contractAddress),
                  let expiration = setup.expirationUnixSeconds
                    .flatMap(abiUnsignedWord) else { return false }
            expected = "0x87517c45" + token + router + amount + expiration
        }
        return calldata.caseInsensitiveCompare(expected) == .orderedSame
    }

    private static func abiAddressWord(_ value: String) -> String? {
        guard value.count == 42, value.hasPrefix("0x"),
              value.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 24)
            + String(value.dropFirst(2)).lowercased()
    }

    private static func abiUnsignedWord(_ value: String) -> String? {
        guard let encoded = WalletEthereumQuantity.decimalToHex(value) else {
            return nil
        }
        let raw = String(encoded.dropFirst(2))
        guard raw.count <= 64 else { return nil }
        return String(repeating: "0", count: 64 - raw.count) + raw
    }

    private static func submittedSolanaSignature(_ transaction: Data) -> String? {
        guard transaction.count >= 65, transaction[transaction.startIndex] == 1 else {
            return nil
        }
        return WalletSolanaBase58.encode(
            transaction.subdata(in: 1..<65)
        )
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        if let value = value as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), value.decimalValue >= 0,
           value.decimalValue == Decimal(value.uint64Value) {
            return value.uint64Value
        }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    static func semanticDigest(_ action: WalletSemanticAction) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(action)
        return "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
