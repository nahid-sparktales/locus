import Foundation

/// Private connector state returned by a driver after its SDK has completed
/// authentication. Tokens, relay topics, serialized transactions, and
/// signatures are deliberately not representable here.
struct WalletConnectorSession: Equatable, Sendable {
    let connectionID: String
    let peerName: String
    let peerURL: String?
    let peerID: String?
    let networkIDs: Set<String>
    let approvedMethods: Set<WalletConnectionMethod>
    let accounts: [WalletAccount]
    let expiresAt: Date
}

enum WalletConnectorEvent: Equatable, Sendable {
    case accountsChanged(connectionID: String, accounts: [WalletAccount])
    case networksChanged(connectionID: String, networkIDs: Set<String>)
    case disconnected(connectionID: String)
    case expired(connectionID: String)
}

@MainActor
protocol WalletConnectorDriver: AnyObject {
    var connector: WalletConnectionConnector { get }
    var isConfigured: Bool { get }
    var events: AsyncStream<WalletConnectorEvent> { get }
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)? { get set }

    func restore() async throws -> [WalletConnectorSession]
    func connect(
        _ request: WalletConnectorPairingRequest,
        approve: @escaping @MainActor (WalletConnectionProposalReview) async -> Bool
    ) async throws
        -> WalletConnectorSession
    func execute(_ request: WalletExternalExecutionRequest) async throws
        -> WalletExternalExecutionResult
    func cancel(requestID: String) async
    func disconnect(connectionID: String) async
    func suspend() async
}

enum WalletConnectorRuntimeError: LocalizedError, Equatable {
    case malformedRequest
    case unsupportedConnector
    case unconfigured(String)
    case tooManyConnections
    case duplicateRequest
    case sessionNotFound
    case sessionMismatch
    case sdkFailure(String)

    var errorDescription: String? {
        switch self {
        case .malformedRequest:
            "The wallet connection request is malformed."
        case .unsupportedConnector:
            "That wallet connector is not available in this build."
        case .unconfigured(let connector):
            "\(connector) requires release-scoped connector configuration."
        case .tooManyConnections:
            "Too many wallet connections are active."
        case .duplicateRequest:
            "That wallet connection request was already received."
        case .sessionNotFound:
            "That wallet connection is no longer active."
        case .sessionMismatch:
            "The wallet SDK returned state outside the approved connection."
        case .sdkFailure(let message):
            String(message.prefix(512))
        }
    }
}
