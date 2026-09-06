import CryptoKit
import Foundation

enum WalletSolanaBase58 {
    private static let alphabet = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8
    )
    private static let positions = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) }
    )

    static func decode(_ value: String, exactLength: Int? = nil) -> Data? {
        let encoded = Array(value.utf8)
        guard !encoded.isEmpty, encoded.count <= 128 else { return nil }
        var littleEndian: [UInt8] = []
        for character in encoded {
            guard var carry = positions[character] else { return nil }
            for index in littleEndian.indices {
                let next = Int(littleEndian[index]) * 58 + carry
                littleEndian[index] = UInt8(next & 0xff)
                carry = next >> 8
            }
            while carry > 0 {
                littleEndian.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        let leadingZeroCount = encoded.prefix { $0 == alphabet[0] }.count
        let decoded = Data(
            Array(repeatElement(UInt8(0), count: leadingZeroCount))
                + Array(littleEndian.reversed())
        )
        guard exactLength.map({ decoded.count == $0 }) ?? true,
              encode(decoded) == value else { return nil }
        return decoded
    }

    static func encode(_ value: Data) -> String {
        guard !value.isEmpty else { return "" }
        let leadingZeroCount = value.prefix { $0 == 0 }.count
        var digits: [UInt8] = []
        for byte in value {
            var carry = Int(byte)
            for index in digits.indices {
                let next = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(next % 58)
                carry = next / 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let prefix = String(repeating: Character("1"), count: leadingZeroCount)
        let significant = digits.reversed().map {
            Character(UnicodeScalar(alphabet[Int($0)]))
        }
        return prefix + String(significant)
    }
}

/// Sui's current gRPC and GraphQL APIs report the full Base58 genesis
/// checkpoint digest. Older tooling stores the first four digest bytes as
/// eight lowercase hexadecimal characters. These are the only two encodings
/// accepted here; provider labels and environment names are never identities.
enum WalletSuiChainIdentity {
    static let mainnetBase58 = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"
    static let testnetBase58 = "69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD"

    static func matches(expected: String, reported: String) -> Bool {
        guard let expected = parsed(expected), let reported = parsed(reported) else {
            return false
        }
        switch (expected, reported) {
        case (.full(let lhs), .full(let rhs)):
            return lhs == rhs
        case (.short(let lhs), .short(let rhs)):
            return lhs == rhs
        case (.full(let full), .short(let short)), (.short(let short), .full(let full)):
            return full.prefix(short.count) == short
        }
    }

    static func shortHex(_ value: String) -> String? {
        guard let parsed = parsed(value) else { return nil }
        let bytes: Data
        switch parsed {
        case .full(let value): bytes = value.prefix(4)
        case .short(let value): bytes = value
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private enum Parsed {
        case full(Data)
        case short(Data)
    }

    private static func parsed(_ value: String) -> Parsed? {
        if value.count == 8, value == value.lowercased(),
           value.allSatisfy(\.isHexDigit), let bytes = hexadecimal(value) {
            return .short(bytes)
        }
        guard let bytes = WalletSolanaBase58.decode(value, exactLength: 32) else {
            return nil
        }
        return .full(bytes)
    }

    private static func hexadecimal(_ value: String) -> Data? {
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        return result
    }
}

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
    case standardizedSignIn = "standardized_sign_in"
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

/// A provider-normalized public activity item. Provider-specific response
/// shapes are discarded before this value reaches the wallet UI or database.
struct WalletEVMIndexedTransfer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let transactionHash: String
    let blockNumber: String
    let occurredAt: Date
    let from: String
    let to: String
    let assetID: String
    let amountBaseUnits: String
    let assetKind: WalletAssetKind
    let assetReference: String?
    let assetName: String
    let assetSymbol: String
    let assetDecimals: Int?
}

/// A provider-normalized ERC-20 holding. Metadata is deliberately excluded:
/// an unknown contract remains quarantined until a signed manifest or the user
/// supplies trust, and remote logos never cross this boundary.
struct WalletEVMDiscoveredAsset: Codable, Equatable, Identifiable, Sendable {
    var id: String { identity.canonicalID }

    let identity: WalletEVMAssetIdentity
    let balanceBaseUnits: String
}

struct WalletEVMNFTSnapshot: Codable, Equatable, Sendable {
    let assets: [WalletEVMDiscoveredAsset]
    let blockNumber: UInt64
    let blockHash: String
}

enum WalletSolanaTokenProgram: String, Codable, CaseIterable, Sendable {
    case spl = "spl"
    case token2022 = "token2022"

    var programID: String {
        switch self {
        case .spl: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        case .token2022: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
        }
    }

    var parsedProgramName: String {
        switch self {
        case .spl: "spl-token"
        case .token2022: "spl-token-2022"
        }
    }
}

struct WalletSolanaAssetIdentity: Codable, Equatable, Sendable {
    let networkID: String
    let program: WalletSolanaTokenProgram
    let mint: String

    var canonicalID: String { "\(networkID)/\(program.rawValue):\(mint)" }

    static func parse(_ value: String) -> Self? {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let networkID = String(components[0])
        let suffix = components[1].split(separator: ":", omittingEmptySubsequences: false)
        guard suffix.count == 2,
              let program = WalletSolanaTokenProgram(rawValue: String(suffix[0])),
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.chain == .solana else { return nil }
        let mint = String(suffix[1])
        guard WalletSolanaBase58.decode(mint, exactLength: 32) != nil else { return nil }
        let identity = Self(networkID: networkID, program: program, mint: mint)
        return identity.canonicalID == value ? identity : nil
    }
}

struct WalletSolanaTokenAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String { address }

    let address: String
    let owner: String
    let identity: WalletSolanaAssetIdentity
    let amountBaseUnits: String
    let decimals: Int
    let state: String
    let isNative: Bool
    /// Canonical RPC extension names. Unknown names remain visible to the
    /// quarantine model but are never silently treated as transferable.
    let extensions: [String]

    init(
        address: String,
        owner: String,
        identity: WalletSolanaAssetIdentity,
        amountBaseUnits: String,
        decimals: Int,
        state: String,
        isNative: Bool,
        extensions: [String] = []
    ) {
        self.address = address
        self.owner = owner
        self.identity = identity
        self.amountBaseUnits = amountBaseUnits
        self.decimals = decimals
        self.state = state
        self.isNative = isNative
        self.extensions = extensions
    }
}

/// Canonical identity for a Sui fungible asset. The GraphQL `MoveType.repr`
/// form intentionally becomes part of the public asset ID so a balance can
/// never be rebound to a different marker type or network.
struct WalletSuiAssetIdentity: Codable, Equatable, Sendable {
    static let nativeCoinType = "0x2::sui::SUI"

    let networkID: String
    let coinType: String

    var canonicalID: String { "\(networkID)/coin:\(coinType)" }

    static func parse(_ value: String) -> Self? {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let networkID = String(components[0])
        let prefix = "coin:"
        let suffix = String(components[1])
        guard suffix.hasPrefix(prefix),
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.chain == .sui else { return nil }
        let coinType = String(suffix.dropFirst(prefix.count))
        guard isCanonicalCoinType(coinType) else { return nil }
        let identity = Self(networkID: networkID, coinType: coinType)
        return identity.canonicalID == value ? identity : nil
    }

    static func isCanonicalCoinType(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x21 }),
              !value.contains("/"), !value.contains("<"), !value.contains(">") else {
            return false
        }
        let components = value.components(separatedBy: "::")
        guard components.count == 3 else { return false }
        let address = components[0]
        guard address.hasPrefix("0x"), (3...66).contains(address.count),
              address == address.lowercased() else { return false }
        let hex = address.dropFirst(2)
        guard !hex.isEmpty, hex.count <= 64,
              hex.first != "0" || hex.count == 1,
              hex.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else { return false }
        return components.dropFirst().allSatisfy(isMoveIdentifier)
    }

    private static func isMoveIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 95 || (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            byte == 95 || (48...57).contains(byte)
                || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }
}

struct WalletSuiBalance: Codable, Equatable, Sendable {
    let identity: WalletSuiAssetIdentity
    let totalBalance: String
    let coinBalance: String
    let addressBalance: String
}

enum WalletSuiAddress {
    static func isCanonical(_ value: String) -> Bool {
        value.count == 66 && value.hasPrefix("0x")
            && value == value.lowercased()
            && value.utf8.dropFirst(2).allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

struct WalletSuiObjectIdentity: Codable, Equatable, Sendable {
    let networkID: String
    let objectID: String

    var canonicalID: String { "\(networkID)/object:\(objectID)" }

    static func parse(_ value: String) -> Self? {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let networkID = String(components[0])
        let prefix = "object:"
        let suffix = String(components[1])
        guard suffix.hasPrefix(prefix),
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.chain == .sui else { return nil }
        let objectID = String(suffix.dropFirst(prefix.count))
        guard WalletSuiAddress.isCanonical(objectID) else { return nil }
        let identity = Self(networkID: networkID, objectID: objectID)
        return identity.canonicalID == value ? identity : nil
    }
}

struct WalletSuiOwnedObject: Codable, Equatable, Sendable {
    let identity: WalletSuiObjectIdentity
    let version: UInt64
    let digest: String
    let moveType: String
    let hasPublicTransfer: Bool
}

enum WalletSolanaCollectibleStandard: String, Codable, Sendable {
    case tokenMetadata = "token-metadata"
    case core
    case bubblegum
}

struct WalletSolanaCollectibleIdentity: Codable, Equatable, Sendable {
    let networkID: String
    let standard: WalletSolanaCollectibleStandard
    let address: String

    var canonicalID: String {
        "\(networkID)/nft:\(standard.rawValue):\(address)"
    }

    static func parse(_ value: String) -> Self? {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let networkID = String(components[0])
        let suffix = components[1].split(separator: ":", omittingEmptySubsequences: false)
        guard suffix.count == 3, suffix[0] == "nft",
              let standard = WalletSolanaCollectibleStandard(
                rawValue: String(suffix[1])
              ),
              WalletNetworkCatalog.descriptor(id: networkID)?.chain == .solana else {
            return nil
        }
        let address = String(suffix[2])
        guard WalletSolanaBase58.decode(address, exactLength: 32) != nil else {
            return nil
        }
        let identity = Self(
            networkID: networkID, standard: standard, address: address
        )
        return identity.canonicalID == value ? identity : nil
    }
}

struct WalletSolanaCollectible: Codable, Equatable, Identifiable, Sendable {
    var id: String { identity.canonicalID }

    let identity: WalletSolanaCollectibleIdentity
    let name: String
    let symbol: String
    let collectionAddress: String?
    let metadataURL: String?
    let rasterImageURL: String?
    let frozen: Bool
    let delegated: Bool
}

/// A finalized Solana transaction or exact owner balance effect normalized from
/// canonical RPC evidence. Unknown transaction shapes remain visible as a
/// transaction-level record without being guessed into a transfer standard.
enum WalletSolanaActivityDirection: String, Equatable, Sendable {
    case inbound
    case outbound
    case selfTransfer = "self_transfer"
}

struct WalletSolanaIndexedActivity: Equatable, Identifiable, Sendable {
    let id: String
    let signature: String
    let slot: UInt64
    let occurredAt: Date
    let successful: Bool
    let owner: String
    let feeBaseUnits: String
    let direction: WalletSolanaActivityDirection?
    let assetID: String?
    let assetKind: WalletAssetKind?
    let assetReference: String?
    let amountBaseUnits: String?
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

    var endpointSHA256: String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
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
    case derivationReproduction = "derivation_reproduction"
    case releaseCandidateBuild = "release_candidate_build"
    case publicationDisclosures = "publication_disclosures"
    case supportSecurityReadiness = "support_security_readiness"
}

/// Manifest-level ownership vocabulary. The connector identifier remains a
/// separate signed field, so a grant cannot silently change MetaMask/Slush
/// into a locally managed signer or expose Phantom as an external prompt.
enum WalletConnectorAccountOwnership: String, Codable, CaseIterable, Sendable {
    case locusVault = "locus_vault"
    case external
    case connectorManaged = "connector_managed"

    static func required(for connector: WalletConnectionConnector) -> Self {
        switch connector {
        case .metamask, .slush: .external
        case .phantom: .connectorManaged
        case .embeddedBrowser, .walletConnect: .locusVault
        }
    }
}

enum WalletReleaseStage: String, Codable, CaseIterable, Sendable {
    case experimentalMainnet = "experimental_mainnet"
    case invitedCanary = "invited_canary"
    case generalAvailability = "general_availability"

    fileprivate var authorityRank: Int {
        switch self {
        case .experimentalMainnet: -1
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
    let networkGrants: [WalletNetworkCapabilityGrant]
    let approvedRegions: Set<String>
    let completedApprovals: Set<WalletLaunchApproval>
    var canaryLimits: [WalletCanaryLimit]? = nil

    var enabledNetworkIDs: Set<String> { Set(networkGrants.map(\.networkID)) }
    var enabledCapabilities: Set<WalletNetworkCapability> {
        networkGrants.reduce(into: []) { $0.formUnion($1.capabilities) }
    }

    func grant(for networkID: String) -> WalletNetworkCapabilityGrant? {
        networkGrants.first { $0.networkID == networkID }
    }
}

extension WalletCapabilityManifest {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(revision, forKey: .revision)
        try values.encode(releaseStage, forKey: .releaseStage)
        try values.encode(evidenceIndexSHA256, forKey: .evidenceIndexSHA256)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(networkGrants, forKey: .networkGrants)
        try values.encode(approvedRegions.sorted(), forKey: .approvedRegions)
        try values.encode(completedApprovals.sorted { $0.rawValue < $1.rawValue }, forKey: .completedApprovals)
        try values.encodeIfPresent(canaryLimits, forKey: .canaryLimits)
    }
}


struct WalletConnectorCapabilityGrant: Codable, Equatable, Sendable {
    let connector: WalletConnectionConnector
    let ownership: WalletConnectorAccountOwnership
    let directions: Set<WalletConnectionDirection>
    let methods: Set<WalletConnectionMethod>
}

/// Signed finite budgets are independent of automation policy. They bind the
/// exact ownership, asset and action and remain cumulative across restarts.
struct WalletCanaryLimit: Codable, Equatable, Sendable {
    let networkID: String
    let assetID: String
    let action: WalletActionKind
    let ownership: WalletConnectorAccountOwnership
    let connector: WalletConnectionConnector?
    let maximumTransactionBaseUnits: String
    let maximumCumulativeBaseUnits: String
    let maximumFeeBaseUnits: String
    let maximumCumulativeFeeBaseUnits: String
    let maximumTransactions: Int

    var identity: String {
        [networkID, assetID, action.rawValue, ownership.rawValue,
         connector?.rawValue ?? "vault"].joined(separator: "|")
    }
}

extension WalletConnectorCapabilityGrant {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(connector, forKey: .connector)
        try values.encode(ownership, forKey: .ownership)
        try values.encode(directions.sorted { $0.rawValue < $1.rawValue }, forKey: .directions)
        try values.encode(methods.sorted { $0.rawValue < $1.rawValue }, forKey: .methods)
    }
}


struct WalletNetworkCapabilityGrant: Codable, Equatable, Sendable {
    let networkID: String
    let capabilities: Set<WalletNetworkCapability>
    let connectors: [WalletConnectorCapabilityGrant]
}

extension WalletNetworkCapabilityGrant {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(networkID, forKey: .networkID)
        try values.encode(capabilities.sorted { $0.rawValue < $1.rawValue }, forKey: .capabilities)
        try values.encode(connectors, forKey: .connectors)
    }
}


struct WalletSignedCapabilityManifest: Codable, Equatable, Sendable {
    let manifest: WalletCapabilityManifest
    let signatureBase64: String
}

/// The release-reviewed public trust roots for assets, contracts, explorers,
/// and transaction adapters. Runtime code hashes and ABIs remain signer-bound;
/// this manifest only identifies the exact public metadata reviewed for a
/// release. It can never contain wallet secrets or transaction bytes.
struct WalletReviewManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int
    let issuedAt: Date
    let expiresAt: Date
    let assets: [WalletAsset]
    let evmContracts: [WalletContractRegistryEntry]
    let explorerTemplates: [String: String]
    let adapterIDs: Set<String>
    let connectors: [WalletReviewedConnector]
    let providerIdentities: [WalletReviewedProviderIdentity]
    let signInAdapters: [WalletReviewedSignInAdapter]
    let programIdentities: [WalletReviewedProgramIdentity]
    let uniswapConfigurations: [WalletReviewedUniswapConfiguration]

    init(
        schemaVersion: Int,
        revision: Int,
        issuedAt: Date,
        expiresAt: Date,
        assets: [WalletAsset],
        evmContracts: [WalletContractRegistryEntry],
        explorerTemplates: [String: String],
        adapterIDs: Set<String>,
        connectors: [WalletReviewedConnector] = [],
        providerIdentities: [WalletReviewedProviderIdentity] = [],
        signInAdapters: [WalletReviewedSignInAdapter] = [],
        programIdentities: [WalletReviewedProgramIdentity] = [],
        uniswapConfigurations: [WalletReviewedUniswapConfiguration] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.assets = assets
        self.evmContracts = evmContracts
        self.explorerTemplates = explorerTemplates
        self.adapterIDs = adapterIDs
        self.connectors = connectors
        self.providerIdentities = providerIdentities
        self.signInAdapters = signInAdapters
        self.programIdentities = programIdentities
        self.uniswapConfigurations = uniswapConfigurations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, issuedAt, expiresAt, assets, evmContracts
        case explorerTemplates, adapterIDs, connectors, providerIdentities
        case signInAdapters, programIdentities
        case uniswapConfigurations
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(revision, forKey: .revision)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(assets, forKey: .assets)
        try values.encode(evmContracts, forKey: .evmContracts)
        try values.encode(explorerTemplates, forKey: .explorerTemplates)
        try values.encode(adapterIDs.sorted(), forKey: .adapterIDs)
        try values.encode(connectors, forKey: .connectors)
        try values.encode(providerIdentities, forKey: .providerIdentities)
        try values.encode(signInAdapters, forKey: .signInAdapters)
        try values.encode(programIdentities, forKey: .programIdentities)
        try values.encode(uniswapConfigurations, forKey: .uniswapConfigurations)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        assets = try container.decode([WalletAsset].self, forKey: .assets)
        evmContracts = try container.decode(
            [WalletContractRegistryEntry].self, forKey: .evmContracts
        )
        explorerTemplates = try container.decode(
            [String: String].self, forKey: .explorerTemplates
        )
        adapterIDs = try container.decode(Set<String>.self, forKey: .adapterIDs)
        connectors = try container.decodeIfPresent(
            [WalletReviewedConnector].self, forKey: .connectors
        ) ?? []
        providerIdentities = try container.decodeIfPresent(
            [WalletReviewedProviderIdentity].self, forKey: .providerIdentities
        ) ?? []
        signInAdapters = try container.decodeIfPresent(
            [WalletReviewedSignInAdapter].self, forKey: .signInAdapters
        ) ?? []
        programIdentities = try container.decodeIfPresent(
            [WalletReviewedProgramIdentity].self, forKey: .programIdentities
        ) ?? []
        uniswapConfigurations = try container.decodeIfPresent(
            [WalletReviewedUniswapConfiguration].self, forKey: .uniswapConfigurations
        ) ?? []
    }
}

struct WalletReviewedConnector: Codable, Equatable, Sendable {
    let connector: WalletConnectionConnector
    let ownership: WalletConnectorAccountOwnership
    let version: String
    let artifactSHA256: String
    let directions: Set<WalletConnectionDirection>
    let methods: Set<WalletConnectionMethod>
    let configurationSHA256: String?

    init(
        connector: WalletConnectionConnector,
        ownership: WalletConnectorAccountOwnership,
        version: String,
        artifactSHA256: String,
        directions: Set<WalletConnectionDirection>,
        methods: Set<WalletConnectionMethod>,
        configurationSHA256: String? = nil
    ) {
        self.connector = connector
        self.ownership = ownership
        self.version = version
        self.artifactSHA256 = artifactSHA256
        self.directions = directions
        self.methods = methods
        self.configurationSHA256 = configurationSHA256
    }
}

extension WalletReviewedConnector {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(connector, forKey: .connector)
        try values.encode(ownership, forKey: .ownership)
        try values.encode(version, forKey: .version)
        try values.encode(artifactSHA256, forKey: .artifactSHA256)
        try values.encodeIfPresent(configurationSHA256, forKey: .configurationSHA256)
        try values.encode(directions.sorted { $0.rawValue < $1.rawValue }, forKey: .directions)
        try values.encode(methods.sorted { $0.rawValue < $1.rawValue }, forKey: .methods)
    }
}

