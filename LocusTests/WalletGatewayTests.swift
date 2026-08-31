import CryptoKit
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
    var policyDecision = "signer_pending"
    var policyID: String?
    var executionError: WalletGateway.Error?
    var browserRPCResponse: Any = "0x1"
    var balanceBaseUnits = "1234500000000000000"
    var discoveredAssetRows: [[String: Any]] = []
    var indexedActivityRows: [[String: Any]] = []
    var indexedHeadBlock: String?
    var accountAddress = "0xabc"
    var accountChain: WalletChain = .evm
    var accountNetworkIDs = [WalletGateway.sepoliaNetworkID]
    var reportedVaultState: WalletVaultState?

    func signerStatus() async throws -> WalletSignerStatus {
        WalletSignerStatus(protocolVersion: 2,
                           vaultState: reportedVaultState ?? (sessionID == nil ? .locked : .unlocked),
                           sessionID: sessionID, accounts: try await listAccounts())
    }
    func beginRecoveryCeremony(
        mode: WalletRecoveryCeremonyMode
    ) async throws -> WalletRecoveryCeremonyLaunch {
        WalletRecoveryCeremonyLaunch(
            handle: .init(id: "ceremony-1", mode: mode), signerEndpoint: nil
        )
    }
    func cancelRecoveryCeremony(id: String) async throws -> WalletSignerStatus {
        try await signerStatus()
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
        browserRPCResponse
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
    let isAvailable = true
    var invalidationHandler: (() -> Void)?
    var outcome: WalletRecoveryCeremonyOutcome = .completed
    var presentedModes: [WalletRecoveryCeremonyMode] = []

    func present(launch: WalletRecoveryCeremonyLaunch) async throws
        -> WalletRecoveryCeremonyResult {
        presentedModes.append(launch.handle.mode)
        let status = outcome == .completed ? WalletSignerStatus(
            protocolVersion: 2, vaultState: .locked, sessionID: nil,
            accounts: [WalletAccount(
                id: "account-1", chain: .evm, address: "0xabc", label: "EVM",
                networkIDs: [WalletGateway.sepoliaNetworkID]
            )]
        ) : nil
        return WalletRecoveryCeremonyResult(
            ceremonyID: launch.handle.id, outcome: outcome,
            signerStatus: status, error: outcome == .failed ? "failed" : nil
        )
    }

    func cancel() {}
}

