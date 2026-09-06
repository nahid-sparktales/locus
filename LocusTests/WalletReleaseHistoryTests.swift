import CryptoKit
import XCTest
@testable import Locus

final class WalletReleaseHistoryTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let installation = String(repeating: "f", count: 64)
    private var identity: WalletInstalledReleaseIdentity {
        .init(sourceRevision: String(repeating: "a", count: 40), bundleVersion: "24",
            outerAppCodeDirectoryHash: String(repeating: "b", count: 40),
            signerCodeDirectoryHash: String(repeating: "c", count: 40))
    }

    private func review(_ revision: Int, at date: Date, adapters: Set<String>) -> WalletReviewManifest {
        .init(schemaVersion: 2, revision: revision, issuedAt: date,
            expiresAt: date.addingTimeInterval(31 * 86_400), assets: [], evmContracts: [],
            explorerTemplates: [:], adapterIDs: adapters,
            providerIdentities: WalletReleaseHistoryVerifier.mainnets.sorted().flatMap { networkID in
                [WalletProviderKind.alchemy, .quickNode].map { provider in
                    WalletReviewedProviderIdentity(networkID: networkID, provider: provider,
                        configurationID: "\(provider.rawValue):\(networkID)",
                        endpointSHA256: String(repeating: "2", count: 64),
                        expectedIdentity: WalletNetworkCatalog.descriptor(id: networkID)!.identity)
                }
            })
    }

    private func signedCeiling() throws -> WalletSignedReviewCeiling {
        let date = now.addingTimeInterval(-120 * 86_400)
        let ceiling = WalletReviewCeiling(schemaVersion: 1, domain: WalletReviewCeiling.domain,
            reviewRevision: 1, reviewedAt: date,
            scope: WalletReviewScope(review(1, at: date, adapters: [WalletReviewedAdapters.erc20])))
        return .init(ceiling: ceiling, signatureBase64: try signature(ceiling))
    }

    private func signature<T: Encodable>(_ value: T) throws -> String {
        try key.signature(for: WalletAuthorityEncoding.encode(value)).base64EncodedString()
    }

    private func transition(_ revision: Int = 1, kind: WalletReleaseTransitionKind = .initial,
                            previous: WalletSignedReleaseTransition? = nil, at date: Date? = nil,
                            adapters: Set<String> = [WalletReviewedAdapters.erc20],
                            purpose: WalletReleasePurpose = .testnetRehearsal,
                            limits: [WalletCanaryLimit] = [], permanent: [WalletCanaryLimit] = [],
                            networks: Set<String> = ["eip155:11155111"],
                            stage: WalletReleaseStage = .invitedCanary,
                            revoked: [String] = []) throws -> WalletSignedReleaseTransition {
        let date = date ?? now.addingTimeInterval(-10)
        let restriction = review(revision, at: date, adapters: adapters)
        let experimental = stage == .experimentalMainnet
        var cap = WalletCapabilityManifest(schemaVersion: 3, revision: revision,
            releaseStage: stage, evidenceIndexSHA256: experimental ? "" : String(repeating: "d", count: 64),
            issuedAt: date, expiresAt: restriction.expiresAt,
            networkGrants: networks.sorted().map { .init(networkID: $0, capabilities: [.nativeTransfer], connectors: []) },
            approvedRegions: experimental ? [] : ["CA"],
            completedApprovals: experimental ? [] : Set(WalletLaunchApproval.allCases))
        cap.canaryLimits = limits
        let value = WalletReleaseTransitionEnvelope(schemaVersion: 2,
            sourceRevision: identity.sourceRevision, bundleVersion: identity.bundleVersion,
            outerAppCodeDirectoryHash: identity.outerAppCodeDirectoryHash,
            signerCodeDirectoryHash: identity.signerCodeDirectoryHash,
            archiveSHA256: String(repeating: "e", count: 64), releaseStage: stage,
            issuedAt: date, expiresAt: restriction.expiresAt, revision: revision,
            capabilityManifest: .init(manifest: cap, signatureBase64: try signature(cap)),
            reviewRestriction: .init(manifest: restriction, signatureBase64: try signature(restriction)),
            transition: kind, purpose: purpose, candidateID: "",
            reviewCeilingSHA256: try WalletAuthorityEncoding.digest(signedCeiling().ceiling),
            previousEnvelopeSHA256: previous?.digest, authoritySHA256: "",
            cohortID: purpose == .production ? String(repeating: "1", count: 64) : nil,
            admissionGeneration: purpose == .production ? 1 : 0,
            revokedAdmissionSerials: revoked, permanentLimits: permanent)
        return try resign(value) { object in
            object["candidateID"] = try value.computedCandidateID()
            object["authoritySHA256"] = try value.computedAuthoritySHA256()
        }
    }

    private func resign(_ envelope: WalletReleaseTransitionEnvelope,
                        mutate: (inout [String: Any]) throws -> Void) throws -> WalletSignedReleaseTransition {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WalletAuthorityEncoding.encode(envelope)) as? [String: Any])
        try mutate(&object)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(WalletReleaseTransitionEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        return .init(envelope: value, signatureBase64: try signature(value))
    }

    private func verify(_ values: [WalletSignedReleaseTransition],
                        previous: WalletReleaseAuthorityCheckpoint? = nil,
                        admission: WalletSignedCanaryAdmission? = nil,
                        installedIdentity: WalletInstalledReleaseIdentity? = nil,
                        allowExperimentalMainnet: Bool = false) throws -> WalletVerifiedReleaseAuthority {
        try WalletReleaseHistoryVerifier.verify(.init(schemaVersion: 1, transitions: values, admission: admission),
            ceiling: signedCeiling(), key: key.publicKey, identity: installedIdentity ?? identity,
            previous: previous, installationID: installation, now: now,
            allowExperimentalMainnet: allowExperimentalMainnet)
    }

    func testExperimentalMainnetRequiresExplicitBuildAdmissionAndClaimsNoReleaseEvidence() throws {
        let initial = try transition(purpose: .experimentalMainnet,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .experimentalMainnet)
        XCTAssertThrowsError(try verify([initial]))
        let enabled = try verify([initial], allowExperimentalMainnet: true)
        XCTAssertNil(enabled.checkpoint.admission)
        XCTAssertTrue(initial.envelope.capabilityManifest.manifest.completedApprovals.isEmpty)
        XCTAssertTrue(initial.envelope.capabilityManifest.manifest.evidenceIndexSHA256.isEmpty)
        XCTAssertTrue(initial.envelope.capabilityManifest.manifest.approvedRegions.isEmpty)
        XCTAssertNoThrow(try enabled.requireAdmission(installationID: installation, now: now))
        for network in WalletReleaseHistoryVerifier.mainnets {
            XCTAssertNoThrow(try enabled.launchGate.authorize(networkID: network,
                capability: .nativeTransfer, regionCode: "ZZ"))
            XCTAssertThrowsError(try enabled.launchGate.authorize(networkID: network,
                capability: .nativeTransfer, regionCode: "ZZ", requireGA: true))
            XCTAssertThrowsError(try enabled.launchGate.authorize(networkID: network,
                capability: .autonomousPolicy, regionCode: "ZZ"))
        }
    }

    func testExperimentalPurposeCannotBeRelabeledAsProductionOrTestnetRehearsal() throws {
        let initial = try transition(purpose: .experimentalMainnet,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .experimentalMainnet)
        for purpose in [WalletReleasePurpose.production, .testnetRehearsal] {
            let relabeled = try resign(initial.envelope) { $0["purpose"] = purpose.rawValue }
            XCTAssertThrowsError(try verify([relabeled], allowExperimentalMainnet: true))
        }
        XCTAssertThrowsError(try verify([transition(purpose: .experimentalMainnet)],
            allowExperimentalMainnet: true))
        XCTAssertThrowsError(try verify([transition(purpose: .experimentalMainnet,
            stage: .experimentalMainnet)], allowExperimentalMainnet: true))
    }

    func testExperimentalRenewalCannotRestoreRestrictedScopeOrPromoteToGA() throws {
        let networks = WalletReleaseHistoryVerifier.mainnets
        let initial = try transition(purpose: .experimentalMainnet, networks: networks, stage: .experimentalMainnet)
        let restricted = try transition(2, kind: .restriction, previous: initial, adapters: [],
            purpose: .experimentalMainnet, networks: ["eip155:1"], stage: .experimentalMainnet)
        let result = try verify([initial, restricted], allowExperimentalMainnet: true)
        XCTAssertEqual(result.launchGate.effectiveManifest?.enabledNetworkIDs, ["eip155:1"])
        let renewal = try transition(3, kind: .renewal, previous: restricted, adapters: [],
            purpose: .experimentalMainnet, networks: ["eip155:1"], stage: .experimentalMainnet)
        XCTAssertNoThrow(try verify([renewal], previous: result.checkpoint, allowExperimentalMainnet: true))
        let restored = try transition(3, kind: .renewal, previous: restricted,
            purpose: .experimentalMainnet, networks: networks, stage: .experimentalMainnet)
        XCTAssertThrowsError(try verify([restored], previous: result.checkpoint, allowExperimentalMainnet: true))
        let promotion = try transition(2, kind: .promotion, previous: initial,
            purpose: .production, networks: networks, stage: .generalAvailability)
        XCTAssertThrowsError(try verify([initial, promotion], allowExperimentalMainnet: true))
    }

    func testExperimentalLaunchGateRejectsFabricatedApprovalAndEvidenceClaims() throws {
        let initial = try transition(purpose: .experimentalMainnet,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .experimentalMainnet)
        let base = initial.envelope.capabilityManifest.manifest
        for field in ["evidenceIndexSHA256", "completedApprovals", "approvedRegions"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WalletAuthorityEncoding.encode(base)) as? [String: Any])
            switch field {
            case "evidenceIndexSHA256": object[field] = String(repeating: "d", count: 64)
            case "completedApprovals": object[field] = [WalletLaunchApproval.signerAudit.rawValue]
            default: object[field] = ["CA"]
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(WalletCapabilityManifest.self,
                from: JSONSerialization.data(withJSONObject: object))
            let signed = WalletSignedCapabilityManifest(manifest: manifest, signatureBase64: try signature(manifest))
            XCTAssertThrowsError(try WalletLaunchGate(signedManifest: signed, publicKey: key.publicKey,
                now: now, allowExperimentalMainnet: true))
        }
    }

    func testExperimentalScopeStillRequiresExactProvidersAndValidSignatures() throws {
        let initial = try transition(purpose: .experimentalMainnet,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .experimentalMainnet)
        XCTAssertThrowsError(try verify([.init(envelope: initial.envelope,
            signatureBase64: Data(repeating: 0, count: 64).base64EncodedString())], allowExperimentalMainnet: true))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            WalletAuthorityEncoding.encode(initial.envelope.reviewRestriction.manifest)) as? [String: Any])
        object["providerIdentities"] = []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let review = try decoder.decode(WalletReviewManifest.self, from: JSONSerialization.data(withJSONObject: object))
        let signedReview = WalletSignedReviewManifest(manifest: review, signatureBase64: try signature(review))
        let missingProviders = try resign(initial.envelope) { value in
            value["reviewRestriction"] = try JSONSerialization.jsonObject(with: WalletAuthorityEncoding.encode(signedReview))
        }
        // Recompute authority so rejection is attributable to absent provider bindings.
        let rebound = try resign(missingProviders.envelope) {
            $0["authoritySHA256"] = try missingProviders.envelope.computedAuthoritySHA256()
        }
        XCTAssertThrowsError(try verify([rebound], allowExperimentalMainnet: true)) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .broaderThanCeiling)
        }
    }

    func testExperimentalAndProductionCapabilityRestrictionsStaySeparate() throws {
        let experimental = try transition(purpose: .experimentalMainnet,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .experimentalMainnet)
        let production = try transition(purpose: .production, limits: mainnetLimits(),
            networks: WalletReleaseHistoryVerifier.mainnets)
        let experimentalGate = try verify([experimental], allowExperimentalMainnet: true).launchGate
        let productionGate = try verify([production]).launchGate
        XCTAssertThrowsError(try experimentalGate.restricted(by: production.envelope.capabilityManifest,
            publicKey: key.publicKey, now: now))
        XCTAssertThrowsError(try productionGate.restricted(by: experimental.envelope.capabilityManifest,
            publicKey: key.publicKey, now: now))
    }

    func testOrdinaryBuildCannotEnableExperimentalModeFromPreferences() {
        #if !LOCUS_EXPERIMENTAL_MAINNET
        XCTAssertFalse(WalletExperimentalMainnetBuild.isEnabled())
        XCTAssertEqual(WalletExperimentalMainnetBuild.authorityStorageSuffix, "")
        #endif
    }

    func testImmutableCeilingCannotBeDecodedAsOperationalManifest() throws {
        let value = try signedCeiling()
        XCTAssertNoThrow(try value.verify(key: key.publicKey, now: now.addingTimeInterval(400 * 86_400)))
        XCTAssertThrowsError(try JSONDecoder().decode(WalletSignedReviewManifest.self,
            from: WalletAuthorityEncoding.encode(value)))
    }

    func testExpiredHistoricalProofRenewsSameScopeWithoutExpiringCeiling() throws {
        let initial = try transition(at: now.addingTimeInterval(-70 * 86_400))
        let renewal = try transition(2, kind: .renewal, previous: initial)
        XCTAssertEqual(initial.envelope.authoritySHA256, renewal.envelope.authoritySHA256)
        let result = try verify([initial, renewal])
        XCTAssertEqual(result.checkpoint.revision, 2)
        XCTAssertGreaterThan(result.reviewRegistry.manifest.expiresAt, now)
        XCTAssertThrowsError(try verify([initial]))
    }

    func testHistoryMustIncludeEveryAuthorityChangingTransition() throws {
        let initial = try transition()
        let restriction = try transition(2, kind: .restriction, previous: initial, adapters: [])
        let renewal = try transition(3, kind: .renewal, previous: restriction, adapters: [])
        XCTAssertNoThrow(try verify([initial, restriction, renewal]))
        XCTAssertThrowsError(try verify([initial, renewal]))
        XCTAssertThrowsError(try verify([renewal]))
        let checkpoint = try verify([initial, restriction]).checkpoint
        XCTAssertNoThrow(try verify([renewal], previous: checkpoint))
        XCTAssertThrowsError(try verify([initial], previous: checkpoint))
    }

    func testHigherRevisionCannotRestoreRemovedAdapter() throws {
        let initial = try transition()
        let restriction = try transition(2, kind: .restriction, previous: initial, adapters: [])
        let restored = try transition(3, kind: .restriction, previous: restriction)
        XCTAssertThrowsError(try verify([initial, restriction, restored]))
        let disguisedRenewal = try transition(3, kind: .renewal, previous: restriction)
        XCTAssertThrowsError(try verify([initial, restriction, disguisedRenewal]))
    }

    func testDifferentHashShapeIdentityFingerprintAndRevisionFailClosed() throws {
        let initial = try transition()
        for (name, value) in [("outerAppCodeDirectoryHash", String(repeating: "b", count: 64)),
                              ("signerCodeDirectoryHash", String(repeating: "c", count: 41)),
                              ("candidateID", String(repeating: "0", count: 64)),
                              ("authoritySHA256", String(repeating: "0", count: 64))] {
            XCTAssertThrowsError(try verify([resign(initial.envelope) { $0[name] = value }]))
        }
        let checkpoint = try verify([initial]).checkpoint
        XCTAssertNoThrow(try verify([initial], previous: checkpoint))
        XCTAssertThrowsError(try verify([initial, initial]))
    }

    func testProductionInitialCannotEnableOnlyOneChain() throws {
        XCTAssertThrowsError(try verify([transition(purpose: .production)]))
    }

    func testBadSignatureAndOversizedHistoryNeverCreateAuthority() throws {
        let value = try transition()
        XCTAssertThrowsError(try verify([.init(envelope: value.envelope, signatureBase64: Data(repeating: 0, count: 64).base64EncodedString())]))
        XCTAssertThrowsError(try verify(Array(repeating: value, count: 65)))
    }

    private func limit(_ amount: String) -> WalletCanaryLimit {
        .init(networkID: "eip155:11155111", assetID: WalletNetworkCatalog.ethereumSepolia.nativeAssetID,
            action: .nativeTransfer, ownership: .locusVault, connector: nil,
            maximumTransactionBaseUnits: amount, maximumCumulativeBaseUnits: "100",
            maximumFeeBaseUnits: "1", maximumCumulativeFeeBaseUnits: "10", maximumTransactions: 10)
    }

    func testLoweredTemporaryLimitMustBePersistedAsPermanentRestriction() throws {
        let initial = try transition(limits: [limit("10")])
        let lostFloor = try transition(2, kind: .restriction, previous: initial, limits: [limit("5")])
        XCTAssertThrowsError(try verify([initial, lostFloor]))
        let restricted = try transition(2, kind: .restriction, previous: initial,
            limits: [limit("5")], permanent: [limit("5")])
        XCTAssertNoThrow(try verify([initial, restricted]))
        let restored = try transition(3, kind: .restriction, previous: restricted,
            limits: [limit("10")], permanent: [limit("5")])
        XCTAssertThrowsError(try verify([initial, restricted, restored]))
    }

    private func mainnetLimits(_ amount: String = "10") -> [WalletCanaryLimit] {
        WalletReleaseHistoryVerifier.mainnets.sorted().map { networkID in
            .init(networkID: networkID, assetID: WalletNetworkCatalog.descriptor(id: networkID)!.nativeAssetID,
                action: .nativeTransfer, ownership: .locusVault, connector: nil,
                maximumTransactionBaseUnits: amount, maximumCumulativeBaseUnits: "100",
                maximumFeeBaseUnits: "1", maximumCumulativeFeeBaseUnits: "10", maximumTransactions: 10)
        }
    }

    private func admission(for transition: WalletSignedReleaseTransition,
                           installationID: String? = nil, expiresAt: Date? = nil,
                           allocation: [WalletCanaryLimit]? = nil) throws -> WalletSignedCanaryAdmission {
        let value = WalletCanaryAdmission(schemaVersion: 1, domain: WalletCanaryAdmission.domain,
            candidateID: transition.envelope.candidateID, cohortID: transition.envelope.cohortID!,
            installationID: installationID ?? installation, serial: String(repeating: "3", count: 64),
            generation: 1, issuedAt: now.addingTimeInterval(-20),
            expiresAt: expiresAt ?? now.addingTimeInterval(86_400), allocation: allocation ?? mainnetLimits("5"))
        return .init(admission: value, signatureBase64: try signature(value))
    }

    func testAllChainCanaryRequiresInstallationBoundAdmissionAndFiniteAllocation() throws {
        let initial = try transition(purpose: .production, limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        let dormant = try verify([initial])
        XCTAssertThrowsError(try dormant.requireAdmission(installationID: installation, now: now))
        let invitation = try admission(for: initial)
        let enabled = try verify([initial], admission: invitation)
        XCTAssertNoThrow(try enabled.requireAdmission(installationID: installation, now: now))
        XCTAssertEqual(enabled.budgetManifest().canaryLimits?.map(\.maximumTransactionBaseUnits), ["5", "5", "5"])
        XCTAssertThrowsError(try enabled.requireAdmission(installationID: String(repeating: "0", count: 64), now: now))
        XCTAssertThrowsError(try verify([initial], admission: admission(for: initial,
            installationID: String(repeating: "0", count: 64))))
        let expired = try verify([initial], admission: admission(for: initial, expiresAt: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try expired.requireAdmission(installationID: installation, now: now))
    }

    func testAdmissionRevocationPersistsGlobalRestrictionAndRenewalCannotRestoreIt() throws {
        let initial = try transition(purpose: .production, limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        let invitation = try admission(for: initial)
        let checkpoint = try verify([initial], admission: invitation).checkpoint
        let restricted = try transition(2, kind: .restriction, previous: initial, purpose: .production,
            limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets,
            revoked: [invitation.admission.serial])
        let result = try verify([restricted], previous: checkpoint)
        XCTAssertEqual(result.checkpoint.revision, 2)
        XCTAssertThrowsError(try result.requireAdmission(installationID: installation, now: now))
        let renewal = try transition(3, kind: .renewal, previous: restricted, purpose: .production,
            limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets,
            revoked: [invitation.admission.serial])
        XCTAssertNoThrow(try verify([renewal], previous: result.checkpoint))
        let restored = try transition(3, kind: .renewal, previous: restricted, purpose: .production,
            limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        XCTAssertThrowsError(try verify([restored], previous: result.checkpoint))
    }

    func testPromotionKeepsExactCandidateAndPermanentEmergencyLimits() throws {
        let initial = try transition(purpose: .production, limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        let restricted = try transition(2, kind: .restriction, previous: initial, purpose: .production,
            limits: mainnetLimits("5"), permanent: mainnetLimits("5"), networks: WalletReleaseHistoryVerifier.mainnets)
        let ga = try transition(3, kind: .promotion, previous: restricted, purpose: .production,
            permanent: mainnetLimits("5"), networks: WalletReleaseHistoryVerifier.mainnets, stage: .generalAvailability)
        let result = try verify([initial, restricted, ga])
        XCTAssertEqual(result.checkpoint.signedTransition.envelope.candidateID, initial.envelope.candidateID)
        XCTAssertEqual(result.budgetManifest().canaryLimits, mainnetLimits("5"))
        let lostFloor = try transition(3, kind: .promotion, previous: restricted, purpose: .production,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .generalAvailability)
        XCTAssertThrowsError(try verify([initial, restricted, lostFloor]))
        let changedArchive = try resign(ga.envelope) { $0["archiveSHA256"] = String(repeating: "0", count: 64) }
        XCTAssertThrowsError(try verify([initial, restricted, changedArchive]))
    }

    func testPromotionDoesNotRetainCanaryAdmissionExpiryTimer() throws {
        let initial = try transition(purpose: .production, limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        let invitation = try admission(for: initial, expiresAt: now.addingTimeInterval(1))
        let canary = try verify([initial], admission: invitation)
        XCTAssertEqual(canary.authorityExpiresAt, invitation.admission.expiresAt)
        let ga = try transition(2, kind: .promotion, previous: initial, purpose: .production,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .generalAvailability)
        let promoted = try verify([ga], previous: canary.checkpoint)
        XCTAssertEqual(promoted.authorityExpiresAt, ga.envelope.expiresAt)
        XCTAssertNoThrow(try promoted.requireAdmission(installationID: installation, now: now.addingTimeInterval(2)))
    }

    func testRestrictionCannotDeleteLimitToMakeLaterPromotionUncapped() throws {
        let initial = try transition(limits: [limit("10")])
        let deletion = try transition(2, kind: .restriction, previous: initial, limits: [])
        XCTAssertThrowsError(try verify([initial, deletion]))
    }

    func testNewInstalledCandidateStartsFreshCanaryWithoutResettingGlobalHighWaterMark() throws {
        let initial = try transition()
        let checkpoint = try verify([initial]).checkpoint
        let base = try transition(2)
        let newIdentity = WalletInstalledReleaseIdentity(sourceRevision: String(repeating: "4", count: 40),
            bundleVersion: "25", outerAppCodeDirectoryHash: String(repeating: "5", count: 40),
            signerCodeDirectoryHash: String(repeating: "6", count: 40))
        let changed = try resign(base.envelope) {
            $0["sourceRevision"] = newIdentity.sourceRevision
            $0["bundleVersion"] = newIdentity.bundleVersion
            $0["outerAppCodeDirectoryHash"] = newIdentity.outerAppCodeDirectoryHash
            $0["signerCodeDirectoryHash"] = newIdentity.signerCodeDirectoryHash
        }
        let replacement = try resign(changed.envelope) { $0["candidateID"] = try changed.envelope.computedCandidateID() }
        let result = try verify([replacement], previous: checkpoint, installedIdentity: newIdentity)
        XCTAssertEqual(result.checkpoint.retiredCandidateIDs, [initial.envelope.candidateID])
        XCTAssertNil(result.checkpoint.admission)
        XCTAssertThrowsError(try verify([replacement], previous: checkpoint))
        let lower = try resign(replacement.envelope) { $0["revision"] = 1 }
        XCTAssertThrowsError(try verify([lower], previous: checkpoint, installedIdentity: newIdentity))
        let oldAgain = try transition(3)
        XCTAssertThrowsError(try verify([oldAgain], previous: result.checkpoint))
        let repacked = try resign(base.envelope) { $0["archiveSHA256"] = String(repeating: "7", count: 64) }
        let sameSourceReset = try resign(repacked.envelope) { $0["candidateID"] = try repacked.envelope.computedCandidateID() }
        XCTAssertThrowsError(try verify([sameSourceReset], previous: checkpoint))
    }

    func testAuthorityCanonicalFixtureParity() throws {
        let initial = try transition(purpose: .production, limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        XCTAssertEqual(initial.envelope.authoritySHA256, try initial.envelope.computedAuthoritySHA256())
        // Synthetic public-only fixture for the independent release-tool verifier.
        // Never emits an invitation, installation identity, key, or real address.
        print("LOCUS_AUTHORITY_CANONICAL_FIXTURE=" + (try WalletAuthorityEncoding.encode(initial.envelope)).base64EncodedString())
        print("LOCUS_CEILING_CANONICAL_FIXTURE=" + (try WalletAuthorityEncoding.encode(signedCeiling())).base64EncodedString())
    }

    @MainActor
    func testCandidateUpdateChannelsRequireAdmissionAndPreserveArchive() throws {
        let initial = try transition(purpose: .production, limits: mainnetLimits(), networks: WalletReleaseHistoryVerifier.mainnets)
        let dormant = try verify([initial])
        let admitted = try verify([initial], admission: admission(for: initial))
        let stable = "https://updates.example.invalid/stable/appcast.xml"
        let canary = "https://updates.example.invalid/canary/appcast.xml"
        let archive = "https://updates.example.invalid/candidate-24/Locus-macOS.zip"
        func selection(_ value: WalletVerifiedReleaseAuthority) -> WalletCandidateUpdateAuthority.Selection? {
            WalletCandidateUpdateAuthority.selection(authority: value, installation: installation,
                stable: stable, canary: canary, archive: archive, now: now)
        }
        XCTAssertNil(selection(dormant))
        let selected = try XCTUnwrap(selection(admitted))
        XCTAssertEqual(selected.feedURL, canary)
        XCTAssertTrue(WalletCandidateUpdateAuthority.permits(selected, archiveURL: archive, version: "24", channel: "canary"))
        XCTAssertFalse(WalletCandidateUpdateAuthority.permits(selected, archiveURL: archive, version: "25", channel: "canary"))
        XCTAssertFalse(WalletCandidateUpdateAuthority.permits(selected, archiveURL: archive, version: "24", channel: nil))
        XCTAssertFalse(WalletCandidateUpdateAuthority.permits(selected, archiveURL: stable, version: "24", channel: "canary"))
        let ga = try transition(2, kind: .promotion, previous: initial, purpose: .production,
            networks: WalletReleaseHistoryVerifier.mainnets, stage: .generalAvailability)
        let promoted = try verify([ga], previous: admitted.checkpoint)
        XCTAssertEqual(selection(promoted)?.feedURL, stable)
        XCTAssertNil(selection(promoted)?.channel)
        XCTAssertEqual(selection(promoted)?.archiveURL, archive)
    }

    @MainActor
    func testExplicitSafetyUpdateRequiresNewerSignedStableChannelArtifact() {
        func permits(_ version: String, channel: String? = nil, url: String = "https://updates.example.invalid/releases/25/Locus-macOS.zip") -> Bool {
            WalletCandidateUpdateAuthority.permitsSafetyUpdate(archiveURL: url, version: version, channel: channel,
                stableFeed: "https://updates.example.invalid/stable/appcast.xml",
                candidateArchive: "https://updates.example.invalid/candidate-24/Locus-macOS.zip", installedVersion: "24")
        }
        XCTAssertTrue(permits("25"))
        XCTAssertFalse(permits("24"))
        XCTAssertFalse(permits("23"))
        XCTAssertFalse(permits("025"))
        XCTAssertFalse(permits("25", channel: "canary"))
        XCTAssertFalse(permits("25", url: "https://untrusted.example.invalid/Locus.zip"))
        XCTAssertFalse(permits("25", url: "http://updates.example.invalid/Locus.zip"))
        XCTAssertFalse(permits("25", url: "https://updates.example.invalid/Locus.zip?token=private"))
    }

    func testOlderProtectedCheckpointDecodesWithoutRetiredCandidateField() throws {
        let value = try verify([transition()]).checkpoint
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WalletAuthorityEncoding.encode(value)) as? [String: Any])
        object.removeValue(forKey: "retiredCandidateIDs")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(WalletReleaseAuthorityCheckpoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, value)
    }
}
