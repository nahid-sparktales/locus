import CryptoKit
import Foundation
import Security

/// Only the separate, sealed experimental app/signer build can opt into this
/// channel. Environment variables and public wallet preferences grant nothing.
enum WalletExperimentalMainnetBuild {
    static func isEnabled(bundle: Bundle = .main) -> Bool {
        #if LOCUS_EXPERIMENTAL_MAINNET && !LOCUS_APP_STORE
        return bundle.object(forInfoDictionaryKey: "LocusWalletExperimentalMainnetEnabled") as? Bool == true
        #else
        return false
        #endif
    }

    static var authorityStorageSuffix: String { isEnabled() ? ".experimental-mainnet" : "" }
}

enum WalletAuthorityEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ value: String, count: Int = 64) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func sorted<T: Encodable>(_ values: [T]) -> [T] {
        values.sorted {
            (try? encode($0).lexicographicallyPrecedes(encode($1))) == true
        }
    }

    static func verify<T: Encodable>(_ value: T, signature: String,
                                     key: Curve25519.Signing.PublicKey) throws {
        guard let bytes = Data(base64Encoded: signature), bytes.count == 64,
              key.isValidSignature(bytes, for: try encode(value)) else {
            throw WalletReleaseActivationError.invalidSignature
        }
    }
}

/// Scope has no operational timestamps. In particular, it is NOT decodable
/// as a WalletReviewManifest and cannot activate an account or a network.
struct WalletReviewScope: Codable, Equatable, Sendable {
    let assets: [WalletAsset]
    let evmContracts: [WalletContractRegistryEntry]
    let explorerTemplates: [String: String]
    let adapterIDs: [String]
    let connectors: [WalletReviewedConnector]
    let providerIdentities: [WalletReviewedProviderIdentity]
    let signInAdapters: [WalletReviewedSignInAdapter]
    let programIdentities: [WalletReviewedProgramIdentity]
    let uniswapConfigurations: [WalletReviewedUniswapConfiguration]

    init(_ manifest: WalletReviewManifest) {
        assets = WalletAuthorityEncoding.sorted(manifest.assets.map { Self.asset($0, revision: 1) })
        evmContracts = WalletAuthorityEncoding.sorted(manifest.evmContracts)
        explorerTemplates = manifest.explorerTemplates
        adapterIDs = manifest.adapterIDs.sorted()
        connectors = WalletAuthorityEncoding.sorted(manifest.connectors)
        providerIdentities = WalletAuthorityEncoding.sorted(manifest.providerIdentities)
        signInAdapters = WalletAuthorityEncoding.sorted(manifest.signInAdapters)
        programIdentities = WalletAuthorityEncoding.sorted(manifest.programIdentities)
        uniswapConfigurations = WalletAuthorityEncoding.sorted(manifest.uniswapConfigurations)
    }

    func registry(revision: Int, issuedAt: Date, expiresAt: Date, now: Date) throws -> WalletReviewRegistry {
        let manifest = WalletReviewManifest(schemaVersion: 2, revision: revision,
            issuedAt: issuedAt, expiresAt: expiresAt,
            assets: assets.map { Self.asset($0, revision: revision) }, evmContracts: evmContracts,
            explorerTemplates: explorerTemplates, adapterIDs: Set(adapterIDs), connectors: connectors,
            providerIdentities: providerIdentities, signInAdapters: signInAdapters,
            programIdentities: programIdentities, uniswapConfigurations: uniswapConfigurations)
        guard Self(manifest) == self else { throw WalletReleaseActivationError.malformed }
        return try WalletReviewRegistry(validatingScopeProjection: manifest, now: now)
    }

    private static func asset(_ value: WalletAsset, revision: Int) -> WalletAsset {
        .init(canonicalID: value.canonicalID, networkID: value.networkID, chain: value.chain,
            kind: value.kind, reference: value.reference, name: value.name, symbol: value.symbol,
            decimals: value.decimals, trust: value.trust, manifestRevision: revision)
    }
}

struct WalletReviewCeiling: Codable, Equatable, Sendable {
    static let domain = "locus-wallet-review-ceiling-v1"
    let schemaVersion: Int
    let domain: String
    let reviewRevision: Int
    let reviewedAt: Date
    let scope: WalletReviewScope
}

