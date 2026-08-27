import Foundation
import XCTest
@testable import Locus

@MainActor
final class BrowserPrivacyTests: XCTestCase {
    func testSettingsMigrationUsesPrivateSecureDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.resolvedBrowserAutofillAuthMode, .session)
        XCTAssertEqual(settings.resolvedBrowserDownloadDestination, .systemDownloads)
        XCTAssertEqual(settings.resolvedBrowserHistoryAccess, .disabled)
        XCTAssertEqual(settings.resolvedBrowserPresentationMode, .fixedCanvas)
        XCTAssertEqual(settings.resolvedBrowserPageAppearance, .automatic)
        XCTAssertEqual(settings.resolvedBrowserPermissionDefaults[.javascript], .allow)
        XCTAssertEqual(settings.resolvedBrowserPermissionDefaults[.userDownloads], .allow)
        XCTAssertEqual(settings.resolvedBrowserPermissionDefaults[.agentDownloads], .ask)
        XCTAssertEqual(settings.resolvedBrowserPermissionDefaults[.fileUploads], .ask)
    }

    func testVaultEncryptsRecordsAndClearsPlaintextWhenLocked() async throws {
        let url = temporaryURL("vault.bin")
        let vault = BrowserAutofillVault(
            fileURL: url,
            keyProvider: InMemoryBrowserVaultKeyProvider()
        )
        let unlocked = await vault.unlock(reason: "Test")
        XCTAssertTrue(unlocked)
        try vault.save(BrowserPasswordRecord(
            origin: "HTTPS://Example.com/login",
            username: "person@example.com",
            password: "unique-secret-value"
        ))

        let bytes = try Data(contentsOf: url)
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "unique-secret-value"))
        XCTAssertEqual(vault.passwords.first?.origin, "https://example.com")

        vault.lock()
        XCTAssertFalse(vault.isUnlocked)
        XCTAssertTrue(vault.passwords.isEmpty)

        let reopened = await vault.unlock(reason: "Test reopen")
        XCTAssertTrue(reopened)
        XCTAssertEqual(vault.passwords.first?.username, "person@example.com")
    }

    func testCardValidationAndEncodingNeverIncludeSecurityCode() async throws {
        let vault = BrowserAutofillVault(
            fileURL: temporaryURL("cards.bin"),
            keyProvider: InMemoryBrowserVaultKeyProvider()
        )
        let unlocked = await vault.unlock(reason: "Test")
        XCTAssertTrue(unlocked)
        let card = BrowserPaymentCardRecord(
            nickname: "Travel",
            cardholder: "A Person",
            number: "4242 4242 4242 4242",
            expirationMonth: 12,
            expirationYear: 2035
        )
        XCTAssertTrue(card.isValid)
        try vault.save(card)
        XCTAssertEqual(vault.cards.first?.maskedNumber, "•••• 4242")

        let encoded = String(decoding: try JSONEncoder().encode(card), as: UTF8.self).lowercased()
        XCTAssertFalse(encoded.contains("cvc"))
        XCTAssertFalse(encoded.contains("cvv"))
        XCTAssertFalse(encoded.contains("cid"))
    }

    func testActivityDatabasePartitionsPersistentWorkspaceProfiles() {
        let database = temporaryURL("activity.sqlite3")
        let first = BrowserActivityStore(databaseURL: database)
        first.configure(profileID: "workspace-a", persistent: true)
        first.recordVisit(
            url: URL(string: "https://example.com/a")!,
            title: "Workspace A",
            visitedAt: Date(timeIntervalSince1970: 1234),
            source: .user
        )

        let reopened = BrowserActivityStore(databaseURL: database)
        reopened.configure(profileID: "workspace-a", persistent: true)
        XCTAssertEqual(reopened.searchHistory(query: "workspace").map(\.title), ["Workspace A"])

        reopened.configure(profileID: "workspace-b", persistent: true)
        XCTAssertTrue(reopened.history.isEmpty)
        reopened.recordVisit(url: URL(string: "https://example.com/b")!, title: "Workspace B", source: .agent)

        reopened.configure(profileID: "workspace-a", persistent: true)
        XCTAssertEqual(reopened.history.count, 1)
        XCTAssertEqual(reopened.history.first?.source, .user)
    }

    func testEphemeralActivityNeverReloadsFromDisk() {
        let database = temporaryURL("ephemeral.sqlite3")
        let store = BrowserActivityStore(databaseURL: database)
        store.configure(profileID: "private", persistent: false)
        store.recordVisit(url: URL(string: "https://private.example")!, title: "Private", source: .user)
        XCTAssertEqual(store.history.count, 1)

        let nextSession = BrowserActivityStore(databaseURL: database)
        nextSession.configure(profileID: "private", persistent: false)
        XCTAssertTrue(nextSession.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testPermissionOriginsIncludeSchemeHostAndPort() {
        let store = BrowserPermissionStore()
        store.configure(profileID: "private", persistent: false)
        store.set(.block, kind: .popups, origin: "HTTPS://Example.COM:8443/path")

        XCTAssertEqual(
            store.decision(for: .popups, url: URL(string: "https://example.com:8443/other")),
            .block
        )
        XCTAssertEqual(
            store.decision(for: .popups, url: URL(string: "https://example.com/other")),
            .ask
        )
    }

    func testPasswordCSVImportValidatesAndRejectsIncompleteRows() throws {
        let url = temporaryURL("passwords.csv")
        try Data("name,url,username,password\nExample,https://example.com/login,user,secret\nBad,https://bad.example,user,\nUnsafe,file:///tmp/passwords,user,secret\n".utf8)
            .write(to: url)
        let preview = try BrowserDataImporter.preview(url: url, kind: .passwords)
        XCTAssertEqual(preview.passwords.count, 1)
        XCTAssertEqual(preview.passwords.first?.origin, "https://example.com")
        XCTAssertEqual(preview.rejectedRows, 2)
    }

    func testContactCSVAndVCardImportsPreviewUserSelectedRecords() throws {
        let csvURL = temporaryURL("contacts.csv")
        try Data("full_name,email,phone,street,city,state,postal_code,country\nA Person,a@example.com,+14165550100,1 Main St,Toronto,ON,M5V 1A1,Canada\n,,,,,,,Canada\n".utf8)
            .write(to: csvURL)
        let csvPreview = try BrowserDataImporter.preview(url: csvURL, kind: .contacts)
        XCTAssertEqual(csvPreview.contacts.first?.fullName, "A Person")
        XCTAssertEqual(csvPreview.contacts.first?.city, "Toronto")
        XCTAssertEqual(csvPreview.rejectedRows, 1)

        let vCardURL = temporaryURL("contacts.vcf")
        try Data("BEGIN:VCARD\nVERSION:3.0\nFN:Example Contact\nEMAIL:contact@example.com\nTEL:+14165550101\nADR:;;2 Main St;Toronto;ON;M5V 2B6;Canada\nEND:VCARD\n".utf8)
            .write(to: vCardURL)
        let vCardPreview = try BrowserDataImporter.preview(url: vCardURL, kind: .contacts)
        XCTAssertEqual(vCardPreview.contacts.first?.email, "contact@example.com")
        XCTAssertEqual(vCardPreview.contacts.first?.street, "2 Main St")
        XCTAssertEqual(vCardPreview.contacts.first?.postalCode, "M5V 2B6")
    }

    func testHistoryJSONImportPreservesTimeAndRejectsNonWebURLs() throws {
        let url = temporaryURL("history.json")
        try Data("""
        {"history":[
          {"url":"https://example.com/path","title":"Example","visited_at":1700000000},
          {"url":"file:///tmp/private.txt","title":"Private file","visited_at":1700000001}
        ]}
        """.utf8).write(to: url)

        let preview = try BrowserDataImporter.preview(url: url, kind: .history)
        XCTAssertEqual(preview.history.count, 1)
        XCTAssertEqual(preview.history.first?.url, "https://example.com/path")
        let visitedAt = try XCTUnwrap(preview.history.first?.visitedAt.timeIntervalSince1970)
        XCTAssertEqual(visitedAt, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(preview.rejectedRows, 1)
    }

    private func temporaryURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocusBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }
}
