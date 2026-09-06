import Foundation
import XCTest
@testable import Locus

@MainActor
final class WalletSuiIntegrationTests: XCTestCase {
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

    func testIndependentFixtureSignerGraphQLNativeTransferAndClientReconciliation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["LOCUS_SUI_LOCALNET_GRAPHQL_URL"], endpoint.hasPrefix("http://127.0.0.1:"),
              let faucet = environment["LOCUS_SUI_LOCALNET_FAUCET_URL"],
              let chain = environment["LOCUS_SUI_LOCALNET_CHAIN_IDENTIFIER"] else {
            throw XCTSkip("Run Tools/RunWalletSuiTests.sh against pinned Sui 1.79.0 GraphQL localnet.")
        }
        XCTAssertEqual(environment["LOCUS_SUI_LOCALNET_VERSION"], "1.79.0")
        // Production Rust deliberately rejects local genesis identities. This
        // separate, fixed-key executable signs the Swift reconstruction only;
        // it does not replace the production signer/derivation evidence gate.
        let sender = try XCTUnwrap(fixtureSigner(operation: "address")["address"] as? String)
        let client = try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint, expectedChainIdentifier: chain)
        _ = try await client.networkStatus()
        let wrongChain = try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint,
                                                  expectedChainIdentifier: chain == "4c78adac" ? "35834a8a" : "4c78adac")
        do { _ = try await wrongChain.networkStatus(); XCTFail("Substituted genesis identity accepted") }
        catch { /* Exact local genesis remains authoritative. */ }

        var faucetRequest = URLRequest(url: try XCTUnwrap(URL(string: faucet + "/v2/gas")))
        faucetRequest.httpMethod = "POST"
        faucetRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        faucetRequest.httpBody = try JSONSerialization.data(withJSONObject: ["FixedAmountRequest": ["recipient": sender]])
        let (_, response) = try await URLSession.shared.data(for: faucetRequest)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var selection: WalletSuiGasCoinSelection?
        for _ in 0..<100 {
            // Only a successfully decoded, not-yet-funded snapshot is retryable.
            // Schema, identity, ownership, or balance-reconciliation errors must
            // fail at their real boundary instead of becoming an indexing timeout.
            let snapshot: WalletSuiGasCoinSnapshot
            do { snapshot = try await client.nativeGasCoins(owner: sender) }
            catch { throw Self.readinessFailure(error, stage: "funding") }
            if let coin = snapshot.coins.first(where: {
                WalletBaseUnits.lessThanOrEqual("11234567", $0.balanceBaseUnits)
            }) {
                selection = WalletSuiGasCoinSelection(
                    snapshot: snapshot, coin: coin, requiredBalanceBaseUnits: "11234567"
                )
            }
            if selection != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let selected = try XCTUnwrap(selection, "Faucet funding was not indexed")
        let status = selected.snapshot.network
        let object = selected.coin.reference
        let packet = WalletSuiPreparationPacket(
            request: .init(networkID: WalletNetworkCatalog.suiTestnet.id, accountID: "local-fixture", source: .human,
                action: .nativeTransfer(recipient: Self.recipient, amountBaseUnits: "1234567"), maximumFeeBaseUnits: "10000000"),
            chainIdentifier: chain, checkpointSequence: status.checkpointSequence, checkpointTimestamp: status.checkpointTimestamp,
            sender: sender, assetID: WalletNetworkCatalog.suiTestnet.nativeAssetID, coinType: WalletSuiAssetIdentity.nativeCoinType,
            coinObject: nil, coinBalanceBaseUnits: nil, coinCheckpointSequence: nil, coinCheckpointTimestamp: nil,
            transferredObject: nil, objectHasPublicTransfer: nil, objectCheckpointSequence: nil, objectCheckpointTimestamp: nil,
            gasObject: object, gasBalanceBaseUnits: selected.coin.balanceBaseUnits, gasBudgetBaseUnits: "10000000",
            referenceGasPriceBaseUnits: status.referenceGasPrice, gasPriceBaseUnits: status.referenceGasPrice,
            currentEpoch: status.epoch, expirationEpoch: status.epoch, observedAt: Date()
        )
        let canonical = try WalletSuiCanonicalTransaction(packet: packet)
        let bcs = canonical.transactionBCS.base64EncodedString()
        let signed = try fixtureSigner(operation: "sign", transactionBCS: bcs)
        let signature = try XCTUnwrap(signed["signature"] as? String)
        let digest = try XCTUnwrap(signed["transaction_digest"] as? String)
        XCTAssertEqual(signed["address"] as? String, sender)
        XCTAssertEqual(digest, canonical.transactionDigest)
        _ = try await client.simulateNativeTransfer(transactionBCS: bcs, expectedTransactionDigest: digest,
            sender: sender, recipient: Self.recipient, amountBaseUnits: "1234567",
            maximumFeeBaseUnits: "10000000", gasObjectID: object.objectID)
        do {
            _ = try await client.simulateNativeTransfer(transactionBCS: bcs, expectedTransactionDigest: digest,
                sender: sender, recipient: Self.recipient, amountBaseUnits: "1234568",
                maximumFeeBaseUnits: "10000000", gasObjectID: object.objectID)
            XCTFail("Changed semantic amount passed simulation reconciliation")
        } catch { /* Simulation effects must match the exact amount. */ }
        _ = try await client.executeTransaction(transactionBCS: bcs, signature: signature, expectedTransactionDigest: digest)

        // A new client has no callback/session state: final success comes from chain effects.
        let restarted = try WalletSuiGraphQLClient(testLoopbackEndpoint: endpoint, expectedChainIdentifier: chain)
        var reconciled: WalletSuiIndexedActivity?
        for _ in 0..<100 {
            do {
                reconciled = try await restarted.activity(owner: Self.recipient).first { $0.transactionDigest == digest }
            } catch { throw Self.readinessFailure(error, stage: "reconciliation") }
            if reconciled != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let activity = try XCTUnwrap(reconciled, "Broadcast did not reconcile after client restart")
        XCTAssertTrue(activity.successful)
        XCTAssertEqual(activity.amountBaseUnits, "1234567")
        XCTAssertEqual(activity.sender, sender)
        do {
            _ = try await restarted.simulateNativeTransfer(transactionBCS: bcs, expectedTransactionDigest: digest,
                sender: sender, recipient: Self.recipient, amountBaseUnits: "1234567",
                maximumFeeBaseUnits: "10000000", gasObjectID: object.objectID)
            XCTFail("Consumed gas object version remained valid")
        } catch { /* The signed object's former version is stale after settlement. */ }
    }

    private static func readinessFailure(_ error: Error, stage: String) -> Error {
        if error is CancellationError { return error }
        let reason: String
        switch error {
        case WalletRPCError.invalidResponse(let message):
            switch message {
            case "Sui returned malformed gas-coin evidence": reason = "malformedGasCoinEvidence"
            case "Sui returned a malformed, misowned, or duplicate gas coin": reason = "invalidGasCoinIdentity"
            case "Sui gas coins did not reconcile with checkpoint balance evidence": reason = "inconsistentCoinBalance"
            case "Sui returned a malformed activity balance change": reason = "invalidActivityBalance"
            default: reason = "invalidProviderEvidence"
            }
        case WalletRPCError.wrongChain: reason = "wrongChain"
        case WalletRPCError.rpc: reason = "graphqlError"
        case let transport as URLError:
            if transport.code == .cancelled { return transport }
            reason = "transportError"
        default: reason = "unexpectedReadinessError"
        }
        // Never attach provider strings, URLs, addresses, or response bytes.
        return NSError(domain: "WalletSuiLocalFixture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Sui \(stage) readiness failed: \(reason)"])
    }

    private func fixtureSigner(operation: String, transactionBCS: String? = nil) throws -> [String: Any] {
        guard let path = ProcessInfo.processInfo.environment["LOCUS_SUI_FIXTURE_SIGNER_BIN"],
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw NSError(domain: "WalletSuiLocalFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The isolated local fixture signer is required; production signing cannot be substituted."])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--local-fixture-only"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stopped = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in stopped.signal() }
        var request: [String: Any] = ["operation": operation]
        if let transactionBCS { request["transaction_bcs"] = transactionBCS }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count <= 65_536 else { throw WalletRPCError.invalidResponse("Fixture request is excessive") }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        guard stopped.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            throw WalletRPCError.invalidResponse("The isolated fixture signer timed out")
        }
        guard process.terminationStatus == 0 else {
            throw WalletRPCError.invalidResponse("The isolated fixture signer rejected the transaction")
        }
        let response = try output.fileHandleForReading.readToEnd() ?? Data()
        guard response.count <= 2048,
              let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw WalletRPCError.invalidResponse("The isolated fixture signer returned malformed evidence")
        }
        return result
    }
}