struct WalletSignedReviewCeiling: Codable, Equatable, Sendable {
    let ceiling: WalletReviewCeiling
    let signatureBase64: String

    func verify(key: Curve25519.Signing.PublicKey, now: Date = Date()) throws {
        guard ceiling.schemaVersion == 1, ceiling.domain == WalletReviewCeiling.domain,
              ceiling.reviewRevision > 0, ceiling.reviewedAt <= now,
              try WalletAuthorityEncoding.encode(self).count <= 1_048_576 else {
            throw WalletReleaseActivationError.malformed
        }
        try WalletAuthorityEncoding.verify(ceiling, signature: signatureBase64, key: key)
        _ = try ceiling.scope.registry(revision: ceiling.reviewRevision,
            issuedAt: now, expiresAt: now.addingTimeInterval(1), now: now)
    }

    static func loadBundled(bundle: Bundle = .main) -> Self? {
        let authority = bundle.object(forInfoDictionaryKey: "LocusWalletCapabilityPublicKey") != nil
            ? bundle : Bundle(url: bundle.bundleURL.appendingPathComponent("Contents/XPCServices/WalletSigner.xpc"))
        guard let authority,
              let text = authority.object(forInfoDictionaryKey: "LocusWalletReviewCeilingBase64") as? String,
              let bytes = Data(base64Encoded: text), bytes.count <= 1_048_576,
              let keyText = authority.object(forInfoDictionaryKey: "LocusWalletCapabilityPublicKey") as? String,
              let keyBytes = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Self.self, from: bytes),
              (try? value.verify(key: key)) != nil else { return nil }
        return value
    }

    /// Pin/configuration inspection only. This projection is never an
    /// activating capability, and must not replace the current signed review
    /// restriction in preparation, submission, or reconciliation.
    static func bundledConfigurationRegistry(bundle: Bundle = .main, now: Date = Date()) -> WalletReviewRegistry? {
        guard let value = loadBundled(bundle: bundle) else { return nil }
        return try? value.ceiling.scope.registry(revision: value.ceiling.reviewRevision,
            issuedAt: now, expiresAt: now.addingTimeInterval(1), now: now)
    }
}

enum WalletReleaseTransitionKind: String, Codable, Sendable {
    case initial, renewal, restriction, promotion
}

enum WalletReleasePurpose: String, Codable, Sendable {
    case production
    case testnetRehearsal = "testnet_rehearsal"
    case experimentalMainnet = "experimental_mainnet"
}

struct WalletReleaseTransitionEnvelope: Codable, Equatable, Sendable {
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
    let transition: WalletReleaseTransitionKind
    let purpose: WalletReleasePurpose
    let candidateID: String
    let reviewCeilingSHA256: String
    let previousEnvelopeSHA256: String?
    let authoritySHA256: String
    let cohortID: String?
    let admissionGeneration: Int
    let revokedAdmissionSerials: [String]
    let permanentLimits: [WalletCanaryLimit]

    var installedIdentity: WalletInstalledReleaseIdentity {
        .init(sourceRevision: sourceRevision, bundleVersion: bundleVersion,
              outerAppCodeDirectoryHash: outerAppCodeDirectoryHash,
              signerCodeDirectoryHash: signerCodeDirectoryHash)
    }

    func computedCandidateID() throws -> String {
        struct Candidate: Encodable {
            let installedIdentity: WalletInstalledReleaseIdentity
            let archiveSHA256: String
            let reviewCeilingSHA256: String
        }
        return try WalletAuthorityEncoding.digest(Candidate(installedIdentity: installedIdentity,
            archiveSHA256: archiveSHA256, reviewCeilingSHA256: reviewCeilingSHA256))
    }

    func computedAuthoritySHA256() throws -> String {
        struct Authority: Encodable {
            let networkGrants: [WalletNetworkCapabilityGrant]
            let approvedRegions: [String]
            let reviewScope: WalletReviewScope
            let releaseStage: WalletReleaseStage
            let canaryLimits: [WalletCanaryLimit]
            let permanentLimits: [WalletCanaryLimit]
            let cohortID: String?
            let admissionGeneration: Int
            let revokedAdmissionSerials: [String]
        }
        return try WalletAuthorityEncoding.digest(Authority(
            networkGrants: Self.normalizedGrants(capabilityManifest.manifest.networkGrants),
            approvedRegions: capabilityManifest.manifest.approvedRegions.sorted(),
            reviewScope: WalletReviewScope(reviewRestriction.manifest), releaseStage: releaseStage,
            canaryLimits: WalletAuthorityEncoding.sorted(capabilityManifest.manifest.canaryLimits ?? []),
            permanentLimits: WalletAuthorityEncoding.sorted(permanentLimits), cohortID: cohortID,
            admissionGeneration: admissionGeneration, revokedAdmissionSerials: revokedAdmissionSerials))
    }