#if !LOCUS_APP_STORE
/// Domain-separated release configuration. Only its digest enters signed review
/// metadata; the underlying URLs/identifiers must never enter diagnostics.
/// The Python release audit reproduces these sorted, compact, ASCII JSON bytes.
enum WalletConnectorReleaseConfiguration {
    private static let padding = CharacterSet(charactersIn: " \t\r\n")

    static func bundledValues(from bundle: Bundle = .main) -> [String: String] {
        (bundle.infoDictionary ?? [:]).compactMapValues {
            ($0 as? String)?.trimmingCharacters(in: padding)
        }
    }

    /// Release never accepts process-environment replacement of sealed values.
    /// Debug overrides still have to match the signed configuration digest.
    static func runtimeValues(
        from bundle: Bundle, environment: [String: String]
    ) -> [String: String] {
        var values = bundledValues(from: bundle)
        #if DEBUG
        let keys = [
            "LocusPhantomAppID": "LOCUS_PHANTOM_APP_ID",
            "LocusPhantomRedirectURL": "LOCUS_PHANTOM_REDIRECT_URL",
            "LocusReownProjectID": "LOCUS_REOWN_PROJECT_ID",
            "LocusWalletConnectRedirectURL": "LOCUS_WALLETCONNECT_REDIRECT_URL",
            "LocusWalletAlchemyEthereumMainnetRPCURL": "LOCUS_WALLET_ALCHEMY_ETHEREUM_MAINNET_RPC_URL",
            "LocusWalletQuickNodeEthereumMainnetRPCURL": "LOCUS_WALLET_QUICKNODE_ETHEREUM_MAINNET_RPC_URL",
            "LocusWalletAlchemyEthereumSepoliaRPCURL": "LOCUS_WALLET_ALCHEMY_ETHEREUM_SEPOLIA_RPC_URL",
            "LocusWalletQuickNodeEthereumSepoliaRPCURL": "LOCUS_WALLET_QUICKNODE_ETHEREUM_SEPOLIA_RPC_URL",
        ]
        for (infoKey, environmentKey) in keys {
            if let override = environment[environmentKey] {
                values[infoKey] = override.trimmingCharacters(in: padding)
            }
        }
        #endif
        return values
    }

