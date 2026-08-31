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
    "erc20-v1",
    "erc721-safe-transfer-v1",
    "erc1155-safe-transfer-v1",
    "uniswap-universal-router-v2-exact-in-v1",
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
    guard asset.chain == "solana" else { return true }
    if asset.kind == "native" {
        return asset.canonicalID == "\(asset.networkID)/slip44:501"
            && asset.reference == nil && asset.decimals == 9
    }
    guard let mint = asset.reference, isCanonicalSolanaAddress(mint),
          asset.canonicalID == "\(asset.networkID)/spl:\(mint)"
            || asset.canonicalID == "\(asset.networkID)/token2022:\(mint)",
          let decimals = asset.decimals else { return false }
    return asset.kind == "fungible_token" || decimals == 0
}

func isValidReviewManifest(_ manifest: ReviewManifest, now: Date) -> Bool {
    let contractLocations = manifest.evmContracts.map {
        "\($0.networkID):\($0.checksumAddress.lowercased())"
    }
    return manifest.schemaVersion == 1
        && manifest.revision > 0
        && manifest.issuedAt <= now
        && manifest.expiresAt > now
        && manifest.expiresAt > manifest.issuedAt
        && manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60
        && manifest.assets.count <= 10_000
        && manifest.evmContracts.count <= 2_000
        && manifest.explorerTemplates.count <= 5
        && manifest.adapterIDs.isSubset(of: supportedAdapterIDs)
        && Set(manifest.assets.map(\.canonicalID)).count == manifest.assets.count
        && Set(manifest.evmContracts.map(\.id)).count == manifest.evmContracts.count
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
