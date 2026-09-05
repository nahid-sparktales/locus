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

/// Test-only evidence checks for the narrow native-transfer smoke. This does
/// not call or stand in for the application's submitted-transaction reconciler.
private enum LocalSolanaSmokeEvidence {
    enum Failure: Error {
        case deadlineExceeded, malformedResponse, transactionFailed, settlementMismatch
    }

    static func remainingRPCBudget(
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant?
    ) throws -> TimeInterval {
        guard let deadline else { return 10 }
        guard now < deadline else { throw Failure.deadlineExceeded }
        let duration = now.duration(to: deadline).components
        let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard remaining.isFinite, remaining > 0 else { throw Failure.deadlineExceeded }
        return min(10, remaining)
    }

    static func finalizedSlot(
        from value: Any,
        receivedAt: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) throws -> UInt64? {
        _ = try remainingRPCBudget(now: receivedAt, deadline: deadline)
        guard let result = value as? [String: Any],
              let statuses = result["value"] as? [Any], statuses.count == 1 else {
            throw Failure.malformedResponse
        }
        if statuses[0] is NSNull { return nil }
        guard let status = statuses[0] as? [String: Any],
              status.keys.contains("err"),
              let slot = unsigned(status["slot"]),
              let confirmation = status["confirmationStatus"] as? String,
              ["processed", "confirmed", "finalized"].contains(confirmation) else {
            throw Failure.malformedResponse
        }
        guard status["err"] is NSNull else { throw Failure.transactionFailed }
        return confirmation == "finalized" ? slot : nil
    }

    static func verifyNativeSettlement(
        _ raw: Any,
        expectedTransfer: WalletSolanaCanonicalNativeTransfer,
        signedBytes: Data,
        signature: String,
        finalizedSlot: UInt64,
        quotedFee: UInt64,
        maximumFee: UInt64
    ) throws {
        guard let result = raw as? [String: Any],
              unsigned(result["slot"]) == finalizedSlot,
              result["version"] as? String == "legacy",
              let encoded = result["transaction"] as? [Any], encoded.count == 2,
              encoded[1] as? String == "base64",
              let base64 = encoded[0] as? String,
              let fetchedBytes = Data(base64Encoded: base64),
              fetchedBytes.base64EncodedString() == base64,
              (66...1_232).contains(signedBytes.count), signedBytes.first == 1,
              expectedTransfer.message.count >= 4,
              fetchedBytes == signedBytes,
              WalletSolanaBase58.encode(signedBytes.subdata(in: 1..<65)) == signature,
              Data(signedBytes.dropFirst(65)) == expectedTransfer.message,
              let meta = result["meta"] as? [String: Any], meta["err"] is NSNull,
              let fee = unsigned(meta["fee"]), fee == quotedFee, fee <= maximumFee,
              let preRaw = meta["preBalances"] as? [Any],
              let postRaw = meta["postBalances"] as? [Any] else {
            throw Failure.settlementMismatch
        }
        // The canonical legacy native adapter fixes payer/recipient at 0/1;
        // exact message equality above also binds all readonly program keys.
        let accountCount = Int(expectedTransfer.message[3])
        guard [3, 4].contains(accountCount),
              preRaw.count == accountCount, postRaw.count == accountCount else {
            throw Failure.settlementMismatch
        }
        let pre = preRaw.compactMap(unsigned)
        let post = postRaw.compactMap(unsigned)
        guard pre.count == accountCount, post.count == accountCount else {
            throw Failure.settlementMismatch
        }
        let debit = pre[0].subtractingReportingOverflow(post[0])
        let credit = post[1].subtractingReportingOverflow(pre[1])
        let amountAndFee = expectedTransfer.lamports.addingReportingOverflow(fee)
        guard !debit.overflow, !credit.overflow, !amountAndFee.overflow,
              debit.partialValue == amountAndFee.partialValue,
              credit.partialValue == expectedTransfer.lamports,
              (2..<accountCount).allSatisfy({ pre[$0] == post[$0] }) else {
            throw Failure.settlementMismatch
        }
    }

