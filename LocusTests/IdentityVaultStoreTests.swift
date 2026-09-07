import Foundation
import PDFKit
import Security
import XCTest
@testable import Locus

@MainActor
final class IdentityVaultStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    override func tearDown() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
        super.tearDown()
    }
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("identity-vault-test-\(UUID())", isDirectory: true)
        temporaryDirectories.append(url)
        return url
    }

    func testEncryptedRoundTripIncludesOriginalsDraftsAndApprovedSnapshots() async throws {
        let url = directory()
        let vault = IdentityVaultStore(directoryURL: url, keyProvider: InMemoryIdentityVaultKeyProvider())
        let loaded = await vault.load()
        XCTAssertTrue(loaded)
        let secret = "private-identity-fixture-4982"
        let profile = try vault.saveProfile(.init(name: "Fixture", kind: .career, fields: [.init(key: "skills", label: "Skills", value: secret)]))
        let document = try vault.addDocument(name: "Private résumé.txt", kind: .resume, mimeType: "text/plain", data: Data(secret.utf8), extractedText: secret, profileID: profile.id)
        let draft = try vault.saveDraft(.init(profileID: profile.id, title: "Private draft", sections: [.init(heading: "Skills", text: secret)]))
        let disclosure = try vault.recordDisclosure(.init(taskID: "fixture-task", recipientID: "fixture-provider", recipientLabel: "Fixture", kind: .provider, summary: "Selected skills", fieldIDs: profile.fields.map(\.id)), snapshot: Data(secret.utf8))
        let encryptedFiles = try XCTUnwrap(FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]))
        for file in encryptedFiles.allObjects.compactMap({ $0 as? URL }) {
            if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                XCTAssertNil(try Data(contentsOf: file).range(of: Data(secret.utf8)), "Cleartext in \(file.lastPathComponent)")
            }
        }
        vault.lock()
        XCTAssertTrue(vault.profiles.isEmpty)
        XCTAssertThrowsError(try vault.documentData(id: document.id))
        let reopened = IdentityVaultStore(directoryURL: url, keyProvider: InMemoryIdentityVaultKeyProvider())
        let reloaded = await reopened.load()
        XCTAssertTrue(reloaded)
        XCTAssertEqual(reopened.profiles.first?.fields.first?.value, secret)
        XCTAssertEqual(try reopened.documentData(id: document.id), Data(secret.utf8))
        XCTAssertEqual(reopened.drafts.first?.id, draft.id)
        XCTAssertEqual(try reopened.snapshotText(id: XCTUnwrap(disclosure.snapshotID)), secret)
    }

    func testFailedMetadataCommitPreservesPublishedAndSavedStateAndRemovesNewBlob() async throws {
        let url = directory()
        var failMetadata = false
        let vault = IdentityVaultStore(directoryURL: url, keyProvider: InMemoryIdentityVaultKeyProvider()) { data, destination in
            if failMetadata, destination.lastPathComponent == "vault.bin" { throw CocoaError(.fileWriteNoPermission) }
            try IdentityVaultStore.writeEncrypted(data, to: destination)
        }
        let loaded = await vault.load()
        XCTAssertTrue(loaded)
        let saved = try vault.saveProfile(.init(name: "Original", kind: .personal))
        let originalBytes = try Data(contentsOf: url.appendingPathComponent("vault.bin"))
        failMetadata = true
        var changed = saved
        changed.name = "Replacement"
        XCTAssertThrowsError(try vault.saveProfile(changed))
        XCTAssertEqual(vault.profiles.first?.name, "Original")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("vault.bin")), originalBytes)
        XCTAssertThrowsError(try vault.addDocument(name: "résumé.txt", kind: .resume, mimeType: "text/plain", data: Data("fixture".utf8)))
        XCTAssertTrue(vault.documents.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("blobs").path), [])
    }

    func testImmutableDocumentVersionsAndStaleProfileEdits() async throws {
        let vault = IdentityVaultStore(inMemory: ())
        let loaded = await vault.load()
        XCTAssertTrue(loaded)
        let firstProfile = try vault.saveProfile(.init(name: "Career", kind: .career))
        var changed = firstProfile
        changed.appendCareerEntry(education: false)
        let secondProfile = try vault.saveProfile(changed)
        XCTAssertEqual(secondProfile.revision, 2)
        XCTAssertTrue(secondProfile.fields.contains { $0.key == "employment_2" })
        XCTAssertThrowsError(try vault.saveProfile(firstProfile))
        let first = try vault.addDocument(name: "Résumé.txt", kind: .resume, mimeType: "text/plain", data: Data("first".utf8))
        let second = try vault.addDocument(name: "Résumé.txt", kind: .resume, mimeType: "text/plain", data: Data("second".utf8), replacingDocumentID: first.id)
        XCTAssertEqual(first.groupID, second.groupID)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(try vault.documentData(id: first.id), Data("first".utf8))
        XCTAssertEqual(try vault.documentData(id: second.id), Data("second".utf8))
        try vault.deleteDocument(second.id)
        XCTAssertEqual(try vault.documentData(id: first.id), Data("first".utf8))
    }

    func testTamperingAndCrossBlobSubstitutionFailClosed() async throws {
        let url = directory()
        let vault = IdentityVaultStore(directoryURL: url, keyProvider: InMemoryIdentityVaultKeyProvider())
        let loaded = await vault.load()
        XCTAssertTrue(loaded)
        let first = try vault.addDocument(name: "one.txt", kind: .other, mimeType: "text/plain", data: Data("one".utf8))
        let second = try vault.addDocument(name: "two.txt", kind: .other, mimeType: "text/plain", data: Data("two".utf8))
        let firstBlob = url.appendingPathComponent("blobs/\(first.blobID).bin")
        let secondBlob = url.appendingPathComponent("blobs/\(second.blobID).bin")
        try Data(contentsOf: secondBlob).write(to: firstBlob)
        XCTAssertThrowsError(try vault.documentData(id: first.id))
        let metadataURL = url.appendingPathComponent("vault.bin")
        var metadata = try Data(contentsOf: metadataURL)
        metadata[metadata.count / 2] ^= 1
        try metadata.write(to: metadataURL)
        let reopened = IdentityVaultStore(directoryURL: url, keyProvider: InMemoryIdentityVaultKeyProvider())
        let reopenedResult = await reopened.load()
        XCTAssertFalse(reopenedResult)
        XCTAssertTrue(reopened.documents.isEmpty)
        XCTAssertThrowsError(try reopened.saveProfile(.init(name: "New", kind: .personal)))
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
    }

    func testSnapshotRevocationPreservesAuditAndMemoryVaultsAreIsolated() async throws {
        let first = IdentityVaultStore(inMemory: ()), second = IdentityVaultStore(inMemory: ())
        let firstLoaded = await first.load(), secondLoaded = await second.load()
        XCTAssertTrue(firstLoaded && secondLoaded)
        let id = try first.saveSnapshot(text: "approved fixture")
        let disclosure = try first.recordDisclosure(.init(taskID: "task", recipientID: "provider", recipientLabel: "Provider", kind: .provider, summary: "One field", snapshotID: id))
        XCTAssertThrowsError(try second.snapshotText(id: id))
        try first.revokeDisclosure(id: disclosure.id)
        XCTAssertThrowsError(try first.snapshotText(id: id))
        XCTAssertEqual(first.disclosures.count, 1)
        XCTAssertNil(first.disclosures.first?.snapshotID)
        first.lock()
        let reloaded = await first.load()
        XCTAssertTrue(reloaded)
        XCTAssertNil(first.disclosures.first?.snapshotID)
    }

    func testKeychainIsEditionScopedDeviceLocalAndDoesNotDemandExtraAuthentication() {
        let query = KeychainIdentityVaultKeyProvider.readQuery()
        let add = KeychainIdentityVaultKeyProvider.addQuery(key: Data(repeating: 1, count: 32))
        XCTAssertEqual(query[kSecAttrService] as? String, AppEdition.current.keychainService("identity-vault.v1"))
        XCTAssertNil(query[kSecUseDataProtectionKeychain])
        XCTAssertNil(add[kSecAttrAccessControl])
        XCTAssertEqual(add[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(AppEdition.locus.keychainService("identity-vault.v1"), AppEdition.locusX.keychainService("identity-vault.v1"))
    }

    func testLockWhileKeyLoadsCannotReopenVault() async throws {
        let provider = SuspendedIdentityVaultFixtureKeyProvider()
        let vault = IdentityVaultStore(directoryURL: directory(), keyProvider: provider)
        let loading = Task { await vault.load() }
        await provider.waitUntilRequested()
        vault.lock()
        await provider.release()
        let loaded = await loading.value
        XCTAssertFalse(loaded)
        XCTAssertFalse(vault.isReady)
        XCTAssertTrue(vault.profiles.isEmpty)
        XCTAssertThrowsError(try vault.saveProfile(.init(name: "Should stay locked", kind: .personal)))
    }

    func testLocalResumeSuggestionsAreReviewableAndPDFRoundTripsText() async throws {
        let text = "Example Person\nexample@fixture.invalid\n+1 416 555 0100\nSKILLS\nSwift and design\nEXPERIENCE\nEngineer at Example\nEDUCATION\nExample University"
        let imported = try await IdentityVaultDocuments.extract(data: Data(text.utf8), name: "résumé.txt")
        let suggestions = IdentityVaultDocuments.suggestedFields(from: imported.extractedText)
        XCTAssertEqual(suggestions.first(where: { $0.key == "email" })?.value, "example@fixture.invalid")
        XCTAssertEqual(suggestions.first(where: { $0.key == "employment_1" })?.value, "Engineer at Example")
        let pdf = try IdentityVaultDocuments.generatePDF(title: "Example résumé", sections: [.init(heading: "Skills", text: "Swift and design")])
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains("Swift and design") == true)
        let read = try await IdentityVaultDocuments.extract(data: pdf, name: "résumé.pdf")
        XCTAssertTrue(read.extractedText.contains("Example résumé"))
    }

    func testRevokingEarlierSourceDuringLaterReviewPreventsWholeBatchRelease() async throws {
        let model = IdentityVaultModel(store: IdentityVaultStore(inMemory: ()))
        let loaded = await model.ready()
        XCTAssertTrue(loaded)
        model.registerSession("private-task")
        let provider = IdentityProviderIdentity(accountID: "fixture", provider: "remote",
            endpoint: "https://fixture.invalid", model: "fixture-model", label: "Fixture provider")
        let ids = try [model.store.saveSnapshot(text: "REVOKED_PRIVATE_FIXTURE_A"),
                       model.store.saveSnapshot(text: "REVOKED_PRIVATE_FIXTURE_B")].sorted { $0.uuidString < $1.uuidString }
        let firstDisclosure = try model.store.recordDisclosure(.init(taskID: "private-task", recipientID: provider.recipientID,
            recipientLabel: provider.label, kind: .provider, summary: "First source", snapshotID: ids[0]))
        try model.store.recordDisclosure(.init(taskID: "private-task", recipientID: provider.recipientID,
            recipientLabel: provider.label, kind: .provider, summary: "Second source", snapshotID: ids[1]))
        _ = model.rememberSource(snapshotID: ids[0], session: "private-task", provider: provider)
        let task = Task { await model.resolveSources(ids.map(\.uuidString), session: "private-task", provider: provider) }
        for _ in 0..<1_000 {
            if model.pendingReview != nil { break }
            await Task.yield()
        }
        let review = try XCTUnwrap(model.pendingReview)
        model.revoke(firstDisclosure)
        model.answerReview(id: review.id, selected: Set(review.items.map(\.id)))
        let result = await task.value
        XCTAssertNotNil(result["error"])
        XCTAssertNil(result["sources"])
        XCTAssertFalse(String(describing: result).contains("REVOKED_PRIVATE_FIXTURE"))
    }
}

private actor SuspendedIdentityVaultFixtureKeyProvider: IdentityVaultKeyProviding {
    private var requested = false
    private var keyContinuation: CheckedContinuation<Data, Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    func keyData() async throws -> Data {
        requested = true
        for continuation in startContinuations { continuation.resume() }
        startContinuations = []
        return try await withCheckedThrowingContinuation { keyContinuation = $0 }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }
    func release() {
        keyContinuation?.resume(returning: Data(repeating: 1, count: 32))
        keyContinuation = nil
    }
}
