import CryptoKit
import XCTest
@testable import Locus

final class WalletReleaseActivationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let key = Curve25519.Signing.PrivateKey()
    private var identity: WalletInstalledReleaseIdentity {
        .init(sourceRevision: String(repeating: "a", count: 40), bundleVersion: "24",
              outerAppCodeDirectoryHash: String(repeating: "b", count: 40),
              signerCodeDirectoryHash: String(repeating: "c", count: 40))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func review(revision: Int, adapters: Set<String> = []) throws -> WalletSignedReviewManifest {
        let manifest = WalletReviewManifest(
            schemaVersion: 2, revision: revision, issuedAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(3_600), assets: [], evmContracts: [],
            explorerTemplates: [:], adapterIDs: adapters
        )
        return .init(manifest: manifest,
                     signatureBase64: try key.signature(for: encode(manifest)).base64EncodedString())
    }

    private func signed(revision: Int = 2, archive: String? = nil,
                        expiresAt: Date? = nil, adapters: Set<String> = []) throws
        -> WalletSignedReleaseActivationEnvelope {
        let manifest = WalletCapabilityManifest(
            schemaVersion: 3, revision: revision, releaseStage: .invitedCanary,
            evidenceIndexSHA256: String(repeating: "d", count: 64),
            issuedAt: now.addingTimeInterval(-30), expiresAt: now.addingTimeInterval(3_600),
            networkGrants: [.init(networkID: "eip155:11155111",
                capabilities: [.nativeTransfer, .externalWallet],
                connectors: [.init(connector: .metamask, ownership: .external,
                    directions: [.externalAccountToLocus],
                    methods: [.sendTransaction, .listAccounts])])],
            approvedRegions: ["CA", "US"], completedApprovals: WalletLaunchGate.requiredCanaryApprovals
        )
        let envelope = WalletReleaseActivationEnvelope(
            schemaVersion: 1, sourceRevision: identity.sourceRevision,
            bundleVersion: identity.bundleVersion,
            outerAppCodeDirectoryHash: identity.outerAppCodeDirectoryHash,
            signerCodeDirectoryHash: identity.signerCodeDirectoryHash,
            archiveSHA256: archive ?? String(repeating: "e", count: 64),
            releaseStage: .invitedCanary, issuedAt: now.addingTimeInterval(-60),
            expiresAt: expiresAt ?? now.addingTimeInterval(3_600), revision: revision,
            capabilityManifest: .init(manifest: manifest,
                signatureBase64: try key.signature(for: encode(manifest)).base64EncodedString()),
            reviewRestriction: try review(revision: revision, adapters: adapters)
        )
        return .init(envelope: envelope,
                     signatureBase64: try key.signature(for: encode(envelope)).base64EncodedString())
    }

    private func verify(_ value: WalletSignedReleaseActivationEnvelope,
                        identity otherIdentity: WalletInstalledReleaseIdentity? = nil,
                        minimumRevision: Int = 0, acceptedDigest: String? = nil,
                        at date: Date? = nil) throws -> WalletVerifiedReleaseActivation {
        try WalletReleaseActivationVerifier.verify(value, publicKey: key.publicKey,
            bundledReviewCeiling: WalletReviewRegistry(signedManifest: review(revision: 1),
                publicKey: key.publicKey, now: now),
            installedIdentity: otherIdentity ?? identity, minimumRevision: minimumRevision,
            acceptedEnvelopeSHA256: acceptedDigest, now: date ?? now)
    }

    func testSignedEnvelopeSurvivesIndependentDecodeAndSetOrdering() throws {
        let original = try signed()
        let bytes = try encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for _ in 0..<50 {
            let decoded = try decoder.decode(WalletSignedReleaseActivationEnvelope.self, from: bytes)
            XCTAssertEqual(try encode(decoded), bytes)
            XCTAssertEqual(try verify(decoded).launchGate.effectiveManifest?.revision, 2)
        }
    }

    func testTamperingIdentityExpiryAndRollbackFailClosed() throws {
        let valid = try signed()
        XCTAssertThrowsError(try verify(.init(envelope: valid.envelope,
            signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()))) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .invalidSignature)
        }
        let other = WalletInstalledReleaseIdentity(sourceRevision: identity.sourceRevision,
            bundleVersion: "25", outerAppCodeDirectoryHash: identity.outerAppCodeDirectoryHash,
            signerCodeDirectoryHash: identity.signerCodeDirectoryHash)
        XCTAssertThrowsError(try verify(valid, identity: other)) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .identityMismatch)
        }
        XCTAssertThrowsError(try verify(valid, minimumRevision: 3)) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .rollback)
        }
        XCTAssertThrowsError(try verify(valid, at: now.addingTimeInterval(3_601))) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .expired)
        }
    }

    func testSameRevisionCannotSubstituteDifferentReleaseData() throws {
        let valid = try signed()
        let digest = try verify(valid).envelopeSHA256
        XCTAssertNoThrow(try verify(valid, minimumRevision: 2, acceptedDigest: digest))
        let substituted = try signed(archive: String(repeating: "f", count: 64))
        XCTAssertThrowsError(try verify(substituted, minimumRevision: 2, acceptedDigest: digest)) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .revisionConflict)
        }
    }

    func testReviewRestrictionCannotAddAnAdapter() throws {
        XCTAssertThrowsError(try verify(signed(adapters: [WalletReviewedAdapters.erc20]))) {
            XCTAssertEqual($0 as? WalletReleaseActivationError, .broaderThanCeiling)
        }
    }
}

