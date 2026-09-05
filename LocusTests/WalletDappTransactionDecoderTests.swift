import CryptoKit
import XCTest
@testable import Locus

final class WalletDappTransactionDecoderTests: XCTestCase {
    private let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
    private let networkID = "solana:devnet"

    @MainActor
    func testDecodesOnlyCanonicalSingleCommandUniversalRouterCalldata() throws {
        let evmNetwork = WalletGateway.sepoliaNetworkID
        let accountAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let routerAddress = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let input = "\(evmNetwork)/erc20:0x1111111111111111111111111111111111111111"
        let output = "\(evmNetwork)/erc20:0x2222222222222222222222222222222222222222"
        let now = Date(timeIntervalSince1970: 1_000)
        let semantic = WalletSemanticAction.exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: "router", inputAssetID: input,
            outputAssetID: output, amountInBaseUnits: "10",
            minimumOutputBaseUnits: "9", recipient: accountAddress,
            route: WalletExactInputSwapRoute(
                protocolVersion: .v2, pathAssetIDs: [input, output],
                feeTiers: [], minimumHopPriceX36: ["1"],
                quotedOutputBaseUnits: "10", slippageBPS: 1_000,
                deadlineUnixSeconds: "1100"
            )
        )
        let materialized = try XCTUnwrap(
            WalletUniversalRouterV2V3Adapter.contractAction(
                for: semantic, accountAddress: accountAddress,
                networkID: evmNetwork, now: now
            )
        )
        let abi = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],"outputs":[]}]"#
        let digest = "sha256:" + SHA256.hash(data: Data(abi.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let entry = WalletContractRegistryEntry(
            id: "router", networkID: evmNetwork,
            checksumAddress: routerAddress, label: "Router",
            normalizedABI: abi, abiDigest: digest,
            runtimeCodeHash: "0x" + String(repeating: "1", count: 64),
            permittedFunctions: ["execute(bytes,bytes[],uint256)"],
            permittedSelectors: ["0x3593564c"],
            reviewedAdapterID:
                WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            verifiedAt: now
        )
        let calldata = try WalletExternalEVMABIEncoder.encode(
            action: materialized, registryEntry: entry
        )
        let account = WalletAccount(
            id: "evm", chain: .evm, address: accountAddress,
            label: "EVM", networkIDs: [evmNetwork]
        )
        let transaction = WalletConnectorDappRequest.EVMTransaction(
            from: accountAddress, to: routerAddress,
            valueHex: "0x0", dataHex: calldata
        )
        let decoded = try XCTUnwrap(
            WalletDappTransactionDecoder.evmUniversalRouterSwap(
                transaction, networkID: evmNetwork, account: account,
                routerContractID: entry.id,
                routerAddress: routerAddress, now: now
            )
        )
        XCTAssertEqual(decoded.protocolVersion, .v2)
        XCTAssertEqual(decoded.pathAssetIDs, [input, output])
        XCTAssertEqual(decoded.minimumHopPriceX36, ["1"])
        XCTAssertEqual(decoded.deadlineUnixSeconds, "1100")

        var noncanonical = calldata
        let offsetStart = noncanonical.index(
            noncanonical.startIndex, offsetBy: 10
        )
        let offsetEnd = noncanonical.index(offsetStart, offsetBy: 64)
        noncanonical.replaceSubrange(
            offsetStart..<offsetEnd,
            with: String(repeating: "0", count: 62) + "80"
        )
        XCTAssertNil(WalletDappTransactionDecoder.evmUniversalRouterSwap(
            .init(
                from: accountAddress, to: routerAddress,
                valueHex: "0x0", dataHex: noncanonical
            ),
            networkID: evmNetwork, account: account,
            routerContractID: entry.id, routerAddress: routerAddress,
            now: now
        ))
    }

    func testDecodesLegacyAndV0NativeTransferIntoSameSemanticAction() async throws {
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let canonical = try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer,
            recipient: recipient,
            recentBlockhash: WalletSolanaBase58.encode(Data(repeating: 9, count: 32)),
            amountBaseUnits: "123456789"
        )
        let account = vaultAccount()
        let legacy = try await WalletDappTransactionDecoder.solana(
            request(canonical.unsignedTransaction),
            networkID: networkID,
            account: account
        )
        XCTAssertEqual(
            legacy,
            .nativeTransfer(
                recipient: recipient, amountBaseUnits: "123456789"
            )
        )

        var v0 = canonical.unsignedTransaction
        v0.insert(0x80, at: 65)
        v0.append(0) // no address-table lookups
        let versioned = try await WalletDappTransactionDecoder.solana(
            request(v0), networkID: networkID, account: account
        )
        XCTAssertEqual(versioned, legacy)
    }

    func testRejectsSignedOrTrailingSolanaBytes() async throws {
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let canonical = try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer,
            recipient: recipient,
            recentBlockhash: WalletSolanaBase58.encode(Data(repeating: 9, count: 32)),
            amountBaseUnits: "1"
        )
        var signed = canonical.unsignedTransaction
        signed[1] = 1
        await XCTAssertThrowsErrorAsync {
            _ = try await WalletDappTransactionDecoder.solana(
                self.request(signed),
                networkID: self.networkID,
                account: self.vaultAccount()
            )
        }
        var trailing = canonical.unsignedTransaction
        trailing.append(0)
        await XCTAssertThrowsErrorAsync {
            _ = try await WalletDappTransactionDecoder.solana(
                self.request(trailing),
                networkID: self.networkID,
                account: self.vaultAccount()
            )
        }
    }

    func testDecodesOnlyStandaloneCoreTransferShape() async throws {
        let asset = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 8, count: 32))
        let canonical = try WalletSolanaCanonicalCoreTransfer(
            feePayer: payer,
            asset: asset,
            recipient: recipient,
            recentBlockhash: WalletSolanaBase58.encode(Data(repeating: 9, count: 32)),
            assetDataDigest: "sha256:" + String(repeating: "a", count: 64)
        )
        let action = try await WalletDappTransactionDecoder.solana(
            request(canonical.unsignedTransaction),
            networkID: networkID,
            account: vaultAccount()
        )
        XCTAssertEqual(
            action,
            .nftTransfer(
                assetID: "\(networkID)/nft:core:\(asset)",
                tokenID: asset,
                recipient: recipient
            )
        )

        var pluginBearing = canonical.unsignedTransaction
        pluginBearing[pluginBearing.count - 1] = 1
        await XCTAssertThrowsErrorAsync {
            _ = try await WalletDappTransactionDecoder.solana(
                self.request(pluginBearing),
                networkID: self.networkID,
                account: self.vaultAccount()
            )
        }
    }

    func testDecodesCanonicalSuiNativeTransferAndRejectsTrailingBytes() async throws {
        let sender = "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c"
        let recipient = "0x" + String(repeating: "07", count: 32)
        let encoded = "AAACAAgVzVsHAAAAAAAgBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcCAgABAQAAAQEDAAAAAAEBAPln4hwWpHV9qv7BPuecDcXFMpGZvl1wyG/Qe45124ksAQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIKgAAAAAAAAAgCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQn5Z+IcFqR1far+wT7nnA3FxTKRmb5dcMhv0HuOdduJLOgDAAAAAAAAgJaYAAAAAAABnAEAAAAAAAA="
        let account = WalletAccount(
            id: "sui-account", chain: .sui, address: sender,
            label: "Sui", networkIDs: ["sui:mainnet"]
        )
        let request = WalletConnectorDappRequest.SuiTransaction(
            transactionBase64: encoded, accountAddress: sender
        )
        let action = try await WalletDappTransactionDecoder.sui(
            request, networkID: "sui:mainnet", account: account,
            reviewedAssets: []
        )
        XCTAssertEqual(
            action,
            .nativeTransfer(
                recipient: recipient, amountBaseUnits: "123456789"
            )
        )

        var trailing = try XCTUnwrap(Data(base64Encoded: encoded))
        trailing.append(0)
        await XCTAssertThrowsErrorAsync {
            _ = try await WalletDappTransactionDecoder.sui(
                .init(
                    transactionBase64: trailing.base64EncodedString(),
                    accountAddress: sender
                ),
                networkID: "sui:mainnet", account: account,
                reviewedAssets: []
            )
        }
    }

    private func vaultAccount() -> WalletAccount {
        WalletAccount(
            id: "solana-account", chain: .solana, address: payer,
            label: "Solana", networkIDs: [networkID]
        )
    }

    private func request(
        _ transaction: Data
    ) -> WalletConnectorDappRequest.SolanaTransaction {
        .init(
            transactionBase64: transaction.base64EncodedString(),
            accountAddress: payer,
            minimumContextSlot: nil
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
