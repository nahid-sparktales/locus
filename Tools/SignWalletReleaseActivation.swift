#!/usr/bin/env swift

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func loadObject(_ path: String) -> [String: Any] {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 1_048_576,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fail("\(path) is not a bounded JSON object") }
        return value
    } catch { fail("cannot read \(path): \(error.localizedDescription)") }
}

func canonical(_ object: Any) -> Data {
    do {
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )
    } catch { fail("the activation input is not canonical JSON") }
}

func string(_ object: [String: Any], _ key: String) -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        fail("\(key) is required")
    }
    return value
}

func integer(_ object: [String: Any], _ key: String) -> Int {
    guard let number = object[key] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue == Double(number.intValue) else { fail("\(key) must be an exact integer") }
    return number.intValue
}

func validHex(_ value: String, lengths: ClosedRange<Int>) -> Bool {
    lengths.contains(value.count) && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
}

func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

func verifiedSignedDocument(
    _ object: [String: Any],
    publicKey: Curve25519.Signing.PublicKey
) -> [String: Any] {
    guard let manifest = object["manifest"] as? [String: Any],
          let signatureText = object["signatureBase64"] as? String,
          let signature = Data(base64Encoded: signatureText),
          publicKey.isValidSignature(signature, for: canonical(manifest)) else {
        fail("an inner signed manifest has an invalid signature")
    }
    return manifest
}

func canonicalMembers(_ value: Any?) -> Set<Data> {
    Set((value as? [Any] ?? []).map(canonical))
}

func restrictionIsNarrower(
    _ restriction: [String: Any],
    than ceiling: [String: Any]
) -> Bool {
    let exactArrayKeys = [
        "evmContracts", "providerIdentities", "signInAdapters",
        "programIdentities", "uniswapConfigurations",
    ]
    guard exactArrayKeys.allSatisfy({
        canonicalMembers(restriction[$0]).isSubset(of: canonicalMembers(ceiling[$0]))
    }) else { return false }
    // A restriction receives a new manifest revision. That provenance change
    // does not change the exact asset identity or any reviewed asset authority.
    func assetAuthority(_ value: Any?) -> Set<Data> {
        Set((value as? [[String: Any]] ?? []).map { asset in
            var authority = asset
            authority.removeValue(forKey: "manifestRevision")
            return canonical(authority)
        })
    }
    guard assetAuthority(restriction["assets"]).isSubset(of: assetAuthority(ceiling["assets"]))
    else { return false }
    let restrictedAdapters = Set(restriction["adapterIDs"] as? [String] ?? [])
    let ceilingAdapters = Set(ceiling["adapterIDs"] as? [String] ?? [])
    guard restrictedAdapters.isSubset(of: ceilingAdapters),
          let restrictedExplorers = restriction["explorerTemplates"] as? [String: String],
          let ceilingExplorers = ceiling["explorerTemplates"] as? [String: String],
          restrictedExplorers.allSatisfy({ ceilingExplorers[$0.key] == $0.value }) else {
        return false
    }
    var ceilingConnectors: [String: [String: Any]] = [:]
    for item in ceiling["connectors"] as? [[String: Any]] ?? [] {
        guard let id = item["connector"] as? String, ceilingConnectors[id] == nil
        else { return false }
        ceilingConnectors[id] = item
    }
    return (restriction["connectors"] as? [[String: Any]] ?? []).allSatisfy { item in
        guard let id = item["connector"] as? String,
              let upper = ceilingConnectors[id],
              item["ownership"] as? String == upper["ownership"] as? String,
              item["version"] as? String == upper["version"] as? String,
              item["artifactSHA256"] as? String == upper["artifactSHA256"] as? String,
              item["configurationSHA256"] as? String == upper["configurationSHA256"] as? String else {
            return false
        }
        return Set(item["directions"] as? [String] ?? []).isSubset(
            of: Set(upper["directions"] as? [String] ?? [])
        ) && Set(item["methods"] as? [String] ?? []).isSubset(
            of: Set(upper["methods"] as? [String] ?? [])
        )
    }
}

guard CommandLine.arguments.count == 8 else {
    fail("usage: SignWalletReleaseActivation.swift metadata.json signed-capability.json signed-review-restriction.json signed-review-ceiling.json evidence-index.json private-key.base64 signed-output.json")
}

