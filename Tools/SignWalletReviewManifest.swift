#!/usr/bin/env swift

import CryptoKit
import Foundation

struct ReviewManifest: Codable {
    let schemaVersion: Int
    let revision: Int
    let issuedAt: Date
    let expiresAt: Date
    let assets: [ReviewAsset]
    let evmContracts: [ReviewContract]
    let explorerTemplates: [String: String]
    let adapterIDs: Set<String>
    let connectors: [ReviewConnector]
    let signInAdapters: [ReviewSignInAdapter]
    let programIdentities: [ReviewProgramIdentity]
    let uniswapConfigurations: [ReviewUniswapConfiguration]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, issuedAt, expiresAt, assets, evmContracts
        case explorerTemplates, adapterIDs, connectors, signInAdapters
        case programIdentities, uniswapConfigurations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        assets = try container.decode([ReviewAsset].self, forKey: .assets)
        evmContracts = try container.decode([ReviewContract].self, forKey: .evmContracts)
        explorerTemplates = try container.decode(
            [String: String].self, forKey: .explorerTemplates
        )
        adapterIDs = try container.decode(Set<String>.self, forKey: .adapterIDs)
        connectors = try container.decodeIfPresent(
            [ReviewConnector].self, forKey: .connectors
        ) ?? []
        signInAdapters = try container.decodeIfPresent(
            [ReviewSignInAdapter].self, forKey: .signInAdapters
        ) ?? []
        programIdentities = try container.decodeIfPresent(
            [ReviewProgramIdentity].self, forKey: .programIdentities
        ) ?? []
        uniswapConfigurations = try container.decodeIfPresent(
            [ReviewUniswapConfiguration].self, forKey: .uniswapConfigurations
        ) ?? []
    }
}

struct ReviewConnector: Codable {
    let connector: String
    let version: String
    let artifactSHA256: String
    let directions: Set<String>
    let methods: Set<String>
}

struct ReviewSignInAdapter: Codable {
    let format: String
    let version: String
    let implementationSHA256: String
    let networkIDs: Set<String>
}

struct ReviewProgramIdentity: Codable {
    let networkID: String
    let kind: String
    let identifier: String
    let codeSHA256: String
}

struct ReviewUniswapConfiguration: Codable {
    let networkID: String
    let universalRouterContractID: String
    let permit2ContractID: String
    let contracts: [ReviewUniswapContract]
    let pools: [ReviewUniswapPool]
    let allowedIntermediaryAssetIDs: Set<String>
    let allowedFeeTiers: Set<UInt32>
    let maximumHops: Int
    let zeroFirstApprovalAssetIDs: Set<String>
}

struct ReviewUniswapContract: Codable {
    let role: String
    let address: String
    let runtimeCodeHash: String
}

struct ReviewUniswapPool: Codable {
    let protocolVersion: String
    let address: String
    let runtimeCodeHash: String
    let token0AssetID: String
    let token1AssetID: String
    let feeTier: UInt32?
}

struct ReviewAsset: Codable {
    let canonicalID: String
    let networkID: String
    let chain: String
    let kind: String
    let reference: String?
    let name: String
    let symbol: String
    let decimals: Int?
    let trust: String
    let manifestRevision: Int
}

struct ReviewContract: Codable {
    let id: String
    let networkID: String
    let checksumAddress: String
    let label: String
    let normalizedABI: String
    let abiDigest: String
    let runtimeCodeHash: String
    let permittedFunctions: [String]
    let permittedSelectors: [String]
    let reviewedAdapterID: String?
    let verifiedAt: Date
}

struct SignedReviewManifest: Codable {
    let manifest: ReviewManifest
    let signatureBase64: String
}

let supportedAdapterIDs: Set<String> = [
    "native-eth-transfer-v1",
    "solana-system-transfer-v1",
    "solana-spl-transfer-checked-v1",
    "solana-token-2022-transfer-checked-v1",
    "solana-associated-token-create-idempotent-v1",
    "solana-mpl-core-transfer-v1",
    "sui-native-transfer-v1",
    "sui-coin-transfer-v1",
    "sui-object-transfer-v1",
    "erc20-v1",
    "erc721-safe-transfer-v1",
    "erc1155-safe-transfer-v1",
    "uniswap-universal-router-v2-exact-in-v1",
    "uniswap-universal-router-v2-v3-exact-in-v2",
    "uniswap-permit2-allowance-setup-v1",
]

