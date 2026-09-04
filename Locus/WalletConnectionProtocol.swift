import Foundation

enum WalletConnectionDirection: String, Codable, CaseIterable, Hashable, Sendable {
    /// A MetaMask, Phantom, or Slush account is exposed inside Wallet Hub.
    case externalAccountToLocus = "external_account_to_locus"
    /// Locus Vault serves a dapp through the browser or WalletConnect.
    case locusVaultToDapp = "locus_vault_to_dapp"
}

enum WalletConnectionConnector: String, Codable, CaseIterable, Hashable, Sendable {
    case metamask
    case phantom
    case slush
    case embeddedBrowser = "embedded_browser"
    case walletConnect = "wallet_connect"

    var externalConnectorID: WalletExternalConnectorID? {
        WalletExternalConnectorID(rawValue: rawValue)
    }
}

struct WalletConnectorBuildIdentity: Equatable, Sendable {
    let version: String
    let artifactSHA256: String

    static func reviewed(_ connector: WalletConnectionConnector) -> Self? {
        switch connector {
        case .metamask:
            Self(
                version: "2.1.1",
                artifactSHA256: "5613e7ff576f226f026786cf43f0e213c7e5cf14ae7768887a165fa46d26ec99"
            )
        case .phantom:
            Self(
                version: "2.0.2",
                artifactSHA256: "5613e7ff576f226f026786cf43f0e213c7e5cf14ae7768887a165fa46d26ec99"
            )
        case .slush:
            Self(
                version: "1.1.23",
                artifactSHA256: "5613e7ff576f226f026786cf43f0e213c7e5cf14ae7768887a165fa46d26ec99"
            )
        case .walletConnect:
            Self(
                version: "2.3.2+locus.1",
                artifactSHA256: "2eac4caec48ca638bab63d61cadc22c8b8cb86df454040560cf28e1d7cbfb838"
            )
        case .embeddedBrowser:
            nil
        }
    }
}

enum WalletConnectionMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case listAccounts = "list_accounts"
    case switchNetwork = "switch_network"
    case sendTransaction = "send_transaction"
    case signInWithEthereum = "sign_in_with_ethereum"
    case signInWithSolana = "sign_in_with_solana"
}

enum WalletConnectionLifecycleState: String, Codable, CaseIterable, Sendable {
    case pairing
    case proposalPending = "proposal_pending"
    case approvalPending = "approval_pending"
    case connected
    case reconnecting
    case expired
    case revoked
    case failed

    var isTerminal: Bool {
        self == .expired || self == .revoked || self == .failed
    }

    func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.pairing, .proposalPending),
             (.pairing, .failed),
             (.pairing, .revoked),
             (.proposalPending, .approvalPending),
             (.proposalPending, .failed),
             (.proposalPending, .expired),
             (.proposalPending, .revoked),
             (.approvalPending, .connected),
             (.approvalPending, .failed),
             (.approvalPending, .expired),
             (.approvalPending, .revoked),
             (.connected, .reconnecting),
             (.connected, .expired),
             (.connected, .revoked),
             (.connected, .failed),
             (.reconnecting, .connected),
             (.reconnecting, .expired),
             (.reconnecting, .revoked),
             (.reconnecting, .failed):
            true
        default:
            self == next
        }
    }
}

