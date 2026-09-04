import CryptoKit
import Foundation
import Security

struct WalletInstalledReleaseIdentity: Codable, Equatable, Sendable {
    let sourceRevision: String
    let bundleVersion: String
    let outerAppCodeDirectoryHash: String
    let signerCodeDirectoryHash: String

    static func current(appBundle: Bundle = .main) -> Self? {
        let signerURL = appBundle.bundleURL
            .appendingPathComponent("Contents/XPCServices/WalletSigner.xpc")
        guard let sourceRevision = appBundle.object(
            forInfoDictionaryKey: "LocusSourceRevision"
        ) as? String,
        let bundleVersion = appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        let outerHash = codeDirectoryHash(at: appBundle.bundleURL),
        let signerHash = codeDirectoryHash(at: signerURL) else { return nil }
        return Self(
            sourceRevision: sourceRevision,
            bundleVersion: bundleVersion,
            outerAppCodeDirectoryHash: outerHash,
            signerCodeDirectoryHash: signerHash
        )
    }

    static func current(signerBundle: Bundle) -> Self? {
        let signerURL = signerBundle.bundleURL
        let appURL = signerURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let appBundle = Bundle(url: appURL),
              let sourceRevision = signerBundle.object(
                forInfoDictionaryKey: "LocusSourceRevision"
              ) as? String,
              let bundleVersion = appBundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let outerHash = codeDirectoryHash(at: appURL),
              let signerHash = codeDirectoryHash(at: signerURL) else { return nil }
        return Self(
            sourceRevision: sourceRevision,
            bundleVersion: bundleVersion,
            outerAppCodeDirectoryHash: outerHash,
            signerCodeDirectoryHash: signerHash
        )
    }

    private static func codeDirectoryHash(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        let hash = values[kSecCodeInfoUnique] as? Data,
        !hash.isEmpty else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

struct WalletReleaseActivationEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let sourceRevision: String
    let bundleVersion: String
    let outerAppCodeDirectoryHash: String
    let signerCodeDirectoryHash: String
    let archiveSHA256: String
    let releaseStage: WalletReleaseStage
    let issuedAt: Date
    let expiresAt: Date
    let revision: Int
    let capabilityManifest: WalletSignedCapabilityManifest
    let reviewRestriction: WalletSignedReviewManifest
}

struct WalletSignedReleaseActivationEnvelope: Codable, Equatable, Sendable {
    let envelope: WalletReleaseActivationEnvelope
    let signatureBase64: String
}

struct WalletVerifiedReleaseActivation: Sendable {
    let signedEnvelope: WalletSignedReleaseActivationEnvelope
    let launchGate: WalletLaunchGate
    let reviewRegistry: WalletReviewRegistry

    var envelopeSHA256: String {
        // Verification already proved that this envelope is encodable.
        WalletReleaseActivationVerifier.digest(signedEnvelope.envelope)
    }
}

enum WalletReleaseActivationError: LocalizedError, Equatable {
    case malformed
    case invalidSignature
    case expired
    case identityMismatch
    case rollback
    case broaderThanCeiling
    case revisionConflict
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .malformed: "The wallet release activation is malformed."
        case .invalidSignature: "The wallet release activation signature is invalid."
        case .expired: "The wallet release activation has expired."
        case .identityMismatch: "The wallet release activation belongs to a different build."
        case .rollback: "An older wallet release activation was rejected."
        case .broaderThanCeiling: "The wallet release activation exceeds this build's review ceiling."
        case .revisionConflict: "The wallet activation revision was reused for different release data."
        case .stateUnavailable: "Wallet activation history is unavailable."
        }
    }
}

enum WalletReleaseActivationVerifier {
    static let maximumEnvelopeBytes = 1_048_576

