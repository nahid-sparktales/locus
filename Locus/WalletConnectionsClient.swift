import Foundation

@MainActor
protocol WalletConnectionsClient: AnyObject {
    var isAvailable: Bool { get }
    var invalidationHandler: (() -> Void)? { get set }
    var statusChangeHandler: (@MainActor (WalletConnectionServiceStatus) -> Void)? { get set }
    var proposalApprovalHandler: (@MainActor (WalletConnectionProposalReview) async -> Bool)? { get set }
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)? { get set }

    func status() async throws -> WalletConnectionServiceStatus
    func beginPairing(
        _ request: WalletConnectorPairingRequest
    ) async throws -> WalletConnectionServiceStatus
    func cancelPairing(requestID: String) async throws -> WalletConnectionServiceStatus
    func executeExternal(
        _ request: WalletExternalExecutionRequest
    ) async throws -> WalletExternalExecutionResult
    func disconnect(connectionID: String) async throws -> WalletConnectionServiceStatus
    func suspendAll() async throws
}

@MainActor
enum WalletConnectionsClientFactory {
    static func make() -> WalletConnectionsClient {
        #if LOCUS_WALLET
        DirectWalletConnectionsClient()
        #else
        UnavailableWalletConnectionsClient()
        #endif
    }
}

@MainActor
final class UnavailableWalletConnectionsClient: WalletConnectionsClient {
    let isAvailable = false
    var invalidationHandler: (() -> Void)?
    var statusChangeHandler: (@MainActor (WalletConnectionServiceStatus) -> Void)?
    var proposalApprovalHandler: (@MainActor (WalletConnectionProposalReview) async -> Bool)?
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)?

    func status() async throws -> WalletConnectionServiceStatus {
        throw WalletGateway.Error.connectionHelperUnavailable
    }

    func beginPairing(
        _ request: WalletConnectorPairingRequest
    ) async throws -> WalletConnectionServiceStatus {
        _ = request
        throw WalletGateway.Error.connectionHelperUnavailable
    }

    func cancelPairing(requestID: String) async throws -> WalletConnectionServiceStatus {
        _ = requestID
        throw WalletGateway.Error.connectionHelperUnavailable
    }

    func executeExternal(
        _ request: WalletExternalExecutionRequest
    ) async throws -> WalletExternalExecutionResult {
        _ = request
        throw WalletGateway.Error.connectionHelperUnavailable
    }

    func disconnect(connectionID: String) async throws -> WalletConnectionServiceStatus {
        _ = connectionID
        throw WalletGateway.Error.connectionHelperUnavailable
    }

    func suspendAll() async throws {
        throw WalletGateway.Error.connectionHelperUnavailable
    }
}