    /// JSON booleans, signed/fractional values and lossy floating conversions
    /// must not be interpreted as lamports or slots.
    private static func unsigned(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = UInt64(number.stringValue),
              number.decimalValue == Decimal(value) else { return nil }
        return value
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
        let finalizedSlot = try await waitForFinalized(
            signature: transactionID, endpoint: endpoint
        )

        // Supplementary end-to-end observation only. The finalized receipt
        // below, not these confirmed whole-address reads, proves the effects.
        let recipientAfter = try await client.balance(address: Self.recipient)
        XCTAssertEqual(
            WalletBaseUnits.subtract(recipientAfter, recipientBefore), "1234567"
        )
        let fetched = try await solanaRPC(
            endpoint: endpoint,
            method: "getTransaction",
            params: [
                transactionID,
                ["commitment": "finalized", "encoding": "base64",
                 "maxSupportedTransactionVersion": 0],
            ]
        )
        let expectedTransfer = try WalletSolanaCanonicalNativeTransfer(
            feePayer: Self.signer, recipient: Self.recipient,
            recentBlockhash: packet.recentBlockhash,
            amountBaseUnits: try XCTUnwrap(request.action.amountBaseUnits),
            computeUnitLimit: packet.computeUnitLimit,
            computeUnitPriceMicroLamports: try XCTUnwrap(UInt64(packet.computeUnitPriceMicroLamports))
        )
        XCTAssertEqual(expectedTransfer.canonicalMessageDigest, packet.canonicalMessageDigest)
        XCTAssertGreaterThanOrEqual(finalizedSlot, packet.contextSlot)
        try LocalSolanaSmokeEvidence.verifyNativeSettlement(
            fetched, expectedTransfer: expectedTransfer,
            signedBytes: try XCTUnwrap(Data(base64Encoded: signed.signedTransaction)),
            signature: transactionID, finalizedSlot: finalizedSlot,
            quotedFee: try XCTUnwrap(UInt64(packet.feeQuoteBaseUnits)),
            maximumFee: try XCTUnwrap(UInt64(packet.maximumFeeBaseUnits))
        )
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

    func testSmokeFinalityRequiresTimelyFinalizedSuccessAndCapsRemainingBudget() throws {
        let now = ContinuousClock().now
        let deadline = now.advanced(by: .seconds(120))
        let finalized: [String: Any] = ["value": [[
            "slot": UInt64(42), "err": NSNull(), "confirmationStatus": "finalized",
        ]]]
        XCTAssertEqual(try LocalSolanaSmokeEvidence.remainingRPCBudget(
            now: now, deadline: deadline
        ), 10)
        XCTAssertEqual(try LocalSolanaSmokeEvidence.remainingRPCBudget(
            now: deadline.advanced(by: .milliseconds(-125)), deadline: deadline
        ), 0.125, accuracy: 0.000001)
        XCTAssertEqual(try LocalSolanaSmokeEvidence.finalizedSlot(
            from: finalized, receivedAt: now, deadline: deadline
        ), 42)
        for receivedAt in [deadline, deadline.advanced(by: .seconds(1))] {
            XCTAssertThrowsError(try LocalSolanaSmokeEvidence.finalizedSlot(
                from: finalized, receivedAt: receivedAt, deadline: deadline
            ))
        }
        let confirmed: [String: Any] = ["value": [[
            "slot": UInt64(42), "err": NSNull(), "confirmationStatus": "confirmed",
        ]]]
        XCTAssertNil(try LocalSolanaSmokeEvidence.finalizedSlot(
            from: confirmed, receivedAt: now, deadline: deadline
        ))
        for status: [String: Any] in [
            ["slot": UInt64(42), "confirmationStatus": "finalized"],
            ["slot": UInt64(42), "err": ["InstructionError": [0, "failure"]],
             "confirmationStatus": "finalized"],
            ["slot": true, "err": NSNull(), "confirmationStatus": "finalized"],
        ] {
            XCTAssertThrowsError(try LocalSolanaSmokeEvidence.finalizedSlot(
                from: ["value": [status]], receivedAt: now, deadline: deadline
            ))
        }
    }

    func testSmokeNativeSettlementBindsExactWireSignatureSlotAndSuccess() throws {
        let fixture = try nativeSettlementFixture()
        XCTAssertNoThrow(try verifySettlement(fixture))
        var changed = fixture.receipt
        var changedBytes = fixture.signedBytes
        changedBytes[changedBytes.count - 1] ^= 1
        changed["transaction"] = [changedBytes.base64EncodedString(), "base64"]
        XCTAssertThrowsError(try verifySettlement(fixture, receipt: changed))
        // Even an expected-wire substitution cannot change the reviewed
        // canonical message while retaining a superficially matching signature.
        XCTAssertThrowsError(try verifySettlement(
            fixture, receipt: changed, signedBytes: changedBytes
        ))
        XCTAssertThrowsError(try verifySettlement(
            fixture, signature: WalletSolanaBase58.encode(Data(repeating: 0x55, count: 64))
        ))
        changed = fixture.receipt
        changed["slot"] = UInt64(43)
        XCTAssertThrowsError(try verifySettlement(fixture, receipt: changed))
        for error: Any in [NSNull(), ["InstructionError": [0, "failure"]]] {
            changed = fixture.receipt
            var meta = try XCTUnwrap(changed["meta"] as? [String: Any])
            if error is NSNull { meta.removeValue(forKey: "err") }
            else { meta["err"] = error }
            changed["meta"] = meta
            XCTAssertThrowsError(try verifySettlement(fixture, receipt: changed))
        }
    }

    func testSmokeNativeSettlementRejectsWrongEffectsFeesAndUncheckedArithmetic() throws {
        let fixture = try nativeSettlementFixture()
        // Sender, recipient, and unrelated program-account substitutions each
        // fail even when the fetched transaction bytes themselves are exact.
        for post: [UInt64] in [
            [4_998_760_434, 4_234_567, 1, 1],
            [4_998_760_433, 4_234_568, 1, 1],
            [4_998_760_433, 4_234_567, 2, 1],
            [5_000_000_001, 4_234_567, 1, 1], // Sender debit underflow.
            [4_998_760_433, 2_999_999, 1, 1], // Recipient credit underflow.
        ] {
            var receipt = fixture.receipt
            var meta = try XCTUnwrap(receipt["meta"] as? [String: Any])
            meta["postBalances"] = post
            receipt["meta"] = meta
            XCTAssertThrowsError(try verifySettlement(fixture, receipt: receipt))
        }
        for invalidFee: Any in [true, -1, 5_000.5, "5000", UInt64(5_001)] {
            var receipt = fixture.receipt
            var meta = try XCTUnwrap(receipt["meta"] as? [String: Any])
            meta["fee"] = invalidFee
            receipt["meta"] = meta
            XCTAssertThrowsError(try verifySettlement(fixture, receipt: receipt))
        }
        XCTAssertThrowsError(try verifySettlement(fixture, maximumFee: 4_999))
        for invalidBalance: Any in [true, 1.5, "1"] {
            var receipt = fixture.receipt
            var meta = try XCTUnwrap(receipt["meta"] as? [String: Any])
            meta["preBalances"] = [UInt64(5_000_000_000), UInt64(3_000_000), invalidBalance, UInt64(1)]
            meta["postBalances"] = [UInt64(4_998_760_433), UInt64(4_234_567), invalidBalance, UInt64(1)]
            receipt["meta"] = meta
            XCTAssertThrowsError(try verifySettlement(fixture, receipt: receipt))
        }
        let overflowing = try nativeSettlementFixture(amount: String(UInt64.max))
        XCTAssertThrowsError(try verifySettlement(overflowing),
            "A transfer plus its fee cannot wrap around UInt64")
        var receipt = fixture.receipt
        var meta = try XCTUnwrap(receipt["meta"] as? [String: Any])
        meta["preBalances"] = [UInt64(5_000_000_000), 3_000_000, 1]
        receipt["meta"] = meta
        XCTAssertThrowsError(try verifySettlement(fixture, receipt: receipt))
    }

    private struct NativeSettlementFixture {
        let transfer: WalletSolanaCanonicalNativeTransfer
        let signedBytes: Data
        let signature: String
        let receipt: [String: Any]
    }

    private func nativeSettlementFixture(amount: String = "1234567") throws -> NativeSettlementFixture {
        let transfer = try WalletSolanaCanonicalNativeTransfer(
            feePayer: Self.signer, recipient: Self.recipient,
            recentBlockhash: WalletSolanaBase58.encode(Data(repeating: 0x22, count: 32)),
            amountBaseUnits: amount, computeUnitLimit: 200_000,
            computeUnitPriceMicroLamports: 0
        )
        // Synthetic public bytes test the pure evidence checker only. These
        // fixtures are never submitted and do not claim valid cryptography.
        let signature = Data(repeating: 0x31, count: 64)
        let signedBytes = Data([1]) + signature + transfer.message
        return NativeSettlementFixture(
            transfer: transfer, signedBytes: signedBytes,
            signature: WalletSolanaBase58.encode(signature),
            receipt: [
                "slot": UInt64(42), "version": "legacy",
                "transaction": [signedBytes.base64EncodedString(), "base64"],
                "meta": [
                    "err": NSNull(), "fee": UInt64(5_000),
                    "preBalances": [UInt64(5_000_000_000), 3_000_000, 1, 1],
                    "postBalances": [UInt64(4_998_760_433), 4_234_567, 1, 1],
                ],
            ]
        )
    }

    private func verifySettlement(
        _ fixture: NativeSettlementFixture,
        receipt: [String: Any]? = nil,
        signedBytes: Data? = nil,
        signature: String? = nil,
        maximumFee: UInt64 = 1_000_000
    ) throws {
        try LocalSolanaSmokeEvidence.verifyNativeSettlement(
            receipt ?? fixture.receipt, expectedTransfer: fixture.transfer,
            signedBytes: signedBytes ?? fixture.signedBytes,
            signature: signature ?? fixture.signature, finalizedSlot: 42,
            quotedFee: 5_000, maximumFee: maximumFee
        )
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
    ) async throws -> UInt64 {
        var lastStatus = "missing"
        // Hosted validators can keep producing confirmations beyond the old
        // forty-second polling window. Wait against a monotonic deadline;
        // never substitute "confirmed" for finalized or broadcast again.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                let value = try await solanaRPC(
                    endpoint: endpoint, method: "getSignatureStatuses",
                    params: [[signature], ["searchTransactionHistory": true]],
                    deadline: deadline
                )
                try Task.checkCancellation()
                lastStatus = String(describing: value).prefix(512).description
                if let slot = try LocalSolanaSmokeEvidence.finalizedSlot(
                    from: value, receivedAt: clock.now, deadline: deadline
                ) {
                    _ = try LocalSolanaSmokeEvidence.remainingRPCBudget(now: clock.now, deadline: deadline)
                    return slot
                }
            } catch LocalSolanaSmokeEvidence.Failure.deadlineExceeded {
                break
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
        params: [Any],
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> Any {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let timeout = try LocalSolanaSmokeEvidence.remainingRPCBudget(
            now: clock.now, deadline: deadline
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
        // Idle and total-resource bounds are both capped by the remaining
        // monotonic finality budget. A trickling response cannot extend it.
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        _ = try LocalSolanaSmokeEvidence.remainingRPCBudget(now: clock.now, deadline: deadline)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else {
            throw LocalSolanaSmokeEvidence.Failure.malformedResponse
        }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              CFGetTypeID(responseID) != CFBooleanGetTypeID(), responseID.stringValue == "1",
              object.keys.contains("result") != object.keys.contains("error") else {
            throw LocalSolanaSmokeEvidence.Failure.malformedResponse
        }
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
