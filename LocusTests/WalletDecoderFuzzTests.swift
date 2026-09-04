import Foundation
import XCTest
@testable import Locus

@MainActor
final class WalletDecoderFuzzTests: XCTestCase {
    private struct SolanaSeed: Decodable {
        let amountBaseUnits: String
        let feePayer: String
        let recentBlockhashByte: UInt8
        let recipientByte: UInt8
    }

    private struct QuoteSeed: Decodable {
        let denominators: [String]
        let values: [String]
    }

    func testTransactionDecoderMutationCorpus() async throws {
        var generator = WalletFuzzGenerator()
        let evmAccount = WalletAccount(
            id: "evm", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "EVM", networkIDs: [WalletGateway.sepoliaNetworkID]
        )
        let evmSeed = try walletFuzzCorpus("evm/erc20-transfer.hex")
        let evmBytes = try XCTUnwrap(Data(hex: String(
            decoding: evmSeed, as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(try WalletDappTransactionDecoder.evm(
            .init(
                from: evmAccount.address,
                to: "0x3333333333333333333333333333333333333333",
                valueHex: "0x0", dataHex: "0x" + evmBytes.hexString
            ),
            networkID: WalletGateway.sepoliaNetworkID, account: evmAccount
        ).type, .fungibleTokenTransfer)
        for iteration in 0..<128 {
            let data = generator.mutate(evmBytes, iteration: iteration)
            let request = WalletConnectorDappRequest.EVMTransaction(
                from: evmAccount.address,
                to: "0x3333333333333333333333333333333333333333",
                valueHex: "0x0", dataHex: "0x" + data.hexString
            )
            if let action = try? WalletDappTransactionDecoder.evm(
                request, networkID: WalletGateway.sepoliaNetworkID,
                account: evmAccount
            ) {
                XCTAssertTrue([
                    WalletActionKind.fungibleTokenTransfer,
                    .nftTransfer,
                ].contains(action.type))
            }
        }

        let solanaSeed = try JSONDecoder().decode(
            SolanaSeed.self, from: walletFuzzCorpus("solana/native-transfer.json")
        )
        let solanaAccount = WalletAccount(
            id: "solana", chain: .solana, address: solanaSeed.feePayer,
            label: "Solana", networkIDs: ["solana:devnet"]
        )
        let canonicalSolana = try WalletSolanaCanonicalNativeTransfer(
            feePayer: solanaSeed.feePayer,
            recipient: WalletSolanaBase58.encode(
                Data(repeating: solanaSeed.recipientByte, count: 32)
            ),
            recentBlockhash: WalletSolanaBase58.encode(
                Data(repeating: solanaSeed.recentBlockhashByte, count: 32)
            ),
            amountBaseUnits: solanaSeed.amountBaseUnits
        ).unsignedTransaction
        let decodedSolana = try await WalletDappTransactionDecoder.solana(
            .init(
                transactionBase64: canonicalSolana.base64EncodedString(),
                accountAddress: solanaAccount.address, minimumContextSlot: nil
            ),
            networkID: "solana:devnet", account: solanaAccount
        )
        XCTAssertEqual(decodedSolana.type, .nativeTransfer)
        for iteration in 0..<128 {
            let data = generator.mutate(canonicalSolana, iteration: iteration)
            _ = try? await WalletDappTransactionDecoder.solana(
                .init(
                    transactionBase64: data.base64EncodedString(),
                    accountAddress: solanaAccount.address,
                    minimumContextSlot: nil
                ),
                networkID: "solana:devnet", account: solanaAccount
            )
        }

        let suiAccount = WalletAccount(
            id: "sui", chain: .sui,
            address: "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c",
            label: "Sui", networkIDs: ["sui:mainnet"]
        )
        let suiSeedText = String(
            decoding: try walletFuzzCorpus("sui/native-transfer.b64"), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let suiSeed = try XCTUnwrap(Data(base64Encoded: suiSeedText))
        let decodedSui = try await WalletDappTransactionDecoder.sui(
            .init(
                transactionBase64: suiSeed.base64EncodedString(),
                accountAddress: suiAccount.address
            ),
            networkID: "sui:mainnet", account: suiAccount,
            reviewedAssets: []
        )
        XCTAssertEqual(decodedSui.type, .nativeTransfer)
        for iteration in 0..<128 {
            let data = generator.mutate(suiSeed, iteration: iteration)
            _ = try? await WalletDappTransactionDecoder.sui(
                .init(
                    transactionBase64: data.base64EncodedString(),
                    accountAddress: suiAccount.address
                ),
                networkID: "sui:mainnet", account: suiAccount,
                reviewedAssets: []
            )
        }
    }

    func testConnectionNamespaceMetadataAndAuthorizationMutationCorpus() throws {
        var generator = WalletFuzzGenerator()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let namespaceSeed = try walletFuzzCorpus("connections/namespace-proposal.json")
        let recordSeed = try walletFuzzCorpus("connections/public-record.json")
        let authorizationSeed = Data(String(
            decoding: try walletFuzzCorpus("authorization/siwe.txt"), as: UTF8.self
        ).trimmingCharacters(in: .newlines).utf8)
        let account = WalletAccount(
            id: "account-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "EVM", networkIDs: [WalletGateway.sepoliaNetworkID]
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let baselineProposals = try decoder.decode(
            [WalletConnectionNamespaceProposal].self, from: namespaceSeed
        )
        XCTAssertNoThrow(try WalletConnectionNamespaceValidator.validate(
            baselineProposals, connector: .walletConnect,
            direction: .locusVaultToDapp
        ))
        XCTAssertNoThrow(try decoder.decode(
            WalletConnectionRecord.self, from: recordSeed
        ))
        XCTAssertNoThrow(try WalletStructuredAuthorization.parseCanonicalMessage(
            String(decoding: authorizationSeed, as: UTF8.self),
            format: .siwe, origin: "https://app.example",
            networkID: WalletGateway.sepoliaNetworkID,
            account: account, now: now
        ))
        for iteration in 0..<128 {
            let namespaceData = generator.mutate(
                namespaceSeed, iteration: iteration
            )
            if let proposals = try? decoder.decode(
                [WalletConnectionNamespaceProposal].self, from: namespaceData
            ) {
                _ = try? WalletConnectionNamespaceValidator.validate(
                    proposals, connector: .walletConnect,
                    direction: .locusVaultToDapp
                )
            }

            let recordData = generator.mutate(recordSeed, iteration: iteration)
            if let record = try? decoder.decode(
                WalletConnectionRecord.self, from: recordData
            ) {
                let store = try WalletPublicStore(path: ":memory:")
                try? store.upsertConnection(record)
                _ = try? store.loadConnections()
            }

            let authorizationData = generator.mutate(
                authorizationSeed, iteration: iteration
            )
            _ = try? WalletStructuredAuthorization.parseCanonicalMessage(
                String(decoding: authorizationData, as: UTF8.self),
                format: .siwe, origin: "https://app.example",
                networkID: WalletGateway.sepoliaNetworkID,
                account: account, now: now
            )
        }
    }

    func testCheckedQuoteMathMutationCorpus() throws {
        var generator = WalletFuzzGenerator()
        let seed = try JSONDecoder().decode(
            QuoteSeed.self, from: walletFuzzCorpus("quote/checked-math.json")
        )
        for iteration in 0..<256 {
            let raw = generator.mutate(
                Data(seed.values[iteration % seed.values.count].utf8),
                iteration: iteration
            )
            let value = String(decoding: raw, as: UTF8.self)
            let denominator = seed.denominators[
                Int(generator.next() % UInt64(seed.denominators.count))
            ]
            if let division = WalletBaseUnits.divide(value, by: denominator) {
                XCTAssertNotNil(WalletBaseUnits.normalize(division.quotient))
                XCTAssertNotNil(WalletBaseUnits.normalize(division.remainder))
            }
            _ = WalletBaseUnits.applyingBasisPointFloor(
                value, bpsToKeep: Int(generator.next() % 10_002)
            )
        }
    }

}

struct WalletFuzzGenerator {
    var state: UInt64 = 0x4c6f_6375_7357_616c

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func mutate(_ seed: Data, iteration: Int) -> Data {
        var value = seed
        guard !value.isEmpty else { return Data([UInt8(truncatingIfNeeded: next())]) }
        let index = Int(next() % UInt64(value.count))
        value[index] ^= UInt8(1 << (next() % 8))
        if iteration.isMultiple(of: 11), value.count < 2_048 {
            value.append(UInt8(truncatingIfNeeded: next()))
        } else if iteration.isMultiple(of: 13), value.count > 1 {
            value.removeLast()
        }
        return value
    }
}

func walletFuzzCorpus(_ relativePath: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent(
        "FuzzCorpus/\(relativePath)"
    ))
}

private extension Data {
    init?(hex: String) {
        let raw = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard raw.count.isMultiple(of: 2), raw.allSatisfy(\.isHexDigit) else {
            return nil
        }
        self.init()
        reserveCapacity(raw.count / 2)
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw.index(index, offsetBy: 2)
            guard let byte = UInt8(raw[index..<end], radix: 16) else { return nil }
            append(byte)
            index = end
        }
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