    static func normalizedGrants(_ grants: [WalletNetworkCapabilityGrant]) -> [WalletNetworkCapabilityGrant] {
        grants.map { .init(networkID: $0.networkID, capabilities: $0.capabilities,
            connectors: WalletAuthorityEncoding.sorted($0.connectors)) }.sorted { $0.networkID < $1.networkID }
    }
}

struct WalletSignedReleaseTransition: Codable, Equatable, Sendable {
    let envelope: WalletReleaseTransitionEnvelope
    let signatureBase64: String
    var digest: String { (try? WalletAuthorityEncoding.digest(envelope)) ?? "" }
}

struct WalletCanaryAdmission: Codable, Equatable, Sendable {
    static let domain = "locus-wallet-canary-admission-v1"
    let schemaVersion: Int
    let domain: String
    let candidateID: String
    let cohortID: String
    let installationID: String
    let serial: String
    let generation: Int
    let issuedAt: Date
    let expiresAt: Date
    let allocation: [WalletCanaryLimit]
}

struct WalletSignedCanaryAdmission: Codable, Equatable, Sendable {
    let admission: WalletCanaryAdmission
    let signatureBase64: String
}

struct WalletReleaseHistoryRequest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let transitions: [WalletSignedReleaseTransition]
    let admission: WalletSignedCanaryAdmission?
}

struct WalletReleaseAuthorityCheckpoint: Codable, Equatable, Sendable {
    let signedTransition: WalletSignedReleaseTransition
    let admission: WalletSignedCanaryAdmission?
    var retiredCandidateIDs: [String] = []
    var revision: Int { signedTransition.envelope.revision }
    var digest: String { signedTransition.digest }
}

extension WalletReleaseAuthorityCheckpoint {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(signedTransition: try values.decode(WalletSignedReleaseTransition.self, forKey: .signedTransition),
            admission: try values.decodeIfPresent(WalletSignedCanaryAdmission.self, forKey: .admission),
            retiredCandidateIDs: try values.decodeIfPresent([String].self, forKey: .retiredCandidateIDs) ?? [])
    }
}

struct WalletVerifiedReleaseAuthority: Sendable {
    let checkpoint: WalletReleaseAuthorityCheckpoint
    let launchGate: WalletLaunchGate
    let reviewRegistry: WalletReviewRegistry

    var authorityExpiresAt: Date {
        let envelope = checkpoint.signedTransition.envelope
        guard envelope.purpose == .production, envelope.releaseStage == .invitedCanary else {
            return envelope.expiresAt
        }
        return min(envelope.expiresAt, checkpoint.admission?.admission.expiresAt ?? envelope.expiresAt)
    }

    func requireAdmission(installationID: String, now: Date = Date()) throws {
        let envelope = checkpoint.signedTransition.envelope
        guard envelope.releaseStage == .invitedCanary, envelope.purpose == .production else { return }
        guard let value = checkpoint.admission?.admission,
              value.installationID == installationID, value.issuedAt <= now, value.expiresAt > now,
              value.candidateID == envelope.candidateID, value.cohortID == envelope.cohortID,
              value.generation == envelope.admissionGeneration,
              !envelope.revokedAdmissionSerials.contains(value.serial) else {
            throw WalletReleaseActivationError.admissionRequired
        }
    }

    /// Admission and emergency limits remain narrower than operational grants.
    /// Return a manifest for the existing cumulative Keychain reservation code.
    func budgetManifest() -> WalletCapabilityManifest {
        var manifest = checkpoint.signedTransition.envelope.capabilityManifest.manifest
        let permanent = checkpoint.signedTransition.envelope.permanentLimits
        if let allocation = checkpoint.admission?.admission.allocation,
           manifest.releaseStage == .invitedCanary {
            manifest.canaryLimits = WalletReleaseHistoryVerifier.intersectLimits(
                manifest.canaryLimits ?? [], allocation)
        }
        if !permanent.isEmpty {
            if manifest.releaseStage == .invitedCanary {
                manifest.canaryLimits = WalletReleaseHistoryVerifier.intersectLimits(
                    manifest.canaryLimits ?? [], permanent, preserveUnmentioned: true)
            } else {
                // GA still reserves permanent emergency caps; callers use the
                // reservation override instead of dropping these restrictions.
                manifest.canaryLimits = permanent
            }
        }
        return manifest
    }
}

