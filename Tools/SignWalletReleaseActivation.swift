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

func digest(_ value: Any) -> String {
    SHA256.hash(data: canonical(value)).map { String(format: "%02x", $0) }.joined()
}

func normalizedScope(_ review: [String: Any]) -> [String: Any] {
    let arrayKeys = ["assets", "evmContracts", "connectors", "providerIdentities", "signInAdapters",
                     "programIdentities", "uniswapConfigurations"]
    var scope: [String: Any] = [:]
    for key in arrayKeys {
        var entries = review[key] as? [[String: Any]] ?? []
        if key == "assets" { entries = entries.map { var value = $0; value["manifestRevision"] = 1; return value } }
        if key == "connectors" {
            entries = entries.map { item in
                var item = item
                for name in ["directions", "methods"] { item[name] = (item[name] as? [String] ?? []).sorted() }
                return item
            }
        }
        if key == "signInAdapters" {
            entries = entries.map { var item = $0; item["networkIDs"] = (item["networkIDs"] as? [String] ?? []).sorted(); return item }
        }
        if key == "uniswapConfigurations" {
            entries = entries.map { item in
                var item = item
                for name in ["allowedIntermediaryAssetIDs", "zeroFirstApprovalAssetIDs"] {
                    item[name] = (item[name] as? [String] ?? []).sorted()
                }
                item["allowedFeeTiers"] = (item["allowedFeeTiers"] as? [Int] ?? []).sorted()
                return item
            }
        }
        scope[key] = entries.sorted { canonical($0).lexicographicallyPrecedes(canonical($1)) }
    }
    scope["adapterIDs"] = (review["adapterIDs"] as? [String] ?? []).sorted()
    scope["explorerTemplates"] = review["explorerTemplates"] as? [String: String] ?? [:]
    return scope
}

func normalizedGrants(_ capability: [String: Any]) -> [[String: Any]] {
    (capability["networkGrants"] as? [[String: Any]] ?? []).map { grant in
        var grant = grant
        grant["capabilities"] = (grant["capabilities"] as? [String] ?? []).sorted()
        let connectors = (grant["connectors"] as? [[String: Any]] ?? []).map { item in
            var item = item
            for key in ["directions", "methods"] { item[key] = (item[key] as? [String] ?? []).sorted() }
            return item
        }
        grant["connectors"] = connectors.sorted { canonical($0).lexicographicallyPrecedes(canonical($1)) }
        return grant
    }.sorted { string($0, "networkID") < string($1, "networkID") }
}

func authority(_ metadata: [String: Any], _ cap: [String: Any], _ review: [String: Any]) -> [String: Any] {
    var value: [String: Any] = [
        "networkGrants": normalizedGrants(cap),
        "approvedRegions": (cap["approvedRegions"] as? [String] ?? []).sorted(),
        "reviewScope": normalizedScope(review), "releaseStage": string(metadata, "releaseStage"),
        "canaryLimits": (cap["canaryLimits"] as? [[String: Any]] ?? []).sorted { canonical($0).lexicographicallyPrecedes(canonical($1)) },
        "permanentLimits": (metadata["permanentLimits"] as? [[String: Any]] ?? []).sorted { canonical($0).lexicographicallyPrecedes(canonical($1)) },
        "admissionGeneration": integer(metadata, "admissionGeneration"),
        "revokedAdmissionSerials": metadata["revokedAdmissionSerials"] as? [String] ?? [],
    ]
    if let cohort = metadata["cohortID"] as? String { value["cohortID"] = cohort }
    return value
}

func candidate(_ metadata: [String: Any], ceilingHash: String) -> [String: Any] {
    ["installedIdentity": ["sourceRevision": string(metadata, "sourceRevision"),
                           "bundleVersion": string(metadata, "bundleVersion"),
                           "outerAppCodeDirectoryHash": string(metadata, "outerAppCodeDirectoryHash"),
                           "signerCodeDirectoryHash": string(metadata, "signerCodeDirectoryHash")],
     "archiveSHA256": string(metadata, "archiveSHA256"), "reviewCeilingSHA256": ceilingHash]
}

