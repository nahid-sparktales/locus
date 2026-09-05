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
    let networkGrants: [NetworkGrant]
    let approvedRegions: Set<String>
    let completedApprovals: Set<String>
    var canaryLimits: [CanaryLimit]? = nil
}

extension CapabilityManifest {
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
        try values.encode(completedApprovals.sorted(), forKey: .completedApprovals)
        try values.encodeIfPresent(canaryLimits, forKey: .canaryLimits)
    }
}


struct NetworkGrant: Codable {
    let networkID: String
    let capabilities: Set<String>
    let connectors: [ConnectorGrant]
}

struct CanaryLimit: Codable {
    let networkID: String
    let assetID: String
    let action: String
    let ownership: String
    let connector: String?
    let maximumTransactionBaseUnits: String
    let maximumCumulativeBaseUnits: String
    let maximumFeeBaseUnits: String
    let maximumCumulativeFeeBaseUnits: String
    let maximumTransactions: Int
}

extension NetworkGrant {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(networkID, forKey: .networkID)
        try values.encode(capabilities.sorted(), forKey: .capabilities)
        try values.encode(connectors, forKey: .connectors)
    }
}


struct ConnectorGrant: Codable {
    let connector: String
    let ownership: String
    let directions: Set<String>
    let methods: Set<String>
}

extension ConnectorGrant {
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(connector, forKey: .connector)
        try values.encode(ownership, forKey: .ownership)
        try values.encode(directions.sorted(), forKey: .directions)
        try values.encode(methods.sorted(), forKey: .methods)
    }
}


struct LaunchEvidenceIndex: Codable {
    let schemaVersion: Int
    let releaseRevision: Int
    let sourceRevision: String
    let phase: String
    let artifactIdentity: ReleaseArtifactIdentity
    let approvals: [LaunchApprovalEvidence]
    let chainTotals: [ChainTransactionTotal]
    let actionCoverage: [ActionCoverageEvidence]
    let connectionCoverage: [ConnectionCoverageEvidence]
}

struct ReleaseArtifactIdentity: Codable {
    let bundleVersion: String
    let outerAppCodeDirectoryHash: String
    let signerCodeDirectoryHash: String
    let archiveSHA256: String
}

struct ChainTransactionTotal: Codable {
    let chain: String
    let successfulTransactions: Int
}

struct ActionCoverageEvidence: Codable {
    let networkID: String
    let action: String
    let successfulOperations: Int
    let successfulTransactions: Int
}

struct ConnectionCoverageEvidence: Codable {
    let networkID: String
    let connector: String
    let direction: String
    let method: String
    let successfulOperations: Int
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
    "derivation_reproduction",
    "release_candidate_build",
]
let gaApprovals = canaryApprovals.union([
    "release_candidate_soak", "publication_disclosures", "support_security_readiness",
])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 5 else {
    fail("usage: SignWalletCapabilityManifest.swift manifest.json evidence-index.json private-key.base64 signed-output.json")
}

let verifying = CommandLine.arguments[1] == "--verify"
let inputURL = URL(fileURLWithPath: CommandLine.arguments[verifying ? 2 : 1])
let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[verifying ? 3 : 2])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[3])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[4])

// Counts are observations, not operator-entered metrics. Recompute the
// hash-linked ledger independently before reading any signing-key bytes.
func verifyRecordedEvidence() throws {
    let verifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("WalletLaunchEvidence.py")
    guard FileManager.default.fileExists(atPath: verifier.path) else {
        fail("the checked-in wallet evidence verifier is missing")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", verifier.path, "verify", evidenceURL.path, inputURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("recorded release evidence failed independent recomputation")
    }
}

