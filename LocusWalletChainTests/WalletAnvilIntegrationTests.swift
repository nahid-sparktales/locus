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

@MainActor
final class WalletAnvilIntegrationTests: XCTestCase {
    private static let pinnedAnvilVersion = "1.7.1"
    private static let entropy = String(repeating: "00", count: 32)

    func testPinnedSignerCoreBroadcastReplayRecheckAndRecoveryOnAnvil() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_ANVIL_RPC_URL"] else {
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
