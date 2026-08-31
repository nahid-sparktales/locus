#!/usr/bin/env swift

import CryptoKit
import Foundation

struct CapabilityManifest: Codable {
    let schemaVersion: Int
    let revision: Int
    let releaseStage: String
    let evidenceIndexSHA256: String
    let issuedAt: Date
    let expiresAt: Date
    let enabledNetworkIDs: Set<String>
    let enabledCapabilities: Set<String>
    let approvedRegions: Set<String>
    let completedApprovals: Set<String>
}

struct LaunchEvidenceIndex: Codable {
    let schemaVersion: Int
    let releaseRevision: Int
    let approvals: [LaunchApprovalEvidence]
}

struct LaunchApprovalEvidence: Codable {
    let approval: String
    let status: String
    let reviewer: String
    let organization: String
    let completedAt: Date
    let artifactPath: String
    let artifactSHA256: String
    let approvedRegions: Set<String>?
    let unresolvedCritical: Int?
    let unresolvedHigh: Int?
    let metrics: [String: Int]?
}

struct SignedCapabilityManifest: Codable {
    let manifest: CapabilityManifest
    let signatureBase64: String
}

let canaryApprovals: Set<String> = [
    "signer_audit",
    "application_penetration_test",
    "legal_regional_matrix",
    "provider_failover_load_test",
    "incident_drill",
    "notarized_artifact",
    "signed_update_feed",
]
let gaApprovals = canaryApprovals.union(["release_candidate_soak"])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 5 else {
    fail("usage: SignWalletCapabilityManifest.swift manifest.json evidence-index.json private-key.base64 signed-output.json")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[2])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[3])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[4])

do {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(CapabilityManifest.self, from: Data(contentsOf: inputURL))
    guard manifest.schemaVersion == 2, manifest.revision > 0 else {
        fail("schemaVersion must be 2 and revision must be positive")
    }
    guard ["invited_canary", "general_availability"].contains(manifest.releaseStage) else {
        fail("releaseStage must be invited_canary or general_availability")
    }
    guard manifest.issuedAt <= Date(), manifest.expiresAt > Date(),
          manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60 else {
        fail("the manifest must be current and valid for no more than 31 days")
    }
    let requiredApprovals = manifest.releaseStage == "general_availability"
        ? gaApprovals : canaryApprovals
    let missing = requiredApprovals.subtracting(manifest.completedApprovals)
    guard missing.isEmpty else {
        fail("\(manifest.releaseStage) approvals are incomplete: \(missing.sorted().joined(separator: ", "))")
    }
    guard manifest.completedApprovals.isSubset(of: gaApprovals) else {
        fail("completedApprovals contains an unknown approval")
    }

    let evidenceData = try Data(contentsOf: evidenceURL)
    let evidenceHash = SHA256.hash(data: evidenceData).map { String(format: "%02x", $0) }.joined()
    guard manifest.evidenceIndexSHA256 == evidenceHash else {
        fail("evidenceIndexSHA256 does not match the supplied evidence index")
    }
    let evidence = try decoder.decode(LaunchEvidenceIndex.self, from: evidenceData)
    guard evidence.schemaVersion == 1, evidence.releaseRevision == manifest.revision else {
        fail("the evidence index schema or release revision does not match the manifest")
    }
    let grouped = Dictionary(grouping: evidence.approvals, by: \.approval)
    guard grouped.values.allSatisfy({ $0.count == 1 }) else {
        fail("the evidence index contains duplicate approval records")
    }
    let evidenceRoot = evidenceURL.deletingLastPathComponent().standardizedFileURL
    for approval in requiredApprovals.sorted() {
        guard let item = grouped[approval]?.first,
              item.status == "passed",
              !item.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.completedAt <= Date() else {
            fail("approval \(approval) has no complete, attributable evidence")
        }
        let artifact = evidenceRoot.appendingPathComponent(item.artifactPath).standardizedFileURL
        let rootPath = evidenceRoot.path.hasSuffix("/") ? evidenceRoot.path : evidenceRoot.path + "/"
        guard artifact.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: artifact.path) else {
            fail("approval \(approval) references a missing or out-of-directory artifact")
        }
        let artifactData = try Data(contentsOf: artifact)
        let artifactHash = SHA256.hash(data: artifactData)
            .map { String(format: "%02x", $0) }.joined()
        guard artifactHash == item.artifactSHA256.lowercased() else {
            fail("approval \(approval) artifact hash does not match")
        }
        if ["signer_audit", "application_penetration_test"].contains(approval) {
            guard item.unresolvedCritical == 0, item.unresolvedHigh == 0 else {
                fail("approval \(approval) still has unresolved critical or high findings")
            }
        }
        if approval == "legal_regional_matrix" {
            let regions = item.approvedRegions ?? []
            guard !manifest.approvedRegions.isEmpty,
                  manifest.approvedRegions.isSubset(of: regions) else {
                fail("the legal evidence does not approve every manifest region")
            }
        }
        if approval == "release_candidate_soak" {
            let metrics = item.metrics ?? [:]
            guard metrics["duration_days", default: 0] >= 30,
                  metrics["external_testers", default: 0] >= 25,
                  metrics["ethereum_successful_transactions", default: 0] >= 100,
                  metrics["solana_successful_transactions", default: 0] >= 100,
                  metrics["sui_successful_transactions", default: 0] >= 100,
                  metrics["unauthorized_signing", default: 1] == 0,
                  metrics["secret_exposure", default: 1] == 0,
                  metrics["unrecoverable_vaults", default: 1] == 0,
                  metrics["unresolved_broadcast_ambiguity", default: 1] == 0,
                  metrics["loss_producing_decoder_discrepancy", default: 1] == 0 else {
                fail("the release-candidate soak does not meet the GA thresholds")
            }
        }
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