do {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let inputData = try Data(contentsOf: inputURL)
    guard inputData.count <= 1_048_576 else { fail("capability input is oversized") }
    let signedInput = verifying ? try decoder.decode(SignedCapabilityManifest.self, from: inputData) : nil
    let manifest = try signedInput?.manifest ?? decoder.decode(CapabilityManifest.self, from: inputData)
    let evidenceData = try Data(contentsOf: evidenceURL)
    guard evidenceData.count <= 16 * 1_048_576 else { fail("evidence index is oversized") }
    let evidence = try decoder.decode(LaunchEvidenceIndex.self, from: evidenceData)
    let limits = manifest.canaryLimits ?? []
    guard limits.count <= 10_000 else { fail("too many canary limits") }
    var limitIDs = Set<String>()
    for limit in limits {
        let amounts = [limit.maximumTransactionBaseUnits, limit.maximumCumulativeBaseUnits,
                       limit.maximumFeeBaseUnits, limit.maximumCumulativeFeeBaseUnits]
        let identity = [limit.networkID, limit.assetID, limit.action, limit.ownership,
                        limit.connector ?? "vault"].joined(separator: "|")
        let expectedOwnership = ["metamask": "external", "slush": "external",
                                 "phantom": "connector_managed"]
        guard limitIDs.insert(identity).inserted, !limit.assetID.isEmpty,
              limit.assetID.utf8.count <= 512,
              ["native_transfer", "fungible_token_transfer", "nft_transfer",
               "exact_input_swap", "swap_allowance_setup"].contains(limit.action),
              (1...1_000_000).contains(limit.maximumTransactions),
              (limit.ownership == "locus_vault" && limit.connector == nil)
                || expectedOwnership[limit.connector ?? ""] == limit.ownership,
              amounts.allSatisfy({ !$0.isEmpty && $0.count <= 78 && $0.first != "0"
                  && $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
            fail("canary limit must bind an exact ownership, action, asset and finite budget")
        }
        func lessOrEqual(_ a: String, _ b: String) -> Bool {
            a.count == b.count ? a <= b : a.count < b.count
        }
        guard lessOrEqual(limit.maximumTransactionBaseUnits, limit.maximumCumulativeBaseUnits),
              lessOrEqual(limit.maximumFeeBaseUnits, limit.maximumCumulativeFeeBaseUnits) else {
            fail("canary per-transaction limits exceed cumulative limits")
        }
    }
    if manifest.releaseStage == "invited_canary" {
        for grant in manifest.networkGrants where
            ["eip155:1", "solana:mainnet-beta", "sui:mainnet"].contains(grant.networkID) {
            guard limits.contains(where: { $0.networkID == grant.networkID }) else {
                fail("each canary mainnet requires signed finite asset/action limits")
            }
        }
    }
    guard manifest.schemaVersion == 3, manifest.revision > 0 else {
        fail("schemaVersion must be 3 and revision must be positive")
    }
    guard ["invited_canary", "general_availability"].contains(manifest.releaseStage) else {
        fail("releaseStage must be invited_canary or general_availability")
    }
    guard manifest.issuedAt <= Date(), manifest.expiresAt > Date(),
          manifest.expiresAt.timeIntervalSince(manifest.issuedAt) <= 31 * 24 * 60 * 60 else {
        fail("the manifest must be current and valid for no more than 31 days")
    }
    let requiredApprovals: Set<String> = evidence.phase == "testnet_rehearsal_authorization"
        ? ["release_candidate_build"]
        : (manifest.releaseStage == "general_availability" ? gaApprovals : canaryApprovals)
    let missing = requiredApprovals.subtracting(manifest.completedApprovals)
    guard missing.isEmpty else {
        fail("\(manifest.releaseStage) approvals are incomplete: \(missing.sorted().joined(separator: ", "))")
    }
    guard manifest.completedApprovals.isSubset(of: gaApprovals) else {
        fail("completedApprovals contains an unknown approval")
    }
    if evidence.phase == "testnet_rehearsal_authorization",
       manifest.completedApprovals != requiredApprovals {
        fail("rehearsal authorization must not claim unperformed release approvals")
    }
    let knownNetworks: Set<String> = [
        "eip155:1", "eip155:11155111", "solana:mainnet-beta",
        "solana:devnet", "sui:mainnet", "sui:testnet",
    ]
    let knownCapabilities: Set<String> = [
        "native_transfer", "fungible_token_transfer", "nft_transfer",
        "exact_input_swap", "reviewed_call", "embedded_browser",
        "external_wallet", "wallet_connect", "autonomous_policy",
        "standardized_sign_in",
    ]
    let knownConnectors: Set<String> = [
        "metamask", "phantom", "slush", "embedded_browser", "wallet_connect",
    ]
    let knownDirections: Set<String> = [
        "external_account_to_locus", "locus_vault_to_dapp",
    ]
    let requiredOwnership: [String: String] = [
        "metamask": "external", "phantom": "connector_managed",
        "slush": "external", "embedded_browser": "locus_vault",
        "wallet_connect": "locus_vault",
    ]
    let knownMethods: Set<String> = [
        "list_accounts", "switch_network", "send_transaction",
        "sign_in_with_ethereum", "sign_in_with_solana",
    ]
    let networkChains: [String: String] = [
        "eip155:1": "evm", "eip155:11155111": "evm",
        "solana:mainnet-beta": "solana", "solana:devnet": "solana",
        "sui:mainnet": "sui", "sui:testnet": "sui",
    ]
    guard !manifest.networkGrants.isEmpty,
          Set(manifest.networkGrants.map(\.networkID)).count
            == manifest.networkGrants.count else {
        fail("networkGrants must contain unique per-network entries")
    }
    for grant in manifest.networkGrants {
        guard knownNetworks.contains(grant.networkID), !grant.capabilities.isEmpty,
              grant.capabilities.isSubset(of: knownCapabilities),
              Set(grant.connectors.map(\.connector)).count == grant.connectors.count else {
            fail("network grant \(grant.networkID) is malformed")
        }
        for connector in grant.connectors {
            guard knownConnectors.contains(connector.connector),
                  connector.ownership == requiredOwnership[connector.connector],
                  !connector.directions.isEmpty,
                  connector.directions.isSubset(of: knownDirections),
                  !connector.methods.isEmpty,
                  connector.methods.isSubset(of: knownMethods) else {
                fail("connector grant \(connector.connector) is malformed")
            }
            let requiredDirection = ["metamask", "phantom", "slush"].contains(
                connector.connector
            ) ? "external_account_to_locus" : "locus_vault_to_dapp"
            guard connector.directions == [requiredDirection] else {
                fail("connector grant \(connector.connector) has the wrong direction")
            }
            let requiredCapability = switch connector.connector {
            case "metamask", "phantom", "slush": "external_wallet"
            case "embedded_browser": "embedded_browser"
            default: "wallet_connect"
            }
            guard grant.capabilities.contains(requiredCapability),
                  let chain = networkChains[grant.networkID] else {
                fail("connector grant \(connector.connector) lacks its network capability")
            }
            let chainMethods: Set<String> = switch chain {
            case "evm": [
                "list_accounts", "switch_network", "send_transaction",
                "sign_in_with_ethereum",
            ]
            case "solana": [
                "list_accounts", "switch_network", "send_transaction",
                "sign_in_with_solana",
            ]
            default: ["list_accounts", "switch_network", "send_transaction"]
            }
            guard connector.methods.isSubset(of: chainMethods) else {
                fail("connector grant \(connector.connector) contains a cross-chain method")
            }
            if connector.connector == "metamask", chain != "evm" {
                fail("MetaMask is enabled only for reviewed EVM networks")
            }
            if connector.connector == "slush", chain != "sui" {
                fail("Slush is enabled only for reviewed Sui networks")
            }
            if connector.connector == "phantom", chain != "solana" {
                fail("Phantom embedded user wallets are enabled only for reviewed Solana networks")
            }
        }
    }

    try verifyRecordedEvidence()
    let evidenceHash = SHA256.hash(data: evidenceData).map { String(format: "%02x", $0) }.joined()
    guard manifest.evidenceIndexSHA256 == evidenceHash else {
        fail("evidenceIndexSHA256 does not match the supplied evidence index")
    }
    let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
    func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }
    func validCDHash(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy(lowercaseHex.contains)
    }
    guard evidence.schemaVersion == 2,
          evidence.releaseRevision == manifest.revision,
          (40...64).contains(evidence.sourceRevision.count),
          evidence.sourceRevision.unicodeScalars.allSatisfy(lowercaseHex.contains),
          !evidence.artifactIdentity.bundleVersion.isEmpty,
          validCDHash(evidence.artifactIdentity.outerAppCodeDirectoryHash),
          validCDHash(evidence.artifactIdentity.signerCodeDirectoryHash),
          validSHA256(evidence.artifactIdentity.archiveSHA256) else {
        fail("the evidence index schema or release revision does not match the manifest")
    }
    // The verifier enforces unique records before constructing any dictionary,
    // maps initial mainnet scope to explicit testnet rehearsal observations,
    // and counts sign-in/account operations without inventing transactions.
    let grouped = Dictionary(grouping: evidence.approvals, by: \.approval)
    guard grouped.values.allSatisfy({ $0.count == 1 }) else {
        fail("the evidence index contains duplicate approval records")
    }
    let evidenceRoot = evidenceURL.deletingLastPathComponent().resolvingSymlinksInPath()
    for approval in requiredApprovals.sorted() {
        guard let item = grouped[approval]?.first,
              item.status == "passed",
              !item.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.completedAt <= Date() else {
            fail("approval \(approval) has no complete, attributable evidence")
        }
        let artifact = evidenceRoot.appendingPathComponent(item.artifactPath).resolvingSymlinksInPath()
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
            guard evidence.phase == "mainnet_soak", item.metrics == nil else {
                fail("soak totals must be derived from recorded observations, not supplied approval metrics")
            }
        }
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonical = try encoder.encode(manifest)
    if let signedInput {
        guard let bytes = Data(base64Encoded: CommandLine.arguments[4]), bytes.count == 32,
              let signature = Data(base64Encoded: signedInput.signatureBase64) else {
            fail("invalid capability verification key or signature")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
        guard key.isValidSignature(signature, for: canonical) else { fail("capability signature is invalid") }
        print("capability_signature_and_recorded_evidence_verified")
        exit(0)
    }
    let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("the signing key file must contain one base64-encoded 32-byte Ed25519 private key")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
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
