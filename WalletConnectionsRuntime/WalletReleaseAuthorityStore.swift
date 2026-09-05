import Foundation
import Security

/// All persisted data here is signer-owned authority, never public-wallet DB
/// metadata. Append-only records make an interrupted/late writer fail closed.
enum WalletSignerReleaseAuthorityStore {
    private static let service = "io.sparktales.locus.WalletSigner.authority.v2"
    private static let identityService = "io.sparktales.locus.WalletSigner.installation.v1"
    private static let admissionService = "io.sparktales.locus.WalletSigner.admissions.v1"
    private static let lock = NSLock()

    static func installationID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let query = WalletVaultKeychainQuery.base(service: identityService, account: "installation")
        if let bytes = try read(query) {
            guard bytes.count == 32 else { throw WalletReleaseActivationError.stateUnavailable }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let result = SecItemAdd(WalletVaultKeychainQuery.add(service: identityService,
            account: "installation", keyData: Data(bytes)) as CFDictionary, nil)
        guard result == errSecSuccess || result == errSecDuplicateItem,
              let stored = try read(query), stored.count == 32 else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        return stored.map { String(format: "%02x", $0) }.joined()
    }

    static func load() throws -> WalletReleaseAuthorityCheckpoint? {
        // Inspect only account attributes first. Do not read every historical
        // manifest into memory just to determine the monotonic high-water mark.
        var query = WalletVaultKeychainQuery.base(service: service, account: "")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let records = result as? [[String: Any]], records.count <= 4_096 else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        var highest = 0
        for record in records {
            guard let account = record[kSecAttrAccount as String] as? String,
                  account.hasPrefix("revision-"), let revision = Int(account.dropFirst(9)),
                  revision > 0, account == "revision-\(revision)" else {
                throw WalletReleaseActivationError.stateUnavailable
            }
            highest = max(highest, revision)
        }
        guard highest > 0, let bytes = try read(WalletVaultKeychainQuery.base(
            service: service, account: "revision-\(highest)")),
              bytes.count <= WalletReleaseHistoryVerifier.maximumHistoryBytes else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(WalletReleaseAuthorityCheckpoint.self, from: bytes)
        guard value.revision == highest, WalletAuthorityEncoding.hex(value.digest) else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        return .init(signedTransition: value.signedTransition,
            admission: try loadAdmission(candidateID: value.signedTransition.envelope.candidateID),
            retiredCandidateIDs: value.retiredCandidateIDs)
    }

    static func store(_ checkpoint: WalletReleaseAuthorityCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if let prior = try load() {
            guard checkpoint.revision >= prior.revision else { throw WalletReleaseActivationError.rollback }
            if checkpoint.revision == prior.revision {
                guard checkpoint.signedTransition == prior.signedTransition,
                      checkpoint.retiredCandidateIDs == prior.retiredCandidateIDs else {
                    throw WalletReleaseActivationError.revisionConflict
                }
                if let admission = checkpoint.admission {
                    try storeAdmission(admission, envelope: checkpoint.signedTransition.envelope)
                }
                return
            }
        }
        let bytes = try WalletAuthorityEncoding.encode(WalletReleaseAuthorityCheckpoint(
            signedTransition: checkpoint.signedTransition, admission: nil,
            retiredCandidateIDs: checkpoint.retiredCandidateIDs))
        guard checkpoint.revision > 0, WalletAuthorityEncoding.hex(checkpoint.digest),
              bytes.count <= WalletReleaseHistoryVerifier.maximumHistoryBytes else {
            throw WalletReleaseActivationError.malformed
        }
        let status = SecItemAdd(WalletVaultKeychainQuery.add(service: service,
            account: "revision-\(checkpoint.revision)", keyData: bytes) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        if let admission = checkpoint.admission {
            try storeAdmission(admission, envelope: checkpoint.signedTransition.envelope)
        }
        guard try load() == checkpoint else { throw WalletReleaseActivationError.rollback }
    }

    private static func loadAdmission(candidateID: String) throws -> WalletSignedCanaryAdmission? {
        var query = WalletVaultKeychainQuery.base(service: admissionService, account: "")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let records = result as? [Data], records.count <= 128 else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var latest: WalletSignedCanaryAdmission?
        for bytes in records {
            guard bytes.count <= 1_048_576 else { throw WalletReleaseActivationError.stateUnavailable }
            let value = try decoder.decode(WalletSignedCanaryAdmission.self, from: bytes)
            guard value.admission.candidateID == candidateID else { continue }
            if let prior = latest {
                if value.admission.generation == prior.admission.generation,
                   value.admission.issuedAt == prior.admission.issuedAt,
                   value.admission != prior.admission { throw WalletReleaseActivationError.revisionConflict }
                if value.admission.generation < prior.admission.generation
                    || (value.admission.generation == prior.admission.generation
                        && value.admission.issuedAt < prior.admission.issuedAt) { continue }
            }
            latest = value
        }
        return latest
    }

    private static func storeAdmission(_ signed: WalletSignedCanaryAdmission,
                                        envelope: WalletReleaseTransitionEnvelope) throws {
        let value = signed.admission
        if let previous = try loadAdmission(candidateID: value.candidateID) {
            if previous.admission == value { return }
            let old = previous.admission
            guard value.generation >= old.generation, value.issuedAt > old.issuedAt else {
                throw WalletReleaseActivationError.rollback
            }
            if value.generation == old.generation {
                guard value.serial == old.serial, value.allocation == old.allocation,
                      value.expiresAt >= old.expiresAt else { throw WalletReleaseActivationError.broaderThanCeiling }
            } else {
                guard envelope.revokedAdmissionSerials.contains(old.serial) else {
                    throw WalletReleaseActivationError.admissionRequired
                }
            }
        }
        let bytes = try WalletAuthorityEncoding.encode(signed)
        let account = try WalletAuthorityEncoding.digest(value)
        let status = SecItemAdd(WalletVaultKeychainQuery.add(service: admissionService,
            account: account, keyData: bytes) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem,
              try loadAdmission(candidateID: value.candidateID)?.admission == value else {
            throw WalletReleaseActivationError.stateUnavailable
        }
    }

    private static func read(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        return data
    }
}

struct WalletReleaseAuthorityStatus: Codable, Equatable, Sendable {
    let installationID: String
    let checkpoint: WalletReleaseAuthorityCheckpoint?
}