    static func digest(
        for connector: WalletConnectionConnector,
        values: [String: String],
        reviewedProviders: [WalletReviewedProviderIdentity] = []
    ) -> String? {
        guard let data = canonicalData(
            for: connector, values: values, reviewedProviders: reviewedProviders
        ) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalData(
        for connector: WalletConnectionConnector,
        values: [String: String],
        reviewedProviders: [WalletReviewedProviderIdentity] = []
    ) -> Data? {
        var payload: [String: Any] = [
            "format": "locus-wallet-connector-config-v1",
            "connector": connector.rawValue,
        ]
        switch connector {
        case .phantom:
            let appID = value("LocusPhantomAppID", in: values)
            let redirect = value("LocusPhantomRedirectURL", in: values)
            guard matches(appID, pattern: "^[A-Za-z0-9._-]{1,128}$"),
                  isCanonicalHTTPSURL(redirect) else { return nil }
            payload.merge([
                "appID": appID, "redirectURL": redirect,
                "providers": ["phantom"], "addressTypes": ["solana"],
                "embeddedWalletType": "user-wallet", "autoConnect": true,
            ]) { _, new in new }
        case .walletConnect:
            let projectID = value("LocusReownProjectID", in: values)
            let redirect = value("LocusWalletConnectRedirectURL", in: values)
            guard matches(projectID, pattern: "^[A-Za-z0-9_-]{16,128}$"),
                  redirect == "locus-wallet://walletconnect" else { return nil }
            payload.merge([
                "projectID": projectID, "redirectURL": redirect,
                "mode": "walletconnect-sign", "dappURL": "https://locus.app",
            ]) { _, new in new }
        case .metamask:
            let rpcURLs = metamaskRPCURLs(values: values, reviewedProviders: reviewedProviders)
            guard !rpcURLs.isEmpty else { return nil }
            payload.merge([
                "rpcURLs": rpcURLs, "dappName": "Locus", "dappURL": "https://locus.app",
                "analyticsEnabled": false, "skipAutoAnnounce": true,
            ]) { _, new in new }
        case .slush:
            payload.merge([
                "mode": "wallet-standard", "walletName": "Slush",
                "dappName": "Locus", "origin": "https://my.slush.app",
            ]) { _, new in new }
        case .embeddedBrowser:
            payload.merge(["mode": "embedded-browser", "signerProtocolVersion": 3]) {
                _, new in new
            }
        }
        return try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Exactly the provider map passed to MetaMask: reviewed Alchemy first,
    /// otherwise reviewed QuickNode, with unavailable networks omitted.
    static func metamaskRPCURLs(
        values: [String: String],
        reviewedProviders: [WalletReviewedProviderIdentity]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (networkID, name) in [
            ("eip155:1", "EthereumMainnet"), ("eip155:11155111", "EthereumSepolia"),
        ] {
            guard let network = WalletNetworkCatalog.descriptor(id: networkID) else { continue }
            for (provider, providerName) in [
                (WalletProviderKind.alchemy, "Alchemy"), (.quickNode, "QuickNode"),
            ] {
                let raw = value("LocusWallet\(providerName)\(name)RPCURL", in: values)
                guard isCanonicalHTTPSURL(raw), let url = URL(string: raw) else { continue }
                let endpoint = WalletProviderEndpoint(
                    id: "\(provider.rawValue):\(networkID)", provider: provider,
                    networkID: networkID, url: url,
                    priority: provider == .alchemy ? 0 : 1, expectedIdentity: network.identity
                )
                guard reviewedProviders.contains(where: { $0.matches(endpoint) }) else { continue }
                result[networkID] = raw
                break
            }
        }
        return result
    }

    private static func value(_ key: String, in values: [String: String]) -> String {
        (values[key] ?? "").trimmingCharacters(in: padding)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isCanonicalHTTPSURL(_ value: String) -> Bool {
        guard (1...2_048).contains(value.utf8.count),
              value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains(where: { "\\<>\"{}|^`[]".contains($0) }),
              value.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              let url = URL(string: value), url.absoluteString == value,
              url.scheme == "https", url.host?.isEmpty == false,
              url.port.map({ (1...65_535).contains($0) }) ?? true,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }
}
#endif


/// A release-reviewed provider configuration without persisting a credential-
/// bearing URL. `endpointSHA256` is the SHA-256 of the exact absolute URL used
/// by the app, including its path and any provider-specific project token.
struct WalletReviewedProviderIdentity: Codable, Equatable, Sendable {
    let networkID: String
    let provider: WalletProviderKind
    let configurationID: String
    let endpointSHA256: String
    let expectedIdentity: WalletChainIdentity

    func matches(_ endpoint: WalletProviderEndpoint) -> Bool {
        networkID == endpoint.networkID
            && provider == endpoint.provider
            && configurationID == endpoint.id
            && expectedIdentity == endpoint.expectedIdentity
            && endpointSHA256 == endpoint.endpointSHA256
    }
}

struct WalletReviewedSignInAdapter: Codable, Equatable, Sendable {
    let format: WalletStructuredAuthorizationFormat
    let version: String
    let implementationSHA256: String
    let networkIDs: Set<String>
}

extension WalletReviewedSignInAdapter {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format)
        try values.encode(version, forKey: .version)
        try values.encode(implementationSHA256, forKey: .implementationSHA256)
        try values.encode(networkIDs.sorted(), forKey: .networkIDs)
    }
}


enum WalletReviewedProgramKind: String, Codable, Sendable {
    case evmRuntime = "evm_runtime"
    case solanaProgram = "solana_program"
    case suiPackage = "sui_package"
}

struct WalletReviewedProgramIdentity: Codable, Equatable, Sendable {
    let networkID: String
    let kind: WalletReviewedProgramKind
    let identifier: String
    let codeSHA256: String
}

struct WalletSignedReviewManifest: Codable, Equatable, Sendable {
    let manifest: WalletReviewManifest
    let signatureBase64: String
}

enum WalletReviewManifestError: LocalizedError, Equatable {
    case malformed
    case invalidSignature
    case expired
    case broaderThanBundledReview

