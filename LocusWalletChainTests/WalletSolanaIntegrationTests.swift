import CryptoKit
import Foundation
import XCTest
@testable import Locus

@_silgen_name("locus_wallet_sign_solana_native_transfer_json")
private func rustSignSolanaNativeTransfer(
    _ entropyHex: UnsafePointer<CChar>,
    _ transactionJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("locus_wallet_string_free")
private func rustFreeSolanaString(_ value: UnsafeMutablePointer<CChar>)

private struct RustSignedSolanaTransaction: Decodable {
    let from: String
    let canonicalMessageDigest: String
    let transactionID: String
    let signedTransaction: String

    enum CodingKeys: String, CodingKey {
        case from
        case canonicalMessageDigest = "canonical_message_digest"
        case transactionID = "transaction_id"
        case signedTransaction = "signed_transaction"
    }
}

@MainActor
final class WalletSolanaIntegrationTests: XCTestCase {
    private static let pinnedValidatorVersion = "4.1.2"
    private static let entropy = String(repeating: "00", count: 32)
    private static let signer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
    private static let recipient = "US517G5965aydkZ46HS38QLi7UQiSojurfbQfKCELFx"

    func testPinnedValidatorNativeTransferSigningBroadcastAndReconciliation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_SOLANA_VALIDATOR_RPC_URL"],
              let genesisHash = environment["LOCUS_SOLANA_VALIDATOR_GENESIS_HASH"],
              !endpoint.isEmpty, !genesisHash.isEmpty else {
            throw XCTSkip("Run Tools/RunWalletSolanaTests.sh with pinned Agave v4.1.2.")
        }
        XCTAssertEqual(
            environment["LOCUS_SOLANA_VALIDATOR_VERSION"],
            Self.pinnedValidatorVersion
        )
        let client = try WalletSolanaRPCClient(
            testLoopbackEndpoint: endpoint,
            expectedGenesisHash: genesisHash
        )
        let health = try await client.health()
        XCTAssertTrue(health.contains("verified genesis"))

        _ = try await solanaRPC(
            endpoint: endpoint, method: "requestAirdrop",
            params: [Self.signer, 5_000_000_000]
        )
        try await waitForBalance(
            minimum: 5_000_000_000, address: Self.signer, client: client
        )
        let recipientBefore = try await client.balance(address: Self.recipient)

        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.canonicalID,
            accountID: "locus-vault-solana-0", source: .human,
            action: .nativeTransfer(
                recipient: Self.recipient, amountBaseUnits: "1234567"
            ),
            maximumFeeBaseUnits: "1000000"
        )
        let packet = try await client.prepare(
            request: request, feePayer: Self.signer
        )
        let recheck = try await client.externalRecheck(
            intentID: "solana-local-native", packet: packet
        )
        XCTAssertEqual(
            recheck.evidence.resolvedAccountsDigest,
            packet.resolvedAccountsDigest
        )
        XCTAssertEqual(
            recheck.materialDigestForTesting,
            packet.canonicalMessageDigest
        )

        let signed = try sign(packet: packet)
        XCTAssertEqual(signed.from, Self.signer)
        XCTAssertEqual(
            signed.canonicalMessageDigest, packet.canonicalMessageDigest
        )
        let transactionID = try await client.broadcast(
            signedTransaction: signed.signedTransaction,
            expectedTransactionID: signed.transactionID,
            minimumContextSlot: packet.contextSlot
        )
        XCTAssertEqual(transactionID, signed.transactionID)
        try await waitForFinalized(
            signature: transactionID, endpoint: endpoint
        )

        let recipientAfter = try await client.balance(address: Self.recipient)
        XCTAssertEqual(
            WalletBaseUnits.subtract(recipientAfter, recipientBefore), "1234567"
        )
        let fetched = try await client.publicRead(
            method: "getTransaction",
            params: [
                transactionID,
                ["commitment": "finalized", "encoding": "jsonParsed",
                 "maxSupportedTransactionVersion": 0],
            ]
        ) as? [String: Any]
        let transaction = fetched?["transaction"] as? [String: Any]
        let message = transaction?["message"] as? [String: Any]
        let keys = message?["accountKeys"] as? [[String: Any]]
        XCTAssertEqual(keys?.first?["pubkey"] as? String, Self.signer)
        XCTAssertTrue(keys?.contains(where: {
            $0["pubkey"] as? String == Self.recipient
        }) == true)
    }

    func testLocalValidatorIdentityMalformedSignatureAndProductionTransportFailClosed() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_SOLANA_VALIDATOR_RPC_URL"],
              let genesisHash = environment["LOCUS_SOLANA_VALIDATOR_GENESIS_HASH"] else {
            throw XCTSkip("Run Tools/RunWalletSolanaTests.sh with pinned Agave v4.1.2.")
        }
        XCTAssertThrowsError(try WalletSolanaRPCClient(
            testLoopbackEndpoint: "http://example.com:8899",
            expectedGenesisHash: genesisHash
        ))
        XCTAssertThrowsError(try WalletSolanaRPCClient(
            network: WalletNetworkCatalog.solanaDevnet, endpoint: endpoint
        ))

        let wrongGenesis = WalletSolanaBase58.encode(Data(repeating: 0x77, count: 32))
        let wrong = try WalletSolanaRPCClient(
            testLoopbackEndpoint: endpoint,
            expectedGenesisHash: wrongGenesis
        )
        do {
            _ = try await wrong.health()
            XCTFail("A substituted local genesis hash must fail closed.")
        } catch WalletRPCError.wrongChain {
            // Expected.
        }

        let client = try WalletSolanaRPCClient(
            testLoopbackEndpoint: endpoint,
            expectedGenesisHash: genesisHash
        )
        do {
            _ = try await client.broadcast(
                signedTransaction: Data([0, 1, 2]).base64EncodedString(),
                expectedTransactionID: WalletSolanaBase58.encode(
                    Data(repeating: 1, count: 64)
                ),
                minimumContextSlot: 0
            )
            XCTFail("Malformed signed transaction bytes must not reach the validator.")
        } catch WalletGateway.Error.invalidArguments {
            // Expected.
        }
    }

    private func sign(
        packet: WalletSolanaPreparationPacket
    ) throws -> RustSignedSolanaTransaction {
        let action = packet.request.action
        let body = try JSONSerialization.data(withJSONObject: [
            "fee_payer": packet.feePayer,
            "recipient": try XCTUnwrap(action.recipient),
            "recent_blockhash": packet.recentBlockhash,
            "amount_base_units": try XCTUnwrap(action.amountBaseUnits),
            "compute_unit_limit": packet.computeUnitLimit,
            "compute_unit_price_micro_lamports":
                packet.computeUnitPriceMicroLamports,
        ], options: [.sortedKeys])
        let pointer = Self.entropy.withCString { entropy in
            String(decoding: body, as: UTF8.self).withCString { request in
                rustSignSolanaNativeTransfer(entropy, request)
            }
        }
        let result = try XCTUnwrap(pointer)
        defer { rustFreeSolanaString(result) }
        return try JSONDecoder().decode(
            RustSignedSolanaTransaction.self,
            from: Data(String(cString: result).utf8)
        )
    }

    private func waitForBalance(
        minimum: UInt64,
        address: String,
        client: WalletSolanaRPCClient
    ) async throws {
        for _ in 0..<100 {
            if let balance = UInt64(try await client.balance(address: address)),
               balance >= minimum {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "WalletSolanaIntegrationTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "The local validator airdrop did not finalize."]
        )
    }

    private func waitForFinalized(
        signature: String,
        endpoint: String
    ) async throws {
        var lastStatus = "missing"
        // Hosted validators can keep producing confirmations beyond the old
        // forty-second polling window. Wait against a monotonic deadline;
        // never substitute "confirmed" for finalized or broadcast again.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while clock.now < deadline {
            try Task.checkCancellation()
            let value = try await solanaRPC(
                endpoint: endpoint, method: "getSignatureStatuses",
                params: [[signature], ["searchTransactionHistory": true]]
            ) as? [String: Any]
            let statuses = value?["value"] as? [Any]
            if let status = statuses?.first as? [String: Any] {
                lastStatus = String(describing: status)
                if !(status["err"] is NSNull) {
                    throw NSError(
                        domain: "WalletSolanaIntegrationTests", code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "The local Solana transaction failed: \(lastStatus)"]
                    )
                }
                if status["confirmationStatus"] as? String == "finalized" {
                    return
                }
            }
            try await clock.sleep(until: min(
                clock.now.advanced(by: .milliseconds(250)), deadline
            ))
        }
        throw NSError(
            domain: "WalletSolanaIntegrationTests", code: 4,
            userInfo: [NSLocalizedDescriptionKey:
                "The local Solana transaction did not finalize: \(lastStatus)"]
        )
    }

    private func solanaRPC(
        endpoint: String,
        method: String,
        params: [Any]
    ) async throws -> Any {
        var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
        // Bound each local transport operation as well as the polling loop.
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        if let error = object["error"] {
            throw NSError(
                domain: "WalletSolanaIntegrationTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
            )
        }
        return try XCTUnwrap(object["result"])
    }
}

private extension WalletSolanaExternalRecheckMaterial {
    var materialDigestForTesting: String {
        "sha256:" + SHA256.hash(data: unsignedTransaction.dropFirst(1 + 64))
            .map { String(format: "%02x", $0) }.joined()
    }
}
