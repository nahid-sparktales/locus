#!/usr/bin/env swift

import CryptoKit
import Foundation

struct CapabilityManifest: Codable {
    let schemaVersion: Int
    let revision: Int
    let issuedAt: Date
    let expiresAt: Date
    let enabledNetworkIDs: Set<String>
    let enabledCapabilities: Set<String>
    let approvedRegions: Set<String>
    let completedApprovals: Set<String>
}

struct SignedCapabilityManifest: Codable {
    let manifest: CapabilityManifest
    let signatureBase64: String
}

let requiredApprovals: Set<String> = [
    "signer_audit",
    "application_penetration_test",
    "legal_regional_matrix",
    "provider_failover_load_test",
    "release_candidate_soak",
    "incident_drill",
    "notarized_artifact",
    "signed_update_feed",
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: SignWalletCapabilityManifest.swift manifest.json private-key.base64 signed-output.json")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

do {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(CapabilityManifest.self, from: Data(contentsOf: inputURL))
    guard manifest.schemaVersion == 1, manifest.revision > 0 else {
        fail("schemaVersion must be 1 and revision must be positive")
    }
    guard manifest.issuedAt <= Date(), manifest.expiresAt > Date(),
          manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60 else {
        fail("the manifest must be current and valid for no more than 31 days")
    }
    let missing = requiredApprovals.subtracting(manifest.completedApprovals)
    guard missing.isEmpty else {
        fail("GA approvals are incomplete: \(missing.sorted().joined(separator: ", "))")
    }
    let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("the signing key file must contain one base64-encoded 32-byte Ed25519 private key")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonical = try encoder.encode(manifest)
    let signature = try privateKey.signature(for: canonical)
    let signed = SignedCapabilityManifest(
        manifest: manifest,
        signatureBase64: signature.base64EncodedString()
    )
    let output = try encoder.encode(signed)
    try output.write(to: outputURL, options: [.atomic])
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    print("public_key_base64=\(publicKey)")
    print("signed_manifest_base64=\(output.base64EncodedString())")
} catch {
    fail(error.localizedDescription)
}
