import Foundation

/// Direct-download connector coordinator. Vendor SDK state lives in each
/// driver and never enters this public projection or WalletPublicStore.
@MainActor
final class DirectWalletConnectionsClient: WalletConnectionsClient {
    private static let maximumConnections = 64
    private static let maximumPairingLifetime: TimeInterval = 10 * 60

    let isAvailable = true
    var invalidationHandler: (() -> Void)?
    var statusChangeHandler: (@MainActor (WalletConnectionServiceStatus) -> Void)?
    var proposalApprovalHandler: (@MainActor (WalletConnectionProposalReview) async -> Bool)?
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)? {
        didSet {
            for driver in drivers.values {
                driver.dappRequestHandler = dappRequestHandler
            }
        }
    }

    private var drivers: [WalletConnectionConnector: WalletConnectorDriver]
    private var connections: [String: WalletConnectionRecord] = [:]
    private var accounts: [String: WalletAccount] = [:]
    private var eventTasks: [WalletConnectionConnector: Task<Void, Never>] = [:]
    private var didRestore = false

    init(
        drivers: [WalletConnectorDriver]? = nil,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let resolved = drivers ?? WalletConnectorDriverFactory.make(
            bundle: bundle, environment: environment
        )
        self.drivers = Dictionary(uniqueKeysWithValues: resolved.map {
            ($0.connector, $0)
        })
        for driver in resolved {
            eventTasks[driver.connector] = Task { [weak self, weak driver] in
                guard let driver else { return }
                for await event in driver.events {
                    guard !Task.isCancelled else { return }
                    self?.apply(event)
                }
            }
        }
    }

    deinit {
        for task in eventTasks.values { task.cancel() }
    }

    func status() async throws -> WalletConnectionServiceStatus {
        try await restoreIfNeeded()
        expireStaleConnections()
        return currentStatus()
    }

    func beginPairing(
        _ request: WalletConnectorPairingRequest
    ) async throws -> WalletConnectionServiceStatus {
        try await restoreIfNeeded()
        try validate(request)
        guard connections.count < Self.maximumConnections else {
            throw WalletConnectorRuntimeError.tooManyConnections
        }
        guard connections[request.requestID] == nil else {
            throw WalletConnectorRuntimeError.duplicateRequest
        }
        guard let driver = drivers[request.connector] else {
            throw WalletConnectorRuntimeError.unsupportedConnector
        }
        guard driver.isConfigured else {
            throw WalletConnectorRuntimeError.unconfigured(
                Self.displayName(request.connector)
            )
        }

        let now = Date()
        var record = WalletConnectionRecord(
            id: request.requestID, direction: request.direction,
            connector: request.connector,
            accountOwnership: Self.ownership(for: request.connector),
            peerName: Self.displayName(request.connector), peerURL: nil,
            networkIDs: request.requestedNetworkIDs,
            approvedMethods: request.requestedMethods, accountIDs: [],
            state: .pairing, createdAt: now, updatedAt: now,
            expiresAt: request.expiresAt
        )
        connections[record.id] = record
        record = record.transitioning(to: .proposalPending) ?? record
        connections[record.id] = record
        do {
            let session = try await driver.connect(request) { [weak self] proposal in
                guard let handler = self?.proposalApprovalHandler else { return false }
                if let current = self?.connections[request.requestID],
                   let awaitingApproval = current.transitioning(to: .approvalPending) {
                    self?.connections[request.requestID] = awaitingApproval
                }
                return await handler(proposal)
            }
            try validate(session, for: request)
            record = WalletConnectionRecord(
                id: request.requestID, direction: request.direction,
                connector: request.connector,
                accountOwnership: Self.ownership(for: request.connector),
                peerName: session.peerName, peerURL: session.peerURL,
                peerID: session.peerID,
                networkIDs: session.networkIDs,
                approvedMethods: session.approvedMethods,
                accountIDs: Set(session.accounts.map(\.id)),
                state: .connected, createdAt: now, updatedAt: Date(),
                expiresAt: session.expiresAt
            )
            connections[record.id] = record
            replaceAccounts(for: record, with: session.accounts)
            return currentStatus()
        } catch {
            connections[record.id] = record.transitioning(to: .failed) ?? record
            throw error
        }
    }

    func cancelPairing(requestID: String) async throws -> WalletConnectionServiceStatus {
        guard let current = connections[requestID],
              [.pairing, .proposalPending, .approvalPending].contains(current.state),
              let revoked = current.transitioning(to: .revoked) else {
            throw WalletConnectorRuntimeError.sessionNotFound
        }
        await drivers[current.connector]?.cancel(requestID: requestID)
        connections[requestID] = revoked
        removeAccounts(for: current)
        return currentStatus()
    }

    func executeExternal(
        _ request: WalletExternalExecutionRequest
    ) async throws -> WalletExternalExecutionResult {
        try await restoreIfNeeded()
        let binding = request.request.binding
        guard let connection = connections[binding.connectionID],
              let account = accounts[binding.accountID],
              let driver = drivers[binding.connector] else {
            throw WalletConnectorRuntimeError.sessionNotFound
        }
        try WalletConnectionAuthority.validate(binding, against: connection)
        guard account.ownership == connection.accountOwnership,
              account.ownership.connectorID == binding.connector.externalConnectorID else {
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        let result = try await driver.execute(request)
        try WalletConnectionAuthority.validateCallback(
            expected: binding, received: result.binding
        )
        return result
    }

    func disconnect(connectionID: String) async throws -> WalletConnectionServiceStatus {
        guard let current = connections[connectionID],
              let revoked = current.transitioning(to: .revoked) else {
            throw WalletConnectorRuntimeError.sessionNotFound
        }
        await drivers[current.connector]?.disconnect(connectionID: connectionID)
        connections[connectionID] = revoked
        removeAccounts(for: current)
        return currentStatus()
    }

    func suspendAll() async throws {
        let now = Date()
        for driver in drivers.values { await driver.suspend() }
        for (id, connection) in connections where !connection.state.isTerminal {
            connections[id] = connection.transitioning(
                to: connection.state == .connected ? .reconnecting : .revoked,
                at: now
            ) ?? connection
        }
    }

    private func restoreIfNeeded() async throws {
        guard !didRestore else { return }
        didRestore = true
        do {
            for driver in drivers.values where driver.isConfigured {
                for session in try await driver.restore() {
                    try installRestored(session, from: driver)
                }
            }
        } catch {
            didRestore = false
            throw error
        }
    }

    private func installRestored(
        _ session: WalletConnectorSession,
        from driver: WalletConnectorDriver
    ) throws {
        guard UUID(uuidString: session.connectionID) != nil,
              session.expiresAt > Date(), !session.accounts.isEmpty,
              session.accounts.allSatisfy({
                  $0.ownership == Self.ownership(for: driver.connector)
                      && Set($0.networkIDs).isSubset(of: session.networkIDs)
              }) else {
            Task { await driver.disconnect(connectionID: session.connectionID) }
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        let now = Date()
        let record = WalletConnectionRecord(
            id: session.connectionID,
            direction: driver.connector == .walletConnect
                ? .locusVaultToDapp : .externalAccountToLocus,
            connector: driver.connector,
            accountOwnership: Self.ownership(for: driver.connector),
            peerName: session.peerName, peerURL: session.peerURL,
            peerID: session.peerID, networkIDs: session.networkIDs,
            approvedMethods: session.approvedMethods,
            accountIDs: Set(session.accounts.map(\.id)), state: .connected,
            createdAt: now, updatedAt: now, expiresAt: session.expiresAt
        )
        connections[record.id] = record
        replaceAccounts(for: record, with: session.accounts)
    }

    private func validate(_ request: WalletConnectorPairingRequest) throws {
        let now = Date()
        guard UUID(uuidString: request.requestID) != nil,
              request.expiresAt > now,
              request.expiresAt.timeIntervalSince(now) <= Self.maximumPairingLifetime,
              !request.requestedNetworkIDs.isEmpty,
              !request.requestedMethods.isEmpty else {
            throw WalletConnectorRuntimeError.malformedRequest
        }
        let expectedDirection: WalletConnectionDirection = request.connector == .walletConnect
            ? .locusVaultToDapp : .externalAccountToLocus
        guard request.direction == expectedDirection else {
            throw WalletConnectionProtocolError.directionMismatch
        }
        if request.connector == .walletConnect {
            guard let uri = request.pairingURI,
                  uri.utf8.count <= 2_048,
                  uri.hasPrefix("wc:"),
                  !request.offeredAccounts.isEmpty,
                  request.offeredAccounts.count <= 32,
                  request.offeredAccounts.allSatisfy({ account in
                      account.ownership == .locusVault
                          && Set(account.networkIDs).isSubset(of: request.requestedNetworkIDs)
                  }) else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
        } else if request.pairingURI != nil || !request.offeredAccounts.isEmpty {
            throw WalletConnectorRuntimeError.malformedRequest
        }
    }

    private func validate(
        _ session: WalletConnectorSession,
        for request: WalletConnectorPairingRequest
    ) throws {
        guard session.connectionID == request.requestID,
              session.expiresAt > Date(),
              session.expiresAt.timeIntervalSince(Date()) <= 30 * 24 * 60 * 60,
              !session.accounts.isEmpty,
              session.networkIDs.isSubset(of: request.requestedNetworkIDs),
              session.approvedMethods.isSubset(of: request.requestedMethods),
              session.accounts.allSatisfy({ account in
                  account.ownership == Self.ownership(for: request.connector)
                      && Set(account.networkIDs).isSubset(of: session.networkIDs)
              }) else {
            throw WalletConnectorRuntimeError.sessionMismatch
        }
    }

    private func apply(_ event: WalletConnectorEvent) {
        switch event {
        case .accountsChanged(let connectionID, let changed):
            guard let current = connections[connectionID],
                  changed.allSatisfy({
                      $0.ownership == current.accountOwnership
                          && Set($0.networkIDs).isSubset(of: current.networkIDs)
                  }) else {
                revoke(connectionID)
                return
            }
            let next = WalletConnectionRecord(
                id: current.id, direction: current.direction,
                connector: current.connector,
                accountOwnership: current.accountOwnership,
                peerName: current.peerName, peerURL: current.peerURL,
                peerID: current.peerID, networkIDs: current.networkIDs,
                approvedMethods: current.approvedMethods,
                accountIDs: Set(changed.map(\.id)), state: current.state,
                createdAt: current.createdAt, updatedAt: Date(),
                expiresAt: current.expiresAt, revokedAt: current.revokedAt
            )
            connections[connectionID] = next
            replaceAccounts(for: current, with: changed)
        case .networksChanged(let connectionID, let networkIDs):
            guard let current = connections[connectionID],
                  networkIDs.isSubset(of: current.networkIDs) else {
                revoke(connectionID)
                return
            }
            for id in current.accountIDs {
                guard let account = accounts[id],
                      Set(account.networkIDs).isSubset(of: networkIDs) else {
                    revoke(connectionID)
                    return
                }
            }
        case .disconnected(let connectionID):
            revoke(connectionID)
        case .expired(let connectionID):
            expire(connectionID)
        }
        statusChangeHandler?(currentStatus())
    }

    private func replaceAccounts(
        for connection: WalletConnectionRecord,
        with changed: [WalletAccount]
    ) {
        removeAccounts(for: connection)
        for account in changed { accounts[account.id] = account }
    }

    private func removeAccounts(for connection: WalletConnectionRecord) {
        for accountID in connection.accountIDs { accounts[accountID] = nil }
    }

    private func revoke(_ connectionID: String) {
        guard let current = connections[connectionID] else { return }
        connections[connectionID] = current.transitioning(to: .revoked) ?? current
        removeAccounts(for: current)
    }

    private func expire(_ connectionID: String) {
        guard let current = connections[connectionID] else { return }
        connections[connectionID] = current.transitioning(to: .expired) ?? current
        removeAccounts(for: current)
    }

    private func expireStaleConnections(now: Date = Date()) {
        for (id, connection) in connections where connection.expiresAt <= now {
            expire(id)
        }
    }

    private func currentStatus() -> WalletConnectionServiceStatus {
        WalletConnectionServiceStatus(
            connections: connections.values.sorted { $0.updatedAt > $1.updatedAt },
            accounts: accounts.values.sorted { $0.id < $1.id }
        )
    }

    private static func ownership(
        for connector: WalletConnectionConnector
    ) -> WalletAccountOwnership {
        switch connector {
        case .metamask:
            .external(connectorID: .metamask)
        case .phantom:
            .connectorManaged(connectorID: .phantom)
        case .slush:
            .external(connectorID: .slush)
        case .embeddedBrowser, .walletConnect:
            .locusVault
        }
    }

    private static func displayName(_ connector: WalletConnectionConnector) -> String {
        switch connector {
        case .metamask: "MetaMask"
        case .phantom: "Phantom-managed"
        case .slush: "Slush"
        case .embeddedBrowser: "Embedded browser"
        case .walletConnect: "WalletConnect"
        }
    }
}
