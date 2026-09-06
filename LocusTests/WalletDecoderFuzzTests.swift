import Foundation
import XCTest
@testable import Locus

@MainActor
final class WalletDecoderFuzzTests: XCTestCase {
    private struct BranchSeed: Decodable {
        let target: String
        let name: String
        let transactionBase64: String
        let expectedKind: WalletActionKind?
        let reads: [String]
    }

    private actor ReadRecorder {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private func branchSeeds() throws -> [BranchSeed] {
        try JSONDecoder().decode([BranchSeed].self, from: walletFuzzCorpus("transactions/decoder-branches.json"))
    }

    private func decodeBranch(
        _ seed: BranchSeed, evidence: WalletDappTransactionDecoder.ReadOnlyEvidence
    ) async throws -> WalletSemanticAction {
        let bytes = try XCTUnwrap(Data(base64Encoded: seed.transactionBase64))
        XCTAssertEqual(bytes.base64EncodedString(), seed.transactionBase64)
        XCTAssertLessThanOrEqual(bytes.count, 16_384)
        if seed.target == "solana_decoder" {
            let account = WalletAccount(id: "fixture-solana", chain: .solana,
                address: WalletFuzzDecoderFixtures.solanaOwner, label: "Synthetic", networkIDs: ["solana:devnet"])
            return try await WalletDappTransactionDecoder.solana(
                .init(transactionBase64: seed.transactionBase64, accountAddress: account.address, minimumContextSlot: nil),
                networkID: "solana:devnet", account: account, evidence: evidence
            )
        }
        XCTAssertEqual(seed.target, "sui_decoder")
        let account = WalletAccount(id: "fixture-sui", chain: .sui,
            address: WalletFuzzDecoderFixtures.suiOwner, label: "Synthetic", networkIDs: ["sui:mainnet"])
        return try await WalletDappTransactionDecoder.sui(
            .init(transactionBase64: seed.transactionBase64, accountAddress: account.address),
            networkID: "sui:mainnet", account: account,
            reviewedAssets: WalletFuzzDecoderFixtures.reviewedAssets, evidence: evidence
        )
    }

    func testDeterministicReadOnlyFixturesReachExactDecoderBranches() async throws {
        let seeds = try branchSeeds()
        XCTAssertEqual(seeds.count, 10)
        XCTAssertEqual(Set(seeds.map(\.name)).count, seeds.count)
        for seed in seeds {
            let recorder = ReadRecorder()
            let evidence = WalletFuzzDecoderFixtures.evidence { await recorder.append($0) }
            if seed.expectedKind == nil {
                do {
                    _ = try await decodeBranch(seed, evidence: evidence)
                    XCTFail("Rejected seed \(seed.name) reached a semantic action.")
                } catch WalletGateway.Error.invalidArguments { /* Expected narrow decoder rejection. */ }
            } else {
                let result = try await decodeBranch(seed, evidence: evidence)
                XCTAssertEqual(result.type, seed.expectedKind, seed.name)
                switch seed.name {
                case "spl-existing-ata", "spl-new-ata":
                    XCTAssertEqual(result, .fungibleTokenTransfer(
                        assetID: "solana:devnet/spl:\(WalletFuzzDecoderFixtures.solanaAddress(13))",
                        recipient: WalletFuzzDecoderFixtures.solanaRecipient, amountBaseUnits: "25"))
                case "v0-native-lookup":
                    XCTAssertEqual(result, .nativeTransfer(
                        recipient: WalletFuzzDecoderFixtures.solanaRecipient, amountBaseUnits: "25"))
                case "core-standalone":
                    let asset = WalletFuzzDecoderFixtures.solanaAddress(20)
                    XCTAssertEqual(result, .nftTransfer(assetID: "solana:devnet/nft:core:\(asset)",
                        tokenID: asset, recipient: WalletFuzzDecoderFixtures.solanaRecipient))
                case "coin":
                    XCTAssertEqual(result, .fungibleTokenTransfer(assetID: WalletFuzzDecoderFixtures.suiCoinID,
                        recipient: WalletFuzzDecoderFixtures.suiRecipient, amountBaseUnits: "25"))
                case "public-object":
                    let object = WalletFuzzDecoderFixtures.suiAddress(0x66)
                    XCTAssertEqual(result, .nftTransfer(assetID: "sui:mainnet/object:\(object)",
                        tokenID: object, recipient: WalletFuzzDecoderFixtures.suiRecipient))
                default: XCTFail("Unasserted decoder success branch \(seed.name)")
                }
            }
            let reads = await recorder.values
            XCTAssertEqual(reads, seed.reads, "The awaited read sequence must match \(seed.name).")
        }
    }

    func testReadOnlyDecoderFixturesRejectUnmatchedRequests() async throws {
        let fixture = WalletFuzzDecoderFixtures.evidence()
        for (network, address, encoding) in [
            ("solana:mainnet", WalletFuzzDecoderFixtures.solanaAddress(11), WalletDappTransactionDecoder.SolanaAccountEncoding.jsonParsed),
            ("solana:devnet", WalletFuzzDecoderFixtures.solanaAddress(99), .jsonParsed),
            ("solana:devnet", WalletFuzzDecoderFixtures.solanaAddress(11), .base64),
        ] {
            do { _ = try await fixture.solanaAccountInfo(network, address, encoding); XCTFail("Unmatched account read accepted") }
            catch WalletFuzzDecoderFixtures.Error.unmatchedRead { /* No fallback provider exists. */ }
        }
        for (network, owner, coinType) in [
            ("sui:testnet", WalletFuzzDecoderFixtures.suiOwner, WalletFuzzDecoderFixtures.suiCoinType),
            ("sui:mainnet", WalletFuzzDecoderFixtures.suiAddress(99), WalletFuzzDecoderFixtures.suiCoinType),
            ("sui:mainnet", WalletFuzzDecoderFixtures.suiOwner, "0x1234::other::COIN"),
        ] {
            do { _ = try await fixture.suiCoinObjects(network, owner, coinType); XCTFail("Unmatched coin read accepted") }
            catch WalletFuzzDecoderFixtures.Error.unmatchedRead { /* No fallback provider exists. */ }
        }
        do { _ = try await fixture.suiOwnedObjects("sui:mainnet", WalletFuzzDecoderFixtures.suiAddress(99)); XCTFail("Unmatched owner accepted") }
        catch WalletFuzzDecoderFixtures.Error.unmatchedRead { /* No fallback provider exists. */ }
    }

    func testReadOnlySolanaEvidenceStillParsesAndRejectsSubstitution() async throws {
        let seeds = try branchSeeds()
        let token = try XCTUnwrap(seeds.first { $0.name == "spl-existing-ata" })
        let base = WalletFuzzDecoderFixtures.evidence()
        for field in ["owner", "mint", "decimals", "program"] {
            let evidence = WalletDappTransactionDecoder.ReadOnlyEvidence(solanaAccountInfo: { network, address, encoding in
                let data = try await base.solanaAccountInfo(network, address, encoding)
                guard address == WalletFuzzDecoderFixtures.solanaAddress(11) else { return data }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var value = try XCTUnwrap(object["value"] as? [String: Any])
                var accountData = try XCTUnwrap(value["data"] as? [String: Any])
                var parsed = try XCTUnwrap(accountData["parsed"] as? [String: Any])
                var info = try XCTUnwrap(parsed["info"] as? [String: Any])
                if field == "program" { value["owner"] = WalletFuzzDecoderFixtures.solanaAddress(99) }
                else if field == "decimals" { info["tokenAmount"] = ["decimals": 7] }
                else { info[field] = WalletFuzzDecoderFixtures.solanaAddress(99) }
                parsed["info"] = info; accountData["parsed"] = parsed; value["data"] = accountData; object["value"] = value
                return try JSONSerialization.data(withJSONObject: object)
            }, suiCoinObjects: base.suiCoinObjects, suiOwnedObjects: base.suiOwnedObjects)
            do { _ = try await decodeBranch(token, evidence: evidence); XCTFail("Substituted \(field) accepted") }
            catch WalletGateway.Error.invalidArguments { /* Production parser and semantic binding remain authoritative. */ }
        }
    }

    func testReadOnlyDecoderEvidenceSizeBoundsFailClosed() async throws {
        let seeds = try branchSeeds()
        let token = try XCTUnwrap(seeds.first { $0.name == "spl-existing-ata" })
        let base = WalletFuzzDecoderFixtures.evidence()
        let oversized = WalletDappTransactionDecoder.ReadOnlyEvidence(
            solanaAccountInfo: { _, _, _ in Data(repeating: 0x20, count: 65_537) },
            suiCoinObjects: base.suiCoinObjects, suiOwnedObjects: base.suiOwnedObjects
        )
        do { _ = try await decodeBranch(token, evidence: oversized); XCTFail("Oversized evidence accepted") }
        catch WalletGateway.Error.invalidArguments { /* The read-only seam cannot provide unbounded parser input. */ }
    }

    func testDedicatedFuzzFixtureSelfTestRequiresEverySuccessBranch() async throws {
        let report = try await WalletFuzzDecoderFixtures.verifySuccessBranches()
        XCTAssertEqual(report.passedBranches, [
            "solana.core-standalone", "solana.native-transfer", "solana.spl-existing-ata", "solana.spl-new-ata",
            "solana.v0-native-lookup", "sui.coin", "sui.native-transfer", "sui.public-object",
        ])
        XCTAssertEqual(report.readCounts, [
            "solana.core-standalone": 0, "solana.native-transfer": 0, "solana.spl-existing-ata": 2,
            "solana.spl-new-ata": 1, "solana.v0-native-lookup": 1, "sui.coin": 1,
            "sui.native-transfer": 0, "sui.public-object": 1,
        ])
    }

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
                networkID: "solana:devnet", account: solanaAccount,
                evidence: WalletFuzzDecoderFixtures.evidence()
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
                reviewedAssets: [], evidence: WalletFuzzDecoderFixtures.evidence()
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