    var errorDescription: String? {
        switch self {
        case .malformed: "The wallet review manifest is malformed."
        case .invalidSignature: "The wallet review manifest signature is invalid."
        case .expired: "The wallet review manifest has expired."
        case .broaderThanBundledReview:
            "A remote wallet manifest attempted to broaden the bundled review set."
        }
    }
}

/// Validates the release review manifest and applies emergency updates with
/// intersection-only semantics. Remote data can remove a compromised asset,
/// contract, explorer, or adapter, but cannot introduce or alter one.
struct WalletReviewRegistry: Sendable {
    let manifest: WalletReviewManifest

    init(
        signedManifest: WalletSignedReviewManifest,
        publicKey: Curve25519.Signing.PublicKey,
        now: Date = Date()
    ) throws {
        let candidate = signedManifest.manifest
        guard Self.isStructurallyValid(candidate, now: now) else {
            throw WalletReviewManifestError.malformed
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(candidate)
        guard let signature = Data(base64Encoded: signedManifest.signatureBase64),
              publicKey.isValidSignature(signature, for: payload) else {
            throw WalletReviewManifestError.invalidSignature
        }
        guard candidate.expiresAt > now else { throw WalletReviewManifestError.expired }
        manifest = candidate
    }

    private init(manifest: WalletReviewManifest) {
        self.manifest = manifest
    }

    /// Only for constructing a non-activating scope projection after its
    /// distinct ceiling signature has been verified. This does not grant a
    /// network capability or replace a signed operational review lease.
    init(validatingScopeProjection manifest: WalletReviewManifest, now: Date) throws {
        guard Self.isStructurallyValid(manifest, now: now), manifest.expiresAt > now else {
            throw WalletReviewManifestError.malformed
        }
        self.manifest = manifest
    }

    var assets: [WalletAsset] { manifest.assets }
    var evmContracts: [WalletContractRegistryEntry] { manifest.evmContracts }

    static func loadBundled(from bundle: Bundle = .main) -> WalletReviewRegistry? {
        let authorityBundle: Bundle
        if bundle.object(forInfoDictionaryKey: "LocusWalletCapabilityPublicKey") != nil {
            authorityBundle = bundle
        } else {
            let signerURL = bundle.bundleURL
                .appendingPathComponent("Contents/XPCServices/WalletSigner.xpc")
            guard let signerBundle = Bundle(url: signerURL) else { return nil }
            authorityBundle = signerBundle
        }
        guard let publicKeyText = authorityBundle.object(
            forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
        ) as? String,
        let publicKeyData = Data(base64Encoded: publicKeyText),
        let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
        let manifestText = authorityBundle.object(
            forInfoDictionaryKey: "LocusWalletReviewManifestBase64"
        ) as? String,
        let manifestData = Data(base64Encoded: manifestText) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            WalletSignedReviewManifest.self, from: manifestData
        ) else { return nil }
        return try? WalletReviewRegistry(
            signedManifest: signed, publicKey: publicKey
        )
    }