/// Schema-v2 public connection metadata. Relay keys, vendor tokens, signed
/// payloads, transaction bytes, and policy authority are intentionally absent.
struct WalletConnectionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let direction: WalletConnectionDirection
    let connector: WalletConnectionConnector
    /// The signing authority exposed by this connection. All accounts in one
    /// connector session must share this exact ownership model.
    let accountOwnership: WalletAccountOwnership
    let peerName: String
    let peerURL: String?
    /// Stable relay/session peer identifier for WalletConnect. This is public
    /// routing metadata, not a relay key or pairing secret.
    let peerID: String?
    let networkIDs: Set<String>
    let approvedMethods: Set<WalletConnectionMethod>
    let accountIDs: Set<String>
    let state: WalletConnectionLifecycleState
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date
    let revokedAt: Date?

    init(
        id: String,
        direction: WalletConnectionDirection,
        connector: WalletConnectionConnector,
        accountOwnership: WalletAccountOwnership? = nil,
        peerName: String,
        peerURL: String?,
        peerID: String? = nil,
        networkIDs: Set<String>,
        approvedMethods: Set<WalletConnectionMethod>,
        accountIDs: Set<String>,
        state: WalletConnectionLifecycleState,
        createdAt: Date,
        updatedAt: Date,
        expiresAt: Date,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.direction = direction
        self.connector = connector
        self.accountOwnership = accountOwnership
            ?? Self.defaultOwnership(direction: direction, connector: connector)
        self.peerName = peerName
        self.peerURL = peerURL
        self.peerID = peerID
        self.networkIDs = networkIDs
        self.approvedMethods = approvedMethods
        self.accountIDs = accountIDs
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    var isUsable: Bool {
        state == .connected && revokedAt == nil && expiresAt > Date()
    }

    func transitioning(
        to next: WalletConnectionLifecycleState,
        at date: Date = Date()
    ) -> Self? {
        guard state.canTransition(to: next), date >= updatedAt else { return nil }
        return Self(
            id: id, direction: direction, connector: connector,
            accountOwnership: accountOwnership,
            peerName: peerName, peerURL: peerURL, peerID: peerID,
            networkIDs: networkIDs,
            approvedMethods: approvedMethods, accountIDs: accountIDs,
            state: next, createdAt: createdAt, updatedAt: date,
            expiresAt: expiresAt, revokedAt: next == .revoked ? date : revokedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, direction, connector, accountOwnership, peerName, peerURL, peerID, networkIDs
        case approvedMethods, accountIDs, state, createdAt, updatedAt
        case expiresAt, revokedAt
        // Schema-v1 compatibility keys.
        case kind, methods, disconnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        peerName = try container.decode(String.self, forKey: .peerName)
        peerURL = try container.decodeIfPresent(String.self, forKey: .peerURL)
        peerID = try container.decodeIfPresent(String.self, forKey: .peerID)
        networkIDs = try container.decodeIfPresent(Set<String>.self, forKey: .networkIDs) ?? []
        accountIDs = try container.decodeIfPresent(Set<String>.self, forKey: .accountIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)

        if let direction = try container.decodeIfPresent(
            WalletConnectionDirection.self, forKey: .direction
        ), let connector = try container.decodeIfPresent(
            WalletConnectionConnector.self, forKey: .connector
        ) {
            self.direction = direction
            self.connector = connector
            accountOwnership = try container.decodeIfPresent(
                WalletAccountOwnership.self, forKey: .accountOwnership
            ) ?? Self.defaultOwnership(direction: direction, connector: connector)
            approvedMethods = try container.decodeIfPresent(
                Set<WalletConnectionMethod>.self, forKey: .approvedMethods
            ) ?? []
            state = try container.decodeIfPresent(
                WalletConnectionLifecycleState.self, forKey: .state
            ) ?? .connected
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
            revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
            return
        }

        let legacyKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "browser"
        direction = legacyKind.contains("external")
            ? .externalAccountToLocus : .locusVaultToDapp
        connector = WalletConnectionConnector(rawValue: legacyKind) ?? .embeddedBrowser
        accountOwnership = Self.defaultOwnership(
            direction: direction, connector: connector
        )
        let legacyMethods = try container.decodeIfPresent(Set<String>.self, forKey: .methods) ?? []
        approvedMethods = Set(legacyMethods.compactMap(WalletConnectionMethod.init(rawValue:)))
        let disconnectedAt = try container.decodeIfPresent(Date.self, forKey: .disconnectedAt)
        revokedAt = disconnectedAt
        updatedAt = disconnectedAt ?? createdAt
        state = disconnectedAt == nil ? .connected : .revoked
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(direction, forKey: .direction)
        try container.encode(connector, forKey: .connector)
        try container.encode(accountOwnership, forKey: .accountOwnership)
        try container.encode(peerName, forKey: .peerName)
        try container.encodeIfPresent(peerURL, forKey: .peerURL)
        try container.encodeIfPresent(peerID, forKey: .peerID)
        try container.encode(networkIDs, forKey: .networkIDs)
        try container.encode(approvedMethods, forKey: .approvedMethods)
        try container.encode(accountIDs, forKey: .accountIDs)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(revokedAt, forKey: .revokedAt)
    }

    private static func defaultOwnership(
        direction: WalletConnectionDirection,
        connector: WalletConnectionConnector
    ) -> WalletAccountOwnership {
        guard direction == .externalAccountToLocus,
              let connectorID = connector.externalConnectorID else {
            return .locusVault
        }
        return .external(connectorID: connectorID)
    }
}

enum WalletConnectionCancellationReason: String, Codable, Sendable {
    case walletLocked = "wallet_locked"
    case signerLost = "signer_lost"
    case walletDisabled = "wallet_disabled"
    case navigation
    case disconnected
    case expired
    case accountChanged = "account_changed"
    case networkChanged = "network_changed"
    case walletRejected = "wallet_rejected"
    case timedOut = "timed_out"
}

/// Immutable authority binding attached before any dapp or connector request
/// enters simulation or review. Each later callback must match it exactly.
struct WalletConnectionRequestBinding: Codable, Equatable, Sendable {
    let requestID: String
    let connectionID: String
    let direction: WalletConnectionDirection
    let connector: WalletConnectionConnector
    let origin: String?
    let peerID: String?
    let accountID: String
    let networkID: String
    let method: WalletConnectionMethod
    let issuedAt: Date
    let expiresAt: Date
}

enum WalletConnectionProtocolError: LocalizedError, Equatable {
    case malformed
    case stale
    case disconnected
    case bindingMismatch
    case methodNotApproved
    case accountNotApproved
    case networkNotApproved
    case directionMismatch

    var errorDescription: String? {
        switch self {
        case .malformed: "The wallet connection request is malformed."
        case .stale: "The wallet connection request has expired."
        case .disconnected: "The wallet connection is no longer active."
        case .bindingMismatch: "The wallet response does not match the original request."
        case .methodNotApproved: "That wallet method was not approved for this connection."
        case .accountNotApproved: "That account was not approved for this connection."
        case .networkNotApproved: "That network was not approved for this connection."
        case .directionMismatch: "That connector cannot be used in this direction."
        }
    }
}

enum WalletConnectionAuthority {
    static let maximumRequestLifetime: TimeInterval = 2 * 60

    static func validate(
        _ binding: WalletConnectionRequestBinding,
        against connection: WalletConnectionRecord,
        now: Date = Date()
    ) throws {
        guard UUID(uuidString: binding.requestID) != nil,
              binding.issuedAt <= now,
              binding.expiresAt > binding.issuedAt,
              binding.expiresAt.timeIntervalSince(binding.issuedAt) <= maximumRequestLifetime else {
            throw WalletConnectionProtocolError.malformed
        }
        guard binding.expiresAt > now, connection.expiresAt > now,
              binding.expiresAt <= connection.expiresAt else {
            throw WalletConnectionProtocolError.stale
        }
        guard connection.state == .connected, connection.revokedAt == nil else {
            throw WalletConnectionProtocolError.disconnected
        }
        guard binding.connectionID == connection.id,
              binding.direction == connection.direction,
              binding.connector == connection.connector else {
            throw WalletConnectionProtocolError.bindingMismatch
        }
        guard connection.approvedMethods.contains(binding.method) else {
            throw WalletConnectionProtocolError.methodNotApproved
        }
        guard connection.accountIDs.contains(binding.accountID) else {
            throw WalletConnectionProtocolError.accountNotApproved
        }
        guard connection.networkIDs.contains(binding.networkID) else {
            throw WalletConnectionProtocolError.networkNotApproved
        }
        switch connection.connector {
        case .metamask:
            guard connection.direction == .externalAccountToLocus,
                  connection.accountOwnership == .external(connectorID: .metamask),
                  binding.origin == nil, binding.peerID == nil else {
                throw WalletConnectionProtocolError.directionMismatch
            }
        case .slush:
            guard connection.direction == .externalAccountToLocus,
                  connection.accountOwnership == .external(connectorID: .slush),
                  binding.origin == nil, binding.peerID == nil else {
                throw WalletConnectionProtocolError.directionMismatch
            }
        case .phantom:
            guard connection.direction == .externalAccountToLocus,
                  connection.accountOwnership == .connectorManaged(connectorID: .phantom),
                  binding.origin == nil, binding.peerID == nil else {
                throw WalletConnectionProtocolError.directionMismatch
            }
        case .embeddedBrowser:
            guard connection.direction == .locusVaultToDapp,
                  connection.accountOwnership == .locusVault,
                  binding.peerID == nil,
                  let origin = normalizedOrigin(binding.origin),
                  let connectionOrigin = normalizedOrigin(connection.peerURL),
                  origin == connectionOrigin
            else {
                throw WalletConnectionProtocolError.bindingMismatch
            }
        case .walletConnect:
            guard connection.direction == .locusVaultToDapp,
                  connection.accountOwnership == .locusVault,
                  binding.peerID?.isEmpty == false,
                  connection.peerID == binding.peerID,
                  originsMatch(binding.origin, connection.peerURL) else {
                throw WalletConnectionProtocolError.bindingMismatch
            }
        }
    }

    static func validateCallback(
        expected: WalletConnectionRequestBinding,
        received: WalletConnectionRequestBinding,
        now: Date = Date()
    ) throws {
        guard expected == received else { throw WalletConnectionProtocolError.bindingMismatch }
        guard received.expiresAt > now else { throw WalletConnectionProtocolError.stale }
    }

    private static func normalizedOrigin(_ value: String?) -> String? {
        guard let value,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil,
              components.fragment == nil else { return nil }
        let standardPort = (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let port = components.port.map { standardPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func originsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        if lhs == nil, rhs == nil { return true }
        guard let left = normalizedOrigin(lhs), let right = normalizedOrigin(rhs) else {
            return false
        }
        return left == right
    }
}

enum WalletConnectionNamespace: String, Codable, CaseIterable, Hashable, Sendable {
    case eip155
    case solana
    case sui
}

enum WalletConnectionEvent: String, Codable, CaseIterable, Hashable, Sendable {
    case accountsChanged = "accounts_changed"
    case networkChanged = "network_changed"
    case disconnected
}

/// A normalized, bounded view of a WalletConnect or Wallet Standard proposal.
/// Vendor-specific payloads are reduced to this type inside the networked
/// helper before the host can review them.
struct WalletConnectionNamespaceProposal: Codable, Equatable, Sendable {
    let namespace: WalletConnectionNamespace
    let networkIDs: Set<String>
    let methods: Set<WalletConnectionMethod>
    let events: Set<WalletConnectionEvent>
}

/// User-reviewable projection of a WalletConnect proposal. Relay topics,
/// verification payloads, icons, and pairing secrets are intentionally absent.
struct WalletConnectionProposalReview: Equatable, Identifiable, Sendable {
    let requestID: String
    let peerName: String
    let peerURL: String?
    let namespaces: [WalletConnectionNamespaceProposal]
    let expiresAt: Date

    var id: String { requestID }
}

enum WalletConnectionNamespaceValidator {
    static func validate(
        _ proposals: [WalletConnectionNamespaceProposal],
        connector: WalletConnectionConnector,
        direction: WalletConnectionDirection
    ) throws {
        guard [.embeddedBrowser, .walletConnect].contains(connector),
              direction == .locusVaultToDapp,
              !proposals.isEmpty,
              proposals.count <= WalletConnectionNamespace.allCases.count,
              Set(proposals.map(\.namespace)).count == proposals.count else {
            throw WalletConnectionProtocolError.malformed
        }
        for proposal in proposals {
            guard !proposal.networkIDs.isEmpty, proposal.networkIDs.count <= 8,
                  !proposal.methods.isEmpty,
                  proposal.events.isSubset(of: Set(WalletConnectionEvent.allCases)),
                  proposal.networkIDs.allSatisfy({ networkID in
                      networkID.hasPrefix("\(proposal.namespace.rawValue):")
                          && networkID.utf8.count <= 128
                  }) else {
                throw WalletConnectionProtocolError.malformed
            }
            let allowedMethods: Set<WalletConnectionMethod> = switch proposal.namespace {
            case .eip155:
                [.listAccounts, .switchNetwork, .sendTransaction, .signInWithEthereum]
            case .solana:
                [.listAccounts, .switchNetwork, .sendTransaction, .signInWithSolana]
            case .sui:
                [.listAccounts, .switchNetwork, .sendTransaction]
            }
            guard proposal.methods.isSubset(of: allowedMethods) else {
                throw WalletConnectionProtocolError.methodNotApproved
            }
        }
    }
}

struct WalletConnectorPairingRequest: Codable, Equatable, Sendable {
    let requestID: String
    let connector: WalletConnectionConnector
    let direction: WalletConnectionDirection
    let requestedNetworkIDs: Set<String>
    let requestedMethods: Set<WalletConnectionMethod>
    let expiresAt: Date
    /// Transient WalletConnect URI. It is passed directly to the Reown driver
    /// and is never copied into WalletConnectionRecord or WalletPublicStore.
    let pairingURI: String?
    /// Locus-owned accounts the user is willing to expose to the dapp. This is
    /// ignored by account-import connectors.
    let offeredAccounts: [WalletAccount]

    init(
        requestID: String,
        connector: WalletConnectionConnector,
        direction: WalletConnectionDirection,
        requestedNetworkIDs: Set<String>,
        requestedMethods: Set<WalletConnectionMethod>,
        expiresAt: Date,
        pairingURI: String? = nil,
        offeredAccounts: [WalletAccount] = []
    ) {
        self.requestID = requestID
        self.connector = connector
        self.direction = direction
        self.requestedNetworkIDs = requestedNetworkIDs
        self.requestedMethods = requestedMethods
        self.expiresAt = expiresAt
        self.pairingURI = pairingURI
        self.offeredAccounts = offeredAccounts
    }
}

enum WalletExternalTransactionFormat: String, Codable, Sendable {
    case evmEIP1193 = "evm_eip1193"
    case solanaBase64 = "solana_base64"
    case suiBCSBase64 = "sui_bcs_base64"
}

struct WalletExternalEVMTransaction: Codable, Equatable, Sendable {
    let from: String
    let to: String
    let valueHex: String
    let dataHex: String
    let gasHex: String
    let maxFeePerGasHex: String
    let maxPriorityFeePerGasHex: String
    let nonceHex: String
    let chainIDHex: String
}

/// Transient, already-simulated transaction material supplied to a connector.
/// It is never written to WalletPublicStore or diagnostics.
struct WalletExternalPreparedPayload: Codable, Equatable, Sendable {
    let format: WalletExternalTransactionFormat
    let evm: WalletExternalEVMTransaction?
    let transactionBase64: String?
    let minimumContextSlot: UInt64?
}

struct WalletExternalPreparedTransaction: Codable, Equatable, Sendable {
    let binding: WalletConnectionRequestBinding
    let action: WalletSemanticAction
    let accountAddress: String
    let semanticDigest: String
    let simulationDigest: String
    let payload: WalletExternalPreparedPayload
    let expiresAt: Date
}

struct WalletExternalExecutionRequest: Codable, Equatable, Sendable {
    let request: WalletRoutedRequest
    let prepared: WalletExternalPreparedTransaction
}

struct WalletExternalExecutionResult: Codable, Equatable, Sendable {
    let binding: WalletConnectionRequestBinding
    let transactionID: String
    let submittedAt: Date
}

/// A bounded, decoded request emitted by the Direct-only connector runtime.
/// Relay topics and the original JSON-RPC payload deliberately have no field
/// here and therefore cannot cross into public storage or signer APIs.
struct WalletConnectorDappRequest: Equatable, Sendable {
    struct EVMTransaction: Equatable, Sendable {
        let from: String
        let to: String
        let valueHex: String
        let dataHex: String
    }

    struct SolanaTransaction: Equatable, Sendable {
        let transactionBase64: String
        let accountAddress: String
        let minimumContextSlot: UInt64?
    }

    struct SuiTransaction: Equatable, Sendable {
        let transactionBase64: String
        let accountAddress: String
    }

    enum Payload: Equatable, Sendable {
        case listAccounts
        case evmTransaction(EVMTransaction)
        case solanaTransaction(SolanaTransaction)
        case suiTransaction(SuiTransaction)
        case canonicalMessage(
            format: WalletStructuredAuthorizationFormat,
            message: String,
            accountAddress: String
        )
    }

    let requestID: String
    let connectionID: String
    let peerID: String
    let peerOrigin: String?
    let peerName: String
    let networkID: String
    let accountID: String?
    let method: WalletConnectionMethod
    let expiresAt: Date
    let payload: Payload
}

struct WalletConnectorDappAccount: Codable, Equatable, Sendable {
    let address: String
    let publicKey: String?
}

enum WalletConnectorDappResponse: Equatable, Sendable {
    case accounts([WalletConnectorDappAccount])
    case transactionIdentifier(String)
    case signature(String)
}

struct WalletConnectionServiceStatus: Codable, Equatable, Sendable {
    static let protocolVersion = 1

    let protocolVersion: Int
    let connections: [WalletConnectionRecord]
    let accounts: [WalletAccount]

    init(
        connections: [WalletConnectionRecord],
        accounts: [WalletAccount]
    ) {
        protocolVersion = Self.protocolVersion
        self.connections = connections
        self.accounts = accounts
    }
}

struct WalletConnectionServiceError: Codable, Equatable, Sendable {
    let code: String
    let message: String
}