enum WalletReleaseHistoryVerifier {
    static let maximumHistoryBytes = 16 * 1_048_576
    static let maximumTransitions = 64
    static let mainnets: Set<String> = ["eip155:1", "solana:mainnet-beta", "sui:mainnet"]

    static func verify(_ request: WalletReleaseHistoryRequest, ceiling: WalletSignedReviewCeiling,
                       key: Curve25519.Signing.PublicKey, identity: WalletInstalledReleaseIdentity,
                       previous: WalletReleaseAuthorityCheckpoint? = nil,
                       installationID: String, now: Date = Date(),
                       allowExperimentalMainnet: Bool = false) throws -> WalletVerifiedReleaseAuthority {
        try ceiling.verify(key: key, now: now)
        guard request.schemaVersion == 1, !request.transitions.isEmpty,
              request.transitions.count <= maximumTransitions,
              try WalletAuthorityEncoding.encode(request).count <= maximumHistoryBytes else {
            throw WalletReleaseActivationError.malformed
        }
        var prior = previous?.signedTransition
        var retired = previous?.retiredCandidateIDs ?? []
        guard retired.count <= 4_096, retired == Array(Set(retired)).sorted(),
              retired.allSatisfy({ WalletAuthorityEncoding.hex($0) }) else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        if let old = prior, let first = request.transitions.first,
           first.envelope.candidateID != old.envelope.candidateID {
            // A genuinely new installed build starts a new canary, not a
            // renewal of the old archive. Preserve the global high-water mark
            // and never return to a retired candidate. Repacking the same
            // source cannot reset reservations or emergency restrictions.
            guard first.envelope.transition == .initial, first.envelope.previousEnvelopeSHA256 == nil,
                  first.envelope.purpose == old.envelope.purpose,
                  first.envelope.revision > old.envelope.revision,
                  first.envelope.sourceRevision != old.envelope.sourceRevision,
                  first.envelope.installedIdentity != old.envelope.installedIdentity,
                  !retired.contains(first.envelope.candidateID) else {
                throw WalletReleaseActivationError.rollback
            }
            retired = Array(Set(retired + [old.envelope.candidateID])).sorted()
            prior = nil
        }
        var latestRegistry: WalletReviewRegistry?
        for signed in request.transitions {
            let value = signed.envelope
            let proofTime = value.issuedAt
            let experimental = value.purpose == .experimentalMainnet
            guard experimental == (value.releaseStage == .experimentalMainnet),
                  !experimental || allowExperimentalMainnet else {
                throw WalletReleaseActivationError.malformed
            }
            guard value.schemaVersion == 2, value.revision > 0, proofTime <= now,
                  proofTime >= ceiling.ceiling.reviewedAt,
                  value.expiresAt > proofTime, value.expiresAt.timeIntervalSince(proofTime) <= 31 * 86_400,
                  WalletAuthorityEncoding.hex(value.sourceRevision, count: 40),
                  WalletAuthorityEncoding.hex(value.outerAppCodeDirectoryHash, count: 40),
                  WalletAuthorityEncoding.hex(value.signerCodeDirectoryHash, count: 40),
                  WalletAuthorityEncoding.hex(value.archiveSHA256),
                  value.installedIdentity == identity,
                  value.reviewCeilingSHA256 == (try WalletAuthorityEncoding.digest(ceiling.ceiling)),
                  value.candidateID == (try value.computedCandidateID()),
                  value.authoritySHA256 == (try value.computedAuthoritySHA256()),
                  value.revokedAdmissionSerials == Array(Set(value.revokedAdmissionSerials)).sorted(),
                  value.revokedAdmissionSerials.count <= 10_000,
                  value.revokedAdmissionSerials.allSatisfy({ WalletAuthorityEncoding.hex($0) }),
                  value.permanentLimits.count <= 10_000,
                  Set(value.permanentLimits.map(\.identity)).count == value.permanentLimits.count,
                  value.permanentLimits.allSatisfy(WalletCanaryBudget.valid) else {
                throw WalletReleaseActivationError.malformed
            }
            try WalletAuthorityEncoding.verify(value, signature: signed.signatureBase64, key: key)
            let cap = value.capabilityManifest.manifest
            let review = value.reviewRestriction.manifest
            guard cap.revision == value.revision, review.revision == value.revision,
                  cap.releaseStage == value.releaseStage,
                  cap.issuedAt == proofTime, review.issuedAt == proofTime,
                  cap.expiresAt == value.expiresAt, review.expiresAt == value.expiresAt else {
                throw WalletReleaseActivationError.malformed
            }
            let gate = try WalletLaunchGate(signedManifest: value.capabilityManifest, publicKey: key,
                now: proofTime, allowExperimentalMainnet: allowExperimentalMainnet)
            let scopeRegistry = try ceiling.ceiling.scope.registry(revision: review.revision,
                issuedAt: proofTime, expiresAt: value.expiresAt, now: proofTime)
            latestRegistry = try scopeRegistry.restricted(by: value.reviewRestriction, publicKey: key, now: proofTime)
            let limits = cap.canaryLimits ?? []
            guard limits.count <= 10_000, Set(limits.map(\.identity)).count == limits.count,
                  limits.allSatisfy(WalletCanaryBudget.valid) else { throw WalletReleaseActivationError.malformed }
            if experimental {
                guard value.cohortID == nil, value.admissionGeneration == 0,
                      value.revokedAdmissionSerials.isEmpty, request.admission == nil,
                      limits.isEmpty,
                      !mainnets.isDisjoint(with: cap.enabledNetworkIDs) else {
                    throw WalletReleaseActivationError.malformed
                }
            }
            if value.purpose == .testnetRehearsal {
                guard cap.networkGrants.allSatisfy({ WalletNetworkCatalog.descriptor(id: $0.networkID)?.environment == .testnet }),
                      value.releaseStage == .invitedCanary, value.cohortID == nil,
                      value.admissionGeneration == 0, value.revokedAdmissionSerials.isEmpty else {
                    throw WalletReleaseActivationError.malformed
                }
            } else {
                if value.releaseStage == .invitedCanary {
                    guard let cohort = value.cohortID, WalletAuthorityEncoding.hex(cohort), value.admissionGeneration > 0 else {
                        throw WalletReleaseActivationError.admissionRequired
                    }
                }
                for grant in cap.networkGrants where mainnets.contains(grant.networkID) {
                    guard Set(review.providerIdentities.filter { $0.networkID == grant.networkID }.map(\.provider))
                        .isSuperset(of: [.alchemy, .quickNode]) else { throw WalletReleaseActivationError.broaderThanCeiling }
                    if value.releaseStage == .invitedCanary {
                        guard limits.contains(where: { $0.networkID == grant.networkID }) else {
                            throw WalletReleaseActivationError.broaderThanCeiling
                        }
                    }
                }
            }
            if let old = prior {
                if old.digest == signed.digest {
                    guard request.transitions.count == 1 else { throw WalletReleaseActivationError.revisionConflict }
                } else {
                    try validateTransition(from: old, to: signed, key: key)
                }
            } else {
                guard value.transition == .initial, value.previousEnvelopeSHA256 == nil,
                      value.releaseStage == (experimental ? .experimentalMainnet : .invitedCanary) else {
                    throw WalletReleaseActivationError.historyRequired
                }
                if value.purpose == .production {
                    guard mainnets.isSubset(of: gate.effectiveManifest?.enabledNetworkIDs ?? []) else {
                        throw WalletReleaseActivationError.broaderThanCeiling
                    }
                }
            }
            prior = signed
        }
        guard let latest = prior, let registry = latestRegistry, latest.envelope.expiresAt > now else {
            throw WalletReleaseActivationError.expired
        }
        let sameCandidate = previous?.signedTransition.envelope.candidateID == latest.envelope.candidateID
        let admission = request.admission ?? (sameCandidate ? previous?.admission : nil)
        if latest.envelope.purpose == .experimentalMainnet, admission != nil {
            throw WalletReleaseActivationError.malformed
        }
        if let signed = admission {
            try validateAdmission(signed, envelope: latest.envelope, key: key, installationID: installationID, now: now)
        }
        let result = WalletVerifiedReleaseAuthority(checkpoint: .init(signedTransition: latest,
            admission: admission, retiredCandidateIDs: retired),
            launchGate: try WalletLaunchGate(signedManifest: latest.envelope.capabilityManifest, publicKey: key,
                now: now, allowExperimentalMainnet: allowExperimentalMainnet),
            reviewRegistry: registry)
        // A revoked/missing admission must not prevent persisting an emergency
        // restriction. Callers apply it and expose no canary signing authority.
        return result
    }