func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func isHex(_ value: Substring) -> Bool {
    value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

func isValidVersion(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || [45, 46, 95].contains($0)
    }
}

func isValidEVMAddress(_ value: String) -> Bool {
    value.count == 42 && value.hasPrefix("0x") && isHex(value.dropFirst(2))
}

func isValidRuntimeCodeHash(_ value: String) -> Bool {
    value.count == 66 && value.hasPrefix("0x") && isHex(value.dropFirst(2))
}

func erc20Address(assetID: String, networkID: String) -> String? {
    let prefix = "\(networkID)/erc20:"
    guard assetID.hasPrefix(prefix) else { return nil }
    let address = String(assetID.dropFirst(prefix.count)).lowercased()
    return isValidEVMAddress(address) ? address : nil
}

func isValidUniswapConfiguration(
    _ configuration: ReviewUniswapConfiguration,
    manifest: ReviewManifest
) -> Bool {
    let roles: Set<String> = [
        "v2_router", "v2_factory", "v3_factory", "v3_quoter_v2",
        "universal_router", "permit2",
    ]
    guard ["eip155:1", "eip155:11155111"].contains(configuration.networkID),
          (1...3).contains(configuration.maximumHops),
          configuration.contracts.count == roles.count,
          Set(configuration.contracts.map(\.role)) == roles,
          !configuration.pools.isEmpty, configuration.pools.count <= 512,
          Set(configuration.pools.map {
              "\($0.protocolVersion):\($0.address.lowercased())"
          }).count == configuration.pools.count,
          configuration.allowedFeeTiers.count <= 16,
          configuration.allowedFeeTiers.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }),
          let routerEntry = manifest.evmContracts.first(where: {
              $0.id == configuration.universalRouterContractID
                  && $0.networkID == configuration.networkID
          }),
          routerEntry.reviewedAdapterID
            == "uniswap-universal-router-v2-v3-exact-in-v2",
          let reviewedRouter = configuration.contracts.first(where: {
              $0.role == "universal_router"
          }),
          reviewedRouter.address.caseInsensitiveCompare(routerEntry.checksumAddress)
            == .orderedSame,
          reviewedRouter.runtimeCodeHash.caseInsensitiveCompare(routerEntry.runtimeCodeHash)
            == .orderedSame,
          let permit2Entry = manifest.evmContracts.first(where: {
              $0.id == configuration.permit2ContractID
                  && $0.networkID == configuration.networkID
          }),
          permit2Entry.reviewedAdapterID == "uniswap-permit2-allowance-setup-v1",
          let reviewedPermit2 = configuration.contracts.first(where: {
              $0.role == "permit2"
          }),
          reviewedPermit2.address.caseInsensitiveCompare(permit2Entry.checksumAddress)
            == .orderedSame,
          reviewedPermit2.runtimeCodeHash.caseInsensitiveCompare(permit2Entry.runtimeCodeHash)
            == .orderedSame,
          configuration.contracts.allSatisfy({
              roles.contains($0.role) && isValidEVMAddress($0.address)
                  && isValidRuntimeCodeHash($0.runtimeCodeHash)
          }),
          Set(configuration.contracts.map { $0.address.lowercased() }).count
            == configuration.contracts.count else { return false }

    let assetIDs = Set(manifest.assets.filter {
        $0.networkID == configuration.networkID && $0.chain == "evm"
            && $0.kind == "fungible_token" && $0.trust == "curated"
    }.map(\.canonicalID))
    let poolAssetIDs = Set(configuration.pools.flatMap {
        [$0.token0AssetID, $0.token1AssetID]
    })
    let reviewedTokenAssetIDs = Set(poolAssetIDs.compactMap { assetID -> String? in
        guard assetIDs.contains(assetID),
              let address = erc20Address(
                assetID: assetID, networkID: configuration.networkID
              ),
              manifest.evmContracts.contains(where: {
                  $0.networkID == configuration.networkID
                      && $0.checksumAddress.caseInsensitiveCompare(address) == .orderedSame
                      && $0.reviewedAdapterID == "erc20-v1"
              }) else { return nil }
        return assetID
    })
    guard manifest.adapterIDs.contains("erc20-v1"),
          poolAssetIDs.isSubset(of: reviewedTokenAssetIDs),
          configuration.allowedIntermediaryAssetIDs.isSubset(of: poolAssetIDs),
          configuration.zeroFirstApprovalAssetIDs.isSubset(of: poolAssetIDs) else {
        return false
    }
    return configuration.pools.allSatisfy { pool in
        guard ["v2", "v3"].contains(pool.protocolVersion),
              isValidEVMAddress(pool.address),
              isValidRuntimeCodeHash(pool.runtimeCodeHash),
              pool.token0AssetID != pool.token1AssetID,
              poolAssetIDs.contains(pool.token0AssetID),
              poolAssetIDs.contains(pool.token1AssetID) else { return false }
        return pool.protocolVersion == "v2"
            ? pool.feeTier == nil
            : pool.feeTier.map(configuration.allowedFeeTiers.contains) == true
    }
}

