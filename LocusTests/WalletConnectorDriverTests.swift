import XCTest
@testable import Locus

@MainActor
final class WalletConnectorDriverTests: XCTestCase {
    func testWalletConnectFixtureCoversApprovalAndRejection() async throws {
        let approvedID = UUID().uuidString
        let account = locusAccount()
        let approvedDriver = FixtureWalletConnectorDriver(
            connector: .walletConnect,
            connectSession: session(
                id: approvedID, connector: .walletConnect, account: account
            ),
            proposal: proposal(id: approvedID)
        )
        let approvedClient = DirectWalletConnectionsClient(
            drivers: [approvedDriver]
        )
        approvedClient.proposalApprovalHandler = { _ in true }

        let approved = try await approvedClient.beginPairing(
            walletConnectRequest(id: approvedID, account: account)
        )
        XCTAssertEqual(approved.connections.first?.state, .connected)
        XCTAssertEqual(approved.accounts, [account])
        XCTAssertEqual(approvedDriver.approvalCount, 1)

        let rejectedID = UUID().uuidString
        let rejectedDriver = FixtureWalletConnectorDriver(
            connector: .walletConnect,
            connectSession: session(
                id: rejectedID, connector: .walletConnect, account: account
            ),
            proposal: proposal(id: rejectedID)
        )
        let rejectedClient = DirectWalletConnectionsClient(
            drivers: [rejectedDriver]
        )
        rejectedClient.proposalApprovalHandler = { _ in false }
        do {
            _ = try await rejectedClient.beginPairing(
                walletConnectRequest(id: rejectedID, account: account)
            )
            XCTFail("Rejected proposals must not establish a connection.")
        } catch let error as WalletConnectorRuntimeError {
            XCTAssertEqual(error, .sdkFailure("rejected"))
        }
        let rejectedStatus = try await rejectedClient.status()
        XCTAssertEqual(rejectedStatus.connections.first?.state, .failed)
    }