    private static func validateTransition(from previous: WalletSignedReleaseTransition,
                                           to current: WalletSignedReleaseTransition,
                                           key: Curve25519.Signing.PublicKey) throws {
        let old = previous.envelope, next = current.envelope
        guard next.revision > old.revision, next.previousEnvelopeSHA256 == previous.digest,
              next.candidateID == old.candidateID, next.purpose == old.purpose,
              next.issuedAt >= old.issuedAt, next.transition != .initial else {
            throw WalletReleaseActivationError.historyRequired
        }
        switch next.transition {
        case .initial: throw WalletReleaseActivationError.historyRequired
        case .renewal:
            guard next.authoritySHA256 == old.authoritySHA256 else { throw WalletReleaseActivationError.broaderThanCeiling }
        case .restriction, .promotion:
            guard grants(next.capabilityManifest.manifest, narrow: old.capabilityManifest.manifest),
                  Set(old.revokedAdmissionSerials).isSubset(of: Set(next.revokedAdmissionSerials)),
                  next.admissionGeneration >= old.admissionGeneration,
                  next.cohortID == old.cohortID,
                  limits(next.permanentLimits, preserve: old.permanentLimits) else {
                throw WalletReleaseActivationError.broaderThanCeiling
            }
            let projection = try WalletReviewScope(old.reviewRestriction.manifest).registry(
                revision: next.revision, issuedAt: next.issuedAt, expiresAt: next.expiresAt, now: next.issuedAt)
            _ = try projection.restricted(by: next.reviewRestriction, publicKey: key, now: next.issuedAt)
            if next.transition == .restriction {
                guard next.releaseStage == old.releaseStage,
                      Set(next.capabilityManifest.manifest.canaryLimits?.map(\.identity) ?? [])
                        == Set(old.capabilityManifest.manifest.canaryLimits?.map(\.identity) ?? []),
                      limits(next.capabilityManifest.manifest.canaryLimits ?? [],
                             narrow: old.capabilityManifest.manifest.canaryLimits ?? []) else {
                    throw WalletReleaseActivationError.broaderThanCeiling
                }
                // Every newly lowered canary cap becomes permanent. Promotion
                // cannot erase an emergency limit by relabeling it temporary.
                for lower in next.capabilityManifest.manifest.canaryLimits ?? [] {
                    if let prior = old.capabilityManifest.manifest.canaryLimits?.first(where: { $0.identity == lower.identity }),
                       lower != prior {
                        guard next.permanentLimits.contains(where: { $0.identity == lower.identity && limit($0, narrow: lower) }) else {
                            throw WalletReleaseActivationError.broaderThanCeiling
                        }
                    }
                }
            } else {
                guard old.releaseStage == .invitedCanary, next.releaseStage == .generalAvailability,
                      old.purpose == .production,
                      WalletReleaseTransitionEnvelope.normalizedGrants(next.capabilityManifest.manifest.networkGrants)
                        == WalletReleaseTransitionEnvelope.normalizedGrants(old.capabilityManifest.manifest.networkGrants),
                      next.capabilityManifest.manifest.approvedRegions == old.capabilityManifest.manifest.approvedRegions,
                      WalletReviewScope(next.reviewRestriction.manifest) == WalletReviewScope(old.reviewRestriction.manifest),
                      next.permanentLimits == old.permanentLimits,
                      (next.capabilityManifest.manifest.canaryLimits ?? []).isEmpty else {
                    throw WalletReleaseActivationError.broaderThanCeiling
                }
            }
        }
    }

