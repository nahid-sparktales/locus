import CryptoKit
import Foundation
import XCTest
@testable import Locus

final class WalletEVMReceiptReconciliationTests: XCTestCase {
    private let owner = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let recipient = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let token = "0x1111111111111111111111111111111111111111"
    private let output = "0x2222222222222222222222222222222222222222"
    private let intermediary = "0x3333333333333333333333333333333333333333"
    private let router = "0x4444444444444444444444444444444444444444"
    private let permit2 = "0x5555555555555555555555555555555555555555"
    private let pool = "0x6666666666666666666666666666666666666666"
    private let secondPool = "0x7777777777777777777777777777777777777777"
    private let transactionHash = "0x" + String(repeating: "a", count: 64)
    private let blockHash = "0x" + String(repeating: "b", count: 64)
    private let network = WalletNetworkCatalog.ethereumSepolia

    func testNativeReceiptBindsSenderChainAndMinedIdentity() throws {
        let action = WalletSemanticAction.nativeTransfer(recipient: recipient, amountBaseUnits: "10")
        var transaction = transaction(to: recipient, data: "0x", value: "0xa")
        let receipt = receipt(to: recipient, logs: [])
        XCTAssertEqual(try reconcile(action, transaction: transaction, receipt: receipt), .confirmed(blockNumber: "0x5", finalized: false))
        transaction["from"] = recipient
        XCTAssertThrowsError(try reconcile(action, transaction: transaction, receipt: receipt))
        transaction["from"] = owner
        transaction["chainId"] = "0x1"
        XCTAssertThrowsError(try reconcile(action, transaction: transaction, receipt: receipt))
        transaction["chainId"] = "0xaa36a7"
        transaction["blockHash"] = "0x" + String(repeating: "c", count: 64)
        XCTAssertThrowsError(try reconcile(action, transaction: transaction, receipt: receipt))
    }

