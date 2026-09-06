import Foundation
#if !LOCUS_WALLET_FUZZ_HOST
@testable import Locus
#endif

/// Public synthetic state shared by native regression tests and the dedicated
/// fuzz executable. This source is not part of either distributed app target.
enum WalletFuzzDecoderFixtures {
    enum Error: Swift.Error { case unmatchedRead, invalidFixture }
    struct SuccessReport: Sendable {
        let passedBranches: [String]
        let readCounts: [String: Int]
    }
    private struct BranchSeed: Decodable {
        let target: String
        let name: String
        let transactionBase64: String
        let expectedKind: WalletActionKind?
        let reads: [String]
    }
    private actor ReadRecorder {
        var reads: [String] = []
        func record(_ read: String) { reads.append(read) }
    }
    static let solanaOwner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
    static let suiOwner = "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c"
    static let solanaRecipient = solanaAddress(7)
    static let suiRecipient = suiAddress(0x22)
    static let suiCoinType = "0x1234::fixture::COIN"
    static let suiCoinID = "sui:mainnet/coin:\(suiCoinType)"
    static let tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    static let lookupProgram = "AddressLookupTab1e1111111111111111111111111"
    static let suiNetwork = WalletSuiNetworkStatus(
        chainIdentifier: WalletSuiChainIdentity.mainnetBase58, checkpointSequence: 100,
        checkpointTimestamp: Date(timeIntervalSince1970: 2_000_000_000), epoch: 7,
        referenceGasPrice: "1000"
    )
    static let reviewedAssets = [WalletAsset(
        canonicalID: suiCoinID, networkID: "sui:mainnet", chain: .sui, kind: .fungibleToken,
        reference: suiCoinType, name: "Synthetic fixture coin", symbol: "FIXTURE", decimals: 6,
        trust: .curated, manifestRevision: 1
    )]

    static func solanaAddress(_ byte: UInt8) -> String {
        WalletSolanaBase58.encode(Data(repeating: byte, count: 32))
    }

    static func suiAddress(_ byte: UInt8) -> String {
        "0x" + String(repeating: String(format: "%02x", byte), count: 32)
    }

