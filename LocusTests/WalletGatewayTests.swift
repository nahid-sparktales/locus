import XCTest
@testable import Locus

@MainActor
private final class FakeWalletSigner: WalletSignerClient {
    let isAvailable = true
    private(set) var sessionID: String?
    private(set) var authorizationCount = 0
    private(set) var preparedRequests: [WalletPrepareRequest] = []
    private(set) var preparedContracts: [WalletContractRegistryEntry?] = []
    private(set) var executedIntentIDs: [String] = []
    private(set) var confirmedIntentIDs: [String] = []
    private(set) var activePolicyStatuses: [WalletActivePolicyStatus] = []
    var invalidationHandler: (() -> Void)?
    var riskFlags: [WalletRiskFlag] = []
    var adapterID: String? = "native-eth-transfer-v1"

    func signerStatus() async throws -> WalletSignerStatus {
        WalletSignerStatus(protocolVersion: 1, vaultState: sessionID == nil ? .locked : .unlocked,
                           sessionID: sessionID, accounts: try await listAccounts())
    }
    func beginVaultCreation() async throws -> WalletVaultCreation {
        WalletVaultCreation(words: Array(repeating: "word", count: 24), verificationIndices: [0, 2, 4, 6, 8, 10])
    }
    func confirmVaultBackup(_ confirmation: WalletBackupConfirmation) async throws -> WalletSignerStatus {
        try await signerStatus()
    }
    func cancelVaultCreation() async throws -> WalletSignerStatus { try await signerStatus() }
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus { try await signerStatus() }

    func authorizeSession() async throws {
        authorizationCount += 1
        sessionID = "signer-session-1"
    }

    func listAccounts() async throws -> [WalletAccount] {
        [WalletAccount(id: "account-1", chain: .evm, address: "0xabc", label: "EVM",
                       networkIDs: [WalletGateway.sepoliaNetworkID])]
    }

    func prepare(
        _ request: WalletPrepareRequest,
        contract: WalletContractRegistryEntry?
    ) async throws -> WalletPreparedTransaction {
        preparedRequests.append(request)
        preparedContracts.append(contract)
        return fixture(request: request, riskFlags: riskFlags, adapterID: adapterID)
    }

    func simulate(intentID: String) async throws -> WalletPreparedTransaction {
        fixture(request: preparedRequests.last!, riskFlags: riskFlags, adapterID: adapterID)
    }

    func confirmExecution(intentID: String) async throws { confirmedIntentIDs.append(intentID) }

    func execute(intentID: String) async throws -> [String: Any] {
        executedIntentIDs.append(intentID)
        return ["text": "Submitted 0xtx", "transaction_hash": "0xtx", "status": "submitted"]
    }

    func activatePolicy(_ policy: WalletSessionPolicy) async throws -> [WalletActivePolicyStatus] {
        activePolicyStatuses = [WalletActivePolicyStatus(policy: policy, spentBaseUnits: "0")]
        return activePolicyStatuses
    }

    func listPolicies() async throws -> [WalletActivePolicyStatus] { activePolicyStatuses }
    func clearPolicies() async throws { activePolicyStatuses.removeAll() }
    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry {
        WalletContractRegistryEntry(
            id: draft.id, networkID: draft.networkID, checksumAddress: draft.address,
            label: draft.label, normalizedABI: draft.abiJSON, abiDigest: "sha256:test",
            runtimeCodeHash: "0xcode", permittedFunctions: draft.permittedFunctions,
            permittedSelectors: ["0x12345678"], reviewedAdapterID: draft.reviewedAdapterID,
            verifiedAt: Date()
        )
    }
    func browserRPC(method: String, params: [Any]) async throws -> Any { "0x1" }

    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        ["text": "ok"]
    }

    func configureRPCURL(_ value: String) {}
    func rpcHealth() async throws -> String { "Sepolia · healthy" }

    func lock() { sessionID = nil }

    private func fixture(
        request: WalletPrepareRequest,
        riskFlags: [WalletRiskFlag],
        adapterID: String?
    ) -> WalletPreparedTransaction {
        WalletPreparedTransaction(
            id: "intent-1", digest: "canonical-digest",
            networkID: request.networkID, accountID: request.accountID,
            action: request.action, summary: "Send 1 wei",
            effects: [WalletDecodedEffect(id: "effect-1", kind: "debit",
                                          assetID: "slip44:60", amountBaseUnits: "1",
                                          from: "0xabc", to: "0xrecipient", spender: nil)],
            riskFlags: riskFlags, contract: nil, adapterID: adapterID,
            budgetAssetID: "slip44:60", spendBaseUnits: "1",
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: "10", simulation: "Success", simulationSucceeded: true,
            nonce: "42", createdAt: Date(), expiresAt: Date().addingTimeInterval(120),
            policyDecision: "signer_pending", policyID: nil
        )
    }
}