    func restricted(
        by remote: WalletSignedReviewManifest,
        publicKey: Curve25519.Signing.PublicKey,
        now: Date = Date()
    ) throws -> WalletReviewRegistry {
        let restriction = try WalletReviewRegistry(
            signedManifest: remote, publicKey: publicKey, now: now
        ).manifest
        guard restriction.revision >= manifest.revision else {
            throw WalletReviewManifestError.malformed
        }
        guard restriction.assets.allSatisfy({ restricted in
            manifest.assets.contains { Self.sameAssetAuthority($0, restricted) }
        }), restriction.evmContracts.allSatisfy({ manifest.evmContracts.contains($0) }),
        restriction.explorerTemplates.allSatisfy({ networkID, template in
            manifest.explorerTemplates[networkID] == template
        }), restriction.adapterIDs.isSubset(of: manifest.adapterIDs),
        restriction.connectors.allSatisfy({ restricted in
            manifest.connectors.contains { ceiling in
                ceiling.connector == restricted.connector
                    && ceiling.ownership == restricted.ownership
                    && ceiling.version == restricted.version
                    && ceiling.artifactSHA256 == restricted.artifactSHA256
                    && ceiling.configurationSHA256 == restricted.configurationSHA256
                    && restricted.directions.isSubset(of: ceiling.directions)
                    && restricted.methods.isSubset(of: ceiling.methods)
            }
        }), restriction.providerIdentities.allSatisfy({
            manifest.providerIdentities.contains($0)
        }), restriction.signInAdapters.allSatisfy({ manifest.signInAdapters.contains($0) }),
        restriction.programIdentities.allSatisfy({ manifest.programIdentities.contains($0) }),
        restriction.uniswapConfigurations.allSatisfy({
            manifest.uniswapConfigurations.contains($0)
        }) else {
            throw WalletReviewManifestError.broaderThanBundledReview
        }
        let requestedAssets = Dictionary(
            uniqueKeysWithValues: restriction.assets.map { ($0.id, $0) }
        )
        let requestedContracts = Dictionary(
            uniqueKeysWithValues: restriction.evmContracts.map { ($0.id, $0) }
        )
        let assets = manifest.assets.filter { asset in
            requestedAssets[asset.id].map { Self.sameAssetAuthority(asset, $0) } == true
        }
        let contracts = manifest.evmContracts.filter { entry in
            requestedContracts[entry.id] == entry
        }
        let explorers = manifest.explorerTemplates.filter { networkID, template in
            restriction.explorerTemplates[networkID] == template
        }
        let adapters = manifest.adapterIDs.intersection(restriction.adapterIDs)
        let connectors: [WalletReviewedConnector] = manifest.connectors.compactMap { reviewed in
            guard let narrowed = restriction.connectors.first(where: {
                $0.connector == reviewed.connector
                    && $0.version == reviewed.version
                    && $0.artifactSHA256 == reviewed.artifactSHA256
                    && $0.configurationSHA256 == reviewed.configurationSHA256
            }) else { return nil }
            let directions = reviewed.directions.intersection(narrowed.directions)
            let methods = reviewed.methods.intersection(narrowed.methods)
            guard !directions.isEmpty, !methods.isEmpty else { return nil }
            return WalletReviewedConnector(
                connector: reviewed.connector,
                ownership: reviewed.ownership,
                version: reviewed.version,
                artifactSHA256: reviewed.artifactSHA256,
                directions: directions,
                methods: methods,
                configurationSHA256: reviewed.configurationSHA256
            )
        }
        let signInAdapters = manifest.signInAdapters.filter {
            restriction.signInAdapters.contains($0)
        }
        let providerIdentities = manifest.providerIdentities.filter {
            restriction.providerIdentities.contains($0)
        }
        let programIdentities = manifest.programIdentities.filter {
            restriction.programIdentities.contains($0)
        }
        let uniswapConfigurations = manifest.uniswapConfigurations.filter {
            restriction.uniswapConfigurations.contains($0)
        }
        return WalletReviewRegistry(manifest: WalletReviewManifest(
            schemaVersion: manifest.schemaVersion,
            revision: restriction.revision,
            issuedAt: max(manifest.issuedAt, restriction.issuedAt),
            expiresAt: min(manifest.expiresAt, restriction.expiresAt),
            assets: assets, evmContracts: contracts,
            explorerTemplates: explorers, adapterIDs: adapters,
            connectors: connectors,
            providerIdentities: providerIdentities,
            signInAdapters: signInAdapters,
            programIdentities: programIdentities,
            uniswapConfigurations: uniswapConfigurations
        ))
    }

    func containsExactContract(_ entry: WalletContractRegistryEntry) -> Bool {
        manifest.adapterIDs.contains(entry.reviewedAdapterID ?? "")
            && manifest.evmContracts.contains(entry)
    }

    func containsExactAsset(_ asset: WalletAsset) -> Bool {
        manifest.assets.contains { Self.sameAssetAuthority($0, asset) }
    }

    func containsAdapter(_ adapterID: String) -> Bool {
        manifest.adapterIDs.contains(adapterID)
    }

    func containsSignInAdapter(
        format: WalletStructuredAuthorizationFormat,
        networkID: String
    ) -> Bool {
        manifest.signInAdapters.contains {
            $0.format == format && $0.networkIDs.contains(networkID)
        }
    }

    func containsConnector(
        _ connector: WalletConnectionConnector,
        direction: WalletConnectionDirection,
        method: WalletConnectionMethod,
        configurationValues: [String: String]? = nil
    ) -> Bool {
        #if LOCUS_APP_STORE
        return false
        #else
        guard let configurationDigest = WalletConnectorReleaseConfiguration.digest(
            for: connector,
            values: configurationValues ?? WalletConnectorReleaseConfiguration.bundledValues(),
            reviewedProviders: manifest.providerIdentities
        ) else { return false }
        let identity = WalletConnectorBuildIdentity.reviewed(connector)
        return manifest.connectors.contains { entry in
            entry.connector == connector
                && entry.ownership == .required(for: connector)
                && entry.directions.contains(direction)
                && entry.methods.contains(method)
                && entry.configurationSHA256 == configurationDigest
                && (identity.map {
                    entry.version == $0.version
                        && entry.artifactSHA256 == $0.artifactSHA256
                } ?? true)
        }
        #endif
    }

    func containsProvider(_ endpoint: WalletProviderEndpoint) -> Bool {
        manifest.providerIdentities.contains { $0.matches(endpoint) }
    }

    func uniswapConfiguration(
        networkID: String,
        universalRouterContractID: String
    ) -> WalletReviewedUniswapConfiguration? {
        manifest.uniswapConfigurations.first {
            $0.networkID == networkID
                && $0.universalRouterContractID == universalRouterContractID
        }
    }

    private static func isStructurallyValid(
        _ manifest: WalletReviewManifest,
        now: Date
    ) -> Bool {
        guard manifest.schemaVersion == 2, manifest.revision > 0,
              manifest.issuedAt <= now,
              manifest.expiresAt > manifest.issuedAt,
              manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60,
              manifest.assets.count <= 10_000,
              manifest.evmContracts.count <= 2_000,
              manifest.connectors.count <= WalletConnectionConnector.allCases.count,
              manifest.providerIdentities.count <= WalletNetworkCatalog.all.count * 4,
              manifest.signInAdapters.count <= 8,
              manifest.programIdentities.count <= 256,
              manifest.uniswapConfigurations.count <= 8,
              manifest.explorerTemplates.count <= WalletNetworkCatalog.all.count,
              manifest.adapterIDs.isSubset(of: WalletReviewedAdapters.staticallySupportedIDs),
              Set(manifest.assets.map(\.id)).count == manifest.assets.count,
              Set(manifest.evmContracts.map(\.id)).count == manifest.evmContracts.count,
              Set(manifest.evmContracts.map {
                  "\($0.networkID):\($0.checksumAddress.lowercased())"
              }).count == manifest.evmContracts.count,
              Set(manifest.connectors.map(\.connector)).count == manifest.connectors.count,
              Set(manifest.providerIdentities.map {
                  "\($0.networkID):\($0.configurationID)"
              }).count == manifest.providerIdentities.count,
              Set(manifest.signInAdapters.map {
                  "\($0.format.rawValue):\($0.networkIDs.sorted().joined(separator: ","))"
              }).count == manifest.signInAdapters.count,
              Set(manifest.programIdentities.map {
                  "\($0.networkID):\($0.kind.rawValue):\($0.identifier)"
              }).count == manifest.programIdentities.count,
              Set(manifest.uniswapConfigurations.map {
                  "\($0.networkID):\($0.universalRouterContractID)"
              }).count == manifest.uniswapConfigurations.count,
              manifest.assets.allSatisfy({ validAsset($0, revision: manifest.revision) }),
              manifest.evmContracts.allSatisfy({ entry in
                  validContract(entry, manifest: manifest)
              }),
              manifest.connectors.allSatisfy(validConnector),
              manifest.providerIdentities.allSatisfy(validProviderIdentity),
              manifest.signInAdapters.allSatisfy(validSignInAdapter),
              manifest.programIdentities.allSatisfy(validProgramIdentity),
              manifest.uniswapConfigurations.allSatisfy({ configuration in
                  validUniswapConfiguration(configuration, manifest: manifest)
              }),
              (!manifest.adapterIDs.contains(
                WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn
              ) || !manifest.uniswapConfigurations.isEmpty),
              manifest.uniswapConfigurations.allSatisfy({ _ in
                  manifest.adapterIDs.contains(
                    WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn
                  )
              }) else { return false }
        return manifest.explorerTemplates.allSatisfy { networkID, template in
            WalletNetworkCatalog.descriptor(id: networkID)?.explorerTransactionURLTemplate
                == template
        }
    }