func runReviewVerifier(_ mode: String, path: String, publicKey: Curve25519.Signing.PublicKey) throws {
    let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SignWalletReviewManifest.swift")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", tool.path, mode, path, publicKey.rawRepresentation.base64EncodedString()]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("review signature or structural validation failed") }
}

func runCapabilityVerifier(publicKey: Curve25519.Signing.PublicKey) throws {
    let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SignWalletCapabilityManifest.swift")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", tool.path, "--verify", CommandLine.arguments[2], CommandLine.arguments[5],
                         publicKey.rawRepresentation.base64EncodedString()]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("capability signature or recorded release evidence failed") }
}

func limitIdentity(_ value: [String: Any]) -> String {
    ["networkID", "assetID", "action", "ownership"].map { string(value, $0) }.joined(separator: "|")
        + "|" + (value["connector"] as? String ?? "vault")
}

func validLimits(_ values: [[String: Any]]) -> Bool {
    var identities = Set<String>()
    return values.count <= 10_000 && values.allSatisfy { item in
        let required: Set<String> = ["networkID", "assetID", "action", "ownership", "maximumTransactionBaseUnits",
                                    "maximumCumulativeBaseUnits", "maximumFeeBaseUnits", "maximumCumulativeFeeBaseUnits", "maximumTransactions"]
        guard Set(item.keys) == required.union(item["connector"] == nil ? [] : ["connector"]),
              item["connector"] == nil || item["connector"] is String,
              string(item, "assetID").utf8.count <= 512 else { return false }
        let count = integer(item, "maximumTransactions")
        let expectedOwnership = ["metamask": "external", "slush": "external", "phantom": "connector_managed"]
        let owner = string(item, "ownership"), connector = item["connector"] as? String
        guard identities.insert(limitIdentity(item)).inserted, (1...1_000_000).contains(count),
              (owner == "locus_vault" && connector == nil) || expectedOwnership[connector ?? ""] == owner,
              ["native_transfer", "fungible_token_transfer", "nft_transfer", "exact_input_swap", "swap_allowance_setup"].contains(string(item, "action")) else { return false }
        for key in ["maximumTransactionBaseUnits", "maximumCumulativeBaseUnits", "maximumFeeBaseUnits", "maximumCumulativeFeeBaseUnits"] {
            let value = string(item, key)
            guard value.count <= 78, value.first != "0", value.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        return lessOrEqual(string(item, "maximumTransactionBaseUnits"), string(item, "maximumCumulativeBaseUnits"))
            && lessOrEqual(string(item, "maximumFeeBaseUnits"), string(item, "maximumCumulativeFeeBaseUnits"))
    }
}

func lessOrEqual(_ a: String, _ b: String) -> Bool { a.count == b.count ? a <= b : a.count < b.count }

func lowerLimit(_ value: [String: Any], _ upper: [String: Any]) -> Bool {
    limitIdentity(value) == limitIdentity(upper)
        && integer(value, "maximumTransactions") <= integer(upper, "maximumTransactions")
        && ["maximumTransactionBaseUnits", "maximumCumulativeBaseUnits", "maximumFeeBaseUnits", "maximumCumulativeFeeBaseUnits"].allSatisfy {
            lessOrEqual(string(value, $0), string(upper, $0))
        }
}

func narrowerGrants(_ next: [String: Any], _ old: [String: Any]) -> Bool {
    guard Set(next["approvedRegions"] as? [String] ?? []).isSubset(of: Set(old["approvedRegions"] as? [String] ?? [])) else { return false }
    return normalizedGrants(next).allSatisfy { grant in
        guard let upper = normalizedGrants(old).first(where: { $0["networkID"] as? String == grant["networkID"] as? String }),
              Set(grant["capabilities"] as? [String] ?? []).isSubset(of: Set(upper["capabilities"] as? [String] ?? [])) else { return false }
        return (grant["connectors"] as? [[String: Any]] ?? []).allSatisfy { item in
            (upper["connectors"] as? [[String: Any]] ?? []).contains { upperItem in
                item["connector"] as? String == upperItem["connector"] as? String
                    && item["ownership"] as? String == upperItem["ownership"] as? String
                    && Set(item["directions"] as? [String] ?? []).isSubset(of: Set(upperItem["directions"] as? [String] ?? []))
                    && Set(item["methods"] as? [String] ?? []).isSubset(of: Set(upperItem["methods"] as? [String] ?? []))
            }
        }
    }
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

// Publication preflight only: no private key is read and no authority is issued.
// The signed issuer transition already binds independently approved GA evidence;
// this check binds its promotion to the retained, actually inspected ZIP.
if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--verify-promotion" {
    do {
        let signed = loadObject(CommandLine.arguments[2])
        let identity = loadObject(CommandLine.arguments[4])
        let signedCeiling = loadObject(CommandLine.arguments[5])
        guard let keyData = Data(base64Encoded: CommandLine.arguments[3]), keyData.count == 32 else { fail("invalid promotion verification key") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard let envelope = signed["envelope"] as? [String: Any],
              let rawSignature = signed["signatureBase64"] as? String,
              let signature = Data(base64Encoded: rawSignature), key.isValidSignature(signature, for: canonical(envelope)),
              let ceiling = signedCeiling["ceiling"] as? [String: Any],
              let rawCeilingSignature = signedCeiling["signatureBase64"] as? String,
              let ceilingSignature = Data(base64Encoded: rawCeilingSignature), key.isValidSignature(ceilingSignature, for: canonical(ceiling)),
              let signedCap = envelope["capabilityManifest"] as? [String: Any],
              let signedReview = envelope["reviewRestriction"] as? [String: Any],
              integer(envelope, "schemaVersion") == 2, string(envelope, "transition") == "promotion",
              string(envelope, "purpose") == "production", string(envelope, "releaseStage") == "general_availability",
              validHex(string(envelope, "previousEnvelopeSHA256"), lengths: 64...64),
              let issued = date(string(envelope, "issuedAt")), let expiry = date(string(envelope, "expiresAt")),
              ISO8601DateFormatter().string(from: issued) == string(envelope, "issuedAt"),
              ISO8601DateFormatter().string(from: expiry) == string(envelope, "expiresAt"),
              issued <= Date(), expiry > Date(), expiry > issued, expiry.timeIntervalSince(issued) <= 31 * 86_400 else {
            fail("a current signed production GA promotion is required")
        }
        let cap = verifiedSignedDocument(signedCap, publicKey: key)
        let review = verifiedSignedDocument(signedReview, publicKey: key)
        let fields: Set<String> = ["sourceRevision", "bundleVersion", "outerAppCodeDirectoryHash", "signerCodeDirectoryHash", "archiveSHA256"]
        guard Set(identity.keys) == fields, fields.allSatisfy({ string(identity, $0) == string(envelope, $0) }),
              validHex(string(identity, "sourceRevision"), lengths: 40...64),
              validHex(string(identity, "outerAppCodeDirectoryHash"), lengths: 40...40),
              validHex(string(identity, "signerCodeDirectoryHash"), lengths: 40...40),
              validHex(string(identity, "archiveSHA256"), lengths: 64...64),
              string(envelope, "reviewCeilingSHA256") == digest(ceiling),
              string(envelope, "candidateID") == digest(candidate(envelope, ceilingHash: digest(ceiling))),
              string(envelope, "authoritySHA256") == digest(authority(envelope, cap, review)),
              integer(cap, "revision") == integer(envelope, "revision"), integer(review, "revision") == integer(envelope, "revision"),
              string(cap, "releaseStage") == "general_availability", (cap["canaryLimits"] as? [[String: Any]] ?? []).isEmpty,
              [cap, review].allSatisfy({ string($0, "issuedAt") == string(envelope, "issuedAt") && string($0, "expiresAt") == string(envelope, "expiresAt") }) else {
            fail("GA promotion differs from the exact retained candidate archive or authority")
        }
        print("Signed GA promotion matches the retained notarized candidate identity.")
        exit(0)
    } catch { fail(error.localizedDescription) }
}

if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--sign-admission" {
    let admission = loadObject(CommandLine.arguments[2])
    let signedTransition = loadObject(CommandLine.arguments[3])
    do {
        let keyText = try String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bytes = Data(base64Encoded: keyText), bytes.count == 32 else { fail("invalid admission signing key") }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        guard let envelope = signedTransition["envelope"] as? [String: Any],
              let signatureText = signedTransition["signatureBase64"] as? String,
              let signature = Data(base64Encoded: signatureText),
              key.publicKey.isValidSignature(signature, for: canonical(envelope)),
              integer(envelope, "schemaVersion") == 2,
              string(envelope, "purpose") == "production", string(envelope, "releaseStage") == "invited_canary",
              let signedCap = envelope["capabilityManifest"] as? [String: Any],
              let signedReview = envelope["reviewRestriction"] as? [String: Any] else { fail("admission requires a verified production canary transition") }
        let cap = verifiedSignedDocument(signedCap, publicKey: key.publicKey)
        let review = verifiedSignedDocument(signedReview, publicKey: key.publicKey)
        guard string(envelope, "candidateID") == digest(candidate(envelope, ceilingHash: string(envelope, "reviewCeilingSHA256"))),
              string(envelope, "authoritySHA256") == digest(authority(envelope, cap, review)),
              integer(cap, "revision") == integer(envelope, "revision"),
              integer(review, "revision") == integer(envelope, "revision"),
              string(cap, "releaseStage") == "invited_canary" else { fail("admission transition identity or authority fingerprint differs") }
        guard Set(admission.keys) == ["schemaVersion", "domain", "candidateID", "cohortID", "installationID",
                                      "serial", "generation", "issuedAt", "expiresAt", "allocation"],
              integer(admission, "schemaVersion") == 1,
              string(admission, "domain") == "locus-wallet-canary-admission-v1",
              string(admission, "candidateID") == string(envelope, "candidateID"),
              string(admission, "cohortID") == string(envelope, "cohortID"),
              integer(admission, "generation") == integer(envelope, "admissionGeneration"),
              ["installationID", "serial", "candidateID", "cohortID"].allSatisfy({ validHex(string(admission, $0), lengths: 64...64) }),
              !(envelope["revokedAdmissionSerials"] as? [String] ?? []).contains(string(admission, "serial")),
              let issued = date(string(admission, "issuedAt")), let expiry = date(string(admission, "expiresAt")),
              let activationExpiry = date(string(envelope, "expiresAt")),
              ISO8601DateFormatter().string(from: issued) == string(admission, "issuedAt"),
              ISO8601DateFormatter().string(from: expiry) == string(admission, "expiresAt"),
              issued <= Date(), expiry > Date(), expiry > issued, expiry <= activationExpiry,
              expiry.timeIntervalSince(issued) <= 31 * 86_400,
              let allocation = admission["allocation"] as? [[String: Any]], !allocation.isEmpty,
              validLimits(allocation), allocation.allSatisfy({ item in
                  (cap["canaryLimits"] as? [[String: Any]] ?? []).contains { lowerLimit(item, $0) }
              }), allocation.allSatisfy({ item in
                  guard let permanent = (envelope["permanentLimits"] as? [[String: Any]] ?? []).first(where: { limitIdentity($0) == limitIdentity(item) }) else { return true }
                  return lowerLimit(item, permanent)
              }) else { fail("admission identity, expiry, revocation state, or finite allocation is invalid") }
        let signed: [String: Any] = ["admission": admission,
            "signatureBase64": try key.signature(for: canonical(admission)).base64EncodedString()]
        let destination = URL(fileURLWithPath: CommandLine.arguments[5])
        guard !FileManager.default.fileExists(atPath: destination.path) else { fail("admission output already exists") }
        try canonical(signed).write(to: destination, options: .atomic)
        print("candidate_bound_admission_signed; publication_and_enrollment_approval_remain_external")
        exit(0)
    } catch { fail(error.localizedDescription) }
}

if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--describe" {
    let metadata = loadObject(CommandLine.arguments[2])
    let capability = loadObject(CommandLine.arguments[3])
    let review = loadObject(CommandLine.arguments[4])
    let ceiling = loadObject(CommandLine.arguments[5])
    guard let value = ceiling["ceiling"] as? [String: Any] else { fail("a distinct signed review ceiling is required") }
    let ceilingHash = digest(value)
    let result: [String: Any] = ["candidateID": digest(candidate(metadata, ceilingHash: ceilingHash)),
                               "reviewCeilingSHA256": ceilingHash,
                               "authoritySHA256": digest(authority(metadata, capability, review))]
    FileHandle.standardOutput.write(canonical(result))
    exit(0)
}