let metadata = loadObject(CommandLine.arguments[1])
guard Set(metadata.keys) == Set(["schemaVersion", "sourceRevision", "bundleVersion",
    "outerAppCodeDirectoryHash", "signerCodeDirectoryHash", "archiveSHA256",
    "releaseStage", "issuedAt", "expiresAt", "revision"]) else {
    fail("activation metadata contains missing or unsupported fields")
}
let signedCapability = loadObject(CommandLine.arguments[2])
let signedRestriction = loadObject(CommandLine.arguments[3])
let signedCeiling = loadObject(CommandLine.arguments[4])
let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[5])
let keyURL = URL(fileURLWithPath: CommandLine.arguments[6])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[7])

do {
    let keyText = try String(contentsOf: keyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("the signing key must contain one base64-encoded 32-byte Ed25519 private key")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let publicKey = privateKey.publicKey
    let capability = verifiedSignedDocument(signedCapability, publicKey: publicKey)
    let restriction = verifiedSignedDocument(signedRestriction, publicKey: publicKey)
    let ceiling = verifiedSignedDocument(signedCeiling, publicKey: publicKey)

    let revision = integer(metadata, "revision")
    let schemaVersion = integer(metadata, "schemaVersion")
    let stage = string(metadata, "releaseStage")
    let issuedText = string(metadata, "issuedAt")
    let expiryText = string(metadata, "expiresAt")
    let sourceRevision = string(metadata, "sourceRevision")
    let bundleVersion = string(metadata, "bundleVersion")
    let appHash = string(metadata, "outerAppCodeDirectoryHash")
    let signerHash = string(metadata, "signerCodeDirectoryHash")
    let archiveHash = string(metadata, "archiveSHA256")
    let now = Date()
    let evidenceData = try Data(contentsOf: evidenceURL)
    let evidenceHash = SHA256.hash(data: evidenceData)
        .map { String(format: "%02x", $0) }.joined()
    let evidence = loadObject(evidenceURL.path)
    guard evidenceHash == string(capability, "evidenceIndexSHA256"),
          integer(evidence, "schemaVersion") == 2,
          integer(evidence, "releaseRevision") == revision,
          string(evidence, "sourceRevision") == sourceRevision,
          let artifact = evidence["artifactIdentity"] as? [String: Any],
          string(artifact, "bundleVersion") == bundleVersion,
          string(artifact, "outerAppCodeDirectorySHA256") == appHash,
          string(artifact, "signerCodeDirectorySHA256") == signerHash,
          string(artifact, "archiveSHA256") == archiveHash else {
        fail("activation build identity differs from the capability's signed evidence")
    }
    guard schemaVersion == 1, revision > 0,
          ["invited_canary", "general_availability"].contains(stage),
          let issuedAt = date(issuedText), let expiresAt = date(expiryText),
          ISO8601DateFormatter().string(from: issuedAt) == issuedText,
          ISO8601DateFormatter().string(from: expiresAt) == expiryText,
          issuedAt <= now, expiresAt > now, expiresAt > issuedAt,
          expiresAt.timeIntervalSince(issuedAt) <= 31 * 24 * 60 * 60,
          validHex(sourceRevision, lengths: 40...64),
          bundleVersion.utf8.count <= 64,
          validHex(appHash, lengths: 40...64),
          validHex(signerHash, lengths: 40...64),
          validHex(archiveHash, lengths: 64...64),
          integer(capability, "schemaVersion") == 3,
          integer(capability, "revision") == revision,
          string(capability, "releaseStage") == stage,
          integer(restriction, "schemaVersion") == 2,
          integer(restriction, "revision") == revision,
          integer(ceiling, "schemaVersion") == 2,
          let capabilityIssued = date(string(capability, "issuedAt")),
          let capabilityExpiry = date(string(capability, "expiresAt")),
          let restrictionIssued = date(string(restriction, "issuedAt")),
          let restrictionExpiry = date(string(restriction, "expiresAt")),
          capabilityIssued >= issuedAt, capabilityExpiry <= expiresAt,
          restrictionIssued >= issuedAt, restrictionExpiry <= expiresAt,
          restrictionIsNarrower(restriction, than: ceiling) else {
        fail("activation metadata or review restriction is invalid")
    }
    var envelope = metadata
    envelope["capabilityManifest"] = signedCapability
    envelope["reviewRestriction"] = signedRestriction
    let payload = canonical(envelope)
    guard payload.count <= 1_048_576 else { fail("the activation envelope is oversized") }
    let signature = try privateKey.signature(for: payload)
    let signed: [String: Any] = [
        "envelope": envelope,
        "signatureBase64": signature.base64EncodedString(),
    ]
    try canonical(signed).write(to: outputURL, options: .atomic)
    print("public_key_base64=\(publicKey.rawRepresentation.base64EncodedString())")
    print("activation_revision=\(revision)")
} catch {
    fail(error.localizedDescription)
}
