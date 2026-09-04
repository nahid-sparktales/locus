import Foundation

enum WalletRoutedRequestPayload: Codable, Equatable, Sendable {
    case listAccounts
    case switchNetwork
    case transaction(action: WalletSemanticAction, maximumFeeBaseUnits: String)
    case signIn(WalletStructuredAuthorizationRequest)

    private enum CodingKeys: String, CodingKey {
        case kind, action, maximumFeeBaseUnits, authorization
    }

    private enum Kind: String, Codable {
        case listAccounts = "list_accounts"
        case switchNetwork = "switch_network"
        case transaction
        case signIn = "sign_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .listAccounts:
            self = .listAccounts
        case .switchNetwork:
            self = .switchNetwork
        case .transaction:
            self = .transaction(
                action: try container.decode(WalletSemanticAction.self, forKey: .action),
                maximumFeeBaseUnits: try container.decode(
                    String.self, forKey: .maximumFeeBaseUnits
                )
            )
        case .signIn:
            self = .signIn(try container.decode(
                WalletStructuredAuthorizationRequest.self, forKey: .authorization
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listAccounts:
            try container.encode(Kind.listAccounts, forKey: .kind)
        case .switchNetwork:
            try container.encode(Kind.switchNetwork, forKey: .kind)
        case .transaction(let action, let maximumFeeBaseUnits):
            try container.encode(Kind.transaction, forKey: .kind)
            try container.encode(action, forKey: .action)
            try container.encode(maximumFeeBaseUnits, forKey: .maximumFeeBaseUnits)
        case .signIn(let authorization):
            try container.encode(Kind.signIn, forKey: .kind)
            try container.encode(authorization, forKey: .authorization)
        }
    }
}

struct WalletRoutedRequest: Codable, Equatable, Sendable {
    let binding: WalletConnectionRequestBinding
    let payload: WalletRoutedRequestPayload
}

enum WalletDappRequestRouterError: LocalizedError, Equatable {
    case duplicateRequest
    case methodPayloadMismatch
    case actionUnavailable
    case accountOwnershipMismatch
    case invalidOriginOrPeer
    case missingRequest
    case canceled(WalletConnectionCancellationReason)

    var errorDescription: String? {
        switch self {
        case .duplicateRequest: "The wallet request was already received."
        case .methodPayloadMismatch: "The wallet method does not match its semantic payload."
        case .actionUnavailable: "That wallet action is outside the reviewed connection surface."
        case .accountOwnershipMismatch: "The selected account cannot serve this connection direction."
        case .invalidOriginOrPeer: "The request is missing its exact origin or peer binding."
        case .missingRequest: "The wallet request is missing or was already completed."
        case .canceled(let reason): "The wallet request was canceled: \(reason.rawValue)."
        }
    }
}

/// The single semantic entry point for browser, WalletConnect, human, and
/// agent-initiated connector requests. It retains the original binding until
/// completion so callback replay and origin/account/network substitution fail.
@MainActor
final class WalletDappRequestRouter {
    private struct Pending {
        let request: WalletRoutedRequest
    }

    private var pending: [String: Pending] = [:]
    private var completedRequestIDs: Set<String> = []
    private var completedRequestOrder: [String] = []
    private var canceledRequestIDs: [String: WalletConnectionCancellationReason] = [:]
    private let maximumCompletedRequestIDs = 2_048

    var pendingCount: Int { pending.count }

    func begin(
        _ request: WalletRoutedRequest,
        connection: WalletConnectionRecord,
        account: WalletAccount,
        now: Date = Date()
    ) throws {
        guard pending[request.binding.requestID] == nil,
              !completedRequestIDs.contains(request.binding.requestID) else {
            throw WalletDappRequestRouterError.duplicateRequest
        }
        try WalletConnectionAuthority.validate(
            request.binding, against: connection, now: now
        )
        try validateEndpoint(request.binding)
        try validateOwnership(account, for: request.binding)
        try validatePayload(request.payload, for: request.binding)
        pending[request.binding.requestID] = Pending(request: request)
    }

    func complete(
        requestID: String,
        callbackBinding: WalletConnectionRequestBinding,
        now: Date = Date()
    ) throws -> WalletRoutedRequest {
        if let reason = canceledRequestIDs.removeValue(forKey: requestID) {
            throw WalletDappRequestRouterError.canceled(reason)
        }
        guard let stored = pending[requestID] else {
            throw WalletDappRequestRouterError.missingRequest
        }
        do {
            try WalletConnectionAuthority.validateCallback(
                expected: stored.request.binding,
                received: callbackBinding,
                now: now
            )
        } catch {
            // A mismatched or stale callback consumes the pending request. It
            // must never reopen the same request identifier for a later replay.
            pending.removeValue(forKey: requestID)
            rememberCompleted(requestID)
            throw error
        }
        pending.removeValue(forKey: requestID)
        rememberCompleted(requestID)
        return stored.request
    }

