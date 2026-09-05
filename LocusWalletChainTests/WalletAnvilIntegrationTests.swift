import CryptoKit
import Foundation
import XCTest
@testable import Locus

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

@_silgen_name("locus_wallet_derive_accounts_json")
private func rustDeriveAccounts(
    _ entropyHex: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_encode_contract_call_json")
private func rustEncodeContractCall(
    _ requestJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_string_free")
private func rustFreeString(_ value: UnsafeMutablePointer<CChar>)

private struct RustPreparedTransaction: Decodable {
    let from: String
    let digest: String
}

private struct RustSignedTransaction: Decodable {
    let from: String
    let digest: String
    let rawTransaction: String
    let transactionHash: String

    enum CodingKeys: String, CodingKey {
        case from, digest
        case rawTransaction = "raw_transaction"
        case transactionHash = "transaction_hash"
    }
}

private struct RustEncodedContractCall: Decodable {
    let input: String
}

private struct RustContractCallRequest: Encodable {
    let normalizedABI: String
    let function: String
    let arguments: [WalletTypedArgument]
}

@MainActor
final class WalletAnvilIntegrationTests: XCTestCase {
    private static let pinnedAnvilVersion = "1.7.1"
    private static let entropy = String(repeating: "00", count: 32)

    func testRustDerivedAccountsDecodeThroughProductionSwiftBoundary() throws {
        let pointer = Self.entropy.withCString { rustDeriveAccounts($0) }
        let resultPointer = try XCTUnwrap(pointer)
        defer { rustFreeString(resultPointer) }

        let accounts = try WalletDerivedAccountsDecoder.decode(
            Data(String(cString: resultPointer).utf8)
        )

        XCTAssertEqual(accounts.map(\.id), [
            "locus-vault-evm-0",
            "locus-vault-solana-0",
            "locus-vault-sui-0",
        ])
        XCTAssertEqual(accounts.map(\.chain), [.evm, .solana, .sui])
        XCTAssertEqual(accounts.map(\.address), [
            "0xF278cF59F82eDcf871d630F28EcC8056f25C1cdb",
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
            "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c",
        ])
        XCTAssertEqual(accounts.map(\.label), [
            "Locus Vault EVM",
            "Locus Vault Solana",
            "Locus Vault Sui",
        ])
        XCTAssertEqual(accounts.map(\.networkIDs), [
            ["eip155:1", "eip155:11155111"],
            ["solana:mainnet-beta", "solana:devnet"],
            ["sui:mainnet", "sui:testnet"],
        ])
    }

    func testPinnedSignerCoreBroadcastReplayRecheckAndRecoveryOnAnvil() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_ANVIL_RPC_URL"],
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Run Tools/RunWalletChainTests.sh with pinned Anvil v1.7.1.")
        }
        XCTAssertEqual(environment["LOCUS_ANVIL_VERSION"], Self.pinnedAnvilVersion)
        let client = try WalletSepoliaRPCClient(testLoopbackEndpoint: endpoint)
        let health = try await client.health()
        XCTAssertTrue(health.contains("chain 11155111"))

        let recipient = "0x1111111111111111111111111111111111111111"
        let preview = try rustPrepared(transaction: transactionJSON(
            nonce: 0,
            gasLimit: 21_000,
            maxFeePerGas: "3000000000",
            priorityFeePerGas: "1000000000",
            recipient: recipient,
            value: "12345"
        ))
        _ = try await rawRPC(
            endpoint: endpoint,
            method: "anvil_setBalance",
            params: [preview.from, "0x56bc75e2d63100000"]
        )

        let request = WalletPrepareRequest(
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: "locus-vault-evm-0",
            source: .agent,
            action: .nativeTransfer(recipient: recipient, amountBaseUnits: "12345"),
            maximumFeeBaseUnits: "100000000000000000"
        )
        let packet = try await client.prepare(request: request, fromAddress: preview.from)
        let canonicalJSON = transactionJSON(packet.transaction)
        let prepared = try rustPrepared(transaction: canonicalJSON)
        let signed = try rustSigned(transaction: canonicalJSON)
        XCTAssertEqual(prepared.digest, signed.digest)
        XCTAssertEqual(prepared.from.lowercased(), signed.from.lowercased())

        let broadcastHash = try await client.broadcast(rawTransaction: signed.rawTransaction)
        XCTAssertEqual(broadcastHash.lowercased(), signed.transactionHash.lowercased())
        let receipt = try await waitForReceipt(hash: signed.transactionHash, client: client)
        XCTAssertEqual(receipt["status"] as? String, "0x1")

        do {
            _ = try await client.broadcast(rawTransaction: signed.rawTransaction)
            XCTFail("The same signed transaction must not broadcast twice.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("nonce")
                || String(describing: error).contains("known"))
        }

        let recheck = try await client.recheck(intentID: "intent-anvil", packet: packet)
        XCTAssertNotEqual(recheck.pendingNonce, packet.transaction.nonce)

        _ = try await rawRPC(
            endpoint: endpoint,
            method: "anvil_setNextBlockBaseFeePerGas",
            params: ["0x77359400"]
        )
        _ = try await rawRPC(endpoint: endpoint, method: "evm_mine", params: [])
        let changedFeePacket = try await client.prepare(request: request, fromAddress: preview.from)
        XCTAssertNotEqual(
            changedFeePacket.transaction.maxFeePerGas,
            packet.transaction.maxFeePerGas
        )

        let reverting = "0x2222222222222222222222222222222222222222"
        _ = try await rawRPC(
            endpoint: endpoint,
            method: "anvil_setCode",
            params: [reverting, "0x60006000fd"]
        )
        let failing = WalletPrepareRequest(
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: "locus-vault-evm-0",
            source: .agent,
            action: .nativeTransfer(recipient: reverting, amountBaseUnits: "1"),
            maximumFeeBaseUnits: "100000000000000000"
        )
        do {
            _ = try await client.prepare(request: failing, fromAddress: preview.from)
            XCTFail("A reverted simulation must not produce a prepared packet.")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }

        // Receipt lookup by the signer-derived local hash is the recovery path
        // when the node accepts a broadcast but the response is lost.
        let recovered = try await client.publicRead(
            method: "eth_getTransactionReceipt",
            params: [signed.transactionHash]
        ) as? [String: Any]
        XCTAssertEqual(recovered?["transactionHash"] as? String, signed.transactionHash)
    }

    func testDebugLoopbackInitializerRejectsNonLoopbackAndHTTPSProductionPathStaysStrict() async {
        XCTAssertThrowsError(try WalletSepoliaRPCClient(
            testLoopbackEndpoint: "http://example.com:8545"
        ))
        let production = WalletSepoliaRPCClient(endpoint: "http://127.0.0.1:8545")
        do {
            try await production.configure(endpoint: "http://127.0.0.1:8545")
            XCTFail("The production endpoint path must remain HTTPS-only.")
        } catch WalletRPCError.invalidEndpoint {
            // Expected.
        } catch {
            XCTFail("Unexpected endpoint error: \(error)")
        }
    }

    func testReviewedCalldataBroadcastsButNoOpContractsCannotProveSettlement() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_ANVIL_RPC_URL"],
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Run Tools/RunWalletChainTests.sh with pinned Anvil v1.7.1.")
        }
        let client = try WalletSepoliaRPCClient(testLoopbackEndpoint: endpoint)
        let recipient = "0x2222222222222222222222222222222222222222"
        let preview = try rustPrepared(transaction: transactionJSON(
            nonce: 0, gasLimit: 21_000, maxFeePerGas: "3000000000",
            priorityFeePerGas: "1000000000", recipient: recipient, value: "1"
        ))
        _ = try await rawRPC(
            endpoint: endpoint, method: "anvil_setBalance",
            params: [preview.from, "0x56bc75e2d63100000"]
        )

        let runtime = "0x60006000f3"
        let runtimeHashValue = try await rawRPC(
            endpoint: endpoint, method: "web3_sha3", params: [runtime]
        )
        let runtimeHash = try XCTUnwrap(runtimeHashValue as? String)
        let erc20 = "0x1000000000000000000000000000000000000001"
        let erc721 = "0x1000000000000000000000000000000000000002"
        let erc1155 = "0x1000000000000000000000000000000000000003"
        let router = "0x1000000000000000000000000000000000000004"
        for address in [erc20, erc721, erc1155, router] {
            _ = try await rawRPC(
                endpoint: endpoint, method: "anvil_setCode",
                params: [address, runtime]
            )
        }

        let erc20ABI = #"[{"type":"function","name":"transfer","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]}]"#
        let erc20Entry = registryEntry(
            id: "anvil.erc20", address: erc20, abi: erc20ABI,
            functions: ["transfer(address,uint256)"], selectors: ["0xa9059cbb"],
            adapter: WalletReviewedAdapters.erc20, runtimeHash: runtimeHash
        )
        let erc20Action = WalletSemanticAction.fungibleTokenTransfer(
            assetID: "\(WalletGateway.sepoliaNetworkID)/erc20:\(erc20)",
            recipient: recipient, amountBaseUnits: "123"
        )
        try await executeReviewedAction(
            erc20Action, entry: erc20Entry,
            materialized: try XCTUnwrap(WalletEVMAssetAdapter.resolve(
                action: erc20Action, registryEntry: erc20Entry,
                accountAddress: preview.from
            )),
            client: client, endpoint: endpoint, from: preview.from
        )

        let erc721ABI = #"[{"type":"function","name":"safeTransferFrom","stateMutability":"nonpayable","inputs":[{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"tokenId","type":"uint256"}],"outputs":[]}]"#
        let erc721Entry = registryEntry(
            id: "anvil.erc721", address: erc721, abi: erc721ABI,
            functions: ["safeTransferFrom(address,address,uint256)"],
            selectors: ["0x42842e0e"],
            adapter: WalletReviewedAdapters.erc721SafeTransfer,
            runtimeHash: runtimeHash
        )
        let erc721Action = WalletSemanticAction.nftTransfer(
            assetID: "\(WalletGateway.sepoliaNetworkID)/erc721:\(erc721)",
            tokenID: "7", recipient: recipient
        )
        try await executeReviewedAction(
            erc721Action, entry: erc721Entry,
            materialized: try XCTUnwrap(WalletEVMAssetAdapter.resolve(
                action: erc721Action, registryEntry: erc721Entry,
                accountAddress: preview.from
            )),
            client: client, endpoint: endpoint, from: preview.from
        )

        let erc1155ABI = #"[{"type":"function","name":"safeTransferFrom","stateMutability":"nonpayable","inputs":[{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"id","type":"uint256"},{"name":"amount","type":"uint256"},{"name":"data","type":"bytes"}],"outputs":[]}]"#
        let erc1155Entry = registryEntry(
            id: "anvil.erc1155", address: erc1155, abi: erc1155ABI,
            functions: ["safeTransferFrom(address,address,uint256,uint256,bytes)"],
            selectors: ["0xf242432a"],
            adapter: WalletReviewedAdapters.erc1155SafeTransfer,
            runtimeHash: runtimeHash
        )
        let erc1155Action = WalletSemanticAction.nftTransfer(
            assetID: "\(WalletGateway.sepoliaNetworkID)/erc1155:\(erc1155)/9",
            tokenID: "9", recipient: recipient
        )
        try await executeReviewedAction(
            erc1155Action, entry: erc1155Entry,
            materialized: try XCTUnwrap(WalletEVMAssetAdapter.resolve(
                action: erc1155Action, registryEntry: erc1155Entry,
                accountAddress: preview.from
            )),
            client: client, endpoint: endpoint, from: preview.from
        )

        let routerABI = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],"outputs":[]}]"#
        let routerEntry = registryEntry(
            id: "anvil.universal-router", address: router, abi: routerABI,
            functions: ["execute(bytes,bytes[],uint256)"],
            selectors: ["0x3593564c"],
            adapter: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            runtimeHash: runtimeHash
        )
        let input = "\(WalletGateway.sepoliaNetworkID)/erc20:\(erc20)"
        let output = "\(WalletGateway.sepoliaNetworkID)/erc20:0x1000000000000000000000000000000000000005"
        let swap = WalletSemanticAction.exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: routerEntry.id, inputAssetID: input,
            outputAssetID: output, amountInBaseUnits: "1000",
            minimumOutputBaseUnits: "995", recipient: preview.from,
            route: WalletExactInputSwapRoute(
                protocolVersion: .v2, pathAssetIDs: [input, output],
                feeTiers: [], minimumHopPriceX36: [],
                quotedOutputBaseUnits: "1000", slippageBPS: 50,
                deadlineUnixSeconds: String(
                    UInt64(Date().timeIntervalSince1970) + 600
                )
            )
        )
        let materializedSwap = try XCTUnwrap(
            WalletUniversalRouterV2V3Adapter.contractAction(
                for: swap, accountAddress: preview.from,
                networkID: WalletGateway.sepoliaNetworkID
            )
        )
        try await executeReviewedAction(
            swap, entry: routerEntry, materialized: WalletEVMReviewedSemanticCall(
                adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                assetID: input,
                function: try XCTUnwrap(materializedSwap.function),
                arguments: materializedSwap.arguments
            ),
            client: client, endpoint: endpoint, from: preview.from
        )

        let changedEntry = registryEntry(
            id: erc20Entry.id, address: erc20, abi: erc20ABI,
            functions: erc20Entry.permittedFunctions,
            selectors: erc20Entry.permittedSelectors,
            adapter: WalletReviewedAdapters.erc20,
            runtimeHash: "0x" + String(repeating: "0", count: 64)
        )
        let encoded = try rustEncoded(
            try XCTUnwrap(WalletEVMAssetAdapter.resolve(
                action: erc20Action, registryEntry: changedEntry,
                accountAddress: preview.from
            )),
            entry: changedEntry
        )
        let request = WalletPrepareRequest(
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: "locus-vault-evm-0", source: .human,
            action: erc20Action, maximumFeeBaseUnits: "100000000000000000"
        )
        do {
            _ = try await client.prepare(
                request: request, fromAddress: preview.from,
                contract: changedEntry, encodedContract: encoded
            )
            XCTFail("Changed contract code must fail closed.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("runtime code changed"))
        }
    }

    func testDualProviderV2QuoteBindsBlockRouteFloorsAndCodeIdentity() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_ANVIL_RPC_URL"],
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Run Tools/RunWalletChainTests.sh with pinned Anvil v1.7.1.")
        }
        let inputAddress = "0x2000000000000000000000000000000000000001"
        let outputAddress = "0x2000000000000000000000000000000000000002"
        let quoteAddress = "0x2000000000000000000000000000000000000003"
        let poolAddress = "0x2000000000000000000000000000000000000004"
        let input = "\(WalletGateway.sepoliaNetworkID)/erc20:\(inputAddress)"
        let output = "\(WalletGateway.sepoliaNetworkID)/erc20:\(outputAddress)"
        let quoteRuntime = Self.constantV2QuoteRuntime(
            amountIn: 1_000, amountOut: 2_000
        )
        let poolRuntime = "0x60006000f3"
        _ = try await rawRPC(
            endpoint: endpoint, method: "anvil_setCode",
            params: [quoteAddress, quoteRuntime]
        )
        _ = try await rawRPC(
            endpoint: endpoint, method: "anvil_setCode",
            params: [poolAddress, poolRuntime]
        )
        let quoteHashValue = try await rawRPC(
            endpoint: endpoint, method: "web3_sha3", params: [quoteRuntime]
        )
        let poolHashValue = try await rawRPC(
            endpoint: endpoint, method: "web3_sha3", params: [poolRuntime]
        )
        let quoteHash = try XCTUnwrap(quoteHashValue as? String)
        let poolHash = try XCTUnwrap(poolHashValue as? String)
        let configuration = WalletReviewedUniswapConfiguration(
            networkID: WalletGateway.sepoliaNetworkID,
            universalRouterContractID: "anvil.universal-router",
            permit2ContractID: "anvil.permit2",
            contracts: [WalletReviewedUniswapContractIdentity(
                role: .v2Router, address: quoteAddress,
                runtimeCodeHash: quoteHash
            )],
            pools: [WalletReviewedUniswapPoolIdentity(
                protocolVersion: .v2, address: poolAddress,
                runtimeCodeHash: poolHash, token0AssetID: input,
                token1AssetID: output, feeTier: nil
            )],
            allowedIntermediaryAssetIDs: [], allowedFeeTiers: [],
            maximumHops: 3, zeroFirstApprovalAssetIDs: []
        )
        let coordinator = try WalletEVMProviderCoordinator(
            testLoopbackPrimary: endpoint, fallback: endpoint
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let request = WalletUniswapQuoteRequest(
            networkID: WalletGateway.sepoliaNetworkID,
            universalRouterContractID: "anvil.universal-router",
            inputAssetID: input, outputAssetID: output,
            amountInBaseUnits: "1000", slippageBPS: 50,
            recipient: "0x3000000000000000000000000000000000000001"
        )
        let quote = try await coordinator.uniswapQuote(
            request: request, configuration: configuration, now: now
        )
        XCTAssertEqual(quote.expiresAt, now.addingTimeInterval(60))
        XCTAssertEqual(quote.action.minimumOutputBaseUnits, "1990")
        XCTAssertEqual(
            quote.action.swapRoute?.minimumHopPriceX36,
            ["1990000000000000000000000000000000000"]
        )
        XCTAssertEqual(
            quote.action.swapRoute?.quoteEvidence?.perHopOutputBaseUnits,
            ["2000"]
        )
        XCTAssertEqual(
            quote.action.swapRoute?.quoteEvidence?.agreeingProviderCount, 2
        )
        XCTAssertEqual(
            quote.action.swapRoute?.quoteEvidence?.quoteContractRuntimeCodeHash,
            quoteHash.lowercased()
        )

        _ = try await rawRPC(
            endpoint: endpoint, method: "anvil_setCode",
            params: [poolAddress, "0x60016000f3"]
        )
        do {
            _ = try await coordinator.uniswapQuote(
                request: request, configuration: configuration, now: now
            )
            XCTFail("A changed reviewed pool identity must invalidate the quote.")
        } catch WalletUniswapQuoteError.changedCodeIdentity {
            // Expected.
        }
    }

    func testFiniteERC20AndPermit2AllowanceSetupChangesOnlyReviewedState() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_ANVIL_RPC_URL"],
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Run Tools/RunWalletChainTests.sh with pinned Anvil v1.7.1.")
        }
        let client = try WalletSepoliaRPCClient(testLoopbackEndpoint: endpoint)
        let preview = try rustPrepared(transaction: transactionJSON(
            nonce: 0, gasLimit: 21_000, maxFeePerGas: "3000000000",
            priorityFeePerGas: "1000000000",
            recipient: "0x4000000000000000000000000000000000000001",
            value: "1"
        ))
        _ = try await rawRPC(
            endpoint: endpoint, method: "anvil_setBalance",
            params: [preview.from, "0x56bc75e2d63100000"]
        )

        let token = "0x4000000000000000000000000000000000000001"
        let permit2 = "0x4000000000000000000000000000000000000002"
        let router = "0x4000000000000000000000000000000000000003"
        let outputToken = "0x4000000000000000000000000000000000000004"
        let tokenRuntime = Self.statefulERC20AllowanceRuntime
        let permit2Runtime = Self.statefulPermit2AllowanceRuntime
        let routerRuntime = "0x60006000f3"
        for (address, runtime) in [
            (token, tokenRuntime), (permit2, permit2Runtime),
            (router, routerRuntime),
        ] {
            _ = try await rawRPC(
                endpoint: endpoint, method: "anvil_setCode",
                params: [address, runtime]
            )
        }
        let tokenHashValue = try await codeHash(address: token, endpoint: endpoint)
        let permit2HashValue = try await codeHash(address: permit2, endpoint: endpoint)
        let routerHashValue = try await codeHash(address: router, endpoint: endpoint)
        let tokenHash = try XCTUnwrap(tokenHashValue)
        let permit2Hash = try XCTUnwrap(permit2HashValue)
        let routerHash = try XCTUnwrap(routerHashValue)

        let network = WalletGateway.sepoliaNetworkID
        let inputAsset = "\(network)/erc20:\(token)"
        let outputAsset = "\(network)/erc20:\(outputToken)"
        let deadline = String(UInt64(Date().timeIntervalSince1970) + 600)
        let route = WalletExactInputSwapRoute(
            protocolVersion: .v2, pathAssetIDs: [inputAsset, outputAsset],
            feeTiers: [],
            minimumHopPriceX36: ["1" + String(repeating: "0", count: 36)],
            quotedOutputBaseUnits: "1000", slippageBPS: 50,
            deadlineUnixSeconds: deadline,
            quoteEvidence: WalletUniswapQuoteEvidence(
                blockNumber: "1",
                blockHash: "0x" + String(repeating: "1", count: 64),
                quoteContractAddress: router,
                quoteContractRuntimeCodeHash: routerHash,
                perHopOutputBaseUnits: ["1000"], gasEstimate: "50000",
                quotedAt: Date(), expiresAt: Date().addingTimeInterval(60),
                agreeingProviderCount: 2
            )
        )
        let binding = WalletSwapAllowanceBinding(
            networkID: network,
            universalRouterContractID: "anvil.universal-router",
            universalRouterAddress: router, permit2Address: permit2,
            inputAssetID: inputAsset, outputAssetID: outputAsset,
            amountInBaseUnits: "1000", minimumOutputBaseUnits: "995",
            recipient: preview.from, route: route
        )
        let bindingDigest = try XCTUnwrap(binding.digest())
        let configuration = WalletReviewedUniswapConfiguration(
            networkID: network,
            universalRouterContractID: "anvil.universal-router",
            permit2ContractID: "anvil.permit2",
            contracts: [
                .init(
                    role: .universalRouter, address: router,
                    runtimeCodeHash: routerHash
                ),
                .init(
                    role: .permit2, address: permit2,
                    runtimeCodeHash: permit2Hash
                ),
            ],
            pools: [], allowedIntermediaryAssetIDs: [], allowedFeeTiers: [],
            maximumHops: 3, zeroFirstApprovalAssetIDs: []
        )
        let tokenABI = #"[{"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"type":"bool"}]}]"#
        let permit2ABI = #"[{"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"name":"token","type":"address"},{"name":"spender","type":"address"},{"name":"amount","type":"uint160"},{"name":"expiration","type":"uint48"}],"outputs":[]}]"#
        let tokenEntry = registryEntry(
            id: "anvil.allowance-token", address: token, abi: tokenABI,
            functions: ["approve(address,uint256)"], selectors: ["0x095ea7b3"],
            adapter: WalletReviewedAdapters.erc20, runtimeHash: tokenHash
        )
        let permit2Entry = registryEntry(
            id: "anvil.permit2", address: permit2, abi: permit2ABI,
            functions: ["approve(address,address,uint160,uint48)"],
            selectors: ["0x87517c45"],
            adapter: WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
            runtimeHash: permit2Hash
        )
        let emptyTokenAllowance = try await ethCallWords(
            address: token, data: "0xdd62ed3e" + String(repeating: "0", count: 128),
            endpoint: endpoint
        )
        XCTAssertEqual(emptyTokenAllowance, ["0"])

        let erc20Setup = WalletSwapAllowanceSetup(
            stage: .erc20ToPermit2, binding: binding,
            bindingDigest: bindingDigest, approvalAmountBaseUnits: "1000",
            expirationUnixSeconds: nil
        )
        let erc20Action = WalletSemanticAction.swapAllowanceSetup(
            contractID: tokenEntry.id, adapterID: WalletReviewedAdapters.erc20,
            setup: erc20Setup
        )
        let erc20Call = try XCTUnwrap(WalletSwapAllowanceAdapter.resolve(
            action: erc20Action, registryEntry: tokenEntry,
            configuration: configuration
        ))
        try await executeReviewedAction(
            erc20Action, entry: tokenEntry, materialized: erc20Call,
            client: client, endpoint: endpoint, from: preview.from
        )
        let tokenAllowance = try await ethCallWords(
            address: token, data: "0xdd62ed3e" + String(repeating: "0", count: 128),
            endpoint: endpoint
        )
        XCTAssertEqual(tokenAllowance, ["1000"])

        let permit2Setup = WalletSwapAllowanceSetup(
            stage: .permit2ToUniversalRouter, binding: binding,
            bindingDigest: bindingDigest, approvalAmountBaseUnits: "1000",
            expirationUnixSeconds: deadline
        )
        let permit2Action = WalletSemanticAction.swapAllowanceSetup(
            contractID: permit2Entry.id,
            adapterID: WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
            setup: permit2Setup
        )
        let permit2Call = try XCTUnwrap(WalletSwapAllowanceAdapter.resolve(
            action: permit2Action, registryEntry: permit2Entry,
            configuration: configuration
        ))
        try await executeReviewedAction(
            permit2Action, entry: permit2Entry, materialized: permit2Call,
            client: client, endpoint: endpoint, from: preview.from
        )
        let permit2Allowance = try await ethCallWords(
            address: permit2,
            data: "0x927da105" + String(repeating: "0", count: 192),
            endpoint: endpoint
        )
        XCTAssertEqual(permit2Allowance, ["1000", deadline, "0"])

        XCTAssertNil(WalletSwapAllowanceAdapter.resolve(
            action: .swapAllowanceSetup(
                contractID: permit2Entry.id,
                adapterID: WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
                setup: WalletSwapAllowanceSetup(
                    stage: .permit2ToUniversalRouter, binding: binding,
                    bindingDigest: bindingDigest,
                    approvalAmountBaseUnits: "1001",
                    expirationUnixSeconds: deadline
                )
            ),
            registryEntry: permit2Entry, configuration: configuration
        ))
    }

    private func transactionJSON(_ transaction: WalletEVMTransactionFields) -> Data {
        transactionJSON(
            nonce: transaction.nonce,
            gasLimit: transaction.gasLimit,
            maxFeePerGas: transaction.maxFeePerGas,
            priorityFeePerGas: transaction.maxPriorityFeePerGas,
            recipient: transaction.to,
            value: transaction.value,
            input: transaction.input
        )
    }

    private static func constantV2QuoteRuntime(
        amountIn: UInt64,
        amountOut: UInt64
    ) -> String {
        func word(_ value: UInt64) -> String {
            let raw = String(value, radix: 16)
            return String(repeating: "0", count: 64 - raw.count) + raw
        }
        // Copy and return four ABI words: dynamic offset, element count,
        // input amount, and output amount. The code is deliberately tiny and
        // immutable; Anvil supplies only a deterministic on-chain quote oracle
        // for exercising the production RPC and checked-math path.
        return "0x6080600c60003960806000f3"
            + word(32) + word(2) + word(amountIn) + word(amountOut)
    }

    private static let statefulERC20AllowanceRuntime =
        "0x5f3560e01c8063dd62ed3e14601c578063095ea7b3146026575f5ffd"
        + "5b505f545f5260205ff35b506024355f5560015f5260205ff3"

    private static let statefulPermit2AllowanceRuntime =
        "0x366064146015576044355f556064356001555f5ff35b5f545f526001"
        + "5460205260025460405260605ff3"

    private func codeHash(address: String, endpoint: String) async throws -> String? {
        let runtime = try await rawRPC(
            endpoint: endpoint, method: "eth_getCode", params: [address, "latest"]
        )
        guard let runtime = runtime as? String else { return nil }
        return try await rawRPC(
            endpoint: endpoint, method: "web3_sha3", params: [runtime]
        ) as? String
    }

    private func ethCallWords(
        address: String, data: String, endpoint: String
    ) async throws -> [String] {
        let encoded = try await rawRPC(
            endpoint: endpoint, method: "eth_call",
            params: [["to": address, "data": data], "latest"]
        )
        let value = try XCTUnwrap(encoded as? String)
        let raw = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard raw.count.isMultiple(of: 64), raw.allSatisfy(\.isHexDigit) else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        return stride(from: 0, to: raw.count, by: 64).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 64)
            return WalletEthereumQuantity.hexToDecimal(String(raw[start..<end])) ?? ""
        }
    }

    private func transactionJSON(
        nonce: UInt64,
        gasLimit: UInt64,
        maxFeePerGas: String,
        priorityFeePerGas: String,
        recipient: String,
        value: String,
        input: String = "0x"
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "chain_id": WalletSepoliaRPCClient.chainID,
            "nonce": nonce,
            "gas_limit": gasLimit,
            "max_fee_per_gas": maxFeePerGas,
            "max_priority_fee_per_gas": priorityFeePerGas,
            "to": recipient,
            "value": value,
            "input": input,
        ], options: [.sortedKeys])
    }

    private func rustPrepared(transaction: Data) throws -> RustPreparedTransaction {
        try rustCall(transaction: transaction, function: rustPrepareEVMTransaction)
    }

    private func rustSigned(transaction: Data) throws -> RustSignedTransaction {
        try rustCall(transaction: transaction, function: rustSignEVMTransaction)
    }

    private func rustEncoded(
        _ call: WalletEVMReviewedSemanticCall,
        entry: WalletContractRegistryEntry
    ) throws -> WalletEncodedContractCall {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(RustContractCallRequest(
            normalizedABI: entry.normalizedABI,
            function: call.function, arguments: call.arguments
        ))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let pointer = text.withCString { rustEncodeContractCall($0) }
        let resultPointer = try XCTUnwrap(pointer)
        defer { rustFreeString(resultPointer) }
        let decoded = try JSONDecoder().decode(
            RustEncodedContractCall.self,
            from: Data(String(cString: resultPointer).utf8)
        )
        return WalletEncodedContractCall(input: decoded.input)
    }

    private func registryEntry(
        id: String,
        address: String,
        abi: String,
        functions: [String],
        selectors: [String],
        adapter: String,
        runtimeHash: String
    ) -> WalletContractRegistryEntry {
        let abiDigest = "sha256:" + SHA256.hash(data: Data(abi.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return WalletContractRegistryEntry(
            id: id, networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: address, label: id, normalizedABI: abi,
            abiDigest: abiDigest, runtimeCodeHash: runtimeHash,
            permittedFunctions: functions, permittedSelectors: selectors,
            reviewedAdapterID: adapter, verifiedAt: Date()
        )
    }

    private func executeReviewedAction(
        _ action: WalletSemanticAction,
        entry: WalletContractRegistryEntry,
        materialized: WalletEVMReviewedSemanticCall,
        client: WalletSepoliaRPCClient,
        endpoint: String,
        from: String
    ) async throws {
        let encoded = try rustEncoded(materialized, entry: entry)
        let request = WalletPrepareRequest(
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: "locus-vault-evm-0", source: .human,
            action: action, maximumFeeBaseUnits: "100000000000000000"
        )
        let packet = try await client.prepare(
            request: request, fromAddress: from,
            contract: entry, encodedContract: encoded
        )
        let signed = try rustSigned(transaction: transactionJSON(packet.transaction))
        let broadcast = try await client.broadcast(rawTransaction: signed.rawTransaction)
        XCTAssertEqual(broadcast.lowercased(), signed.transactionHash.lowercased())
        let receipt = try await waitForReceipt(hash: broadcast, client: client)
        XCTAssertEqual(receipt["status"] as? String, "0x1")
        let fetched = try await rawRPC(
            endpoint: endpoint, method: "eth_getTransactionByHash",
            params: [broadcast]
        ) as? [String: Any]
        XCTAssertEqual(
            (fetched?["to"] as? String)?.lowercased(),
            entry.checksumAddress.lowercased()
        )
        XCTAssertEqual(
            (fetched?["input"] as? String)?.lowercased(),
            encoded.input.lowercased()
        )
        // These tiny contracts exercise transport and encoding, not balances
        // or ownership. A successful receipt must not certify economic effects.
        let reconciliation = try WalletSubmittedTransactionReconciler.reconcileEVMObservedTransaction(
            transactionID: broadcast, network: WalletNetworkCatalog.ethereumSepolia,
            account: WalletAccount(id: "local-external", chain: .evm, address: from,
                label: "Local fixture", networkIDs: [WalletGateway.sepoliaNetworkID],
                ownership: .external(connectorID: .metamask)),
            expectedAction: action, expectedContractAddress: entry.checksumAddress,
            transaction: try XCTUnwrap(fetched), receipt: receipt
        )
        guard case .failed = reconciliation else {
            return XCTFail("A success-only fixture cannot prove reviewed token, NFT, swap or allowance effects.")
        }
    }

    private func rustCall<T: Decodable>(
        transaction: Data,
        function: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> T {
        let transactionText = try XCTUnwrap(String(data: transaction, encoding: .utf8))
        let pointer = Self.entropy.withCString { entropy in
            transactionText.withCString { json in function(entropy, json) }
        }
        let resultPointer = try XCTUnwrap(pointer)
        defer { rustFreeString(resultPointer) }
        return try JSONDecoder().decode(T.self, from: Data(String(cString: resultPointer).utf8))
    }

    private func rawRPC(endpoint: String, method: String, params: [Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        if let error = object["error"] { throw NSError(
            domain: "AnvilRPC", code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
        ) }
        return object["result"] ?? NSNull()
    }

    private func waitForReceipt(
        hash: String,
        client: WalletSepoliaRPCClient
    ) async throws -> [String: Any] {
        for _ in 0..<50 {
            if let receipt = try await client.publicRead(
                method: "eth_getTransactionReceipt", params: [hash]
            ) as? [String: Any] {
                return receipt
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Anvil did not return the transaction receipt.")
        return [:]
    }
}
