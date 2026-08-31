import CryptoKit
import Foundation

enum WalletNetworkEnvironment: String, Codable, CaseIterable, Sendable {
    case mainnet
    case testnet
    case local
}

enum WalletChainIdentityKind: String, Codable, Sendable {
    case eip155ChainID = "eip155_chain_id"
    case solanaGenesisHash = "solana_genesis_hash"
    case suiChainIdentifier = "sui_chain_identifier"
}

struct WalletChainIdentity: Codable, Equatable, Sendable {
    let kind: WalletChainIdentityKind
    let value: String
}

enum WalletNetworkCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case nativeTransfer = "native_transfer"
    case fungibleTokenTransfer = "fungible_token_transfer"
    case nftTransfer = "nft_transfer"
    case exactInputSwap = "exact_input_swap"
    case reviewedCall = "reviewed_call"
    case embeddedBrowser = "embedded_browser"
    case externalWallet = "external_wallet"
    case walletConnect = "wallet_connect"
    case autonomousPolicy = "autonomous_policy"
}

struct WalletNetworkDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String { canonicalID }

    let canonicalID: String
    let chain: WalletChain
    let environment: WalletNetworkEnvironment
    let displayName: String
    let identity: WalletChainIdentity
    let nativeAssetID: String
    let nativeSymbol: String
    let nativeDecimals: Int
    let explorerTransactionURLTemplate: String
    let staticallyReviewedCapabilities: Set<WalletNetworkCapability>

    func explorerURL(transactionID: String) -> URL? {
        guard !transactionID.isEmpty else { return nil }
        return URL(string: explorerTransactionURLTemplate.replacingOccurrences(
            of: "{transaction}", with: transactionID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? transactionID
        ))
    }
}

enum WalletAssetKind: String, Codable, CaseIterable, Sendable {
    case native
    case fungibleToken = "fungible_token"
    case nft
    case collectible
}

enum WalletAssetTrust: String, Codable, CaseIterable, Sendable {
    case curated
    case userTrusted = "user_trusted"
    case quarantined
    case disabled
}

/// Public, canonical asset metadata. Contract, mint, coin-type, collection,
/// and object identities live in `reference`; private keys and transaction
/// bytes are intentionally not representable here.
struct WalletAsset: Codable, Equatable, Identifiable, Sendable {
    var id: String { canonicalID }

    let canonicalID: String
    let networkID: String
    let chain: WalletChain
    let kind: WalletAssetKind
    let reference: String?
    let name: String
    let symbol: String
    let decimals: Int?
    let trust: WalletAssetTrust
    let manifestRevision: Int

    var isVisibleByDefault: Bool { trust == .curated || trust == .userTrusted }
}

enum WalletProviderKind: String, Codable, CaseIterable, Sendable {
    case alchemy
    case quickNode = "quicknode"
    case userDefined = "user_defined"
    case local
}

struct WalletProviderEndpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let provider: WalletProviderKind
    let networkID: String
    let url: URL
    let priority: Int
    let expectedIdentity: WalletChainIdentity

    var isProductionSafe: Bool { url.scheme?.lowercased() == "https" }
}

enum WalletLaunchApproval: String, Codable, CaseIterable, Hashable, Sendable {
    case signerAudit = "signer_audit"
    case applicationPenetrationTest = "application_penetration_test"
    case legalRegionalMatrix = "legal_regional_matrix"
    case providerFailoverLoadTest = "provider_failover_load_test"
    case releaseCandidateSoak = "release_candidate_soak"
    case incidentDrill = "incident_drill"
    case notarizedArtifact = "notarized_artifact"
    case signedUpdateFeed = "signed_update_feed"
}

enum WalletReleaseStage: String, Codable, CaseIterable, Sendable {
    case invitedCanary = "invited_canary"
    case generalAvailability = "general_availability"

    fileprivate var authorityRank: Int {
        switch self {
        case .invitedCanary: 0
        case .generalAvailability: 1
        }
    }
}

struct WalletCapabilityManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int
    let releaseStage: WalletReleaseStage
    let evidenceIndexSHA256: String
    let issuedAt: Date
    let expiresAt: Date
    let enabledNetworkIDs: Set<String>
    let enabledCapabilities: Set<WalletNetworkCapability>
    let approvedRegions: Set<String>
    let completedApprovals: Set<WalletLaunchApproval>
}

struct WalletSignedCapabilityManifest: Codable, Equatable, Sendable {
    let manifest: WalletCapabilityManifest
    let signatureBase64: String
}

