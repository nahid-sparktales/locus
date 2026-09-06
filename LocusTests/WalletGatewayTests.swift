import CryptoKit
import Security
import XCTest
@testable import Locus

private final class WalletRPCURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (status: Int, data: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let result = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: result.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func walletRPCRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw URLError(.cannotParseResponse)
    }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw stream.streamError ?? URLError(.cannotParseResponse) }
        if count == 0 { break }
        body.append(buffer, count: count)
    }
    return body
}

@MainActor
private final class FakeWalletSigner: WalletSignerClient {
    #if LOCUS_DIRECT_DOWNLOAD
    var currentReleaseStatus = WalletReleaseAuthorityStatus(
        installationID: String(repeating: "f", count: 64), checkpoint: nil)
    private(set) var releaseHistoryApplyCount = 0
    private(set) var releaseHistoryStateChangeCount = 0
    var hasOperationalReleaseAuthority = false
    #if DEBUG
    var experimentalTestConfiguration: WalletExperimentalActivationTestConfiguration?
    #endif
    var releaseHistoryApplyHandler: ((WalletReleaseHistoryRequest) async throws -> WalletReleaseAuthorityStatus)?

    func releaseAuthorityStatus() async throws -> WalletReleaseAuthorityStatus { currentReleaseStatus }

    func applyReleaseHistory(_ history: WalletReleaseHistoryRequest) async throws -> WalletReleaseAuthorityStatus {
        releaseHistoryApplyCount += 1
        guard let releaseHistoryApplyHandler else { throw WalletReleaseActivationError.stateUnavailable }
        let accepted = try await releaseHistoryApplyHandler(history)
        if accepted.checkpoint != currentReleaseStatus.checkpoint { releaseHistoryStateChangeCount += 1 }
        currentReleaseStatus = accepted
        hasOperationalReleaseAuthority = true
        return accepted
    }
    #endif

    func applyReleaseActivation(
        _ envelope: WalletSignedReleaseActivationEnvelope
    ) async throws -> WalletReleaseActivationStatus {
        throw WalletGateway.Error.signerUnavailable
    }

    let isAvailable = true
    private(set) var sessionID: String?
    private(set) var authorizationCount = 0
    private(set) var preparedRequests: [WalletPrepareRequest] = []
    private(set) var preparedContracts: [WalletContractRegistryEntry?] = []
    private(set) var executedIntentIDs: [String] = []
    private(set) var confirmedIntentIDs: [String] = []
    private(set) var canceledIntentIDs: [String] = []
    var confirmationHandler: ((String) async -> Void)?
    private(set) var activePolicyStatuses: [WalletActivePolicyStatus] = []
    var invalidationHandler: (() -> Void)?
    var riskFlags: [WalletRiskFlag] = []
    var adapterID: String? = "native-eth-transfer-v1"
    var policyDecision = "signer_pending"
    var policyID: String?
    var executionError: WalletGateway.Error?
    var browserRPCResponse: Any = "0x1"
    var browserRPCResponses: [Any] = []
    var balanceBaseUnits = "1234500000000000000"
    var discoveredAssetRows: [[String: Any]] = []
    var indexedActivityRows: [[String: Any]] = []
    var indexedHeadBlock: String?
    var accountAddress = "0xabc"
    var accountChain: WalletChain = .evm
    var accountNetworkIDs = [WalletGateway.sepoliaNetworkID]
    var reportedVaultState: WalletVaultState?

    func signerStatus() async throws -> WalletSignerStatus {
        WalletSignerStatus(protocolVersion: WalletGateway.protocolVersion,
                           vaultState: reportedVaultState ?? (sessionID == nil ? .locked : .unlocked),
                           sessionID: sessionID, accounts: try await listAccounts())
    }
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus { try await signerStatus() }
    func deleteRecoveryVault(confirmation: String) async throws -> WalletSignerStatus {
        try await signerStatus()
    }

    func authorizeSession() async throws {
        authorizationCount += 1
        sessionID = "signer-session-1"
    }

    func listAccounts() async throws -> [WalletAccount] {
        [WalletAccount(
            id: "account-1", chain: accountChain, address: accountAddress,
            label: accountChain.rawValue, networkIDs: accountNetworkIDs
        )]
    }

    func signStructuredAuthorization(
        _ request: WalletStructuredAuthorizationRequest,
        source: WalletRequestSource
    ) async throws -> WalletStructuredAuthorizationResult {
        let account = try await listAccounts()[0]
        return WalletStructuredAuthorizationResult(
            request: request,
            canonicalMessage: try WalletStructuredAuthorization.canonicalMessage(
                request, account: account
            ),
            messageDigest: "0xdigest",
            signature: "0xsignature",
            signatureEncoding: .eip191Hex,
            signedAt: Date()
        )
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

    func confirmExecution(intentID: String) async throws {
        confirmedIntentIDs.append(intentID)
        await confirmationHandler?(intentID)
    }

    func cancelPreparation(intentID: String) { canceledIntentIDs.append(intentID) }

    func execute(intentID: String) async throws -> [String: Any] {
        executedIntentIDs.append(intentID)
        if let executionError { throw executionError }
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
    func browserRPC(networkID: String, method: String, params: [Any]) async throws -> Any {
        if !browserRPCResponses.isEmpty {
            return browserRPCResponses.removeFirst()
        }
        return browserRPCResponse
    }

    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        if tool == "wallet_get_assets" {
            return ["text": "assets", "assets": discoveredAssetRows]
        }
        if tool == "wallet_get_activity" {
            var result: [String: Any] = ["text": "indexed", "activity": indexedActivityRows]
            if let indexedHeadBlock { result["head_block_number"] = indexedHeadBlock }
            return result
        }
        return ["text": "ok", "balance_base_units": balanceBaseUnits]
    }

    func configureRPCURL(_ value: String) {}
    func rpcHealth() async throws -> String { "Sepolia · healthy" }

    func lock() { sessionID = nil }

    private func fixture(
        request: WalletPrepareRequest,
        riskFlags: [WalletRiskFlag],
        adapterID: String?
    ) -> WalletPreparedTransaction {
        let assetID = WalletNetworkCatalog.descriptor(id: request.networkID)?.nativeAssetID
            ?? "slip44:60"
        let recipient = request.action.recipient
            ?? "0x1111111111111111111111111111111111111111"
        let amount = request.action.amountBaseUnits ?? "1"
        return WalletPreparedTransaction(
            id: "intent-1", digest: "canonical-digest",
            networkID: request.networkID, accountID: request.accountID,
            source: request.source, action: request.action, summary: "Send 1 wei",
            effects: [WalletDecodedEffect(id: "effect-1", kind: "debit",
                                          assetID: assetID, amountBaseUnits: amount,
                                          from: accountAddress, to: recipient, spender: nil)],
            riskFlags: riskFlags, contract: nil, adapterID: adapterID,
            budgetAssetID: assetID, spendBaseUnits: amount,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: "10", simulation: "Success", simulationSucceeded: true,
            nonce: "42", createdAt: Date(), expiresAt: Date().addingTimeInterval(120),
            policyDecision: policyDecision, policyID: policyID
        )
    }
}

@MainActor
private final class FakeWalletRecoveryView: WalletRecoveryViewClient {
    var isAvailable = true
    var presentationState = WalletRecoveryPresentationState.idle
    var presentationStateHandler: ((WalletRecoveryPresentationState) -> Void)?
    var invalidationHandler: (() -> Void)?
    var outcome: WalletRecoveryCeremonyOutcome = .completed
    var presentedModes: [WalletRecoveryCeremonyMode] = []
    var error: Error?
    var cancelCount = 0
    var bringToFrontCount = 0

    func present(mode: WalletRecoveryCeremonyMode) async throws
        -> WalletRecoveryCeremonyResult {
        if let error { throw error }
        presentedModes.append(mode)
        presentationState = .presented
        presentationStateHandler?(.presented)
        let status = outcome == .completed ? WalletSignerStatus(
            protocolVersion: WalletGateway.protocolVersion,
            vaultState: .locked, sessionID: nil,
            accounts: [WalletAccount(
                id: "account-1", chain: .evm, address: "0xabc", label: "EVM",
                networkIDs: [WalletGateway.sepoliaNetworkID]
            )]
        ) : nil
        return WalletRecoveryCeremonyResult(
            ceremonyID: "ceremony-1", outcome: outcome,
            signerStatus: status, error: outcome == .failed ? "failed" : nil
        )
    }

    func bringToFront() { bringToFrontCount += 1 }
    func cancel() { cancelCount += 1 }
}

@MainActor
final class WalletGatewayTests: XCTestCase {
    func testPolicyAccountSelectionRequiresExactVaultOwnershipChainAndNetwork() {
        let mainnet = WalletNetworkCatalog.ethereumMainnet.id
        let accounts: [WalletAccount] = [
            .init(id: "vault-mainnet", chain: .evm, address: "0x1", label: "Vault",
                networkIDs: [mainnet]),
            .init(id: "vault-testnet", chain: .evm, address: "0x2", label: "Testnet",
                networkIDs: [WalletNetworkCatalog.ethereumSepolia.id]),
            .init(id: "metamask", chain: .evm, address: "0x3", label: "MetaMask",
                networkIDs: [mainnet], ownership: .external(connectorID: .metamask)),
            .init(id: "wrong-chain", chain: .solana, address: "not-used", label: "Wrong chain",
                networkIDs: [mainnet]),
        ]
        XCTAssertEqual(WalletPolicyAccountEligibility.accounts(accounts, networkID: mainnet).map(\.id),
            ["vault-mainnet"])
    }

    func testSolanaPolicySelectionNeverIncludesManagedOrExternalAccounts() {
        let networkID = WalletNetworkCatalog.solanaMainnet.id
        let accounts: [WalletAccount] = [
            .init(id: "vault", chain: .solana, address: "public", label: "Vault", networkIDs: [networkID]),
            .init(id: "managed", chain: .solana, address: "public", label: "Phantom", networkIDs: [networkID],
                ownership: .connectorManaged(connectorID: .phantom)),
            .init(id: "legacy", chain: .solana, address: "public", label: "Legacy", networkIDs: [networkID],
                ownership: .external(connectorID: .phantom)),
        ]
        XCTAssertEqual(WalletPolicyAccountEligibility.accounts(accounts, networkID: networkID).map(\.id), ["vault"])
    }

    func testPolicySelectionDoesNotExpandToSuiOrUnknownNetworks() {
        let account = WalletAccount(id: "sui", chain: .sui, address: "0x1", label: "Sui",
            networkIDs: [WalletNetworkCatalog.suiMainnet.id, "unknown"])
        XCTAssertTrue(WalletPolicyAccountEligibility.accounts([account], networkID: WalletNetworkCatalog.suiMainnet.id).isEmpty)
        XCTAssertTrue(WalletPolicyAccountEligibility.accounts([account], networkID: "unknown").isEmpty)
    }

    func testContractPolicyAssetUsesRegistryNetworkRatherThanSepolia() {
        let address = "0xAa11111111111111111111111111111111111111"
        let entry = WalletContractRegistryEntry(id: "mainnet.token", networkID: "eip155:1",
            checksumAddress: address, label: "Token", normalizedABI: "[]", abiDigest: "digest",
            runtimeCodeHash: "hash", permittedFunctions: ["transfer(address,uint256)"],
            permittedSelectors: ["0xa9059cbb"], reviewedAdapterID: WalletReviewedAdapters.erc20,
            verifiedAt: Date())
        XCTAssertEqual(WalletPolicyAccountEligibility.contractAssetID(entry: entry, address: address),
            "eip155:1/erc20:0xaa11111111111111111111111111111111111111")
        XCTAssertNil(WalletPolicyAccountEligibility.contractAssetID(entry: entry, address: "not-an-address"))
        XCTAssertEqual(WalletPolicyAccountEligibility.contractCapability(entry), .fungibleTokenTransfer)
    }

    func testRuleReadinessCannotEnablePolicyOnDormantNetwork() async {
        let signer = FakeWalletSigner()
        signer.accountNetworkIDs = [WalletNetworkCatalog.ethereumMainnet.id]
        let gateway = WalletGateway(signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            launchGate: try! WalletLaunchGate())
        _ = await gateway.authorizeSession()
        XCTAssertTrue(gateway.policyAccounts(networkID: WalletNetworkCatalog.ethereumMainnet.id,
            capability: .nativeTransfer).isEmpty)
        XCTAssertFalse(gateway.canAuthorizeNativePolicy)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
    }

    func testRuleReadinessPreservesSupportedTestnetWithoutMainnetActivation() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            launchGate: try! WalletLaunchGate())
        _ = await gateway.authorizeSession()
        XCTAssertEqual(gateway.policyAccounts(networkID: WalletGateway.sepoliaNetworkID,
            capability: .nativeTransfer).map(\.id), ["account-1"])
        XCTAssertTrue(gateway.canAuthorizeNativePolicy)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
        gateway.applyFeatureAccess(walletEnabled: false, browserEnabled: false)
        XCTAssertFalse(gateway.canAuthorizeNativePolicy)
    }

    private func contractRuleEntry(adapter: String) -> WalletContractRegistryEntry {
        .init(id: "mainnet.contract", networkID: "eip155:1",
            checksumAddress: "0x1111111111111111111111111111111111111111", label: "Contract",
            normalizedABI: "[]", abiDigest: "digest", runtimeCodeHash: "hash",
            permittedFunctions: [], permittedSelectors: [], reviewedAdapterID: adapter, verifiedAt: Date())
    }

    private func contractRuleDraft(
        adapter: String = WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
        ownership: WalletAccountOwnership = .locusVault,
        networkIDs: [String] = ["eip155:1"], slippage: String = "50", floor: String = "975",
        perTransaction: String = "1000", sessionCap: String = "2000"
    ) -> WalletSessionPolicy? {
        let account = WalletAccount(id: "selected-vault", chain: .evm,
            address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", label: "Vault", networkIDs: networkIDs,
            ownership: ownership)
        return WalletPolicyAccountEligibility.contractPolicy(entry: contractRuleEntry(adapter: adapter),
            account: account, inputToken: "0x2222222222222222222222222222222222222222",
            recipient: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", perTransaction: perTransaction,
            sessionCap: sessionCap, feeCap: "20", durationMinutes: "30",
            maximumSlippageBPS: slippage, minimumOutput: floor,
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSwapRuleDraftBindsSemanticActionSelectedVaultNetworkRecipientAndFiniteLimits() throws {
        let policy = try XCTUnwrap(contractRuleDraft())
        XCTAssertEqual(policy.accountID, "selected-vault")
        XCTAssertEqual(policy.networkID, "eip155:1")
        XCTAssertEqual(policy.allowedAssetIDs, ["eip155:1/erc20:0x2222222222222222222222222222222222222222"])
        XCTAssertEqual(policy.allowedRecipients, ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertEqual(policy.allowedContractIDs, ["mainnet.contract"])
        XCTAssertEqual(policy.allowedActionKinds, [.exactInputSwap])
        XCTAssertEqual(policy.maximumSlippageBPS, 50)
        XCTAssertEqual(policy.minimumOutputBaseUnits, "975")
        XCTAssertEqual(policy.maximumTransactionBaseUnits, "1000")
        XCTAssertEqual(policy.maximumSessionBaseUnits, "2000")
        XCTAssertEqual(policy.maximumFeeBaseUnits, "20")
        XCTAssertEqual(policy.expiresAt, Date(timeIntervalSince1970: 1_800_001_800))
    }

    func testSwapRuleDraftRejectsMissingOutOfRangeAndMalformedLimits() {
        for slippage in ["", "-1", "501", "not-a-number"] { XCTAssertNil(contractRuleDraft(slippage: slippage)) }
        for floor in ["", "0", "01", "1.5", "-1"] { XCTAssertNil(contractRuleDraft(floor: floor)) }
        XCTAssertNil(contractRuleDraft(perTransaction: "0"))
        XCTAssertNil(contractRuleDraft(perTransaction: "2001"))
        XCTAssertNotNil(contractRuleDraft(slippage: "0"))
        XCTAssertNotNil(contractRuleDraft(slippage: "500"))
    }

    func testContractRuleDraftRejectsWrongNetworkExternalManagedAndAllowanceAdapters() {
        XCTAssertNil(contractRuleDraft(networkIDs: [WalletNetworkCatalog.ethereumSepolia.id]))
        XCTAssertNil(contractRuleDraft(ownership: .external(connectorID: .metamask)))
        XCTAssertNil(contractRuleDraft(ownership: .connectorManaged(connectorID: .phantom)))
        XCTAssertNil(contractRuleDraft(adapter: WalletReviewedAdapters.uniswapPermit2AllowanceSetup))
        XCTAssertNil(contractRuleDraft(adapter: WalletReviewedAdapters.erc721SafeTransfer))
    }

    func testTokenRuleDraftUsesFungibleTransferNotApprovalOrLegacyContractAction() throws {
        let policy = try XCTUnwrap(contractRuleDraft(adapter: WalletReviewedAdapters.erc20, slippage: "", floor: ""))
        XCTAssertEqual(policy.allowedActionKinds, [.fungibleTokenTransfer])
        XCTAssertEqual(policy.allowedAssetIDs, ["eip155:1/erc20:0x1111111111111111111111111111111111111111"])
        XCTAssertEqual(policy.allowedRecipients, ["0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        XCTAssertNil(policy.maximumSlippageBPS)
        XCTAssertNil(policy.minimumOutputBaseUnits)
    }

    #if LOCUS_DIRECT_DOWNLOAD
    #if DEBUG
    private func experimentalGatewayFixture() throws
        -> (gateway: WalletGateway, signer: FakeWalletSigner, data: Data) {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let issued = now.addingTimeInterval(-30)
        let expiry = now.addingTimeInterval(600)
        let network = WalletNetworkCatalog.ethereumMainnet
        let providers = [WalletProviderKind.alchemy, .quickNode].map { provider in
            WalletReviewedProviderIdentity(networkID: network.id, provider: provider,
                configurationID: "\(provider.rawValue):\(network.id)",
                endpointSHA256: String(repeating: "2", count: 64), expectedIdentity: network.identity)
        }
        let review = WalletReviewManifest(schemaVersion: 2, revision: 1, issuedAt: issued,
            expiresAt: expiry, assets: [], evmContracts: [], explorerTemplates: [:], adapterIDs: [],
            providerIdentities: providers)
        let ceilingValue = WalletReviewCeiling(schemaVersion: 1, domain: WalletReviewCeiling.domain,
            reviewRevision: 1, reviewedAt: issued.addingTimeInterval(-60), scope: WalletReviewScope(review))
        func signature<T: Encodable>(_ value: T) throws -> String {
            try key.signature(for: WalletAuthorityEncoding.encode(value)).base64EncodedString()
        }
        let ceiling = WalletSignedReviewCeiling(ceiling: ceilingValue, signatureBase64: try signature(ceilingValue))
        let identity = WalletInstalledReleaseIdentity(sourceRevision: String(repeating: "a", count: 40),
            bundleVersion: "fixture", outerAppCodeDirectoryHash: String(repeating: "b", count: 40),
            signerCodeDirectoryHash: String(repeating: "c", count: 40))
        let cap = WalletCapabilityManifest(schemaVersion: 3, revision: 1, releaseStage: .experimentalMainnet,
            evidenceIndexSHA256: "", issuedAt: issued, expiresAt: expiry,
            networkGrants: [.init(networkID: network.id, capabilities: [.nativeTransfer], connectors: [])],
            approvedRegions: [], completedApprovals: [])
        let envelope = WalletReleaseTransitionEnvelope(schemaVersion: 2,
            sourceRevision: identity.sourceRevision, bundleVersion: identity.bundleVersion,
            outerAppCodeDirectoryHash: identity.outerAppCodeDirectoryHash,
            signerCodeDirectoryHash: identity.signerCodeDirectoryHash,
            archiveSHA256: String(repeating: "d", count: 64), releaseStage: .experimentalMainnet,
            issuedAt: issued, expiresAt: expiry, revision: 1,
            capabilityManifest: .init(manifest: cap, signatureBase64: try signature(cap)),
            reviewRestriction: .init(manifest: review, signatureBase64: try signature(review)),
            transition: .initial, purpose: .experimentalMainnet, candidateID: "",
            reviewCeilingSHA256: try WalletAuthorityEncoding.digest(ceilingValue),
            previousEnvelopeSHA256: nil, authoritySHA256: "", cohortID: nil,
            admissionGeneration: 0, revokedAdmissionSerials: [], permanentLimits: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WalletAuthorityEncoding.encode(envelope)) as? [String: Any])
        object["candidateID"] = try envelope.computedCandidateID()
        object["authoritySHA256"] = try envelope.computedAuthoritySHA256()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let completed = try decoder.decode(WalletReleaseTransitionEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object))
        let history = WalletReleaseHistoryRequest(schemaVersion: 1,
            transitions: [.init(envelope: completed, signatureBase64: try signature(completed))], admission: nil)
        let signer = FakeWalletSigner()
        signer.releaseHistoryApplyHandler = { [weak signer] request in
            guard let signer else { throw WalletReleaseActivationError.stateUnavailable }
            let current = signer.currentReleaseStatus
            let verified = try WalletReleaseHistoryVerifier.verify(request, ceiling: ceiling, key: key.publicKey,
                identity: identity, previous: current.checkpoint, installationID: current.installationID,
                allowExperimentalMainnet: true)
            return .init(installationID: current.installationID, checkpoint: verified.checkpoint)
        }
        let gateway = WalletGateway(signer: signer, connectionsClient: UnavailableWalletConnectionsClient(),
            recoveryView: FakeWalletRecoveryView(),
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1", "XCTestConfigurationFilePath": "fixture"],
            launchGate: try WalletLaunchGate())
        let configuration = WalletExperimentalActivationTestConfiguration(key: key.publicKey, ceiling: ceiling, identity: identity)
        signer.experimentalTestConfiguration = configuration
        gateway.configureExperimentalActivationForTesting(configuration)
        return (gateway, signer, try WalletAuthorityEncoding.encode(history))
    }

    func testExperimentalGatewayPreviewGrantsNothingUntilOneExplicitEnable() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let preview = try XCTUnwrap(gateway.experimentalMainnetActivationPreview)
        XCTAssertEqual(preview.networkGrants.map(\.networkID), ["eip155:1"])
        XCTAssertEqual(preview.networkGrants.first?.capabilities, [.nativeTransfer])
        XCTAssertEqual(signer.releaseHistoryApplyCount, 0)
        XCTAssertFalse(gateway.experimentalMainnetActive)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
        try await gateway.enableExperimentalMainnetActivation(previewID: preview.id)
        XCTAssertEqual(signer.releaseHistoryApplyCount, 2, "Explicit import, followed by idempotent signer hydration on refresh")
        XCTAssertEqual(signer.releaseHistoryStateChangeCount, 1)
        XCTAssertTrue(signer.hasOperationalReleaseAuthority)
        XCTAssertTrue(gateway.experimentalMainnetActive)
        XCTAssertNil(gateway.experimentalMainnetActivationPreview)
        XCTAssertNotNil(signer.currentReleaseStatus.checkpoint)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
        XCTAssertTrue(signer.executedIntentIDs.isEmpty)
        XCTAssertEqual(signer.authorizationCount, 0)
    }

    func testExperimentalGatewayReplacementAndDuplicatePreviewsCannotApply() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let oldID = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        try await gateway.previewExperimentalMainnetActivation(data)
        let currentID = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        XCTAssertNotEqual(oldID, currentID)
        do { try await gateway.enableExperimentalMainnetActivation(previewID: oldID); XCTFail("Stale review accepted") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 0)
        try await gateway.enableExperimentalMainnetActivation(previewID: currentID)
        do { try await gateway.enableExperimentalMainnetActivation(previewID: currentID); XCTFail("Review replay accepted") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 2)
        XCTAssertEqual(signer.releaseHistoryStateChangeCount, 1)
    }

    func testExperimentalGatewayLockCancelsUnconsumedReview() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let id = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        gateway.lock()
        do { try await gateway.enableExperimentalMainnetActivation(previewID: id); XCTFail("Canceled review accepted") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 0)
        XCTAssertFalse(gateway.experimentalMainnetActive)
    }

    func testExperimentalGatewayRestartRehydratesColdSignerFromPersistedCheckpoint() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        try await gateway.enableExperimentalMainnetActivation(
            previewID: XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id))
        XCTAssertEqual(signer.releaseHistoryStateChangeCount, 1)
        let checkpoint = try XCTUnwrap(signer.currentReleaseStatus.checkpoint)
        signer.hasOperationalReleaseAuthority = false
        let restarted = WalletGateway(signer: signer, connectionsClient: UnavailableWalletConnectionsClient(),
            recoveryView: FakeWalletRecoveryView(),
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1", "XCTestConfigurationFilePath": "fixture"],
            launchGate: try WalletLaunchGate())
        restarted.configureExperimentalActivationForTesting(try XCTUnwrap(signer.experimentalTestConfiguration))
        XCTAssertFalse(restarted.experimentalMainnetActive)
        await restarted.refreshStatus()
        XCTAssertTrue(signer.hasOperationalReleaseAuthority)
        XCTAssertTrue(restarted.experimentalMainnetActive)
        XCTAssertEqual(signer.currentReleaseStatus.checkpoint, checkpoint)
        XCTAssertEqual(signer.releaseHistoryApplyCount, 3)
        XCTAssertEqual(signer.releaseHistoryStateChangeCount, 1)
        XCTAssertTrue(restarted.activePolicies.isEmpty)
        XCTAssertTrue(signer.executedIntentIDs.isEmpty)
    }

    func testExperimentalGatewayChangedInstallationInvalidatesPreview() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let id = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        signer.currentReleaseStatus = .init(installationID: String(repeating: "e", count: 64), checkpoint: nil)
        do { try await gateway.enableExperimentalMainnetActivation(previewID: id); XCTFail("Replaced installation accepted") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 0)
        XCTAssertFalse(gateway.experimentalMainnetActive)
    }

    func testExperimentalGatewayDisableDuringSignerCallbackDoesNotPublishActivation() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let id = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        let verify = try XCTUnwrap(signer.releaseHistoryApplyHandler)
        signer.releaseHistoryApplyHandler = { [weak gateway] request in
            let committed = try await verify(request)
            gateway?.applyFeatureAccess(walletEnabled: false, browserEnabled: false)
            return committed
        }
        do { try await gateway.enableExperimentalMainnetActivation(previewID: id); XCTFail("Canceled callback published success") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 1)
        XCTAssertNotNil(signer.currentReleaseStatus.checkpoint, "Do not erase an already committed signer checkpoint")
        XCTAssertFalse(gateway.walletEnabled)
        XCTAssertFalse(gateway.experimentalMainnetActive)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
        XCTAssertNil(gateway.experimentalMainnetActivationPreview)
    }

    func testExperimentalGatewayRejectsForgedSignatureBeforeCreatingPreview() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        let original = try WalletExperimentalActivationImport.decode(data)
        let forged = WalletReleaseHistoryRequest(schemaVersion: 1, transitions: [
            .init(envelope: original.transitions[0].envelope, signatureBase64: Data(repeating: 0, count: 64).base64EncodedString())
        ], admission: nil)
        do { try await gateway.previewExperimentalMainnetActivation(WalletAuthorityEncoding.encode(forged)); XCTFail("Forged signature accepted") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 0)
        XCTAssertNil(gateway.experimentalMainnetActivationPreview)
        XCTAssertFalse(gateway.experimentalMainnetActive)
    }

    func testExperimentalGatewayLockDuringSignerCallbackDoesNotPublishActivation() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let id = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        let verify = try XCTUnwrap(signer.releaseHistoryApplyHandler)
        signer.releaseHistoryApplyHandler = { [weak gateway] request in
            let committed = try await verify(request)
            gateway?.lock()
            return committed
        }
        do { try await gateway.enableExperimentalMainnetActivation(previewID: id); XCTFail("Lock callback published success") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 1)
        XCTAssertNotNil(signer.currentReleaseStatus.checkpoint)
        XCTAssertTrue(gateway.walletEnabled)
        XCTAssertEqual(gateway.status, .locked)
        XCTAssertFalse(gateway.experimentalMainnetActive)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
    }

    func testExperimentalGatewayLockDuringRefreshDoesNotPublishSuccess() async throws {
        let (gateway, signer, data) = try experimentalGatewayFixture()
        try await gateway.previewExperimentalMainnetActivation(data)
        let id = try XCTUnwrap(gateway.experimentalMainnetActivationPreview?.id)
        let verify = try XCTUnwrap(signer.releaseHistoryApplyHandler)
        signer.releaseHistoryApplyHandler = { [weak gateway, weak signer] request in
            let committed = try await verify(request)
            if signer?.releaseHistoryApplyCount == 2 { gateway?.lock() }
            return committed
        }
        do { try await gateway.enableExperimentalMainnetActivation(previewID: id); XCTFail("Lock during refresh published success") } catch { }
        XCTAssertEqual(signer.releaseHistoryApplyCount, 2)
        XCTAssertEqual(signer.releaseHistoryStateChangeCount, 1)
        XCTAssertNotNil(signer.currentReleaseStatus.checkpoint)
        XCTAssertEqual(gateway.status, .locked)
        XCTAssertFalse(gateway.experimentalMainnetActive)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
    }
    #endif

    /// Intake fixtures deliberately contain invalid signatures. Intake may
    /// decode them; the separate history verifier must still authenticate them.
    private func experimentalIntakeHistory(
        stage: WalletReleaseStage = .experimentalMainnet,
        purpose: WalletReleasePurpose = .experimentalMainnet
    ) -> WalletReleaseHistoryRequest {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let capability = WalletCapabilityManifest(schemaVersion: 3, revision: 1,
            releaseStage: stage, evidenceIndexSHA256: "", issuedAt: now,
            expiresAt: now.addingTimeInterval(600), networkGrants: [],
            approvedRegions: [], completedApprovals: [])
        let review = WalletReviewManifest(schemaVersion: 2, revision: 1,
            issuedAt: now, expiresAt: now.addingTimeInterval(600), assets: [],
            evmContracts: [], explorerTemplates: [:], adapterIDs: [])
        let envelope = WalletReleaseTransitionEnvelope(schemaVersion: 2,
            sourceRevision: String(repeating: "a", count: 40), bundleVersion: "1",
            outerAppCodeDirectoryHash: String(repeating: "b", count: 40),
            signerCodeDirectoryHash: String(repeating: "c", count: 40),
            archiveSHA256: String(repeating: "d", count: 64), releaseStage: stage,
            issuedAt: now, expiresAt: now.addingTimeInterval(600), revision: 1,
            capabilityManifest: .init(manifest: capability, signatureBase64: "invalid"),
            reviewRestriction: .init(manifest: review, signatureBase64: "invalid"),
            transition: .initial, purpose: purpose, candidateID: String(repeating: "e", count: 64),
            reviewCeilingSHA256: String(repeating: "f", count: 64), previousEnvelopeSHA256: nil,
            authoritySHA256: String(repeating: "a", count: 64), cohortID: nil,
            admissionGeneration: 0, revokedAdmissionSerials: [], permanentLimits: [])
        return .init(schemaVersion: 1, transitions: [.init(envelope: envelope, signatureBase64: "invalid")], admission: nil)
    }

    func testExperimentalImportIntakeRejectsEmptyOversizedAndMalformedFiles() {
        for data in [Data(), Data(repeating: 0x20, count: WalletExperimentalActivationImport.maximumBytes + 1),
                     Data("{}".utf8)] {
            XCTAssertThrowsError(try WalletExperimentalActivationImport.decode(data))
        }
    }

    func testExperimentalImportIntakeRequiresBothExperimentalStageAndPurpose() throws {
        for pair: (WalletReleaseStage, WalletReleasePurpose) in [
            (.invitedCanary, .production), (.generalAvailability, .production),
            (.experimentalMainnet, .production), (.invitedCanary, .experimentalMainnet),
            (.experimentalMainnet, .testnetRehearsal),
        ] {
            XCTAssertThrowsError(try WalletExperimentalActivationImport.decode(
                WalletAuthorityEncoding.encode(experimentalIntakeHistory(stage: pair.0, purpose: pair.1))))
        }
        let request = experimentalIntakeHistory()
        XCTAssertEqual(try WalletExperimentalActivationImport.decode(WalletAuthorityEncoding.encode(request)), request)
    }

    func testExperimentalImportIntakeRejectsMixedAndEmptyHistories() throws {
        let experimental = experimentalIntakeHistory().transitions
        let production = experimentalIntakeHistory(stage: .generalAvailability, purpose: .production).transitions
        for transitions in [[], experimental + production,
            Array(repeating: experimental[0], count: WalletReleaseHistoryVerifier.maximumTransitions + 1)] {
            let request = WalletReleaseHistoryRequest(schemaVersion: 1, transitions: transitions, admission: nil)
            XCTAssertThrowsError(try WalletExperimentalActivationImport.decode(WalletAuthorityEncoding.encode(request)))
        }
    }

    func testRemoteHistoryCannotIntroduceExperimentalAuthority() {
        XCTAssertTrue(WalletExperimentalActivationImport.containsExperimentalAuthority(experimentalIntakeHistory()))
        XCTAssertTrue(WalletExperimentalActivationImport.containsExperimentalAuthority(
            experimentalIntakeHistory(stage: .invitedCanary, purpose: .experimentalMainnet)))
        XCTAssertFalse(WalletExperimentalActivationImport.containsExperimentalAuthority(
            experimentalIntakeHistory(stage: .invitedCanary, purpose: .production)))
    }

    func testExperimentalEnableWithoutAnExplicitPreviewGrantsNothing() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [:], launchGate: try! WalletLaunchGate())
        do {
            try await gateway.enableExperimentalMainnetActivation(previewID: UUID())
            XCTFail("A missing review must never authorize mainnet")
        } catch { }
        XCTAssertNil(gateway.experimentalMainnetActivationPreview)
        XCTAssertFalse(gateway.experimentalMainnetActive)
        XCTAssertTrue(gateway.activePolicies.isEmpty)
        XCTAssertEqual(signer.authorizationCount, 0)
        XCTAssertTrue(signer.executedIntentIDs.isEmpty)
    }
    #endif

    private func prepared(
        riskFlags: [WalletRiskFlag] = [],
        adapterID: String? = "native-eth-transfer-v1",
        expiresAt: Date = Date().addingTimeInterval(120),
        simulationSucceeded: Bool = true,
        policyDecision: String = ""
    ) -> WalletPreparedTransaction {
        WalletPreparedTransaction(
            id: "intent-1", digest: "digest", networkID: WalletGateway.sepoliaNetworkID,
            accountID: "account-1", source: .agent,
            action: .nativeTransfer(recipient: "0x1111111111111111111111111111111111111111", amountBaseUnits: "10"),
            summary: "Transfer", effects: [], riskFlags: riskFlags, contract: nil,
            adapterID: adapterID, budgetAssetID: "slip44:60", spendBaseUnits: "10",
            maximumFeeBaseUnits: "20", feeQuoteBaseUnits: "15", simulation: "Success",
            simulationSucceeded: simulationSucceeded, nonce: "1", createdAt: Date(),
            expiresAt: expiresAt, policyDecision: policyDecision, policyID: nil
        )
    }

    private func policy() -> WalletSessionPolicy {
        WalletSessionPolicy(
            id: "policy-1", accountID: "account-1", networkID: WalletGateway.sepoliaNetworkID,
            allowedAssetIDs: ["slip44:60"], allowedRecipients: ["0x1111111111111111111111111111111111111111"],
            allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
            maximumTransactionBaseUnits: "25", maximumSessionBaseUnits: "50",
            maximumFeeBaseUnits: "20", expiresAt: Date().addingTimeInterval(300)
        )
    }

    func testBaseUnitArithmeticDoesNotRoundLargeValues() {
        XCTAssertEqual(WalletBaseUnits.normalize("0000010"), "10")
        XCTAssertEqual(WalletBaseUnits.add("999999999999999999999999", "1"),
                       "1000000000000000000000000")
        XCTAssertEqual(WalletBaseUnits.subtract("1000000000000000000000000", "1"),
                       "999999999999999999999999")
        XCTAssertEqual(WalletBaseUnits.subtract("1000", "1000"), "0")
        XCTAssertNil(WalletBaseUnits.subtract("999", "1000"))
        XCTAssertEqual(WalletBaseUnits.multiply("18446744073709551616", "1000000000"),
                       "18446744073709551616000000000")
        XCTAssertTrue(WalletBaseUnits.lessThanOrEqual("18446744073709551616", "18446744073709551617"))
        XCTAssertFalse(WalletBaseUnits.lessThanOrEqual("1.0", "2"))
        XCTAssertNil(WalletBaseUnits.normalize("١٠"))
        XCTAssertEqual(WalletEthereumQuantity.decimalToHex("18446744073709551616"),
                       "0x10000000000000000")
        XCTAssertEqual(WalletEthereumQuantity.hexToDecimal("0x10000000000000000"),
                       "18446744073709551616")
        XCTAssertNil(WalletEthereumQuantity.hexToDecimal("0xnot-hex"))
        XCTAssertEqual(WalletAmountFormatter.baseUnits(from: "1.5", decimals: 6), "1500000")
        XCTAssertEqual(
            WalletAmountFormatter.asset(baseUnits: "1500000", decimals: 6, symbol: "TOK"),
            "1.5 TOK"
        )
    }

    func testProtocolV2SemanticActionsRoundTripWithoutRawSigningMaterial() throws {
        let action = WalletSemanticAction.exactInputSwap(
            adapterID: "reviewed-swap-v1",
            inputAssetID: "eip155:1/erc20:0x1111111111111111111111111111111111111111",
            outputAssetID: "eip155:1/erc20:0x2222222222222222222222222222222222222222",
            amountInBaseUnits: "1000", minimumOutputBaseUnits: "975",
            recipient: "0x3333333333333333333333333333333333333333"
        )
        let encoded = try JSONEncoder().encode(action)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private_key"))
        XCTAssertFalse(text.contains("raw_transaction"))
        XCTAssertFalse(text.contains("digest"))
        XCTAssertEqual(try JSONDecoder().decode(WalletSemanticAction.self, from: encoded), action)
    }

    func testSignerDerivedAccountsPayloadMapsSnakeCaseNetworkIDs() throws {
        let payload = Data(
            #"""
            {"accounts":[{"id":"locus-vault-evm-0","chain":"evm","address":"0xabc","label":"Locus Vault EVM","network_ids":["eip155:1","eip155:11155111"]}]}
            """#.utf8
        )

        let accounts = try WalletDerivedAccountsDecoder.decode(payload)

        XCTAssertEqual(accounts, [WalletAccount(
            id: "locus-vault-evm-0", chain: .evm, address: "0xabc",
            label: "Locus Vault EVM",
            networkIDs: ["eip155:1", "eip155:11155111"]
        )])
        let swiftWire = String(
            decoding: try JSONEncoder().encode(accounts[0]), as: UTF8.self
        )
        XCTAssertTrue(swiftWire.contains("\"networkIDs\""))
        XCTAssertFalse(swiftWire.contains("network_ids"))
    }

    func testWalletVaultKeyUsesProvisionedDataProtectionKeychain() {
        let base = WalletVaultKeychainQuery.base(
            service: "io.sparktales.locus.WalletSigner.wrap.v2",
            account: "locus-mainnet-vault"
        )
        let add = WalletVaultKeychainQuery.add(
            service: "io.sparktales.locus.WalletSigner.wrap.v2",
            account: "locus-mainnet-vault",
            keyData: Data(repeating: 3, count: 32)
        )

        for query in [base, add] {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(
                query[kSecAttrAccessGroup as String] as? String,
                WalletVaultKeychainQuery.accessGroup
            )
            XCTAssertNil(query[kSecAttrAccessControl as String])
        }
        XCTAssertNil(base[kSecAttrAccessible as String])
        XCTAssertEqual(
            add[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            add[kSecAttrService as String] as? String,
            base[kSecAttrService as String] as? String
        )
        XCTAssertEqual(
            add[kSecAttrAccount as String] as? String,
            base[kSecAttrAccount as String] as? String
        )
        XCTAssertEqual(add[kSecValueData as String] as? Data, Data(repeating: 3, count: 32))
    }

    func testRecoveryCeremonyReturnsOnlyStatusAndPublicAccountsToMainProcess() async throws {
        let signer = FakeWalletSigner()
        signer.reportedVaultState = .missing
        let recovery = FakeWalletRecoveryView()
        let gateway = WalletGateway(
            signer: signer, recoveryView: recovery,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"]
        )
        await gateway.refreshStatus()
        let completed = await gateway.beginVaultCreation()
        XCTAssertTrue(completed)
        XCTAssertEqual(recovery.presentedModes, [.create])
        XCTAssertEqual(gateway.accounts.first?.address, "0xabc")

        let result = WalletRecoveryCeremonyResult(
            ceremonyID: "ceremony-1", outcome: .completed,
            signerStatus: try await signer.signerStatus(), error: nil
        )
        let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(wire.contains("words"))
        XCTAssertFalse(wire.contains("phrase"))
        XCTAssertFalse(wire.contains("entropy"))
    }

    func testSignedLaunchManifestCanOnlyNarrowBundledAuthority() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let limited = WalletNetworkDescriptor(
            canonicalID: "eip155:1", chain: .evm, environment: .mainnet,
            displayName: "Ethereum", identity: .init(kind: .eip155ChainID, value: "1"),
            nativeAssetID: "eip155:1/slip44:60", nativeSymbol: "ETH", nativeDecimals: 18,
            explorerTransactionURLTemplate: "https://etherscan.io/tx/{transaction}",
            staticallyReviewedCapabilities: [.nativeTransfer]
        )
        let manifest = WalletCapabilityManifest(
            schemaVersion: 3, revision: 1, releaseStage: .generalAvailability,
            evidenceIndexSHA256: String(repeating: "b", count: 64),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            networkGrants: [.init(
                networkID: limited.id,
                capabilities: [.nativeTransfer],
                connectors: []
            )],
            approvedRegions: ["CA"],
            completedApprovals: WalletLaunchGate.requiredGAApprovals
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try privateKey.signature(for: encoder.encode(manifest)).base64EncodedString()
        let gate = try WalletLaunchGate(
            bundledNetworks: [limited],
            signedManifest: .init(manifest: manifest, signatureBase64: signature),
            publicKey: privateKey.publicKey,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNoThrow(try gate.authorize(
            networkID: limited.id, capability: .nativeTransfer, regionCode: "ca"
        ))
        XCTAssertThrowsError(try gate.authorize(
            networkID: limited.id, capability: .exactInputSwap, regionCode: "CA"
        )) { error in
            XCTAssertEqual(error as? WalletLaunchGateError, .capabilityNotReviewed)
        }
    }

    func testInvitedCanaryCannotClaimGeneralAvailability() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = WalletCapabilityManifest(
            schemaVersion: 3, revision: 7, releaseStage: .invitedCanary,
            evidenceIndexSHA256: String(repeating: "a", count: 64),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            networkGrants: [.init(
                networkID: WalletNetworkCatalog.ethereumMainnet.id,
                capabilities: [.nativeTransfer],
                connectors: []
            )],
            approvedRegions: ["CA"],
            completedApprovals: WalletLaunchGate.requiredCanaryApprovals
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try privateKey.signature(for: encoder.encode(manifest))
        let gate = try WalletLaunchGate(
            signedManifest: .init(
                manifest: manifest, signatureBase64: signature.base64EncodedString()
            ),
            publicKey: privateKey.publicKey,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNoThrow(try gate.authorize(
            networkID: WalletNetworkCatalog.ethereumMainnet.id,
            capability: .nativeTransfer, regionCode: "CA"
        ))
        XCTAssertThrowsError(try gate.authorize(
            networkID: WalletNetworkCatalog.ethereumMainnet.id,
            capability: .nativeTransfer, regionCode: "CA", requireGA: true
        )) { error in
            XCTAssertEqual(error as? WalletLaunchGateError, .generalAvailabilityNotApproved)
        }
    }

    func testSignedReviewManifestCuratesExactMetadataAndRemoteOnlyNarrowsIt() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let contract = "0x1111111111111111111111111111111111111111"
        let abi = #"[{"inputs":[{"type":"address"},{"type":"uint256"}],"name":"transfer","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"}]"#
        let digest = "sha256:" + SHA256.hash(data: Data(abi.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = WalletAsset(
            canonicalID: "eip155:1/erc20:\(contract)", networkID: "eip155:1",
            chain: .evm, kind: .fungibleToken, reference: contract,
            name: "Reviewed Token", symbol: "RVT", decimals: 6,
            trust: .curated, manifestRevision: 4
        )
        let entry = WalletContractRegistryEntry(
            id: "erc20.reviewed", networkID: "eip155:1", checksumAddress: contract,
            label: "Reviewed Token", normalizedABI: abi, abiDigest: digest,
            runtimeCodeHash: "0x" + String(repeating: "a", count: 64),
            permittedFunctions: ["transfer(address,uint256)"],
            permittedSelectors: ["0xa9059cbb"],
            reviewedAdapterID: WalletReviewedAdapters.erc20,
            verifiedAt: issuedAt.addingTimeInterval(-60)
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 4, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(20 * 24 * 60 * 60),
            assets: [asset], evmContracts: [entry],
            explorerTemplates: [
                "eip155:1": WalletNetworkCatalog.ethereumMainnet
                    .explorerTransactionURLTemplate,
            ],
            adapterIDs: [WalletReviewedAdapters.erc20]
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: privateKey),
            publicKey: privateKey.publicKey,
            now: issuedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(registry.assets, [asset])
        XCTAssertTrue(registry.containsExactContract(entry))

        let extra = WalletAsset(
            canonicalID: "eip155:1/erc20:0x2222222222222222222222222222222222222222",
            networkID: "eip155:1", chain: .evm, kind: .fungibleToken,
            reference: "0x2222222222222222222222222222222222222222",
            name: "Unbundled", symbol: "NEW", decimals: 18,
            trust: .curated, manifestRevision: 5
        )
        let retained = WalletAsset(
            canonicalID: asset.canonicalID, networkID: asset.networkID,
            chain: asset.chain, kind: asset.kind, reference: asset.reference,
            name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            trust: asset.trust, manifestRevision: 5
        )
        let restriction = WalletReviewManifest(
            schemaVersion: 2, revision: 5,
            issuedAt: issuedAt.addingTimeInterval(120),
            expiresAt: issuedAt.addingTimeInterval(10 * 24 * 60 * 60),
            assets: [retained, extra], evmContracts: [],
            explorerTemplates: [:], adapterIDs: []
        )
        XCTAssertThrowsError(try registry.restricted(
            by: signedReview(restriction, key: privateKey),
            publicKey: privateKey.publicKey,
            now: issuedAt.addingTimeInterval(180)
        )) { error in
            XCTAssertEqual(error as? WalletReviewManifestError, .broaderThanBundledReview)
        }
        let exactRestriction = WalletReviewManifest(
            schemaVersion: 2, revision: 5,
            issuedAt: issuedAt.addingTimeInterval(120),
            expiresAt: issuedAt.addingTimeInterval(10 * 24 * 60 * 60),
            assets: [retained], evmContracts: [], explorerTemplates: [:], adapterIDs: []
        )
        let narrowed = try registry.restricted(
            by: signedReview(exactRestriction, key: privateKey),
            publicKey: privateKey.publicKey,
            now: issuedAt.addingTimeInterval(180)
        )
        XCTAssertEqual(narrowed.assets.map(\.id), [asset.id])
        XCTAssertTrue(narrowed.evmContracts.isEmpty)
        XCTAssertFalse(narrowed.manifest.adapterIDs.contains(WalletReviewedAdapters.erc20))
    }

    func testUnsignedPersistedCuratedAssetIsNotTrustedAfterRestart() throws {
        let store = try WalletPublicStore(path: ":memory:")
        try store.upsertAsset(WalletAsset(
            canonicalID: "eip155:1/erc20:0x1111111111111111111111111111111111111111",
            networkID: "eip155:1", chain: .evm, kind: .fungibleToken,
            reference: "0x1111111111111111111111111111111111111111",
            name: "Spoofed Curated", symbol: "FAKE", decimals: 18,
            trust: .curated, manifestRevision: 99
        ))
        let gateway = WalletGateway(
            signer: FakeWalletSigner(), environment: [:], publicStore: store
        )
        XCTAssertTrue(gateway.assets.isEmpty)
    }

    func testWalletSendEligibilityExposesOnlyReviewedMultichainPaths() {
        func snapshot(
            chain: WalletChain,
            networkID: String,
            assetID: String,
            symbol: String
        ) -> WalletAccountSnapshot {
            WalletAccountSnapshot(
                accountID: "account", chain: chain, address: "address",
                label: "Account", networkID: networkID, assetID: assetID,
                symbol: symbol, balanceBaseUnits: "1", refreshedAt: Date(),
                freshness: .current
            )
        }

        let suiNetwork = WalletNetworkCatalog.suiTestnet
        let nativeSui = snapshot(
            chain: .sui, networkID: suiNetwork.id,
            assetID: suiNetwork.nativeAssetID, symbol: "SUI"
        )
        XCTAssertTrue(WalletSendEligibility.supports(
            snapshot: nativeSui, assets: []
        ))

        let coinIdentity = WalletSuiAssetIdentity(
            networkID: suiNetwork.id, coinType: "0x1234::coin::COIN"
        )
        let reviewedCoin = WalletAsset(
            canonicalID: coinIdentity.canonicalID, networkID: suiNetwork.id,
            chain: .sui, kind: .fungibleToken,
            reference: coinIdentity.coinType, name: "Reviewed Coin",
            symbol: "COIN", decimals: 6, trust: .curated,
            manifestRevision: 1
        )
        let coinSnapshot = snapshot(
            chain: .sui, networkID: suiNetwork.id,
            assetID: reviewedCoin.id, symbol: reviewedCoin.symbol
        )
        XCTAssertTrue(WalletSendEligibility.supports(
            snapshot: coinSnapshot, assets: [reviewedCoin]
        ))
        let locallyTrustedCoin = WalletAsset(
            canonicalID: reviewedCoin.id, networkID: reviewedCoin.networkID,
            chain: reviewedCoin.chain, kind: reviewedCoin.kind,
            reference: reviewedCoin.reference, name: reviewedCoin.name,
            symbol: reviewedCoin.symbol, decimals: reviewedCoin.decimals,
            trust: .userTrusted, manifestRevision: 0
        )
        XCTAssertFalse(WalletSendEligibility.supports(
            snapshot: coinSnapshot, assets: [locallyTrustedCoin]
        ))

        let objectIdentity = WalletSuiObjectIdentity(
            networkID: suiNetwork.id,
            objectID: "0x" + String(repeating: "3", count: 64)
        )
        let reviewedObject = WalletAsset(
            canonicalID: objectIdentity.canonicalID, networkID: suiNetwork.id,
            chain: .sui, kind: .collectible,
            reference: objectIdentity.objectID, name: "Reviewed Object",
            symbol: "OBJECT", decimals: 0, trust: .curated,
            manifestRevision: 1
        )
        XCTAssertTrue(WalletSendEligibility.supports(
            snapshot: snapshot(
                chain: .sui, networkID: suiNetwork.id,
                assetID: reviewedObject.id, symbol: reviewedObject.symbol
            ), assets: [reviewedObject]
        ))
        let locallyTrustedObject = WalletAsset(
            canonicalID: reviewedObject.id,
            networkID: reviewedObject.networkID,
            chain: reviewedObject.chain, kind: reviewedObject.kind,
            reference: reviewedObject.reference, name: reviewedObject.name,
            symbol: reviewedObject.symbol, decimals: reviewedObject.decimals,
            trust: .userTrusted, manifestRevision: 0
        )
        XCTAssertFalse(WalletSendEligibility.supports(
            snapshot: snapshot(
                chain: .sui, networkID: suiNetwork.id,
                assetID: reviewedObject.id, symbol: reviewedObject.symbol
            ), assets: [locallyTrustedObject]
        ))

        let mint = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let tokenIdentity = WalletSolanaAssetIdentity(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            program: .token2022, mint: mint
        )
        let token = WalletAsset(
            canonicalID: tokenIdentity.canonicalID,
            networkID: tokenIdentity.networkID, chain: .solana,
            kind: .fungibleToken, reference: mint, name: "Token-2022",
            symbol: "T22", decimals: 6, trust: .userTrusted,
            manifestRevision: 0
        )
        XCTAssertTrue(WalletSendEligibility.supports(
            snapshot: snapshot(
                chain: .solana, networkID: tokenIdentity.networkID,
                assetID: token.id, symbol: token.symbol
            ), assets: [token]
        ))

        let coreAddress = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let coreIdentity = WalletSolanaCollectibleIdentity(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            standard: .core, address: coreAddress
        )
        let coreAsset = WalletAsset(
            canonicalID: coreIdentity.canonicalID,
            networkID: coreIdentity.networkID, chain: .solana,
            kind: .collectible, reference: coreAddress,
            name: "Reviewed Core Asset", symbol: "CORE", decimals: nil,
            trust: .curated, manifestRevision: 1
        )
        XCTAssertTrue(WalletSendEligibility.supports(
            snapshot: snapshot(
                chain: .solana, networkID: coreIdentity.networkID,
                assetID: coreAsset.id, symbol: coreAsset.symbol
            ), assets: [coreAsset]
        ))
    }

    func testSignedReviewManifestRequiresCanonicalSolanaMintIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let mint = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let asset = WalletAsset(
            canonicalID: "solana:mainnet-beta/spl:\(mint)",
            networkID: WalletNetworkCatalog.solanaMainnet.id,
            chain: .solana, kind: .fungibleToken, reference: mint,
            name: "Reviewed SPL Token", symbol: "SPL", decimals: 6,
            trust: .curated, manifestRevision: 1
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 1, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(registry.assets, [asset])

        let mismatched = WalletAsset(
            canonicalID: asset.canonicalID, networkID: asset.networkID,
            chain: asset.chain, kind: asset.kind,
            reference: WalletSolanaBase58.encode(Data(repeating: 5, count: 32)),
            name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            trust: asset.trust, manifestRevision: asset.manifestRevision
        )
        let invalid = WalletReviewManifest(
            schemaVersion: 2, revision: 1, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [mismatched], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        XCTAssertThrowsError(try WalletReviewRegistry(
            signedManifest: signedReview(invalid, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        ))
    }

    func testSignedReviewManifestCuratesExactSolanaCollectibleIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let address = WalletSolanaBase58.encode(Data(repeating: 14, count: 32))
        let asset = WalletAsset(
            canonicalID: "solana:mainnet-beta/nft:core:\(address)",
            networkID: WalletNetworkCatalog.solanaMainnet.id,
            chain: .solana, kind: .collectible, reference: address,
            name: "Reviewed Core Asset", symbol: "CORE", decimals: 0,
            trust: .curated, manifestRevision: 2
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 2, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(registry.assets, [asset])

        let wrongReference = WalletAsset(
            canonicalID: asset.canonicalID, networkID: asset.networkID,
            chain: asset.chain, kind: asset.kind,
            reference: WalletSolanaBase58.encode(Data(repeating: 15, count: 32)),
            name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            trust: asset.trust, manifestRevision: asset.manifestRevision
        )
        let invalid = WalletReviewManifest(
            schemaVersion: 2, revision: 2, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [wrongReference], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        XCTAssertThrowsError(try WalletReviewRegistry(
            signedManifest: signedReview(invalid, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        ))
    }

    func testSignedReviewManifestRequiresCanonicalSuiCoinIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let coinType = "0x1234::example::COIN"
        let asset = WalletAsset(
            canonicalID: "sui:mainnet/coin:\(coinType)",
            networkID: WalletNetworkCatalog.suiMainnet.id,
            chain: .sui, kind: .fungibleToken, reference: coinType,
            name: "Reviewed Coin", symbol: "COIN", decimals: 6,
            trust: .curated, manifestRevision: 3
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 3, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(registry.assets, [asset])
        XCTAssertEqual(
            WalletSuiAssetIdentity.parse(asset.canonicalID)?.coinType,
            coinType
        )

        let malformed = WalletAsset(
            canonicalID: "sui:mainnet/coin:0x01234::example::COIN",
            networkID: asset.networkID, chain: asset.chain,
            kind: asset.kind, reference: "0x01234::example::COIN",
            name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            trust: asset.trust, manifestRevision: asset.manifestRevision
        )
        let invalid = WalletReviewManifest(
            schemaVersion: 2, revision: 3, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [malformed], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        XCTAssertThrowsError(try WalletReviewRegistry(
            signedManifest: signedReview(invalid, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        ))
    }

    func testSignedReviewManifestRequiresCanonicalSuiObjectIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let objectID = "0x" + String(repeating: "a", count: 64)
        let asset = WalletAsset(
            canonicalID: "sui:mainnet/object:\(objectID)",
            networkID: WalletNetworkCatalog.suiMainnet.id,
            chain: .sui, kind: .collectible, reference: objectID,
            name: "Reviewed Object", symbol: "OBJECT", decimals: 0,
            trust: .curated, manifestRevision: 4
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 4, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(registry.assets, [asset])
        XCTAssertEqual(
            WalletSuiObjectIdentity.parse(asset.canonicalID)?.objectID,
            objectID
        )

        let uppercase = objectID.uppercased().replacingOccurrences(of: "0X", with: "0x")
        let malformed = WalletAsset(
            canonicalID: "sui:mainnet/object:\(uppercase)",
            networkID: asset.networkID, chain: asset.chain,
            kind: asset.kind, reference: uppercase,
            name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            trust: asset.trust, manifestRevision: asset.manifestRevision
        )
        let invalid = WalletReviewManifest(
            schemaVersion: 2, revision: 4, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [malformed], evmContracts: [], explorerTemplates: [:],
            adapterIDs: []
        )
        XCTAssertThrowsError(try WalletReviewRegistry(
            signedManifest: signedReview(invalid, key: key),
            publicKey: key.publicKey,
            now: issuedAt.addingTimeInterval(1)
        ))
    }

    func testPublicWalletSQLiteStorePersistsOnlyPublicRecordsAndQuarantine() throws {
        let store = try WalletPublicStore(path: ":memory:")
        let record = WalletActivityRecord(
            id: "0xtx", intentID: "intent", transactionHash: "0xtx",
            networkID: WalletGateway.ethereumMainnetNetworkID, accountID: "account",
            summary: "Submitted transfer", submittedAt: Date(timeIntervalSince1970: 100),
            state: .submitted, blockNumber: nil, lastCheckedAt: nil, detail: nil
        )
        try store.upsertActivity(record)
        XCTAssertEqual(try store.loadActivities(), [record])

        let unknown = WalletAsset(
            canonicalID: "eip155:1/erc20:0x1111111111111111111111111111111111111111",
            networkID: "eip155:1", chain: .evm, kind: .fungibleToken,
            reference: "0x1111111111111111111111111111111111111111",
            name: "Unknown", symbol: "UNKNOWN", decimals: nil,
            trust: .quarantined, manifestRevision: 0
        )
        try store.upsertAsset(unknown)
        XCTAssertEqual(try store.loadAssets(), [unknown])
        XCTAssertFalse(try XCTUnwrap(store.loadAssets().first).isVisibleByDefault)
    }

    func testContractRegistryAddressUsesEIP55Checksum() throws {
        let address = try WalletSepoliaRPCClient.checksummedAddress(
            "0x52908400098527886e0f7030069857d2e4169ee7",
            keccakHash: "0x297c1ba3882c3eb45bc8970bdb323ffa98749993835ebfa9b4150ee83081da79"
        )
        XCTAssertEqual(address, "0x52908400098527886E0F7030069857D2E4169EE7")
    }

    func testReviewedAdapterClassificationCannotBeSelfAsserted() {
        let erc20ABI = #"[{"type":"function","name":"transfer","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]}]"#
        XCTAssertEqual(
            WalletReviewedAdapters.classify(
                normalizedABI: erc20ABI,
                permittedFunctions: ["transfer(address,uint256)"]
            ),
            WalletReviewedAdapters.erc20
        )
        let mismatchedABI = #"[{"type":"function","name":"transfer","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"bytes32"}],"outputs":[]}]"#
        XCTAssertNil(WalletReviewedAdapters.classify(
            normalizedABI: mismatchedABI,
            permittedFunctions: ["transfer(address,uint256)"]
        ))

        let routerABI = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],"outputs":[]}]"#
        XCTAssertEqual(
            WalletReviewedAdapters.classify(
                normalizedABI: routerABI,
                permittedFunctions: ["execute(bytes,bytes[],uint256)"]
            ),
            WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn
        )
        let legacyRouter = WalletContractRegistryEntry(
            id: "uniswap.legacy", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: "0x1111111111111111111111111111111111111111",
            label: "Legacy Router", normalizedABI: routerABI,
            abiDigest: "sha256:test", runtimeCodeHash: "0xcode",
            permittedFunctions: ["execute(bytes,bytes[],uint256)"],
            permittedSelectors: ["0x3593564c"],
            reviewedAdapterID:
                WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
            verifiedAt: Date()
        )
        XCTAssertEqual(
            WalletReviewedAdapters.validatedID(for: legacyRouter),
            WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn
        )
        XCTAssertNil(WalletReviewedAdapters.classify(
            normalizedABI: routerABI,
            permittedFunctions: ["execute(bytes,bytes[],uint256)", "execute(bytes,bytes[])"]
        ))

        let erc721ABI = #"[{"type":"function","name":"safeTransferFrom","stateMutability":"nonpayable","inputs":[{"type":"address"},{"type":"address"},{"type":"uint256"}],"outputs":[]}]"#
        XCTAssertEqual(WalletReviewedAdapters.classify(
            normalizedABI: erc721ABI,
            permittedFunctions: ["safeTransferFrom(address,address,uint256)"]
        ), WalletReviewedAdapters.erc721SafeTransfer)

        let erc1155ABI = #"[{"type":"function","name":"safeTransferFrom","stateMutability":"nonpayable","inputs":[{"type":"address"},{"type":"address"},{"type":"uint256"},{"type":"uint256"},{"type":"bytes"}],"outputs":[]}]"#
        XCTAssertEqual(WalletReviewedAdapters.classify(
            normalizedABI: erc1155ABI,
            permittedFunctions: ["safeTransferFrom(address,address,uint256,uint256,bytes)"]
        ), WalletReviewedAdapters.erc1155SafeTransfer)
    }

    func testSemanticEVMAssetAdaptersBuildOnlyReviewedStandardCalls() throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let recipient = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let contract = "0x1111111111111111111111111111111111111111"
        let erc721ABI = #"[{"type":"function","name":"safeTransferFrom","stateMutability":"nonpayable","inputs":[{"type":"address"},{"type":"address"},{"type":"uint256"}],"outputs":[]}]"#
        let entry = WalletContractRegistryEntry(
            id: "nft.collection", networkID: WalletGateway.ethereumMainnetNetworkID,
            checksumAddress: contract, label: "Collection", normalizedABI: erc721ABI,
            abiDigest: "sha256:test", runtimeCodeHash: "0x" + String(repeating: "1", count: 64),
            permittedFunctions: ["safeTransferFrom(address,address,uint256)"],
            permittedSelectors: ["0x42842e0e"],
            reviewedAdapterID: WalletReviewedAdapters.erc721SafeTransfer,
            verifiedAt: Date()
        )
        let action = WalletSemanticAction.nftTransfer(
            assetID: "eip155:1/erc721:\(contract)/7",
            tokenID: "7", recipient: recipient
        )
        let call = try XCTUnwrap(WalletEVMAssetAdapter.resolve(
            action: action, registryEntry: entry, accountAddress: account
        ))
        XCTAssertEqual(call.function, "safeTransferFrom(address,address,uint256)")
        XCTAssertEqual(call.arguments.map(\.value), [account, recipient, "7"])

        let substituted = WalletSemanticAction.nftTransfer(
            assetID: "eip155:1/erc721:\(contract)/8",
            tokenID: "7", recipient: recipient
        )
        XCTAssertNil(WalletEVMAssetAdapter.resolve(
            action: substituted, registryEntry: entry, accountAddress: account
        ))
        XCTAssertNil(WalletEVMAssetIdentity.parse(
            "eip155:01/erc721:\(contract)/7"
        ))
    }

    func testTrustedERC20SemanticTransferResolvesVerifiedRegistry() async throws {
        let store = try WalletPublicStore(path: ":memory:")
        let contract = "0x1111111111111111111111111111111111111111"
        let assetID = "\(WalletGateway.sepoliaNetworkID)/erc20:\(contract)"
        try store.upsertAsset(WalletAsset(
            canonicalID: assetID, networkID: WalletGateway.sepoliaNetworkID,
            chain: .evm, kind: .fungibleToken, reference: contract,
            name: "Reviewed Token", symbol: "RVT", decimals: 6,
            trust: .userTrusted, manifestRevision: 1
        ))
        let abi = #"[{"type":"function","name":"transfer","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"type":"bool"}]}]"#
        let entry = WalletContractRegistryEntry(
            id: "erc20.reviewed", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: contract, label: "Reviewed Token", normalizedABI: abi,
            abiDigest: "sha256:test", runtimeCodeHash: "0x" + String(repeating: "2", count: 64),
            permittedFunctions: ["transfer(address,uint256)"],
            permittedSelectors: ["0xa9059cbb"], reviewedAdapterID: WalletReviewedAdapters.erc20,
            verifiedAt: Date()
        )
        let suiteName = "WalletAssetTransferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode([entry]), forKey: "LocusWalletContractRegistryV1")
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults, publicStore: store
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let prepared = await gateway.prepareHumanFungibleTransfer(
            networkID: WalletGateway.sepoliaNetworkID, accountID: "account-1",
            assetID: assetID,
            recipient: "0x2222222222222222222222222222222222222222",
            amountBaseUnits: "42000000", maximumFeeBaseUnits: "10000000000000000"
        )
        XCTAssertTrue(prepared)
        XCTAssertEqual(signer.preparedRequests.last?.action.type, .fungibleTokenTransfer)
        XCTAssertEqual(signer.preparedContracts.last.flatMap { $0 }?.id, entry.id)
    }

    func testPersistedRegistryAdapterLabelsAreRecomputedOnLoad() throws {
        let suiteName = "WalletRegistryMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalid = WalletContractRegistryEntry(
            id: "spoofed", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: "0x1111111111111111111111111111111111111111",
            label: "Spoofed", normalizedABI: "[]", abiDigest: "sha256:test",
            runtimeCodeHash: "0xcode", permittedFunctions: ["transfer(address,uint256)"],
            permittedSelectors: ["0xa9059cbb"],
            reviewedAdapterID: WalletReviewedAdapters.erc20, verifiedAt: Date()
        )
        defaults.set(try JSONEncoder().encode([invalid]), forKey: "LocusWalletContractRegistryV1")
        let gateway = WalletGateway(
            signer: FakeWalletSigner(), environment: [:], userDefaults: defaults
        )
        XCTAssertNil(gateway.contractRegistry.first?.reviewedAdapterID)
    }

    func testPersistedLegacyRouterAdapterIsNotSilentlyBroadened() throws {
        let suiteName = "WalletRegistryLegacyRouterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let routerABI = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],"outputs":[]}]"#
        let legacy = WalletContractRegistryEntry(
            id: "uniswap.legacy", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: "0x1111111111111111111111111111111111111111",
            label: "Legacy Router", normalizedABI: routerABI,
            abiDigest: "sha256:test", runtimeCodeHash: "0xcode",
            permittedFunctions: ["execute(bytes,bytes[],uint256)"],
            permittedSelectors: ["0x3593564c"],
            reviewedAdapterID:
                WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
            verifiedAt: Date()
        )
        defaults.set(
            try JSONEncoder().encode([legacy]),
            forKey: "LocusWalletContractRegistryV1"
        )
        let gateway = WalletGateway(
            signer: FakeWalletSigner(), environment: [:], userDefaults: defaults
        )
        XCTAssertEqual(
            gateway.contractRegistry.first?.reviewedAdapterID,
            WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn
        )
    }

    func testUniversalRouterAdapterDecodesOnlyOneBoundedExactInputCommand() throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let inputToken = "1111111111111111111111111111111111111111"
        let outputToken = "2222222222222222222222222222222222222222"
        let encodedInput = [
            abiWord(String(account.dropFirst(2))), abiWord("a"), abiWord("9"),
            abiWord("a0"), abiWord("1"), abiWord("2"),
            abiWord(inputToken), abiWord(outputToken),
        ].joined()
        let now = Date(timeIntervalSince1970: 1_000)
        let action = WalletSemanticAction.contractCall(
            contractID: "uniswap.router", function: "execute(bytes,bytes[],uint256)",
            arguments: [
                WalletTypedArgument(type: "bytes", value: "0x08"),
                WalletTypedArgument(type: "bytes[]", value: "[0x\(encodedInput)]"),
                WalletTypedArgument(type: "uint256", value: "1100"),
            ]
        )
        let swap = try XCTUnwrap(WalletUniversalRouterV2Adapter.decode(
            action: action, accountAddress: account, now: now
        ))
        XCTAssertEqual(swap.amountIn, "10")
        XCTAssertEqual(swap.minimumAmountOut, "9")
        XCTAssertEqual(swap.protocolVersion, .v2)
        XCTAssertEqual(swap.recipient, account)
        XCTAssertTrue(swap.inputAssetID.hasSuffix(inputToken))
        XCTAssertTrue(swap.outputAssetID.hasSuffix(outputToken))

        let allowRevert = WalletSemanticAction.contractCall(
            contractID: "uniswap.router", function: "execute(bytes,bytes[],uint256)",
            arguments: [
                WalletTypedArgument(type: "bytes", value: "0x88"),
                action.arguments[1], action.arguments[2],
            ]
        )
        XCTAssertNil(WalletUniversalRouterV2Adapter.decode(
            action: allowRevert, accountAddress: account, now: now
        ))
        let stale = WalletSemanticAction.contractCall(
            contractID: "uniswap.router", function: "execute(bytes,bytes[],uint256)",
            arguments: [action.arguments[0], action.arguments[1],
                        WalletTypedArgument(type: "uint256", value: "999")]
        )
        XCTAssertNil(WalletUniversalRouterV2Adapter.decode(
            action: stale, accountAddress: account, now: now
        ))
    }

    func testUniversalRouterV2V3AdapterBindsCurrentExactInputShapes() throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let inputToken = "1111111111111111111111111111111111111111"
        let outputToken = "2222222222222222222222222222222222222222"
        let now = Date(timeIntervalSince1970: 1_000)
        func action(command: String, words: [String]) -> WalletSemanticAction {
            WalletSemanticAction.contractCall(
                contractID: "uniswap.router",
                function: "execute(bytes,bytes[],uint256)",
                arguments: [
                    WalletTypedArgument(type: "bytes", value: command),
                    WalletTypedArgument(
                        type: "bytes[]", value: "[0x\(words.joined())]"
                    ),
                    WalletTypedArgument(type: "uint256", value: "1100"),
                ]
            )
        }

        let v2Words = [
            abiWord(String(account.dropFirst(2))), abiWord("a"), abiWord("9"),
            abiWord("c0"), abiWord("1"), abiWord("120"), abiWord("2"),
            abiWord(inputToken), abiWord(outputToken), abiWord("1"), abiWord("1"),
        ]
        let v2 = try XCTUnwrap(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x08", words: v2Words),
            accountAddress: account, now: now
        ))
        XCTAssertEqual(v2.protocolVersion, .v2)
        XCTAssertEqual(v2.amountIn, "10")
        XCTAssertEqual(v2.minimumAmountOut, "9")
        XCTAssertTrue(v2.inputAssetID.hasSuffix(inputToken))
        XCTAssertTrue(v2.outputAssetID.hasSuffix(outputToken))

        let packedPath = inputToken + "000bb8" + outputToken
        let paddedPath = packedPath
            + String(repeating: "0", count: 128 - packedPath.count)
        let v3Words = [
            abiWord(String(account.dropFirst(2))), abiWord("a"), abiWord("9"),
            abiWord("c0"), abiWord("1"), abiWord("120"), abiWord("2b"),
            String(paddedPath.prefix(64)), String(paddedPath.dropFirst(64)),
            abiWord("1"), abiWord("1"),
        ]
        let v3 = try XCTUnwrap(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x00", words: v3Words),
            accountAddress: account, now: now
        ))
        XCTAssertEqual(v3.protocolVersion, .v3)
        XCTAssertEqual(v3.inputAssetID, v2.inputAssetID)
        XCTAssertEqual(v3.outputAssetID, v2.outputAssetID)

        XCTAssertNil(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x88", words: v2Words),
            accountAddress: account, now: now
        ))
        var substitutedOffset = v2Words
        substitutedOffset[5] = abiWord("100")
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x08", words: substitutedOffset),
            accountAddress: account, now: now
        ))
        var wrongPriceCount = v2Words
        wrongPriceCount[9] = abiWord("2")
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x08", words: wrongPriceCount),
            accountAddress: account, now: now
        ))
        var routerPaid = v3Words
        routerPaid[4] = abiWord("0")
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x00", words: routerPaid),
            accountAddress: account, now: now
        ))
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x10", words: v3Words),
            accountAddress: account, now: now
        ))

        let thirdToken = "3333333333333333333333333333333333333333"
        let cyclicV2Words = [
            abiWord(String(account.dropFirst(2))), abiWord("a"), abiWord("9"),
            abiWord("c0"), abiWord("1"), abiWord("160"), abiWord("4"),
            abiWord(inputToken), abiWord(outputToken), abiWord(thirdToken),
            abiWord(outputToken), abiWord("0"),
        ]
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.decode(
            action: action(command: "0x08", words: cyclicV2Words),
            accountAddress: account, now: now
        ))
    }

    func testSemanticUniversalRouterSwapMaterializesOnlyReviewedCall() throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let input = "eip155:1/erc20:0x1111111111111111111111111111111111111111"
        let output = "eip155:1/erc20:0x2222222222222222222222222222222222222222"
        let now = Date(timeIntervalSince1970: 1_000)
        func action(
            protocolVersion: WalletUniversalRouterSwapProtocol,
            path: [String] = [], feeTiers: [UInt32] = [],
            slippageBPS: Int = 1_000
        ) -> WalletSemanticAction {
            let resolvedPath = path.isEmpty ? [input, output] : path
            return .exactInputSwap(
                adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                contractID: "uniswap.router", inputAssetID: input,
                outputAssetID: output, amountInBaseUnits: "10",
                minimumOutputBaseUnits: "9", recipient: account,
                route: WalletExactInputSwapRoute(
                    protocolVersion: protocolVersion,
                    pathAssetIDs: resolvedPath, feeTiers: feeTiers,
                    minimumHopPriceX36: ["1"],
                    quotedOutputBaseUnits: "10", slippageBPS: slippageBPS,
                    deadlineUnixSeconds: "1100"
                )
            )
        }

        let v2Call = try XCTUnwrap(
            WalletUniversalRouterV2V3Adapter.contractAction(
                for: action(protocolVersion: .v2),
                accountAddress: account, networkID: "eip155:1", now: now
            )
        )
        XCTAssertEqual(v2Call.type, .contractCall)
        XCTAssertEqual(v2Call.function, "execute(bytes,bytes[],uint256)")
        XCTAssertEqual(v2Call.arguments.first?.value, "0x08")
        XCTAssertEqual(
            WalletUniversalRouterV2V3Adapter.decode(
                action: v2Call, accountAddress: account,
                networkID: "eip155:1", now: now
            )?.protocolVersion,
            .v2
        )

        let v3Call = try XCTUnwrap(
            WalletUniversalRouterV2V3Adapter.contractAction(
                for: action(protocolVersion: .v3, feeTiers: [3_000]),
                accountAddress: account, networkID: "eip155:1", now: now
            )
        )
        XCTAssertEqual(v3Call.arguments.first?.value, "0x00")
        XCTAssertEqual(
            WalletUniversalRouterV2V3Adapter.decode(
                action: v3Call, accountAddress: account,
                networkID: "eip155:1", now: now
            )?.protocolVersion,
            .v3
        )

        let middle = "eip155:1/erc20:0x3333333333333333333333333333333333333333"
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.contractAction(
            for: action(
                protocolVersion: .v2,
                path: [input, middle, input, output]
            ), accountAddress: account, networkID: "eip155:1", now: now
        ))
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.contractAction(
            for: action(protocolVersion: .v3, feeTiers: []),
            accountAddress: account, networkID: "eip155:1", now: now
        ))
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.contractAction(
            // At 500 bps, floor(10 * 0.95) is still 9. Zero slippage
            // requires all 10 units and must reject this supplied minimum.
            for: action(protocolVersion: .v2, slippageBPS: 0),
            accountAddress: account, networkID: "eip155:1", now: now
        ))

        let overflow = WalletSemanticAction.exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: "uniswap.router", inputAssetID: input,
            outputAssetID: output,
            amountInBaseUnits: "115792089237316195423570985008687907853269984665640564039457584007913129639936",
            minimumOutputBaseUnits: "9", recipient: account,
            route: WalletExactInputSwapRoute(
                protocolVersion: .v2, pathAssetIDs: [input, output],
                feeTiers: [], minimumHopPriceX36: [],
                quotedOutputBaseUnits: "10", slippageBPS: 1_000,
                deadlineUnixSeconds: "1100"
            )
        )
        XCTAssertNil(WalletUniversalRouterV2V3Adapter.contractAction(
            for: overflow, accountAddress: account,
            networkID: "eip155:1", now: now
        ))
    }

    private func abiWord(_ value: String) -> String {
        String(repeating: "0", count: 64 - value.count) + value.lowercased()
    }

    func testRPCRejectsMismatchedResponseIDAndAmbiguousEnvelope() async throws {
        let client = makeRPCClient { _ in
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 2, "result": "0xaa36a7",
            ])
        }
        do {
            _ = try await client.publicRead(method: "eth_blockNumber", params: [])
            XCTFail("A mismatched JSON-RPC ID must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("response ID"))
        }

        let ambiguous = makeRPCClient { _ in
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "result": "0xaa36a7",
                "error": ["code": -1, "message": "ambiguous"],
            ])
        }
        do {
            _ = try await ambiguous.publicRead(method: "eth_blockNumber", params: [])
            XCTFail("A response with both result and error must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("exactly one"))
        }
    }

    func testRPCProviderResponseMutationCorpusIsBoundedAndFailsClosed() async throws {
        let seed = try walletFuzzCorpus("providers/json-rpc-response.json")
        func bindingResponseID(
            _ response: Data,
            to request: URLRequest
        ) throws -> Data {
            guard var responseObject = try? JSONSerialization.jsonObject(
                with: response
            ) as? [String: Any],
            let requestObject = try JSONSerialization.jsonObject(
                with: walletRPCRequestBody(request)
            ) as? [String: Any],
            let requestID = requestObject["id"] else {
                return response
            }
            responseObject["id"] = requestID
            return try JSONSerialization.data(withJSONObject: responseObject)
        }
        let baseline = makeRPCClient {
            try bindingResponseID(seed, to: $0)
        }
        let baselineValue = try await baseline.publicRead(
            method: "eth_blockNumber", params: []
        )
        XCTAssertEqual(baselineValue as? String, "0xaa36a7")

        var generator = WalletFuzzGenerator()
        for iteration in 0..<128 {
            let response = generator.mutate(seed, iteration: iteration)
            XCTAssertLessThanOrEqual(response.count, 2_048)
            let client = makeRPCClient {
                try bindingResponseID(response, to: $0)
            }
            _ = try? await client.publicRead(
                method: "eth_blockNumber", params: []
            )
        }
    }

    func testEVMSwapPreparationBindsReviewedRouterCodeAndZeroNativeValue() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let router = "0x4444444444444444444444444444444444444444"
        let codeHash = "0x" + String(repeating: "b", count: 64)
        let client = makeRPCClient { request in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? Int)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any = switch method {
            case "eth_getCode": "0x6000"
            case "web3_sha3": codeHash
            case "eth_chainId": "0xaa36a7"
            case "eth_getTransactionCount": "0x1"
            case "eth_getBlockByNumber": ["baseFeePerGas": "0x64"]
            case "eth_maxPriorityFeePerGas": "0x1"
            case "eth_call": "0x"
            case "eth_estimateGas": "0x5208"
            default: throw WalletRPCError.invalidResponse("unexpected \(method)")
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }
        let routerABI = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],"outputs":[]}]"#
        let entry = WalletContractRegistryEntry(
            id: "uniswap.router", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: router, label: "Reviewed Router",
            normalizedABI: routerABI,
            abiDigest: "sha256:" + SHA256.hash(data: Data(routerABI.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            runtimeCodeHash: codeHash,
            permittedFunctions: ["execute(bytes,bytes[],uint256)"],
            permittedSelectors: ["0x3593564c"],
            reviewedAdapterID:
                WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            verifiedAt: Date()
        )
        let input = "eip155:11155111/erc20:0x1111111111111111111111111111111111111111"
        let output = "eip155:11155111/erc20:0x2222222222222222222222222222222222222222"
        let action = WalletSemanticAction.exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: entry.id, inputAssetID: input,
            outputAssetID: output, amountInBaseUnits: "1000",
            minimumOutputBaseUnits: "975", recipient: account,
            route: WalletExactInputSwapRoute(
                protocolVersion: .v3, pathAssetIDs: [input, output],
                feeTiers: [3_000], minimumHopPriceX36: ["1"],
                quotedOutputBaseUnits: "1000", slippageBPS: 250,
                deadlineUnixSeconds: String(
                    UInt64(Date().timeIntervalSince1970) + 600
                )
            )
        )
        let request = WalletPrepareRequest(
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: "account-1", source: .human, action: action,
            maximumFeeBaseUnits: "10000000"
        )
        let encoded = WalletEncodedContractCall(
            input: "0x3593564c" + String(repeating: "0", count: 64)
        )
        let packet = try await client.prepare(
            request: request, fromAddress: account,
            contract: entry, encodedContract: encoded
        )
        XCTAssertEqual(packet.transaction.to, router)
        XCTAssertEqual(packet.transaction.value, "0")
        XCTAssertEqual(packet.transaction.input, encoded.input)
        XCTAssertEqual(packet.observedRuntimeCodeHash, codeHash)
        XCTAssertTrue(packet.simulationSucceeded)
    }

    func testRPCAssetBalancesUseOnlyReviewedStandardSelectors() async throws {
        let contract = "0x1111111111111111111111111111111111111111"
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let addressWord = String(repeating: "0", count: 24) + String(account.dropFirst(2))
        var observedData: [String] = []
        let client = makeRPCClient { request in
            let body = try walletRPCRequestBody(request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? Int)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: String
            if method == "eth_chainId" {
                result = "0xaa36a7"
            } else {
                let params = try XCTUnwrap(object["params"] as? [Any])
                let call = try XCTUnwrap(params.first as? [String: Any])
                let data = try XCTUnwrap(call["data"] as? String)
                observedData.append(data)
                result = data.hasPrefix("0x6352211e")
                    ? "0x" + addressWord
                    : "0x2a"
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }

        let erc20 = try XCTUnwrap(WalletEVMAssetIdentity.parse(
            "eip155:11155111/erc20:\(contract)"
        ))
        let erc20Balance = try await client.assetBalance(identity: erc20, address: account)
        XCTAssertEqual(erc20Balance, "42")
        XCTAssertEqual(observedData.last, "0x70a08231" + addressWord)

        let erc721 = try XCTUnwrap(WalletEVMAssetIdentity.parse(
            "eip155:11155111/erc721:\(contract)/7"
        ))
        let erc721Balance = try await client.assetBalance(identity: erc721, address: account)
        XCTAssertEqual(erc721Balance, "1")
        XCTAssertEqual(
            observedData.last,
            "0x6352211e" + String(repeating: "0", count: 63) + "7"
        )

        let erc1155 = try XCTUnwrap(WalletEVMAssetIdentity.parse(
            "eip155:11155111/erc1155:\(contract)/9"
        ))
        let erc1155Balance = try await client.assetBalance(identity: erc1155, address: account)
        XCTAssertEqual(erc1155Balance, "42")
        XCTAssertEqual(
            observedData.last,
            "0x00fdd58e" + addressWord + String(repeating: "0", count: 63) + "9"
        )
        XCTAssertTrue(observedData.allSatisfy {
            ["0x70a08231", "0x6352211e", "0x00fdd58e"].contains(String($0.prefix(10)))
        })
    }

    func testAlchemyERC20DiscoveryUsesCanonicalPaginatedBaseUnits() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let first = "0x1111111111111111111111111111111111111111"
        let second = "0x2222222222222222222222222222222222222222"
        let zero = "0x3333333333333333333333333333333333333333"
        var page = 0
        let client = makeRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? Int)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            if method == "eth_chainId" {
                result = "0xaa36a7"
            } else {
                XCTAssertEqual(method, "alchemy_getTokenBalances")
                let params = try XCTUnwrap(object["params"] as? [Any])
                XCTAssertEqual(params[0] as? String, account)
                XCTAssertEqual(params[1] as? String, "erc20")
                let options = try XCTUnwrap(params[2] as? [String: Any])
                XCTAssertEqual(options["maxCount"] as? Int, 100)
                page += 1
                if page == 1 {
                    XCTAssertNil(options["pageKey"])
                    result = [
                        "address": "0x" + account.dropFirst(2).uppercased(),
                        "tokenBalances": [[
                            "contractAddress": "0x" + second.dropFirst(2).uppercased(),
                            "tokenBalance": "0x2a", "error": NSNull(),
                        ], [
                            "contractAddress": zero,
                            "tokenBalance": "0x0", "error": NSNull(),
                        ]],
                        "pageKey": "page-2",
                    ]
                } else {
                    XCTAssertEqual(options["pageKey"] as? String, "page-2")
                    result = [
                        "address": account,
                        "tokenBalances": [[
                            "contractAddress": first,
                            "tokenBalance": "0xffffffffffffffffffffffffffffffff",
                            "error": NSNull(),
                        ]],
                        "pageKey": NSNull(),
                    ]
                }
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }
        let assets = try await client.tokenBalances(
            provider: .alchemy, address: account
        )
        XCTAssertEqual(page, 2)
        XCTAssertEqual(assets.map(\.identity.contractAddress), [first, second])
        XCTAssertEqual(
            assets.map(\.balanceBaseUnits),
            ["340282366920938463463374607431768211455", "42"]
        )
    }

    func testAlchemyERC20DiscoveryRejectsDuplicateOrErroredEvidence() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let contract = "0x1111111111111111111111111111111111111111"
        let client = makeRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? Int)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any = method == "eth_chainId" ? "0xaa36a7" : [
                "address": account,
                "tokenBalances": [
                    ["contractAddress": contract, "tokenBalance": "0x1"],
                    ["contractAddress": contract, "tokenBalance": "0x2"],
                ],
                "pageKey": NSNull(),
            ]
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }
        do {
            _ = try await client.tokenBalances(provider: .alchemy, address: account)
            XCTFail("Duplicate ERC-20 contracts must fail the asset snapshot.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("token evidence"))
        }
    }

    func testAlchemyNFTDiscoveryUsesMetadataFreeStableSnapshot() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let erc721 = "0x1111111111111111111111111111111111111111"
        let erc1155 = "0x2222222222222222222222222222222222222222"
        let blockHash = "0x" + String(repeating: "a", count: 64)
        var nftPage = 0
        let client = try makeAlchemyEVMRPCClient { request in
            if request.httpMethod == "POST" {
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: walletRPCRequestBody(request)
                    ) as? [String: Any]
                )
                return try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": object["id"]!, "result": "0xaa36a7",
                ])
            }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.url?.path,
                "/nft/v3/test_key-123/getNFTsForOwner"
            )
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(
                components.queryItems
            ).map { ($0.name, $0.value) })
            XCTAssertEqual(query["owner"]!, account)
            XCTAssertEqual(query["withMetadata"]!, "false")
            XCTAssertEqual(query["pageSize"]!, "100")
            nftPage += 1
            let item: [String: Any]
            let next: Any
            if nftPage == 1 {
                XCTAssertNil(query["pageKey"] ?? nil)
                item = [
                    "contract": [
                        "address": erc1155, "tokenType": "ERC1155",
                        "name": "Ignored contract metadata",
                    ],
                    "tokenId": "9", "tokenType": "ERC1155", "balance": "42",
                    "name": "Ignored NFT metadata",
                    "image": ["originalUrl": "https://malicious.invalid/active.svg"],
                ]
                next = "next-page"
            } else {
                XCTAssertEqual(query["pageKey"]!, "next-page")
                item = [
                    "contract": ["address": erc721, "tokenType": "ERC721"],
                    "tokenId": "7", "tokenType": "ERC721", "balance": "1",
                ]
                next = NSNull()
            }
            return try JSONSerialization.data(withJSONObject: [
                "ownedNfts": [item], "totalCount": 2,
                "validAt": ["blockNumber": 123_456, "blockHash": blockHash],
                "pageKey": next,
            ])
        }
        let snapshot = try await client.nftBalances(
            provider: .alchemy, address: account
        )
        XCTAssertEqual(nftPage, 2)
        XCTAssertEqual(snapshot.blockNumber, 123_456)
        XCTAssertEqual(snapshot.blockHash, blockHash)
        XCTAssertEqual(snapshot.assets.map(\.id), [
            "eip155:11155111/erc1155:\(erc1155)/9",
            "eip155:11155111/erc721:\(erc721)/7",
        ])
        XCTAssertEqual(snapshot.assets.map(\.balanceBaseUnits), ["42", "1"])
    }

    func testAlchemyNFTDiscoveryRejectsSnapshotAndOwnershipSubstitution() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let contract = "0x1111111111111111111111111111111111111111"
        let firstHash = "0x" + String(repeating: "a", count: 64)
        let secondHash = "0x" + String(repeating: "b", count: 64)
        var page = 0
        let client = try makeAlchemyEVMRPCClient { request in
            if request.httpMethod == "POST" {
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: walletRPCRequestBody(request)
                    ) as? [String: Any]
                )
                return try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": object["id"]!, "result": "0xaa36a7",
                ])
            }
            page += 1
            return try JSONSerialization.data(withJSONObject: [
                "ownedNfts": [[
                    "contract": ["address": contract, "tokenType": "ERC721"],
                    "tokenId": String(page), "tokenType": "ERC721", "balance": "1",
                ]],
                "totalCount": 2,
                "validAt": [
                    "blockNumber": page == 1 ? 123_456 : 123_457,
                    "blockHash": page == 1 ? firstHash : secondHash,
                ],
                "pageKey": page == 1 ? "next-page" : NSNull(),
            ])
        }
        do {
            _ = try await client.nftBalances(provider: .alchemy, address: account)
            XCTFail("NFT pagination must stay on one provider snapshot.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("changed"))
        }
    }

    func testAlchemyIndexedActivityNormalizesRawBaseUnitsWithoutFloatingPoint() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let contract = "0x1111111111111111111111111111111111111111"
        let hash = "0x" + String(repeating: "b", count: 64)
        let client = makeRPCClient { request in
            let body = try walletRPCRequestBody(request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? Int)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            if method == "eth_chainId" {
                result = "0xaa36a7"
            } else {
                let params = try XCTUnwrap(object["params"] as? [[String: Any]])
                let inbound = params[0]["toAddress"] != nil
                result = [
                    "transfers": inbound ? [[
                        "blockNum": "0x2a", "uniqueId": "\(hash):log:1",
                        "hash": hash, "from": contract, "to": account,
                        "asset": "TOK", "category": "erc20",
                        "rawContract": [
                            "value": "0x2a", "address": contract, "decimal": "0x6",
                        ],
                        "metadata": ["blockTimestamp": "2026-08-31T08:00:00Z"],
                    ]] : [],
                ]
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }
        let transfers = try await client.indexedTransfers(
            provider: .alchemy, address: account
        )
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(transfers[0].amountBaseUnits, "42")
        XCTAssertEqual(transfers[0].blockNumber, "42")
        XCTAssertEqual(
            transfers[0].assetID,
            "eip155:11155111/erc20:\(contract)"
        )
        XCTAssertEqual(transfers[0].assetDecimals, 6)
    }

    func testQuickNodeFallbackIndexesNativeHistoryWithoutGuessingContractStandards() async throws {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let recipient = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let hash = "0x" + String(repeating: "d", count: 64)
        let client = makeRPCClient { request in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? Int)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any = method == "eth_chainId" ? "0xaa36a7" : [
                "totalPages": 1,
                "paginatedItems": [
                    [
                        "transactionHash": hash, "blockNumber": "42",
                        "blockTimestamp": "1788153600", "fromAddress": account,
                        "toAddress": recipient, "value": "1000",
                    ],
                    [
                        "transactionHash": "0x" + String(repeating: "e", count: 64),
                        "blockNumber": "43", "blockTimestamp": "1788153601",
                        "fromAddress": account, "toAddress": recipient, "value": "1",
                        "contractAddress": "0x1111111111111111111111111111111111111111",
                    ],
                ],
            ]
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }
        let transfers = try await client.indexedTransfers(
            provider: .quickNode, address: account
        )
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(transfers[0].transactionHash, hash)
        XCTAssertEqual(transfers[0].assetKind, .native)
        XCTAssertEqual(transfers[0].amountBaseUnits, "1000")
    }

    func testIndexedInboundActivityIsPersistedAndUnknownAssetIsQuarantined() async throws {
        let signer = FakeWalletSigner()
        signer.accountAddress = "0xabc0000000000000000000000000000000000000"
        signer.indexedHeadBlock = "106"
        let hash = "0x" + String(repeating: "c", count: 64)
        let contract = "0x1111111111111111111111111111111111111111"
        signer.indexedActivityRows = [[
            "id": "\(hash):log:1", "transaction_hash": hash,
            "block_number": "42", "occurred_at": 1_788_153_600.0,
            "from": contract, "to": "0xabc0000000000000000000000000000000000000",
            "asset_id": "eip155:11155111/erc20:\(contract)",
            "amount_base_units": "42", "asset_kind": "fungible_token",
            "asset_reference": contract, "asset_name": "Unknown Token<script>",
            "asset_symbol": "TOK", "asset_decimals": 6,
        ]]
        let store = try WalletPublicStore(path: ":memory:")
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: store
        )
        await gateway.refreshStatus()
        await gateway.refreshTransactionHistory()
        XCTAssertEqual(gateway.transactionHistory.count, 1)
        XCTAssertEqual(gateway.transactionHistory[0].direction, .inbound)
        XCTAssertEqual(gateway.transactionHistory[0].amountBaseUnits, "42")
        XCTAssertEqual(gateway.transactionHistory[0].finality, .finalized)
        XCTAssertEqual(gateway.assets.first?.trust, .quarantined)
        XCTAssertFalse(try XCTUnwrap(store.loadAssets().first).isVisibleByDefault)
    }

    func testGatewayQuarantinesDiscoveredERC20UntilExplicitTrust() async throws {
        let signer = FakeWalletSigner()
        signer.accountAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let contract = "0x1111111111111111111111111111111111111111"
        let assetID = "eip155:11155111/erc20:\(contract)"
        signer.discoveredAssetRows = [[
            "asset_id": assetID,
            "asset_kind": WalletAssetKind.fungibleToken.rawValue,
            "reference": contract,
            "balance_base_units": "340282366920938463463374607431768211455",
        ]]
        let store = try WalletPublicStore(path: ":memory:")
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: store
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let quarantined = try XCTUnwrap(gateway.assets.first { $0.id == assetID })
        XCTAssertEqual(quarantined.name, "Unknown ERC-20 token")
        XCTAssertEqual(quarantined.trust, .quarantined)
        XCTAssertNil(quarantined.decimals)
        XCTAssertFalse(gateway.accountSnapshots.contains { $0.assetID == assetID })

        gateway.trustQuarantinedAsset(id: assetID)
        await gateway.refreshAccountSnapshots()
        let snapshot = try XCTUnwrap(gateway.accountSnapshots.first {
            $0.assetID == assetID
        })
        XCTAssertEqual(
            snapshot.balanceBaseUnits,
            "340282366920938463463374607431768211455"
        )
        XCTAssertEqual(snapshot.freshness, .current)
        XCTAssertTrue(try XCTUnwrap(
            store.loadAssets().first { $0.id == assetID }
        ).isVisibleByDefault)
    }

    func testGatewayQuarantinesMetadataFreeEthereumCollectibleSnapshot() async throws {
        let signer = FakeWalletSigner()
        signer.accountAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let contract = "0x2222222222222222222222222222222222222222"
        let assetID = "eip155:11155111/erc1155:\(contract)/9"
        signer.discoveredAssetRows = [[
            "asset_id": assetID,
            "asset_kind": WalletAssetKind.collectible.rawValue,
            "reference": contract, "standard": "erc1155", "token_id": "9",
            "balance_base_units": "42",
            "snapshot_block_number": "123456",
            "snapshot_block_hash": "0x" + String(repeating: "a", count: 64),
        ]]
        let store = try WalletPublicStore(path: ":memory:")
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: store
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let asset = try XCTUnwrap(gateway.assets.first { $0.id == assetID })
        XCTAssertEqual(asset.name, "Unknown Ethereum collectible")
        XCTAssertEqual(asset.symbol, "ERC1155 #9")
        XCTAssertEqual(asset.kind, .collectible)
        XCTAssertEqual(asset.trust, .quarantined)
        XCTAssertEqual(asset.decimals, 0)
        XCTAssertFalse(gateway.accountSnapshots.contains { $0.assetID == assetID })

        gateway.trustQuarantinedAsset(id: assetID)
        await gateway.refreshAccountSnapshots()
        let snapshot = try XCTUnwrap(gateway.accountSnapshots.first {
            $0.assetID == assetID
        })
        XCTAssertEqual(snapshot.balanceBaseUnits, "42")
        XCTAssertEqual(snapshot.freshness, .current)
        XCTAssertTrue(try XCTUnwrap(
            store.loadAssets().first { $0.id == assetID }
        ).isVisibleByDefault)
    }

    func testRPCRejectsOversizedResponseBeforeParsing() async throws {
        let client = makeRPCClient { _ in Data(repeating: 0x20, count: 1_048_577) }
        do {
            _ = try await client.publicRead(method: "eth_blockNumber", params: [])
            XCTFail("An oversized wallet RPC response must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("1 MiB"))
        }
    }

    func testRPCPreservesJSONNullResultForReceiptReconciliation() async throws {
        var responseID = 0
        let client = makeRPCClient { _ in
            responseID += 1
            let result: Any = responseID == 1 ? "0xaa36a7" : NSNull()
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": responseID, "result": result,
            ])
        }
        let value = try await client.publicRead(
            method: "eth_getTransactionReceipt", params: ["0xtx"]
        )
        XCTAssertTrue(value is NSNull)
    }

    func testSuiChainIdentityMatchesOnlyCanonicalFullAndLegacyForms() {
        XCTAssertEqual(
            WalletSuiChainIdentity.shortHex(WalletSuiChainIdentity.mainnetBase58),
            "35834a8a"
        )
        XCTAssertEqual(
            WalletSuiChainIdentity.shortHex(WalletSuiChainIdentity.testnetBase58),
            "4c78adac"
        )
        XCTAssertTrue(WalletSuiChainIdentity.matches(
            expected: WalletSuiChainIdentity.mainnetBase58, reported: "35834a8a"
        ))
        XCTAssertTrue(WalletSuiChainIdentity.matches(
            expected: "4c78adac", reported: WalletSuiChainIdentity.testnetBase58
        ))
        XCTAssertFalse(WalletSuiChainIdentity.matches(
            expected: WalletSuiChainIdentity.mainnetBase58,
            reported: WalletSuiChainIdentity.testnetBase58
        ))
        XCTAssertFalse(WalletSuiChainIdentity.matches(
            expected: WalletSuiChainIdentity.mainnetBase58, reported: "35834A8A"
        ))
        XCTAssertEqual(
            WalletNetworkCatalog.suiMainnet.identity.value,
            WalletSuiChainIdentity.mainnetBase58
        )
        XCTAssertEqual(
            WalletSuiAssetIdentity.parse(
                "sui:mainnet/coin:0x1234::example::COIN"
            )?.coinType,
            "0x1234::example::COIN"
        )
        XCTAssertNil(WalletSuiAssetIdentity.parse(
            "sui:mainnet/coin:0x01234::example::COIN"
        ))
        XCTAssertNil(WalletSuiAssetIdentity.parse(
            "sui:mainnet/coin:0x1234::example::Coin<0x2::sui::SUI>"
        ))
    }

    func testSuiGraphQLBindsChainCheckpointAndBothBalanceStores() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let address = "0x" + String(repeating: "1", count: 64)
        let client = makeSuiGraphQLClient(now: now) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let object = try JSONSerialization.jsonObject(
                with: walletRPCRequestBody(request)
            ) as? [String: Any]
            XCTAssertNil(object?["jsonrpc"])
            let query = object?["query"] as? String
            XCTAssertTrue(query?.contains("chainIdentifier") == true)
            XCTAssertTrue(query?.contains("addressBalance") == true)
            let variables = object?["variables"] as? [String: Any]
            XCTAssertEqual(variables?["address"] as? String, address)
            XCTAssertEqual(variables?["coinType"] as? String, "0x2::sui::SUI")
            return try self.suiOverviewResponse(address: address)
        }
        let overview = try await client.accountOverview(address: address)
        XCTAssertEqual(overview.totalBalance, "1007")
        XCTAssertEqual(overview.coinBalance, "1000")
        XCTAssertEqual(overview.addressBalance, "7")
        XCTAssertEqual(overview.network.checkpointSequence, 123_456)
        XCTAssertEqual(overview.network.epoch, 900)
        XCTAssertEqual(overview.network.referenceGasPrice, "1000")
        let refreshedBalance = try await client.balance(address: address)
        XCTAssertEqual(refreshedBalance, "1007")
    }

    func testSuiGraphQLNormalizesPinnedOfficialMoveTypeRepresentationsOnlyAtWireBoundary() {
        // Exact repr examples from Sui 1.79.0 commit 46f18562f1f5af2438d35828e8b62d5e0b972db7:
        // crates/sui-indexer-alt-e2e-tests/tests/graphql/addressable/coins.snap.
        let native = "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
        let coin = "0x0000000000000000000000000000000000000000000000000000000000000002::coin::Coin<0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI>"
        let empty = "0x0000000000000000000000000000000000000000000000000000000000000042::empty::COIN"
        XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType(native), "0x2::sui::SUI")
        XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType(coin), "0x2::coin::Coin<0x2::sui::SUI>")
        XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType(empty), "0x42::empty::COIN")
        XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType("0x2::sui::SUI"), "0x2::sui::SUI")
        XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType("0x0::example::Object"), "0x0::example::Object")
        XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType(
            "0x2::example::Object<vector<\(empty)>,u64>"
        ), "0x2::example::Object<vector<0x42::empty::COIN>,u64>")
        XCTAssertFalse(WalletSuiAssetIdentity.isCanonicalCoinType(native))
        XCTAssertNil(WalletSuiAssetIdentity.parse("sui:testnet/coin:\(native)"))
        XCTAssertNil(WalletSuiAssetIdentity.parse("sui:testnet/coin:0x2::coin::Coin<0x2::sui::SUI>"))
    }

    func testSuiGraphQLWireTypeNormalizerRejectsMalformedAndExcessiveGrammar() {
        let invalid = [
            "", "u64", "vector<u8>", "0x02::sui::SUI", "0X2::sui::SUI", "0xA::sui::SUI",
            "0x::sui::SUI", "0x2::sui", "0x2::::SUI", "0x2::2sui::SUI", "0x2::sui::SUI::Extra",
            "0x2::sui::SUI ", "0x2::sui::SUI\n", "0x2::sui::SUİ", "0x2::sui::SUI/extra",
            "0x2::coin::Coin<>", "0x2::coin::Coin<u64,>", "0x2::coin::Coin<,u64>",
            "0x2::coin::Coin<u64", "0x2::coin::Coin<u64>>", "0x2::coin::Coin<unknown>",
            "0x2::coin::Coin<vector<u8,u64>>", "0x2::coin::Coin<0x02::sui::SUI>",
            "0x" + String(repeating: "1", count: 65) + "::sui::SUI",
            "0x2::example::Object<" + String(repeating: "vector<", count: 16) + "u8" + String(repeating: ">", count: 17),
            "0x2::example::Object<" + Array(repeating: "u8", count: 17).joined(separator: ",") + ">",
            "0x2::example::" + String(repeating: "A", count: 512),
        ]
        for value in invalid {
            XCTAssertNil(WalletSuiGraphQLClient.normalizedWireMoveType(value), "Malformed type must not normalize")
        }
        XCTAssertNil(WalletSuiGraphQLClient.normalizedWireMoveType(NSNull()))
        XCTAssertNil(WalletSuiGraphQLClient.normalizedWireMoveType(2))
    }

    func testSuiGraphQLWireNormalizationPreservesNumericAddressModuleAndTypeIdentity() {
        let address = "0x" + String(repeating: "0", count: 63) + "2"
        for (wire, expected) in [
            ("0x" + String(repeating: "0", count: 63) + "3::sui::SUI", "0x3::sui::SUI"),
            ("\(address)::Sui::SUI", "0x2::Sui::SUI"),
            ("\(address)::sui::Sui", "0x2::sui::Sui"),
            ("\(address)::coin::Coin<0x3::sui::SUI>", "0x2::coin::Coin<0x3::sui::SUI>"),
        ] {
            XCTAssertEqual(WalletSuiGraphQLClient.normalizedWireMoveType(wire), expected)
            XCTAssertNotEqual(WalletSuiGraphQLClient.normalizedWireMoveType(wire), "0x2::sui::SUI")
        }
    }

    func testSuiGraphQLRejectsShortAndPaddedDuplicateBalanceIdentities() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:05:00Z"))
        let owner = "0x" + String(repeating: "1", count: 64)
        let padded = "0x" + String(repeating: "0", count: 63) + "2::sui::SUI"
        let client = makeSuiGraphQLClient(now: now, paddedWireTypes: false) { _ in
            try self.suiBalancesResponse(address: owner, balances: [
                ("0x2::sui::SUI", "1", "1", "0"), (padded, "2", "2", "0"),
            ], hasNextPage: false, endCursor: nil)
        }
        do {
            _ = try await client.balances(owner: owner)
            XCTFail("Wire aliases must remain one identity and duplicate evidence must fail")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("duplicate"))
        }
    }

    func testSuiGraphQLPaddedGasEvidenceRejectsPackageModuleAndTypeSubstitution() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:05:00Z"))
        let owner = "0x" + String(repeating: "1", count: 64)
        let objectID = "0x" + String(repeating: "2", count: 64)
        for wrongType in ["0x3::sui::SUI", "0x2::Sui::SUI", "0x2::sui::Sui"] {
            let client = makeSuiGraphQLClient(now: now) { _ in
                try self.suiGasCoinsResponse(owner: owner, total: "100", coinsBalance: "100", accumulator: "0",
                    coins: [self.suiGasCoinJSON(objectID: objectID, owner: owner, version: 1,
                                               digestByte: 13, balance: 100, coinType: wrongType)],
                    hasNextPage: false, endCursor: nil)
            }
            do {
                _ = try await client.selectNativeGasCoin(owner: owner, requiredBalanceBaseUnits: "1")
                XCTFail("Padded package/module/type substitution must fail exact gas-coin identity")
            } catch WalletRPCError.invalidResponse(let message) {
                XCTAssertTrue(message.contains("malformed"))
            }
        }
    }

    func testSuiGraphQLRejectsWrongChainAndInconsistentBalance() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let address = "0x" + String(repeating: "2", count: 64)
        let wrongChain = makeSuiGraphQLClient(now: now) { _ in
            try self.suiOverviewResponse(
                chainIdentifier: WalletSuiChainIdentity.mainnetBase58,
                address: address
            )
        }
        do {
            _ = try await wrongChain.accountOverview(address: address)
            XCTFail("A Sui provider on another genesis must fail closed.")
        } catch WalletRPCError.wrongChain(let reported) {
            XCTAssertEqual(reported, WalletSuiChainIdentity.mainnetBase58)
        }

        let inconsistent = makeSuiGraphQLClient(now: now) { _ in
            try self.suiOverviewResponse(
                address: address, total: "1008", coins: "1000", accumulator: "7"
            )
        }
        do {
            _ = try await inconsistent.accountOverview(address: address)
            XCTFail("Sui coin-object and accumulator totals must reconcile exactly.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("balance evidence"))
        }
    }

    func testSuiGraphQLRejectsErrorsStaleEvidenceAndOversizedResponses() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:30:00Z"
        ))
        let address = "0x" + String(repeating: "3", count: 64)
        let graphQLError = makeSuiGraphQLClient(now: now) { _ in
            try JSONSerialization.data(withJSONObject: [
                "data": ["chainIdentifier": WalletSuiChainIdentity.testnetBase58],
                "errors": [["message": "denied\nby provider"]],
            ])
        }
        do {
            _ = try await graphQLError.accountOverview(address: address)
            XCTFail("GraphQL partial data with errors must not be trusted.")
        } catch WalletRPCError.rpc(_, let message) {
            XCTAssertEqual(message, "deniedby provider")
        }

        let stale = makeSuiGraphQLClient(now: now) { _ in
            try self.suiOverviewResponse(address: address)
        }
        do {
            _ = try await stale.accountOverview(address: address)
            XCTFail("A stale checkpoint must not drive a current balance.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("stale"))
        }

        let oversized = makeSuiGraphQLClient(now: now) { _ in
            Data(repeating: 0x20, count: 1_048_577)
        }
        do {
            _ = try await oversized.accountOverview(address: address)
            XCTFail("An oversized Sui response must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("oversized"))
        }
    }

    func testSuiGraphQLDiscoversCanonicalCoinBalancesAcrossStablePages() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let address = "0x" + String(repeating: "5", count: 64)
        let coinType = "0x1234::example::COIN"
        var requests = 0
        let client = makeSuiGraphQLClient(now: now) { request in
            requests += 1
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let variables = try XCTUnwrap(object["variables"] as? [String: Any])
            XCTAssertEqual(variables["address"] as? String, address)
            XCTAssertEqual(variables["first"] as? Int, 50)
            if requests == 1 {
                XCTAssertTrue(variables["after"] is NSNull)
                XCTAssertTrue(variables["checkpoint"] is NSNull)
                return try self.suiBalancesResponse(
                    address: address,
                    balances: [
                        (WalletSuiAssetIdentity.nativeCoinType, "10", "8", "2"),
                    ],
                    hasNextPage: true, endCursor: "page-2"
                )
            }
            XCTAssertEqual(variables["after"] as? String, "page-2")
            XCTAssertEqual(variables["checkpoint"] as? UInt64, 123_456)
            return try self.suiBalancesResponse(
                address: address,
                balances: [(coinType, "1007", "1000", "7")],
                hasNextPage: false, endCursor: nil
            )
        }
        let balances = try await client.balances(owner: address)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(Set(balances.map(\.identity.coinType)), Set([
            WalletSuiAssetIdentity.nativeCoinType, coinType,
        ]))
        XCTAssertEqual(
            balances.first(where: { $0.identity.coinType == coinType })?.totalBalance,
            "1007"
        )
    }

    func testSuiGraphQLBalanceQueryClosesItsOperationSelection() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:05:00Z"))
        let owner = "0x" + String(repeating: "5", count: 64)
        let client = makeSuiGraphQLClient(now: now) { request in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: walletRPCRequestBody(request)) as? [String: Any])
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.contains("query LocusSuiBalances("))
            // This literal contains no string values or brace-bearing argument
            // objects: its final brace must close the operation, not the address.
            var depth = 0
            var operationClosures = 0
            for character in query {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    XCTAssertGreaterThanOrEqual(depth, 0)
                    if depth == 0 { operationClosures += 1 }
                }
            }
            XCTAssertEqual(depth, 0)
            XCTAssertEqual(operationClosures, 1)
            return try self.suiBalancesResponse(address: owner, balances: [],
                hasNextPage: false, endCursor: nil)
        }
        let balances = try await client.balances(owner: owner)
        XCTAssertTrue(balances.isEmpty)
    }

    func testSuiGraphQLDiscoveryPreservesTotalBoundsAndCheckpointAcrossSmallerPages() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:05:00Z"))
        let owner = "0x" + String(repeating: "5", count: 64)
        let marker = "0x1234::example::COIN"
        // Existing total capacities: 10,000 balances and 5,000 objects/coins.
        // An endless, otherwise-valid cursor stream must fail at the exact cap.
        for (kind, totalLimit) in [(0, 10_000), (1, 5_000), (2, 5_000), (3, 5_000)] {
            var requests = 0
            let client = makeSuiGraphQLClient(now: now) { request in
                requests += 1
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)) as? [String: Any])
                let variables = try XCTUnwrap(body["variables"] as? [String: Any])
                XCTAssertEqual(variables["first"] as? Int, 50)
                XCTAssertEqual(variables["address"] as? String, owner)
                if requests == 1 {
                    XCTAssertTrue(variables["checkpoint"] is NSNull)
                    XCTAssertTrue(variables["after"] is NSNull)
                } else {
                    XCTAssertEqual(variables["checkpoint"] as? UInt64, 123_456)
                    XCTAssertEqual(variables["after"] as? String, "page-\(requests - 1)")
                }
                switch kind {
                case 0:
                    return try self.suiBalancesResponse(address: owner, balances: [],
                        hasNextPage: true, endCursor: "page-\(requests)")
                case 1:
                    return try self.suiOwnedObjectsResponse(owner: owner, objects: [],
                        hasNextPage: true, endCursor: "page-\(requests)")
                default:
                    return try self.suiGasCoinsResponse(owner: owner, total: "0",
                        coinsBalance: "0", accumulator: "0", coins: [],
                        hasNextPage: true, endCursor: "page-\(requests)",
                        coinType: kind == 2 ? WalletSuiAssetIdentity.nativeCoinType : marker)
                }
            }
            do {
                switch kind {
                case 0: _ = try await client.balances(owner: owner)
                case 1: _ = try await client.ownedObjects(owner: owner)
                case 2: _ = try await client.nativeGasCoins(owner: owner)
                default: _ = try await client.coinObjects(owner: owner, coinType: marker)
                }
                XCTFail("Unresolved discovery pagination must fail at its existing total bound.")
            } catch WalletRPCError.invalidResponse(let message) {
                XCTAssertTrue(message.contains("pagination was truncated"))
            }
            XCTAssertEqual(requests * 50, totalLimit)
        }
    }

    func testSuiGasCoinDiscoveryReconcilesAcrossAFullPinnedPageBoundary() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:05:00Z"))
        let owner = "0x" + String(repeating: "6", count: 64)
        let coins = (1...51).map { index in
            self.suiGasCoinJSON(objectID: "0x" + String(format: "%064x", index),
                owner: owner, version: 1, digestByte: UInt8(index), balance: 1)
        }
        var requests = 0
        let client = makeSuiGraphQLClient(now: now) { request in
            requests += 1
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: walletRPCRequestBody(request)) as? [String: Any])
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["first"] as? Int, 50)
            if requests == 1 {
                XCTAssertTrue(variables["checkpoint"] is NSNull)
                return try self.suiGasCoinsResponse(owner: owner, total: "51",
                    coinsBalance: "51", accumulator: "0", coins: Array(coins.prefix(50)),
                    hasNextPage: true, endCursor: "coin-51")
            }
            XCTAssertEqual(variables["checkpoint"] as? UInt64, 123_456)
            XCTAssertEqual(variables["after"] as? String, "coin-51")
            return try self.suiGasCoinsResponse(owner: owner, total: "51",
                coinsBalance: "51", accumulator: "0", coins: [coins[50]],
                hasNextPage: false, endCursor: nil)
        }
        let snapshot = try await client.nativeGasCoins(owner: owner)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(snapshot.coins.count, 51)
        XCTAssertEqual(Set(snapshot.coins.map(\.reference.objectID)).count, 51)
        XCTAssertEqual(snapshot.coinBalance, "51")
        XCTAssertEqual(snapshot.network.checkpointSequence, 123_456)
    }

    func testSuiGasCoinDiscoveryRejectsMoreThanTheRequestedPageSize() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T12:05:00Z"))
        let owner = "0x" + String(repeating: "7", count: 64)
        let coins = (1...51).map { index in
            self.suiGasCoinJSON(objectID: "0x" + String(format: "%064x", index),
                owner: owner, version: 1, digestByte: UInt8(index), balance: 1)
        }
        let client = makeSuiGraphQLClient(now: now) { request in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: walletRPCRequestBody(request)) as? [String: Any])
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["first"] as? Int, 50)
            return try self.suiGasCoinsResponse(owner: owner, total: "51",
                coinsBalance: "51", accumulator: "0", coins: coins,
                hasNextPage: false, endCursor: nil)
        }
        do {
            _ = try await client.nativeGasCoins(owner: owner)
            XCTFail("A response cannot exceed the exact requested connection bound.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertEqual(message, "Sui returned malformed gas-coin evidence")
        }
    }

    func testSuiGraphQLRejectsDuplicateAndNoncanonicalCoinTypes() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let address = "0x" + String(repeating: "6", count: 64)
        let duplicate = makeSuiGraphQLClient(now: now) { _ in
            try self.suiBalancesResponse(
                address: address,
                balances: [
                    ("0x1234::example::COIN", "1", "1", "0"),
                    ("0x1234::example::COIN", "2", "2", "0"),
                ],
                hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await duplicate.balances(owner: address)
            XCTFail("Duplicate Sui Coin types must fail the entire discovery response.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("duplicate"))
        }

        let generic = makeSuiGraphQLClient(now: now) { _ in
            try self.suiBalancesResponse(
                address: address,
                balances: [("0x2::coin::Coin<0x2::sui::SUI>", "1", "1", "0")],
                hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await generic.balances(owner: address)
            XCTFail("Unreviewed generic Move marker types must remain outside discovery.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("malformed"))
        }
    }

    func testSuiGraphQLDiscoversOnlyValidatedNonCoinOwnedObjects() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "8", count: 64)
        let objectID = "0x" + String(repeating: "9", count: 64)
        let coinID = "0x" + String(repeating: "a", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 11, count: 32))
        let client = makeSuiGraphQLClient(now: now) { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.contains("hasPublicTransfer"))
            XCTAssertFalse(query.contains("objectBcs"))
            XCTAssertFalse(query.contains("display"))
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["first"] as? Int, 50)
            return try self.suiOwnedObjectsResponse(
                owner: owner,
                objects: [
                    self.suiObjectJSON(
                        objectID: objectID, owner: owner, version: 42,
                        digest: digest, moveType: "0x1234::artifact::ARTIFACT",
                        hasPublicTransfer: true
                    ),
                    self.suiObjectJSON(
                        objectID: coinID, owner: owner, version: 43,
                        digest: WalletSolanaBase58.encode(Data(repeating: 12, count: 32)),
                        moveType: "0x2::coin::Coin<0x2::sui::SUI>",
                        hasPublicTransfer: true
                    ),
                ],
                hasNextPage: false, endCursor: nil
            )
        }
        let objects = try await client.ownedObjects(owner: owner)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].identity.objectID, objectID)
        XCTAssertEqual(objects[0].version, 42)
        XCTAssertEqual(objects[0].digest, digest)
        XCTAssertTrue(objects[0].hasPublicTransfer)
    }

    func testSuiGraphQLRejectsMisownedAndDuplicateObjects() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "b", count: 64)
        let wrongOwner = "0x" + String(repeating: "c", count: 64)
        let objectID = "0x" + String(repeating: "d", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 13, count: 32))
        let misowned = makeSuiGraphQLClient(now: now) { _ in
            try self.suiOwnedObjectsResponse(
                owner: owner,
                objects: [self.suiObjectJSON(
                    objectID: objectID, owner: wrongOwner, version: 1,
                    digest: digest, moveType: "0x1234::artifact::ARTIFACT",
                    hasPublicTransfer: false
                )],
                hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await misowned.ownedObjects(owner: owner)
            XCTFail("An object attributed to another owner must fail discovery.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("misowned"))
        }

        let duplicate = makeSuiGraphQLClient(now: now) { _ in
            let object = self.suiObjectJSON(
                objectID: objectID, owner: owner, version: 1,
                digest: digest, moveType: "0x1234::artifact::ARTIFACT",
                hasPublicTransfer: true
            )
            return try self.suiOwnedObjectsResponse(
                owner: owner, objects: [object, object],
                hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await duplicate.ownedObjects(owner: owner)
            XCTFail("Duplicate Sui object IDs must fail discovery.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("duplicate"))
        }
    }

    func testSuiGasCoinSelectionPinsCheckpointAndChoosesSmallestSufficientCoin() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "1", count: 64)
        let smallID = "0x" + String(repeating: "2", count: 64)
        let tieWinnerID = "0x" + String(repeating: "3", count: 64)
        let tieLoserID = "0x" + String(repeating: "4", count: 64)
        var requests = 0
        let client = makeSuiGraphQLClient(now: now) { request in
            requests += 1
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.contains("filter: { type: $objectType }"))
            XCTAssertTrue(query.contains("contents { type { repr } bcs }"))
            XCTAssertFalse(query.contains("json"))
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["address"] as? String, owner)
            XCTAssertEqual(variables["coinType"] as? String, "0x2::sui::SUI")
            XCTAssertEqual(variables["first"] as? Int, 50)
            XCTAssertEqual(
                variables["objectType"] as? String,
                "0x2::coin::Coin<0x2::sui::SUI>"
            )
            if requests == 1 {
                XCTAssertTrue(variables["checkpoint"] is NSNull)
                XCTAssertTrue(variables["after"] is NSNull)
                return try self.suiGasCoinsResponse(
                    owner: owner, total: "457", coinsBalance: "450", accumulator: "7",
                    coins: [self.suiGasCoinJSON(
                        objectID: tieLoserID, owner: owner, version: 12,
                        digestByte: 14, balance: 200
                    )], hasNextPage: true, endCursor: "gas-page-2"
                )
            }
            XCTAssertEqual(variables["checkpoint"] as? UInt64, 123_456)
            XCTAssertEqual(variables["after"] as? String, "gas-page-2")
            return try self.suiGasCoinsResponse(
                owner: owner, total: "457", coinsBalance: "450", accumulator: "7",
                coins: [
                    self.suiGasCoinJSON(
                        objectID: smallID, owner: owner, version: 10,
                        digestByte: 12, balance: 50
                    ),
                    self.suiGasCoinJSON(
                        objectID: tieWinnerID, owner: owner, version: 11,
                        digestByte: 13, balance: 200
                    ),
                ], hasNextPage: false, endCursor: nil
            )
        }
        let selection = try await client.selectNativeGasCoin(
            owner: owner, requiredBalanceBaseUnits: "150"
        )
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(selection.requiredBalanceBaseUnits, "150")
        XCTAssertEqual(selection.coin.reference.objectID, tieWinnerID)
        XCTAssertEqual(selection.coin.reference.version, 11)
        XCTAssertEqual(selection.coin.balanceBaseUnits, "200")
        XCTAssertEqual(selection.snapshot.network.checkpointSequence, 123_456)
        XCTAssertEqual(selection.snapshot.network.epoch, 900)
        XCTAssertEqual(selection.snapshot.network.referenceGasPrice, "1000")
        XCTAssertEqual(selection.snapshot.coinBalance, "450")
        XCTAssertEqual(selection.snapshot.addressBalance, "7")
        XCTAssertEqual(
            selection.snapshot.coins.map(\.reference.objectID),
            [smallID, tieWinnerID, tieLoserID]
        )
    }

    func testSuiGasCoinSelectionRejectsMalformedBCSAndCoinFragmentation() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "5", count: 64)
        let firstID = "0x" + String(repeating: "6", count: 64)
        let secondID = "0x" + String(repeating: "7", count: 64)

        let malformed = makeSuiGraphQLClient(now: now) { _ in
            var coin = self.suiGasCoinJSON(
                objectID: firstID, owner: owner, version: 1,
                digestByte: 15, balance: 300
            )
            var contents = try XCTUnwrap(coin["contents"] as? [String: Any])
            contents["bcs"] = Data(repeating: 0, count: 40).base64EncodedString()
            coin["contents"] = contents
            return try self.suiGasCoinsResponse(
                owner: owner, total: "300", coinsBalance: "300", accumulator: "0",
                coins: [coin], hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await malformed.nativeGasCoins(owner: owner)
            XCTFail("Coin BCS whose embedded UID differs from its object ID must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("malformed"))
        }

        let fragmented = makeSuiGraphQLClient(now: now) { _ in
            try self.suiGasCoinsResponse(
                owner: owner, total: "300", coinsBalance: "300", accumulator: "0",
                coins: [
                    self.suiGasCoinJSON(
                        objectID: firstID, owner: owner, version: 1,
                        digestByte: 16, balance: 150
                    ),
                    self.suiGasCoinJSON(
                        objectID: secondID, owner: owner, version: 2,
                        digestByte: 17, balance: 150
                    ),
                ], hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await fragmented.selectNativeGasCoin(
                owner: owner, requiredBalanceBaseUnits: "200"
            )
            XCTFail("The one-coin transfer subset must not silently merge fragmented gas coins.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("No single reviewed"))
        }

        let inconsistent = makeSuiGraphQLClient(now: now) { _ in
            try self.suiGasCoinsResponse(
                owner: owner, total: "301", coinsBalance: "301", accumulator: "0",
                coins: [self.suiGasCoinJSON(
                    objectID: firstID, owner: owner, version: 1,
                    digestByte: 18, balance: 300
                )], hasNextPage: false, endCursor: nil
            )
        }
        do {
            _ = try await inconsistent.nativeGasCoins(owner: owner)
            XCTFail("Enumerated SUI coin balances must reconcile with checkpoint totals.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("reconcile"))
        }
    }

    func testSuiCoinObjectSelectionPinsTypeCheckpointAndRawBalance() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "9", count: 64)
        let coinType = "0x1234::usdc::USDC"
        let smallID = "0x" + String(repeating: "a", count: 64)
        let selectedID = "0x" + String(repeating: "b", count: 64)
        var requests = 0
        let client = makeSuiGraphQLClient(now: now) { request in
            requests += 1
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["coinType"] as? String, coinType)
            XCTAssertEqual(variables["first"] as? Int, 50)
            XCTAssertEqual(
                variables["objectType"] as? String,
                "0x2::coin::Coin<\(coinType)>"
            )
            if requests == 1 {
                XCTAssertTrue(variables["checkpoint"] is NSNull)
                return try self.suiGasCoinsResponse(
                    owner: owner, total: "307", coinsBalance: "300",
                    accumulator: "7", coins: [self.suiGasCoinJSON(
                        objectID: smallID, owner: owner, version: 4,
                        digestByte: 51, balance: 100, coinType: coinType
                    )], hasNextPage: true, endCursor: "coin-page-2",
                    coinType: coinType
                )
            }
            XCTAssertEqual(variables["checkpoint"] as? UInt64, 123_456)
            XCTAssertEqual(variables["after"] as? String, "coin-page-2")
            return try self.suiGasCoinsResponse(
                owner: owner, total: "307", coinsBalance: "300",
                accumulator: "7", coins: [self.suiGasCoinJSON(
                    objectID: selectedID, owner: owner, version: 5,
                    digestByte: 52, balance: 200, coinType: coinType
                )], hasNextPage: false, endCursor: nil, coinType: coinType
            )
        }
        let selection = try await client.selectCoinObject(
            owner: owner, coinType: coinType,
            requiredBalanceBaseUnits: "150"
        )
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(selection.object.reference.objectID, selectedID)
        XCTAssertEqual(selection.object.reference.version, 5)
        XCTAssertEqual(selection.object.reference.type, "0x2::coin::Coin<\(coinType)>")
        XCTAssertEqual(selection.object.balanceBaseUnits, "200")
        XCTAssertEqual(selection.snapshot.identity.coinType, coinType)
        XCTAssertEqual(selection.snapshot.coinBalance, "300")
        XCTAssertEqual(selection.snapshot.addressBalance, "7")
    }

    func testSuiCoinObjectSelectionRejectsTypeSubstitutionAndFragmentation() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "c", count: 64)
        let coinType = "0x1234::usdc::USDC"
        let firstID = "0x" + String(repeating: "d", count: 64)
        let secondID = "0x" + String(repeating: "e", count: 64)
        let wrongType = makeSuiGraphQLClient(now: now) { _ in
            try self.suiGasCoinsResponse(
                owner: owner, total: "200", coinsBalance: "200",
                accumulator: "0", coins: [self.suiGasCoinJSON(
                    objectID: firstID, owner: owner, version: 1,
                    digestByte: 53, balance: 200,
                    coinType: "0x1234::fake::FAKE"
                )], hasNextPage: false, endCursor: nil, coinType: coinType
            )
        }
        do {
            _ = try await wrongType.coinObjects(owner: owner, coinType: coinType)
            XCTFail("A provider cannot substitute another Move Coin type.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("malformed"))
        }

        let fragmented = makeSuiGraphQLClient(now: now) { _ in
            try self.suiGasCoinsResponse(
                owner: owner, total: "200", coinsBalance: "200",
                accumulator: "0", coins: [
                    self.suiGasCoinJSON(
                        objectID: firstID, owner: owner, version: 1,
                        digestByte: 54, balance: 100, coinType: coinType
                    ),
                    self.suiGasCoinJSON(
                        objectID: secondID, owner: owner, version: 2,
                        digestByte: 55, balance: 100, coinType: coinType
                    ),
                ], hasNextPage: false, endCursor: nil, coinType: coinType
            )
        }
        do {
            _ = try await fragmented.selectCoinObject(
                owner: owner, coinType: coinType,
                requiredBalanceBaseUnits: "150"
            )
            XCTFail("The first Coin-transfer subset must not add merge commands.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("No single reviewed"))
        }
        do {
            _ = try await fragmented.coinObjects(
                owner: owner, coinType: WalletSuiAssetIdentity.nativeCoinType
            )
            XCTFail("Native SUI must remain on the separately reviewed gas-coin path.")
        } catch WalletGateway.Error.invalidArguments {
            // Expected.
        }
    }

    @MainActor
    func testGatewayPreparesOnlySignedManifestSuiCoinTransfer() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date().addingTimeInterval(-60)
        let identity = WalletSuiAssetIdentity(
            networkID: WalletNetworkCatalog.suiTestnet.id,
            coinType: "0x1234::example::COIN"
        )
        let asset = WalletAsset(
            canonicalID: identity.canonicalID, networkID: identity.networkID,
            chain: .sui, kind: .fungibleToken, reference: identity.coinType,
            name: "Reviewed Coin", symbol: "COIN", decimals: 6,
            trust: .curated, manifestRevision: 4
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 4, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: [WalletReviewedAdapters.suiCoinTransfer]
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey
        )
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountAddress = "0x" + String(repeating: "1", count: 64)
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.adapterID = WalletReviewedAdapters.suiCoinTransfer
        let defaults = UserDefaults(
            suiteName: "WalletGatewayTests.sui-coin.\(UUID().uuidString)"
        )!
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: try WalletPublicStore(path: ":memory:"),
            reviewRegistry: registry, buildSupportsWalletAlpha: true
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let response = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": WalletNetworkCatalog.suiTestnet.id,
                "account_id": "account-1",
                "maximum_fee_base_units": "10000000",
                "action": [
                    "type": WalletActionKind.fungibleTokenTransfer.rawValue,
                    "asset_id": identity.canonicalID,
                    "recipient": "0x" + String(repeating: "2", count: 64),
                    "amount_base_units": "100",
                ],
            ],
            source: .human
        )
        XCTAssertNil(response["error"])
        XCTAssertEqual(signer.preparedRequests.last?.action.assetID, identity.canonicalID)
        XCTAssertNil(signer.preparedContracts.last ?? nil)
    }

    @MainActor
    func testGatewayPreparesOnlySignedManifestSemanticRouterSwap() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date().addingTimeInterval(-60)
        let routerABI = #"[{"type":"function","name":"execute","stateMutability":"payable","inputs":[{"name":"commands","type":"bytes"},{"name":"inputs","type":"bytes[]"},{"name":"deadline","type":"uint256"}],"outputs":[]}]"#
        let digest = "sha256:" + SHA256.hash(data: Data(routerABI.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let entry = WalletContractRegistryEntry(
            id: "uniswap.router", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: "0x4444444444444444444444444444444444444444",
            label: "Reviewed Router", normalizedABI: routerABI,
            abiDigest: digest,
            runtimeCodeHash: "0x" + String(repeating: "a", count: 64),
            permittedFunctions: ["execute(bytes,bytes[],uint256)"],
            permittedSelectors: ["0x3593564c"],
            reviewedAdapterID:
                WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            verifiedAt: issuedAt.addingTimeInterval(-60)
        )
        let input = "eip155:11155111/erc20:0x1111111111111111111111111111111111111111"
        let output = "eip155:11155111/erc20:0x2222222222222222222222222222222222222222"
        let assets = [
            WalletAsset(
                canonicalID: input, networkID: WalletGateway.sepoliaNetworkID,
                chain: .evm, kind: .fungibleToken,
                reference: "0x1111111111111111111111111111111111111111",
                name: "Input", symbol: "IN", decimals: 18,
                trust: .curated, manifestRevision: 7
            ),
            WalletAsset(
                canonicalID: output, networkID: WalletGateway.sepoliaNetworkID,
                chain: .evm, kind: .fungibleToken,
                reference: "0x2222222222222222222222222222222222222222",
                name: "Output", symbol: "OUT", decimals: 18,
                trust: .curated, manifestRevision: 7
            ),
        ]
        let codeHash: (Character) -> String = {
            "0x" + String(repeating: String($0), count: 64)
        }
        let permit2ABI = #"[{"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"name":"token","type":"address"},{"name":"spender","type":"address"},{"name":"amount","type":"uint160"},{"name":"expiration","type":"uint48"}],"outputs":[]}]"#
        let permit2Entry = WalletContractRegistryEntry(
            id: "uniswap.permit2", networkID: WalletGateway.sepoliaNetworkID,
            checksumAddress: "0x9999999999999999999999999999999999999999",
            label: "Reviewed Permit2", normalizedABI: permit2ABI,
            abiDigest: "sha256:" + SHA256.hash(data: Data(permit2ABI.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            runtimeCodeHash: codeHash("f"),
            permittedFunctions: ["approve(address,address,uint160,uint48)"],
            permittedSelectors: ["0x87517c45"],
            reviewedAdapterID: WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
            verifiedAt: issuedAt.addingTimeInterval(-60)
        )
        let erc20ABI = #"[{"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]}]"#
        func tokenEntry(id: String, address: String, hash: Character)
            -> WalletContractRegistryEntry {
            WalletContractRegistryEntry(
                id: id, networkID: WalletGateway.sepoliaNetworkID,
                checksumAddress: address, label: id,
                normalizedABI: erc20ABI,
                abiDigest: "sha256:" + SHA256.hash(data: Data(erc20ABI.utf8))
                    .map { String(format: "%02x", $0) }.joined(),
                runtimeCodeHash: codeHash(hash),
                permittedFunctions: ["approve(address,uint256)"],
                permittedSelectors: ["0x095ea7b3"],
                reviewedAdapterID: WalletReviewedAdapters.erc20,
                verifiedAt: issuedAt.addingTimeInterval(-60)
            )
        }
        let inputEntry = tokenEntry(
            id: "token.input",
            address: "0x1111111111111111111111111111111111111111",
            hash: "7"
        )
        let outputEntry = tokenEntry(
            id: "token.output",
            address: "0x2222222222222222222222222222222222222222",
            hash: "8"
        )
        let uniswap = WalletReviewedUniswapConfiguration(
            networkID: WalletGateway.sepoliaNetworkID,
            universalRouterContractID: entry.id,
            permit2ContractID: permit2Entry.id,
            contracts: [
                .init(role: .v2Router, address: "0x5555555555555555555555555555555555555555", runtimeCodeHash: codeHash("b")),
                .init(role: .v2Factory, address: "0x6666666666666666666666666666666666666666", runtimeCodeHash: codeHash("c")),
                .init(role: .v3Factory, address: "0x7777777777777777777777777777777777777777", runtimeCodeHash: codeHash("d")),
                .init(role: .v3QuoterV2, address: "0x8888888888888888888888888888888888888888", runtimeCodeHash: codeHash("e")),
                .init(role: .universalRouter, address: entry.checksumAddress, runtimeCodeHash: entry.runtimeCodeHash),
                .init(role: .permit2, address: "0x9999999999999999999999999999999999999999", runtimeCodeHash: codeHash("f")),
            ],
            pools: [.init(
                protocolVersion: .v3,
                address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                runtimeCodeHash: codeHash("1"),
                token0AssetID: input, token1AssetID: output, feeTier: 3_000
            )],
            allowedIntermediaryAssetIDs: [], allowedFeeTiers: [3_000],
            maximumHops: 3, zeroFirstApprovalAssetIDs: []
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 7, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: assets,
            evmContracts: [entry, permit2Entry, inputEntry, outputEntry],
            explorerTemplates: [:],
            adapterIDs: [
                WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
                WalletReviewedAdapters.erc20,
            ],
            uniswapConfigurations: [uniswap]
        )
        let missingTokenReview = WalletReviewManifest(
            schemaVersion: manifest.schemaVersion, revision: manifest.revision,
            issuedAt: manifest.issuedAt, expiresAt: manifest.expiresAt,
            assets: manifest.assets,
            evmContracts: [entry, permit2Entry, inputEntry],
            explorerTemplates: manifest.explorerTemplates,
            adapterIDs: manifest.adapterIDs,
            uniswapConfigurations: manifest.uniswapConfigurations
        )
        XCTAssertThrowsError(try WalletReviewRegistry(
            signedManifest: signedReview(missingTokenReview, key: key),
            publicKey: key.publicKey
        )) { error in
            XCTAssertEqual(error as? WalletReviewManifestError, .malformed)
        }
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey
        )
        let suiteName = "WalletGatewayTests.semantic-swap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode([entry, permit2Entry, inputEntry, outputEntry]),
            forKey: "LocusWalletContractRegistryV1"
        )
        let signer = FakeWalletSigner()
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        signer.accountAddress = account
        signer.browserRPCResponses = [
            "0x" + String(repeating: "0", count: 61) + "3e8",
            "0x" + String(repeating: "0", count: 61) + "3e8"
                + String(format: "%064x", UInt64(Date().timeIntervalSince1970) + 1_200)
                + String(repeating: "0", count: 64),
        ]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: try WalletPublicStore(path: ":memory:"),
            reviewRegistry: registry, buildSupportsWalletAlpha: true
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let quoteTime = Date()
        func swapAction(expiresAt: Date) -> [String: Any] {
            [
                "type": WalletActionKind.exactInputSwap.rawValue,
                "contract_id": entry.id,
                "adapter_id": WalletReviewedAdapters
                    .uniswapUniversalRouterV2V3ExactIn,
                "input_asset_id": input, "output_asset_id": output,
                "amount_base_units": "1000",
                "minimum_output_base_units": "975",
                "recipient": account,
                "route": [
                    "protocol_version": "v3",
                    "path_asset_ids": [input, output],
                    "fee_tiers": ["3000"],
                    "minimum_hop_price_x36": [
                        "975000000000000000000000000000000000",
                    ],
                    "quoted_output_base_units": "1000",
                    "slippage_bps": "250",
                    "deadline_unix_seconds": String(
                        UInt64(quoteTime.timeIntervalSince1970) + 600
                    ),
                    "quote_evidence": [
                        "block_number": "100",
                        "block_hash": "0x" + String(repeating: "2", count: 64),
                        "quote_contract_address": "0x8888888888888888888888888888888888888888",
                        "quote_contract_runtime_code_hash": codeHash("e"),
                        "per_hop_output_base_units": ["1000"],
                        "gas_estimate": "100000",
                        "quoted_at": quoteTime,
                        "expires_at": expiresAt,
                        "agreeing_provider_count": "1",
                    ],
                ],
            ]
        }
        let response = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": WalletGateway.sepoliaNetworkID,
                "account_id": "account-1",
                "maximum_fee_base_units": "50000",
                "action": swapAction(
                    expiresAt: quoteTime.addingTimeInterval(60)
                ),
            ],
            source: .human
        )
        XCTAssertNil(response["error"])
        XCTAssertEqual(signer.preparedRequests.last?.action.type, .exactInputSwap)
        XCTAssertEqual(
            signer.preparedRequests.last?.action.swapRoute?.feeTiers, [3_000]
        )
        XCTAssertEqual(signer.preparedContracts.last.flatMap { $0 }, entry)

        let rejected = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": WalletGateway.sepoliaNetworkID,
                "account_id": "account-1", "maximum_fee_base_units": "50000",
                "action": [
                    "type": WalletActionKind.exactInputSwap.rawValue,
                    "contract_id": entry.id,
                    "adapter_id": WalletReviewedAdapters
                        .uniswapUniversalRouterV2ExactIn,
                ],
            ], source: .human
        )
        XCTAssertNotNil(rejected["error"])
        XCTAssertEqual(signer.preparedRequests.count, 1)

        let staleQuote = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": WalletGateway.sepoliaNetworkID,
                "account_id": "account-1", "maximum_fee_base_units": "50000",
                "action": swapAction(
                    expiresAt: quoteTime.addingTimeInterval(-1)
                ),
            ], source: .human
        )
        XCTAssertNotNil(staleQuote["error"])
        XCTAssertEqual(signer.preparedRequests.count, 1)
    }

    @MainActor
    func testGatewayPreparesOnlySignedManifestSuiObjectTransfer() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date().addingTimeInterval(-60)
        let objectID = "0x" + String(repeating: "3", count: 64)
        let identity = WalletSuiObjectIdentity(
            networkID: WalletNetworkCatalog.suiTestnet.id,
            objectID: objectID
        )
        let asset = WalletAsset(
            canonicalID: identity.canonicalID, networkID: identity.networkID,
            chain: .sui, kind: .collectible, reference: identity.objectID,
            name: "Reviewed Object", symbol: "OBJECT", decimals: nil,
            trust: .curated, manifestRevision: 5
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 5, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: [WalletReviewedAdapters.suiObjectTransfer]
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey
        )
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountAddress = "0x" + String(repeating: "1", count: 64)
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.adapterID = WalletReviewedAdapters.suiObjectTransfer
        let defaults = UserDefaults(
            suiteName: "WalletGatewayTests.sui-object.\(UUID().uuidString)"
        )!
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: try WalletPublicStore(path: ":memory:"),
            reviewRegistry: registry, buildSupportsWalletAlpha: true
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let response = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": WalletNetworkCatalog.suiTestnet.id,
                "account_id": "account-1",
                "maximum_fee_base_units": "10000000",
                "action": [
                    "type": WalletActionKind.nftTransfer.rawValue,
                    "asset_id": identity.canonicalID,
                    "token_id": identity.objectID,
                    "recipient": "0x" + String(repeating: "2", count: 64),
                ],
            ],
            source: .human
        )
        XCTAssertNil(response["error"])
        XCTAssertEqual(signer.preparedRequests.last?.action.type, .nftTransfer)
        XCTAssertEqual(signer.preparedRequests.last?.action.assetID, identity.canonicalID)
        XCTAssertEqual(signer.preparedRequests.last?.action.tokenID, identity.objectID)
        XCTAssertEqual(signer.preparedRequests.last?.action.amountBaseUnits, "1")
        XCTAssertNil(signer.preparedContracts.last ?? nil)
    }

    @MainActor
    func testGatewayPreparesOnlySignedManifestCoreTransfer() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let issuedAt = Date().addingTimeInterval(-60)
        let address = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 8, count: 32))
        let identity = WalletSolanaCollectibleIdentity(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            standard: .core, address: address
        )
        let asset = WalletAsset(
            canonicalID: identity.canonicalID, networkID: identity.networkID,
            chain: .solana, kind: .collectible, reference: identity.address,
            name: "Reviewed Core Asset", symbol: "CORE", decimals: nil,
            trust: .curated, manifestRevision: 6
        )
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: 6, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(24 * 60 * 60),
            assets: [asset], evmContracts: [], explorerTemplates: [:],
            adapterIDs: [WalletReviewedAdapters.solanaCoreTransfer]
        )
        let registry = try WalletReviewRegistry(
            signedManifest: signedReview(manifest, key: key),
            publicKey: key.publicKey
        )
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.adapterID = WalletReviewedAdapters.solanaCoreTransfer
        let suiteName = "WalletGatewayTests.core-object.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: try WalletPublicStore(path: ":memory:"),
            reviewRegistry: registry, buildSupportsWalletAlpha: true
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let valid = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": identity.networkID,
                "account_id": "account-1",
                "maximum_fee_base_units": "6000",
                "action": [
                    "type": WalletActionKind.nftTransfer.rawValue,
                    "asset_id": identity.canonicalID,
                    "token_id": identity.address,
                    "recipient": recipient,
                ],
            ],
            source: .human
        )
        XCTAssertNil(valid["error"])
        XCTAssertEqual(signer.preparedRequests.last?.action.assetID, identity.canonicalID)
        XCTAssertEqual(signer.preparedRequests.last?.action.amountBaseUnits, "1")
        XCTAssertNil(signer.preparedContracts.last ?? nil)

        let substituted = await gateway.perform(
            tool: "wallet_prepare_transaction",
            arguments: [
                "network_id": identity.networkID,
                "account_id": "account-1",
                "maximum_fee_base_units": "6000",
                "action": [
                    "type": WalletActionKind.nftTransfer.rawValue,
                    "asset_id": identity.canonicalID,
                    "token_id": recipient,
                    "recipient": recipient,
                ],
            ],
            source: .human
        )
        XCTAssertNotNil(substituted["error"])
        XCTAssertEqual(signer.preparedRequests.count, 1)
    }

    func testSuiNativeTransferSimulationBindsExactEffectsAndSignerBytes() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let sender = "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c"
        let recipient = "0x" + String(repeating: "07", count: 32)
        let gasObjectID = "0x" + String(repeating: "08", count: 32)
        let transactionDigest = "UWx2nPyFTrBo7AFnv46gHJthCkfERY5ash86HcnSdpC"
        let transactionBCS = "AAACAAgVzVsHAAAAAAAgBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcCAgABAQAAAQEDAAAAAAEBAPln4hwWpHV9qv7BPuecDcXFMpGZvl1wyG/Qe45124ksAQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIKgAAAAAAAAAgCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQn5Z+IcFqR1far+wT7nnA3FxTKRmb5dcMhv0HuOdduJLOgDAAAAAAAAgJaYAAAAAAABnAEAAAAAAAA="
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 44, count: 32))
        let client = makeSuiGraphQLClient(
            network: WalletNetworkCatalog.suiMainnet, now: now
        ) { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.contains("checksEnabled: true"))
            XCTAssertTrue(query.contains("doGasSelection: false"))
            XCTAssertTrue(query.contains("balanceChanges(first: 3)"))
            XCTAssertFalse(query.contains("executeTransaction"))
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            let transaction = try XCTUnwrap(variables["transaction"] as? [String: Any])
            let bcs = try XCTUnwrap(transaction["bcs"] as? [String: Any])
            XCTAssertEqual(bcs["value"] as? String, transactionBCS)
            return try self.suiNativeTransferSimulationResponse(
                sender: sender, recipient: recipient, gasObjectID: gasObjectID,
                transactionDigest: transactionDigest, effectsDigest: effectsDigest,
                senderDebit: "123458089", recipientCredit: "123456789"
            )
        }
        let result = try await client.simulateNativeTransfer(
            transactionBCS: transactionBCS,
            expectedTransactionDigest: transactionDigest,
            sender: sender, recipient: recipient,
            amountBaseUnits: "123456789", maximumFeeBaseUnits: "10000000",
            gasObjectID: gasObjectID
        )
        XCTAssertEqual(result.network.chainIdentifier, WalletSuiChainIdentity.mainnetBase58)
        XCTAssertEqual(result.transactionDigest, transactionDigest)
        XCTAssertEqual(result.effectsDigest, effectsDigest)
        XCTAssertEqual(result.senderDebitBaseUnits, "123458089")
        XCTAssertEqual(result.recipientCreditBaseUnits, "123456789")
        XCTAssertEqual(result.gas.actualFeeBaseUnits, "1300")
        XCTAssertEqual(result.gas.computationCost, "1000")
        XCTAssertEqual(result.gas.storageCost, "500")
        XCTAssertEqual(result.gas.storageRebate, "200")
        XCTAssertEqual(result.gas.nonRefundableStorageFee, "100")
    }

    func testSuiNativeTransferSimulationRejectsSubstitutedEffects() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let sender = "0x" + String(repeating: "1", count: 64)
        let recipient = "0x" + String(repeating: "2", count: 64)
        let gasObjectID = "0x" + String(repeating: "3", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 45, count: 32))
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 46, count: 32))
        let transactionBCS = Data([0, 1, 2, 3]).base64EncodedString()
        let substitutions: [(String, String, String, Bool)] = [
            ("101", "100", "SUCCESS", false),
            ("102", "101", "SUCCESS", false),
            ("102", "100", "FAILURE", false),
            ("102", "100", "SUCCESS", true),
        ]
        for (senderDebit, recipientCredit, status, hasNextPage) in substitutions {
            let client = makeSuiGraphQLClient(
                network: WalletNetworkCatalog.suiMainnet, now: now
            ) { _ in
                try self.suiNativeTransferSimulationResponse(
                    sender: sender, recipient: recipient, gasObjectID: gasObjectID,
                    transactionDigest: digest, effectsDigest: effectsDigest,
                    senderDebit: senderDebit, recipientCredit: recipientCredit,
                    computationCost: 2, storageCost: 0, storageRebate: 0,
                    nonRefundableStorageFee: 0, status: status,
                    hasNextPage: hasNextPage
                )
            }
            do {
                _ = try await client.simulateNativeTransfer(
                    transactionBCS: transactionBCS,
                    expectedTransactionDigest: digest,
                    sender: sender, recipient: recipient,
                    amountBaseUnits: "100", maximumFeeBaseUnits: "10",
                    gasObjectID: gasObjectID
                )
                XCTFail("Substituted Sui simulation effects must fail closed.")
            } catch WalletRPCError.invalidResponse {
                // Expected.
            }
        }
    }

    func testSuiCoinTransferSimulationBindsSeparateAssetAndGasDebits() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let sender = "0x" + String(repeating: "1", count: 64)
        let recipient = "0x" + String(repeating: "2", count: 64)
        let coinObjectID = "0x" + String(repeating: "3", count: 64)
        let gasObjectID = "0x" + String(repeating: "4", count: 64)
        let identity = WalletSuiAssetIdentity(
            networkID: WalletNetworkCatalog.suiMainnet.id,
            coinType: "0x2::locus::LOCUS"
        )
        let digest = WalletSolanaBase58.encode(Data(repeating: 51, count: 32))
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 52, count: 32))
        let transactionBCS = Data([4, 3, 2, 1]).base64EncodedString()
        let client = makeSuiGraphQLClient(
            network: WalletNetworkCatalog.suiMainnet, now: now
        ) { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            XCTAssertTrue((body["query"] as? String)?.contains(
                "balanceChanges(first: 3)"
            ) == true)
            return try self.suiCoinTransferSimulationResponse(
                sender: sender, recipient: recipient,
                coinType: identity.coinType, gasObjectID: gasObjectID,
                transactionDigest: digest, effectsDigest: effectsDigest,
                assetDebit: "100", recipientCredit: "100", gasDebit: "1300"
            )
        }
        let result = try await client.simulateCoinTransfer(
            transactionBCS: transactionBCS,
            expectedTransactionDigest: digest,
            sender: sender, recipient: recipient, identity: identity,
            coinObjectID: coinObjectID, amountBaseUnits: "100",
            maximumFeeBaseUnits: "10000", gasObjectID: gasObjectID
        )
        XCTAssertEqual(result.identity, identity)
        XCTAssertEqual(result.coinObjectID, coinObjectID)
        XCTAssertEqual(result.senderAssetDebitBaseUnits, "100")
        XCTAssertEqual(result.recipientCreditBaseUnits, "100")
        XCTAssertEqual(result.senderGasDebitBaseUnits, "1300")
        XCTAssertEqual(result.gas.actualFeeBaseUnits, "1300")
    }

    func testSuiCoinTransferSimulationRejectsMixedOrSubstitutedEffects() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let sender = "0x" + String(repeating: "1", count: 64)
        let recipient = "0x" + String(repeating: "2", count: 64)
        let coinObjectID = "0x" + String(repeating: "3", count: 64)
        let gasObjectID = "0x" + String(repeating: "4", count: 64)
        let identity = WalletSuiAssetIdentity(
            networkID: WalletNetworkCatalog.suiMainnet.id,
            coinType: "0x2::locus::LOCUS"
        )
        let digest = WalletSolanaBase58.encode(Data(repeating: 53, count: 32))
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 54, count: 32))
        let transactionBCS = Data([4, 3, 2, 1]).base64EncodedString()
        let substitutions = [
            ("101", "100", "1300", identity.coinType),
            ("100", "99", "1300", identity.coinType),
            ("100", "100", "1299", identity.coinType),
            ("100", "100", "1300", "0x2::other::COIN"),
        ]
        for (assetDebit, credit, gasDebit, responseType) in substitutions {
            let client = makeSuiGraphQLClient(
                network: WalletNetworkCatalog.suiMainnet, now: now
            ) { _ in
                try self.suiCoinTransferSimulationResponse(
                    sender: sender, recipient: recipient,
                    coinType: responseType, gasObjectID: gasObjectID,
                    transactionDigest: digest, effectsDigest: effectsDigest,
                    assetDebit: assetDebit, recipientCredit: credit,
                    gasDebit: gasDebit
                )
            }
            do {
                _ = try await client.simulateCoinTransfer(
                    transactionBCS: transactionBCS,
                    expectedTransactionDigest: digest,
                    sender: sender, recipient: recipient, identity: identity,
                    coinObjectID: coinObjectID, amountBaseUnits: "100",
                    maximumFeeBaseUnits: "10000", gasObjectID: gasObjectID
                )
                XCTFail("Substituted Sui Coin effects must fail closed.")
            } catch WalletRPCError.invalidResponse {
                // Expected.
            }
        }
    }

    func testSuiObjectTransferSimulationBindsOwnershipAndGasEffects() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let sender = "0x" + String(repeating: "1", count: 64)
        let recipient = "0x" + String(repeating: "2", count: 64)
        let input = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "3", count: 64), version: 19,
            digest: WalletSolanaBase58.encode(Data(repeating: 61, count: 32)),
            type: "0x1234::collectible::LOCUS"
        )
        let gas = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "4", count: 64), version: 42,
            digest: WalletSolanaBase58.encode(Data(repeating: 62, count: 32)),
            type: "0x2::coin::Coin<0x2::sui::SUI>"
        )
        let digest = WalletSolanaBase58.encode(Data(repeating: 63, count: 32))
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 64, count: 32))
        let transactionBCS = Data([9, 8, 7, 6]).base64EncodedString()
        let client = makeSuiGraphQLClient(
            network: WalletNetworkCatalog.suiMainnet, now: now
        ) { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            XCTAssertTrue((body["query"] as? String)?.contains(
                "objectChanges(first: 3)"
            ) == true)
            return try self.suiObjectTransferSimulationResponse(
                sender: sender, recipient: recipient, input: input, gas: gas,
                transactionDigest: digest, effectsDigest: effectsDigest
            )
        }
        let result = try await client.simulateObjectTransfer(
            transactionBCS: transactionBCS,
            expectedTransactionDigest: digest,
            sender: sender, recipient: recipient, inputObject: input,
            maximumFeeBaseUnits: "10000", gasObject: gas
        )
        XCTAssertEqual(result.inputObject, input)
        XCTAssertEqual(result.outputObject.objectID, input.objectID)
        XCTAssertEqual(result.outputObject.version, 20)
        XCTAssertEqual(result.outputObject.type, input.type)
        XCTAssertEqual(result.senderGasDebitBaseUnits, "1300")
        XCTAssertTrue(result.hasPublicTransfer)
    }

    func testSuiObjectTransferSimulationRejectsOwnershipOrTypeSubstitution() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let sender = "0x" + String(repeating: "1", count: 64)
        let recipient = "0x" + String(repeating: "2", count: 64)
        let input = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "3", count: 64), version: 19,
            digest: WalletSolanaBase58.encode(Data(repeating: 65, count: 32)),
            type: "0x1234::collectible::LOCUS"
        )
        let gas = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "4", count: 64), version: 42,
            digest: WalletSolanaBase58.encode(Data(repeating: 66, count: 32)),
            type: "0x2::coin::Coin<0x2::sui::SUI>"
        )
        let digest = WalletSolanaBase58.encode(Data(repeating: 67, count: 32))
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 68, count: 32))
        let transactionBCS = Data([9, 8, 7, 6]).base64EncodedString()
        let substitutions = [
            (sender, input.type, true),
            (recipient, "0x1234::other::OBJECT", true),
            (recipient, input.type, false),
        ]
        for (outputOwner, outputType, isPublic) in substitutions {
            let client = makeSuiGraphQLClient(
                network: WalletNetworkCatalog.suiMainnet, now: now
            ) { _ in
                try self.suiObjectTransferSimulationResponse(
                    sender: sender, recipient: recipient, input: input, gas: gas,
                    transactionDigest: digest, effectsDigest: effectsDigest,
                    outputOwner: outputOwner, outputType: outputType,
                    outputHasPublicTransfer: isPublic
                )
            }
            do {
                _ = try await client.simulateObjectTransfer(
                    transactionBCS: transactionBCS,
                    expectedTransactionDigest: digest,
                    sender: sender, recipient: recipient, inputObject: input,
                    maximumFeeBaseUnits: "10000", gasObject: gas
                )
                XCTFail("Substituted Sui object effects must fail closed.")
            } catch WalletRPCError.invalidResponse {
                // Expected.
            }
        }
    }

    func testSuiExecutionUsesExactSignerMaterialAndRequiresFinality() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let transactionBCS = Data([0, 1, 2, 3]).base64EncodedString()
        let signature = Data(repeating: 7, count: 97).base64EncodedString()
        let digest = WalletSolanaBase58.encode(Data(repeating: 47, count: 32))
        let effectsDigest = WalletSolanaBase58.encode(Data(repeating: 48, count: 32))
        var requests = 0
        let client = makeSuiGraphQLClient(
            network: WalletNetworkCatalog.suiMainnet, now: now
        ) { request in
            requests += 1
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let operation = try XCTUnwrap(body["query"] as? String)
            if requests == 1 {
                XCTAssertTrue(operation.contains("query LocusSuiNetworkStatus"))
                return try self.suiNetworkStatusResponse(
                    chainIdentifier: WalletSuiChainIdentity.mainnetBase58
                )
            }
            XCTAssertTrue(operation.contains("mutation LocusSuiExecuteTransaction"))
            XCTAssertFalse(operation.contains("simulateTransaction"))
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["transactionDataBcs"] as? String, transactionBCS)
            XCTAssertEqual(variables["signatures"] as? [String], [signature])
            return try JSONSerialization.data(withJSONObject: [
                "data": [
                    "executeTransaction": [
                        "effects": [
                            "digest": digest,
                            "effectsDigest": effectsDigest,
                            "status": "SUCCESS",
                            "executionError": NSNull(),
                            "checkpoint": [
                                "sequenceNumber": 123_457,
                                "timestamp": "2026-08-31T12:04:00Z",
                            ],
                        ],
                    ],
                ],
            ])
        }
        let result = try await client.executeTransaction(
            transactionBCS: transactionBCS, signature: signature,
            expectedTransactionDigest: digest
        )
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(result.transactionDigest, digest)
        XCTAssertEqual(result.effectsDigest, effectsDigest)
        XCTAssertEqual(result.checkpointSequence, 123_457)
    }

    func testSuiExecutionRejectsMismatchedOrNonfinalEffects() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let transactionBCS = Data([0, 1, 2, 3]).base64EncodedString()
        let signature = Data(repeating: 8, count: 97).base64EncodedString()
        let digest = WalletSolanaBase58.encode(Data(repeating: 49, count: 32))
        let otherDigest = WalletSolanaBase58.encode(Data(repeating: 50, count: 32))
        var requests = 0
        let client = makeSuiGraphQLClient(
            network: WalletNetworkCatalog.suiMainnet, now: now
        ) { _ in
            requests += 1
            if requests == 1 {
                return try self.suiNetworkStatusResponse(
                    chainIdentifier: WalletSuiChainIdentity.mainnetBase58
                )
            }
            return try JSONSerialization.data(withJSONObject: [
                "data": [
                    "executeTransaction": [
                        "effects": [
                            "digest": otherDigest,
                            "effectsDigest": otherDigest,
                            "status": "SUCCESS",
                            "executionError": NSNull(),
                            "checkpoint": NSNull(),
                        ],
                    ],
                ],
            ])
        }
        do {
            _ = try await client.executeTransaction(
                transactionBCS: transactionBCS, signature: signature,
                expectedTransactionDigest: digest
            )
            XCTFail("Mismatched or nonfinal Sui execution evidence must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("finality"))
        }
    }

    func testSuiGraphQLIndexesFinalizedOwnerCoinChangesWithoutOpaqueData() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "1", count: 64)
        let sender = "0x" + String(repeating: "2", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 21, count: 32))
        let coinType = "0x1234::example::COIN"
        let client = makeSuiGraphQLClient(now: now) { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.contains("relation: AFFECTED"))
            XCTAssertTrue(query.contains("balanceChanges(first: 50)"))
            XCTAssertFalse(query.lowercased().contains("bcs"))
            XCTAssertFalse(query.contains("display"))
            let variables = try XCTUnwrap(body["variables"] as? [String: Any])
            XCTAssertEqual(variables["address"] as? String, owner)
            XCTAssertEqual(variables["first"] as? Int, 50)
            XCTAssertTrue(variables["after"] is NSNull)
            XCTAssertTrue(variables["checkpoint"] is NSNull)
            return try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: sender,
                    balanceChanges: [
                        self.suiBalanceChangeJSON(
                            owner: owner,
                            coinType: WalletSuiAssetIdentity.nativeCoinType,
                            amount: "25"
                        ),
                        self.suiBalanceChangeJSON(
                            owner: owner, coinType: coinType, amount: "-9"
                        ),
                    ]
                )]
            )
        }
        let activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 2)
        XCTAssertTrue(activity.allSatisfy {
            $0.transactionDigest == digest && $0.checkpointSequence == 123_455
                && $0.sender == sender && $0.successful
        })
        let native = try XCTUnwrap(activity.first {
            $0.identity?.coinType == WalletSuiAssetIdentity.nativeCoinType
        })
        XCTAssertEqual(native.amountBaseUnits, "25")
        XCTAssertEqual(native.isInbound, true)
        let coin = try XCTUnwrap(activity.first { $0.identity?.coinType == coinType })
        XCTAssertEqual(coin.amountBaseUnits, "9")
        XCTAssertEqual(coin.isInbound, false)
    }

    func testSuiGraphQLIndexesExactFinalizedObjectOwnershipChange() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "1", count: 64)
        let sender = "0x" + String(repeating: "2", count: 64)
        let objectID = "0x" + String(repeating: "3", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 70, count: 32))
        let input = WalletSuiObjectReference(
            objectID: objectID, version: 9,
            digest: WalletSolanaBase58.encode(Data(repeating: 71, count: 32)),
            type: "0x1234::artifact::ARTIFACT"
        )
        let output = WalletSuiObjectReference(
            objectID: objectID, version: 10,
            digest: WalletSolanaBase58.encode(Data(repeating: 72, count: 32)),
            type: input.type
        )
        let gasInput = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "4", count: 64), version: 30,
            digest: WalletSolanaBase58.encode(Data(repeating: 77, count: 32)),
            type: "0x2::coin::Coin<0x2::sui::SUI>"
        )
        let gasOutput = WalletSuiObjectReference(
            objectID: gasInput.objectID, version: 31,
            digest: WalletSolanaBase58.encode(Data(repeating: 78, count: 32)),
            type: gasInput.type
        )
        let client = makeSuiGraphQLClient(now: now) { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.contains("objectChanges(first: 50)"))
            XCTAssertTrue(query.contains("hasPublicTransfer"))
            XCTAssertFalse(query.lowercased().contains("bcs"))
            XCTAssertFalse(query.contains("display"))
            return try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: sender, balanceChanges: [],
                    objectChanges: [
                        self.suiActivityObjectChangeJSON(
                            input: input, output: output,
                            inputOwner: sender, outputOwner: owner
                        ),
                        self.suiActivityObjectChangeJSON(
                            input: gasInput, output: gasOutput,
                            inputOwner: sender, outputOwner: sender
                        ),
                    ]
                )]
            )
        }
        let activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 1)
        let item = try XCTUnwrap(activity.first)
        XCTAssertEqual(item.transactionDigest, digest)
        XCTAssertEqual(item.objectIdentity?.objectID, objectID)
        XCTAssertEqual(item.objectType, input.type)
        XCTAssertEqual(item.objectHasPublicTransfer, true)
        XCTAssertEqual(item.amountBaseUnits, "1")
        XCTAssertEqual(item.isInbound, true)
        XCTAssertNil(item.identity)
    }

    func testSuiGraphQLIndexesOwnedObjectCreationAndDeletion() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "4", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 80, count: 32))
        let created = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "8", count: 64), version: 1,
            digest: WalletSolanaBase58.encode(Data(repeating: 81, count: 32)),
            type: "0x1234::artifact::CREATED"
        )
        let deleted = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "9", count: 64), version: 7,
            digest: WalletSolanaBase58.encode(Data(repeating: 82, count: 32)),
            type: "0x1234::artifact::DELETED"
        )
        let client = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, balanceChanges: [],
                    objectChanges: [
                        self.suiActivityTerminalObjectChangeJSON(
                            state: created, owner: owner, created: true
                        ),
                        self.suiActivityTerminalObjectChangeJSON(
                            state: deleted, owner: owner, created: false
                        ),
                    ]
                )]
            )
        }
        let activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 2)
        let byObject = Dictionary(uniqueKeysWithValues: activity.compactMap {
            item in item.objectIdentity.map { ($0.objectID, item) }
        })
        let creation = try XCTUnwrap(byObject[created.objectID])
        XCTAssertEqual(creation.objectType, created.type)
        XCTAssertEqual(creation.objectHasPublicTransfer, true)
        XCTAssertEqual(creation.amountBaseUnits, "1")
        XCTAssertEqual(creation.isInbound, true)
        let deletion = try XCTUnwrap(byObject[deleted.objectID])
        XCTAssertEqual(deletion.objectType, deleted.type)
        XCTAssertEqual(deletion.objectHasPublicTransfer, true)
        XCTAssertEqual(deletion.amountBaseUnits, "1")
        XCTAssertEqual(deletion.isInbound, false)
    }

    func testSuiGraphQLRejectsContradictoryObjectLifecycleEvidence() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "4", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 83, count: 32))
        let object = WalletSuiObjectReference(
            objectID: "0x" + String(repeating: "a", count: 64), version: 1,
            digest: WalletSolanaBase58.encode(Data(repeating: 84, count: 32)),
            type: "0x1234::artifact::OBJECT"
        )
        var contradictory = suiActivityTerminalObjectChangeJSON(
            state: object, owner: owner, created: true
        )
        contradictory["idDeleted"] = true
        let client = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, balanceChanges: [],
                    objectChanges: [contradictory]
                )]
            )
        }
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("Contradictory lifecycle flags must fail the activity batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("contradictory"))
        }

        var malformed = suiActivityTerminalObjectChangeJSON(
            state: object, owner: owner, created: true
        )
        malformed["inputState"] = malformed["outputState"]
        let malformedClient = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, balanceChanges: [],
                    objectChanges: [malformed]
                )]
            )
        }
        do {
            _ = try await malformedClient.activity(owner: owner)
            XCTFail("A creation with an input state must fail the activity batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("ambiguous"))
        }
    }

    func testSuiGraphQLRejectsAmbiguousObjectActivityEvidence() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "4", count: 64)
        let recipient = "0x" + String(repeating: "5", count: 64)
        let objectID = "0x" + String(repeating: "6", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 73, count: 32))
        let input = WalletSuiObjectReference(
            objectID: objectID, version: 20,
            digest: WalletSolanaBase58.encode(Data(repeating: 74, count: 32)),
            type: "0x1234::artifact::ARTIFACT"
        )
        let substituted = WalletSuiObjectReference(
            objectID: objectID, version: 21,
            digest: WalletSolanaBase58.encode(Data(repeating: 75, count: 32)),
            type: "0x1234::other::OBJECT"
        )
        let client = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, balanceChanges: [],
                    objectChanges: [self.suiActivityObjectChangeJSON(
                        input: input, output: substituted,
                        inputOwner: owner, outputOwner: recipient
                    )]
                )]
            )
        }
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("Object type substitution must fail the activity batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("ambiguous"))
        }

        let validOutput = WalletSuiObjectReference(
            objectID: objectID, version: 21,
            digest: WalletSolanaBase58.encode(Data(repeating: 79, count: 32)),
            type: input.type
        )
        let repeated = suiActivityObjectChangeJSON(
            input: input, output: validOutput,
            inputOwner: owner, outputOwner: recipient
        )
        let duplicate = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, balanceChanges: [],
                    objectChanges: [repeated, repeated]
                )]
            )
        }
        do {
            _ = try await duplicate.activity(owner: owner)
            XCTFail("Duplicate object effects must fail the activity batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("duplicate"))
        }

        let truncated = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, balanceChanges: [],
                    objectChanges: [], hasMoreObjectChanges: true
                )]
            )
        }
        do {
            _ = try await truncated.activity(owner: owner)
            XCTFail("Truncated object changes must fail the activity batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("effects"))
        }
    }

    func testSuiGraphQLRejectsAmbiguousBalanceChangeEvidence() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "3", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 22, count: 32))
        let repeated = self.suiBalanceChangeJSON(
            owner: owner, coinType: "0x1234::example::COIN", amount: "1"
        )
        let duplicate = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner,
                    balanceChanges: [repeated, repeated]
                )]
            )
        }
        do {
            _ = try await duplicate.activity(owner: owner)
            XCTFail("A repeated Coin type must fail the entire Sui transaction.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("repeated"))
        }

        let truncated = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner,
                    balanceChanges: [repeated], hasMoreBalanceChanges: true
                )]
            )
        }
        do {
            _ = try await truncated.activity(owner: owner)
            XCTFail("Unresolved nested balance-change pages must fail closed.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("effects"))
        }
    }

    func testSuiGraphQLRejectsFailedTransactionWithBalanceChanges() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(
            from: "2026-08-31T12:05:00Z"
        ))
        let owner = "0x" + String(repeating: "4", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 23, count: 32))
        let client = makeSuiGraphQLClient(now: now) { _ in
            try self.suiActivityResponse(
                owner: owner,
                transactions: [self.suiActivityTransactionJSON(
                    digest: digest, sender: owner, status: "FAILURE",
                    balanceChanges: [self.suiBalanceChangeJSON(
                        owner: owner,
                        coinType: WalletSuiAssetIdentity.nativeCoinType,
                        amount: "-1"
                    )]
                )]
            )
        }
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("Failed Sui effects must not report owner balance changes.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("failed"))
        }
    }

    func testGatewayRefreshesCanonicalNativeSuiSnapshot() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.accountAddress = "0x" + String(repeating: "4", count: 64)
        signer.balanceBaseUnits = "1234567890"
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let snapshot = try XCTUnwrap(gateway.accountSnapshots.first)
        XCTAssertEqual(snapshot.chain, .sui)
        XCTAssertEqual(snapshot.networkID, WalletNetworkCatalog.suiTestnet.id)
        XCTAssertEqual(snapshot.assetID, WalletNetworkCatalog.suiTestnet.nativeAssetID)
        XCTAssertEqual(snapshot.balanceBaseUnits, "1234567890")
        XCTAssertEqual(snapshot.freshness, .current)
    }

    func testGatewayQuarantinesSuiCoinUntilExplicitTrust() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.accountAddress = "0x" + String(repeating: "7", count: 64)
        let coinType = "0x1234::example::COIN"
        let assetID = "sui:testnet/coin:\(coinType)"
        signer.discoveredAssetRows = [
            [
                "asset_id": WalletNetworkCatalog.suiTestnet.nativeAssetID,
                "asset_kind": WalletAssetKind.fungibleToken.rawValue,
                "reference": WalletSuiAssetIdentity.nativeCoinType,
                "coin_type": WalletSuiAssetIdentity.nativeCoinType,
                "balance_base_units": "45",
                "coin_balance_base_units": "40",
                "address_balance_base_units": "5",
            ],
            [
                "asset_id": assetID,
                "asset_kind": WalletAssetKind.fungibleToken.rawValue,
                "reference": coinType, "coin_type": coinType,
                "balance_base_units": "1007",
                "coin_balance_base_units": "1000",
                "address_balance_base_units": "7",
            ],
        ]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        XCTAssertEqual(
            gateway.accountSnapshots.first(where: {
                $0.assetID == WalletNetworkCatalog.suiTestnet.nativeAssetID
            })?.balanceBaseUnits,
            "45"
        )
        XCTAssertEqual(gateway.assets.first(where: { $0.id == assetID })?.trust, .quarantined)
        XCTAssertFalse(gateway.accountSnapshots.contains { $0.assetID == assetID })

        gateway.trustQuarantinedAsset(id: assetID)
        await gateway.refreshAccountSnapshots()
        let snapshot = try XCTUnwrap(
            gateway.accountSnapshots.first(where: { $0.assetID == assetID })
        )
        XCTAssertEqual(snapshot.balanceBaseUnits, "1007")
        XCTAssertEqual(snapshot.symbol, "COIN")
        XCTAssertEqual(snapshot.freshness, .current)
    }

    func testGatewayQuarantinesSuiObjectWithoutRemoteMetadata() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.accountAddress = "0x" + String(repeating: "e", count: 64)
        let objectID = "0x" + String(repeating: "f", count: 64)
        let assetID = "sui:testnet/object:\(objectID)"
        signer.discoveredAssetRows = [[
            "asset_id": assetID,
            "asset_kind": WalletAssetKind.collectible.rawValue,
            "reference": objectID, "object_id": objectID,
            "object_version": UInt64(77),
            "object_digest": WalletSolanaBase58.encode(Data(repeating: 17, count: 32)),
            "move_type": "0x1234::artifact::ARTIFACT",
            "has_public_transfer": false,
            "balance_base_units": "1", "decimals": 0,
        ]]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let asset = try XCTUnwrap(gateway.assets.first(where: { $0.id == assetID }))
        XCTAssertEqual(asset.kind, .collectible)
        XCTAssertEqual(asset.trust, .quarantined)
        XCTAssertEqual(asset.name, "Unknown Sui object")
        XCTAssertEqual(asset.symbol, "ARTIFACT")
        XCTAssertFalse(gateway.accountSnapshots.contains { $0.assetID == assetID })

        gateway.trustQuarantinedAsset(id: assetID)
        await gateway.refreshAccountSnapshots()
        XCTAssertEqual(
            gateway.accountSnapshots.first(where: { $0.assetID == assetID })?.balanceBaseUnits,
            "1"
        )
    }

    func testGatewayPersistsFinalizedSuiActivityAndQuarantinesUnknownCoin() async throws {
        let suiteName = "WalletSuiActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.accountAddress = "0x" + String(repeating: "5", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 24, count: 32))
        let coinType = "0x1234::example::COIN"
        let coinID = "sui:testnet/coin:\(coinType)"
        let timestamp = Date().addingTimeInterval(-30).timeIntervalSince1970
        signer.indexedActivityRows = [
            [
                "id": "\(digest):native", "transaction_hash": digest,
                "block_number": "123455", "occurred_at": timestamp,
                "status": "confirmed", "owner": signer.accountAddress,
                "sender": "0x" + String(repeating: "6", count: 64),
                "asset_id": WalletNetworkCatalog.suiTestnet.nativeAssetID,
                "asset_reference": WalletSuiAssetIdentity.nativeCoinType,
                "asset_kind": WalletAssetKind.native.rawValue,
                "amount_base_units": "25", "direction": "inbound",
            ],
            [
                "id": "\(digest):coin", "transaction_hash": digest,
                "block_number": "123455", "occurred_at": timestamp,
                "status": "confirmed", "owner": signer.accountAddress,
                "sender": signer.accountAddress,
                "asset_id": coinID, "asset_reference": coinType,
                "asset_kind": WalletAssetKind.fungibleToken.rawValue,
                "amount_base_units": "9", "direction": "outbound",
            ],
        ]
        let store = try WalletPublicStore(path: ":memory:")
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: store
        )
        await gateway.refreshStatus()
        await gateway.refreshTransactionHistory()
        XCTAssertEqual(gateway.transactionHistory.count, 2)
        XCTAssertTrue(gateway.transactionHistory.allSatisfy {
            $0.transactionHash == digest && $0.finality == .finalized
                && $0.state == .confirmed
        })
        XCTAssertEqual(
            gateway.transactionHistory.first(where: { $0.assetID == coinID })?.direction,
            .outbound
        )
        let quarantined = try XCTUnwrap(gateway.assets.first { $0.id == coinID })
        XCTAssertEqual(quarantined.trust, .quarantined)
        XCTAssertFalse(try XCTUnwrap(
            store.loadAssets().first { $0.id == coinID }
        ).isVisibleByDefault)
    }

    func testGatewayPersistsFinalizedSolanaActivityAndQuarantinesUnknownAssets() async throws {
        let suiteName = "WalletSolanaActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let signature = WalletSolanaBase58.encode(Data(repeating: 61, count: 64))
        let mint = WalletSolanaBase58.encode(Data(repeating: 62, count: 32))
        let coreAsset = WalletSolanaBase58.encode(Data(repeating: 63, count: 32))
        let tokenID = "solana:devnet/spl:\(mint)"
        let coreID = "solana:devnet/nft:core:\(coreAsset)"
        let timestamp = Date().addingTimeInterval(-30).timeIntervalSince1970
        signer.indexedActivityRows = [
            [
                "id": "\(signature):transaction", "transaction_hash": signature,
                "block_number": "123455", "occurred_at": timestamp,
                "status": "confirmed", "owner": signer.accountAddress,
                "fee_base_units": "5000",
            ],
            [
                "id": "\(signature):token", "transaction_hash": signature,
                "block_number": "123455", "occurred_at": timestamp,
                "status": "confirmed", "owner": signer.accountAddress,
                "fee_base_units": "5000", "asset_id": tokenID,
                "asset_reference": mint,
                "asset_kind": WalletAssetKind.fungibleToken.rawValue,
                "amount_base_units": "40", "direction": "outbound",
            ],
            [
                "id": "\(signature):core", "transaction_hash": signature,
                "block_number": "123455", "occurred_at": timestamp,
                "status": "confirmed", "owner": signer.accountAddress,
                "fee_base_units": "5000", "asset_id": coreID,
                "asset_reference": coreAsset,
                "asset_kind": WalletAssetKind.collectible.rawValue,
                "amount_base_units": "1", "direction": "inbound",
            ],
        ]
        let store = try WalletPublicStore(path: ":memory:")
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: store
        )
        await gateway.refreshStatus()
        await gateway.refreshTransactionHistory()
        XCTAssertEqual(gateway.transactionHistory.count, 3)
        XCTAssertTrue(gateway.transactionHistory.allSatisfy {
            $0.transactionHash == signature && $0.finality == .finalized
                && $0.state == .confirmed
        })
        XCTAssertEqual(
            gateway.transactionHistory.first(where: { $0.assetID == tokenID })?.direction,
            .outbound
        )
        XCTAssertEqual(
            gateway.transactionHistory.first(where: { $0.assetID == coreID })?.actionKind,
            .nftTransfer
        )
        let token = try XCTUnwrap(gateway.assets.first { $0.id == tokenID })
        let collectible = try XCTUnwrap(gateway.assets.first { $0.id == coreID })
        XCTAssertEqual(token.trust, .quarantined)
        XCTAssertEqual(collectible.trust, .quarantined)
        XCTAssertEqual(collectible.kind, .collectible)
        XCTAssertFalse(try XCTUnwrap(
            store.loadAssets().first { $0.id == tokenID }
        ).isVisibleByDefault)
        XCTAssertFalse(try XCTUnwrap(
            store.loadAssets().first { $0.id == coreID }
        ).isVisibleByDefault)
    }

    func testGatewayRejectsEntireSolanaActivityBatchOnOwnerSubstitution() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let signature = WalletSolanaBase58.encode(Data(repeating: 64, count: 64))
        let timestamp = Date().addingTimeInterval(-30).timeIntervalSince1970
        let valid: [String: Any] = [
            "id": "valid", "transaction_hash": signature,
            "block_number": "123455", "occurred_at": timestamp,
            "status": "confirmed", "owner": signer.accountAddress,
            "fee_base_units": "5000",
        ]
        var substituted = valid
        substituted["id"] = "substituted"
        substituted["owner"] = WalletSolanaBase58.encode(Data(repeating: 65, count: 32))
        signer.indexedActivityRows = [valid, substituted]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        await gateway.refreshStatus()
        await gateway.refreshTransactionHistory()
        XCTAssertTrue(gateway.transactionHistory.isEmpty)
    }

    func testGatewayPersistsFinalizedSuiObjectActivityInQuarantine() async throws {
        let suiteName = "WalletSuiObjectActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.accountAddress = "0x" + String(repeating: "9", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 76, count: 32))
        let objectID = "0x" + String(repeating: "a", count: 64)
        let assetID = "sui:testnet/object:\(objectID)"
        signer.indexedActivityRows = [[
            "id": "\(digest):object", "transaction_hash": digest,
            "block_number": "123455",
            "occurred_at": Date().addingTimeInterval(-30).timeIntervalSince1970,
            "status": "confirmed", "owner": signer.accountAddress,
            "sender": "0x" + String(repeating: "b", count: 64),
            "asset_id": assetID, "asset_reference": objectID,
            "asset_kind": WalletAssetKind.collectible.rawValue,
            "object_type": "0x1234::artifact::ARTIFACT",
            "has_public_transfer": true,
            "amount_base_units": "1", "direction": "inbound",
        ]]
        let store = try WalletPublicStore(path: ":memory:")
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults,
            publicStore: store
        )
        await gateway.refreshStatus()
        await gateway.refreshTransactionHistory()
        let record = try XCTUnwrap(gateway.transactionHistory.first)
        XCTAssertEqual(record.transactionHash, digest)
        XCTAssertEqual(record.actionKind, .nftTransfer)
        XCTAssertEqual(record.assetID, assetID)
        XCTAssertEqual(record.amountBaseUnits, "1")
        XCTAssertEqual(record.direction, .inbound)
        XCTAssertEqual(record.finality, .finalized)
        let asset = try XCTUnwrap(gateway.assets.first { $0.id == assetID })
        XCTAssertEqual(asset.kind, .collectible)
        XCTAssertEqual(asset.trust, .quarantined)
        XCTAssertEqual(asset.reference, objectID)
        XCTAssertFalse(try XCTUnwrap(
            store.loadAssets().first { $0.id == assetID }
        ).isVisibleByDefault)
    }

    func testGatewayRejectsEntireSuiActivityBatchOnOwnerSubstitution() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .sui
        signer.accountNetworkIDs = [WalletNetworkCatalog.suiTestnet.id]
        signer.accountAddress = "0x" + String(repeating: "7", count: 64)
        let digest = WalletSolanaBase58.encode(Data(repeating: 25, count: 32))
        let timestamp = Date().addingTimeInterval(-30).timeIntervalSince1970
        let valid: [String: Any] = [
            "id": "valid", "transaction_hash": digest,
            "block_number": "123455", "occurred_at": timestamp,
            "status": "confirmed", "owner": signer.accountAddress,
        ]
        var substituted = valid
        substituted["id"] = "substituted"
        substituted["owner"] = "0x" + String(repeating: "8", count: 64)
        signer.indexedActivityRows = [valid, substituted]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        await gateway.refreshStatus()
        await gateway.refreshTransactionHistory()
        XCTAssertTrue(gateway.transactionHistory.isEmpty)
    }

    func testSolanaCanonicalNativeMessageUsesStrictBase58AndReviewedShape() throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let transfer = try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer, recipient: recipient,
            recentBlockhash: blockhash, amountBaseUnits: "123456789"
        )
        XCTAssertEqual(WalletSolanaBase58.decode(payer, exactLength: 32)?.count, 32)
        XCTAssertEqual(transfer.message.count, 150)
        XCTAssertEqual(transfer.unsignedTransaction.count, 215)
        XCTAssertEqual(
            transfer.canonicalMessageDigest,
            "sha256:f5d55dd7bde27c8ff2565f8867ded2ec84d5ca0b75ada68aec6c6b3ec305d59d"
        )
        XCTAssertEqual(
            transfer.resolvedAccountsDigest,
            WalletSolanaCanonicalNativeTransfer.resolvedDigest(
                feePayer: payer, recipient: recipient
            )
        )
        XCTAssertNil(WalletSolanaBase58.decode("0OIl", exactLength: 32))
        XCTAssertThrowsError(try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer, recipient: payer,
            recentBlockhash: blockhash, amountBaseUnits: "1"
        ))
        XCTAssertThrowsError(try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer, recipient: recipient,
            recentBlockhash: blockhash, amountBaseUnits: "18446744073709551616"
        ))
        XCTAssertThrowsError(try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer, recipient: recipient,
            recentBlockhash: blockhash, amountBaseUnits: "1",
            computeUnitLimit: 825
        ))
        XCTAssertThrowsError(try WalletSolanaCanonicalNativeTransfer(
            feePayer: payer,
            recipient: "ComputeBudget111111111111111111111111111111",
            recentBlockhash: blockhash, amountBaseUnits: "1",
            computeUnitLimit: 825, computeUnitPriceMicroLamports: 30_000
        ))
    }

    func testSolanaCanonicalCoreMessageMatchesIndependentSignerShape() throws {
        XCTAssertTrue(
            WalletNetworkCatalog.solanaMainnet.staticallyReviewedCapabilities
                .contains(.nftTransfer)
        )
        XCTAssertThrowsError(try WalletLaunchGate().authorize(
            networkID: WalletNetworkCatalog.solanaMainnet.id,
            capability: .nftTransfer, regionCode: "CA"
        ))
        XCTAssertTrue(
            WalletNetworkCatalog.solanaDevnet.staticallyReviewedCapabilities
                .contains(.nftTransfer)
        )
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let asset = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 8, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let evidenceDigest = "sha256:" + String(repeating: "a", count: 64)
        let transfer = try WalletSolanaCanonicalCoreTransfer(
            feePayer: payer, asset: asset, recipient: recipient,
            recentBlockhash: blockhash, assetDataDigest: evidenceDigest
        )
        XCTAssertEqual(transfer.message.count, 177)
        XCTAssertEqual(transfer.unsignedTransaction.count, 242)
        XCTAssertEqual(Array(transfer.message.prefix(4)), [1, 0, 2, 4])
        XCTAssertEqual(
            Array(transfer.message[167..<174]),
            [1, 3, 0, 3, 2, 3, 3]
        )
        XCTAssertEqual(Array(transfer.message.suffix(3)), [2, 14, 0])
        XCTAssertEqual(
            transfer.resolvedAccountsDigest,
            WalletSolanaCanonicalCoreTransfer.resolvedDigest(
                feePayer: payer, asset: asset, recipient: recipient,
                assetDataDigest: evidenceDigest
            )
        )
        XCTAssertThrowsError(try WalletSolanaCanonicalCoreTransfer(
            feePayer: payer, asset: asset, recipient: asset,
            recentBlockhash: blockhash, assetDataDigest: evidenceDigest
        ))
        XCTAssertThrowsError(try WalletSolanaCanonicalCoreTransfer(
            feePayer: payer, asset: asset, recipient: recipient,
            recentBlockhash: blockhash, assetDataDigest: "sha256:ABC"
        ))
    }

    func testSolanaCanonicalSPLMessageMatchesIndependentSignerFixture() throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let source = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let destination = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let transfer = try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: destination, recipientOwner: recipient,
            tokenProgramID: WalletSolanaTokenProgram.spl.programID,
            recentBlockhash: blockhash, amountBaseUnits: "123456789",
            decimals: 6
        )
        XCTAssertEqual(transfer.message.count, 214)
        XCTAssertEqual(transfer.unsignedTransaction.count, 279)
        XCTAssertEqual(
            transfer.canonicalMessageDigest,
            "sha256:1e22ab87cedf350790b6bc80e98799dfe043aa04d0e7e1374b9e98b1a3390c7f"
        )
        XCTAssertEqual(transfer.message.suffix(10).first, 12)
        XCTAssertEqual(
            transfer.resolvedAccountsDigest,
            WalletSolanaCanonicalSPLTransfer.resolvedDigest(
                feePayer: payer, sourceTokenAccount: source, mint: mint,
                destinationTokenAccount: destination,
                recipientOwner: recipient,
                tokenProgramID: WalletSolanaTokenProgram.spl.programID
            )
        )
        XCTAssertThrowsError(try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: destination, recipientOwner: recipient,
            tokenProgramID: WalletSolanaBase58.encode(
                Data(repeating: 10, count: 32)
            ),
            recentBlockhash: blockhash, amountBaseUnits: "1", decimals: 6
        ))
        XCTAssertThrowsError(try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: source, recipientOwner: recipient,
            tokenProgramID: WalletSolanaTokenProgram.spl.programID,
            recentBlockhash: blockhash, amountBaseUnits: "1", decimals: 6
        ))
    }

    func testSolanaCanonicalAssociatedTokenCreationMatchesIndependentSignerFixture() throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let source = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let destination = "DUJre3jPyHZAAuoWaaqRQgJ6DjyKTaXVXKMH3bpLV8Kb"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let transfer = try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: destination, recipientOwner: recipient,
            tokenProgramID: WalletSolanaTokenProgram.spl.programID,
            recentBlockhash: blockhash, amountBaseUnits: "123456789",
            decimals: 6, createsDestinationAssociatedAccount: true
        )
        XCTAssertEqual(transfer.message.count, 320)
        XCTAssertEqual(transfer.unsignedTransaction.count, 385)
        XCTAssertEqual(
            transfer.canonicalMessageDigest,
            "sha256:25ad6ed5b9995274e83214731f90361f3873880a34f656adae5b9ce20c928ca8"
        )
        XCTAssertTrue(transfer.createsDestinationAssociatedAccount)
        XCTAssertEqual(transfer.associatedTokenCreationAccounts.count, 6)
        XCTAssertEqual(
            transfer.resolvedAccountsDigest,
            WalletSolanaCanonicalSPLTransfer.resolvedDigest(
                feePayer: payer, sourceTokenAccount: source, mint: mint,
                destinationTokenAccount: destination,
                recipientOwner: recipient,
                tokenProgramID: WalletSolanaTokenProgram.spl.programID,
                createsDestinationAssociatedAccount: true
            )
        )
    }

    func testSolanaCanonicalToken2022TransferMatchesIndependentSignerFixture() throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let source = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let destination = "9dTDtNrTEkkDWLkvXLLQfmsJ7wFcuk7DCf6nN53i1Dt"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let transfer = try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: destination, recipientOwner: recipient,
            tokenProgramID: WalletSolanaTokenProgram.token2022.programID,
            recentBlockhash: blockhash, amountBaseUnits: "123456789",
            decimals: 6, createsDestinationAssociatedAccount: true,
            mintExtensions: ["metadataPointer", "tokenMetadata"],
            sourceAccountExtensions: ["immutableOwner"],
            destinationAccountExtensions: ["immutableOwner"]
        )
        XCTAssertEqual(
            transfer.canonicalMessageDigest,
            "sha256:163ce00af6a503a938aabe131c8c672d16fbe56104b2431de34ebb9dcddc7f4a"
        )
        XCTAssertEqual(transfer.message.count, 320)
        XCTAssertThrowsError(try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: destination, recipientOwner: recipient,
            tokenProgramID: WalletSolanaTokenProgram.token2022.programID,
            recentBlockhash: blockhash, amountBaseUnits: "123456789",
            decimals: 6, createsDestinationAssociatedAccount: true,
            mintExtensions: ["transferFeeConfig"],
            sourceAccountExtensions: ["immutableOwner"],
            destinationAccountExtensions: ["immutableOwner"]
        ))
    }

    func testSolanaAssetIdentityIsCanonicalAndProgramScoped() {
        let mint = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let legacy = "solana:devnet/spl:\(mint)"
        let token2022 = "solana:devnet/token2022:\(mint)"
        XCTAssertEqual(
            WalletSolanaAssetIdentity.parse(legacy)?.program,
            .spl
        )
        XCTAssertEqual(
            WalletSolanaAssetIdentity.parse(token2022)?.program.programID,
            WalletSolanaTokenProgram.token2022.programID
        )
        XCTAssertNil(WalletSolanaAssetIdentity.parse("solana:devnet/spl:0OIl"))
        XCTAssertNil(WalletSolanaAssetIdentity.parse("eip155:1/spl:\(mint)"))
        XCTAssertNil(WalletSolanaAssetIdentity.parse("solana:devnet/unknown:\(mint)"))
    }

    func testSolanaCollectibleIdentityIsCanonicalAndStandardScoped() {
        let address = WalletSolanaBase58.encode(Data(repeating: 12, count: 32))
        let canonical = "solana:devnet/nft:core:\(address)"
        XCTAssertEqual(
            WalletSolanaCollectibleIdentity.parse(canonical)?.standard,
            .core
        )
        XCTAssertEqual(
            WalletSolanaCollectibleIdentity.parse(canonical)?.address,
            address
        )
        XCTAssertNil(WalletSolanaCollectibleIdentity.parse(
            "eip155:1/nft:core:\(address)"
        ))
        XCTAssertNil(WalletSolanaCollectibleIdentity.parse(
            "solana:devnet/nft:unknown:\(address)"
        ))
        XCTAssertNil(WalletSolanaCollectibleIdentity.parse(
            "solana:devnet/nft:core:0OIl"
        ))
    }

    func testSolanaTokenDiscoveryValidatesBothProgramsAndRawBalances() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let mint = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let tokenAccount = WalletSolanaBase58.encode(Data(repeating: 6, count: 32))
        var requestedPrograms: [String] = []
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            if method == "getGenesisHash" {
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            } else {
                XCTAssertEqual(method, "getTokenAccountsByOwner")
                let params = try XCTUnwrap(object["params"] as? [Any])
                let filter = try XCTUnwrap(params[1] as? [String: Any])
                let programID = try XCTUnwrap(filter["programId"] as? String)
                requestedPrograms.append(programID)
                let values: [Any]
                if programID == WalletSolanaTokenProgram.spl.programID {
                    values = [[
                        "pubkey": tokenAccount,
                        "account": [
                            "data": [
                                "program": "spl-token",
                                "parsed": [
                                    "type": "account",
                                    "info": [
                                        "isNative": false, "mint": mint,
                                        "owner": owner, "state": "initialized",
                                        "tokenAmount": [
                                            "amount": "18446744073709551615",
                                            "decimals": 6, "uiAmount": 1.25,
                                            "uiAmountString": "ignored",
                                        ],
                                    ],
                                ],
                                "space": 165,
                            ],
                            "executable": false, "lamports": 2_039_280,
                            "owner": programID, "space": 165,
                        ],
                    ]]
                } else {
                    values = []
                }
                result = ["context": ["slot": 42], "value": values]
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let accounts = try await client.tokenAccounts(owner: owner)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].amountBaseUnits, "18446744073709551615")
        XCTAssertEqual(accounts[0].decimals, 6)
        XCTAssertEqual(accounts[0].identity.mint, mint)
        XCTAssertEqual(Set(requestedPrograms), Set(
            WalletSolanaTokenProgram.allCases.map(\.programID)
        ))
    }

    func testSolanaDASCollectiblesValidateOwnershipAndExcludeActiveMedia() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let core = WalletSolanaBase58.encode(Data(repeating: 20, count: 32))
        let collection = WalletSolanaBase58.encode(Data(repeating: 21, count: 32))
        let compressed = WalletSolanaBase58.encode(Data(repeating: 22, count: 32))
        let tokenMetadata = WalletSolanaBase58.encode(Data(repeating: 27, count: 32))
        let unsupported = WalletSolanaBase58.encode(Data(repeating: 28, count: 32))
        let ownership: [String: Any] = [
            "ownership_model": "single", "owner": owner,
            "frozen": false, "delegated": false,
        ]
        func item(
            id: String, interface: String, compression: [String: Any],
            content: [String: Any], grouping: [[String: Any]] = []
        ) -> [String: Any] {
            [
                "id": id, "interface": interface, "burnt": false,
                "ownership": ownership, "compression": compression,
                "content": content, "grouping": grouping,
            ]
        }
        var wrongOwner = item(
            id: WalletSolanaBase58.encode(Data(repeating: 29, count: 32)),
            interface: "MplCoreAsset", compression: ["compressed": false],
            content: ["metadata": ["name": "Not Ours", "symbol": "NO"]]
        )
        wrongOwner["ownership"] = [
            "ownership_model": "single",
            "owner": WalletSolanaBase58.encode(Data(repeating: 31, count: 32)),
            "frozen": false, "delegated": false,
        ]
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getAssetsByOwner":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let query = try XCTUnwrap(params.first as? [String: Any])
                XCTAssertEqual(query["ownerAddress"] as? String, owner)
                XCTAssertEqual(query["page"] as? Int, 1)
                XCTAssertEqual(query["limit"] as? Int, 100)
                result = [
                    "total": 5, "page": 1, "limit": 100,
                    "items": [
                        item(
                            id: core, interface: "MplCoreAsset",
                            compression: ["compressed": false],
                            content: [
                                "metadata": ["name": "Core Asset", "symbol": "CORE"],
                                "json_uri": "https://metadata.example/core.json",
                                "files": [[
                                    "mime": "image/png",
                                    "uri": "https://images.example/core.png",
                                ]],
                            ],
                            grouping: [[
                                "group_key": "collection", "group_value": collection,
                            ]]
                        ),
                        item(
                            id: compressed, interface: "V1_NFT",
                            compression: [
                                "compressed": true,
                                "tree": WalletSolanaBase58.encode(
                                    Data(repeating: 23, count: 32)
                                ),
                                "data_hash": WalletSolanaBase58.encode(
                                    Data(repeating: 24, count: 32)
                                ),
                                "creator_hash": WalletSolanaBase58.encode(
                                    Data(repeating: 25, count: 32)
                                ),
                                "asset_hash": WalletSolanaBase58.encode(
                                    Data(repeating: 26, count: 32)
                                ),
                                "leaf_id": 3,
                            ],
                            content: [
                                "metadata": ["name": "Compressed", "symbol": "CNFT"],
                                "files": [],
                            ]
                        ),
                        item(
                            id: tokenMetadata, interface: "ProgrammableNFT",
                            compression: ["compressed": false],
                            content: [
                                "metadata": [
                                    "name": "Poisoned\u{0000}Name", "symbol": "PNFT",
                                ],
                                "json_uri": "javascript:alert(1)",
                                "files": [[
                                    "mime": "image/svg+xml",
                                    "uri": "https://images.example/active.svg",
                                ]],
                            ]
                        ),
                        item(
                            id: unsupported, interface: "Custom",
                            compression: [
                                "compressed": true,
                                "tree": WalletSolanaBase58.encode(
                                    Data(repeating: 32, count: 32)
                                ),
                                "data_hash": WalletSolanaBase58.encode(
                                    Data(repeating: 33, count: 32)
                                ),
                                "creator_hash": WalletSolanaBase58.encode(
                                    Data(repeating: 34, count: 32)
                                ),
                                "asset_hash": WalletSolanaBase58.encode(
                                    Data(repeating: 35, count: 32)
                                ),
                                "leaf_id": 4,
                            ],
                            content: ["metadata": ["name": "Unknown", "symbol": "?"]]
                        ),
                        wrongOwner,
                    ],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let collectibles = try await client.collectibles(owner: owner)
        XCTAssertEqual(collectibles.count, 3)
        XCTAssertEqual(
            Set(collectibles.map(\.identity.standard)),
            Set([.core, .bubblegum, .tokenMetadata])
        )
        let coreAsset = try XCTUnwrap(collectibles.first {
            $0.identity.address == core
        })
        XCTAssertEqual(coreAsset.collectionAddress, collection)
        XCTAssertEqual(coreAsset.metadataURL, "https://metadata.example/core.json")
        XCTAssertEqual(coreAsset.rasterImageURL, "https://images.example/core.png")
        let poisoned = try XCTUnwrap(collectibles.first {
            $0.identity.address == tokenMetadata
        })
        XCTAssertTrue(poisoned.name.hasPrefix("Collectible "))
        XCTAssertNil(poisoned.metadataURL)
        XCTAssertNil(poisoned.rasterImageURL)
    }

    func testSolanaDASRejectsTruncatedPagination() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            if method == "getGenesisHash" {
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            } else {
                XCTAssertEqual(method, "getAssetsByOwner")
                result = ["total": 1, "page": 1, "limit": 100, "items": []]
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        do {
            _ = try await client.collectibles(owner: owner)
            XCTFail("A provider must not silently truncate collectible holdings.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("truncated"))
        }
    }

    func testSolanaFinalizedActivityBindsSignatureBalancesTokensAndCore() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 8, count: 32))
        let tokenAccount = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let asset = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let signature = WalletSolanaBase58.encode(Data(repeating: 42, count: 64))
        let timestamp = UInt64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getSignaturesForAddress":
                let params = try XCTUnwrap(object["params"] as? [Any])
                XCTAssertEqual(params.first as? String, owner)
                let configuration = try XCTUnwrap(params[1] as? [String: Any])
                XCTAssertEqual(configuration["commitment"] as? String, "finalized")
                XCTAssertEqual(configuration["limit"] as? Int, 100)
                result = [[
                    "signature": signature, "slot": 42,
                    "blockTime": timestamp, "confirmationStatus": "finalized",
                    "err": NSNull(), "memo": NSNull(),
                ]]
            case "getTransaction":
                let params = try XCTUnwrap(object["params"] as? [Any])
                XCTAssertEqual(params.first as? String, signature)
                let configuration = try XCTUnwrap(params[1] as? [String: Any])
                XCTAssertEqual(configuration["encoding"] as? String, "jsonParsed")
                XCTAssertEqual(configuration["maxSupportedTransactionVersion"] as? Int, 1)
                let accountKeys: [[String: Any]] = [
                    ["pubkey": owner, "signer": true, "writable": true,
                     "source": "transaction"],
                    ["pubkey": recipient, "signer": false, "writable": false,
                     "source": "transaction"],
                    ["pubkey": tokenAccount, "signer": false, "writable": true,
                     "source": "transaction"],
                    ["pubkey": mint, "signer": false, "writable": false,
                     "source": "transaction"],
                    ["pubkey": WalletSolanaTokenProgram.spl.programID,
                     "signer": false, "writable": false, "source": "transaction"],
                    ["pubkey": asset, "signer": false, "writable": true,
                     "source": "transaction"],
                    ["pubkey": WalletSolanaCanonicalCoreTransfer.coreProgramID,
                     "signer": false, "writable": false, "source": "transaction"],
                ]
                let preToken: [[String: Any]] = [[
                    "accountIndex": 2, "mint": mint, "owner": owner,
                    "programId": WalletSolanaTokenProgram.spl.programID,
                    "uiTokenAmount": ["amount": "100", "decimals": 6],
                ]]
                let postToken: [[String: Any]] = [[
                    "accountIndex": 2, "mint": mint, "owner": owner,
                    "programId": WalletSolanaTokenProgram.spl.programID,
                    "uiTokenAmount": ["amount": "60", "decimals": 6],
                ]]
                result = [
                    "slot": 42, "blockTime": timestamp, "version": "legacy",
                    "transaction": [
                        "signatures": [signature],
                        "message": [
                            "accountKeys": accountKeys,
                            "instructions": [[
                                "programId": WalletSolanaCanonicalCoreTransfer
                                    .coreProgramID,
                                "accounts": [
                                    asset,
                                    WalletSolanaCanonicalCoreTransfer.coreProgramID,
                                    owner,
                                    WalletSolanaCanonicalCoreTransfer.coreProgramID,
                                    recipient,
                                    WalletSolanaCanonicalCoreTransfer.coreProgramID,
                                    WalletSolanaCanonicalCoreTransfer.coreProgramID,
                                ],
                                "data": WalletSolanaBase58.encode(Data([14, 0])),
                            ]],
                        ],
                    ],
                    "meta": [
                        "err": NSNull(), "fee": 5_000,
                        "preBalances": [1_000_000, 10, 20, 30, 1, 40, 1],
                        "postBalances": [990_000, 10, 20, 30, 1, 40, 1],
                        "preTokenBalances": preToken,
                        "postTokenBalances": postToken,
                        "innerInstructions": [], "logMessages": [],
                    ],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 4)
        XCTAssertEqual(activity.first?.id, "\(signature):transaction")
        XCTAssertEqual(
            activity.first(where: { $0.assetID
                == WalletNetworkCatalog.solanaDevnet.nativeAssetID
            })?.amountBaseUnits,
            "10000"
        )
        let tokenID = "solana:devnet/spl:\(mint)"
        XCTAssertEqual(activity.first(where: { $0.assetID == tokenID })?.direction,
                       .outbound)
        XCTAssertEqual(activity.first(where: { $0.assetID == tokenID })?.amountBaseUnits,
                       "40")
        let coreID = "solana:devnet/nft:core:\(asset)"
        XCTAssertEqual(activity.first(where: { $0.assetID == coreID })?.direction,
                       .outbound)
        XCTAssertEqual(activity.first(where: { $0.assetID == coreID })?.amountBaseUnits,
                       "1")
        XCTAssertTrue(activity.allSatisfy {
            $0.signature == signature && $0.slot == 42 && $0.successful
                && $0.feeBaseUnits == "5000"
        })
    }

    func testSolanaActivityKeepsGenericRecordForUnreviewedTokenProgram() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let tokenAccount = WalletSolanaBase58.encode(Data(repeating: 44, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 45, count: 32))
        let unknownProgram = WalletSolanaBase58.encode(Data(repeating: 46, count: 32))
        let signature = WalletSolanaBase58.encode(Data(repeating: 47, count: 64))
        let timestamp = UInt64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getSignaturesForAddress":
                result = [[
                    "signature": signature, "slot": 43,
                    "blockTime": timestamp, "confirmationStatus": "finalized",
                    "err": NSNull(), "memo": NSNull(),
                ]]
            case "getTransaction":
                let balance: (String) -> [[String: Any]] = { amount in [[
                    "accountIndex": 1, "mint": mint, "owner": owner,
                    "programId": unknownProgram,
                    "uiTokenAmount": ["amount": amount, "decimals": 0],
                ]] }
                result = [
                    "slot": 43, "blockTime": timestamp, "version": "legacy",
                    "transaction": [
                        "signatures": [signature],
                        "message": [
                            "accountKeys": [
                                ["pubkey": owner, "signer": true,
                                 "writable": true, "source": "transaction"],
                                ["pubkey": tokenAccount, "signer": false,
                                 "writable": true, "source": "transaction"],
                                ["pubkey": unknownProgram, "signer": false,
                                 "writable": false, "source": "transaction"],
                            ],
                            "instructions": [],
                        ],
                    ],
                    "meta": [
                        "err": NSNull(), "fee": 5_000,
                        "preBalances": [1_000_000, 10, 1],
                        "postBalances": [1_000_000, 10, 1],
                        "preTokenBalances": balance("100"),
                        "postTokenBalances": balance("60"),
                        "innerInstructions": [], "logMessages": [],
                    ],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 1)
        XCTAssertEqual(activity.first?.id, "\(signature):transaction")
        XCTAssertNil(activity.first?.assetID)
    }

    func testSolanaActivityValidatesV0LookupsAndV1ResourceLimits() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let table = WalletSolanaBase58.encode(Data(repeating: 49, count: 32))
        let loadedWritable = WalletSolanaBase58.encode(Data(repeating: 50, count: 32))
        let loadedReadonly = WalletSolanaBase58.encode(Data(repeating: 51, count: 32))
        let signature = WalletSolanaBase58.encode(Data(repeating: 52, count: 64))
        let timestamp = UInt64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        var responseVersion = 0
        var substituteEvidence = false
        var malformedResourceLimit = false
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getSignaturesForAddress":
                result = [[
                    "signature": signature, "slot": 44,
                    "blockTime": timestamp, "confirmationStatus": "finalized",
                    "err": NSNull(), "memo": NSNull(),
                ]]
            case "getTransaction":
                var message: [String: Any]
                var meta: [String: Any]
                if responseVersion == 0 {
                    message = [
                        "accountKeys": [
                            ["pubkey": owner, "signer": true,
                             "writable": true, "source": "transaction"],
                            ["pubkey": loadedWritable, "signer": false,
                             "writable": true, "source": "lookupTable"],
                            ["pubkey": loadedReadonly, "signer": false,
                             "writable": false, "source": "lookupTable"],
                        ],
                        "addressTableLookups": [[
                            "accountKey": table, "writableIndexes": [1],
                            "readonlyIndexes": [2],
                        ]],
                        "instructions": [],
                    ]
                    meta = [
                        "err": NSNull(), "fee": 5_000,
                        "preBalances": [1_000_000, 10, 20],
                        "postBalances": [1_000_000, 10, 20],
                        "preTokenBalances": [], "postTokenBalances": [],
                        "innerInstructions": [], "logMessages": [],
                        "loadedAddresses": [
                            "writable": [loadedWritable],
                            "readonly": substituteEvidence
                                ? [loadedWritable] : [loadedReadonly],
                        ],
                    ]
                } else {
                    message = [
                        "accountKeys": [[
                            "pubkey": owner, "signer": true,
                            "writable": true, "source": "transaction",
                        ]],
                        "transactionConfig": [
                            "computeUnitLimit": 30_000, "heapSize": NSNull(),
                            "loadedAccountsDataSizeLimit": 200_000,
                            "priorityFee": malformedResourceLimit
                                ? "5000" : NSNull(),
                        ],
                        "instructions": [],
                    ]
                    if substituteEvidence { message["addressTableLookups"] = [] }
                    meta = [
                        "err": NSNull(), "fee": 5_000,
                        "preBalances": [1_000_000],
                        "postBalances": [1_000_000],
                        "preTokenBalances": [], "postTokenBalances": [],
                        "innerInstructions": [], "logMessages": [],
                    ]
                }
                result = [
                    "slot": 44, "blockTime": timestamp,
                    "version": responseVersion,
                    "transaction": [
                        "signatures": [signature], "message": message,
                    ],
                    "meta": meta,
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        var activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 1)
        substituteEvidence = true
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("Substituted v0 loaded addresses must reject the batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("substituted or reordered"))
        }
        responseVersion = 1
        substituteEvidence = false
        activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 1)
        substituteEvidence = true
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("A v1 transaction must not carry address-table evidence.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("v1 Solana activity"))
        }
        substituteEvidence = false
        malformedResourceLimit = true
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("A v1 resource limit must use its canonical integer form.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("resource limits"))
        }
    }

    func testSolanaActivityCapPreservesEveryFetchedTransactionRecord() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let timestamp = UInt64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        let signatures = (0..<500).map { index in
            var value = UInt64(index).bigEndian
            var bytes = withUnsafeBytes(of: &value) { Data($0) }
            bytes.append(Data(repeating: 48, count: 56))
            return WalletSolanaBase58.encode(bytes)
        }
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getSignaturesForAddress":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let configuration = try XCTUnwrap(params[1] as? [String: Any])
                let before = configuration["before"] as? String
                let start = before.flatMap {
                    signatures.firstIndex(of: $0)
                }.map { $0 + 1 } ?? 0
                let limit = try XCTUnwrap(configuration["limit"] as? Int)
                result = signatures.dropFirst(start).prefix(limit).enumerated().map {
                    offset, signature in
                    [
                        "signature": signature,
                        "slot": 1_000 - start - offset,
                        "blockTime": timestamp,
                        "confirmationStatus": "finalized",
                        "err": NSNull(), "memo": NSNull(),
                    ] as [String: Any]
                }
            case "getTransaction":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let signature = try XCTUnwrap(params.first as? String)
                let index = try XCTUnwrap(signatures.firstIndex(of: signature))
                result = [
                    "slot": 1_000 - index, "blockTime": timestamp,
                    "version": "legacy",
                    "transaction": [
                        "signatures": [signature],
                        "message": [
                            "accountKeys": [[
                                "pubkey": owner, "signer": true,
                                "writable": true, "source": "transaction",
                            ]],
                            "instructions": [],
                        ],
                    ],
                    "meta": [
                        "err": NSNull(), "fee": 1,
                        "preBalances": [100], "postBalances": [99],
                        "preTokenBalances": [], "postTokenBalances": [],
                        "innerInstructions": [], "logMessages": [],
                    ],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let activity = try await client.activity(owner: owner)
        XCTAssertEqual(activity.count, 500)
        XCTAssertEqual(Set(activity.map(\.signature)).count, 500)
        XCTAssertTrue(activity.allSatisfy { $0.id.hasSuffix(":transaction") })
    }

    func testSolanaActivityRejectsDuplicateAndSubstitutedEvidence() async throws {
        let owner = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let signature = WalletSolanaBase58.encode(Data(repeating: 43, count: 64))
        let timestamp = UInt64(Date().addingTimeInterval(-60).timeIntervalSince1970)
        var duplicate = true
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getSignaturesForAddress":
                let row: [String: Any] = [
                    "signature": signature, "slot": 42, "blockTime": timestamp,
                    "confirmationStatus": "finalized", "err": NSNull(),
                    "memo": NSNull(),
                ]
                result = duplicate ? [row, row] : [row]
            case "getTransaction":
                result = [
                    "slot": 41, "blockTime": timestamp, "version": "legacy",
                    "transaction": [
                        "signatures": [signature],
                        "message": ["accountKeys": [], "instructions": []],
                    ],
                    "meta": [
                        "err": NSNull(), "fee": 5_000,
                        "preBalances": [], "postBalances": [],
                        "preTokenBalances": [], "postTokenBalances": [],
                    ],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("Duplicate finalized signatures must reject the batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("duplicated"))
        }
        duplicate = false
        do {
            _ = try await client.activity(owner: owner)
            XCTFail("A transaction from another slot must reject the batch.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("mismatched finalized evidence"))
        }
    }

    func testSolanaProviderPreparesAndRechecksOnlyVerifiedSPLAccounts() async throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let source = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let destination = "DUJre3jPyHZAAuoWaaqRQgJ6DjyKTaXVXKMH3bpLV8Kb"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let assetID = "solana:devnet/spl:\(mint)"
        var sourceAmount = "999999999"
        var destinationOccupied = false
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getAccountInfo":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let address = try XCTUnwrap(params[0] as? String)
                if address == mint {
                    result = [
                        "context": ["slot": 42],
                        "value": [
                            "data": [
                                "program": "spl-token",
                                "parsed": [
                                    "type": "mint",
                                    "info": ["decimals": 6, "isInitialized": true],
                                ],
                                "space": 82,
                            ],
                            "executable": false, "lamports": 1_461_600,
                            "owner": WalletSolanaTokenProgram.spl.programID,
                            "space": 82,
                        ],
                    ]
                } else {
                    XCTAssertEqual(address, destination)
                    let configuration = try XCTUnwrap(params[1] as? [String: Any])
                    XCTAssertEqual(configuration["encoding"] as? String, "base64")
                    result = [
                        "context": ["slot": 42],
                        "value": destinationOccupied
                            ? (["owner": "attacker"] as Any)
                            : (NSNull() as Any),
                    ]
                }
            case "getTokenAccountsByOwner":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let owner = try XCTUnwrap(params[0] as? String)
                let filter = try XCTUnwrap(params[1] as? [String: Any])
                let programID = try XCTUnwrap(filter["programId"] as? String)
                let values: [Any]
                if programID != WalletSolanaTokenProgram.spl.programID {
                    values = []
                } else if owner == payer {
                    values = [self.solanaTokenAccountJSON(
                        address: source, mint: mint, owner: payer,
                        amount: sourceAmount, decimals: 6, programID: programID
                    )]
                } else if owner == recipient {
                    values = []
                } else {
                    values = []
                }
                result = ["context": ["slot": 42], "value": values]
            case "getLatestBlockhash":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "blockhash": blockhash, "lastValidBlockHeight": 500,
                    ],
                ]
            case "getFeeForMessage":
                result = ["context": ["slot": 42], "value": 5_000]
            case "getRecentPrioritizationFees":
                result = [["slot": 42, "prioritizationFee": 0]]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "err": NSNull(), "innerInstructions": [],
                        "logs": ["Program Tokenkeg success"], "unitsConsumed": 2_000,
                    ],
                ]
            case "getBlockHeight":
                result = 450
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .fungibleTokenTransfer(
                assetID: assetID, recipient: recipient,
                amountBaseUnits: "123456789"
            ),
            maximumFeeBaseUnits: "6000"
        )
        let packet = try await client.prepare(
            request: request, feePayer: payer,
            recipientAssociatedTokenAddress: destination
        )
        XCTAssertEqual(packet.canonicalMessageDigest,
                       "sha256:ce71b30c644741f4113ae3e8f038d81eaeeed2d8ac3f390e1bec0782320a1ad0")
        XCTAssertEqual(packet.computeUnitLimit, 2_200)
        XCTAssertEqual(packet.computeUnitPriceMicroLamports, "0")
        XCTAssertEqual(packet.instructions.count, 2)
        XCTAssertEqual(
            packet.instructions[0].adapterID,
            WalletReviewedAdapters.solanaAssociatedTokenCreateIdempotent
        )
        XCTAssertEqual(
            packet.instructions[1].adapterID,
            WalletReviewedAdapters.solanaSPLTransferChecked
        )
        XCTAssertEqual(packet.instructions[1].canonicalArguments["decimals"], "6")
        let recheck = try await client.recheck(intentID: "spl-intent", packet: packet)
        XCTAssertEqual(recheck.resolvedAccountsDigest, packet.resolvedAccountsDigest)

        sourceAmount = "1"
        do {
            _ = try await client.recheck(intentID: "spl-intent", packet: packet)
            XCTFail("A substituted or depleted SPL source account must be rejected.")
        } catch WalletRPCError.simulation(let message) {
            XCTAssertTrue(message.contains("evidence changed"))
        }

        sourceAmount = "999999999"
        destinationOccupied = true
        do {
            _ = try await client.prepare(
                request: request, feePayer: payer,
                recipientAssociatedTokenAddress: destination
            )
            XCTFail("An occupied unverified associated address must be rejected.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("already occupied"))
        }
    }

    func testSolanaProviderAllowsOnlySafeToken2022ExtensionSubset() async throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let source = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let destination = "9dTDtNrTEkkDWLkvXLLQfmsJ7wFcuk7DCf6nN53i1Dt"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let assetID = "solana:devnet/token2022:\(mint)"
        var unsafeMintExtension = false
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getAccountInfo":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let address = try XCTUnwrap(params[0] as? String)
                if address == mint {
                    let extensions: [[String: Any]] = unsafeMintExtension
                        ? [["extension": "transferFeeConfig", "state": [:]]]
                        : [
                            ["extension": "tokenMetadata", "state": [:]],
                            ["extension": "metadataPointer", "state": [:]],
                        ]
                    result = [
                        "context": ["slot": 42],
                        "value": [
                            "data": [
                                "program": WalletSolanaTokenProgram.token2022
                                    .parsedProgramName,
                                "parsed": [
                                    "type": "mint",
                                    "info": [
                                        "decimals": 6, "isInitialized": true,
                                        "extensions": extensions,
                                    ],
                                ],
                                "space": 256,
                            ],
                            "executable": false, "lamports": 2_000_000,
                            "owner": WalletSolanaTokenProgram.token2022.programID,
                            "space": 256,
                        ],
                    ]
                } else {
                    XCTAssertEqual(address, destination)
                    result = ["context": ["slot": 42], "value": NSNull()]
                }
            case "getTokenAccountsByOwner":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let owner = try XCTUnwrap(params[0] as? String)
                let filter = try XCTUnwrap(params[1] as? [String: Any])
                let programID = try XCTUnwrap(filter["programId"] as? String)
                let values: [Any]
                if programID == WalletSolanaTokenProgram.token2022.programID,
                   owner == payer {
                    values = [self.solanaTokenAccountJSON(
                        address: source, mint: mint, owner: payer,
                        amount: "999999999", decimals: 6, programID: programID,
                        extensions: [["extension": "immutableOwner"]]
                    )]
                } else {
                    values = []
                }
                result = ["context": ["slot": 42], "value": values]
            case "getLatestBlockhash":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "blockhash": blockhash, "lastValidBlockHeight": 500,
                    ],
                ]
            case "getFeeForMessage":
                result = ["context": ["slot": 42], "value": 5_000]
            case "getRecentPrioritizationFees":
                result = [["slot": 42, "prioritizationFee": 0]]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "err": NSNull(), "innerInstructions": [],
                        "logs": ["Program TokenzQd success"],
                        "unitsConsumed": 3_000,
                    ],
                ]
            case "getBlockHeight":
                result = 450
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .fungibleTokenTransfer(
                assetID: assetID, recipient: recipient,
                amountBaseUnits: "123456789"
            ),
            maximumFeeBaseUnits: "6000"
        )
        let packet = try await client.prepare(
            request: request, feePayer: payer,
            recipientAssociatedTokenAddress: destination
        )
        XCTAssertEqual(
            packet.canonicalMessageDigest,
            "sha256:0df481d3222a4bc61d33e4c14b0e4df81cc96e899200f02c263b86f2c47bf447"
        )
        XCTAssertEqual(packet.computeUnitLimit, 3_300)
        XCTAssertEqual(packet.computeUnitPriceMicroLamports, "0")
        XCTAssertEqual(
            packet.instructions.last?.adapterID,
            WalletReviewedAdapters.solanaToken2022TransferChecked
        )
        XCTAssertEqual(
            packet.instructions.last?.canonicalArguments["mint_extensions"],
            "metadataPointer,tokenMetadata"
        )
        XCTAssertEqual(
            packet.instructions.last?.canonicalArguments["source_extensions"],
            "immutableOwner"
        )
        _ = try await client.recheck(intentID: "token-2022", packet: packet)

        unsafeMintExtension = true
        do {
            _ = try await client.prepare(
                request: request, feePayer: payer,
                recipientAssociatedTokenAddress: destination
            )
            XCTFail("Transfer-fee Token-2022 mints must remain unsignable.")
        } catch WalletGateway.Error.policyDenied(let message) {
            XCTAssertTrue(message.contains("change reviewed transfer semantics"))
        }
    }

    func testSolanaProviderPreparesAndRechecksOnlyPluginFreeCoreAssets() async throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let asset = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 8, count: 32))
        let authority = WalletSolanaBase58.encode(Data(repeating: 10, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let assetID = "solana:devnet/nft:core:\(asset)"
        let before = try solanaCoreAssetData(owner: payer, updateAuthority: authority)
        let after = try solanaCoreAssetData(owner: recipient, updateAuthority: authority)
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getAccountInfo":
                result = [
                    "context": ["slot": 44],
                    "value": self.solanaCoreAccountJSON(data: before),
                ]
            case "getLatestBlockhash":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "blockhash": blockhash, "lastValidBlockHeight": 500,
                    ],
                ]
            case "getFeeForMessage":
                result = ["context": ["slot": 42], "value": 5_000]
            case "getRecentPrioritizationFees":
                result = [["slot": 42, "prioritizationFee": 0]]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 45],
                    "value": [
                        "err": NSNull(),
                        "accounts": [self.solanaCoreAccountJSON(data: after)],
                        "innerInstructions": [],
                        "logs": ["Program CoREEN success"],
                        "unitsConsumed": 4_000,
                    ],
                ]
            case "getBlockHeight":
                result = 450
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .nftTransfer(
                assetID: assetID, tokenID: asset, recipient: recipient
            ),
            maximumFeeBaseUnits: "6000"
        )
        let packet = try await client.prepare(request: request, feePayer: payer)
        XCTAssertEqual(packet.contextSlot, 44)
        XCTAssertEqual(packet.instructions.count, 1)
        XCTAssertEqual(
            packet.instructions[0].adapterID,
            WalletReviewedAdapters.solanaCoreTransfer
        )
        XCTAssertEqual(packet.instructions[0].canonicalArguments["plugins"], "none")
        XCTAssertEqual(
            packet.instructions[0].canonicalArguments["update_authority"],
            authority
        )
        let recheck = try await client.recheck(intentID: "core-intent", packet: packet)
        XCTAssertEqual(recheck.resolvedAccountsDigest, packet.resolvedAccountsDigest)
        XCTAssertTrue(recheck.simulation.contains("owner transition succeeded"))
    }

    func testSolanaCoreProviderRejectsPluginsCollectionsAndChangedPostState() async throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let asset = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 8, count: 32))
        let authority = WalletSolanaBase58.encode(Data(repeating: 10, count: 32))
        let substitutedAuthority = WalletSolanaBase58.encode(
            Data(repeating: 11, count: 32)
        )
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let assetID = "solana:devnet/nft:core:\(asset)"
        var before = try solanaCoreAssetData(owner: payer, updateAuthority: authority)
        var after = try solanaCoreAssetData(owner: recipient, updateAuthority: authority)
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getAccountInfo":
                result = [
                    "context": ["slot": 44],
                    "value": self.solanaCoreAccountJSON(data: before),
                ]
            case "getLatestBlockhash":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "blockhash": blockhash, "lastValidBlockHeight": 500,
                    ],
                ]
            case "getFeeForMessage":
                result = ["context": ["slot": 42], "value": 5_000]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 45],
                    "value": [
                        "err": NSNull(),
                        "accounts": [self.solanaCoreAccountJSON(data: after)],
                        "innerInstructions": [], "logs": [],
                        "unitsConsumed": 4_000,
                    ],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .nftTransfer(
                assetID: assetID, tokenID: asset, recipient: recipient
            ),
            maximumFeeBaseUnits: "6000"
        )

        before.append(1)
        do {
            _ = try await client.prepare(request: request, feePayer: payer)
            XCTFail("A plugin-bearing Core account must remain read-only.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("Plugin-bearing"))
        }

        before = try solanaCoreAssetData(
            owner: payer, updateAuthority: nil,
            collection: WalletSolanaBase58.encode(Data(repeating: 12, count: 32))
        )
        do {
            _ = try await client.prepare(request: request, feePayer: payer)
            XCTFail("A collection-backed Core account must remain read-only.")
        } catch WalletRPCError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("Collection-backed"))
        }

        before = try solanaCoreAssetData(owner: payer, updateAuthority: authority)
        after = try solanaCoreAssetData(
            owner: recipient, updateAuthority: substitutedAuthority
        )
        do {
            _ = try await client.prepare(request: request, feePayer: payer)
            XCTFail("A simulated update-authority substitution must be rejected.")
        } catch WalletRPCError.simulation(let message) {
            XCTAssertTrue(message.contains("changed update authority"))
        }
    }

    func testSolanaProviderBindsGenesisBlockhashFeeSimulationAndRecheck() async throws {
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        var currentBlockHeight = 450
        var feeRequestCount = 0
        var substitutedFee = false
        let client = makeSolanaRPCClient { request in
            let body = try walletRPCRequestBody(request)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let id = try XCTUnwrap(object["id"] as? NSNumber)
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getLatestBlockhash":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "blockhash": blockhash,
                        "lastValidBlockHeight": 500,
                    ],
                ]
            case "getFeeForMessage":
                feeRequestCount += 1
                result = [
                    "context": ["slot": 42],
                    "value": feeRequestCount == 1
                        ? 5_000 : (substitutedFee ? 5_024 : 5_025),
                ]
            case "getRecentPrioritizationFees":
                let params = try XCTUnwrap(object["params"] as? [Any])
                let writableAccounts = try XCTUnwrap(params[0] as? [String])
                XCTAssertEqual(writableAccounts, [
                    "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
                    recipient,
                ])
                result = [
                    ["slot": 42, "prioritizationFee": 40_000],
                    ["slot": 41, "prioritizationFee": 30_000],
                    ["slot": 40, "prioritizationFee": 20_000],
                    ["slot": 39, "prioritizationFee": 10_000],
                ]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "err": NSNull(), "innerInstructions": [],
                        "logs": ["Program 11111111111111111111111111111111 success"],
                        "unitsConsumed": 750,
                    ],
                ]
            case "getBlockHeight":
                result = currentBlockHeight
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "result": result,
            ])
        }
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .nativeTransfer(
                recipient: recipient, amountBaseUnits: "123456789"
            ),
            maximumFeeBaseUnits: "6000"
        )
        let packet = try await client.prepare(
            request: request,
            feePayer: "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        )
        XCTAssertEqual(packet.genesisHash, WalletNetworkCatalog.solanaDevnet.identity.value)
        XCTAssertEqual(packet.version, .legacy)
        XCTAssertEqual(packet.recentBlockhash, blockhash)
        XCTAssertEqual(packet.feeQuoteBaseUnits, "5025")
        XCTAssertEqual(packet.computeUnitLimit, 825)
        XCTAssertEqual(packet.computeUnitPriceMicroLamports, "30000")
        XCTAssertEqual(packet.priorityFeeBaseUnits, "25")
        XCTAssertEqual(
            packet.canonicalMessageDigest,
            "sha256:d8a487a5cba7e2c33f0d4eebf8e79f64e9cff82034ab8ab6bb30968af6868efa"
        )
        XCTAssertEqual(packet.instructions.count, 1)
        XCTAssertEqual(
            packet.instructions[0].adapterID,
            WalletReviewedAdapters.solanaNativeTransfer
        )

        let recheck = try await client.recheck(intentID: "intent-sol", packet: packet)
        XCTAssertEqual(recheck.intentID, "intent-sol")
        XCTAssertEqual(recheck.currentBlockHeight, 450)
        XCTAssertEqual(recheck.resolvedAccountsDigest, packet.resolvedAccountsDigest)
        XCTAssertTrue(recheck.simulationSucceeded)

        substitutedFee = true
        do {
            _ = try await client.recheck(intentID: "intent-sol", packet: packet)
            XCTFail("A changed fee for the exact prepared message must be rejected.")
        } catch WalletRPCError.simulation(let message) {
            XCTAssertTrue(message.contains("fee changed"))
        }
        substitutedFee = false
        currentBlockHeight = 501
        do {
            _ = try await client.recheck(intentID: "intent-sol", packet: packet)
            XCTFail("A stale Solana blockhash must be rejected before signing.")
        } catch WalletRPCError.simulation(let message) {
            XCTAssertTrue(message.contains("expired"))
        }
    }

    func testSolanaPriorityFeeIsCappedByTheExactUserMaximum() async throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        var feeRequestCount = 0
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            let method = try XCTUnwrap(object["method"] as? String)
            let result: Any
            switch method {
            case "getGenesisHash":
                result = WalletNetworkCatalog.solanaDevnet.identity.value
            case "getLatestBlockhash":
                result = [
                    "context": ["slot": 42],
                    "value": ["blockhash": blockhash, "lastValidBlockHeight": 500],
                ]
            case "getFeeForMessage":
                feeRequestCount += 1
                result = [
                    "context": ["slot": 42],
                    "value": feeRequestCount == 1 ? 5_000 : 5_010,
                ]
            case "getRecentPrioritizationFees":
                result = [["slot": 42, "prioritizationFee": 40_000]]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "err": NSNull(), "innerInstructions": [], "logs": [],
                        "unitsConsumed": 750,
                    ],
                ]
            case "getBlockHeight":
                result = 450
            default:
                throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": result,
            ])
        }
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .nativeTransfer(
                recipient: recipient, amountBaseUnits: "123456789"
            ),
            maximumFeeBaseUnits: "5010"
        )
        let packet = try await client.prepare(request: request, feePayer: payer)
        XCTAssertEqual(packet.computeUnitLimit, 825)
        XCTAssertEqual(packet.computeUnitPriceMicroLamports, "12121")
        XCTAssertEqual(packet.priorityFeeBaseUnits, "10")
        XCTAssertEqual(packet.feeQuoteBaseUnits, "5010")
        _ = try await client.recheck(intentID: "capped-priority", packet: packet)
    }

    func testSolanaProviderRejectsMaliciousGenesisBeforePreparation() async throws {
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!,
                "result": "WrongGenesis111111111111111111111111111111",
            ])
        }
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let request = WalletPrepareRequest(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .human,
            action: .nativeTransfer(recipient: recipient, amountBaseUnits: "1"),
            maximumFeeBaseUnits: "5000"
        )
        do {
            _ = try await client.prepare(
                request: request,
                feePayer: "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
            )
            XCTFail("A mismatched Solana genesis must fail before message preparation.")
        } catch WalletRPCError.wrongChain(let identity) {
            XCTAssertTrue(identity.hasPrefix("WrongGenesis"))
        }
    }

    func testSolanaBroadcastBindsTransactionIDToFirstSignature() async throws {
        let signature = Data(repeating: 5, count: 64)
        let transactionID = WalletSolanaBase58.encode(signature)
        var signed = Data([1])
        signed.append(signature)
        signed.append(0)
        let client = makeSolanaRPCClient { request in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: walletRPCRequestBody(request)
                ) as? [String: Any]
            )
            return try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": object["id"]!, "result": transactionID,
            ])
        }
        let result = try await client.broadcast(
            signedTransaction: signed.base64EncodedString(),
            expectedTransactionID: transactionID,
            minimumContextSlot: 42
        )
        XCTAssertEqual(result, transactionID)

        var substituted = signed
        substituted[1] = 6
        do {
            _ = try await client.broadcast(
                signedTransaction: substituted.base64EncodedString(),
                expectedTransactionID: transactionID,
                minimumContextSlot: 42
            )
            XCTFail("A transaction ID that is not the first signature must be rejected.")
        } catch WalletGateway.Error.invalidArguments {
            // Expected before any broadcast attempt.
        }
    }

    func testGatewayPreparesHumanSOLTransferThroughSemanticPath() async {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        signer.adapterID = WalletReviewedAdapters.solanaNativeTransfer
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"]
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let prepared = await gateway.prepareHumanNativeTransfer(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "account-1", recipient: recipient,
            amountBaseUnits: "1000", maximumFeeBaseUnits: "5000"
        )
        XCTAssertTrue(prepared)
        XCTAssertEqual(signer.preparedRequests.last?.networkID, "solana:devnet")
        XCTAssertEqual(signer.preparedRequests.last?.action.amountBaseUnits, "1000")
        XCTAssertEqual(gateway.pendingConfirmation?.source, .human)
    }

    func testGatewayRefreshesSOLBalanceAndFinalizedActivity() async {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        signer.adapterID = WalletReviewedAdapters.solanaNativeTransfer
        signer.balanceBaseUnits = "123456789"
        let suiteName = "WalletGatewayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        XCTAssertEqual(gateway.accountSnapshots.first?.balanceBaseUnits, "123456789")

        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let prepared = await gateway.prepareHumanNativeTransfer(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "account-1", recipient: recipient,
            amountBaseUnits: "1000", maximumFeeBaseUnits: "5000"
        )
        XCTAssertTrue(prepared)
        let executed = await gateway.confirmAndExecuteHumanIntent(intentID: "intent-1")
        XCTAssertTrue(executed)
        XCTAssertEqual(gateway.transactionHistory.first?.networkID, "solana:devnet")
        signer.browserRPCResponse = [
            "context": ["slot": 100],
            "value": [[
                "slot": 99, "confirmationStatus": "finalized", "err": NSNull(),
            ]],
        ]
        await gateway.refreshTransactionHistory()
        XCTAssertEqual(gateway.transactionHistory.first?.state, .confirmed)
        XCTAssertEqual(gateway.transactionHistory.first?.finality, .finalized)
        XCTAssertEqual(gateway.transactionHistory.first?.blockNumber, "99")
    }

    func testGatewayQuarantinesDiscoveredSolanaTokensUntilExplicitTrust() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let mint = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let assetID = "solana:devnet/spl:\(mint)"
        signer.discoveredAssetRows = [[
            "asset_id": assetID, "mint": mint, "token_program": "spl",
            "balance_base_units": "420000000000000", "decimals": 6,
            "account_count": 1, "has_frozen_account": false,
        ]]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        XCTAssertEqual(gateway.assets.first(where: { $0.id == assetID })?.trust, .quarantined)
        XCTAssertFalse(gateway.accountSnapshots.contains { $0.assetID == assetID })

        gateway.trustQuarantinedAsset(id: assetID)
        await gateway.refreshAccountSnapshots()
        let snapshot = try XCTUnwrap(
            gateway.accountSnapshots.first(where: { $0.assetID == assetID })
        )
        XCTAssertEqual(snapshot.balanceBaseUnits, "420000000000000")
        XCTAssertEqual(snapshot.freshness, .current)
    }

    func testGatewayQuarantinesDiscoveredSolanaCollectiblesUntilExplicitTrust() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let address = WalletSolanaBase58.encode(Data(repeating: 30, count: 32))
        let assetID = "solana:devnet/nft:core:\(address)"
        signer.discoveredAssetRows = [[
            "asset_id": assetID,
            "asset_kind": WalletAssetKind.collectible.rawValue,
            "collectible_standard": WalletSolanaCollectibleStandard.core.rawValue,
            "reference": address, "name": "Unknown Core Asset",
            "symbol": "CORE", "balance_base_units": "1", "decimals": 0,
            "account_count": 1, "has_frozen_account": false,
            "delegated": false,
        ]]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let quarantined = try XCTUnwrap(gateway.assets.first {
            $0.id == assetID
        })
        XCTAssertEqual(quarantined.kind, .collectible)
        XCTAssertEqual(quarantined.trust, .quarantined)
        XCTAssertFalse(gateway.accountSnapshots.contains { $0.assetID == assetID })

        gateway.trustQuarantinedAsset(id: assetID)
        await gateway.refreshAccountSnapshots()
        let snapshot = try XCTUnwrap(gateway.accountSnapshots.first {
            $0.assetID == assetID
        })
        XCTAssertEqual(snapshot.balanceBaseUnits, "1")
        XCTAssertEqual(snapshot.freshness, .current)
    }

    func testGatewayPreparesOnlyExplicitlyTrustedClassicSPLToken() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        signer.adapterID = WalletReviewedAdapters.solanaSPLTransferChecked
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let assetID = "solana:devnet/spl:\(mint)"
        signer.discoveredAssetRows = [[
            "asset_id": assetID, "mint": mint, "token_program": "spl",
            "balance_base_units": "999999999", "decimals": 6,
            "account_count": 1, "has_frozen_account": false,
        ]]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let quarantined = await gateway.prepareHumanFungibleTransfer(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "account-1", assetID: assetID, recipient: recipient,
            amountBaseUnits: "123456789", maximumFeeBaseUnits: "6000"
        )
        XCTAssertFalse(quarantined)
        gateway.trustQuarantinedAsset(id: assetID)
        let trusted = await gateway.prepareHumanFungibleTransfer(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "account-1", assetID: assetID, recipient: recipient,
            amountBaseUnits: "123456789", maximumFeeBaseUnits: "6000"
        )
        XCTAssertTrue(trusted)
        XCTAssertEqual(signer.preparedRequests.last?.action.assetID, assetID)
        XCTAssertEqual(
            signer.preparedRequests.last?.action.type,
            .fungibleTokenTransfer
        )
        XCTAssertEqual(gateway.pendingConfirmation?.source, .human)
    }

    func testGatewayPreparesExplicitlyTrustedToken2022ThroughReviewedPath() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        signer.accountAddress = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        signer.adapterID = WalletReviewedAdapters.solanaToken2022TransferChecked
        let mint = WalletSolanaBase58.encode(Data(repeating: 6, count: 32))
        let assetID = "solana:devnet/token2022:\(mint)"
        signer.discoveredAssetRows = [[
            "asset_id": assetID, "mint": mint,
            "token_program": WalletSolanaTokenProgram.token2022.rawValue,
            "balance_base_units": "999999999", "decimals": 6,
            "account_count": 1, "has_frozen_account": false,
        ]]
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            publicStore: try WalletPublicStore(path: ":memory:")
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        gateway.trustQuarantinedAsset(id: assetID)
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let prepared = await gateway.prepareHumanFungibleTransfer(
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "account-1", assetID: assetID, recipient: recipient,
            amountBaseUnits: "123456789", maximumFeeBaseUnits: "6000"
        )
        XCTAssertTrue(prepared)
        XCTAssertEqual(signer.preparedRequests.last?.action.assetID, assetID)
        XCTAssertEqual(
            signer.preparedRequests.last?.action.type,
            .fungibleTokenTransfer
        )
    }

    private func solanaCoreAssetData(
        owner: String,
        updateAuthority: String?,
        collection: String? = nil
    ) throws -> Data {
        guard let ownerBytes = WalletSolanaBase58.decode(owner, exactLength: 32) else {
            throw URLError(.cannotDecodeContentData)
        }
        var data = Data([1])
        data.append(ownerBytes)
        if let collection {
            guard let collectionBytes = WalletSolanaBase58.decode(
                collection, exactLength: 32
            ) else {
                throw URLError(.cannotDecodeContentData)
            }
            data.append(2)
            data.append(collectionBytes)
        } else if let updateAuthority {
            guard let authorityBytes = WalletSolanaBase58.decode(
                updateAuthority, exactLength: 32
            ) else {
                throw URLError(.cannotDecodeContentData)
            }
            data.append(1)
            data.append(authorityBytes)
        } else {
            data.append(0)
        }
        for value in ["Core Asset", "https://metadata.example/core.json"] {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).littleEndian
            Swift.withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        data.append(0) // Borsh Option<u64>::None sequence number.
        return data
    }

    private func solanaCoreAccountJSON(data: Data) -> [String: Any] {
        [
            "data": [data.base64EncodedString(), "base64"],
            "executable": false, "lamports": 2_000_000,
            "owner": WalletSolanaCanonicalCoreTransfer.coreProgramID,
            "space": data.count,
        ]
    }

    private func makeRPCClient(
        response: @escaping (URLRequest) throws -> Data
    ) -> WalletSepoliaRPCClient {
        WalletRPCURLProtocol.handler = { request in (200, try response(request)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WalletRPCURLProtocol.self]
        return WalletSepoliaRPCClient(
            endpoint: "https://wallet-rpc.test", session: URLSession(configuration: configuration)
        )
    }

    private func makeAlchemyEVMRPCClient(
        response: @escaping (URLRequest) throws -> Data
    ) throws -> WalletSepoliaRPCClient {
        WalletRPCURLProtocol.handler = { request in (200, try response(request)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WalletRPCURLProtocol.self]
        return try WalletSepoliaRPCClient(
            network: WalletNetworkCatalog.ethereumSepolia,
            endpoint: "https://eth-sepolia.g.alchemy.com/v2/test_key-123",
            session: URLSession(configuration: configuration)
        )
    }

    private func makeSolanaRPCClient(
        response: @escaping (URLRequest) throws -> Data
    ) -> WalletSolanaRPCClient {
        WalletRPCURLProtocol.handler = { request in (200, try response(request)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WalletRPCURLProtocol.self]
        return try! WalletSolanaRPCClient(
            network: WalletNetworkCatalog.solanaDevnet,
            endpoint: "https://solana-wallet-rpc.test",
            session: URLSession(configuration: configuration)
        )
    }

    private func makeSuiGraphQLClient(
        network: WalletNetworkDescriptor = WalletNetworkCatalog.suiTestnet,
        now: Date,
        paddedWireTypes: Bool = true,
        response: @escaping (URLRequest) throws -> Data
    ) -> WalletSuiGraphQLClient {
        WalletRPCURLProtocol.handler = { request in
            let data = try response(request)
            guard paddedWireTypes,
                  let object = try? JSONSerialization.jsonObject(with: data) else { return (200, data) }
            return (200, try JSONSerialization.data(withJSONObject: Self.suiOfficialWireRepresentations(object)))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WalletRPCURLProtocol.self]
        return try! WalletSuiGraphQLClient(
            network: network,
            endpoint: "https://sui-wallet-graphql.test/graphql",
            session: URLSession(configuration: configuration),
            now: { now }
        )
    }

    // The real GraphQL server emits padded addresses in every MoveType.repr,
    // including nested Coin<T>, simulation, and indexed activity. Keep outgoing
    // requests and expected internal identities unchanged. Invalid fixture
    // spellings (including partial leading-zero padding) are never repaired.
    private static func suiOfficialWireRepresentations(_ value: Any) -> Any {
        if let values = value as? [Any] { return values.map(suiOfficialWireRepresentations) }
        guard let object = value as? [String: Any] else { return value }
        var result: [String: Any] = [:]
        for (key, field) in object {
            guard key == "repr", let type = field as? String else {
                result[key] = suiOfficialWireRepresentations(field)
                continue
            }
            let expression = try! NSRegularExpression(pattern: "0x(?:0|[1-9a-f][0-9a-f]{0,63})(?=::)")
            let padded = NSMutableString(string: type)
            for match in expression.matches(in: type, range: NSRange(type.startIndex..., in: type)).reversed() {
                let address = (type as NSString).substring(with: match.range)
                let hex = String(address.dropFirst(2))
                padded.replaceCharacters(in: match.range, with: "0x" + String(repeating: "0", count: 64 - hex.count) + hex)
            }
            result[key] = padded as String
        }
        return result
    }

    private func suiNetworkStatusResponse(
        chainIdentifier: String = WalletSuiChainIdentity.testnetBase58,
        timestamp: String = "2026-08-31T12:00:00Z"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": chainIdentifier,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": timestamp,
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
            ],
        ])
    }

    private func suiOverviewResponse(
        chainIdentifier: String = WalletSuiChainIdentity.testnetBase58,
        address: String,
        timestamp: String = "2026-08-31T12:00:00Z",
        total: String = "1007",
        coins: String = "1000",
        accumulator: String = "7"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": chainIdentifier,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": timestamp,
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "address": [
                    "address": address,
                    "balance": [
                        "coinType": ["repr": "0x2::sui::SUI"],
                        "totalBalance": total,
                        "coinBalance": coins,
                        "addressBalance": accumulator,
                    ],
                ],
            ],
        ])
    }

    private func suiBalancesResponse(
        chainIdentifier: String = WalletSuiChainIdentity.testnetBase58,
        address: String,
        timestamp: String = "2026-08-31T12:00:00Z",
        balances: [(String, String, String, String)],
        hasNextPage: Bool,
        endCursor: String?
    ) throws -> Data {
        let nodes: [[String: Any]] = balances.map { item in
            [
                "coinType": ["repr": item.0],
                "totalBalance": item.1,
                "coinBalance": item.2,
                "addressBalance": item.3,
            ]
        }
        let cursorValue: Any = endCursor.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": chainIdentifier,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": timestamp,
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "address": [
                    "address": address,
                    "balances": [
                        "nodes": nodes,
                        "pageInfo": [
                            "hasNextPage": hasNextPage,
                            "endCursor": cursorValue,
                        ],
                    ],
                ],
            ],
        ])
    }

    private func suiObjectJSON(
        objectID: String,
        owner: String,
        version: Int,
        digest: String,
        moveType: String,
        hasPublicTransfer: Bool
    ) -> [String: Any] {
        [
            "address": objectID,
            "version": version,
            "digest": digest,
            "hasPublicTransfer": hasPublicTransfer,
            "contents": ["type": ["repr": moveType]],
            "owner": [
                "__typename": "AddressOwner",
                "address": ["address": owner],
            ],
        ]
    }

    private func suiOwnedObjectsResponse(
        chainIdentifier: String = WalletSuiChainIdentity.testnetBase58,
        owner: String,
        timestamp: String = "2026-08-31T12:00:00Z",
        objects: [[String: Any]],
        hasNextPage: Bool,
        endCursor: String?
    ) throws -> Data {
        let cursorValue: Any = endCursor.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": chainIdentifier,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": timestamp,
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "address": [
                    "address": owner,
                    "objects": [
                        "nodes": objects,
                        "pageInfo": [
                            "hasNextPage": hasNextPage,
                            "endCursor": cursorValue,
                        ],
                    ],
                ],
            ],
        ])
    }

    private func suiGasCoinJSON(
        objectID: String,
        owner: String,
        version: Int,
        digestByte: UInt8,
        balance: UInt64,
        coinType: String = WalletSuiAssetIdentity.nativeCoinType
    ) -> [String: Any] {
        let hexadecimal = objectID.dropFirst(2)
        var bcs = Data()
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            bcs.append(UInt8(hexadecimal[index..<end], radix: 16)!)
            index = end
        }
        var littleEndianBalance = balance.littleEndian
        withUnsafeBytes(of: &littleEndianBalance) { bcs.append(contentsOf: $0) }
        return [
            "address": objectID,
            "version": version,
            "digest": WalletSolanaBase58.encode(Data(repeating: digestByte, count: 32)),
            "contents": [
                "type": ["repr": "0x2::coin::Coin<\(coinType)>"],
                "bcs": bcs.base64EncodedString(),
            ],
            "owner": [
                "__typename": "AddressOwner",
                "address": ["address": owner],
            ],
        ]
    }

    private func suiGasCoinsResponse(
        chainIdentifier: String = WalletSuiChainIdentity.testnetBase58,
        owner: String,
        timestamp: String = "2026-08-31T12:00:00Z",
        total: String,
        coinsBalance: String,
        accumulator: String,
        coins: [[String: Any]],
        hasNextPage: Bool,
        endCursor: String?,
        coinType: String = WalletSuiAssetIdentity.nativeCoinType
    ) throws -> Data {
        let cursorValue: Any = endCursor.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": chainIdentifier,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": timestamp,
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "address": [
                    "address": owner,
                    "balance": [
                        "coinType": ["repr": coinType],
                        "totalBalance": total,
                        "coinBalance": coinsBalance,
                        "addressBalance": accumulator,
                    ],
                    "objects": [
                        "nodes": coins,
                        "pageInfo": [
                            "hasNextPage": hasNextPage,
                            "endCursor": cursorValue,
                        ],
                    ],
                ],
            ],
        ])
    }

    private func suiNativeTransferSimulationResponse(
        sender: String,
        recipient: String,
        gasObjectID: String,
        transactionDigest: String,
        effectsDigest: String,
        senderDebit: String,
        recipientCredit: String,
        computationCost: Int = 1_000,
        storageCost: Int = 500,
        storageRebate: Int = 200,
        nonRefundableStorageFee: Int = 100,
        status: String = "SUCCESS",
        hasNextPage: Bool = false
    ) throws -> Data {
        let executionError: Any = status == "SUCCESS"
            ? NSNull() : ["message": "simulated failure"]
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": WalletSuiChainIdentity.mainnetBase58,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": "2026-08-31T12:00:00Z",
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "simulateTransaction": [
                    "effects": [
                        "digest": transactionDigest,
                        "effectsDigest": effectsDigest,
                        "status": status,
                        "executionError": executionError,
                        "gasEffects": [
                            "gasObject": ["address": gasObjectID],
                            "gasSummary": [
                                "computationCost": computationCost,
                                "storageCost": storageCost,
                                "storageRebate": storageRebate,
                                "nonRefundableStorageFee": nonRefundableStorageFee,
                            ],
                        ],
                        "balanceChanges": [
                            "nodes": [
                                self.suiBalanceChangeJSON(
                                    owner: sender, coinType: "0x2::sui::SUI",
                                    amount: "-\(senderDebit)"
                                ),
                                self.suiBalanceChangeJSON(
                                    owner: recipient, coinType: "0x2::sui::SUI",
                                    amount: recipientCredit
                                ),
                            ],
                            "pageInfo": ["hasNextPage": hasNextPage],
                        ],
                    ],
                ],
            ],
        ])
    }

    private func suiCoinTransferSimulationResponse(
        sender: String,
        recipient: String,
        coinType: String,
        gasObjectID: String,
        transactionDigest: String,
        effectsDigest: String,
        assetDebit: String,
        recipientCredit: String,
        gasDebit: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": WalletSuiChainIdentity.mainnetBase58,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": "2026-08-31T12:00:00Z",
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "simulateTransaction": [
                    "effects": [
                        "digest": transactionDigest,
                        "effectsDigest": effectsDigest,
                        "status": "SUCCESS",
                        "executionError": NSNull(),
                        "gasEffects": [
                            "gasObject": ["address": gasObjectID],
                            "gasSummary": [
                                "computationCost": 1_000,
                                "storageCost": 500,
                                "storageRebate": 200,
                                "nonRefundableStorageFee": 100,
                            ],
                        ],
                        "balanceChanges": [
                            "nodes": [
                                self.suiBalanceChangeJSON(
                                    owner: sender, coinType: coinType,
                                    amount: "-\(assetDebit)"
                                ),
                                self.suiBalanceChangeJSON(
                                    owner: recipient, coinType: coinType,
                                    amount: recipientCredit
                                ),
                                self.suiBalanceChangeJSON(
                                    owner: sender,
                                    coinType: WalletSuiAssetIdentity.nativeCoinType,
                                    amount: "-\(gasDebit)"
                                ),
                            ],
                            "pageInfo": ["hasNextPage": false],
                        ],
                    ],
                ],
            ],
        ])
    }

    private func suiObjectTransferSimulationResponse(
        sender: String,
        recipient: String,
        input: WalletSuiObjectReference,
        gas: WalletSuiObjectReference,
        transactionDigest: String,
        effectsDigest: String,
        outputOwner: String? = nil,
        outputType: String? = nil,
        outputHasPublicTransfer: Bool = true
    ) throws -> Data {
        let output = WalletSuiObjectReference(
            objectID: input.objectID, version: input.version + 1,
            digest: WalletSolanaBase58.encode(Data(repeating: 69, count: 32)),
            type: outputType ?? input.type
        )
        let gasOutput = WalletSuiObjectReference(
            objectID: gas.objectID, version: gas.version + 1,
            digest: WalletSolanaBase58.encode(Data(repeating: 70, count: 32)),
            type: gas.type
        )
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": WalletSuiChainIdentity.mainnetBase58,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": "2026-08-31T12:00:00Z",
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "simulateTransaction": [
                    "effects": [
                        "digest": transactionDigest,
                        "effectsDigest": effectsDigest,
                        "status": "SUCCESS",
                        "executionError": NSNull(),
                        "gasEffects": [
                            "gasObject": ["address": gas.objectID],
                            "gasSummary": [
                                "computationCost": 1_000,
                                "storageCost": 500,
                                "storageRebate": 200,
                                "nonRefundableStorageFee": 100,
                            ],
                        ],
                        "balanceChanges": [
                            "nodes": [self.suiBalanceChangeJSON(
                                owner: sender,
                                coinType: WalletSuiAssetIdentity.nativeCoinType,
                                amount: "-1300"
                            )],
                            "pageInfo": ["hasNextPage": false],
                        ],
                        "objectChanges": [
                            "nodes": [
                                [
                                    "address": input.objectID,
                                    "idCreated": false,
                                    "idDeleted": false,
                                    "inputState": self.suiObjectStateJSON(
                                        reference: input, owner: sender,
                                        hasPublicTransfer: true
                                    ),
                                    "outputState": self.suiObjectStateJSON(
                                        reference: output,
                                        owner: outputOwner ?? recipient,
                                        hasPublicTransfer: outputHasPublicTransfer
                                    ),
                                ],
                                [
                                    "address": gas.objectID,
                                    "idCreated": false,
                                    "idDeleted": false,
                                    "inputState": self.suiObjectStateJSON(
                                        reference: gas, owner: sender,
                                        hasPublicTransfer: true
                                    ),
                                    "outputState": self.suiObjectStateJSON(
                                        reference: gasOutput, owner: sender,
                                        hasPublicTransfer: true
                                    ),
                                ],
                            ],
                            "pageInfo": ["hasNextPage": false],
                        ],
                    ],
                ],
            ],
        ])
    }

    private func suiObjectStateJSON(
        reference: WalletSuiObjectReference,
        owner: String,
        hasPublicTransfer: Bool
    ) -> [String: Any] {
        [
            "address": reference.objectID,
            "version": reference.version,
            "digest": reference.digest,
            "owner": [
                "__typename": "AddressOwner",
                "address": ["address": owner],
            ],
            "asMoveObject": [
                "hasPublicTransfer": hasPublicTransfer,
                "contents": ["type": ["repr": reference.type]],
            ],
        ]
    }

    private func suiBalanceChangeJSON(
        owner: String,
        coinType: String,
        amount: String
    ) -> [String: Any] {
        [
            "owner": ["address": owner],
            "coinType": ["repr": coinType],
            "amount": amount,
        ]
    }

    private func suiActivityTransactionJSON(
        digest: String,
        sender: String?,
        status: String = "SUCCESS",
        timestamp: String = "2026-08-31T12:00:00Z",
        checkpointSequence: Int = 123_455,
        balanceChanges: [[String: Any]],
        hasMoreBalanceChanges: Bool = false,
        objectChanges: [[String: Any]] = [],
        hasMoreObjectChanges: Bool = false
    ) -> [String: Any] {
        let senderValue: Any = sender.map {
            ["address": $0] as [String: Any]
        } ?? NSNull()
        return [
            "digest": digest,
            "sender": senderValue,
            "effects": [
                "digest": digest,
                "status": status,
                "timestamp": timestamp,
                "checkpoint": ["sequenceNumber": checkpointSequence],
                "balanceChanges": [
                    "nodes": balanceChanges,
                    "pageInfo": ["hasNextPage": hasMoreBalanceChanges],
                ],
                "objectChanges": [
                    "nodes": objectChanges,
                    "pageInfo": ["hasNextPage": hasMoreObjectChanges],
                ],
            ],
        ]
    }

    private func suiActivityObjectChangeJSON(
        input: WalletSuiObjectReference,
        output: WalletSuiObjectReference,
        inputOwner: String,
        outputOwner: String,
        hasPublicTransfer: Bool = true
    ) -> [String: Any] {
        [
            "address": input.objectID,
            "idCreated": false,
            "idDeleted": false,
            "inputState": suiObjectStateJSON(
                reference: input, owner: inputOwner,
                hasPublicTransfer: hasPublicTransfer
            ),
            "outputState": suiObjectStateJSON(
                reference: output, owner: outputOwner,
                hasPublicTransfer: hasPublicTransfer
            ),
        ]
    }

    private func suiActivityTerminalObjectChangeJSON(
        state: WalletSuiObjectReference,
        owner: String,
        created: Bool,
        hasPublicTransfer: Bool = true
    ) -> [String: Any] {
        [
            "address": state.objectID,
            "idCreated": created,
            "idDeleted": !created,
            "inputState": created
                ? NSNull()
                : suiObjectStateJSON(
                    reference: state, owner: owner,
                    hasPublicTransfer: hasPublicTransfer
                ),
            "outputState": created
                ? suiObjectStateJSON(
                    reference: state, owner: owner,
                    hasPublicTransfer: hasPublicTransfer
                )
                : NSNull(),
        ]
    }

    private func suiActivityResponse(
        chainIdentifier: String = WalletSuiChainIdentity.testnetBase58,
        owner: String,
        checkpointTimestamp: String = "2026-08-31T12:00:00Z",
        transactions: [[String: Any]],
        hasNextPage: Bool = false,
        endCursor: String? = nil
    ) throws -> Data {
        let cursorValue: Any = endCursor.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: [
            "data": [
                "chainIdentifier": chainIdentifier,
                "checkpoint": [
                    "sequenceNumber": 123_456,
                    "timestamp": checkpointTimestamp,
                    "epoch": ["epochId": 900, "referenceGasPrice": "1000"],
                ],
                "address": [
                    "address": owner,
                    "transactions": [
                        "nodes": transactions,
                        "pageInfo": [
                            "hasNextPage": hasNextPage,
                            "endCursor": cursorValue,
                        ],
                    ],
                ],
            ],
        ])
    }

    private func solanaTokenAccountJSON(
        address: String,
        mint: String,
        owner: String,
        amount: String,
        decimals: Int,
        programID: String,
        extensions: [[String: Any]] = []
    ) -> [String: Any] {
        let parsedProgram = programID == WalletSolanaTokenProgram.token2022.programID
            ? WalletSolanaTokenProgram.token2022.parsedProgramName
            : WalletSolanaTokenProgram.spl.parsedProgramName
        var info: [String: Any] = [
            "isNative": false, "mint": mint, "owner": owner,
            "state": "initialized",
            "tokenAmount": [
                "amount": amount, "decimals": decimals,
                "uiAmount": NSNull(), "uiAmountString": "ignored",
            ],
        ]
        if !extensions.isEmpty { info["extensions"] = extensions }
        return [
            "pubkey": address,
            "account": [
                "data": [
                    "program": parsedProgram,
                    "parsed": [
                        "type": "account",
                        "info": info,
                    ],
                    "space": 165,
                ],
                "executable": false, "lamports": 2_039_280,
                "owner": programID, "space": 165,
            ],
        ]
    }

    private func signedReview(
        _ manifest: WalletReviewManifest,
        key: Curve25519.Signing.PrivateKey
    ) throws -> WalletSignedReviewManifest {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try key.signature(for: encoder.encode(manifest))
        return WalletSignedReviewManifest(
            manifest: manifest, signatureBase64: signature.base64EncodedString()
        )
    }

    func testXPCReplyGateConsumesExactlyOneReply() {
        let gate = WalletXPCReplyGate()
        XCTAssertTrue(gate.take())
        XCTAssertFalse(gate.take())
        XCTAssertFalse(gate.take())
    }

    #if LOCUS_DIRECT_DOWNLOAD
    func testEmbeddedSignerProcessReportsAConnectionLocalLockedSession() async throws {
        let client = XPCWalletSignerClient(bundle: Bundle.main)
        XCTAssertTrue(client.isAvailable, "The direct build must embed WalletSigner.xpc.")
        let status = try await client.signerStatus()
        XCTAssertEqual(status.protocolVersion, WalletGateway.protocolVersion)
        XCTAssertNil(status.sessionID)
        XCTAssertNotEqual(status.vaultState, .unlocked)
        client.lock()
    }

    func testEmbeddedRecoveryApplicationAndBothSignerCopiesArePresent() throws {
        let client = ProcessWalletRecoveryViewClient(bundle: Bundle.main)
        XCTAssertTrue(client.isAvailable, "The direct build must embed signed WalletRecovery.app.")
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let outerSigner = contents.appendingPathComponent(
            "XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner"
        )
        let innerSigner = contents.appendingPathComponent(
            "Helpers/WalletRecovery.app/Contents/XPCServices/WalletSigner.xpc/Contents/MacOS/WalletSigner"
        )
        XCTAssertEqual(try Data(contentsOf: outerSigner), try Data(contentsOf: innerSigner))
    }
    #endif

    func testRecoveryProcessFramesAreBoundedChunkableAndSecretFree() throws {
        let invocationID = UUID().uuidString.lowercased()
        let start = WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .start,
            mode: .create
        )
        let presented = WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .presented
        )
        let startFrame = try WalletRecoveryProcessFrameDecoder.encode(start)
        let presentedFrame = try WalletRecoveryProcessFrameDecoder.encode(presented)
        let wire = String(decoding: startFrame + presentedFrame, as: UTF8.self).lowercased()
        for forbidden in ["words", "phrase", "entropy", "private_key", "privatekey"] {
            XCTAssertFalse(wire.contains(forbidden))
        }

        var decoder = WalletRecoveryProcessFrameDecoder()
        XCTAssertTrue(try decoder.append(startFrame.prefix(3)).isEmpty)
        let messages = try decoder.append(startFrame.dropFirst(3) + presentedFrame)
        XCTAssertEqual(messages, [start, presented])

        var oversized = WalletRecoveryProcessFrameDecoder()
        XCTAssertThrowsError(try oversized.append(Data([0, 1, 0, 1]))) { error in
            XCTAssertEqual(error as? WalletRecoveryProcessFrameError, .oversized)
        }
        var malformed = WalletRecoveryProcessFrameDecoder()
        XCTAssertThrowsError(try malformed.append(Data([0, 0, 0, 1, 0xff]))) { error in
            XCTAssertEqual(error as? WalletRecoveryProcessFrameError, .malformed)
        }
    }

    func testRecoveryProcessLifecycleRejectsMismatchedAndDuplicateMessages() throws {
        let invocationID = UUID().uuidString.lowercased()
        var lifecycle = WalletRecoveryProcessLifecycle(invocationID: invocationID)
        XCTAssertThrowsError(try lifecycle.receive(WalletRecoveryProcessMessage(
            invocationID: UUID().uuidString.lowercased(),
            kind: .presented
        )))

        _ = try lifecycle.receive(WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .presented
        ))
        XCTAssertEqual(lifecycle.presentationState, .presented)
        XCTAssertThrowsError(try lifecycle.receive(WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .presented
        )))

        let terminal = WalletRecoveryCeremonyResult(
            ceremonyID: "ceremony-1", outcome: .canceled,
            signerStatus: nil, error: nil
        )
        _ = try lifecycle.receive(WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .terminal,
            result: terminal
        ))
        XCTAssertThrowsError(try lifecycle.receive(WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .terminal,
            result: terminal
        )))
    }

    func testRecoveryPresentationTimeoutWinsLateTerminalAndCancelIsIdempotent() throws {
        let invocationID = UUID().uuidString.lowercased()
        var lifecycle = WalletRecoveryProcessLifecycle(invocationID: invocationID)
        XCTAssertTrue(lifecycle.presentationTimedOut())
        XCTAssertFalse(lifecycle.requestCancellation())

        let canceled = WalletRecoveryCeremonyResult(
            ceremonyID: "ceremony-1", outcome: .canceled,
            signerStatus: nil, error: nil
        )
        _ = try lifecycle.receive(WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .terminal,
            result: canceled
        ))
        XCTAssertThrowsError(try lifecycle.terminalResolution(canceled).get()) { error in
            XCTAssertEqual(error as? WalletRecoveryViewError, .presentationTimedOut)
        }

        var canceledBeforePresentation = WalletRecoveryProcessLifecycle(
            invocationID: invocationID
        )
        XCTAssertTrue(canceledBeforePresentation.requestCancellation())
        XCTAssertFalse(canceledBeforePresentation.requestCancellation())
        XCTAssertFalse(canceledBeforePresentation.presentationTimedOut())
        let result = try canceledBeforePresentation.terminationResolution().get()
        XCTAssertEqual(result.outcome, .canceled)
        XCTAssertEqual(result.ceremonyID, invocationID)
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

    func testBrowserSourceCanNeverUseAnAutonomousPolicy() {
        let browser = WalletPreparedTransaction(
            id: "browser-intent", digest: "digest", networkID: WalletGateway.sepoliaNetworkID,
            accountID: "account-1", source: .browser(origin: "https://dapp.test"),
            action: .nativeTransfer(recipient: "0x1111111111111111111111111111111111111111", amountBaseUnits: "10"),
            summary: "Transfer", effects: [], riskFlags: [], contract: nil,
            adapterID: "native-eth-transfer-v1", budgetAssetID: "slip44:60",
            spendBaseUnits: "10", maximumFeeBaseUnits: "20", feeQuoteBaseUnits: "15",
            simulation: "Success", simulationSucceeded: true, nonce: "1",
            createdAt: Date(), expiresAt: Date().addingTimeInterval(120),
            policyDecision: "", policyID: nil
        )
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: browser, policy: policy(), spentThisSession: "0"
        ) else { return XCTFail("Browser-originated transactions must require exact confirmation") }
    }

    func testFailedExpiredMismatchedAndDeniedTransactionsCannotBeConfirmed() {
        let gateway = WalletGateway(
            signer: UnavailableWalletSignerClient(),
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"]
        )
        XCTAssertTrue(gateway.isTransactionConfirmable(prepared()))
        XCTAssertFalse(gateway.isTransactionConfirmable(prepared(
            expiresAt: Date().addingTimeInterval(-1)
        )))
        XCTAssertFalse(gateway.isTransactionConfirmable(prepared(
            simulationSucceeded: false
        )))
        XCTAssertFalse(gateway.isTransactionConfirmable(prepared(
            riskFlags: [.codeHashMismatch]
        )))
        XCTAssertFalse(gateway.isTransactionConfirmable(prepared(
            policyDecision: "denied_by_signer"
        )))
    }

    func testPolicyUsesUnsignedBaseUnitCaps() {
        XCTAssertEqual(WalletPolicyEngine.evaluate(
            transaction: prepared(), policy: policy(), spentThisSession: "5"
        ), .automatic)
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: prepared(), policy: policy(), spentThisSession: "45"
        ) else { return XCTFail("cumulative cap must be enforced") }
    }

    func testUniswapRoutePlannerEnumeratesOnlyAcyclicReviewedSingleVersionPaths() {
        let network = WalletGateway.sepoliaNetworkID
        let input = "\(network)/erc20:0x1111111111111111111111111111111111111111"
        let middle = "\(network)/erc20:0x2222222222222222222222222222222222222222"
        let output = "\(network)/erc20:0x3333333333333333333333333333333333333333"
        let forbidden = "\(network)/erc20:0x4444444444444444444444444444444444444444"
        func pool(
            _ version: WalletUniversalRouterSwapProtocol, _ marker: Character,
            _ token0: String, _ token1: String, _ fee: UInt32? = nil
        ) -> WalletReviewedUniswapPoolIdentity {
            .init(
                protocolVersion: version,
                address: "0x" + String(repeating: String(marker), count: 40),
                runtimeCodeHash: "0x" + String(repeating: String(marker), count: 64),
                token0AssetID: token0, token1AssetID: token1, feeTier: fee
            )
        }
        let configuration = WalletReviewedUniswapConfiguration(
            networkID: network, universalRouterContractID: "router",
            permit2ContractID: "permit2", contracts: [],
            pools: [
                pool(.v2, "a", input, output),
                pool(.v2, "b", input, middle),
                pool(.v2, "c", middle, output),
                pool(.v3, "d", input, output, 500),
                pool(.v3, "e", input, middle, 3_000),
                pool(.v3, "f", middle, output, 3_000),
                pool(.v3, "1", input, forbidden, 500),
                pool(.v3, "2", forbidden, output, 500),
            ],
            allowedIntermediaryAssetIDs: [middle],
            allowedFeeTiers: [500, 3_000], maximumHops: 2,
            zeroFirstApprovalAssetIDs: []
        )

        let routes = WalletUniswapRoutePlanner.candidates(
            configuration: configuration,
            inputAssetID: input, outputAssetID: output
        )
        XCTAssertEqual(routes.count, 4)
        XCTAssertEqual(Set(routes.map(\.protocolVersion)), [.v2, .v3])
        XCTAssertTrue(routes.allSatisfy { Set($0.pathAssetIDs).count == $0.pathAssetIDs.count })
        XCTAssertFalse(routes.contains { $0.pathAssetIDs.contains(forbidden) })
        XCTAssertTrue(routes.filter { $0.protocolVersion == .v2 }.allSatisfy {
            $0.feeTiers.isEmpty
        })
        XCTAssertEqual(
            Set(routes.filter { $0.protocolVersion == .v3 }.map(\.feeTiers)),
            Set([[500], [3_000, 3_000]])
        )
    }

    func testCheckedQuoteMathUsesFloorAndRejectsZeroDivisor() {
        XCTAssertEqual(
            WalletBaseUnits.divide("100", by: "3")?.quotient, "33"
        )
        XCTAssertEqual(
            WalletBaseUnits.divide("100", by: "3")?.remainder, "1"
        )
        XCTAssertEqual(
            WalletBaseUnits.applyingBasisPointFloor("999", bpsToKeep: 9_950),
            "994"
        )
        XCTAssertNil(WalletBaseUnits.divide("1", by: "0"))
        XCTAssertNil(WalletBaseUnits.applyingBasisPointFloor(
            "1", bpsToKeep: 10_001
        ))
    }

    func testSwapAllowanceIsExactFiniteSwapBoundAndNeverAutonomous() throws {
        let networkID = WalletGateway.sepoliaNetworkID
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let token = "0x1111111111111111111111111111111111111111"
        let outputToken = "0x2222222222222222222222222222222222222222"
        let router = "0x3333333333333333333333333333333333333333"
        let permit2 = "0x4444444444444444444444444444444444444444"
        let inputAsset = "\(networkID)/erc20:\(token)"
        let outputAsset = "\(networkID)/erc20:\(outputToken)"
        let now = Date()
        let route = WalletExactInputSwapRoute(
            protocolVersion: .v3,
            pathAssetIDs: [inputAsset, outputAsset], feeTiers: [3_000],
            minimumHopPriceX36: ["975" + String(repeating: "0", count: 33)],
            quotedOutputBaseUnits: "1000", slippageBPS: 250,
            deadlineUnixSeconds: String(UInt64(now.timeIntervalSince1970) + 600),
            quoteEvidence: WalletUniswapQuoteEvidence(
                blockNumber: "1", blockHash: "0x" + String(repeating: "1", count: 64),
                quoteContractAddress: "0x5555555555555555555555555555555555555555",
                quoteContractRuntimeCodeHash: "0x" + String(repeating: "5", count: 64),
                perHopOutputBaseUnits: ["1000"], gasEstimate: "1",
                quotedAt: now, expiresAt: now.addingTimeInterval(60),
                agreeingProviderCount: 2
            )
        )
        let binding = WalletSwapAllowanceBinding(
            networkID: networkID, universalRouterContractID: "router",
            universalRouterAddress: router, permit2Address: permit2,
            inputAssetID: inputAsset, outputAssetID: outputAsset,
            amountInBaseUnits: "1000", minimumOutputBaseUnits: "975",
            recipient: account, route: route
        )
        let setup = WalletSwapAllowanceSetup(
            stage: .erc20ToPermit2, binding: binding,
            bindingDigest: try XCTUnwrap(binding.digest()),
            approvalAmountBaseUnits: "1000", expirationUnixSeconds: nil
        )
        let action = WalletSemanticAction.swapAllowanceSetup(
            contractID: "token", adapterID: WalletReviewedAdapters.erc20,
            setup: setup
        )
        let erc20ABI = #"[{"type":"function","name":"approve","stateMutability":"nonpayable","inputs":[{"type":"address"},{"type":"uint256"}],"outputs":[{"type":"bool"}]}]"#
        let entry = WalletContractRegistryEntry(
            id: "token", networkID: networkID, checksumAddress: token,
            label: "Token", normalizedABI: erc20ABI,
            abiDigest: "sha256:test",
            runtimeCodeHash: "0x" + String(repeating: "a", count: 64),
            permittedFunctions: ["approve(address,uint256)"],
            permittedSelectors: ["0x095ea7b3"],
            reviewedAdapterID: WalletReviewedAdapters.erc20,
            verifiedAt: now
        )
        let configuration = WalletReviewedUniswapConfiguration(
            networkID: networkID, universalRouterContractID: "router",
            permit2ContractID: "permit2", contracts: [
                WalletReviewedUniswapContractIdentity(
                    role: .universalRouter, address: router,
                    runtimeCodeHash: "0x" + String(repeating: "3", count: 64)
                ),
                WalletReviewedUniswapContractIdentity(
                    role: .permit2, address: permit2,
                    runtimeCodeHash: "0x" + String(repeating: "4", count: 64)
                ),
            ], pools: [], allowedIntermediaryAssetIDs: [],
            allowedFeeTiers: [3_000], maximumHops: 3,
            zeroFirstApprovalAssetIDs: []
        )
        let call = try XCTUnwrap(WalletSwapAllowanceAdapter.resolve(
            action: action, registryEntry: entry,
            configuration: configuration
        ))
        XCTAssertEqual(call.function, "approve(address,uint256)")
        XCTAssertEqual(call.arguments.map(\.value), [permit2, "1000"])

        let transaction = WalletPreparedTransaction(
            id: "allowance", digest: "digest", networkID: networkID,
            accountID: "account-1", source: .agent, action: action,
            summary: "Allowance", effects: [], riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.erc20,
            budgetAssetID: inputAsset, spendBaseUnits: "1000",
            maximumFeeBaseUnits: "20", feeQuoteBaseUnits: "10",
            simulation: "Success", simulationSucceeded: true, nonce: "1",
            createdAt: now, expiresAt: now.addingTimeInterval(120),
            policyDecision: "", policyID: nil
        )
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: transaction, policy: policy(), spentThisSession: "0"
        ) else {
            return XCTFail("Allowance setup must never consume signer policy.")
        }

        let substituted = WalletSemanticAction.swapAllowanceSetup(
            contractID: "token", adapterID: WalletReviewedAdapters.erc20,
            setup: WalletSwapAllowanceSetup(
                stage: .erc20ToPermit2, binding: binding,
                bindingDigest: "sha256:" + String(repeating: "0", count: 64),
                approvalAmountBaseUnits: "1000", expirationUnixSeconds: nil
            )
        )
        XCTAssertNil(WalletSwapAllowanceAdapter.resolve(
            action: substituted, registryEntry: entry,
            configuration: configuration
        ))
    }

    func testReviewedContractPoliciesRequireExactContractAssetAndCounterparty() {
        let token = "0x1111111111111111111111111111111111111111"
        let recipient = "0x2222222222222222222222222222222222222222"
        let transaction = WalletPreparedTransaction(
            id: "erc20-intent", digest: "digest", networkID: WalletGateway.sepoliaNetworkID,
            accountID: "account-1", source: .agent,
            action: .contractCall(
                contractID: "token.test", function: "transfer(address,uint256)",
                arguments: [
                    WalletTypedArgument(type: "address", value: recipient),
                    WalletTypedArgument(type: "uint256", value: "10"),
                ]
            ),
            summary: "Token transfer",
            effects: [WalletDecodedEffect(
                id: "effect", kind: "token_transfer",
                assetID: "eip155:11155111/erc20:\(token)", amountBaseUnits: "10",
                from: "0x3333333333333333333333333333333333333333",
                to: recipient, spender: nil
            )],
            riskFlags: [],
            contract: WalletContractIdentity(
                registryID: "token.test", address: token, label: "Token",
                function: "transfer(address,uint256)", abiDigest: "sha256:test",
                runtimeCodeHash: "0xcode"
            ),
            adapterID: WalletReviewedAdapters.erc20,
            budgetAssetID: "eip155:11155111/erc20:\(token)", spendBaseUnits: "10",
            maximumFeeBaseUnits: "20", feeQuoteBaseUnits: "15", simulation: "Success",
            simulationSucceeded: true, nonce: "1", createdAt: Date(),
            expiresAt: Date().addingTimeInterval(120), policyDecision: "", policyID: nil
        )
        let exactPolicy = WalletSessionPolicy(
            id: "erc20-policy", accountID: "account-1",
            networkID: WalletGateway.sepoliaNetworkID,
            allowedAssetIDs: ["eip155:11155111/erc20:\(token)"],
            allowedRecipients: [recipient], allowedContractIDs: ["token.test"],
            allowedAdapterIDs: [WalletReviewedAdapters.erc20],
            maximumTransactionBaseUnits: "10", maximumSessionBaseUnits: "20",
            maximumFeeBaseUnits: "20", expiresAt: Date().addingTimeInterval(300)
        )
        XCTAssertEqual(WalletPolicyEngine.evaluate(
            transaction: transaction, policy: exactPolicy, spentThisSession: "0"
        ), .automatic)

        let wrongCounterparty = WalletSessionPolicy(
            id: exactPolicy.id, accountID: exactPolicy.accountID,
            networkID: exactPolicy.networkID, allowedAssetIDs: exactPolicy.allowedAssetIDs,
            allowedRecipients: ["0x4444444444444444444444444444444444444444"],
            allowedContractIDs: exactPolicy.allowedContractIDs,
            allowedAdapterIDs: exactPolicy.allowedAdapterIDs,
            maximumTransactionBaseUnits: exactPolicy.maximumTransactionBaseUnits,
            maximumSessionBaseUnits: exactPolicy.maximumSessionBaseUnits,
            maximumFeeBaseUnits: exactPolicy.maximumFeeBaseUnits,
            expiresAt: exactPolicy.expiresAt
        )
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: transaction, policy: wrongCounterparty, spentThisSession: "0"
        ) else { return XCTFail("A contract adapter must enforce its decoded counterparty.") }
    }

    func testSemanticSwapPolicyBindsSlippageMinimumRouterAndRecipient() {
        let account = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let input = "eip155:11155111/erc20:0x1111111111111111111111111111111111111111"
        let output = "eip155:11155111/erc20:0x2222222222222222222222222222222222222222"
        let route = WalletExactInputSwapRoute(
            protocolVersion: .v3, pathAssetIDs: [input, output],
            feeTiers: [3_000], minimumHopPriceX36: ["1"],
            quotedOutputBaseUnits: "1000", slippageBPS: 250,
            deadlineUnixSeconds: String(
                UInt64(Date().timeIntervalSince1970) + 600
            )
        )
        let action = WalletSemanticAction.exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: "uniswap.router", inputAssetID: input,
            outputAssetID: output, amountInBaseUnits: "1000",
            minimumOutputBaseUnits: "975", recipient: account, route: route
        )
        let transaction = WalletPreparedTransaction(
            id: "swap-intent", digest: "digest",
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: "account-1", source: .agent, action: action,
            summary: "Swap", effects: [
                WalletDecodedEffect(
                    id: "spend", kind: "token_swap_exact_in",
                    assetID: input, amountBaseUnits: "1000",
                    from: account, to: "0x4444444444444444444444444444444444444444",
                    spender: nil
                ),
                WalletDecodedEffect(
                    id: "receive", kind: "minimum_receive",
                    assetID: output, amountBaseUnits: "975",
                    from: "0x4444444444444444444444444444444444444444",
                    to: account, spender: nil
                ),
            ], riskFlags: [], contract: WalletContractIdentity(
                registryID: "uniswap.router",
                address: "0x4444444444444444444444444444444444444444",
                label: "Router", function: "execute(bytes,bytes[],uint256)",
                abiDigest: "sha256:test", runtimeCodeHash: "0xcode"
            ),
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            budgetAssetID: input, spendBaseUnits: "1000",
            maximumFeeBaseUnits: "20", feeQuoteBaseUnits: "15",
            simulation: "Success", simulationSucceeded: true, nonce: "1",
            createdAt: Date(), expiresAt: Date().addingTimeInterval(120),
            policyDecision: "", policyID: nil
        )
        func policy(slippage: Int, minimum: String) -> WalletSessionPolicy {
            WalletSessionPolicy(
                id: "swap-policy", accountID: "account-1",
                networkID: WalletGateway.sepoliaNetworkID,
                allowedAssetIDs: [input], allowedRecipients: [account],
                allowedContractIDs: ["uniswap.router"],
                allowedAdapterIDs: [
                    WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                ], maximumTransactionBaseUnits: "1000",
                maximumSessionBaseUnits: "2000", maximumFeeBaseUnits: "20",
                expiresAt: Date().addingTimeInterval(300),
                allowedActionKinds: [.exactInputSwap],
                maximumSlippageBPS: slippage,
                minimumOutputBaseUnits: minimum
            )
        }
        XCTAssertEqual(WalletPolicyEngine.evaluate(
            transaction: transaction, policy: policy(slippage: 250, minimum: "975"),
            spentThisSession: "0"
        ), .automatic)
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: transaction, policy: policy(slippage: 200, minimum: "975"),
            spentThisSession: "0"
        ) else { return XCTFail("The swap slippage policy must be signer-bound.") }
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: transaction, policy: policy(slippage: 250, minimum: "976"),
            spentThisSession: "0"
        ) else { return XCTFail("The swap minimum-output policy must be signer-bound.") }
    }

    func testExternalConnectorCatalogKeepsNativeSigningOnSepolia() {
        XCTAssertEqual(
            WalletExternalConnectorCatalog.connectors.map(\.kind),
            [.metamask, .phantom, .slush]
        )
        XCTAssertTrue(WalletExternalConnectorCatalog.canUseNativeSigner(on: "eip155:11155111"))
        XCTAssertFalse(WalletExternalConnectorCatalog.canUseNativeSigner(on: "eip155:1"))
        XCTAssertFalse(WalletExternalConnectorCatalog.canUseNativeSigner(on: "solana:mainnet"))
        XCTAssertTrue(WalletExternalConnectorCatalog.connectors.allSatisfy {
            $0.state == .foundationReady && $0.documentationURL.scheme == "https"
        })
    }

    func testHumanEtherFormatterNeverUsesFloatingPoint() {
        XCTAssertEqual(WalletAmountFormatter.ether(wei: "0"), "0 ETH")
        XCTAssertEqual(WalletAmountFormatter.ether(wei: "1000000000000000000"), "1 ETH")
        XCTAssertEqual(WalletAmountFormatter.ether(wei: "1234500000000000000"), "1.2345 ETH")
        XCTAssertEqual(WalletAmountFormatter.ether(wei: "1"), "0.000000000000000001 ETH")
        XCTAssertNil(WalletAmountFormatter.ether(wei: "1.5"))
    }

    func testHumanEtherParserProducesCanonicalWeiWithoutFloatingPoint() {
        XCTAssertEqual(WalletAmountFormatter.wei(fromEther: "0"), "0")
        XCTAssertEqual(WalletAmountFormatter.wei(fromEther: "1"), "1000000000000000000")
        XCTAssertEqual(WalletAmountFormatter.wei(fromEther: "1.2345"), "1234500000000000000")
        XCTAssertEqual(WalletAmountFormatter.wei(fromEther: ".5"), "500000000000000000")
        XCTAssertEqual(WalletAmountFormatter.wei(fromEther: "1."), "1000000000000000000")
        XCTAssertEqual(WalletAmountFormatter.wei(fromEther: "0.000000000000000001"), "1")
        XCTAssertNil(WalletAmountFormatter.wei(fromEther: "0.0000000000000000001"))
        XCTAssertNil(WalletAmountFormatter.wei(fromEther: " 1"))
        XCTAssertNil(WalletAmountFormatter.wei(fromEther: "+1"))
        XCTAssertNil(WalletAmountFormatter.wei(fromEther: "1e3"))
        XCTAssertNil(WalletAmountFormatter.wei(fromEther: "١"))
    }

    func testReceivePayloadBindsCanonicalNetworkWithoutAmount() {
        XCTAssertEqual(
            WalletReceiveURI.payload(
                address: "0xabc", networkID: WalletGateway.sepoliaNetworkID
            ),
            "ethereum:0xabc@11155111"
        )
        XCTAssertEqual(
            WalletReceiveURI.payload(
                address: "0xabc", networkID: WalletGateway.ethereumMainnetNetworkID
            ),
            "ethereum:0xabc@1"
        )
        XCTAssertEqual(
            WalletReceiveURI.payload(address: "SolAddress", networkID: "solana:mainnet-beta"),
            "solana:SolAddress"
        )
        XCTAssertEqual(
            WalletReceiveURI.payload(address: "0xsui", networkID: "sui:mainnet"),
            "0xsui"
        )
        XCTAssertFalse(WalletReceiveURI.payload(
            address: "0xabc", networkID: WalletGateway.sepoliaNetworkID
        ).contains("?value="))
    }

    func testNativePolicyTemplateBindsSolanaAssetAndAdapter() {
        let template = WalletPolicyTemplate(
            id: "sol-rule", name: "SOL rule",
            accountID: "locus-vault-solana-0",
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            recipient: WalletSolanaBase58.encode(Data(repeating: 7, count: 32)),
            maximumTransactionBaseUnits: "1000",
            maximumSessionBaseUnits: "5000",
            maximumFeeBaseUnits: "5000", durationMinutes: 30
        )
        let policy = template.policy()
        XCTAssertEqual(policy.allowedAssetIDs, [
            WalletNetworkCatalog.solanaDevnet.nativeAssetID,
        ])
        XCTAssertEqual(policy.allowedAdapterIDs, [
            WalletReviewedAdapters.solanaNativeTransfer,
        ])
        XCTAssertEqual(policy.networkID, WalletNetworkCatalog.solanaDevnet.id)
    }

    func testSolanaNativePolicyRequiresExactChainAssetAdapterAndRecipient() {
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        let action = WalletSemanticAction.nativeTransfer(
            recipient: recipient, amountBaseUnits: "1000"
        )
        let transaction = WalletPreparedTransaction(
            id: "sol-intent", digest: "digest",
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .agent,
            action: action, summary: "Send SOL", effects: [], riskFlags: [],
            contract: nil, adapterID: WalletReviewedAdapters.solanaNativeTransfer,
            budgetAssetID: WalletNetworkCatalog.solanaDevnet.nativeAssetID,
            spendBaseUnits: "1000", maximumFeeBaseUnits: "5000",
            feeQuoteBaseUnits: "5000", simulation: "Success",
            simulationSucceeded: true, nonce: "blockhash",
            createdAt: Date(), expiresAt: Date().addingTimeInterval(120),
            policyDecision: "", policyID: nil
        )
        let policy = WalletPolicyTemplate(
            id: "sol-rule", name: "SOL rule",
            accountID: "locus-vault-solana-0",
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            recipient: recipient, maximumTransactionBaseUnits: "1000",
            maximumSessionBaseUnits: "5000", maximumFeeBaseUnits: "5000",
            durationMinutes: 30
        ).policy()
        XCTAssertEqual(WalletPolicyEngine.evaluate(
            transaction: transaction, policy: policy, spentThisSession: "0"
        ), .automatic)

        let wrongRecipient = WalletSemanticAction.nativeTransfer(
            recipient: WalletSolanaBase58.encode(Data(repeating: 8, count: 32)),
            amountBaseUnits: "1000"
        )
        let substituted = WalletPreparedTransaction(
            id: transaction.id, digest: transaction.digest,
            networkID: transaction.networkID, accountID: transaction.accountID,
            source: transaction.source, action: wrongRecipient,
            summary: transaction.summary, effects: transaction.effects,
            riskFlags: transaction.riskFlags, contract: nil,
            adapterID: transaction.adapterID, budgetAssetID: transaction.budgetAssetID,
            spendBaseUnits: transaction.spendBaseUnits,
            maximumFeeBaseUnits: transaction.maximumFeeBaseUnits,
            feeQuoteBaseUnits: transaction.feeQuoteBaseUnits,
            simulation: transaction.simulation,
            simulationSucceeded: transaction.simulationSucceeded,
            nonce: transaction.nonce, createdAt: transaction.createdAt,
            expiresAt: transaction.expiresAt, policyDecision: "", policyID: nil
        )
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: substituted, policy: policy, spentThisSession: "0"
        ) else { return XCTFail("A substituted SOL recipient must require exact approval.") }
    }

    func testSolanaSPLPolicyBindsMintRecipientAmountFeeAndAdapter() {
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let assetID = "solana:devnet/spl:\(mint)"
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let action = WalletSemanticAction.fungibleTokenTransfer(
            assetID: assetID, recipient: recipient, amountBaseUnits: "1000000"
        )
        let transaction = WalletPreparedTransaction(
            id: "spl-intent", digest: "digest",
            networkID: WalletNetworkCatalog.solanaDevnet.id,
            accountID: "locus-vault-solana-0", source: .agent,
            action: action, summary: "Send token",
            effects: [.init(
                id: "effect", kind: "token_transfer", assetID: assetID,
                amountBaseUnits: "1000000", from: "payer", to: recipient,
                spender: nil
            )],
            riskFlags: [], contract: nil,
            adapterID: WalletReviewedAdapters.solanaSPLTransferChecked,
            budgetAssetID: assetID, spendBaseUnits: "1000000",
            maximumFeeBaseUnits: "5000", feeQuoteBaseUnits: "5000",
            simulation: "Success", simulationSucceeded: true, nonce: "blockhash",
            createdAt: Date(), expiresAt: Date().addingTimeInterval(120),
            policyDecision: "", policyID: nil
        )
        let policy = WalletSessionPolicy(
            id: "spl-rule", accountID: transaction.accountID,
            networkID: transaction.networkID,
            allowedAssetIDs: [assetID], allowedRecipients: [recipient],
            allowedContractIDs: [],
            allowedAdapterIDs: [WalletReviewedAdapters.solanaSPLTransferChecked],
            maximumTransactionBaseUnits: "1000000",
            maximumSessionBaseUnits: "5000000", maximumFeeBaseUnits: "5000",
            expiresAt: Date().addingTimeInterval(1800),
            allowedActionKinds: [.fungibleTokenTransfer]
        )
        XCTAssertEqual(WalletPolicyEngine.evaluate(
            transaction: transaction, policy: policy, spentThisSession: "0"
        ), .automatic)

        let token2022 = WalletSessionPolicy(
            id: policy.id, accountID: policy.accountID,
            networkID: policy.networkID,
            allowedAssetIDs: [assetID.replacingOccurrences(of: "/spl:", with: "/token2022:")],
            allowedRecipients: policy.allowedRecipients,
            allowedContractIDs: [], allowedAdapterIDs: policy.allowedAdapterIDs,
            maximumTransactionBaseUnits: policy.maximumTransactionBaseUnits,
            maximumSessionBaseUnits: policy.maximumSessionBaseUnits,
            maximumFeeBaseUnits: policy.maximumFeeBaseUnits,
            expiresAt: policy.expiresAt,
            allowedActionKinds: policy.allowedActionKinds
        )
        guard case .requiresApproval = WalletPolicyEngine.evaluate(
            transaction: transaction, policy: token2022, spentThisSession: "0"
        ) else {
            return XCTFail("A substituted Token-2022 asset must require exact approval.")
        }
    }

    func testWalletFeatureSettingsMigrateEnvironmentOnceAndAppStoreStaysOff() {
        var direct = AppSettings()
        XCTAssertTrue(direct.migrateLegacyWalletFeatureAccess(environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ], isDirectDownload: true))
        XCTAssertTrue(direct.walletAlphaEnabled)
        XCTAssertTrue(direct.walletBrowserProviderEnabled)
        XCTAssertFalse(direct.migrateLegacyWalletFeatureAccess(
            environment: [:], isDirectDownload: true
        ))
        XCTAssertTrue(direct.walletAlphaEnabled, "persisted in-app access becomes authoritative")

        var appStore = AppSettings()
        XCTAssertTrue(appStore.migrateLegacyWalletFeatureAccess(environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ], isDirectDownload: false))
        XCTAssertFalse(appStore.walletAlphaEnabled)
        XCTAssertFalse(appStore.walletBrowserProviderEnabled)
        let effective = AppSettings.effectiveWalletFeatureAccess(
            walletEnabled: true, browserEnabled: true, isDirectDownload: false
        )
        XCTAssertFalse(effective.walletEnabled)
        XCTAssertFalse(effective.browserEnabled)
    }

    func testWalletHubStateCoversBuildAccessSetupBackupLockAndReady() async {
        let signer = FakeWalletSigner()
        let recovery = FakeWalletRecoveryView()
        let unavailable = WalletGateway(
            signer: signer,
            recoveryView: recovery,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            buildSupportsWalletAlpha: false
        )
        XCTAssertEqual(unavailable.hubState, .unavailableBuild)

        let gateway = WalletGateway(signer: signer, recoveryView: recovery, environment: [:])
        XCTAssertEqual(gateway.hubState, .alphaDisabled)
        signer.reportedVaultState = .missing
        gateway.applyFeatureAccess(walletEnabled: true, browserEnabled: false)
        await gateway.refreshStatus()
        XCTAssertEqual(gateway.hubState, .setupRequired)
        signer.reportedVaultState = .awaitingBackup
        await gateway.refreshStatus()
        XCTAssertEqual(gateway.hubState, .backupIncomplete)
        signer.reportedVaultState = .rotationRequired
        await gateway.refreshStatus()
        XCTAssertEqual(gateway.hubState, .rotationRequired)
        XCTAssertTrue(gateway.canRotateForMainnet)
        signer.reportedVaultState = .locked
        await gateway.refreshStatus()
        XCTAssertEqual(gateway.hubState, .locked)
        signer.reportedVaultState = nil
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        XCTAssertEqual(gateway.hubState, .ready)
    }

    func testRecoveryUnavailableStateExplainsMissingHelper() async {
        let signer = FakeWalletSigner()
        signer.reportedVaultState = .missing
        let recovery = FakeWalletRecoveryView()
        recovery.isAvailable = false
        let gateway = WalletGateway(
            signer: signer,
            recoveryView: recovery,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"]
        )
        await gateway.refreshStatus()
        XCTAssertEqual(gateway.hubState, .recoveryUnavailable)
        let didBegin = await gateway.beginVaultCreation()
        XCTAssertFalse(didBegin)
        XCTAssertTrue(gateway.lastError?.contains("signed recovery helper") == true)
        XCTAssertFalse(gateway.diagnosticSnapshot().recoveryHelperAvailable)
    }

    func testRecoveryFailureSurvivesAuthoritativeStatusRefreshAndCanRetry() async {
        let signer = FakeWalletSigner()
        signer.reportedVaultState = .missing
        let recovery = FakeWalletRecoveryView()
        recovery.outcome = .failed
        let gateway = WalletGateway(
            signer: signer,
            recoveryView: recovery,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"]
        )
        await gateway.refreshStatus()
        let failed = await gateway.beginVaultCreation()
        XCTAssertFalse(failed)
        XCTAssertEqual(gateway.lastError, "failed")
        XCTAssertFalse(gateway.recoveryCeremonyActive)
        XCTAssertEqual(gateway.recoveryPresentationState, .idle)

        recovery.outcome = .completed
        let retried = await gateway.beginVaultCreation()
        XCTAssertTrue(retried)
        XCTAssertNil(gateway.lastError)
        XCTAssertEqual(recovery.presentedModes, [.create, .create])
    }

    func testDisablingAlphaLocksAndRevokesButRetainsReceiveSnapshot() async throws {
        let signer = FakeWalletSigner()
        let gateway = try browserFixtureGateway(signer: signer)
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        let grant = Task { await gateway.requestBrowserAccounts(origin: "https://dapp.test") }
        await Task.yield()
        gateway.approveBrowserOrigin()
        _ = await grant.value
        XCTAssertEqual(gateway.approvedBrowserOrigins, ["https://dapp.test"])

        gateway.applyFeatureAccess(walletEnabled: false, browserEnabled: false)

        XCTAssertEqual(gateway.status, .locked)
        XCTAssertNil(gateway.capability)
        XCTAssertEqual(gateway.accounts.first?.address, "0xabc")
        XCTAssertEqual(gateway.accountSnapshots.first?.balanceBaseUnits, signer.balanceBaseUnits)
        XCTAssertTrue(gateway.approvedBrowserOrigins.isEmpty)
        XCTAssertTrue(gateway.browserAccounts(origin: "https://dapp.test").isEmpty)
    }

    func testDiagnosticsAreCategorizedAndExcludeWalletIdentifiers() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        await gateway.refreshAccountSnapshots()
        await gateway.checkRPCHealth()
        let snapshot = gateway.diagnosticSnapshot()
        let text = snapshot.text()
        XCTAssertEqual(snapshot.rpcHealthCategory, "healthy")
        XCTAssertFalse(text.contains("0xabc"))
        XCTAssertFalse(text.contains("dapp.test"))
        XCTAssertFalse(text.contains(signer.balanceBaseUnits))
    }

    @MainActor
    func testUnavailableSignerHasNoCapability() {
        let gateway = WalletGateway(
            signer: UnavailableWalletSignerClient(),
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"]
        )
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
        XCTAssertEqual(gateway.capability?["protocol_version"] as? Int, 3)
        XCTAssertTrue(
            (gateway.capability?["supported_chains"] as? [String])?.contains(
                WalletNetworkCatalog.solanaDevnet.id
            ) == true
        )
        XCTAssertTrue(
            (gateway.capability?["supported_chains"] as? [String])?.contains(
                WalletNetworkCatalog.suiTestnet.id
            ) == true
        )

        let prepared = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": WalletGateway.sepoliaNetworkID,
            "account_id": "account-1",
            "action": [
                "type": "native_transfer",
                "recipient": "0x1111111111111111111111111111111111111111",
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

    /// The browser never inherits testnet authority from its environment flag.
    /// Positive fixtures carry explicitly signed testnet network/method grants.
    private func browserFixtureGateway(
        signer: WalletSignerClient,
        networkID: String = WalletGateway.sepoliaNetworkID
    ) throws -> WalletGateway {
        let network = try XCTUnwrap(WalletNetworkCatalog.descriptor(id: networkID))
        XCTAssertEqual(network.environment, .testnet, "Fixtures must not grant mainnet authority.")
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        var methods: Set<WalletConnectionMethod> = [.listAccounts, .sendTransaction]
        let signInAdapters: [WalletReviewedSignInAdapter]
        switch network.chain {
        case .evm:
            methods.formUnion([.switchNetwork, .signInWithEthereum])
            signInAdapters = [.init(format: .siwe, version: "1.0.0",
                implementationSHA256: String(repeating: "a", count: 64), networkIDs: [networkID])]
        case .solana:
            methods.insert(.signInWithSolana)
            signInAdapters = [.init(format: .siws, version: "1.0.0",
                implementationSHA256: String(repeating: "a", count: 64), networkIDs: [networkID])]
        case .sui:
            signInAdapters = []
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let capability = WalletCapabilityManifest(
            schemaVersion: 3, revision: 1, releaseStage: .invitedCanary,
            evidenceIndexSHA256: String(repeating: "f", count: 64),
            issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(600),
            networkGrants: [.init(networkID: networkID,
                capabilities: [.embeddedBrowser, .nativeTransfer, .standardizedSignIn],
                connectors: [.init(connector: .embeddedBrowser, ownership: .locusVault,
                    directions: [.locusVaultToDapp], methods: methods)])],
            approvedRegions: ["CA"], completedApprovals: WalletLaunchGate.requiredCanaryApprovals
        )
        let gate = try WalletLaunchGate(signedManifest: .init(manifest: capability,
            signatureBase64: key.signature(for: encoder.encode(capability)).base64EncodedString()),
            publicKey: key.publicKey, now: now)
        let review = WalletReviewManifest(schemaVersion: 2, revision: 1,
            issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(600),
            assets: [], evmContracts: [], explorerTemplates: [:], adapterIDs: [],
            connectors: [.init(connector: .embeddedBrowser, ownership: .locusVault,
                version: "1.0.0", artifactSHA256: String(repeating: "b", count: 64),
                directions: [.locusVaultToDapp], methods: methods,
                configurationSHA256: WalletConnectorReleaseConfiguration.digest(
                    for: .embeddedBrowser, values: [:]))], signInAdapters: signInAdapters)
        let registry = try WalletReviewRegistry(signedManifest: signedReview(review, key: key),
            publicKey: key.publicKey, now: now)
        return WalletGateway(signer: signer, connectionsClient: UnavailableWalletConnectionsClient(),
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
                          "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1"],
            launchGate: gate, reviewRegistry: registry, regionCode: "CA")
    }

    @MainActor
    func testBrowserAccountGrantIsOriginScopedAndRevoked() async throws {
        let signer = FakeWalletSigner()
        let gateway = try browserFixtureGateway(signer: signer)
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

    func testBrowserProviderEnvironmentFlagDoesNotGrantNetworkAuthority() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer,
            connectionsClient: UnavailableWalletConnectionsClient(), environment: [
                "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
                "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
            ])
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let accounts = await gateway.requestBrowserAccounts(origin: "https://dapp.test")
        XCTAssertNil(accounts)
        XCTAssertNil(gateway.pendingBrowserOriginGrant)
        XCTAssertFalse(gateway.canUseBrowserNetwork(WalletGateway.sepoliaNetworkID))
        XCTAssertFalse(gateway.canUseBrowserNetwork(WalletNetworkCatalog.ethereumMainnet.id))
    }

    func testGatewayRejectsSignerAutonomyForBrowserSource() async throws {
        let signer = FakeWalletSigner()
        signer.policyDecision = "allowed_by_session_policy"
        signer.policyID = "policy-1"
        let gateway = try browserFixtureGateway(signer: signer)
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let accountRequest = Task {
            await gateway.requestBrowserAccounts(origin: "https://dapp.test")
        }
        await Task.yield()
        gateway.approveBrowserOrigin()
        _ = await accountRequest.value
        do {
            _ = try await gateway.browserSendTransaction(
                origin: "https://dapp.test",
                transaction: ["from": "0xabc", "to": "0x1111111111111111111111111111111111111111", "value": "0x1"]
            )
            XCTFail("Browser requests must never consume an autonomous policy.")
        } catch {
            XCTAssertTrue(signer.executedIntentIDs.isEmpty)
            XCTAssertNil(gateway.pendingConfirmation)
        }
    }

    func testSignerInterruptionWithdrawsAgentCapabilityAndBrowserGrants() async throws {
        let signer = FakeWalletSigner()
        let gateway = try browserFixtureGateway(signer: signer)
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

    func testRevokingBrowserOriginCancelsPendingExactTransaction() async throws {
        let signer = FakeWalletSigner()
        let gateway = try browserFixtureGateway(signer: signer)
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
                "from": "0xabc", "to": "0x1111111111111111111111111111111111111111", "value": "0x1",
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

    func testRevokingBrowserOriginDuringSignerPresencePreventsExecution() async throws {
        let signer = FakeWalletSigner()
        var approval: CheckedContinuation<Void, Never>?
        signer.confirmationHandler = { _ in
            await withCheckedContinuation { approval = $0 }
        }
        let gateway = try browserFixtureGateway(signer: signer)
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let connect = Task { await gateway.requestBrowserAccounts(origin: "https://dapp.test") }
        for _ in 0..<100 where gateway.pendingBrowserOriginGrant == nil { await Task.yield() }
        gateway.approveBrowserOrigin()
        _ = await connect.value
        let send = Task {
            try await gateway.browserSendTransaction(origin: "https://dapp.test", transaction: [
                "from": "0xabc", "to": "0x1111111111111111111111111111111111111111", "value": "0x1",
            ])
        }
        for _ in 0..<100 where gateway.pendingConfirmation == nil { await Task.yield() }
        XCTAssertNotNil(gateway.pendingConfirmation)
        gateway.confirm(intentID: "intent-1")
        for _ in 0..<100 where approval == nil { await Task.yield() }
        XCTAssertNotNil(approval)
        gateway.revokeBrowserOrigin("https://dapp.test", reason: .navigation)
        XCTAssertNil(gateway.pendingConfirmation)
        XCTAssertTrue(signer.canceledIntentIDs.contains("intent-1"))
        approval?.resume()
        do { _ = try await send.value; XCTFail("Navigation must cancel an approval already in progress.") }
        catch { XCTAssertTrue(signer.executedIntentIDs.isEmpty) }
    }

    func testLockOrCancelDuringSignerPresencePreventsExecutionAndDuplicateReview() async {
        for lock in [false, true] {
            let signer = FakeWalletSigner()
            var approval: CheckedContinuation<Void, Never>?
            signer.confirmationHandler = { _ in
                await withCheckedContinuation { approval = $0 }
            }
            let gateway = WalletGateway(signer: signer, environment: [
                "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            ])
            let authorized = await gateway.authorizeSession()
            XCTAssertTrue(authorized)
            _ = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
                "network_id": WalletGateway.sepoliaNetworkID, "account_id": "account-1",
                "action": ["type": "native_transfer", "recipient": "0x1111111111111111111111111111111111111111", "amount_base_units": "1"],
                "maximum_fee_base_units": "20",
            ], source: .human)
            let first = Task { await gateway.confirmAndExecuteHumanIntent(intentID: "intent-1") }
            for _ in 0..<100 where approval == nil { await Task.yield() }
            XCTAssertNotNil(approval)
            let duplicate = await gateway.confirmAndExecuteHumanIntent(intentID: "intent-1")
            XCTAssertFalse(duplicate)
            XCTAssertEqual(signer.confirmedIntentIDs, ["intent-1"])
            if lock { gateway.lock() } else { gateway.cancelConfirmation(intentID: "intent-1") }
            approval?.resume()
            let executed = await first.value
            XCTAssertFalse(executed)
            XCTAssertNil(gateway.pendingConfirmation)
            XCTAssertTrue(signer.executedIntentIDs.isEmpty)
        }
    }

    func testConnectionLifecycleWithdrawsPreparedReviewAndSuspendedExecution() async {
        for event in ["remove", "disconnect", "account", "network", "methods", "peer", "expiry", "reconnect"] {
            let signer = FakeWalletSigner()
            let client = UnavailableWalletConnectionsClient()
            var approval: CheckedContinuation<Void, Never>?
            signer.confirmationHandler = { _ in
                await withCheckedContinuation { approval = $0 }
            }
            let gateway = WalletGateway(signer: signer, connectionsClient: client, environment: [
                "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            ])
            let authorized = await gateway.authorizeSession()
            XCTAssertTrue(authorized)
            let now = Date()
            func connection(changed: Bool) -> WalletConnectionRecord {
                WalletConnectionRecord(
                    id: "connection-1", direction: .locusVaultToDapp, connector: .walletConnect,
                    accountOwnership: .locusVault, peerName: "Fixture dapp", peerURL: "https://dapp.test",
                    peerID: changed && event == "peer" ? "other-peer" : "peer-1",
                    networkIDs: changed && event == "network" ? ["eip155:1"] : [WalletGateway.sepoliaNetworkID],
                    approvedMethods: changed && event == "methods" ? [.listAccounts] : [.sendTransaction],
                    accountIDs: changed && event == "account" ? ["other-account"] : ["account-1"],
                    state: changed && event == "expiry" ? .expired
                        : changed && event == "reconnect" ? .reconnecting : .connected,
                    createdAt: now, updatedAt: now,
                    expiresAt: now.addingTimeInterval(600)
                )
            }
            client.statusChangeHandler?(.init(connections: [connection(changed: false)], accounts: []))
            let source = WalletRequestSource.walletConnect(peerID: "peer-1", origin: "https://dapp.test", displayName: "Fixture dapp")
            _ = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
                "network_id": WalletGateway.sepoliaNetworkID, "account_id": "account-1",
                "action": ["type": "native_transfer", "recipient": "0x1111111111111111111111111111111111111111", "amount_base_units": "1"],
                "maximum_fee_base_units": "20",
            ], source: source)
            XCTAssertNotNil(gateway.pendingConfirmation, event)
            gateway.confirm(intentID: "intent-1")
            let execution = Task {
                await gateway.perform(tool: "wallet_execute_transaction", arguments: ["intent_id": "intent-1"], source: source)
            }
            for _ in 0..<100 where approval == nil { await Task.yield() }
            XCTAssertNotNil(approval, event)
            if event == "disconnect" {
                await gateway.disconnectWalletConnection(id: "connection-1")
            } else {
                client.statusChangeHandler?(.init(
                    connections: event == "remove" ? [] : [connection(changed: true)], accounts: []
                ))
            }
            XCTAssertNil(gateway.pendingConfirmation, event)
            XCTAssertTrue(signer.canceledIntentIDs.contains("intent-1"), event)
            approval?.resume()
            let result = await execution.value
            XCTAssertNotNil(result["error"], event)
            XCTAssertTrue(signer.executedIntentIDs.isEmpty, event)
            gateway.confirm(intentID: "intent-1")
            let replay = await gateway.perform(tool: "wallet_execute_transaction", arguments: ["intent_id": "intent-1"], source: source)
            XCTAssertNotNil(replay["error"], event)
        }
    }

    func testBrowserPersonalSignAcceptsOnlyCanonicalReviewedSIWE() async throws {
        let signer = FakeWalletSigner()
        signer.accountAddress = "0x1111111111111111111111111111111111111111"
        let now = Date()
        let gateway = try browserFixtureGateway(signer: signer)
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let accountRequest = Task {
            await gateway.requestBrowserAccounts(origin: "https://dapp.test")
        }
        await Task.yield()
        gateway.approveBrowserOrigin()
        _ = await accountRequest.value
        let signerAccounts = try await signer.listAccounts()
        let account = try XCTUnwrap(signerAccounts.first)
        let request = WalletStructuredAuthorizationRequest(
            format: .siwe, domain: "dapp.test", origin: "https://dapp.test",
            networkID: WalletGateway.sepoliaNetworkID,
            accountID: account.id, address: account.address,
            statement: "Sign in to the test dapp", uri: "https://dapp.test/session",
            nonce: "Nonce123", issuedAt: now.addingTimeInterval(-5),
            expirationTime: now.addingTimeInterval(300), notBefore: nil,
            requestID: "browser-siwe", resources: []
        )
        let message = try WalletStructuredAuthorization.canonicalMessage(
            request, account: account, now: now
        )
        let hexMessage = "0x" + Data(message.utf8).map {
            String(format: "%02x", $0)
        }.joined()

        let signature = try await gateway.browserSignInWithEthereum(
            origin: "https://dapp.test", params: [hexMessage, account.address]
        )
        XCTAssertEqual(signature, "0xsignature")
        do {
            _ = try await gateway.browserSignInWithEthereum(
                origin: "https://dapp.test",
                params: ["Please sign this arbitrary message", account.address]
            )
            XCTFail("Arbitrary personal_sign content must remain unavailable.")
        } catch {
            XCTAssertTrue(error is WalletStructuredAuthorizationError)
        }
    }

    func testBroadcastUnknownActivityPersistsAndReconcilesByReceipt() async {
        let signer = FakeWalletSigner()
        signer.executionError = .broadcastUnknown(
            transactionHash: "0xuncertain", message: "connection closed after submission"
        )
        let suiteName = "WalletGatewayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let gateway = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        _ = await gateway.perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": WalletGateway.sepoliaNetworkID,
            "account_id": "account-1",
            "action": [
                "type": "native_transfer", "recipient": "0x1111111111111111111111111111111111111111",
                "amount_base_units": "1",
            ],
            "maximum_fee_base_units": "20",
        ])
        gateway.confirm(intentID: "intent-1")
        let result = await gateway.perform(
            tool: "wallet_execute_transaction", arguments: ["intent_id": "intent-1"]
        )
        XCTAssertNotNil(result["error"])
        XCTAssertEqual(gateway.transactionHistory.first?.state, .broadcastUnknown)
        XCTAssertEqual(gateway.transactionHistory.first?.transactionHash, "0xuncertain")

        let reloaded = WalletGateway(
            signer: signer,
            environment: ["LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1"],
            userDefaults: defaults
        )
        XCTAssertEqual(reloaded.transactionHistory.first?.state, .broadcastUnknown)
        signer.browserRPCResponse = ["status": "0x1", "blockNumber": "0x2a"]
        await reloaded.refreshTransactionHistory()
        XCTAssertEqual(reloaded.transactionHistory.first?.state, .confirmed)
        XCTAssertEqual(reloaded.transactionHistory.first?.blockNumber, "0x2a")
        XCTAssertNil(reloaded.transactionHistory.first?.detail)
    }

    func testProviderScriptAnnouncesLocusWithoutImpersonatingOtherWallets() {
        let script = LocusWalletProviderScript.evmBootstrap
        XCTAssertTrue(script.contains("eip6963:announceProvider"))
        XCTAssertTrue(script.contains("wallet-standard:register-wallet"))
        XCTAssertTrue(script.contains("solana:signAndSendTransaction"))
        XCTAssertTrue(script.contains("solana:signIn"))
        XCTAssertTrue(script.contains("sui:signAndExecuteTransaction"))
        XCTAssertTrue(script.contains("supportedTransactionVersions"))
        XCTAssertTrue(script.contains("input.transaction.serialize"))
        XCTAssertFalse(script.contains("solana:signTransaction':"))
        XCTAssertFalse(script.contains("solana:signAllTransactions':"))
        XCTAssertFalse(script.contains("sui:signTransaction':"))
        XCTAssertTrue(script.contains("name: 'Locus Vault'"))
        XCTAssertTrue(script.contains("typeof globalThis.ethereum === 'undefined'"))
        XCTAssertTrue(script.contains("pending.size >= 32"))
        XCTAssertTrue(script.contains("crypto?.randomUUID"))
        XCTAssertTrue(script.contains("Object.freeze"))
        XCTAssertFalse(script.contains("535b3a6d-22e8-4f91-8a6f-bc9c6b2cafe1"))
        XCTAssertFalse(script.contains("isMetaMask"))
        XCTAssertFalse(script.contains("isPhantom"))
    }

    @MainActor
    func testBrowserWalletStandardGrantIsChainBound() async throws {
        let signer = FakeWalletSigner()
        signer.accountChain = .solana
        signer.accountAddress = "11111111111111111111111111111111"
        signer.accountNetworkIDs = [WalletNetworkCatalog.solanaDevnet.id]
        let gateway = try browserFixtureGateway(
            signer: signer, networkID: WalletNetworkCatalog.solanaDevnet.id
        )
        let authorized = await gateway.authorizeSession()
        XCTAssertTrue(authorized)
        let request = Task {
            await gateway.requestBrowserAccounts(
                origin: "https://solana.example",
                networkID: WalletNetworkCatalog.solanaDevnet.id
            )
        }
        await Task.yield()
        gateway.approveBrowserOrigin()
        let addresses = await request.value
        XCTAssertEqual(addresses, [signer.accountAddress])
        XCTAssertTrue(gateway.browserAccounts(
            origin: "https://solana.example",
            networkID: WalletGateway.sepoliaNetworkID
        ).isEmpty)
        let records = gateway.browserWalletStandardAccounts(
            origin: "https://solana.example",
            networkID: WalletNetworkCatalog.solanaDevnet.id
        )
        XCTAssertEqual(records.first?["address"] as? String, signer.accountAddress)
        XCTAssertEqual(
            Data(base64Encoded: try XCTUnwrap(records.first?["publicKeyBase64"] as? String))?.count,
            32
        )
    }
}