@MainActor
final class WalletGatewayTests: XCTestCase {
    private func prepared(
        riskFlags: [WalletRiskFlag] = [],
        adapterID: String? = "native-eth-transfer-v1",
        expiresAt: Date = Date().addingTimeInterval(120)
    ) -> WalletPreparedTransaction {
        WalletPreparedTransaction(
            id: "intent-1", digest: "digest", networkID: WalletGateway.sepoliaNetworkID,
            accountID: "account-1", action: .nativeTransfer(recipient: "0xrecipient", amountBaseUnits: "10"),
            summary: "Transfer", effects: [], riskFlags: riskFlags, contract: nil,
            adapterID: adapterID, budgetAssetID: "slip44:60", spendBaseUnits: "10",
            maximumFeeBaseUnits: "20", feeQuoteBaseUnits: "15", simulation: "Success",
            simulationSucceeded: true, nonce: "1", createdAt: Date(), expiresAt: expiresAt,
            policyDecision: "", policyID: nil
        )
    }

    private func policy() -> WalletSessionPolicy {
        WalletSessionPolicy(
            id: "policy-1", accountID: "account-1", networkID: WalletGateway.sepoliaNetworkID,
            allowedAssetIDs: ["slip44:60"], allowedRecipients: ["0xrecipient"],
            allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
            maximumTransactionBaseUnits: "25", maximumSessionBaseUnits: "50",
            maximumFeeBaseUnits: "20", expiresAt: Date().addingTimeInterval(300)
        )
    }

    func testBaseUnitArithmeticDoesNotRoundLargeValues() {
        XCTAssertEqual(WalletBaseUnits.normalize("0000010"), "10")
        XCTAssertEqual(WalletBaseUnits.add("999999999999999999999999", "1"),
                       "1000000000000000000000000")
        XCTAssertEqual(WalletBaseUnits.multiply("18446744073709551616", "1000000000"),
                       "18446744073709551616000000000")
        XCTAssertTrue(WalletBaseUnits.lessThanOrEqual("18446744073709551616", "18446744073709551617"))
        XCTAssertFalse(WalletBaseUnits.lessThanOrEqual("1.0", "2"))
        XCTAssertEqual(WalletEthereumQuantity.decimalToHex("18446744073709551616"),
                       "0x10000000000000000")
        XCTAssertEqual(WalletEthereumQuantity.hexToDecimal("0x10000000000000000"),
                       "18446744073709551616")
        XCTAssertNil(WalletEthereumQuantity.hexToDecimal("0xnot-hex"))
    }

    func testContractRegistryAddressUsesEIP55Checksum() throws {
        let address = try WalletSepoliaRPCClient.checksummedAddress(
            "0x52908400098527886e0f7030069857d2e4169ee7",
            keccakHash: "0x297c1ba3882c3eb45bc8970bdb323ffa98749993835ebfa9b4150ee83081da79"
        )
        XCTAssertEqual(address, "0x52908400098527886E0F7030069857D2E4169EE7")
    }

    func testXPCReplyGateConsumesExactlyOneReply() {
        let gate = WalletXPCReplyGate()
        XCTAssertTrue(gate.take())
        XCTAssertFalse(gate.take())
        XCTAssertFalse(gate.take())
    }