    private static func validConnector(_ entry: WalletReviewedConnector) -> Bool {
        guard validVersion(entry.version), validSHA256(entry.artifactSHA256),
              entry.configurationSHA256.map(validSHA256) ?? true,
              entry.ownership == .required(for: entry.connector),
              !entry.directions.isEmpty, !entry.methods.isEmpty else { return false }
        switch entry.connector {
        case .metamask:
            return entry.directions == [.externalAccountToLocus]
                && entry.methods.isSubset(of: [
                    .listAccounts, .switchNetwork, .sendTransaction,
                    .signInWithEthereum,
                ])
        case .phantom:
            return entry.directions == [.externalAccountToLocus]
                && entry.methods.isSubset(of: [
                    .listAccounts, .switchNetwork, .sendTransaction,
                    .signInWithSolana,
                ])
        case .slush:
            return entry.directions == [.externalAccountToLocus]
                && entry.methods.isSubset(of: [
                    .listAccounts, .switchNetwork, .sendTransaction,
                ])
        case .embeddedBrowser, .walletConnect:
            return entry.directions == [.locusVaultToDapp]
        }
    }

    private static func validProviderIdentity(
        _ entry: WalletReviewedProviderIdentity
    ) -> Bool {
        guard let network = WalletNetworkCatalog.descriptor(id: entry.networkID),
              entry.expectedIdentity == network.identity,
              validSHA256(entry.endpointSHA256),
              entry.configurationID == "\(entry.provider.rawValue):\(entry.networkID)" else {
            return false
        }
        return entry.provider != .local
    }

    private static func validSignInAdapter(_ entry: WalletReviewedSignInAdapter) -> Bool {
        guard validVersion(entry.version), validSHA256(entry.implementationSHA256),
              !entry.networkIDs.isEmpty else { return false }
        return entry.networkIDs.allSatisfy { networkID in
            guard let chain = WalletNetworkCatalog.descriptor(id: networkID)?.chain else {
                return false
            }
            return (entry.format == .siwe && chain == .evm)
                || (entry.format == .siws && chain == .solana)
        }
    }

    private static func validProgramIdentity(_ entry: WalletReviewedProgramIdentity) -> Bool {
        guard let chain = WalletNetworkCatalog.descriptor(id: entry.networkID)?.chain,
              !entry.identifier.isEmpty, entry.identifier.utf8.count <= 256,
              validSHA256(entry.codeSHA256) else { return false }
        return switch entry.kind {
        case .evmRuntime: chain == .evm
        case .solanaProgram: chain == .solana
        case .suiPackage: chain == .sui
        }
    }

    private static func validUniswapConfiguration(
        _ configuration: WalletReviewedUniswapConfiguration,
        manifest: WalletReviewManifest
    ) -> Bool {
        guard WalletNetworkCatalog.descriptor(id: configuration.networkID)?.chain == .evm,
              (1...3).contains(configuration.maximumHops),
              configuration.contracts.count
                == WalletReviewedUniswapContractRole.allCases.count,
              Set(configuration.contracts.map(\.role)).count
                == configuration.contracts.count,
              configuration.pools.count <= 512,
              !configuration.pools.isEmpty,
              Set(configuration.pools.map {
                  "\($0.protocolVersion.rawValue):\($0.address.lowercased())"
              }).count == configuration.pools.count,
              configuration.allowedFeeTiers.count <= 16,
              configuration.allowedFeeTiers.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }),
              let routerEntry = manifest.evmContracts.first(where: {
                  $0.id == configuration.universalRouterContractID
                      && $0.networkID == configuration.networkID
              }),
              routerEntry.reviewedAdapterID
                == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
              let reviewedRouter = configuration.contract(.universalRouter),
              reviewedRouter.address.caseInsensitiveCompare(
                  routerEntry.checksumAddress
              ) == .orderedSame,
              reviewedRouter.runtimeCodeHash.caseInsensitiveCompare(
                  routerEntry.runtimeCodeHash
              ) == .orderedSame,
              let permit2Entry = manifest.evmContracts.first(where: {
                  $0.id == configuration.permit2ContractID
                      && $0.networkID == configuration.networkID
              }),
              permit2Entry.reviewedAdapterID
                == WalletReviewedAdapters.uniswapPermit2AllowanceSetup,
              let reviewedPermit2 = configuration.contract(.permit2),
              reviewedPermit2.address.caseInsensitiveCompare(
                  permit2Entry.checksumAddress
              ) == .orderedSame,
              reviewedPermit2.runtimeCodeHash.caseInsensitiveCompare(
                  permit2Entry.runtimeCodeHash
              ) == .orderedSame else { return false }

        let manifestAssetIDs = Set(manifest.assets.filter {
            $0.networkID == configuration.networkID
                && $0.chain == .evm && $0.kind == .fungibleToken
                && $0.trust == .curated
        }.map(\.id))
        let poolAssetIDs = Set(configuration.pools.flatMap {
            [$0.token0AssetID, $0.token1AssetID]
        })
        let reviewedTokenAssetIDs = Set(poolAssetIDs.compactMap { assetID -> String? in
            guard let identity = WalletEVMAssetIdentity.parse(assetID),
                  identity.networkID == configuration.networkID,
                  identity.standard == .erc20, identity.tokenID == nil,
                  manifest.evmContracts.contains(where: {
                      $0.networkID == configuration.networkID
                          && $0.checksumAddress.caseInsensitiveCompare(
                            identity.contractAddress
                          ) == .orderedSame
                          && $0.reviewedAdapterID == WalletReviewedAdapters.erc20
                  }) else { return nil }
            return assetID
        })
        guard manifest.adapterIDs.contains(WalletReviewedAdapters.erc20),
              poolAssetIDs.isSubset(of: reviewedTokenAssetIDs),
              configuration.allowedIntermediaryAssetIDs.isSubset(of: poolAssetIDs),
              configuration.zeroFirstApprovalAssetIDs.isSubset(of: poolAssetIDs),
              configuration.contracts.allSatisfy({
                  validEVMAddress($0.address) && validRuntimeCodeHash($0.runtimeCodeHash)
              }),
              Set(configuration.contracts.map { $0.address.lowercased() }).count
                == configuration.contracts.count else { return false }

