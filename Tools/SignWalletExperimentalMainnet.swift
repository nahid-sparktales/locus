#!/usr/bin/env swift

// Local, initial-only experimental authority. This is not a release-evidence issuer.
import CryptoKit
import Darwin
import Foundation
import Security

enum InputError: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw InputError.invalid(message) }
}
// Match WalletAuthorityEncoding's JSONEncoder, not JSONSerialization's
// locale/case-insensitive sortedKeys (reviewRevision/reviewedAt differ).
struct CanonicalJSON: Encodable {
    let value: Any
    func encode(to encoder: Encoder) throws {
        var output = encoder.singleValueContainer()
        switch value {
        case is NSNull: try output.encodeNil()
        case let text as String: try output.encode(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { try output.encode(number.boolValue) }
            else if let signed = Int64(number.stringValue) { try output.encode(signed) }
            else if let unsigned = UInt64(number.stringValue) { try output.encode(unsigned) }
            else if let decimal = number as? NSDecimalNumber { try output.encode(decimal.decimalValue) }
            else {
                try require(number.doubleValue.isFinite, "nonfinite JSON number")
                try output.encode(number.doubleValue)
            }
        case let items as [Any]: try output.encode(items.map { CanonicalJSON(value: $0) })
        case let fields as [String: Any]: try output.encode(fields.mapValues { CanonicalJSON(value: $0) })
        default: throw InputError.invalid("unsupported canonical JSON value")
        }
    }
}
func canonical(_ value: Any) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(CanonicalJSON(value: value))
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func digest(_ value: Any) throws -> String { hash(try canonical(value)) }
func hex(_ value: String, _ length: Int) -> Bool {
    value.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func string(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else { throw InputError.invalid("missing string field: \(key)") }
    return value
}
func integer(_ object: [String: Any], _ key: String) throws -> Int {
    guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite, value.doubleValue == Double(value.intValue) else {
        throw InputError.invalid("invalid integer field: \(key)")
    }
    return value.intValue
}
func strings(_ object: [String: Any], _ key: String) throws -> Set<String> {
    guard let value = object[key] as? [String], Set(value).count == value.count else {
        throw InputError.invalid("invalid or duplicate set: \(key)")
    }
    return Set(value)
}
func exactKeys(_ object: [String: Any], _ keys: Set<String>) throws {
    try require(Set(object.keys) == keys, "unexpected or missing input fields")
}
func checkedURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    try require(url.path == url.resolvingSymlinksInPath().path, "symlink inputs and output ancestors are unavailable; use their canonical paths")
    return url
}
func openInput(_ url: URL, limit: Int? = nil, privateKey: Bool = false) throws -> Int32 {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try require(descriptor >= 0, "cannot open input")
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size >= 0, limit == nil || info.st_size <= limit!,
          !privateKey || (info.st_uid == geteuid() && info.st_nlink == 1 && (info.st_mode & 0o077) == 0) else {
        close(descriptor); throw InputError.invalid("input type, size, ownership or private-key permissions are invalid")
    }
    return descriptor
}
func readInput(_ url: URL, limit: Int = 1_048_576, privateKey: Bool = false) throws -> Data {
    let descriptor = try openInput(url, limit: limit, privateKey: privateKey)
    defer { close(descriptor) }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        try require(count >= 0, "input read failed")
        if count == 0 { break }
        try require(data.count + count <= limit, "input grew beyond its bound")
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}
func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw InputError.invalid("input must be a JSON object")
    }
    return value
}
func archiveHash(_ url: URL) throws -> String {
    let descriptor = try openInput(url)
    defer { close(descriptor) }
    var before = stat(), after = stat(), hasher = SHA256()
    try require(fstat(descriptor, &before) == 0 && before.st_size > 0, "archive must be nonempty")
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        try require(count >= 0, "archive read failed")
        if count == 0 { break }
        hasher.update(data: Data(buffer.prefix(count)))
    }
    try require(fstat(descriptor, &after) == 0 && before.st_size == after.st_size
        && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
        && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
        && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, "archive changed while hashing")
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
func plist(_ url: URL) throws -> [String: Any] {
    guard let result = try PropertyListSerialization.propertyList(from: readInput(url), format: nil) as? [String: Any] else {
        throw InputError.invalid("invalid bundle configuration")
    }
    guard let enabled = result["LocusWalletExperimentalMainnetEnabled"] as? NSNumber,
          CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue else {
        throw InputError.invalid("app and signer must have a sealed experimental Boolean")
    }
    return result
}