let solanaBase58Alphabet = Array(
    "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8
)
let solanaBase58Positions = Dictionary(
    uniqueKeysWithValues: solanaBase58Alphabet.enumerated().map {
        ($0.element, $0.offset)
    }
)

func encodeBase58(_ value: [UInt8]) -> String {
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
    return String(repeating: "1", count: leadingZeroCount) + String(
        digits.reversed().map {
            Character(UnicodeScalar(solanaBase58Alphabet[Int($0)]))
        }
    )
}

func isCanonicalSolanaAddress(_ value: String) -> Bool {
    let encoded = Array(value.utf8)
    guard !encoded.isEmpty, encoded.count <= 128 else { return false }
    var littleEndian: [UInt8] = []
    for character in encoded {
        guard var carry = solanaBase58Positions[character] else { return false }
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
    let leadingZeroCount = encoded.prefix { $0 == solanaBase58Alphabet[0] }.count
    let decoded = Array(repeating: UInt8(0), count: leadingZeroCount)
        + littleEndian.reversed()
    return decoded.count == 32 && encodeBase58(Array(decoded)) == value
}

func isCanonicalSuiCoinType(_ value: String) -> Bool {
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
          hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        return false
    }
    return components.dropFirst().allSatisfy { component in
        guard let first = component.utf8.first,
              first == 95 || (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return component.utf8.dropFirst().allSatisfy {
            $0 == 95 || (48...57).contains($0)
                || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}

func isCanonicalSuiAddress(_ value: String) -> Bool {
    value.count == 66 && value.hasPrefix("0x")
        && value == value.lowercased()
        && value.utf8.dropFirst(2).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
}

func isValidReviewAsset(_ asset: ReviewAsset, revision: Int) -> Bool {
    guard !asset.canonicalID.isEmpty,
          !asset.networkID.isEmpty,
          ["evm", "solana", "sui"].contains(asset.chain),
          ["native", "fungible_token", "nft", "collectible"].contains(asset.kind),
          !asset.name.isEmpty, asset.name.count <= 128,
          !asset.symbol.isEmpty, asset.symbol.count <= 32,
          asset.decimals.map({ (0...255).contains($0) }) != false,
          asset.trust == "curated", asset.manifestRevision == revision else {
        return false
    }
    if asset.chain == "solana" {
        if asset.kind == "native" {
            return asset.canonicalID == "\(asset.networkID)/slip44:501"
                && asset.reference == nil && asset.decimals == 9
        }
        if asset.kind == "nft" || asset.kind == "collectible" {
            guard let address = asset.reference,
                  isCanonicalSolanaAddress(address),
                  asset.canonicalID == "\(asset.networkID)/nft:core:\(address)",
                  asset.decimals == nil || asset.decimals == 0 else {
                return false
            }
            return true
        }
        guard let mint = asset.reference, isCanonicalSolanaAddress(mint),
              asset.canonicalID == "\(asset.networkID)/spl:\(mint)"
                || asset.canonicalID == "\(asset.networkID)/token2022:\(mint)",
              let decimals = asset.decimals else { return false }
        return asset.kind == "fungible_token" || decimals == 0
    }
    guard asset.chain == "sui" else { return true }
    let nativeType = "0x2::sui::SUI"
    if asset.kind == "native" {
        return asset.canonicalID == "\(asset.networkID)/coin:\(nativeType)"
            && asset.reference == nil && asset.decimals == 9
    }
    if asset.kind == "nft" || asset.kind == "collectible" {
        guard let objectID = asset.reference else { return false }
        return isCanonicalSuiAddress(objectID)
            && asset.canonicalID == "\(asset.networkID)/object:\(objectID)"
            && (asset.decimals == nil || asset.decimals == 0)
    }
    guard let coinType = asset.reference,
          coinType != nativeType,
          isCanonicalSuiCoinType(coinType),
          asset.canonicalID == "\(asset.networkID)/coin:\(coinType)",
          asset.kind == "fungible_token",
          let decimals = asset.decimals, (0...255).contains(decimals) else {
        return false
    }
    return true
}

func isValidReviewManifest(_ manifest: ReviewManifest, now: Date) -> Bool {
    let contractLocations = manifest.evmContracts.map {
        "\($0.networkID):\($0.checksumAddress.lowercased())"
    }
    let knownConnectors: Set<String> = [
        "metamask", "phantom", "slush", "embedded_browser", "wallet_connect",
    ]
    let knownDirections: Set<String> = [
        "external_account_to_locus", "locus_vault_to_dapp",
    ]
    let knownMethods: Set<String> = [
        "list_accounts", "switch_network", "send_transaction",
        "sign_in_with_ethereum", "sign_in_with_solana",
    ]
    let knownNetworks: [String: String] = [
        "eip155:1": "evm", "eip155:11155111": "evm",
        "solana:mainnet-beta": "solana", "solana:devnet": "solana",
        "sui:mainnet": "sui", "sui:testnet": "sui",
    ]
    return manifest.schemaVersion == 2
        && manifest.revision > 0
        && manifest.issuedAt <= now
        && manifest.expiresAt > now
        && manifest.expiresAt > manifest.issuedAt
        && manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60
        && manifest.assets.count <= 10_000
        && manifest.evmContracts.count <= 2_000
        && manifest.connectors.count <= knownConnectors.count
        && manifest.signInAdapters.count <= 8
        && manifest.programIdentities.count <= 256
        && manifest.uniswapConfigurations.count <= 8
        && manifest.explorerTemplates.count <= 5
        && manifest.adapterIDs.isSubset(of: supportedAdapterIDs)
        && Set(manifest.assets.map(\.canonicalID)).count == manifest.assets.count
        && Set(manifest.evmContracts.map(\.id)).count == manifest.evmContracts.count
        && Set(manifest.connectors.map(\.connector)).count == manifest.connectors.count
        && Set(manifest.signInAdapters.map {
            "\($0.format):\($0.networkIDs.sorted().joined(separator: ","))"
        }).count == manifest.signInAdapters.count
        && Set(manifest.programIdentities.map {
            "\($0.networkID):\($0.kind):\($0.identifier)"
        }).count == manifest.programIdentities.count
        && Set(manifest.uniswapConfigurations.map {
            "\($0.networkID):\($0.universalRouterContractID)"
        }).count == manifest.uniswapConfigurations.count
        && Set(contractLocations).count == contractLocations.count
        && manifest.assets.allSatisfy {
            isValidReviewAsset($0, revision: manifest.revision)
        }
        && manifest.evmContracts.allSatisfy {
            !$0.id.isEmpty && $0.id.count <= 128
                && $0.checksumAddress.count == 42
                && $0.checksumAddress.hasPrefix("0x")
                && isHex($0.checksumAddress.dropFirst(2))
                && !$0.label.isEmpty && $0.label.count <= 128
                && !$0.normalizedABI.isEmpty && $0.normalizedABI.utf8.count <= 256 * 1024
                && $0.abiDigest.count == 71 && $0.abiDigest.hasPrefix("sha256:")
                && isHex($0.abiDigest.dropFirst(7))
                && $0.runtimeCodeHash.count == 66 && $0.runtimeCodeHash.hasPrefix("0x")
                && isHex($0.runtimeCodeHash.dropFirst(2))
                && $0.permittedFunctions.count == $0.permittedSelectors.count
                && !$0.permittedFunctions.isEmpty
                && $0.permittedSelectors.allSatisfy {
                    $0.count == 10 && $0.hasPrefix("0x") && isHex($0.dropFirst(2))
                }
                && $0.reviewedAdapterID.map(manifest.adapterIDs.contains) == true
                && $0.verifiedAt <= manifest.issuedAt
        }
        && manifest.connectors.allSatisfy { connector in
            guard knownConnectors.contains(connector.connector),
                  isValidVersion(connector.version),
                  isLowercaseSHA256(connector.artifactSHA256),
                  !connector.directions.isEmpty,
                  connector.directions.isSubset(of: knownDirections),
                  !connector.methods.isEmpty,
                  connector.methods.isSubset(of: knownMethods) else {
                return false
            }
            switch connector.connector {
            case "metamask":
                return connector.directions == ["external_account_to_locus"]
                    && connector.methods.isSubset(of: [
                        "list_accounts", "switch_network", "send_transaction",
                        "sign_in_with_ethereum",
                    ])
            case "phantom":
                return connector.directions == ["external_account_to_locus"]
                    && connector.methods.isSubset(of: [
                        "list_accounts", "switch_network", "send_transaction",
                        "sign_in_with_solana",
                    ])
            case "slush":
                return connector.directions == ["external_account_to_locus"]
                    && connector.methods.isSubset(of: [
                        "list_accounts", "switch_network", "send_transaction",
                    ])
            default:
                return connector.directions == ["locus_vault_to_dapp"]
            }
        }
        && manifest.signInAdapters.allSatisfy { adapter in
            ["siwe", "siws"].contains(adapter.format)
                && isValidVersion(adapter.version)
                && isLowercaseSHA256(adapter.implementationSHA256)
                && !adapter.networkIDs.isEmpty
                && adapter.networkIDs.allSatisfy { networkID in
                    adapter.format == "siwe"
                        ? knownNetworks[networkID] == "evm"
                        : knownNetworks[networkID] == "solana"
                }
        }
        && manifest.programIdentities.allSatisfy { identity in
            guard let chain = knownNetworks[identity.networkID],
                  !identity.identifier.isEmpty,
                  identity.identifier.utf8.count <= 256,
                  isLowercaseSHA256(identity.codeSHA256) else { return false }
            return (identity.kind == "evm_runtime" && chain == "evm")
                || (identity.kind == "solana_program" && chain == "solana")
                || (identity.kind == "sui_package" && chain == "sui")
        }
        && manifest.uniswapConfigurations.allSatisfy {
            isValidUniswapConfiguration($0, manifest: manifest)
        }
        && (!manifest.adapterIDs.contains(
            "uniswap-universal-router-v2-v3-exact-in-v2"
        ) || !manifest.uniswapConfigurations.isEmpty)
        && manifest.uniswapConfigurations.allSatisfy { _ in
            manifest.adapterIDs.contains(
                "uniswap-universal-router-v2-v3-exact-in-v2"
            )
        }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

do {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--verify" {
        let signedURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let signed = try decoder.decode(
            SignedReviewManifest.self, from: Data(contentsOf: signedURL)
        )
        guard isValidReviewManifest(signed.manifest, now: Date()),
              let keyData = Data(base64Encoded: CommandLine.arguments[3]),
              keyData.count == 32,
              let signature = Data(base64Encoded: signed.signatureBase64) else {
            fail("the signed review manifest, public key, or validity window is invalid")
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        let canonical = try canonicalEncoder().encode(signed.manifest)
        guard publicKey.isValidSignature(signature, for: canonical) else {
            fail("the review manifest signature does not match the embedded public key")
        }
        print("review_manifest_verified")
        exit(0)
    }

    guard CommandLine.arguments.count == 4 else {
        fail("usage: SignWalletReviewManifest.swift manifest.json private-key.base64 signed-output.json\n       SignWalletReviewManifest.swift --verify signed-manifest.json public-key.base64")
    }
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let manifest = try decoder.decode(
        ReviewManifest.self, from: Data(contentsOf: inputURL)
    )
    guard isValidReviewManifest(manifest, now: Date()) else {
        fail("the review manifest schema, validity window, or reviewed entries are invalid")
    }
    let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("the signing key file must contain one base64-encoded 32-byte Ed25519 private key")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let encoder = canonicalEncoder()
    let canonical = try encoder.encode(manifest)
    let signature = try privateKey.signature(for: canonical)
    let output = try encoder.encode(SignedReviewManifest(
        manifest: manifest, signatureBase64: signature.base64EncodedString()
    ))
    try output.write(to: outputURL, options: [.atomic])
    print("public_key_base64=\(privateKey.publicKey.rawRepresentation.base64EncodedString())")
    print("signed_review_manifest_base64=\(output.base64EncodedString())")
} catch {
    fail(error.localizedDescription)
}