    func testUnknownEffectsAndUnlimitedApprovalCanNeverBeAutonomous() {
        for flag in [WalletRiskFlag.unknownEffect, .undecodableCall, .unlimitedApproval] {
            guard case .requiresApproval = WalletPolicyEngine.evaluate(
                transaction: prepared(riskFlags: [flag]), policy: policy(), spentThisSession: "0"
            ) else { return XCTFail("\(flag) must require exact approval") }
        }
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: prepared(adapterID: nil), policy: policy(), spentThisSession: "0"
        ) else { return XCTFail("missing adapter must require exact approval") }
    }

    func testPolicyUsesUnsignedBaseUnitCaps() {
        XCTAssertEqual(WalletPolicyEngine.evaluate(
            transaction: prepared(), policy: policy(), spentThisSession: "5"
        ), .automatic)
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: prepared(), policy: policy(), spentThisSession: "45"
        ) else { return XCTFail("cumulative cap must be enforced") }
    }

    @MainActor
    func testUnavailableSignerHasNoCapability() {
        let gateway = WalletGateway(environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"])
        XCTAssertFalse(gateway.agentToolingAvailable)
        XCTAssertNil(gateway.capability)
        XCTAssertEqual(gateway.status, .securityReviewRequired)
    }

    @MainActor
    func testCallerSafetyLabelsAreIgnoredAndExecutionUsesOnlyOpaqueID() async throws {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer,
                                    environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        XCTAssertEqual(gateway.capability?["protocol_version"] as? Int, 1)

        let prepared = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": WalletGateway.sepoliaNetworkID,
            "account_id": "account-1",
            "action": [
                "type": "native_transfer",
                "recipient": "0xrecipient",
                "amount_base_units": "0001",
            ],
            "maximum_fee_base_units": "20",
            "decoded": true,
            "unlimited_approval": false,
            "digest": "attacker-digest",
        ])
        XCTAssertEqual(prepared["digest"] as? String, "canonical-digest")
        XCTAssertEqual(signer.preparedRequests.first?.action.amountBaseUnits, "1")

        let blocked = await gateway.perform(
            tool: "wallet_execute_transaction",
            arguments: ["intent_id": "intent-1", "digest": "attacker-substitution"]
        )
        XCTAssertNotNil(blocked["error"])
        XCTAssertTrue(signer.executedIntentIDs.isEmpty)

        gateway.confirm(intentID: "intent-1")
        let executed = await gateway.perform(
            tool: "wallet_execute_transaction",
            arguments: ["intent_id": "intent-1", "digest": "attacker-substitution"]
        )
        XCTAssertEqual(executed["text"] as? String, "Submitted 0xtx")
        XCTAssertEqual(signer.executedIntentIDs, ["intent-1"])
        XCTAssertEqual(signer.confirmedIntentIDs, ["intent-1"])

        let replay = await gateway.perform(tool: "wallet_execute_transaction",
                                           arguments: ["intent_id": "intent-1"])
        XCTAssertNotNil(replay["error"])
    }

    @MainActor
    func testRawCalldataIsRejectedBeforeSigner() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer,
                                    environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let result = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": WalletGateway.sepoliaNetworkID,
            "account_id": "account-1",
            "action": ["type": "contract_call", "contract_id": "erc20.usdc",
                       "function": "0xa9059cbb", "arguments": [], "calldata": "0xdeadbeef"],
            "maximum_fee_base_units": "20",
        ])
        XCTAssertNotNil(result["error"])
        XCTAssertTrue(signer.preparedRequests.isEmpty)
    }

    func testRegisteredContractCallResolvesRegistryBeforeSigner() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer,
                                    environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let registered = await gateway.addContractRegistryEntry(WalletContractRegistryDraft(
            id: "erc20.test", networkID: WalletGateway.sepoliaNetworkID,
            address: "0x1111111111111111111111111111111111111111", label: "Test Token",
            abiJSON: "[]", permittedFunctions: ["transfer(address,uint256)"],
            reviewedAdapterID: nil
        ))
        XCTAssertTrue(registered)
        let result = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": WalletGateway.sepoliaNetworkID,
            "account_id": "account-1",
            "action": [
                "type": "contract_call", "contract_id": "erc20.test",
                "function": "transfer(address,uint256)",
                "arguments": [
                    ["type": "address", "value": "0x2222222222222222222222222222222222222222"],
                    ["type": "uint256", "value": "42"],
                ],
                "value_base_units": "0",
            ],
            "maximum_fee_base_units": "20",
        ])
        XCTAssertEqual(result["digest"] as? String, "canonical-digest")
        XCTAssertEqual(signer.preparedContracts.last.flatMap { $0 }?.id, "erc20.test")
        XCTAssertEqual(signer.preparedRequests.last?.action.arguments.count, 2)
    }

    @MainActor
    func testBrowserAccountGrantIsOriginScopedAndRevoked() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let request = Task {
            await gateway.requestBrowserAccounts(origin: "https://example.test:443/path")
        }
        await Task.yield()
        XCTAssertEqual(gateway.pendingBrowserOriginGrant?.origin, "https://example.test")
        gateway.approveBrowserOrigin()
        let grantedAccounts = await request.value
        XCTAssertEqual(grantedAccounts, ["0xabc"])
        XCTAssertEqual(gateway.browserAccounts(origin: "https://example.test/elsewhere"), ["0xabc"])
        XCTAssertTrue(gateway.browserAccounts(origin: "https://other.test").isEmpty)
        gateway.revokeBrowserOrigin("https://example.test")
        XCTAssertTrue(gateway.browserAccounts(origin: "https://example.test").isEmpty)
    }

    func testBrowserProviderRequiresItsSeparateFeatureGate() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
        ])
        let authorized = await gateway.authorizeSession()
        let accounts = await gateway.requestBrowserAccounts(origin: "https://dapp.test")
        XCTAssertTrue(authorized)
        XCTAssertNil(accounts)
    }

    func testSignerInterruptionWithdrawsAgentCapabilityAndBrowserGrants() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let accountRequest = Task {
            await gateway.requestBrowserAccounts(origin: "https://dapp.test")
        }
        await Task.yield()
        gateway.approveBrowserOrigin()
        let grantedAccounts = await accountRequest.value
        XCTAssertEqual(grantedAccounts, ["0xabc"])

        signer.invalidationHandler?()

        XCTAssertNil(gateway.capability)
        XCTAssertEqual(gateway.status, .locked)
        XCTAssertTrue(gateway.browserAccounts(origin: "https://dapp.test").isEmpty)
    }

    func testRevokingBrowserOriginCancelsPendingExactTransaction() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let accountRequest = Task {
            await gateway.requestBrowserAccounts(origin: "https://dapp.test")
        }
        await Task.yield()
        gateway.approveBrowserOrigin()
        _ = await accountRequest.value

        let send = Task {
            try await gateway.browserSendTransaction(origin: "https://dapp.test:443/path", transaction: [
                "from": "0xabc", "to": "0xrecipient", "value": "0x1",
            ])
        }
        for _ in 0..<20 where gateway.pendingConfirmation == nil { await Task.yield() }
        XCTAssertNotNil(gateway.pendingConfirmation)
        gateway.revokeBrowserOrigin("https://dapp.test")
        do {
            _ = try await send.value
            XCTFail("A revoked origin must not reach signer execution.")
        } catch {
            XCTAssertTrue(signer.executedIntentIDs.isEmpty)
        }
    }

    func testProviderScriptAnnouncesLocusWithoutImpersonatingOtherWallets() {
        let script = LocusWalletProviderScript.evmBootstrap
        XCTAssertTrue(script.contains("eip6963:announceProvider"))
        XCTAssertTrue(script.contains("name: 'Locus Vault'"))
        XCTAssertTrue(script.contains("typeof globalThis.ethereum === 'undefined'"))
        XCTAssertTrue(script.contains("pending.size >= 32"))
        XCTAssertFalse(script.contains("isMetaMask"))
        XCTAssertFalse(script.contains("isPhantom"))
    }
}