struct CodeIdentity: Equatable { let codeDirectoryHash: String }
// Tests replace only this function in a temporary source copy, never in this CLI.
func verifiedCodeIdentity(_ url: URL, identifier: String) throws -> CodeIdentity {
    var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
    let rule = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"4X4RJA7GMD\""
    try require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                "cannot inspect signed executable")
    try require(SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                "cannot create code requirement")
    guard let code else { throw InputError.invalid("missing signed executable") }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    try require(SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess,
                "executable signature, team, identifier or sealed contents are invalid")
    try require(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                "cannot read code identity")
    guard let values = information as? [String: Any],
          values[kSecCodeInfoIdentifier as String] as? String == identifier,
          values[kSecCodeInfoTeamIdentifier as String] as? String == "4X4RJA7GMD",
          let unique = values[kSecCodeInfoUnique as String] as? Data, unique.count == 20 else {
        throw InputError.invalid("invalid Apple code identity")
    }
    return CodeIdentity(codeDirectoryHash: unique.map { String(format: "%02x", $0) }.joined())
}

func runValidator(_ name: String, _ arguments: [String]) throws {
    let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(name)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [name.hasSuffix(".swift") ? "swift" : "python3", tool.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice // No input/configuration values in diagnostics.
    try process.run(); process.waitUntilExit()
    try require(process.terminationReason == .exit && process.terminationStatus == 0,
                "\(name) rejected the signed configuration")
}
func signedPayload(_ signed: [String: Any], field: String, key: Curve25519.Signing.PublicKey) throws -> [String: Any] {
    try exactKeys(signed, [field, "signatureBase64"])
    guard let value = signed[field] as? [String: Any],
          let signature = Data(base64Encoded: try string(signed, "signatureBase64")), signature.count == 64 else {
        throw InputError.invalid("invalid signed document")
    }
    try require(key.isValidSignature(signature, for: canonical(value)), "signed document signature is invalid")
    return value
}
func sortedObjects(_ objects: [[String: Any]]) throws -> [[String: Any]] {
    try objects.map { (try canonical($0), $0) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
}
func normalizedScope(_ review: [String: Any]) throws -> [String: Any] {
    var scope: [String: Any] = [:]
    for field in ["assets", "evmContracts", "connectors", "providerIdentities", "signInAdapters", "programIdentities", "uniswapConfigurations"] {
        guard let values = review[field] as? [[String: Any]] else { throw InputError.invalid("missing review scope") }
        scope[field] = try sortedObjects(values.map { original in
            var value = original
            if field == "assets" { value["manifestRevision"] = 1 }
            let setKeys = field == "connectors" ? ["directions", "methods"] : field == "signInAdapters" ? ["networkIDs"]
                : field == "uniswapConfigurations" ? ["allowedIntermediaryAssetIDs", "zeroFirstApprovalAssetIDs"] : []
            for key in setKeys { value[key] = try strings(value, key).sorted() }
            if field == "uniswapConfigurations" { value["allowedFeeTiers"] = (value["allowedFeeTiers"] as? [Int] ?? []).sorted() }
            return value
        })
    }
    scope["adapterIDs"] = try strings(review, "adapterIDs").sorted()
    scope["explorerTemplates"] = review["explorerTemplates"]
    return scope
}
func requireNarrowing(_ scope: [String: Any], ceiling: [String: Any]) throws {
    for field in ["assets", "evmContracts", "providerIdentities", "signInAdapters", "programIdentities", "uniswapConfigurations"] {
        let upper = try Set((ceiling[field] as? [[String: Any]] ?? []).map(canonical))
        let lower = try Set((scope[field] as? [[String: Any]] ?? []).map(canonical))
        try require(lower.isSubset(of: upper), "review restriction broadens the bundled ceiling")
    }
    try require(strings(scope, "adapterIDs").isSubset(of: strings(ceiling, "adapterIDs")), "adapter restriction broadens ceiling")
    let upperExplorers = ceiling["explorerTemplates"] as? [String: String] ?? [:]
    try require((scope["explorerTemplates"] as? [String: String] ?? [:]).allSatisfy { upperExplorers[$0.key] == $0.value }, "explorer restriction broadens ceiling")
    for item in scope["connectors"] as? [[String: Any]] ?? [] {
        guard let upper = (ceiling["connectors"] as? [[String: Any]] ?? []).first(where: { $0["connector"] as? String == item["connector"] as? String }) else {
            throw InputError.invalid("connector absent from ceiling")
        }
        for field in ["ownership", "version", "artifactSHA256", "configurationSHA256"] {
            try require(item[field] as? String == upper[field] as? String, "connector identity differs from ceiling")
        }
        for field in ["directions", "methods"] {
            try require(strings(item, field).isSubset(of: strings(upper, field)), "connector grant broadens ceiling")
        }
    }
}

let networkNames = ["eip155:1": "EthereumMainnet", "eip155:11155111": "EthereumSepolia",
                    "solana:mainnet-beta": "SolanaMainnet", "solana:devnet": "SolanaDevnet",
                    "sui:mainnet": "SuiMainnet", "sui:testnet": "SuiTestnet"]
let mainnets: Set<String> = ["eip155:1", "solana:mainnet-beta", "sui:mainnet"]
func validatedGrants(_ cap: [String: Any], review: [String: Any], info: [String: Any]) throws -> [[String: Any]] {
    guard let grants = cap["networkGrants"] as? [[String: Any]], !grants.isEmpty, grants.count <= 6 else {
        throw InputError.invalid("explicit network grants are required")
    }
    var networks = Set<String>(), output: [[String: Any]] = []
    for grant in grants {
        try exactKeys(grant, ["networkID", "capabilities", "connectors"])
        let network = try string(grant, "networkID")
        guard let name = networkNames[network] else { throw InputError.invalid("unsupported network") }
        try require(networks.insert(network).inserted, "duplicate network grant")
        let evm = network.hasPrefix("eip155:"), solana = network.hasPrefix("solana:")
        var allowed: Set<String> = ["native_transfer", "fungible_token_transfer", "nft_transfer", "embedded_browser", "external_wallet", "wallet_connect"]
        if evm || solana { allowed.formUnion(["autonomous_policy", "standardized_sign_in"]) }
        if evm { allowed.formUnion(["exact_input_swap", "reviewed_call"]) }
        let capabilities = try strings(grant, "capabilities")
        try require(!capabilities.isEmpty && capabilities.isSubset(of: allowed), "unsupported network capability")
        guard let connectors = grant["connectors"] as? [[String: Any]], connectors.count <= 5 else { throw InputError.invalid("invalid connector grants") }
        var ids = Set<String>(), normalizedConnectors: [[String: Any]] = []
        for connector in connectors {
            try exactKeys(connector, ["connector", "ownership", "directions", "methods"])
            let id = try string(connector, "connector")
            let vendor = ["metamask", "phantom", "slush"].contains(id)
            let expected = ["metamask": "external", "phantom": "connector_managed", "slush": "external", "embedded_browser": "locus_vault", "wallet_connect": "locus_vault"]
            try require(ids.insert(id).inserted && expected[id] == (connector["ownership"] as? String), "invalid connector ownership or duplicate")
            try require(id != "metamask" || evm, "connector network mismatch")
            try require(id != "phantom" || solana, "connector network mismatch")
            try require(id != "slush" || network.hasPrefix("sui:"), "connector network mismatch")
            try require(capabilities.contains(vendor ? "external_wallet" : id), "connector capability missing")
            let directions = try strings(connector, "directions"), methods = try strings(connector, "methods")
            var allowedMethods: Set<String> = ["list_accounts", "switch_network", "send_transaction"]
            if evm { allowedMethods.insert("sign_in_with_ethereum") }
            if solana { allowedMethods.insert("sign_in_with_solana") }
            try require(directions == [vendor ? "external_account_to_locus" : "locus_vault_to_dapp"] && !methods.isEmpty && methods.isSubset(of: allowedMethods), "unsupported connector direction or method")
            guard let reviewed = (review["connectors"] as? [[String: Any]] ?? []).first(where: { $0["connector"] as? String == id }) else { throw InputError.invalid("connector is not reviewed") }
            try require(reviewed["ownership"] as? String == connector["ownership"] as? String
                && directions.isSubset(of: strings(reviewed, "directions")) && methods.isSubset(of: strings(reviewed, "methods")), "connector exceeds signed review")
            var normalized = connector; normalized["directions"] = directions.sorted(); normalized["methods"] = methods.sorted()
            normalizedConnectors.append(normalized)
        }
        // Both provider identities are required for every enabled mainnet. The
        // independent binding validator below checks their exact sealed URLs.
        if mainnets.contains(network) {
            for provider in ["Alchemy", "QuickNode"] {
                let key = "LocusWallet\(provider)\(name)\(network.hasPrefix("sui:") ? "GraphQLURL" : "RPCURL")"
                let endpoint = try string(info, key).trimmingCharacters(in: .whitespacesAndNewlines)
                let rows = review["providerIdentities"] as? [[String: Any]] ?? []
                try require(rows.contains { $0["networkID"] as? String == network && $0["provider"] as? String == provider.lowercased()
                    && $0["endpointSHA256"] as? String == hash(Data(endpoint.utf8)) }, "enabled mainnet lacks a reviewed configured provider")
            }
        }
        output.append(["networkID": network, "capabilities": capabilities.sorted(), "connectors": try sortedObjects(normalizedConnectors)])
    }
    try require(!mainnets.isDisjoint(with: networks), "experimental mainnet requires at least one explicit mainnet")
    return output.sorted { ($0["networkID"] as! String) < ($1["networkID"] as! String) }
}

func writeExclusive(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try require(descriptor >= 0, "output already exists or cannot be created")
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            try require(count > 0, "output write failed; incomplete output must not be used")
            offset += count
        }
    }
    try require(fsync(descriptor) == 0, "output sync failed")
}