enum WalletLaunchGateError: LocalizedError, Equatable {
    case invalidManifest
    case invalidSignature
    case expiredManifest
    case networkNotReviewed
    case capabilityNotReviewed
    case regionNotApproved
    case approvalsIncomplete(Set<WalletLaunchApproval>)
    case generalAvailabilityNotApproved

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The wallet capability manifest is malformed."
        case .invalidSignature: "The wallet capability manifest signature is invalid."
        case .expiredManifest: "The wallet capability manifest has expired."
        case .networkNotReviewed: "This network is not enabled by the reviewed wallet manifest."
        case .capabilityNotReviewed: "This wallet capability has not passed its review gate."
        case .regionNotApproved: "This capability is unavailable in the current region."
        case .approvalsIncomplete(let missing):
            "Wallet launch approvals are incomplete: \(missing.map(\.rawValue).sorted().joined(separator: ", "))."
        case .generalAvailabilityNotApproved:
            "This build is approved only for the invited mainnet canary, not public GA."
        }
    }
}

/// The bundled review set is the upper authority bound. A signed remote
/// manifest can narrow or disable it, but intersection semantics prevent a
/// remote response from enabling code that was not shipped as reviewed.
struct WalletLaunchGate: Sendable {
    static let requiredGAApprovals = Set(WalletLaunchApproval.allCases)
    static let requiredCanaryApprovals: Set<WalletLaunchApproval> = [
        .signerAudit, .applicationPenetrationTest, .legalRegionalMatrix,
        .providerFailoverLoadTest, .incidentDrill, .notarizedArtifact, .signedUpdateFeed,
    ]

    let bundledNetworks: [String: WalletNetworkDescriptor]
    let effectiveManifest: WalletCapabilityManifest?

    init(
        bundledNetworks: [WalletNetworkDescriptor] = WalletNetworkCatalog.all,
        signedManifest: WalletSignedCapabilityManifest? = nil,
        publicKey: Curve25519.Signing.PublicKey? = nil,
        now: Date = Date()
    ) throws {
        self.bundledNetworks = Dictionary(uniqueKeysWithValues: bundledNetworks.map { ($0.id, $0) })
        guard let signedManifest else {
            effectiveManifest = nil
            return
        }
        guard let publicKey,
              signedManifest.manifest.schemaVersion == 2,
              signedManifest.manifest.revision > 0,
              signedManifest.manifest.issuedAt <= now,
              signedManifest.manifest.expiresAt
                > signedManifest.manifest.issuedAt,
              signedManifest.manifest.evidenceIndexSHA256.count == 64,
              signedManifest.manifest.evidenceIndexSHA256.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw WalletLaunchGateError.invalidManifest
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(signedManifest.manifest)
        guard let signature = Data(base64Encoded: signedManifest.signatureBase64),
              publicKey.isValidSignature(signature, for: payload) else {
            throw WalletLaunchGateError.invalidSignature
        }
        guard signedManifest.manifest.expiresAt > now else {
            throw WalletLaunchGateError.expiredManifest
        }
        effectiveManifest = signedManifest.manifest
    }

    private init(
        bundledNetworks: [String: WalletNetworkDescriptor],
        effectiveManifest: WalletCapabilityManifest?
    ) {
        self.bundledNetworks = bundledNetworks
        self.effectiveManifest = effectiveManifest
    }

    /// Applies a separately signed emergency manifest with intersection-only
    /// semantics. Even a valid newer remote document cannot add a network,
    /// capability, region, or approval absent from the bundled release gate.
    func restricted(
        by remote: WalletSignedCapabilityManifest,
        publicKey: Curve25519.Signing.PublicKey,
        now: Date = Date()
    ) throws -> WalletLaunchGate {
        guard let bundled = effectiveManifest else {
            return self
        }
        let remoteGate = try WalletLaunchGate(
            bundledNetworks: Array(bundledNetworks.values),
            signedManifest: remote, publicKey: publicKey, now: now
        )
        guard let restriction = remoteGate.effectiveManifest,
              restriction.revision >= bundled.revision else {
            throw WalletLaunchGateError.invalidManifest
        }
        let combined = WalletCapabilityManifest(
            schemaVersion: bundled.schemaVersion,
            revision: restriction.revision,
            releaseStage: restriction.releaseStage.authorityRank
                < bundled.releaseStage.authorityRank
                ? restriction.releaseStage : bundled.releaseStage,
            evidenceIndexSHA256: bundled.evidenceIndexSHA256,
            issuedAt: max(bundled.issuedAt, restriction.issuedAt),
            expiresAt: min(bundled.expiresAt, restriction.expiresAt),
            enabledNetworkIDs: bundled.enabledNetworkIDs
                .intersection(restriction.enabledNetworkIDs),
            enabledCapabilities: bundled.enabledCapabilities
                .intersection(restriction.enabledCapabilities),
            approvedRegions: bundled.approvedRegions.intersection(restriction.approvedRegions),
            completedApprovals: bundled.completedApprovals
                .intersection(restriction.completedApprovals)
        )
        return WalletLaunchGate(
            bundledNetworks: bundledNetworks,
            effectiveManifest: combined
        )
    }