        return configuration.pools.allSatisfy { pool in
            guard validEVMAddress(pool.address),
                  validRuntimeCodeHash(pool.runtimeCodeHash),
                  pool.token0AssetID != pool.token1AssetID,
                  manifestAssetIDs.contains(pool.token0AssetID),
                  manifestAssetIDs.contains(pool.token1AssetID) else { return false }
            switch pool.protocolVersion {
            case .v2:
                return pool.feeTier == nil
            case .v3:
                guard let feeTier = pool.feeTier else { return false }
                return configuration.allowedFeeTiers.contains(feeTier)
            }
        }
    }

    private static func validEVMAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func validRuntimeCodeHash(_ value: String) -> Bool {
        value.count == 66 && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func validAsset(_ asset: WalletAsset, revision: Int) -> Bool {
        guard asset.trust == .curated, asset.manifestRevision == revision,
              let network = WalletNetworkCatalog.descriptor(id: asset.networkID),
              network.chain == asset.chain,
              !asset.name.isEmpty, asset.name.count <= 128,
              !asset.symbol.isEmpty, asset.symbol.count <= 32 else { return false }
        if asset.kind == .native {
            return asset.id == network.nativeAssetID && asset.reference == nil
                && asset.decimals == network.nativeDecimals
        }
        guard let reference = asset.reference else { return false }
        if network.chain == .evm {
            guard let identity = WalletEVMAssetIdentity.parse(asset.id),
                  identity.networkID == network.id,
                  identity.contractAddress.caseInsensitiveCompare(reference) == .orderedSame else {
                return false
            }
            switch identity.standard {
            case .erc20:
                return asset.kind == .fungibleToken && identity.tokenID == nil
                    && asset.decimals.map { (0...255).contains($0) } == true
            case .erc721:
                return (asset.kind == .nft || asset.kind == .collectible)
                    && (asset.decimals == nil || asset.decimals == 0)
            case .erc1155:
                return (asset.kind == .nft || asset.kind == .collectible)
                    && identity.tokenID != nil
                    && (asset.decimals == nil || asset.decimals == 0)
            }
        }
        if network.chain == .solana {
            if let collectible = WalletSolanaCollectibleIdentity.parse(asset.id) {
                return collectible.networkID == network.id
                    && collectible.address == reference
                    && (asset.kind == .nft || asset.kind == .collectible)
                    && (asset.decimals == nil || asset.decimals == 0)
            }
            guard let identity = WalletSolanaAssetIdentity.parse(asset.id),
                  identity.networkID == network.id,
                  identity.mint == reference,
                  let decimals = asset.decimals, (0...255).contains(decimals) else {
                return false
            }
            switch asset.kind {
            case .fungibleToken:
                return true
            case .nft, .collectible:
                return decimals == 0
            case .native:
                return false
            }
        }
        if let identity = WalletSuiAssetIdentity.parse(asset.id) {
            guard identity.networkID == network.id,
                  identity.coinType == reference,
                  asset.kind == .fungibleToken,
                  let decimals = asset.decimals, (0...255).contains(decimals) else {
                return false
            }
            return identity.coinType != WalletSuiAssetIdentity.nativeCoinType
        }
        guard let identity = WalletSuiObjectIdentity.parse(asset.id),
              identity.networkID == network.id,
              identity.objectID == reference,
              (asset.kind == .nft || asset.kind == .collectible) else { return false }
        return asset.decimals == nil || asset.decimals == 0
    }

    private static func validContract(
        _ entry: WalletContractRegistryEntry,
        manifest: WalletReviewManifest
    ) -> Bool {
        guard WalletNetworkCatalog.descriptor(id: entry.networkID)?.chain == .evm,
              entry.checksumAddress.count == 42,
              entry.checksumAddress.hasPrefix("0x"),
              entry.checksumAddress.dropFirst(2).allSatisfy(\.isHexDigit),
              entry.runtimeCodeHash.count == 66,
              entry.runtimeCodeHash.hasPrefix("0x"),
              entry.runtimeCodeHash.dropFirst(2).allSatisfy(\.isHexDigit),
              entry.abiDigest.hasPrefix("sha256:"), entry.abiDigest.count == 71,
              entry.abiDigest.dropFirst(7).utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              entry.permittedFunctions.count == entry.permittedSelectors.count,
              !entry.permittedFunctions.isEmpty,
              entry.permittedSelectors.allSatisfy({ selector in
                  selector.count == 10 && selector.hasPrefix("0x")
                      && selector.dropFirst(2).allSatisfy(\.isHexDigit)
              }),
              let adapterID = WalletReviewedAdapters.validatedID(for: entry),
              manifest.adapterIDs.contains(adapterID),
              entry.verifiedAt <= manifest.issuedAt else { return false }
        return true
    }

    private static func sameAssetAuthority(_ lhs: WalletAsset, _ rhs: WalletAsset) -> Bool {
        lhs.canonicalID == rhs.canonicalID
            && lhs.networkID == rhs.networkID
            && lhs.chain == rhs.chain
            && lhs.kind == rhs.kind
            && lhs.reference == rhs.reference
            && lhs.name == rhs.name
            && lhs.symbol == rhs.symbol
            && lhs.decimals == rhs.decimals
            && lhs.trust == rhs.trust
    }
}