@MainActor
final class WalletGatewayTests: XCTestCase {
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
            schemaVersion: 2, revision: 1, releaseStage: .generalAvailability,
            evidenceIndexSHA256: String(repeating: "b", count: 64),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            enabledNetworkIDs: [limited.id],
            enabledCapabilities: [.nativeTransfer, .exactInputSwap],
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
            schemaVersion: 2, revision: 7, releaseStage: .invitedCanary,
            evidenceIndexSHA256: String(repeating: "a", count: 64),
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            enabledNetworkIDs: [WalletNetworkCatalog.ethereumMainnet.id],
            enabledCapabilities: [.nativeTransfer], approvedRegions: ["CA"],
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
            schemaVersion: 1, revision: 4, issuedAt: issuedAt,
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
            schemaVersion: 1, revision: 5,
            issuedAt: issuedAt.addingTimeInterval(120),
            expiresAt: issuedAt.addingTimeInterval(10 * 24 * 60 * 60),
            assets: [retained, extra], evmContracts: [],
            explorerTemplates: [:], adapterIDs: []
        )
        let narrowed = try registry.restricted(
            by: signedReview(restriction, key: privateKey),
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
            schemaVersion: 1, revision: 1, issuedAt: issuedAt,
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
            schemaVersion: 1, revision: 1, issuedAt: issuedAt,
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
            tokenProgramID: WalletSolanaTokenProgram.token2022.programID,
            recentBlockhash: blockhash, amountBaseUnits: "1", decimals: 6
        ))
        XCTAssertThrowsError(try WalletSolanaCanonicalSPLTransfer(
            feePayer: payer, sourceTokenAccount: source, mint: mint,
            destinationTokenAccount: source, recipientOwner: recipient,
            tokenProgramID: WalletSolanaTokenProgram.spl.programID,
            recentBlockhash: blockhash, amountBaseUnits: "1", decimals: 6
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

    func testSolanaProviderPreparesAndRechecksOnlyVerifiedSPLAccounts() async throws {
        let payer = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        let source = WalletSolanaBase58.encode(Data(repeating: 2, count: 32))
        let mint = WalletSolanaBase58.encode(Data(repeating: 3, count: 32))
        let destination = WalletSolanaBase58.encode(Data(repeating: 4, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 5, count: 32))
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let assetID = "solana:devnet/spl:\(mint)"
        var sourceAmount = "999999999"
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
                    values = [self.solanaTokenAccountJSON(
                        address: destination, mint: mint, owner: recipient,
                        amount: "0", decimals: 6, programID: programID
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
        let packet = try await client.prepare(request: request, feePayer: payer)
        XCTAssertEqual(packet.canonicalMessageDigest,
                       "sha256:1e22ab87cedf350790b6bc80e98799dfe043aa04d0e7e1374b9e98b1a3390c7f")
        XCTAssertEqual(packet.instructions.count, 1)
        XCTAssertEqual(
            packet.instructions[0].adapterID,
            WalletReviewedAdapters.solanaSPLTransferChecked
        )
        XCTAssertEqual(packet.instructions[0].canonicalArguments["decimals"], "6")
        let recheck = try await client.recheck(intentID: "spl-intent", packet: packet)
        XCTAssertEqual(recheck.resolvedAccountsDigest, packet.resolvedAccountsDigest)

        sourceAmount = "1"
        do {
            _ = try await client.recheck(intentID: "spl-intent", packet: packet)
            XCTFail("A substituted or depleted SPL source account must be rejected.")
        } catch WalletRPCError.simulation(let message) {
            XCTAssertTrue(message.contains("evidence changed"))
        }
    }

    func testSolanaProviderBindsGenesisBlockhashFeeSimulationAndRecheck() async throws {
        let blockhash = WalletSolanaBase58.encode(Data(repeating: 9, count: 32))
        let recipient = WalletSolanaBase58.encode(Data(repeating: 7, count: 32))
        var currentBlockHeight = 450
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
                result = ["context": ["slot": 42], "value": 5_000]
            case "simulateTransaction":
                result = [
                    "context": ["slot": 42],
                    "value": [
                        "err": NSNull(), "innerInstructions": [],
                        "logs": ["Program 11111111111111111111111111111111 success"],
                        "unitsConsumed": 150,
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
        XCTAssertEqual(packet.feeQuoteBaseUnits, "5000")
        XCTAssertEqual(packet.priorityFeeBaseUnits, "0")
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

        currentBlockHeight = 501
        do {
            _ = try await client.recheck(intentID: "intent-sol", packet: packet)
            XCTFail("A stale Solana blockhash must be rejected before signing.")
        } catch WalletRPCError.simulation(let message) {
            XCTAssertTrue(message.contains("expired"))
        }
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

    private func solanaTokenAccountJSON(
        address: String,
        mint: String,
        owner: String,
        amount: String,
        decimals: Int,
        programID: String
    ) -> [String: Any] {
        [
            "pubkey": address,
            "account": [
                "data": [
                    "program": "spl-token",
                    "parsed": [
                        "type": "account",
                        "info": [
                            "isNative": false, "mint": mint, "owner": owner,
                            "state": "initialized",
                            "tokenAmount": [
                                "amount": amount, "decimals": decimals,
                                "uiAmount": NSNull(), "uiAmountString": "ignored",
                            ],
                        ],
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
        let client = XPCWalletSignerClient()
        guard client.isAvailable else {
            throw XCTSkip("The direct-download test host did not embed WalletSigner.xpc.")
        }
        let status = try await client.signerStatus()
        XCTAssertEqual(status.protocolVersion, WalletGateway.protocolVersion)
        XCTAssertNil(status.sessionID)
        XCTAssertNotEqual(status.vaultState, .unlocked)
        client.lock()
    }
    #endif

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

    func testDisablingAlphaLocksAndRevokesButRetainsReceiveSnapshot() async {
        let signer = FakeWalletSigner()
        let gateway = WalletGateway(signer: signer, environment: [
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET": "1",
            "LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER": "1",
        ])
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
        XCTAssertEqual(gateway.capability?["protocol_version"] as? Int, 2)
        XCTAssertTrue(
            (gateway.capability?["supported_chains"] as? [String])?.contains(
                WalletNetworkCatalog.solanaDevnet.id
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

    func testGatewayRejectsSignerAutonomyForBrowserSource() async {
        let signer = FakeWalletSigner()
        signer.policyDecision = "allowed_by_session_policy"
        signer.policyID = "policy-1"
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
        XCTAssertTrue(script.contains("name: 'Locus Vault'"))
        XCTAssertTrue(script.contains("typeof globalThis.ethereum === 'undefined'"))
        XCTAssertTrue(script.contains("pending.size >= 32"))
        XCTAssertTrue(script.contains("crypto?.randomUUID"))
        XCTAssertTrue(script.contains("Object.freeze"))
        XCTAssertFalse(script.contains("535b3a6d-22e8-4f91-8a6f-bc9c6b2cafe1"))
        XCTAssertFalse(script.contains("isMetaMask"))
        XCTAssertFalse(script.contains("isPhantom"))
    }
}