    static func grants(_ candidate: WalletCapabilityManifest, narrow ceiling: WalletCapabilityManifest) -> Bool {
        candidate.approvedRegions.isSubset(of: ceiling.approvedRegions) && candidate.networkGrants.allSatisfy { grant in
            guard let upper = ceiling.grant(for: grant.networkID), grant.capabilities.isSubset(of: upper.capabilities) else { return false }
            return grant.connectors.allSatisfy { item in
                upper.connectors.contains { $0.connector == item.connector && $0.ownership == item.ownership
                    && item.directions.isSubset(of: $0.directions) && item.methods.isSubset(of: $0.methods) }
            }
        }
    }

    static func limit(_ value: WalletCanaryLimit, narrow upper: WalletCanaryLimit) -> Bool {
        func le(_ a: String, _ b: String) -> Bool { a.count == b.count ? a <= b : a.count < b.count }
        return value.identity == upper.identity && WalletCanaryBudget.valid(value) && WalletCanaryBudget.valid(upper)
            && le(value.maximumTransactionBaseUnits, upper.maximumTransactionBaseUnits)
            && le(value.maximumCumulativeBaseUnits, upper.maximumCumulativeBaseUnits)
            && le(value.maximumFeeBaseUnits, upper.maximumFeeBaseUnits)
            && le(value.maximumCumulativeFeeBaseUnits, upper.maximumCumulativeFeeBaseUnits)
            && value.maximumTransactions <= upper.maximumTransactions
    }