    static func evidence(
        onRead: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> WalletDappTransactionDecoder.ReadOnlyEvidence {
        .init(solanaAccountInfo: { networkID, address, encoding in
            await Task.yield()
            guard networkID == "solana:devnet" else { throw Error.unmatchedRead }
            switch encoding {
            case .base64:
                guard address == solanaAddress(40) else { throw Error.unmatchedRead }
                await onRead("solana.lookup")
                // Official 56-byte ALT metadata followed by one recipient.
                var bytes = Data([1, 0, 0, 0])
                bytes.append(Data(repeating: 0xff, count: 8))
                bytes.append(Data([1, 0, 0, 0, 0, 0, 0, 0]))
                bytes.append(Data(repeating: 0, count: 36))
                bytes.append(Data(repeating: 7, count: 32))
                return try JSONSerialization.data(withJSONObject: [
                    "context": ["slot": 100],
                    "value": ["owner": lookupProgram, "data": [bytes.base64EncodedString(), "base64"]],
                ])
            case .jsonParsed:
                guard [solanaAddress(11), solanaAddress(12)].contains(address) else { throw Error.unmatchedRead }
                let source = address == solanaAddress(11)
                await onRead(source ? "solana.source" : "solana.destination")
                return try JSONSerialization.data(withJSONObject: [
                    "context": ["slot": 100],
                    "value": ["owner": tokenProgram, "data": ["parsed": [
                        "type": "account", "info": [
                            "owner": source ? solanaOwner : solanaRecipient, "mint": solanaAddress(13),
                            "tokenAmount": ["decimals": 6, "amount": "1000000"],
                        ],
                    ]]],
                ])
            }
        }, suiCoinObjects: { networkID, owner, coinType in
            await Task.yield()
            guard networkID == "sui:mainnet", owner == suiOwner, coinType == suiCoinType else {
                throw Error.unmatchedRead
            }
            await onRead("sui.coin")
            let identity = WalletSuiAssetIdentity(networkID: "sui:mainnet", coinType: suiCoinType)
            return WalletSuiCoinObjectSnapshot(
                network: suiNetwork, owner: suiOwner, identity: identity, totalBalance: "1000000",
                coinBalance: "1000000", addressBalance: "0", objects: [WalletSuiCoinObject(
                    reference: .init(objectID: suiAddress(0x44), version: 7,
                        digest: solanaAddress(0x44), type: "0x2::coin::Coin<\(suiCoinType)>"),
                    owner: suiOwner, identity: identity, balanceBaseUnits: "1000000"
                )]
            )
        }, suiOwnedObjects: { networkID, owner in
            await Task.yield()
            guard networkID == "sui:mainnet", owner == suiOwner else { throw Error.unmatchedRead }
            await onRead("sui.object")
            return WalletSuiOwnedObjectSnapshot(network: suiNetwork, owner: suiOwner, objects: [
                WalletSuiOwnedObject(identity: .init(networkID: "sui:mainnet", objectID: suiAddress(0x66)),
                    version: 7, digest: solanaAddress(0x66), moveType: "0x1234::fixture::OBJECT", hasPublicTransfer: true),
            ])
        })
    }

    /// Runs before any campaign CPU clock. This proves that the awaited fixture
    /// seam reaches production success branches, not just app/JSON startup code.
    static func verifySuccessBranches() async throws -> SuccessReport {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("FuzzCorpus")
        func corpus(_ path: String) throws -> Data {
            let url = root.appendingPathComponent(path)
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size <= 65_536 else { throw Error.invalidFixture }
            return try Data(contentsOf: url)
        }
        let seeds = try JSONDecoder().decode([BranchSeed].self, from: corpus("transactions/decoder-branches.json"))
        guard seeds.count == 10, Set(seeds.map(\.name)).count == seeds.count else { throw Error.invalidFixture }
        let solana = WalletAccount(id: "fixture-solana", chain: .solana, address: solanaOwner,
            label: "Synthetic", networkIDs: ["solana:devnet"])
        let sui = WalletAccount(id: "fixture-sui", chain: .sui, address: suiOwner,
            label: "Synthetic", networkIDs: ["sui:mainnet"])
        var counts: [String: Int] = [:]
        for seed in seeds where seed.expectedKind != nil {
            guard let bytes = Data(base64Encoded: seed.transactionBase64),
                  bytes.base64EncodedString() == seed.transactionBase64, bytes.count <= 16_384 else {
                throw Error.invalidFixture
            }
            let recorder = ReadRecorder()
            let source = evidence { await recorder.record($0) }
            let result: WalletSemanticAction
            let expected: WalletSemanticAction
            let branch: String
            if seed.target == "solana_decoder" {
                result = try await WalletDappTransactionDecoder.solana(
                    .init(transactionBase64: seed.transactionBase64, accountAddress: solana.address, minimumContextSlot: nil),
                    networkID: "solana:devnet", account: solana, evidence: source)
                branch = "solana.\(seed.name)"
                switch seed.name {
                case "spl-existing-ata", "spl-new-ata":
                    expected = .fungibleTokenTransfer(assetID: "solana:devnet/spl:\(solanaAddress(13))",
                        recipient: solanaRecipient, amountBaseUnits: "25")
                case "v0-native-lookup": expected = .nativeTransfer(recipient: solanaRecipient, amountBaseUnits: "25")
                case "core-standalone":
                    expected = .nftTransfer(assetID: "solana:devnet/nft:core:\(solanaAddress(20))",
                        tokenID: solanaAddress(20), recipient: solanaRecipient)
                default: throw Error.invalidFixture
                }
            } else {
                guard seed.target == "sui_decoder" else { throw Error.invalidFixture }
                result = try await WalletDappTransactionDecoder.sui(
                    .init(transactionBase64: seed.transactionBase64, accountAddress: sui.address),
                    networkID: "sui:mainnet", account: sui, reviewedAssets: reviewedAssets, evidence: source)
                branch = "sui.\(seed.name)"
                switch seed.name {
                case "coin": expected = .fungibleTokenTransfer(assetID: suiCoinID, recipient: suiRecipient, amountBaseUnits: "25")
                case "public-object":
                    expected = .nftTransfer(assetID: "sui:mainnet/object:\(suiAddress(0x66))",
                        tokenID: suiAddress(0x66), recipient: suiRecipient)
                default: throw Error.invalidFixture
                }
            }
            let reads = await recorder.reads
            guard result == expected, result.type == seed.expectedKind, reads == seed.reads else { throw Error.invalidFixture }
            counts[branch] = reads.count
        }
        let source = evidence()
        let native = try WalletSolanaCanonicalNativeTransfer(feePayer: solana.address,
            recipient: solanaRecipient, recentBlockhash: solanaAddress(9), amountBaseUnits: "123456789")
        let solanaNative = try await WalletDappTransactionDecoder.solana(
            .init(transactionBase64: native.unsignedTransaction.base64EncodedString(), accountAddress: solana.address,
                minimumContextSlot: nil), networkID: "solana:devnet", account: solana, evidence: source)
        guard solanaNative == .nativeTransfer(recipient: solanaRecipient, amountBaseUnits: "123456789") else {
            throw Error.invalidFixture
        }
        counts["solana.native-transfer"] = 0
        let suiNativeText = String(decoding: try corpus("sui/native-transfer.b64"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suiNative = try await WalletDappTransactionDecoder.sui(
            .init(transactionBase64: suiNativeText, accountAddress: sui.address), networkID: "sui:mainnet",
            account: sui, reviewedAssets: [], evidence: source)
        guard suiNative == .nativeTransfer(recipient: suiAddress(7), amountBaseUnits: "123456789") else {
            throw Error.invalidFixture
        }
        counts["sui.native-transfer"] = 0
        guard counts.count == 8 else { throw Error.invalidFixture }
        return SuccessReport(passedBranches: counts.keys.sorted(), readCounts: counts)
    }
}