do {
    try require(CommandLine.arguments.count == 8, "usage: SignWalletExperimentalMainnet.swift app archive unsigned-capability signed-review signed-ceiling private-key-base64 NEW-output-history")
    let urls = try CommandLine.arguments.dropFirst().map(checkedURL)
    let app = urls[0], signer = try checkedURL(app.appendingPathComponent("Contents/XPCServices/WalletSigner.xpc").path)
    let appInfoURL = try checkedURL(app.appendingPathComponent("Contents/Info.plist").path)
    let signerInfoURL = try checkedURL(signer.appendingPathComponent("Contents/Info.plist").path)
    let appIdentity = try verifiedCodeIdentity(app, identifier: "io.sparktales.locus")
    let signerIdentity = try verifiedCodeIdentity(signer, identifier: "io.sparktales.locus.WalletSigner")
    let appInfo = try plist(appInfoURL), signerInfo = try plist(signerInfoURL)
    let source = try string(appInfo, "LocusSourceRevision"), version = try string(appInfo, "CFBundleVersion")
    try require(hex(source, 40) && version.utf8.count <= 64 && signerInfo["LocusSourceRevision"] as? String == source
        && signerInfo["CFBundleVersion"] as? String == version, "app and signer source/version differ")
    try require(!urls[5].path.hasPrefix(app.path + "/"), "private key must remain outside the app")
    let keyData = try readInput(urls[5], limit: 256, privateKey: true)
    guard let rawKey = Data(base64Encoded: String(decoding: keyData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), rawKey.count == 32 else { throw InputError.invalid("invalid external private key") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey), publicKey = key.publicKey
    try require(signerInfo["LocusWalletCapabilityPublicKey"] as? String == publicKey.rawRepresentation.base64EncodedString(), "external key does not match sealed verification key")
    let capBytes = try readInput(urls[2]), reviewBytes = try readInput(urls[3]), ceilingBytes = try readInput(urls[4])
    var cap = try object(capBytes)
    let signedReview = try object(reviewBytes), signedCeiling = try object(ceilingBytes)
    let review = try signedPayload(signedReview, field: "manifest", key: publicKey)
    let ceiling = try signedPayload(signedCeiling, field: "ceiling", key: publicKey)
    // The app loads authority from its nested signer. Reject a conflicting
    // outer override if present, but do not invent an outer configuration key.
    if appInfo["LocusWalletCapabilityPublicKey"] != nil || appInfo["LocusWalletReviewCeilingBase64"] != nil {
        try require(appInfo["LocusWalletCapabilityPublicKey"] as? String == publicKey.rawRepresentation.base64EncodedString()
            && appInfo["LocusWalletReviewCeilingBase64"] != nil, "outer authority override is incomplete or differs from signer")
    }
    for info in [signerInfo] + (appInfo["LocusWalletReviewCeilingBase64"] == nil ? [] : [appInfo]) {
        guard let encoded = info["LocusWalletReviewCeilingBase64"] as? String, let bytes = Data(base64Encoded: encoded) else { throw InputError.invalid("missing sealed review ceiling") }
        try require(canonical(object(bytes)) == canonical(signedCeiling), "supplied ceiling differs from sealed ceiling")
    }
    try runValidator("SignWalletReviewManifest.swift", ["--verify", urls[3].path, publicKey.rawRepresentation.base64EncodedString()])
    try runValidator("SignWalletReviewManifest.swift", ["--verify-ceiling", urls[4].path, publicKey.rawRepresentation.base64EncodedString()])
    try runValidator("VerifyWalletProviderBindings.py", [urls[3].path, appInfoURL.path])
    try require(readInput(urls[3]) == reviewBytes && readInput(urls[4]) == ceilingBytes, "signed input changed during validation")
    try exactKeys(cap, ["schemaVersion", "revision", "releaseStage", "evidenceIndexSHA256", "issuedAt", "expiresAt", "networkGrants", "approvedRegions", "completedApprovals", "canaryLimits"])
    let revision = try integer(cap, "revision"), issued = try string(cap, "issuedAt"), expires = try string(cap, "expiresAt")
    let formatter = ISO8601DateFormatter()
    guard let issueDate = formatter.date(from: issued), let expiry = formatter.date(from: expires),
          let reviewedAt = formatter.date(from: try string(ceiling, "reviewedAt")) else {
        throw InputError.invalid("invalid authority dates")
    }
    // The runtime uses the ceiling's review date as the earliest admissible
    // authority proof time. Reject unusable output before signing anything.
    try require(issueDate >= reviewedAt, "authority issue date predates the bundled review ceiling")
    try require(formatter.string(from: issueDate) == issued && formatter.string(from: expiry) == expires
        && issueDate <= Date() && expiry > Date() && expiry > issueDate && expiry.timeIntervalSince(issueDate) <= 31 * 86_400,
        "authority requires canonical current dates and a lease of at most 31 days")
    try require(integer(cap, "schemaVersion") == 3 && revision > 0 && cap["releaseStage"] as? String == "experimental_mainnet"
        && cap["evidenceIndexSHA256"] as? String == "" && strings(cap, "approvedRegions").isEmpty && strings(cap, "completedApprovals").isEmpty
        && (cap["canaryLimits"] as? [Any])?.isEmpty == true, "experimental authority cannot claim production approvals, regions, evidence or canary limits")
    try require(integer(review, "revision") == revision && review["issuedAt"] as? String == issued && review["expiresAt"] as? String == expires,
        "review and capability revision/timing must match exactly")
    let scope = try normalizedScope(review)
    guard let ceilingScope = ceiling["scope"] as? [String: Any] else { throw InputError.invalid("missing review ceiling scope") }
    try requireNarrowing(scope, ceiling: ceilingScope)
    cap["networkGrants"] = try validatedGrants(cap, review: review, info: appInfo)
    let archiveDigest = try archiveHash(urls[1]), ceilingDigest = try digest(ceiling)
    let installed: [String: Any] = ["sourceRevision": source, "bundleVersion": version,
        "outerAppCodeDirectoryHash": appIdentity.codeDirectoryHash, "signerCodeDirectoryHash": signerIdentity.codeDirectoryHash]
    let candidate = try digest(["installedIdentity": installed, "archiveSHA256": archiveDigest, "reviewCeilingSHA256": ceilingDigest])
    let authority = try digest(["networkGrants": cap["networkGrants"]!, "approvedRegions": [String](), "reviewScope": scope,
        "releaseStage": "experimental_mainnet", "canaryLimits": [Any](), "permanentLimits": [Any](), "admissionGeneration": 0, "revokedAdmissionSerials": [String]()])
    var envelope = installed
    envelope.merge(["schemaVersion": 2, "archiveSHA256": archiveDigest, "releaseStage": "experimental_mainnet", "issuedAt": issued,
        "expiresAt": expires, "revision": revision, "transition": "initial", "purpose": "experimental_mainnet", "candidateID": candidate,
        "reviewCeilingSHA256": ceilingDigest, "authoritySHA256": authority, "admissionGeneration": 0, "revokedAdmissionSerials": [String](),
        "permanentLimits": [Any](), "capabilityManifest": ["manifest": cap, "signatureBase64": try key.signature(for: canonical(cap)).base64EncodedString()],
        "reviewRestriction": signedReview]) { _, new in new }
    let signed: [String: Any] = ["envelope": envelope, "signatureBase64": try key.signature(for: canonical(envelope)).base64EncodedString()]
    try require(verifiedCodeIdentity(app, identifier: "io.sparktales.locus") == appIdentity
        && verifiedCodeIdentity(signer, identifier: "io.sparktales.locus.WalletSigner") == signerIdentity,
        "signed app changed during issuance")
    try writeExclusive(canonical(["schemaVersion": 1, "transitions": [signed]]), to: urls[6])
    print("Created initial experimental authority; no release approvals or packaging evidence claimed.")
} catch InputError.invalid(let message) {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8)); exit(1)
} catch {
    FileHandle.standardError.write(Data("error: experimental issuance failed; no authority may be inferred\n".utf8)); exit(1)
}
