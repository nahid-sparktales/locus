import Foundation

@MainActor
enum WalletConnectorDriverFactory {
    static func make(
        bundle: Bundle,
        environment: [String: String]
    ) -> [WalletConnectorDriver] {
        var drivers: [WalletConnectorDriver] = [
            WalletConnectDriver(bundle: bundle, environment: environment)
        ]
        if let runtime = try? WalletConnectorWebRuntime(
            bundle: bundle, environment: environment
        ) {
            drivers += [
                WalletConnectorWebDriver(connector: .metamask, runtime: runtime),
                WalletConnectorWebDriver(connector: .phantom, runtime: runtime),
                WalletConnectorWebDriver(connector: .slush, runtime: runtime),
            ]
        }
        return drivers
    }
}

private struct WalletWebSessionPayload: Codable {
    struct Account: Codable {
        let id: String
        let chain: WalletChain
        let address: String
        let publicKeyBase64: String?
        let label: String
        let networkIDs: [String]
    }

    let connectionID: String
    let peerName: String
    let peerURL: String?
    let peerID: String?
    let networkIDs: [String]
    let approvedMethods: [WalletConnectionMethod]
    let accounts: [Account]
    let expiresAt: Date
}

@MainActor
private final class WalletConnectorWebDriver: WalletConnectorDriver {
    let connector: WalletConnectionConnector
    let events: AsyncStream<WalletConnectorEvent>

    private let runtime: WalletConnectorWebRuntime
    private let eventContinuation: AsyncStream<WalletConnectorEvent>.Continuation
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)?

    init(connector: WalletConnectionConnector, runtime: WalletConnectorWebRuntime) {
        self.connector = connector
        self.runtime = runtime
        var continuation: AsyncStream<WalletConnectorEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
        runtime.addEventHandler(connector: connector) { [weak self] event in
            self?.eventContinuation.yield(event)
        }
    }

    deinit { eventContinuation.finish() }

    var isConfigured: Bool {
        runtime.isConfigured(connector)
    }

    func restore() async throws -> [WalletConnectorSession] {
        let payloads: [WalletWebSessionPayload] = try await runtime.request(
            operation: "restore", connector: connector, payload: [:]
        )
        return try payloads.map(session)
    }

    func connect(
        _ request: WalletConnectorPairingRequest,
        approve: @escaping @MainActor (WalletConnectionProposalReview) async -> Bool
    ) async throws
        -> WalletConnectorSession {
        _ = approve
        runtime.present(title: "Connect \(Self.displayName(connector))")
        let payload: WalletWebSessionPayload = try await runtime.request(
            operation: "connect", connector: connector,
            payload: ["request": try runtime.jsonObject(request)]
        )
        let connected = try session(payload)
        let namespaces = Dictionary(grouping: connected.networkIDs) { networkID in
            WalletConnectionNamespace.forNetworkID(networkID)
        }.compactMap { namespace, networkIDs -> WalletConnectionNamespaceProposal? in
            guard let namespace else { return nil }
            return WalletConnectionNamespaceProposal(
                namespace: namespace,
                networkIDs: Set(networkIDs),
                methods: connected.approvedMethods,
                events: [.accountsChanged, .networkChanged, .disconnected]
            )
        }
        let review = WalletConnectionProposalReview(
            requestID: connected.connectionID,
            peerName: connected.peerName,
            peerURL: connected.peerURL,
            namespaces: namespaces,
            accounts: connected.accounts,
            expiresAt: min(connected.expiresAt, request.expiresAt)
        )
        guard await approve(review) else {
            await disconnect(connectionID: connected.connectionID)
            throw WalletConnectorRuntimeError.sdkFailure("The connection was rejected in Locus.")
        }
        return connected
    }

    func execute(_ request: WalletExternalExecutionRequest) async throws
        -> WalletExternalExecutionResult {
        runtime.present(title: "Review in \(Self.displayName(connector))")
        return try await runtime.request(
            operation: "execute", connector: connector,
            payload: ["request": try runtime.jsonObject(request)]
        )
    }

    func cancel(requestID: String) async {
        let _: WalletWebEmpty? = try? await runtime.request(
            operation: "cancel", connector: connector,
            payload: ["requestID": requestID]
        )
    }

    func disconnect(connectionID: String) async {
        let _: WalletWebEmpty? = try? await runtime.request(
            operation: "disconnect", connector: connector,
            payload: ["connectionID": connectionID]
        )
    }

    func suspend() async {
        let _: WalletWebEmpty? = try? await runtime.request(
            operation: "suspend", connector: connector, payload: [:]
        )
    }

    private func session(_ payload: WalletWebSessionPayload) throws
        -> WalletConnectorSession {
        let ownership: WalletAccountOwnership = switch connector {
        case .metamask:
            .external(connectorID: .metamask)
        case .phantom:
            .connectorManaged(connectorID: .phantom)
        case .slush:
            .external(connectorID: .slush)
        case .embeddedBrowser, .walletConnect:
            throw WalletConnectorRuntimeError.unsupportedConnector
        }
        let accounts = payload.accounts.map {
            WalletAccount(
                id: $0.id, chain: $0.chain, address: $0.address,
                publicKeyBase64: $0.publicKeyBase64,
                label: $0.label, networkIDs: $0.networkIDs,
                ownership: ownership
            )
        }
        return WalletConnectorSession(
            connectionID: payload.connectionID,
            peerName: payload.peerName, peerURL: payload.peerURL,
            peerID: payload.peerID, networkIDs: Set(payload.networkIDs),
            approvedMethods: Set(payload.approvedMethods), accounts: accounts,
            expiresAt: payload.expiresAt
        )
    }

    private static func displayName(_ connector: WalletConnectionConnector) -> String {
        switch connector {
        case .metamask: "MetaMask"
        case .phantom: "Phantom"
        case .slush: "Slush"
        case .embeddedBrowser: "Embedded browser"
        case .walletConnect: "WalletConnect"
        }
    }
}

private struct WalletWebEmpty: Codable {}