    func testFixtureRestoreAccountNetworkDisconnectAndExpiryEvents() async throws {
        let restoredID = UUID().uuidString
        let original = externalAccount(id: "metamask-1")
        let replacement = externalAccount(id: "metamask-2")
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [
                session(id: restoredID, connector: .metamask, account: original),
            ]
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])

        var status = try await client.status()
        XCTAssertEqual(status.connections.first?.state, .connected)
        XCTAssertEqual(status.accounts, [original])

        driver.emit(.accountsChanged(
            connectionID: restoredID, accounts: [replacement]
        ))
        await drainEvents()
        status = try await client.status()
        XCTAssertEqual(status.connections.first?.accountIDs, Set([replacement.id]))
        XCTAssertEqual(status.accounts, [replacement])

        driver.emit(.networksChanged(
            connectionID: restoredID, networkIDs: []
        ))
        await drainEvents()
        status = try await client.status()
        XCTAssertEqual(status.connections.first?.state, .revoked)
        XCTAssertTrue(status.accounts.isEmpty)

        let disconnectedID = UUID().uuidString
        let disconnectDriver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [
                session(
                    id: disconnectedID, connector: .metamask, account: original
                ),
            ]
        )
        let disconnectClient = DirectWalletConnectionsClient(
            drivers: [disconnectDriver]
        )
        _ = try await disconnectClient.status()
        status = try await disconnectClient.disconnect(
            connectionID: disconnectedID
        )
        XCTAssertEqual(status.connections.first?.state, .revoked)
        XCTAssertEqual(disconnectDriver.disconnectedIDs, [disconnectedID])

        let expiredID = UUID().uuidString
        let expiryDriver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [
                session(id: expiredID, connector: .metamask, account: original),
            ]
        )
        let expiryClient = DirectWalletConnectionsClient(
            drivers: [expiryDriver]
        )
        _ = try await expiryClient.status()
        expiryDriver.emit(.expired(connectionID: expiredID))
        await drainEvents()
        status = try await expiryClient.status()
        XCTAssertEqual(status.connections.first?.state, .expired)
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testFixtureFailsClosedForMissingConfigurationTimeoutAndVendorError() async throws {
        let requestID = UUID().uuidString
        let request = externalRequest(id: requestID)
        let unavailable = FixtureWalletConnectorDriver(
            connector: .metamask, isConfigured: false
        )
        let unavailableClient = DirectWalletConnectionsClient(
            drivers: [unavailable]
        )
        do {
            _ = try await unavailableClient.beginPairing(request)
            XCTFail("Missing release configuration must fail closed.")
        } catch let error as WalletConnectorRuntimeError {
            XCTAssertEqual(error, .unconfigured("MetaMask"))
        }

        for failure in [
            WalletConnectorRuntimeError.sdkFailure("timeout"),
            WalletConnectorRuntimeError.sdkFailure("vendor rejected request"),
        ] {
            let driver = FixtureWalletConnectorDriver(
                connector: .metamask, connectError: failure
            )
            let client = DirectWalletConnectionsClient(drivers: [driver])
            let current = externalRequest(id: UUID().uuidString)
            do {
                _ = try await client.beginPairing(current)
                XCTFail("Connector errors must not establish a connection.")
            } catch let error as WalletConnectorRuntimeError {
                XCTAssertEqual(error, failure)
            }
            let failedStatus = try await client.status()
            XCTAssertEqual(failedStatus.connections.first?.state, .failed)
        }
    }

    func testFixtureSuspendCancelsAuthorityAndMovesConnectedSessionsToReconnect() async throws {
        let connectionID = UUID().uuidString
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [
                session(
                    id: connectionID, connector: .metamask,
                    account: externalAccount(id: "metamask-1")
                ),
            ]
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])
        _ = try await client.status()

        try await client.suspendAll()

        let suspendedStatus = try await client.status()
        XCTAssertEqual(suspendedStatus.connections.first?.state, .reconnecting)
        XCTAssertEqual(driver.suspendCount, 1)
    }

    private func walletConnectRequest(
        id: String,
        account: WalletAccount
    ) -> WalletConnectorPairingRequest {
        WalletConnectorPairingRequest(
            requestID: id, connector: .walletConnect,
            direction: .locusVaultToDapp,
            requestedNetworkIDs: [WalletGateway.sepoliaNetworkID],
            requestedMethods: [.listAccounts, .sendTransaction],
            expiresAt: Date().addingTimeInterval(300),
            pairingURI: "wc:fixture@2?relay-protocol=irn&symKey="
                + String(repeating: "a", count: 64),
            offeredAccounts: [account]
        )
    }

    private func externalRequest(id: String) -> WalletConnectorPairingRequest {
        WalletConnectorPairingRequest(
            requestID: id, connector: .metamask,
            direction: .externalAccountToLocus,
            requestedNetworkIDs: [WalletGateway.sepoliaNetworkID],
            requestedMethods: [.listAccounts, .sendTransaction],
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func proposal(id: String) -> WalletConnectionProposalReview {
        WalletConnectionProposalReview(
            requestID: id, peerName: "Fixture dapp",
            peerURL: "https://app.example",
            namespaces: [
                WalletConnectionNamespaceProposal(
                    namespace: .eip155,
                    networkIDs: [WalletGateway.sepoliaNetworkID],
                    methods: [.listAccounts, .sendTransaction],
                    events: [.accountsChanged, .networkChanged, .disconnected]
                ),
            ],
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    private func session(
        id: String,
        connector: WalletConnectionConnector,
        account: WalletAccount
    ) -> WalletConnectorSession {
        WalletConnectorSession(
            connectionID: id,
            peerName: connector == .walletConnect ? "Fixture dapp" : "MetaMask",
            peerURL: connector == .walletConnect ? "https://app.example" : nil,
            peerID: connector == .walletConnect ? "fixture-peer" : nil,
            networkIDs: [WalletGateway.sepoliaNetworkID],
            approvedMethods: [.listAccounts, .sendTransaction],
            accounts: [account], expiresAt: Date().addingTimeInterval(3_600)
        )
    }

    private func locusAccount() -> WalletAccount {
        WalletAccount(
            id: "locus-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "Locus Vault", networkIDs: [WalletGateway.sepoliaNetworkID],
            ownership: .locusVault
        )
    }

    private func externalAccount(id: String) -> WalletAccount {
        WalletAccount(
            id: id, chain: .evm,
            address: id == "metamask-1"
                ? "0x1111111111111111111111111111111111111111"
                : "0x2222222222222222222222222222222222222222",
            label: "MetaMask", networkIDs: [WalletGateway.sepoliaNetworkID],
            ownership: .external(connectorID: .metamask)
        )
    }

    private func drainEvents() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

@MainActor
private final class FixtureWalletConnectorDriver: WalletConnectorDriver {
    let connector: WalletConnectionConnector
    let isConfigured: Bool
    let events: AsyncStream<WalletConnectorEvent>
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)?

    private let continuation: AsyncStream<WalletConnectorEvent>.Continuation
    private let restoreSessions: [WalletConnectorSession]
    private let restoreError: WalletConnectorRuntimeError?
    private let connectSession: WalletConnectorSession?
    private let connectError: WalletConnectorRuntimeError?
    private let proposal: WalletConnectionProposalReview?

    private(set) var approvalCount = 0
    private(set) var disconnectedIDs: [String] = []
    private(set) var suspendCount = 0

    init(
        connector: WalletConnectionConnector,
        isConfigured: Bool = true,
        restoreSessions: [WalletConnectorSession] = [],
        restoreError: WalletConnectorRuntimeError? = nil,
        connectSession: WalletConnectorSession? = nil,
        connectError: WalletConnectorRuntimeError? = nil,
        proposal: WalletConnectionProposalReview? = nil
    ) {
        self.connector = connector
        self.isConfigured = isConfigured
        self.restoreSessions = restoreSessions
        self.restoreError = restoreError
        self.connectSession = connectSession
        self.connectError = connectError
        self.proposal = proposal
        let stream = AsyncStream.makeStream(of: WalletConnectorEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    deinit { continuation.finish() }

    func restore() async throws -> [WalletConnectorSession] {
        if let restoreError { throw restoreError }
        return restoreSessions
    }

    func connect(
        _ request: WalletConnectorPairingRequest,
        approve: @escaping @MainActor (WalletConnectionProposalReview) async -> Bool
    ) async throws -> WalletConnectorSession {
        if let connectError { throw connectError }
        if let proposal {
            approvalCount += 1
            guard await approve(proposal) else {
                throw WalletConnectorRuntimeError.sdkFailure("rejected")
            }
        }
        guard let connectSession,
              connectSession.connectionID == request.requestID else {
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        return connectSession
    }

    func execute(
        _ request: WalletExternalExecutionRequest
    ) async throws -> WalletExternalExecutionResult {
        throw WalletConnectorRuntimeError.sdkFailure("fixture has no transaction result")
    }

    func cancel(requestID: String) async {}

    func disconnect(connectionID: String) async {
        disconnectedIDs.append(connectionID)
    }

    func suspend() async { suspendCount += 1 }

    func emit(_ event: WalletConnectorEvent) {
        continuation.yield(event)
    }
}