guard CommandLine.arguments.count == 9 else {
    fail("usage: SignWalletReleaseActivation.swift metadata.json signed-capability.json signed-review-restriction.json signed-review-ceiling.json evidence-index.json previous-envelope.json|initial private-key.base64 signed-output.json\n       --describe metadata.json unsigned-capability.json unsigned-review.json signed-ceiling.json")
}

let metadata = loadObject(CommandLine.arguments[1])
guard Set(metadata.keys) == Set(["schemaVersion", "sourceRevision", "bundleVersion",
    "outerAppCodeDirectoryHash", "signerCodeDirectoryHash", "archiveSHA256",
    "releaseStage", "issuedAt", "expiresAt", "revision", "transition", "purpose", "candidateID",
    "reviewCeilingSHA256", "authoritySHA256", "admissionGeneration", "revokedAdmissionSerials", "permanentLimits"])
    .union(metadata["cohortID"] == nil ? [] : ["cohortID"])
    .union(metadata["previousEnvelopeSHA256"] == nil ? [] : ["previousEnvelopeSHA256"]) else {
    fail("activation metadata contains missing or unsupported fields")
}
let signedCapability = loadObject(CommandLine.arguments[2])
let signedRestriction = loadObject(CommandLine.arguments[3])
let signedCeiling = loadObject(CommandLine.arguments[4])
let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[5])
let previousPath = CommandLine.arguments[6]
let keyURL = URL(fileURLWithPath: CommandLine.arguments[7])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[8])

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
    guard let ceilingDocument = signedCeiling["ceiling"] as? [String: Any],
          let ceilingSignature = signedCeiling["signatureBase64"] as? String,
          let ceilingBytes = Data(base64Encoded: ceilingSignature),
          publicKey.isValidSignature(ceilingBytes, for: canonical(ceilingDocument)),
          let ceiling = ceilingDocument["scope"] as? [String: Any] else {
        fail("the non-activating review ceiling signature is invalid")
    }

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
    let transition = string(metadata, "transition")
    let purpose = string(metadata, "purpose")
    let ceilingHash = digest(ceilingDocument)
    let currentAuthority = digest(authority(metadata, capability, restriction))
    guard string(metadata, "reviewCeilingSHA256") == ceilingHash,
          string(metadata, "candidateID") == digest(candidate(metadata, ceilingHash: ceilingHash)),
          string(metadata, "authoritySHA256") == currentAuthority else {
        fail("candidate, ceiling, or authority fingerprint differs from exact normalized inputs")
    }
    var previous: [String: Any]?
    if previousPath != "initial" {
        let signed = loadObject(previousPath)
        guard let value = signed["envelope"] as? [String: Any],
              let signatureText = signed["signatureBase64"] as? String,
              let signature = Data(base64Encoded: signatureText),
              publicKey.isValidSignature(signature, for: canonical(value)) else { fail("previous activation signature is invalid") }
        previous = value
    }
    let now = Date()
    let evidenceData = try Data(contentsOf: evidenceURL)
    let evidenceHash = SHA256.hash(data: evidenceData)
        .map { String(format: "%02x", $0) }.joined()
    let evidence = loadObject(evidenceURL.path)
    guard evidenceHash == string(capability, "evidenceIndexSHA256"),
          integer(evidence, "schemaVersion") == 2,
          integer(evidence, "releaseRevision") == revision,
          string(evidence, "sourceRevision") == sourceRevision,
          string(evidence, "candidateID") == string(metadata, "candidateID"),
          string(evidence, "authoritySHA256") == ((transition == "promotion" || transition == "restriction")
              ? previous.map { string($0, "authoritySHA256") } ?? "" : currentAuthority),
          let artifact = evidence["artifactIdentity"] as? [String: Any],
          string(artifact, "bundleVersion") == bundleVersion,
          string(artifact, "outerAppCodeDirectoryHash") == appHash,
          string(artifact, "signerCodeDirectoryHash") == signerHash,
          string(artifact, "archiveSHA256") == archiveHash else {
        fail("activation build identity differs from the capability's signed evidence")
    }
    guard schemaVersion == 2, revision > 0,
          ["invited_canary", "general_availability"].contains(stage),
          let issuedAt = date(issuedText), let expiresAt = date(expiryText),
          ISO8601DateFormatter().string(from: issuedAt) == issuedText,
          ISO8601DateFormatter().string(from: expiresAt) == expiryText,
          issuedAt <= now, expiresAt > now, expiresAt > issuedAt,
          expiresAt.timeIntervalSince(issuedAt) <= 31 * 24 * 60 * 60,
          validHex(sourceRevision, lengths: 40...64),
          bundleVersion.utf8.count <= 64,
          validHex(appHash, lengths: 40...40),
          validHex(signerHash, lengths: 40...40),
          validHex(archiveHash, lengths: 64...64),
          integer(capability, "schemaVersion") == 3,
          integer(capability, "revision") == revision,
          string(capability, "releaseStage") == stage,
          integer(restriction, "schemaVersion") == 2,
          integer(restriction, "revision") == revision,
          integer(ceilingDocument, "schemaVersion") == 1,
          string(ceilingDocument, "domain") == "locus-wallet-review-ceiling-v1",
          let capabilityIssued = date(string(capability, "issuedAt")),
          let capabilityExpiry = date(string(capability, "expiresAt")),
          let restrictionIssued = date(string(restriction, "issuedAt")),
          let restrictionExpiry = date(string(restriction, "expiresAt")),
          string(capability, "issuedAt") == issuedText, string(capability, "expiresAt") == expiryText,
          string(restriction, "issuedAt") == issuedText, string(restriction, "expiresAt") == expiryText,
          capabilityIssued == issuedAt, capabilityExpiry == expiresAt,
          restrictionIssued == issuedAt, restrictionExpiry == expiresAt,
          restrictionIsNarrower(restriction, than: ceiling) else {
        fail("activation metadata or review restriction is invalid")
    }
    let limits = capability["canaryLimits"] as? [[String: Any]] ?? []
    let permanent = metadata["permanentLimits"] as? [[String: Any]] ?? []
    let revoked = metadata["revokedAdmissionSerials"] as? [String] ?? []
    guard validLimits(limits), validLimits(permanent), revoked == Array(Set(revoked)).sorted(),
          revoked.count <= 10_000, revoked.allSatisfy({ validHex($0, lengths: 64...64) }),
          ["initial", "renewal", "restriction", "promotion"].contains(transition),
          ["production", "testnet_rehearsal"].contains(purpose) else { fail("invalid transition controls") }
    let mainnets: Set<String> = ["eip155:1", "solana:mainnet-beta", "sui:mainnet"]
    let testnets: Set<String> = ["eip155:11155111", "solana:devnet", "sui:testnet"]
    let networks = Set(normalizedGrants(capability).map { string($0, "networkID") })
    let phase = string(evidence, "phase")
    if purpose == "testnet_rehearsal" {
        guard !networks.isEmpty, networks.isSubset(of: testnets), stage == "invited_canary",
              metadata["cohortID"] == nil, integer(metadata, "admissionGeneration") == 0,
              revoked.isEmpty, phase == "testnet_rehearsal_authorization" else { fail("rehearsal may not activate mainnet or bypass its evidence gates") }
    } else if stage == "invited_canary" {
        guard validHex(string(metadata, "cohortID"), lengths: 64...64), integer(metadata, "admissionGeneration") > 0,
              networks.intersection(mainnets).allSatisfy({ network in limits.contains { $0["networkID"] as? String == network } }) else {
            fail("production canary requires exact admission and finite all-chain controls")
        }
    }
    if purpose == "production" {
        for network in networks.intersection(mainnets) {
            let providers = Set((restriction["providerIdentities"] as? [[String: Any]] ?? [])
                .filter { $0["networkID"] as? String == network }.compactMap { $0["provider"] as? String })
            guard providers.isSuperset(of: ["alchemy", "quicknode"]) else {
                fail("every activated mainnet requires both exact reviewed provider identities")
            }
        }
    }
    if let old = previous {
        guard transition != "initial", integer(old, "schemaVersion") == 2,
              revision > integer(old, "revision"), metadata["previousEnvelopeSHA256"] as? String == digest(old),
              string(old, "candidateID") == string(metadata, "candidateID"), string(old, "purpose") == purpose,
              let oldIssued = date(string(old, "issuedAt")), oldIssued <= issuedAt,
              let oldSignedCapability = old["capabilityManifest"] as? [String: Any],
              let oldSignedReview = old["reviewRestriction"] as? [String: Any] else { fail("transition history or candidate lineage differs") }
        let oldCap = verifiedSignedDocument(oldSignedCapability, publicKey: publicKey)
        let oldReview = verifiedSignedDocument(oldSignedReview, publicKey: publicKey)
        if transition == "renewal" {
            guard currentAuthority == string(old, "authoritySHA256") else { fail("renewal changed authority") }
        } else {
            let oldPermanent = old["permanentLimits"] as? [[String: Any]] ?? []
            guard narrowerGrants(capability, oldCap), restrictionIsNarrower(restriction, than: oldReview),
                  Set(old["revokedAdmissionSerials"] as? [String] ?? []).isSubset(of: Set(revoked)),
                  integer(metadata, "admissionGeneration") >= integer(old, "admissionGeneration"),
                  metadata["cohortID"] as? String == old["cohortID"] as? String,
                  oldPermanent.allSatisfy({ upper in permanent.contains { lowerLimit($0, upper) } }) else {
                fail("transition would restore previously restricted authority")
            }
            if transition == "promotion" {
                guard purpose == "production", stage == "general_availability", string(old, "releaseStage") == "invited_canary",
                      canonical(normalizedGrants(capability)) == canonical(normalizedGrants(oldCap)),
                      canonical(normalizedScope(restriction)) == canonical(normalizedScope(oldReview)),
                      Set(capability["approvedRegions"] as? [String] ?? []) == Set(oldCap["approvedRegions"] as? [String] ?? []),
                      canonical(permanent) == canonical(oldPermanent), limits.isEmpty, phase == "mainnet_soak" else {
                    fail("promotion must retain the exact soaked archive and scope")
                }
            } else {
                let oldLimits = oldCap["canaryLimits"] as? [[String: Any]] ?? []
                guard stage == string(old, "releaseStage"), limits.allSatisfy({ item in oldLimits.contains { lowerLimit(item, $0) } }),
                      oldLimits.allSatisfy({ upper in limits.contains { limitIdentity($0) == limitIdentity(upper) } }),
                      limits.allSatisfy({ item in
                          guard let upper = oldLimits.first(where: { limitIdentity($0) == limitIdentity(item) }), canonical(upper) != canonical(item) else { return true }
                          return permanent.contains { lowerLimit($0, item) }
                      }) else { fail("an emergency limit reduction must remain permanent") }
            }
        }
    } else {
        guard transition == "initial", metadata["previousEnvelopeSHA256"] == nil, stage == "invited_canary" else {
            fail("initial activation requires explicit initial lineage")
        }
        if purpose == "production" {
            guard mainnets.isSubset(of: networks), phase == "pre_canary_rehearsal" else { fail("initial production canary requires all three chains and rehearsal evidence") }
        }
    }
    try runReviewVerifier("--verify-ceiling", path: CommandLine.arguments[4], publicKey: publicKey)
    try runReviewVerifier("--verify", path: CommandLine.arguments[3], publicKey: publicKey)
    try runCapabilityVerifier(publicKey: publicKey)
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