final class WalletPairingURIIntakeTests: XCTestCase {
    private let topic = String(repeating: "a", count: 64)
    private let key = String(repeating: "b", count: 64)
    private var uri: String { "wc:\(topic)@2?relay-protocol=irn&symKey=\(key)" }

    func testCanonicalPairingAndReorderedFieldsHaveOneReplayIdentity() throws {
        let first = try WalletPairingURIIntake.validated(uri)
        let reordered = try WalletPairingURIIntake.validated("wc:\(topic)@2?symKey=\(key)&relay-protocol=irn")
        XCTAssertEqual(WalletPairingURIIntake.digest(first), WalletPairingURIIntake.digest(reordered))
    }

    func testRejectsOversizedDuplicateUnknownExpiredAndMalformedPairings() {
        let invalid = [String(repeating: " ", count: 2_049) + uri,
            uri + "&symKey=\(key)", uri + "&unknown=1", uri + "&expiryTimestamp=1",
            uri + "&expiryTimestamp=nan", uri + "#fragment",
            uri.replacingOccurrences(of: "@2", with: "@1")]
        for candidate in invalid { XCTAssertThrowsError(try WalletPairingURIIntake.validated(candidate)) }
    }

    func testDeepLinkRequiresExactlyOneBoundedURI() throws {
        var link = URLComponents(string: "locus-wallet://wc")!
        link.queryItems = [.init(name: "uri", value: uri)]
        XCTAssertEqual(try WalletPairingURIIntake.pairingURI(fromDeepLink: link.url!), uri)
        link.queryItems?.append(.init(name: "uri", value: uri))
        XCTAssertThrowsError(try WalletPairingURIIntake.pairingURI(fromDeepLink: link.url!))
    }
}

final class WalletCanaryBudgetTests: XCTestCase {
    private var limit: WalletCanaryLimit {
        .init(networkID: "eip155:1", assetID: WalletNetworkCatalog.ethereumMainnet.nativeAssetID,
              action: .nativeTransfer, ownership: .external, connector: .metamask,
              maximumTransactionBaseUnits: "100", maximumCumulativeBaseUnits: "150",
              maximumFeeBaseUnits: "10", maximumCumulativeFeeBaseUnits: "15",
              maximumTransactions: 2)
    }

    func testCumulativeAmountFeesAndCountRemainAuthoritative() throws {
        let first = try WalletCanaryBudget.next(.init(), amount: "100", fee: "10", limit: limit)
        let persisted = try JSONEncoder().encode(first)
        let restored = try JSONDecoder().decode(WalletCanaryBudget.Usage.self, from: persisted)
        XCTAssertThrowsError(try WalletCanaryBudget.next(restored, amount: "51", fee: "0", limit: limit))
        XCTAssertThrowsError(try WalletCanaryBudget.next(restored, amount: "1", fee: "6", limit: limit))
        let final = try WalletCanaryBudget.next(restored, amount: "50", fee: "5", limit: limit)
        XCTAssertThrowsError(try WalletCanaryBudget.next(final, amount: "0", fee: "0", limit: limit))
    }

    func testNoncanonicalAndOverflowAmountsCannotConsumeBudget() {
        for amount in ["-1", "+1", "01", "1.0", "", String(repeating: "9", count: 79)] {
            XCTAssertThrowsError(try WalletCanaryBudget.next(.init(), amount: amount, fee: "0", limit: limit))
        }
        XCTAssertThrowsError(try WalletCanaryBudget.next(.init(amount: "bad"), amount: "1", fee: "0", limit: limit))
    }
}

final class WalletActivationRevisionTests: XCTestCase {
    func testOutOfOrderAppendOnlyRecordsKeepTheHighestRevision() throws {
        let old = WalletSignerActivationRevisionStore.Accepted(
            revision: 4, envelopeSHA256: String(repeating: "a", count: 64))
        let newest = WalletSignerActivationRevisionStore.Accepted(
            revision: 6, envelopeSHA256: String(repeating: "b", count: 64))
        let delayed = WalletSignerActivationRevisionStore.Accepted(
            revision: 5, envelopeSHA256: String(repeating: "c", count: 64))
        XCTAssertEqual(try WalletSignerActivationRevisionStore.highestAccepted(
            [newest, old, delayed, old]), newest)
        XCTAssertEqual(try WalletSignerActivationRevisionStore.highestAccepted(
            [old, delayed, newest]), newest)
    }

    func testConflictingOrMalformedRevisionStateFailsClosed() throws {
        let original = WalletSignerActivationRevisionStore.Accepted(
            revision: 4, envelopeSHA256: String(repeating: "a", count: 64))
        let conflict = WalletSignerActivationRevisionStore.Accepted(
            revision: 4, envelopeSHA256: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try WalletSignerActivationRevisionStore.highestAccepted(
            [original, conflict]))
        for invalid in [WalletSignerActivationRevisionStore.Accepted(
            revision: 0, envelopeSHA256: String(repeating: "a", count: 64)),
            .init(revision: 5, envelopeSHA256: String(repeating: "Z", count: 64))] {
            XCTAssertThrowsError(try WalletSignerActivationRevisionStore.highestAccepted(
                [original, invalid]))
        }
    }
}
