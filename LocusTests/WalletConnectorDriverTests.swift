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

        await emitAndWait(.accountsChanged(
            connectionID: restoredID, accounts: [replacement]
        ), from: driver, to: client)
        status = try await client.status()
        XCTAssertEqual(status.connections.first?.accountIDs, Set([replacement.id]))
        XCTAssertEqual(status.accounts, [replacement])

        await emitAndWait(.networksChanged(
            connectionID: restoredID, networkIDs: []
        ), from: driver, to: client)
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
        await emitAndWait(.expired(connectionID: expiredID), from: expiryDriver, to: expiryClient)
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

    func testInvalidAccountEventsPublishRevocationAndRemoveAccounts() async throws {
        let original = externalAccount(id: "metamask-1")
        let replacement = externalAccount(id: "metamask-2")
        for changed in [[], [replacement, replacement], [locusAccount()]] {
            let id = UUID().uuidString
            let driver = FixtureWalletConnectorDriver(
                connector: .metamask,
                restoreSessions: [session(id: id, connector: .metamask, account: original)]
            )
            let client = DirectWalletConnectionsClient(drivers: [driver])
            _ = try await client.status()

            let published = await emitAndWait(
                .accountsChanged(connectionID: id, accounts: changed), from: driver, to: client
            )
            XCTAssertEqual(published?.connections.first?.state, .revoked)
            XCTAssertEqual(published?.accounts, [])
            let authoritative = try await client.status()
            XCTAssertEqual(authoritative.connections, published?.connections)
            XCTAssertEqual(authoritative.accounts, published?.accounts)
        }
    }

    func testNetworkRestrictionPublishesExactNarrowedGrant() async throws {
        let id = UUID().uuidString
        let account = externalAccount(id: "metamask-1")
        let original = session(id: id, connector: .metamask, account: account)
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [WalletConnectorSession(
                connectionID: id, peerName: original.peerName,
                peerURL: nil, peerID: nil,
                networkIDs: [WalletGateway.sepoliaNetworkID, "eip155:1"],
                approvedMethods: original.approvedMethods,
                accounts: [account], expiresAt: original.expiresAt
            )]
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])
        _ = try await client.status()
        let published = await emitAndWait(
            .networksChanged(connectionID: id, networkIDs: [WalletGateway.sepoliaNetworkID]),
            from: driver, to: client
        )
        XCTAssertEqual(published?.connections.first?.networkIDs, [WalletGateway.sepoliaNetworkID])
        XCTAssertEqual(published?.connections.first?.state, .connected)
        XCTAssertEqual(published?.accounts, [account])
        let authoritative = try await client.status()
        XCTAssertEqual(authoritative.connections, published?.connections)
    }

    func testOtherDriverAndRevokedSessionCallbacksCannotReplacePublicAccounts() async throws {
        let id = UUID().uuidString
        let barrierID = UUID().uuidString
        let slushID = UUID().uuidString
        let original = externalAccount(id: "metamask-1")
        let replacement = externalAccount(id: "metamask-2")
        let slushAccount = WalletAccount(
            id: "slush-fixture", chain: .sui, address: "0x" + String(repeating: "1", count: 64),
            label: "Slush", networkIDs: ["sui:testnet"], ownership: .external(connectorID: .slush)
        )
        let metamask = FixtureWalletConnectorDriver(
            connector: .metamask, restoreSessions: [
                session(id: id, connector: .metamask, account: original),
                session(id: barrierID, connector: .metamask, account: replacement),
            ]
        )
        let slush = FixtureWalletConnectorDriver(
            connector: .slush, restoreSessions: [WalletConnectorSession(
                connectionID: slushID, peerName: "Slush", peerURL: nil, peerID: nil,
                networkIDs: ["sui:testnet"], approvedMethods: [.listAccounts, .sendTransaction],
                accounts: [slushAccount], expiresAt: Date().addingTimeInterval(3_600)
            )]
        )
        let client = DirectWalletConnectionsClient(drivers: [metamask, slush])
        _ = try await client.status()

        // The valid event on the same FIFO stream acknowledges consumption of
        // the preceding malicious event, without scheduler-yield guesses.
        slush.emit(.accountsChanged(connectionID: id, accounts: [replacement]))
        _ = await emitAndWait(
            .accountsChanged(connectionID: slushID, accounts: [slushAccount]), from: slush, to: client
        )
        var status = try await client.status()
        XCTAssertEqual(status.connections.first(where: { $0.id == id })?.accountIDs, [original.id])
        XCTAssertTrue(status.accounts.contains(original))

        _ = try await client.disconnect(connectionID: id)
        metamask.emit(.accountsChanged(connectionID: id, accounts: [original]))
        _ = await emitAndWait(
            .accountsChanged(connectionID: barrierID, accounts: [replacement]), from: metamask, to: client
        )
        status = try await client.status()
        XCTAssertEqual(status.connections.first(where: { $0.id == id })?.state, .revoked)
        XCTAssertFalse(status.accounts.contains(original), "Late events cannot resurrect removed public accounts")
        XCTAssertTrue(status.accounts.contains(replacement))
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

    func testLatePairingApprovalCannotRestoreCanceledOrSuspendedAuthority() async throws {
        for suspend in [false, true] {
            let id = UUID().uuidString
            let account = locusAccount()
            let driver = FixtureWalletConnectorDriver(
                connector: .walletConnect,
                connectSession: session(id: id, connector: .walletConnect, account: account),
                proposal: proposal(id: id)
            )
            let client = DirectWalletConnectionsClient(drivers: [driver])
            let enteredReview = expectation(description: "Pairing awaits exact proposal approval")
            var approval: CheckedContinuation<Bool, Never>?
            client.proposalApprovalHandler = { _ in
                await withCheckedContinuation { continuation in
                    approval = continuation
                    enteredReview.fulfill()
                }
            }
            let pairing = Task { try await client.beginPairing(walletConnectRequest(id: id, account: account)) }
            await fulfillment(of: [enteredReview], timeout: 1)
            if suspend {
                try await client.suspendAll()
            } else {
                _ = try await client.cancelPairing(requestID: id)
            }
            let canceled = try await client.status()
            XCTAssertEqual(canceled.connections.first?.state, .revoked)
            XCTAssertTrue(canceled.accounts.isEmpty)
            approval?.resume(returning: true)
            do {
                _ = try await pairing.value
                XCTFail("A late vendor completion must not restore canceled authority")
            } catch let error as WalletConnectorRuntimeError {
                XCTAssertEqual(error, .sdkFailure("rejected"))
            }
            let completed = try await client.status()
            XCTAssertEqual(completed.connections, canceled.connections)
            XCTAssertTrue(completed.accounts.isEmpty)
            XCTAssertEqual(driver.acceptedProposalCount, 0, "Revoked review must not reach vendor approval")
            XCTAssertTrue(driver.disconnectedIDs.isEmpty, "No vendor session was approved")
        }
    }

    func testLateSDKConnectionCompletionIsDisconnectedWithoutRestoringAuthority() async throws {
        let id = UUID().uuidString
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            connectSession: session(id: id, connector: .metamask, account: externalAccount(id: "metamask-1"))
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])
        let enteredSDK = expectation(description: "Vendor connection is pending")
        var completion: CheckedContinuation<Void, Never>?
        driver.connectCompletionHandler = {
            await withCheckedContinuation { continuation in
                completion = continuation
                enteredSDK.fulfill()
            }
        }
        let pairing = Task { try await client.beginPairing(externalRequest(id: id)) }
        await fulfillment(of: [enteredSDK], timeout: 1)
        _ = try await client.cancelPairing(requestID: id)
        let canceled = try await client.status()
        completion?.resume()
        do {
            _ = try await pairing.value
            XCTFail("Canceled SDK completion must not install its returned session")
        } catch let error as WalletConnectorRuntimeError {
            XCTAssertEqual(error, .sessionNotFound)
        }
        let completed = try await client.status()
        XCTAssertEqual(completed.connections, canceled.connections)
        XCTAssertEqual(completed.connections.first?.state, .revoked)
        XCTAssertTrue(completed.accounts.isEmpty)
        XCTAssertEqual(driver.disconnectedIDs, [id])
    }

    func testDisconnectPublishesRevocationBeforeAwaitingVendorCleanup() async throws {
        let id = UUID().uuidString
        let account = externalAccount(id: "metamask-1")
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [session(id: id, connector: .metamask, account: account)]
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])
        _ = try await client.status()
        let enteredCleanup = expectation(description: "Vendor cleanup is pending")
        var cleanup: CheckedContinuation<Void, Never>?
        var projection: WalletConnectionServiceStatus?
        client.statusChangeHandler = { projection = $0 }
        driver.disconnectHandler = {
            await withCheckedContinuation { continuation in
                cleanup = continuation
                enteredCleanup.fulfill()
            }
        }
        let disconnect = Task { try await client.disconnect(connectionID: id) }
        await fulfillment(of: [enteredCleanup], timeout: 1)
        let pending = try await client.status()
        XCTAssertEqual(pending.connections.first?.state, .revoked)
        XCTAssertTrue(pending.accounts.isEmpty)
        XCTAssertEqual(projection?.connections, pending.connections)
        XCTAssertEqual(projection?.accounts, [])
        cleanup?.resume()
        let completed = try await disconnect.value
        XCTAssertEqual(completed.connections, pending.connections)
        XCTAssertTrue(completed.accounts.isEmpty)
    }

    func testFreshPairingIsRejectedWhileVendorSuspensionIsPending() async throws {
        let id = UUID().uuidString
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            connectSession: session(id: id, connector: .metamask, account: externalAccount(id: "metamask-1"))
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])
        _ = try await client.status()
        let enteredCleanup = expectation(description: "Vendor suspension is pending")
        var cleanup: CheckedContinuation<Void, Never>?
        driver.suspendHandler = {
            await withCheckedContinuation { continuation in
                cleanup = continuation
                enteredCleanup.fulfill()
            }
        }
        let suspension = Task { try await client.suspendAll() }
        await fulfillment(of: [enteredCleanup], timeout: 1)
        do {
            _ = try await client.beginPairing(externalRequest(id: id))
            XCTFail("New pairing must not enter a driver while its sessions are being suspended")
        } catch let error as WalletConnectorRuntimeError {
            XCTAssertEqual(error, .sessionNotFound)
        }
        XCTAssertEqual(driver.connectCount, 0)
        cleanup?.resume()
        try await suspension.value
        let status = try await client.status()
        XCTAssertTrue(status.connections.isEmpty)
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testRestorationCompletedAfterSuspensionCannotInstallStaleSessions() async throws {
        let id = UUID().uuidString
        let driver = FixtureWalletConnectorDriver(
            connector: .metamask,
            restoreSessions: [session(id: id, connector: .metamask, account: externalAccount(id: "metamask-1"))]
        )
        let client = DirectWalletConnectionsClient(drivers: [driver])
        let enteredRestore = expectation(description: "Vendor restoration is pending")
        var completion: CheckedContinuation<Void, Never>?
        driver.restoreHandler = {
            await withCheckedContinuation { continuation in
                completion = continuation
                enteredRestore.fulfill()
            }
        }
        let restoration = Task { try await client.status() }
        await fulfillment(of: [enteredRestore], timeout: 1)
        try await client.suspendAll()
        completion?.resume()
        do {
            _ = try await restoration.value
            XCTFail("A pre-suspension restoration cannot create post-suspension authority")
        } catch let error as WalletConnectorRuntimeError {
            XCTAssertEqual(error, .sessionNotFound)
        }
        XCTAssertEqual(driver.disconnectedIDs, [id])
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

    @discardableResult
    private func emitAndWait(
        _ event: WalletConnectorEvent,
        from driver: FixtureWalletConnectorDriver,
        to client: DirectWalletConnectionsClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> WalletConnectionServiceStatus? {
        let published = expectation(description: "Connector event updates the authoritative projection")
        published.assertForOverFulfill = true
        var projection: WalletConnectionServiceStatus?
        client.statusChangeHandler = { status in
            projection = status
            published.fulfill()
        }
        defer { client.statusChangeHandler = nil }
        driver.emit(event)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertNotNil(projection, file: file, line: line)
        return projection
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
    private(set) var connectCount = 0
    private(set) var acceptedProposalCount = 0
    private(set) var disconnectedIDs: [String] = []
    private(set) var suspendCount = 0
    var disconnectHandler: (@MainActor () async -> Void)?
    var connectCompletionHandler: (@MainActor () async -> Void)?
    var suspendHandler: (@MainActor () async -> Void)?
    var restoreHandler: (@MainActor () async -> Void)?

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
        await restoreHandler?()
        if let restoreError { throw restoreError }
        return restoreSessions
    }

    func connect(
        _ request: WalletConnectorPairingRequest,
        approve: @escaping @MainActor (WalletConnectionProposalReview) async -> Bool
    ) async throws -> WalletConnectorSession {
        connectCount += 1
        if let connectError { throw connectError }
        if let proposal {
            approvalCount += 1
            guard await approve(proposal) else {
                throw WalletConnectorRuntimeError.sdkFailure("rejected")
            }
            acceptedProposalCount += 1
        }
        guard let connectSession,
              connectSession.connectionID == request.requestID else {
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        await connectCompletionHandler?()
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
        await disconnectHandler?()
    }

    func suspend() async {
        suspendCount += 1
        await suspendHandler?()
    }

    func emit(_ event: WalletConnectorEvent) {
        continuation.yield(event)
    }
}
