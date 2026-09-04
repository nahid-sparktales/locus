import Foundation
import XCTest
@testable import Locus

@_silgen_name("locus_wallet_sign_sui_native_transfer_json")
private func rustSignSuiNative(_ entropy: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("locus_wallet_string_free")
private func rustFreeSui(_ value: UnsafeMutablePointer<CChar>)

@MainActor
final class WalletSuiIntegrationTests: XCTestCase {
    private static let sender = "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c"
    private static let recipient = "0x1111111111111111111111111111111111111111111111111111111111111111"

    func testLoopbackBoundaryAndProductionHTTPSOnly() throws {
        for endpoint in ["http://example.com:9125/graphql", "http://127.0.0.1@example.com/graphql",
                         "http://127.0.0.1:9125/graphql#fragment", "https://127.0.0.1:9125/graphql"] {
            XCTAssertThrowsError(try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint,
                                                          expectedChainIdentifier: "4c78adac"))
        }
        XCTAssertThrowsError(try WalletSuiGraphQLClient(testLoopbackEndpoint: "http://127.0.0.1:9125/graphql",
                                                      expectedChainIdentifier: "not-a-chain"))
        XCTAssertThrowsError(try WalletSuiGraphQLClient(network: WalletNetworkCatalog.suiTestnet,
                                                      endpoint: "http://127.0.0.1:9125/graphql"))
        XCTAssertNoThrow(try WalletSuiGraphQLClient(testLoopbackEndpoint: "http://127.0.0.1:9125/graphql",
                                                  expectedChainIdentifier: "4c78adac"))
    }

    func testPinnedGraphQLNativeTransferAndRestartReconciliation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_SUI_LOCALNET_GRAPHQL_URL"], endpoint.hasPrefix("http://127.0.0.1:"),
              let faucet = environment["LOCUS_SUI_LOCALNET_FAUCET_URL"],
              let chain = environment["LOCUS_SUI_LOCALNET_CHAIN_IDENTIFIER"] else {
            throw XCTSkip("Run Tools/RunWalletSuiTests.sh against pinned Sui 1.79.0 GraphQL localnet.")
        }
        XCTAssertEqual(environment["LOCUS_SUI_LOCALNET_VERSION"], "1.79.0")
        let client = try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint, expectedChainIdentifier: chain)
        _ = try await client.networkStatus()
        let wrongChain = try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint,
                                                  expectedChainIdentifier: chain == "4c78adac" ? "35834a8a" : "4c78adac")
        do { _ = try await wrongChain.networkStatus(); XCTFail("Substituted genesis identity accepted") }
        catch { /* Exact local genesis remains authoritative. */ }

        var faucetRequest = URLRequest(url: try XCTUnwrap(URL(string: faucet + "/v2/gas")))
        faucetRequest.httpMethod = "POST"
        faucetRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        faucetRequest.httpBody = try JSONSerialization.data(withJSONObject: ["FixedAmountRequest": ["recipient": Self.sender]])
        let (_, response) = try await URLSession.shared.data(for: faucetRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var selection: WalletSuiGasCoinSelection?
        for _ in 0..<100 {
            selection = try? await client.selectNativeGasCoin(owner: Self.sender, requiredBalanceBaseUnits: "11000000")
            if selection != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let selected = try XCTUnwrap(selection, "Faucet funding was not indexed")
        let status = selected.snapshot.network
        let object = selected.coin.reference
        let fields: [String: Any] = [
            "chain_identifier": chain, "sender": Self.sender, "recipient": Self.recipient,
            "gas_object_id": object.objectID, "gas_object_version": object.version,
            "gas_object_digest": object.digest, "gas_balance_base_units": selected.coin.balanceBaseUnits,
            "amount_base_units": "1234567", "reference_gas_price_base_units": status.referenceGasPrice,
            "gas_price_base_units": status.referenceGasPrice, "gas_budget_base_units": "10000000",
            "current_epoch": status.epoch, "expiration_epoch": status.epoch + 1,
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
        let signed: [String: Any] = try String(repeating: "00", count: 32).withCString { entropy in
            try json.withCString { request in
                let pointer = try XCTUnwrap(rustSignSuiNative(entropy, request))
                defer { rustFreeSui(pointer) }
                return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any])
            }
        }
        let bcs = try XCTUnwrap(signed["transaction_bcs"] as? String)
        let signature = try XCTUnwrap(signed["signature"] as? String)
        let digest = try XCTUnwrap(signed["transaction_digest"] as? String)
        XCTAssertEqual(signed["from"] as? String, Self.sender)
        _ = try await client.simulateNativeTransfer(transactionBCS: bcs, expectedTransactionDigest: digest,
            sender: Self.sender, recipient: Self.recipient, amountBaseUnits: "1234567",
            maximumFeeBaseUnits: "10000000", gasObjectID: object.objectID)
        do {
            _ = try await client.simulateNativeTransfer(transactionBCS: bcs, expectedTransactionDigest: digest,
                sender: Self.sender, recipient: Self.recipient, amountBaseUnits: "1234568",
                maximumFeeBaseUnits: "10000000", gasObjectID: object.objectID)
            XCTFail("Changed semantic amount passed simulation reconciliation")
        } catch { /* Simulation effects must match the exact amount. */ }
        _ = try await client.executeTransaction(transactionBCS: bcs, signature: signature, expectedTransactionDigest: digest)

        // A new client has no callback/session state: final success comes from chain effects.
        let restarted = try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint, expectedChainIdentifier: chain)
        var reconciled: WalletSuiIndexedActivity?
        for _ in 0..<100 {
            reconciled = try? await restarted.activity(owner: Self.recipient).first { $0.transactionDigest == digest }
            if reconciled != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let activity = try XCTUnwrap(reconciled, "Broadcast did not reconcile after client restart")
        XCTAssertTrue(activity.successful)
        XCTAssertEqual(activity.amountBaseUnits, "1234567")
        XCTAssertEqual(activity.sender, Self.sender)
        do {
            _ = try await restarted.simulateNativeTransfer(transactionBCS: bcs, expectedTransactionDigest: digest,
                sender: Self.sender, recipient: Self.recipient, amountBaseUnits: "1234567",
                maximumFeeBaseUnits: "10000000", gasObjectID: object.objectID)
            XCTFail("Consumed gas object version remained valid")
        } catch { /* The signed object's former version is stale after settlement. */ }
    }
}