    func authorize(
        networkID: String,
        capability: WalletNetworkCapability,
        regionCode: String,
        requireGA: Bool = false
    ) throws {
        guard let network = bundledNetworks[networkID] else {
            throw WalletLaunchGateError.networkNotReviewed
        }
        guard network.staticallyReviewedCapabilities.contains(capability) else {
            throw WalletLaunchGateError.capabilityNotReviewed
        }
        guard let manifest = effectiveManifest,
              manifest.enabledNetworkIDs.contains(networkID),
              manifest.enabledCapabilities.contains(capability) else {
            throw WalletLaunchGateError.capabilityNotReviewed
        }
        guard manifest.approvedRegions.contains(regionCode.uppercased()) else {
            throw WalletLaunchGateError.regionNotApproved
        }
        if requireGA, manifest.releaseStage != .generalAvailability {
            throw WalletLaunchGateError.generalAvailabilityNotApproved
        }
        let required = manifest.releaseStage == .generalAvailability
            ? Self.requiredGAApprovals : Self.requiredCanaryApprovals
        let missing = required.subtracting(manifest.completedApprovals)
        guard missing.isEmpty else {
            throw WalletLaunchGateError.approvalsIncomplete(missing)
        }
    }
}

enum WalletNetworkCatalog {
    static let ethereumMainnet = WalletNetworkDescriptor(
        canonicalID: "eip155:1", chain: .evm, environment: .mainnet,
        displayName: "Ethereum", identity: .init(kind: .eip155ChainID, value: "1"),
        nativeAssetID: "eip155:1/slip44:60", nativeSymbol: "ETH", nativeDecimals: 18,
        explorerTransactionURLTemplate: "https://etherscan.io/tx/{transaction}",
        staticallyReviewedCapabilities: [
            .nativeTransfer, .fungibleTokenTransfer, .exactInputSwap,
            .reviewedCall, .embeddedBrowser, .autonomousPolicy,
        ]
    )

    static let ethereumSepolia = WalletNetworkDescriptor(
        canonicalID: "eip155:11155111", chain: .evm, environment: .testnet,
        displayName: "Ethereum Sepolia",
        identity: .init(kind: .eip155ChainID, value: "11155111"),
        nativeAssetID: "eip155:11155111/slip44:60", nativeSymbol: "ETH", nativeDecimals: 18,
        explorerTransactionURLTemplate: "https://sepolia.etherscan.io/tx/{transaction}",
        staticallyReviewedCapabilities: Set(WalletNetworkCapability.allCases)
    )

    static let solanaMainnet = WalletNetworkDescriptor(
        canonicalID: "solana:mainnet-beta", chain: .solana, environment: .mainnet,
        displayName: "Solana",
        identity: .init(
            kind: .solanaGenesisHash,
            value: "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2d"
        ),
        nativeAssetID: "solana:mainnet-beta/slip44:501", nativeSymbol: "SOL", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://explorer.solana.com/tx/{transaction}",
        staticallyReviewedCapabilities: []
    )

    static let solanaDevnet = WalletNetworkDescriptor(
        canonicalID: "solana:devnet", chain: .solana, environment: .testnet,
        displayName: "Solana Devnet",
        identity: .init(kind: .solanaGenesisHash, value: "EtWTRABZaYq6iMfeYKouRu166VU2xqa1"),
        nativeAssetID: "solana:devnet/slip44:501", nativeSymbol: "SOL", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://explorer.solana.com/tx/{transaction}?cluster=devnet",
        staticallyReviewedCapabilities: []
    )

    static let suiMainnet = WalletNetworkDescriptor(
        canonicalID: "sui:mainnet", chain: .sui, environment: .mainnet,
        displayName: "Sui", identity: .init(kind: .suiChainIdentifier, value: "35834a8a"),
        nativeAssetID: "sui:mainnet/coin:0x2::sui::SUI", nativeSymbol: "SUI", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://suiscan.xyz/mainnet/tx/{transaction}",
        staticallyReviewedCapabilities: []
    )

    static let suiTestnet = WalletNetworkDescriptor(
        canonicalID: "sui:testnet", chain: .sui, environment: .testnet,
        displayName: "Sui Testnet", identity: .init(kind: .suiChainIdentifier, value: "4c78adac"),
        nativeAssetID: "sui:testnet/coin:0x2::sui::SUI", nativeSymbol: "SUI", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://suiscan.xyz/testnet/tx/{transaction}",
        staticallyReviewedCapabilities: []
    )

    static let all = [
        ethereumMainnet, ethereumSepolia, solanaMainnet, solanaDevnet, suiMainnet, suiTestnet,
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(id: String) -> WalletNetworkDescriptor? { byID[id] }
}
