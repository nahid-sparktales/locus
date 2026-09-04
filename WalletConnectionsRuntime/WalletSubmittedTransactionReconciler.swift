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
            return try await evm(
                transactionID: transactionID, network: network,
                account: account, expectedAction: expectedAction,
                expectedContractAddress: expectedContractAddress, bundle: bundle,
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
        expectedContractAddress: String?,
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
        guard let transaction = raw as? [String: Any], transaction.count <= 32,
              let hash = transaction["hash"] as? String,
              hash.caseInsensitiveCompare(transactionID) == .orderedSame,
              let from = transaction["from"] as? String,
              let to = transaction["to"] as? String,
              let value = transaction["value"] as? String,
              let input = transaction["input"] as? String else {
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
        let receiptRaw = try await coordinator.publicRead(
            method: "eth_getTransactionReceipt", params: [transactionID]
        )
        if receiptRaw is NSNull { return .pending }
        guard let receipt = receiptRaw as? [String: Any], receipt.count <= 32,
              let receiptHash = receipt["transactionHash"] as? String,
              receiptHash.caseInsensitiveCompare(transactionID) == .orderedSame,
              let status = receipt["status"] as? String,
              let block = receipt["blockNumber"] as? String,
              WalletEthereumQuantity.hexToUInt64(block) != nil else {
            throw WalletRPCError.invalidResponse("The submitted EVM receipt is malformed.")
        }
        guard status.lowercased() == "0x1" else {
            return .failed("The external EVM transaction reverted.")
        }
        return .confirmed(blockNumber: block, finalized: false)
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
