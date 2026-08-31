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

    var assets: [WalletAsset] { manifest.assets }
    var evmContracts: [WalletContractRegistryEntry] { manifest.evmContracts }

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
        return WalletReviewRegistry(manifest: WalletReviewManifest(
            schemaVersion: manifest.schemaVersion,
            revision: restriction.revision,
            issuedAt: max(manifest.issuedAt, restriction.issuedAt),
            expiresAt: min(manifest.expiresAt, restriction.expiresAt),
            assets: assets, evmContracts: contracts,
            explorerTemplates: explorers, adapterIDs: adapters
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

    private static func isStructurallyValid(
        _ manifest: WalletReviewManifest,
        now: Date
    ) -> Bool {
        guard manifest.schemaVersion == 1, manifest.revision > 0,
              manifest.issuedAt <= now,
              manifest.expiresAt > manifest.issuedAt,
              manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60,
              manifest.assets.count <= 10_000,
              manifest.evmContracts.count <= 2_000,
              manifest.explorerTemplates.count <= WalletNetworkCatalog.all.count,
              manifest.adapterIDs.isSubset(of: WalletReviewedAdapters.staticallySupportedIDs),
              Set(manifest.assets.map(\.id)).count == manifest.assets.count,
              Set(manifest.evmContracts.map(\.id)).count == manifest.evmContracts.count,
              Set(manifest.evmContracts.map {
                  "\($0.networkID):\($0.checksumAddress.lowercased())"
              }).count == manifest.evmContracts.count,
              manifest.assets.allSatisfy({ validAsset($0, revision: manifest.revision) }),
              manifest.evmContracts.allSatisfy({ entry in
                  validContract(entry, manifest: manifest)
              }) else { return false }
        return manifest.explorerTemplates.allSatisfy { networkID, template in
            WalletNetworkCatalog.descriptor(id: networkID)?.explorerTransactionURLTemplate
                == template
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
        staticallyReviewedCapabilities: [
            .nativeTransfer, .fungibleTokenTransfer, .autonomousPolicy,
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
        ]
    )

    static let all = [
        ethereumMainnet, ethereumSepolia, solanaMainnet, solanaDevnet, suiMainnet, suiTestnet,
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(id: String) -> WalletNetworkDescriptor? { byID[id] }
}