    static func verify(
        _ signed: WalletSignedReleaseActivationEnvelope,
        publicKey: Curve25519.Signing.PublicKey,
        bundledReviewCeiling: WalletReviewRegistry,
        installedIdentity: WalletInstalledReleaseIdentity,
        minimumRevision: Int = 0,
        acceptedEnvelopeSHA256: String? = nil,
        now: Date = Date()
    ) throws -> WalletVerifiedReleaseActivation {
        let value = signed.envelope
        guard value.schemaVersion == WalletReleaseActivationEnvelope.schemaVersion,
              value.revision > 0,
              value.revision >= minimumRevision,
              value.issuedAt <= now,
              value.expiresAt > value.issuedAt,
              value.expiresAt.timeIntervalSince(value.issuedAt) <= 31 * 24 * 60 * 60,
              validHex(value.sourceRevision, lengths: 40...64),
              !value.bundleVersion.isEmpty, value.bundleVersion.utf8.count <= 64,
              validHex(value.outerAppCodeDirectoryHash, lengths: 40...64),
              validHex(value.signerCodeDirectoryHash, lengths: 40...64),
              validHex(value.archiveSHA256, lengths: 64...64),
              value.capabilityManifest.manifest.revision == value.revision,
              value.reviewRestriction.manifest.revision == value.revision,
              value.capabilityManifest.manifest.releaseStage == value.releaseStage,
              value.capabilityManifest.manifest.issuedAt >= value.issuedAt,
              value.capabilityManifest.manifest.expiresAt <= value.expiresAt,
              value.reviewRestriction.manifest.issuedAt >= value.issuedAt,
              value.reviewRestriction.manifest.expiresAt <= value.expiresAt else {
            if value.revision < minimumRevision { throw WalletReleaseActivationError.rollback }
            throw WalletReleaseActivationError.malformed
        }
        guard value.expiresAt > now else { throw WalletReleaseActivationError.expired }
        if value.revision == minimumRevision, let acceptedEnvelopeSHA256,
           digest(value) != acceptedEnvelopeSHA256 {
            throw WalletReleaseActivationError.revisionConflict
        }
        guard value.sourceRevision == installedIdentity.sourceRevision,
              value.bundleVersion == installedIdentity.bundleVersion,
              value.outerAppCodeDirectoryHash == installedIdentity.outerAppCodeDirectoryHash,
              value.signerCodeDirectoryHash == installedIdentity.signerCodeDirectoryHash else {
            throw WalletReleaseActivationError.identityMismatch
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(value)
        guard payload.count <= maximumEnvelopeBytes,
              let signature = Data(base64Encoded: signed.signatureBase64),
              publicKey.isValidSignature(signature, for: payload) else {
            throw WalletReleaseActivationError.invalidSignature
        }
        let launchGate = try WalletLaunchGate(
            signedManifest: value.capabilityManifest,
            publicKey: publicKey,
            now: now
        )
        let limits = value.capabilityManifest.manifest.canaryLimits ?? []
        guard limits.count <= 10_000,
              Set(limits.map(\.identity)).count == limits.count,
              limits.allSatisfy(WalletCanaryBudget.valid) else {
            throw WalletReleaseActivationError.malformed
        }
        let reviewRegistry: WalletReviewRegistry
        do {
            reviewRegistry = try bundledReviewCeiling.restricted(
                by: value.reviewRestriction,
                publicKey: publicKey,
                now: now
            )
        } catch WalletReviewManifestError.broaderThanBundledReview {
            throw WalletReleaseActivationError.broaderThanCeiling
        } catch {
            throw WalletReleaseActivationError.malformed
        }
        for grant in value.capabilityManifest.manifest.networkGrants {
            guard let network = WalletNetworkCatalog.descriptor(id: grant.networkID),
                  network.environment == .mainnet else { continue }
            guard Set(reviewRegistry.manifest.providerIdentities.filter {
                $0.networkID == network.id
            }.map(\.provider)).isSuperset(of: [.alchemy, .quickNode]) else {
                throw WalletReleaseActivationError.broaderThanCeiling
            }
            if value.releaseStage == .invitedCanary {
                guard limits.contains(where: { $0.networkID == network.id }) else {
                    throw WalletReleaseActivationError.malformed
                }
                for limit in limits where limit.networkID == network.id {
                    guard limit.assetID == network.nativeAssetID
                            || reviewRegistry.assets.contains(where: { $0.id == limit.assetID }) else {
                        throw WalletReleaseActivationError.broaderThanCeiling
                    }
                }
            }
        }
        return WalletVerifiedReleaseActivation(
            signedEnvelope: signed,
            launchGate: launchGate,
            reviewRegistry: reviewRegistry
        )
    }

    static func digest(_ envelope: WalletReleaseActivationEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validHex(_ value: String, lengths: ClosedRange<Int>) -> Bool {
        lengths.contains(value.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum WalletCanaryBudget {
    private static let lock = NSLock()
    struct Usage: Codable, Equatable {
        var amount = "0"
        var fees = "0"
        var transactions = 0
    }

    static func valid(_ limit: WalletCanaryLimit) -> Bool {
        guard WalletNetworkCatalog.descriptor(id: limit.networkID) != nil,
              !limit.assetID.isEmpty, limit.assetID.utf8.count <= 512,
              [.nativeTransfer, .fungibleTokenTransfer, .nftTransfer,
               .exactInputSwap, .swapAllowanceSetup].contains(limit.action),
              [limit.maximumTransactionBaseUnits, limit.maximumCumulativeBaseUnits,
               limit.maximumFeeBaseUnits, limit.maximumCumulativeFeeBaseUnits]
                .allSatisfy({ canonical($0) && $0 != "0" }),
              lessOrEqual(limit.maximumTransactionBaseUnits, limit.maximumCumulativeBaseUnits),
              lessOrEqual(limit.maximumFeeBaseUnits, limit.maximumCumulativeFeeBaseUnits),
              (1...1_000_000).contains(limit.maximumTransactions) else { return false }
        if limit.ownership == .locusVault { return limit.connector == nil }
        guard let connector = limit.connector,
              [.metamask, .phantom, .slush].contains(connector) else { return false }
        return limit.ownership == .required(for: connector)
    }

    static func next(_ usage: Usage, amount: String, fee: String,
                     limit: WalletCanaryLimit) throws -> Usage {
        guard valid(limit), canonical(amount), canonical(fee),
              canonical(usage.amount), canonical(usage.fees), usage.transactions >= 0,
              lessOrEqual(amount, limit.maximumTransactionBaseUnits),
              lessOrEqual(fee, limit.maximumFeeBaseUnits),
              let total = add(usage.amount, amount), let fees = add(usage.fees, fee),
              lessOrEqual(total, limit.maximumCumulativeBaseUnits),
              lessOrEqual(fees, limit.maximumCumulativeFeeBaseUnits),
              usage.transactions < limit.maximumTransactions else {
            throw WalletReleaseActivationError.broaderThanCeiling
        }
        return Usage(amount: total, fees: fees, transactions: usage.transactions + 1)
    }

    /// Reserve before releasing signed bytes / submitting to an external
    /// wallet. Failed or ambiguous submissions retain the reservation.
    static func reserve(transaction: WalletPreparedTransaction,
                        ownership: WalletConnectorAccountOwnership,
                        connector: WalletConnectionConnector?,
                        manifest: WalletCapabilityManifest?, sourceRevision: String,
                        signerOwned: Bool) throws {
        guard WalletNetworkCatalog.descriptor(id: transaction.networkID)?.environment == .mainnet
        else { return }
        guard let manifest, manifest.expiresAt > Date() else {
            throw WalletReleaseActivationError.expired
        }
        guard manifest.releaseStage == .invitedCanary else { return }
        let assetID = transaction.action.swapAllowanceSetup?.binding.inputAssetID
            ?? transaction.budgetAssetID
        let amount = transaction.action.swapAllowanceSetup?.binding.amountInBaseUnits
            ?? transaction.spendBaseUnits
        guard !sourceRevision.isEmpty,
              signerOwned == (ownership == .locusVault),
              let limit = manifest.canaryLimits?.first(where: {
                  $0.networkID == transaction.networkID && $0.assetID == assetID
                    && $0.action == transaction.action.type && $0.ownership == ownership
                    && $0.connector == connector
              }) else { throw WalletReleaseActivationError.broaderThanCeiling }
        let account = SHA256.hash(data: Data((sourceRevision + "|" + limit.identity).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let service = "io.sparktales.locus.wallet-canary-budget.v1"
        var query = WalletVaultKeychainQuery.base(service: service, account: account)
        if !signerOwned {
            query[kSecAttrAccessGroup as String] = "4X4RJA7GMD.io.sparktales.locus"
        }
        lock.lock()
        defer { lock.unlock() }
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        let usage: Usage
        if status == errSecItemNotFound { usage = Usage() }
        else if status == errSecSuccess, let data = result as? Data,
                let decoded = try? JSONDecoder().decode(Usage.self, from: data) { usage = decoded }
        else { throw WalletReleaseActivationError.stateUnavailable }
        let updated = try next(usage, amount: amount,
                               fee: transaction.maximumFeeBaseUnits, limit: limit)
        let bytes = try JSONEncoder().encode(updated)
        let writeStatus: OSStatus
        if status == errSecItemNotFound {
            query[kSecValueData as String] = bytes
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            writeStatus = SecItemAdd(query as CFDictionary, nil)
        } else {
            writeStatus = SecItemUpdate(query as CFDictionary,
                [kSecValueData as String: bytes] as CFDictionary)
        }
        guard writeStatus == errSecSuccess else { throw WalletReleaseActivationError.stateUnavailable }
    }

    private static func canonical(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 78 && (value == "0" || value.first != "0")
            && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func lessOrEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs <= rhs : lhs.count < rhs.count
    }
    private static func add(_ lhs: String, _ rhs: String) -> String? {
        var a = Array(lhs.utf8.reversed()), b = Array(rhs.utf8.reversed())
        let count = max(a.count, b.count)
        a += Array(repeating: 48, count: count - a.count)
        b += Array(repeating: 48, count: count - b.count)
        var result: [UInt8] = [], carry: UInt8 = 0
        for index in 0..<count {
            let total = a[index] - 48 + b[index] - 48 + carry
            result.append(total % 10 + 48)
            carry = total / 10
        }
        if carry > 0 { result.append(carry + 48) }
        guard result.count <= 78 else { return nil }
        return String(decoding: result.reversed(), as: UTF8.self)
    }
}

struct WalletReleaseActivationSource {
    static func endpoint(bundle: Bundle = .main) -> URL? {
        guard let value = bundle.object(
            forInfoDictionaryKey: "LocusWalletReleaseActivationURL"
        ) as? String,
        let url = URL(string: value), url.scheme == "https", url.host != nil,
        url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    static func fetch(from url: URL, session: URLSession? = nil) async throws -> Data {
        guard url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw WalletReleaseActivationError.malformed
        }
        let client = session ?? URLSession(configuration: .ephemeral)
        defer { if session == nil { client.finishTasksAndInvalidate() } }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        let (bytes, response) = try await client.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme == "https",
              response.expectedContentLength <= WalletReleaseActivationVerifier.maximumEnvelopeBytes else {
            throw WalletReleaseActivationError.malformed
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < WalletReleaseActivationVerifier.maximumEnvelopeBytes else {
                throw WalletReleaseActivationError.malformed
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw WalletReleaseActivationError.malformed }
        return data
    }
}

enum WalletReleaseActivationCache {
    static func load(fileManager: FileManager = .default) -> Data? {
        guard let url = try? cacheURL(fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              data.count <= WalletReleaseActivationVerifier.maximumEnvelopeBytes else {
            return nil
        }
        return data
    }

    static func store(_ data: Data, fileManager: FileManager = .default) throws {
        guard !data.isEmpty,
              data.count <= WalletReleaseActivationVerifier.maximumEnvelopeBytes else {
            throw WalletReleaseActivationError.malformed
        }
        let url = try cacheURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func remove(fileManager: FileManager = .default) {
        guard let url = try? cacheURL(fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func cacheURL(fileManager: FileManager) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Locus/WalletReleaseActivation-v1.json")
    }
}

/// Signer-owned monotonic state. The Direct host lacks this Keychain access
/// group, so it cannot lower the accepted activation revision.
enum WalletSignerActivationRevisionStore {
    private static let service = "io.sparktales.locus.WalletSigner.activation"
    private static let mutationLock = NSLock()

    struct Accepted: Codable, Equatable {
        let revision: Int
        let envelopeSHA256: String
    }

    static func load() throws -> Accepted? {
        var query = WalletVaultKeychainQuery.base(service: service, account: "")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let records = result as? [Data],
              records.count <= 4_096 else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let decoded: [Accepted]
        do { decoded = try records.map { try JSONDecoder().decode(Accepted.self, from: $0) } }
        catch { throw WalletReleaseActivationError.stateUnavailable }
        return try highestAccepted(decoded)
    }

    static func highestAccepted(_ records: [Accepted]) throws -> Accepted? {
        var byRevision: [Int: String] = [:]
        var highest: Accepted?
        for value in records {
            guard value.revision > 0, value.envelopeSHA256.count == 64,
                  value.envelopeSHA256.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }) else { throw WalletReleaseActivationError.stateUnavailable }
            if let digest = byRevision[value.revision], digest != value.envelopeSHA256 {
                throw WalletReleaseActivationError.revisionConflict
            }
            byRevision[value.revision] = value.envelopeSHA256
            if highest == nil || value.revision > highest!.revision { highest = value }
        }
        return highest
    }

    static func store(_ accepted: Accepted) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        _ = try highestAccepted([accepted])
        if let previous = try load() {
            guard accepted.revision >= previous.revision else {
                throw WalletReleaseActivationError.rollback
            }
            if accepted.revision == previous.revision {
                guard accepted == previous else { throw WalletReleaseActivationError.revisionConflict }
                return
            }
        }
        let value = try JSONEncoder().encode(accepted)
        // Append immutable per-revision records. Concurrent signer processes
        // cannot overwrite a newer high-water mark with an older value. Legacy
        // highest-revision-v1 records are still read, but never mutated.
        let status = SecItemAdd(
            WalletVaultKeychainQuery.add(
                service: service, account: "revision-\(accepted.revision)", keyData: value
            ) as CFDictionary,
            nil
        )
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        guard try load() == accepted else { throw WalletReleaseActivationError.rollback }
    }
}