    func cancel(
        requestID: String,
        reason: WalletConnectionCancellationReason
    ) {
        guard pending.removeValue(forKey: requestID) != nil else { return }
        canceledRequestIDs[requestID] = reason
        rememberCompleted(requestID)
    }

    func cancel(
        connectionID: String? = nil,
        origin: String? = nil,
        reason: WalletConnectionCancellationReason
    ) {
        let matching = pending.filter { _, value in
            (connectionID == nil || value.request.binding.connectionID == connectionID)
                && (origin == nil || value.request.binding.origin == origin)
        }.map(\.key)
        for requestID in matching {
            guard pending.removeValue(forKey: requestID) != nil else { continue }
            canceledRequestIDs[requestID] = reason
            rememberCompleted(requestID)
        }
    }

    private func validateEndpoint(_ binding: WalletConnectionRequestBinding) throws {
        switch binding.connector {
        case .embeddedBrowser:
            guard Self.normalizedOrigin(binding.origin) != nil, binding.peerID == nil else {
                throw WalletDappRequestRouterError.invalidOriginOrPeer
            }
        case .walletConnect:
            guard binding.peerID?.isEmpty == false else {
                throw WalletDappRequestRouterError.invalidOriginOrPeer
            }
        case .metamask, .phantom, .slush:
            guard binding.origin == nil else {
                throw WalletDappRequestRouterError.invalidOriginOrPeer
            }
        }
    }

    private func validateOwnership(
        _ account: WalletAccount,
        for binding: WalletConnectionRequestBinding
    ) throws {
        guard account.id == binding.accountID,
              account.networkIDs.contains(binding.networkID) else {
            throw WalletDappRequestRouterError.accountOwnershipMismatch
        }
        switch binding.direction {
        case .locusVaultToDapp:
            guard account.ownership == .locusVault else {
                throw WalletDappRequestRouterError.accountOwnershipMismatch
            }
        case .externalAccountToLocus:
            guard let expectedOwnership = connectionOwnership(for: binding.connector),
                  binding.connector.externalConnectorID == account.ownership.connectorID,
                  account.ownership == expectedOwnership else {
                throw WalletDappRequestRouterError.accountOwnershipMismatch
            }
        }
    }

    private func connectionOwnership(
        for connector: WalletConnectionConnector
    ) -> WalletAccountOwnership? {
        switch connector {
        case .metamask:
            .external(connectorID: .metamask)
        case .phantom:
            .connectorManaged(connectorID: .phantom)
        case .slush:
            .external(connectorID: .slush)
        case .embeddedBrowser, .walletConnect:
            nil
        }
    }

    private func validatePayload(
        _ payload: WalletRoutedRequestPayload,
        for binding: WalletConnectionRequestBinding
    ) throws {
        switch (binding.method, payload) {
        case (.listAccounts, .listAccounts), (.switchNetwork, .switchNetwork):
            return
        case (.sendTransaction, .transaction(let action, let maximumFee)):
            guard Self.isCanonicalUnsignedInteger(maximumFee) else {
                throw WalletDappRequestRouterError.methodPayloadMismatch
            }
            switch action.type {
            case .nativeTransfer, .fungibleTokenTransfer, .nftTransfer, .exactInputSwap:
                return
            case .swapAllowanceSetup, .reviewedCall, .standardizedSignIn,
                 .reviewedTypedAuthorization, .contractCall:
                throw WalletDappRequestRouterError.actionUnavailable
            }
        case (.signInWithEthereum, .signIn(let authorization)):
            guard authorization.format == .siwe else {
                throw WalletDappRequestRouterError.methodPayloadMismatch
            }
        case (.signInWithSolana, .signIn(let authorization)):
            guard authorization.format == .siws else {
                throw WalletDappRequestRouterError.methodPayloadMismatch
            }
        default:
            throw WalletDappRequestRouterError.methodPayloadMismatch
        }
    }

    private func rememberCompleted(_ requestID: String) {
        guard completedRequestIDs.insert(requestID).inserted else { return }
        completedRequestOrder.append(requestID)
        while completedRequestOrder.count > maximumCompletedRequestIDs {
            let evicted = completedRequestOrder.removeFirst()
            completedRequestIDs.remove(evicted)
            canceledRequestIDs.removeValue(forKey: evicted)
        }
    }

    private static func normalizedOrigin(_ value: String?) -> String? {
        guard let value,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else { return nil }
        let isStandardPort = (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let port = components.port.map { isStandardPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func isCanonicalUnsignedInteger(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return value == "0" || value.first != "0"
    }
}