    func testERC20RequiresExactTransactionScopedTransfer() throws {
        let action = WalletSemanticAction.fungibleTokenTransfer(assetID: asset(token), recipient: recipient, amountBaseUnits: "10")
        let transaction = transaction(to: token, data: "0xa9059cbb" + addressWord(recipient) + word(10))
        let transfer = log(token, "Transfer(address,address,uint256)", [owner, recipient], [word(10)])
        assertFailed(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [])))
        XCTAssertEqual(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [transfer])), .confirmed(blockNumber: "0x5", finalized: false))
        var wrongAmount = transfer
        wrongAmount["data"] = "0x" + word(9)
        assertFailed(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [wrongAmount])))
        var otherTransaction = transfer
        otherTransaction["transactionHash"] = "0x" + String(repeating: "c", count: 64)
        XCTAssertThrowsError(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [otherTransaction])))
        var removed = transfer
        removed["removed"] = true
        XCTAssertThrowsError(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [removed])))
        XCTAssertThrowsError(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [transfer, transfer])))
        var extra = transfer
        extra["logIndex"] = "0x1"
        assertFailed(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [transfer, extra])))
        let unsupportedBatch = log(token, "TransferBatch(address,address,address,uint256[],uint256[])",
            [owner, owner, recipient], [word(64), word(96), word(0), word(0)], index: 1)
        assertFailed(try reconcile(action, transaction: transaction, receipt: receipt(to: token, logs: [transfer, unsupportedBatch])))
    }

    func testCollectiblesRequireExactOwnerTokenAndQuantity() throws {
        let nft = WalletSemanticAction.nftTransfer(assetID: "\(network.id)/erc721:\(token)", tokenID: "7", recipient: recipient)
        let nftTransaction = transaction(to: token, data: "0x42842e0e" + addressWord(owner) + addressWord(recipient) + word(7))
        var event = log(token, "Transfer(address,address,uint256)", [owner, recipient], [])
        event["topics"] = (event["topics"] as! [String]) + ["0x" + word(7)]
        XCTAssertEqual(try reconcile(nft, transaction: nftTransaction, receipt: receipt(to: token, logs: [event])), .confirmed(blockNumber: "0x5", finalized: false))
        event["topics"] = [topic("Transfer(address,address,uint256)"), "0x" + addressWord(owner), "0x" + addressWord(recipient), "0x" + word(8)]
        assertFailed(try reconcile(nft, transaction: nftTransaction, receipt: receipt(to: token, logs: [event])))

        let multi = WalletSemanticAction.nftTransfer(assetID: "\(network.id)/erc1155:\(token)/7", tokenID: "7", recipient: recipient)
        let multiTransaction = transaction(to: token, data: "0xf242432a" + addressWord(owner) + addressWord(recipient) + word(7) + word(1) + word(160) + word(0))
        let single = log(token, "TransferSingle(address,address,address,uint256,uint256)", [owner, owner, recipient], [word(7), word(1)])
        XCTAssertEqual(try reconcile(multi, transaction: multiTransaction, receipt: receipt(to: token, logs: [single])), .confirmed(blockNumber: "0x5", finalized: false))
        assertFailed(try reconcile(multi, transaction: multiTransaction, receipt: receipt(to: token, logs: [])))
    }

    func testAllowancesRequireExactOwnerSpenderAmountAndExpiry() throws {
        for stage in [WalletSwapAllowanceStage.erc20ToPermit2, .erc20Reset, .permit2ToUniversalRouter] {
            let swap = try swapFixture(.v2)
            let binding = WalletSwapAllowanceBinding(networkID: network.id, universalRouterContractID: "router",
                universalRouterAddress: router, permit2Address: permit2, inputAssetID: asset(token),
                outputAssetID: asset(output), amountInBaseUnits: "10", minimumOutputBaseUnits: "9",
                recipient: owner, route: try XCTUnwrap(swap.action.swapRoute))
            let amount = stage == .erc20Reset ? "0" : "10"
            let isPermit2 = stage == .permit2ToUniversalRouter
            let setup = WalletSwapAllowanceSetup(stage: stage, binding: binding, bindingDigest: try XCTUnwrap(binding.digest()),
                approvalAmountBaseUnits: amount, expirationUnixSeconds: isPermit2 ? "1600" : nil)
            let action = WalletSemanticAction.swapAllowanceSetup(contractID: isPermit2 ? "permit2" : "token",
                adapterID: isPermit2 ? WalletReviewedAdapters.uniswapPermit2AllowanceSetup : WalletReviewedAdapters.erc20, setup: setup)
            let target = isPermit2 ? permit2 : token
            let data = isPermit2
                ? "0x87517c45" + addressWord(token) + addressWord(router) + word(10) + word(1600)
                : "0x095ea7b3" + addressWord(permit2) + word(stage == .erc20Reset ? 0 : 10)
            let event = isPermit2
                ? log(target, "Approval(address,address,address,uint160,uint48)", [owner, token, router], [word(10), word(1600)])
                : log(target, "Approval(address,address,uint256)", [owner, permit2], [word(stage == .erc20Reset ? 0 : 10)])
            var submitted = transaction(to: target, data: data)
            let mined = receipt(to: target, logs: [event])
            XCTAssertEqual(try reconcile(action, transaction: submitted, receipt: mined), .confirmed(blockNumber: "0x5", finalized: false))
            submitted["from"] = recipient
            XCTAssertThrowsError(try reconcile(action, transaction: submitted, receipt: mined))
            submitted["from"] = owner
            assertFailed(try reconcile(action, transaction: submitted, receipt: receipt(to: target, logs: [])))
            var wrongEvent = event
            wrongEvent["data"] = "0x" + word(11) + (isPermit2 ? word(1600) : "")
            assertFailed(try reconcile(action, transaction: submitted, receipt: receipt(to: target, logs: [wrongEvent])))
        }
    }

    func testReviewedV2AndV3HopsRequirePoolEventsAndExactTokenFlows() throws {
        for version in [WalletUniversalRouterSwapProtocol.v2, .v3] {
            for multiple in [false, true] {
                let fixture = try swapFixture(version, multiple: multiple)
                XCTAssertEqual(try reconcile(fixture.action, transaction: fixture.transaction,
                    receipt: receipt(to: router, logs: fixture.logs), configuration: fixture.configuration), .confirmed(blockNumber: "0x5", finalized: false))
                assertFailed(try reconcile(fixture.action, transaction: fixture.transaction,
                    receipt: receipt(to: router, logs: []), configuration: fixture.configuration))
                assertFailed(try reconcile(fixture.action, transaction: fixture.transaction,
                    receipt: receipt(to: router, logs: Array(fixture.logs.dropLast())), configuration: fixture.configuration))
                assertFailed(try reconcile(fixture.action, transaction: fixture.transaction,
                    receipt: receipt(to: router, logs: fixture.logs), configuration: nil))
                let lowOutput = try swapFixture(version, multiple: multiple, outputAmount: 8)
                assertFailed(try reconcile(lowOutput.action, transaction: lowOutput.transaction,
                    receipt: receipt(to: router, logs: lowOutput.logs), configuration: lowOutput.configuration))
            }
        }
    }

    func testReviewedTransactionCommitmentBindsNonceFeesTypeAndAccessList() throws {
        let action = WalletSemanticAction.nativeTransfer(recipient: recipient, amountBaseUnits: "10")
        let submitted = transaction(to: recipient, data: "0x", value: "0xa")
        let mined = receipt(to: recipient, logs: [])
        let commitment = try WalletSubmittedTransactionReconciler.evmTransactionCommitment(
            evmFields(submitted), maximumFeeBaseUnits: "42000")
        XCTAssertEqual(commitment.count, 64)
        XCTAssertTrue(commitment.allSatisfy(\.isHexDigit))
        XCTAssertEqual(try reconcile(action, transaction: submitted, receipt: mined,
            commitment: commitment, maximumFee: "42000"), .confirmed(blockNumber: "0x5", finalized: false))

        let replacements: [(String, Any)] = [
            ("nonce", "0x4"), ("gas", "0x5209"), ("maxFeePerGas", "0x3"),
            ("maxPriorityFeePerGas", "0x0"), ("gasPrice", "0x2"), ("type", "0x0"),
            ("accessList", [["address": token, "storageKeys": []]] as [[String: Any]]),
            ("authorizationList", [] as [Any]), ("blobVersionedHashes", [] as [Any]),
            ("input", "0x00"), ("value", "0xb"), ("chainId", "0x1"), ("from", recipient),
        ]
        for (key, value) in replacements {
            var changed = submitted
            changed[key] = value
            assertRejected {
                try reconcile(action, transaction: changed, receipt: mined,
                    commitment: commitment, maximumFee: "42000")
            }
        }
        for key in ["nonce", "gas", "maxFeePerGas", "maxPriorityFeePerGas", "type", "accessList"] {
            var missing = submitted
            missing[key] = nil
            assertRejected {
                try reconcile(action, transaction: missing, receipt: mined,
                    commitment: commitment, maximumFee: "42000")
            }
        }
        assertRejected {
            try reconcile(action, transaction: submitted, receipt: mined,
                commitment: commitment, maximumFee: "42001")
        }
        assertRejected {
            try reconcile(action, transaction: submitted, receipt: mined,
                commitment: commitment, maximumFee: nil)
        }
    }

    func testReceiptFeeEffectsCannotExceedOrContradictReviewedFields() throws {
        let action = WalletSemanticAction.nativeTransfer(recipient: recipient, amountBaseUnits: "10")
        let submitted = transaction(to: recipient, data: "0x", value: "0xa")
        let commitment = try WalletSubmittedTransactionReconciler.evmTransactionCommitment(
            evmFields(submitted), maximumFeeBaseUnits: "42000")
        let replacements = [("gasUsed", "0x5209"), ("gasUsed", "0x0"),
            ("effectiveGasPrice", "0x3"), ("effectiveGasPrice", "0x01")]
        for (key, value) in replacements {
            var mined = receipt(to: recipient, logs: [])
            mined[key] = value
            assertRejected {
                try reconcile(action, transaction: submitted, receipt: mined,
                    commitment: commitment, maximumFee: "42000")
            }
        }
        XCTAssertThrowsError(try WalletSubmittedTransactionReconciler.evmTransactionCommitment(
            evmFields(submitted), maximumFeeBaseUnits: "41999"))
        XCTAssertThrowsError(try WalletSubmittedTransactionReconciler.evmTransactionCommitment(
            evmFields(submitted), maximumFeeBaseUnits: "042000"))
        var badPriority = submitted
        badPriority["maxPriorityFeePerGas"] = "0x3"
        XCTAssertThrowsError(try WalletSubmittedTransactionReconciler.evmTransactionCommitment(
            evmFields(badPriority), maximumFeeBaseUnits: "42000"))
    }

    func testProductionReconciliationRequiresRetainedCommitmentBeforeProviderAccess() async throws {
        let action = WalletSemanticAction.nativeTransfer(recipient: recipient, amountBaseUnits: "10")
        do {
            _ = try await WalletSubmittedTransactionReconciler.reconcile(
                transactionID: transactionHash, networkID: network.id,
                account: fixtureAccount, expectedAction: action,
                expectedSemanticDigest: WalletSubmittedTransactionReconciler.semanticDigest(action))
            XCTFail("Historical EVM activity without exact preparation evidence was confirmed")
        } catch WalletRPCError.invalidResponse(let reason) {
            XCTAssertTrue(reason.contains("commitment is unavailable"))
        } catch {
            XCTFail("Missing commitment should fail before provider setup: \(error)")
        }
    }

    func testSettlementCodeSelectionIgnoresMoreThanSixteenUnrelatedPoolIdentities() throws {
        for version in [WalletUniversalRouterSwapProtocol.v2, .v3] {
            let fixture = try swapFixture(version, multiple: true)
            // All these pools mention route tokens, so the old any-token-pair
            // filter wrongly counted them toward the 16-code-identity ceiling.
            // Their unrelated hashes must never participate in this settlement.
            let differentHash = "0x" + String(repeating: "d", count: 64)
            var irrelevant = (1...15).map { tier in
                WalletReviewedUniswapPoolIdentity(protocolVersion: .v3,
                    address: numberedAddress(100 + tier), runtimeCodeHash: differentHash,
                    token0AssetID: asset(token), token1AssetID: asset(output), feeTier: UInt32(tier))
            }
            irrelevant.append(.init(protocolVersion: .v2, address: numberedAddress(200),
                runtimeCodeHash: differentHash, token0AssetID: asset(token), token1AssetID: asset(output), feeTier: nil))
            for (index, adjacent) in fixture.configuration.pools.enumerated() {
                irrelevant.append(.init(protocolVersion: version == .v2 ? .v3 : .v2,
                    address: numberedAddress(210 + index), runtimeCodeHash: differentHash,
                    token0AssetID: adjacent.token0AssetID, token1AssetID: adjacent.token1AssetID,
                    feeTier: version == .v2 ? 3000 : nil))
            }
            XCTAssertGreaterThan(irrelevant.count, 16)
            let configuration = replacingPools(fixture.configuration,
                pools: irrelevant + fixture.configuration.pools.reversed())
            let selected = try WalletSubmittedTransactionReconciler.reviewedSettlementPools(
                for: fixture.action, configuration: configuration)
            XCTAssertEqual(selected, fixture.configuration.pools)
            XCTAssertEqual(selected.count, 2)
            XCTAssertTrue(selected.allSatisfy { $0.runtimeCodeHash == transactionHash })
            XCTAssertEqual(try reconcile(fixture.action, transaction: fixture.transaction,
                receipt: receipt(to: router, logs: fixture.logs), configuration: configuration),
                .confirmed(blockNumber: "0x5", finalized: false))
        }
    }

    func testSettlementCodeSelectionRejectsMissingAmbiguousAndWrongFeeHops() throws {
        let fixture = try swapFixture(.v3, multiple: true)
        let first = try XCTUnwrap(fixture.configuration.pools.first)
        let wrongTier = WalletReviewedUniswapPoolIdentity(protocolVersion: .v3,
            address: numberedAddress(300), runtimeCodeHash: transactionHash,
            token0AssetID: first.token0AssetID, token1AssetID: first.token1AssetID, feeTier: 500)
        let ambiguous = WalletReviewedUniswapPoolIdentity(protocolVersion: .v3,
            address: numberedAddress(301), runtimeCodeHash: transactionHash,
            token0AssetID: first.token0AssetID, token1AssetID: first.token1AssetID, feeTier: 3000)
        let cases = [
            Array(fixture.configuration.pools.dropFirst()),
            [wrongTier] + fixture.configuration.pools.dropFirst(),
            fixture.configuration.pools + [ambiguous],
        ]
        for pools in cases {
            let configuration = replacingPools(fixture.configuration, pools: pools)
            XCTAssertThrowsError(try WalletSubmittedTransactionReconciler.reviewedSettlementPools(
                for: fixture.action, configuration: configuration))
            assertFailed(try reconcile(fixture.action, transaction: fixture.transaction,
                receipt: receipt(to: router, logs: fixture.logs), configuration: configuration))
        }
        let withUnusedTier = replacingPools(fixture.configuration, pools: [wrongTier] + fixture.configuration.pools)
        XCTAssertEqual(try WalletSubmittedTransactionReconciler.reviewedSettlementPools(
            for: fixture.action, configuration: withUnusedTier), fixture.configuration.pools)
    }

    private func numberedAddress(_ value: Int) -> String {
        let hex = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: 40 - hex.count) + hex
    }

    private func replacingPools(_ configuration: WalletReviewedUniswapConfiguration,
                                pools: [WalletReviewedUniswapPoolIdentity]) -> WalletReviewedUniswapConfiguration {
        WalletReviewedUniswapConfiguration(networkID: configuration.networkID,
            universalRouterContractID: configuration.universalRouterContractID,
            permit2ContractID: configuration.permit2ContractID, contracts: configuration.contracts,
            pools: pools, allowedIntermediaryAssetIDs: configuration.allowedIntermediaryAssetIDs,
            allowedFeeTiers: Set([3000] + (1...15).map(UInt32.init)), maximumHops: configuration.maximumHops,
            zeroFirstApprovalAssetIDs: configuration.zeroFirstApprovalAssetIDs)
    }

    private var fixtureAccount: WalletAccount {
        WalletAccount(id: "external", chain: .evm, address: owner, label: "Fixture",
            networkIDs: [network.id], ownership: .external(connectorID: .metamask))
    }

    private func evmFields(_ transaction: [String: Any]) -> WalletExternalEVMTransaction {
        WalletExternalEVMTransaction(from: transaction["from"] as! String,
            to: transaction["to"] as! String, valueHex: transaction["value"] as! String,
            dataHex: transaction["input"] as! String, gasHex: transaction["gas"] as! String,
            maxFeePerGasHex: transaction["maxFeePerGas"] as! String,
            maxPriorityFeePerGasHex: transaction["maxPriorityFeePerGas"] as! String,
            nonceHex: transaction["nonce"] as! String, chainIDHex: transaction["chainId"] as! String)
    }

    private func assertRejected(_ action: () throws -> WalletSubmittedTransactionReconciliation,
                                file: StaticString = #filePath, line: UInt = #line) {
        do { assertFailed(try action(), file: file, line: line) }
        catch { /* A malformed commitment fails closed before effects can be confirmed. */ }
    }

    private func reconcile(_ action: WalletSemanticAction, transaction: [String: Any], receipt: [String: Any],
                           configuration: WalletReviewedUniswapConfiguration? = nil,
                           commitment: String? = nil, maximumFee: String? = nil) throws -> WalletSubmittedTransactionReconciliation {
        try WalletSubmittedTransactionReconciler.reconcileEVMObservedTransaction(
            transactionID: transactionHash, network: network,
            account: fixtureAccount,
            expectedAction: action, expectedContractAddress: transaction["to"] as? String,
            transaction: transaction, receipt: receipt,
            expectedEVMTransactionDigest: commitment, expectedEVMMaximumFeeBaseUnits: maximumFee,
            uniswapConfiguration: configuration
        )
    }

    private func assertFailed(_ result: WalletSubmittedTransactionReconciliation, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed = result else { return XCTFail("Unproven effects were confirmed", file: file, line: line) }
    }

    private func transaction(to: String, data: String, value: String = "0x0") -> [String: Any] {
        ["hash": transactionHash, "from": owner, "to": to, "value": value, "input": data,
         "chainId": "0xaa36a7", "blockHash": blockHash, "blockNumber": "0x5", "transactionIndex": "0x0",
         "type": "0x2", "accessList": [] as [Any], "nonce": "0x3", "gas": "0x5208",
         "maxFeePerGas": "0x2", "maxPriorityFeePerGas": "0x1", "gasPrice": "0x1"]
    }
    private func receipt(to: String, logs: [[String: Any]]) -> [String: Any] {
        ["transactionHash": transactionHash, "from": owner, "to": to, "status": "0x1", "blockHash": blockHash,
         "blockNumber": "0x5", "transactionIndex": "0x0", "logs": logs,
         "gasUsed": "0x5208", "effectiveGasPrice": "0x1"]
    }
    private func log(_ emitter: String, _ signature: String, _ addresses: [String], _ words: [String], index: Int = 0) -> [String: Any] {
        ["address": emitter, "topics": [topic(signature)] + addresses.map { "0x" + addressWord($0) },
         "data": "0x" + words.joined(), "removed": false, "transactionHash": transactionHash,
         "blockHash": blockHash, "blockNumber": "0x5", "transactionIndex": "0x0", "logIndex": "0x" + String(index, radix: 16)]
    }
    private func topic(_ value: String) -> String { "0x" + WalletKeccak256.hash(Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func addressWord(_ value: String) -> String { String(repeating: "0", count: 24) + value.dropFirst(2) }
    private func word(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex
    }
    private func negativeWord(_ value: UInt64) -> String {
        let tail = String(UInt64.max - value + 1, radix: 16)
        return String(repeating: "f", count: 64 - tail.count) + tail
    }
    private func asset(_ address: String) -> String { "\(network.id)/erc20:\(address)" }

    private func swapFixture(_ version: WalletUniversalRouterSwapProtocol, multiple: Bool = false, outputAmount: UInt64 = 10) throws
        -> (action: WalletSemanticAction, transaction: [String: Any], logs: [[String: Any]], configuration: WalletReviewedUniswapConfiguration) {
        let path = multiple ? [asset(token), asset(intermediary), asset(output)] : [asset(token), asset(output)]
        let route = WalletExactInputSwapRoute(protocolVersion: version, pathAssetIDs: path,
            feeTiers: version == .v3 ? Array(repeating: 3000, count: path.count - 1) : [],
            minimumHopPriceX36: Array(repeating: "9" + String(repeating: "0", count: 35), count: path.count - 1),
            quotedOutputBaseUnits: "10", slippageBPS: 1000, deadlineUnixSeconds: "1600",
            quoteEvidence: .init(blockNumber: "1", blockHash: blockHash, quoteContractAddress: router,
                quoteContractRuntimeCodeHash: transactionHash, perHopOutputBaseUnits: Array(repeating: "10", count: path.count - 1),
                gasEstimate: "1", quotedAt: Date(timeIntervalSince1970: 1000), expiresAt: Date(timeIntervalSince1970: 1060), agreeingProviderCount: 2))
        let action = WalletSemanticAction.exactInputSwap(adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: "router", inputAssetID: asset(token), outputAssetID: asset(output), amountInBaseUnits: "10",
            minimumOutputBaseUnits: "9", recipient: owner, route: route)
        let abi = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"type":"bytes"},{"type":"bytes[]"},{"type":"uint256"}],"outputs":[]}]"#
        let entry = WalletContractRegistryEntry(id: "router", networkID: network.id, checksumAddress: router, label: "Router",
            normalizedABI: abi, abiDigest: "sha256:" + SHA256.hash(data: Data(abi.utf8)).map { String(format: "%02x", $0) }.joined(), runtimeCodeHash: transactionHash,
            permittedFunctions: ["execute(bytes,bytes[],uint256)"], permittedSelectors: ["0x3593564c"],
            reviewedAdapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn, verifiedAt: Date(timeIntervalSince1970: 1000))
        let materialized = try XCTUnwrap(WalletUniversalRouterV2V3Adapter.contractAction(for: action, accountAddress: owner,
            networkID: network.id, now: Date(timeIntervalSince1970: 1000)))
        let data = try WalletExternalEVMABIEncoder.encode(action: materialized, registryEntry: entry)
        let addresses = multiple ? [pool, secondPool] : [pool]
        let tokens = multiple ? [token, intermediary, output] : [token, output]
        let pools = addresses.indices.map { index in
            WalletReviewedUniswapPoolIdentity(protocolVersion: version, address: addresses[index], runtimeCodeHash: transactionHash,
                token0AssetID: path[index], token1AssetID: path[index + 1], feeTier: version == .v3 ? 3000 : nil)
        }
        let configuration = WalletReviewedUniswapConfiguration(networkID: network.id, universalRouterContractID: "router",
            permit2ContractID: "permit2", contracts: [.init(role: .universalRouter, address: router, runtimeCodeHash: transactionHash)],
            pools: pools, allowedIntermediaryAssetIDs: multiple ? [asset(intermediary)] : [], allowedFeeTiers: [3000], maximumHops: 3, zeroFirstApprovalAssetIDs: [])
        var logs: [[String: Any]] = []
        for index in addresses.indices {
            let received = index == addresses.count - 1 ? outputAmount : 10
            let to = index == addresses.count - 1 ? owner : (version == .v2 ? addresses[index + 1] : router)
            if index == 0 || version == .v3 {
                logs.append(log(tokens[index], "Transfer(address,address,uint256)", [index == 0 ? owner : router, addresses[index]], [word(10)], index: logs.count))
            }
            logs.append(log(tokens[index + 1], "Transfer(address,address,uint256)", [addresses[index], to], [word(received)], index: logs.count))
            logs.append(log(addresses[index], version == .v2
                ? "Swap(address,uint256,uint256,uint256,uint256,address)"
                : "Swap(address,address,int256,int256,uint160,uint128,int24)", [router, to],
                version == .v2 ? [word(10), word(0), word(0), word(received)]
                    : [word(10), negativeWord(received), word(1), word(1), word(0)], index: logs.count))
        }
        return (action, transaction(to: router, data: data), logs, configuration)
    }
}