    static func limits(_ values: [WalletCanaryLimit], narrow ceiling: [WalletCanaryLimit]) -> Bool {
        values.allSatisfy { value in ceiling.contains { limit(value, narrow: $0) } }
    }

    private static func limits(_ values: [WalletCanaryLimit], preserve floor: [WalletCanaryLimit]) -> Bool {
        floor.allSatisfy { old in values.contains { limit($0, narrow: old) } }
    }

    static func intersectLimits(_ values: [WalletCanaryLimit], _ restrictions: [WalletCanaryLimit],
                                preserveUnmentioned: Bool = false) -> [WalletCanaryLimit] {
        values.compactMap { value in
            guard let lower = restrictions.first(where: { $0.identity == value.identity }) else {
                return preserveUnmentioned ? value : nil
            }
            func minAmount(_ a: String, _ b: String) -> String { a.count == b.count ? min(a, b) : (a.count < b.count ? a : b) }
            return .init(networkID: value.networkID, assetID: value.assetID, action: value.action,
                ownership: value.ownership, connector: value.connector,
                maximumTransactionBaseUnits: minAmount(value.maximumTransactionBaseUnits, lower.maximumTransactionBaseUnits),
                maximumCumulativeBaseUnits: minAmount(value.maximumCumulativeBaseUnits, lower.maximumCumulativeBaseUnits),
                maximumFeeBaseUnits: minAmount(value.maximumFeeBaseUnits, lower.maximumFeeBaseUnits),
                maximumCumulativeFeeBaseUnits: minAmount(value.maximumCumulativeFeeBaseUnits, lower.maximumCumulativeFeeBaseUnits),
                maximumTransactions: min(value.maximumTransactions, lower.maximumTransactions))
        }
    }

    private static func validateAdmission(_ signed: WalletSignedCanaryAdmission,
                                          envelope: WalletReleaseTransitionEnvelope,
                                          key: Curve25519.Signing.PublicKey,
                                          installationID: String, now: Date) throws {
        let value = signed.admission
        try WalletAuthorityEncoding.verify(value, signature: signed.signatureBase64, key: key)
        guard value.schemaVersion == 1, value.domain == WalletCanaryAdmission.domain,
              value.candidateID == envelope.candidateID, value.cohortID == envelope.cohortID,
              WalletAuthorityEncoding.hex(value.installationID), value.installationID == installationID,
              WalletAuthorityEncoding.hex(value.serial), value.generation > 0,
              value.issuedAt <= now, value.expiresAt > value.issuedAt,
              value.expiresAt.timeIntervalSince(value.issuedAt) <= 31 * 86_400,
              value.allocation.count <= 10_000, !value.allocation.isEmpty,
              Set(value.allocation.map(\.identity)).count == value.allocation.count,
              value.allocation.allSatisfy(WalletCanaryBudget.valid) else {
            throw WalletReleaseActivationError.admissionRequired
        }
        // Expired or revoked admissions remain attributable history. They are
        // rejected by requireAdmission at preparation/release, not used to
        // prevent an emergency restriction from being persisted.
    }
}