enum WalletLaunchGateError: LocalizedError, Equatable {
    case invalidManifest
    case invalidSignature
    case expiredManifest
    case networkNotReviewed
    case capabilityNotReviewed
    case connectorNotReviewed
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
        case .connectorNotReviewed:
            "This connector, direction, or method has not passed its review gate."
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
        .derivationReproduction, .releaseCandidateBuild,
    ]

    let bundledNetworks: [String: WalletNetworkDescriptor]
    let effectiveManifest: WalletCapabilityManifest?
    private let allowsExperimentalMainnet: Bool

    init(
        bundledNetworks: [WalletNetworkDescriptor] = WalletNetworkCatalog.all,
        signedManifest: WalletSignedCapabilityManifest? = nil,
        publicKey: Curve25519.Signing.PublicKey? = nil,
        now: Date = Date(),
        allowExperimentalMainnet: Bool = false
    ) throws {
        self.bundledNetworks = Dictionary(uniqueKeysWithValues: bundledNetworks.map { ($0.id, $0) })
        #if LOCUS_APP_STORE
        self.allowsExperimentalMainnet = false
        #else
        self.allowsExperimentalMainnet = allowExperimentalMainnet
        #endif
        guard let signedManifest else {
            effectiveManifest = nil
            return
        }
        guard let publicKey,
              signedManifest.manifest.schemaVersion == 3,
              signedManifest.manifest.revision > 0,
              signedManifest.manifest.issuedAt <= now,
              signedManifest.manifest.expiresAt
                > signedManifest.manifest.issuedAt,
              Self.validGrantShape(
                  signedManifest.manifest,
                  bundledNetworks: self.bundledNetworks
              ),
              Self.validEvidenceShape(signedManifest.manifest,
                  allowExperimentalMainnet: allowsExperimentalMainnet) else {
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
        effectiveManifest: WalletCapabilityManifest?,
        allowsExperimentalMainnet: Bool
    ) {
        self.bundledNetworks = bundledNetworks
        self.effectiveManifest = effectiveManifest
        self.allowsExperimentalMainnet = allowsExperimentalMainnet
    }

    private static func validEvidenceShape(_ manifest: WalletCapabilityManifest,
                                           allowExperimentalMainnet: Bool) -> Bool {
        if manifest.releaseStage == .experimentalMainnet {
            // Experimental authority claims no audit, legal-region or release
            // evidence. Its exact operational scope is still signed.
            return allowExperimentalMainnet && manifest.evidenceIndexSHA256.isEmpty
                && manifest.completedApprovals.isEmpty && manifest.approvedRegions.isEmpty
                && (manifest.canaryLimits ?? []).isEmpty
                && manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 86_400
        }
        return manifest.evidenceIndexSHA256.count == 64
            && manifest.evidenceIndexSHA256.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
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
        // An experimental document cannot remove production release gates;
        // a production document cannot relabel experimental testing as GA.
        guard (bundled.releaseStage == .experimentalMainnet)
                == (remote.manifest.releaseStage == .experimentalMainnet) else {
            throw WalletLaunchGateError.invalidManifest
        }
        let remoteGate = try WalletLaunchGate(
            bundledNetworks: Array(bundledNetworks.values),
            signedManifest: remote, publicKey: publicKey, now: now,
            allowExperimentalMainnet: allowsExperimentalMainnet
        )
        guard let restriction = remoteGate.effectiveManifest,
              restriction.revision >= bundled.revision else {
            throw WalletLaunchGateError.invalidManifest
        }
        let networkGrants: [WalletNetworkCapabilityGrant] = bundled.networkGrants.compactMap {
            bundledGrant in
            guard let restrictionGrant = restriction.grant(for: bundledGrant.networkID) else {
                return nil
            }
            let connectorGrants: [WalletConnectorCapabilityGrant] =
                bundledGrant.connectors.compactMap { bundledConnector in
                guard let restrictionConnector = restrictionGrant.connectors.first(
                    where: { $0.connector == bundledConnector.connector }
                ) else { return nil }
                let directions = bundledConnector.directions.intersection(
                    restrictionConnector.directions
                )
                let methods = bundledConnector.methods.intersection(
                    restrictionConnector.methods
                )
                guard !directions.isEmpty, !methods.isEmpty else { return nil }
                return WalletConnectorCapabilityGrant(
                    connector: bundledConnector.connector,
                    ownership: bundledConnector.ownership,
                    directions: directions,
                    methods: methods
                )
            }
            let capabilities = bundledGrant.capabilities.intersection(
                restrictionGrant.capabilities
            )
            guard !capabilities.isEmpty else { return nil }
            return WalletNetworkCapabilityGrant(
                networkID: bundledGrant.networkID,
                capabilities: capabilities,
                connectors: connectorGrants
            )
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
            networkGrants: networkGrants,
            approvedRegions: bundled.approvedRegions.intersection(restriction.approvedRegions),
            completedApprovals: bundled.completedApprovals
                .intersection(restriction.completedApprovals),
            canaryLimits: (bundled.canaryLimits ?? []).filter { limit in
                restriction.canaryLimits?.contains(limit) == true
            }
        )
        return WalletLaunchGate(
            bundledNetworks: bundledNetworks,
            effectiveManifest: combined,
            allowsExperimentalMainnet: allowsExperimentalMainnet
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
              manifest.expiresAt > Date(),
              manifest.grant(for: networkID)?.capabilities.contains(capability) == true else {
            throw WalletLaunchGateError.capabilityNotReviewed
        }
        if manifest.releaseStage == .experimentalMainnet {
            guard allowsExperimentalMainnet else { throw WalletLaunchGateError.invalidManifest }
            if requireGA { throw WalletLaunchGateError.generalAvailabilityNotApproved }
            return
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

    func authorizeConnection(
        networkID: String,
        connector: WalletConnectionConnector,
        direction: WalletConnectionDirection,
        method: WalletConnectionMethod,
        regionCode: String,
        requireGA: Bool = false
    ) throws {
        let capability: WalletNetworkCapability = switch connector {
        case .metamask, .phantom, .slush: .externalWallet
        case .embeddedBrowser: .embeddedBrowser
        case .walletConnect: .walletConnect
        }
        try authorize(
            networkID: networkID,
            capability: capability,
            regionCode: regionCode,
            requireGA: requireGA
        )
        guard let connectorGrant = effectiveManifest?.grant(for: networkID)?.connectors.first(
            where: { $0.connector == connector }
        ), connectorGrant.directions.contains(direction),
        connectorGrant.methods.contains(method) else {
            throw WalletLaunchGateError.connectorNotReviewed
        }
    }

    private static func validGrantShape(
        _ manifest: WalletCapabilityManifest,
        bundledNetworks: [String: WalletNetworkDescriptor]
    ) -> Bool {
        guard !manifest.networkGrants.isEmpty,
              Set(manifest.networkGrants.map(\.networkID)).count
                == manifest.networkGrants.count else { return false }
        return manifest.networkGrants.allSatisfy { grant in
            guard let network = bundledNetworks[grant.networkID],
                  !grant.capabilities.isEmpty,
                  grant.capabilities.isSubset(of: network.staticallyReviewedCapabilities),
                  Set(grant.connectors.map(\.connector)).count == grant.connectors.count else {
                return false
            }
            return grant.connectors.allSatisfy { connector in
                let requiredCapability: WalletNetworkCapability = switch connector.connector {
                case .metamask, .phantom, .slush: .externalWallet
                case .embeddedBrowser: .embeddedBrowser
                case .walletConnect: .walletConnect
                }
                guard grant.capabilities.contains(requiredCapability),
                      connector.ownership == .required(for: connector.connector),
                      !connector.directions.isEmpty, !connector.methods.isEmpty else {
                    return false
                }
                switch connector.connector {
                case .metamask:
                    return network.chain == .evm
                        && connector.directions == [.externalAccountToLocus]
                        && connector.methods.isSubset(of: [
                            .listAccounts, .switchNetwork, .sendTransaction,
                            .signInWithEthereum,
                        ])
                case .phantom:
                    return network.chain == .solana
                        && connector.directions == [.externalAccountToLocus]
                        && connector.methods.isSubset(of: [
                            .listAccounts, .switchNetwork, .sendTransaction,
                            .signInWithSolana,
                        ])
                case .slush:
                    return network.chain == .sui
                        && connector.directions == [.externalAccountToLocus]
                        && connector.methods.isSubset(of: [
                            .listAccounts, .switchNetwork, .sendTransaction,
                        ])
                case .embeddedBrowser, .walletConnect:
                    let methods: Set<WalletConnectionMethod> = switch network.chain {
                    case .evm:
                        [.listAccounts, .switchNetwork, .sendTransaction,
                         .signInWithEthereum]
                    case .solana:
                        [.listAccounts, .switchNetwork, .sendTransaction,
                         .signInWithSolana]
                    case .sui:
                        [.listAccounts, .switchNetwork, .sendTransaction]
                    }
                    return connector.directions == [.locusVaultToDapp]
                        && connector.methods.isSubset(of: methods)
                }
            }
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
            .nativeTransfer, .fungibleTokenTransfer, .nftTransfer, .exactInputSwap,
            .reviewedCall, .embeddedBrowser, .externalWallet, .walletConnect,
            .standardizedSignIn, .autonomousPolicy,
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
        staticallyReviewedCapabilities: [
            .nativeTransfer, .fungibleTokenTransfer, .nftTransfer, .autonomousPolicy,
            .embeddedBrowser, .externalWallet, .walletConnect, .standardizedSignIn,
        ]
    )

    static let solanaDevnet = WalletNetworkDescriptor(
        canonicalID: "solana:devnet", chain: .solana, environment: .testnet,
        displayName: "Solana Devnet",
        identity: .init(kind: .solanaGenesisHash, value: "EtWTRABZaYq6iMfeYKouRu166VU2xqa1"),
        nativeAssetID: "solana:devnet/slip44:501", nativeSymbol: "SOL", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://explorer.solana.com/tx/{transaction}?cluster=devnet",
        staticallyReviewedCapabilities: [
            .nativeTransfer, .fungibleTokenTransfer, .nftTransfer,
            .embeddedBrowser, .externalWallet, .walletConnect, .standardizedSignIn,
            .autonomousPolicy,
        ]
    )

    static let suiMainnet = WalletNetworkDescriptor(
        canonicalID: "sui:mainnet", chain: .sui, environment: .mainnet,
        displayName: "Sui", identity: .init(
            kind: .suiChainIdentifier,
            value: WalletSuiChainIdentity.mainnetBase58
        ),
        nativeAssetID: "sui:mainnet/coin:0x2::sui::SUI", nativeSymbol: "SUI", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://suiscan.xyz/mainnet/tx/{transaction}",
        staticallyReviewedCapabilities: [
            .nativeTransfer, .fungibleTokenTransfer, .nftTransfer,
            .embeddedBrowser, .externalWallet, .walletConnect,
        ]
    )

    static let suiTestnet = WalletNetworkDescriptor(
        canonicalID: "sui:testnet", chain: .sui, environment: .testnet,
        displayName: "Sui Testnet", identity: .init(
            kind: .suiChainIdentifier,
            value: WalletSuiChainIdentity.testnetBase58
        ),
        nativeAssetID: "sui:testnet/coin:0x2::sui::SUI", nativeSymbol: "SUI", nativeDecimals: 9,
        explorerTransactionURLTemplate: "https://suiscan.xyz/testnet/tx/{transaction}",
        staticallyReviewedCapabilities: [
            .nativeTransfer, .fungibleTokenTransfer, .nftTransfer,
            .embeddedBrowser, .externalWallet, .walletConnect,
        ]
    )

    static let all = [
        ethereumMainnet, ethereumSepolia, solanaMainnet, solanaDevnet, suiMainnet, suiTestnet,
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(id: String) -> WalletNetworkDescriptor? { byID[id] }
}
