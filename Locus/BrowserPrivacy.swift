import AppKit
import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SQLite3
import WebKit

// MARK: - Migration-safe browser preferences

enum BrowserAutofillAuthMode: String, CaseIterable, Codable, Identifiable {
    case session
    case eachFill

    var id: String { rawValue }
    var title: String { self == .session ? "Once per session" : "Every fill" }
}

enum BrowserDownloadDestinationKind: String, CaseIterable, Codable, Identifiable {
    case systemDownloads
    case locus
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemDownloads: "Downloads"
        case .locus: "Locus storage"
        case .custom: "Custom folder"
        }
    }
}

enum BrowserHistoryAccess: String, CaseIterable, Codable, Identifiable {
    case disabled
    case ask
    case always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Disable"
        case .ask: "Ask"
        case .always: "Always allow"
        }
    }
}

enum BrowserPresentationMode: String, CaseIterable, Codable, Identifiable {
    case fixedCanvas

    var id: String { rawValue }
    var title: String { "Fixed viewport canvas" }
}

enum BrowserPageAppearance: String, CaseIterable, Codable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BrowserPermissionDecision: String, CaseIterable, Codable, Identifiable {
    case allow
    case ask
    case block

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BrowserPermissionKind: String, CaseIterable, Codable, Identifiable {
    case javascript
    case userDownloads
    case agentDownloads
    case fileUploads
    case popups
    case externalSchemes
    case camera
    case microphone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .javascript: "JavaScript"
        case .userDownloads: "Downloads you start"
        case .agentDownloads: "Agent and automatic downloads"
        case .fileUploads: "File uploads"
        case .popups: "Popups and redirects"
        case .externalSchemes: "External application links"
        case .camera: "Camera"
        case .microphone: "Microphone"
        }
    }

    var symbol: String {
        switch self {
        case .javascript: "curlybraces"
        case .userDownloads, .agentDownloads: "arrow.down.circle"
        case .fileUploads: "arrow.up.doc"
        case .popups: "macwindow.on.rectangle"
        case .externalSchemes: "arrow.up.right.square"
        case .camera: "camera"
        case .microphone: "mic"
        }
    }

    var defaultDecision: BrowserPermissionDecision {
        switch self {
        case .javascript, .userDownloads: .allow
        case .agentDownloads, .fileUploads, .popups, .externalSchemes, .camera, .microphone:
            .ask
        }
    }
}

enum BrowserDataType: String, CaseIterable, Codable, Identifiable {
    case history
    case downloadHistory
    case cookies
    case cache
    case websiteData

    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: "Browsing history"
        case .downloadHistory: "Download history"
        case .cookies: "Cookies"
        case .cache: "Cached images and files"
        case .websiteData: "Site storage"
        }
    }

    var webKitTypes: Set<String> {
        switch self {
        case .history, .downloadHistory: []
        case .cookies: [WKWebsiteDataTypeCookies]
        case .cache: [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        case .websiteData: [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
        }
    }
}

// MARK: - Autofill vault

struct BrowserPasswordRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var origin: String
    var username: String
    var password: String
    var label = ""
    var createdAt = Date()
    var updatedAt = Date()

    var displayOrigin: String { URL(string: origin)?.host ?? origin }
}

struct BrowserContactRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var label = "Personal"
    var fullName = ""
    var organization = ""
    var email = ""
    var phone = ""
    var street = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = ""
    var createdAt = Date()
    var updatedAt = Date()

    var summary: String {
        [email, phone, city].first(where: { !$0.isEmpty }) ?? "Empty contact"
    }
}

struct BrowserPaymentCardRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var nickname = "Card"
    var cardholder = ""
    var number = ""
    var expirationMonth = 1
    var expirationYear = Calendar.current.component(.year, from: Date())
    var billingContactID: UUID?
    var createdAt = Date()
    var updatedAt = Date()

    var normalizedNumber: String { number.filter(\.isNumber) }
    var lastFour: String { String(normalizedNumber.suffix(4)) }
    var maskedNumber: String { lastFour.isEmpty ? "No number" : "•••• \(lastFour)" }

    var isValid: Bool {
        let digits = normalizedNumber.compactMap(\.wholeNumberValue)
        guard (12...19).contains(digits.count), (1...12).contains(expirationMonth) else {
            return false
        }
        let total = digits.reversed().enumerated().reduce(0) { result, item in
            let (offset, digit) = item
            if offset.isMultiple(of: 2) { return result + digit }
            let doubled = digit * 2
            return result + (doubled > 9 ? doubled - 9 : doubled)
        }
        return total.isMultiple(of: 10)
    }
}

private struct BrowserVaultPayload: Codable {
    var version = 1
    var passwords: [BrowserPasswordRecord] = []
    var contacts: [BrowserContactRecord] = []
    var cards: [BrowserPaymentCardRecord] = []
}

enum BrowserVaultError: LocalizedError {
    case locked
    case authenticationFailed
    case invalidCard
    case corruptVault

    var errorDescription: String? {
        switch self {
        case .locked: "Unlock Autofill before making changes."
        case .authenticationFailed: "Autofill could not be unlocked."
        case .invalidCard: "Enter a valid card number and expiration date. Security codes are never stored."
        case .corruptVault: "The encrypted Autofill data could not be opened."
        }
    }
}

protocol BrowserVaultKeyProviding: Sendable {
    func keyData(reason: String) async throws -> Data
}

struct KeychainBrowserVaultKeyProvider: BrowserVaultKeyProviding {
    static let service = "io.sparktales.locus.browser-autofill"
    static let account = "vault-master-key-v1"

    func keyData(reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
            kSecUseDataProtectionKeychain: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }
        guard status == errSecItemNotFound else { throw BrowserVaultError.authenticationFailed }

        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else { throw error?.takeRetainedValue() ?? BrowserVaultError.authenticationFailed }

        query.removeAll()
        query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecValueData: key,
            kSecAttrAccessControl: access,
            kSecUseDataProtectionKeychain: true,
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw BrowserVaultError.authenticationFailed }
        return key
    }
}

struct InMemoryBrowserVaultKeyProvider: BrowserVaultKeyProviding {
    let data: Data
    init(data: Data = Data(repeating: 7, count: 32)) { self.data = data }
    func keyData(reason: String) async throws -> Data { data }
}

@MainActor
final class BrowserAutofillVault: ObservableObject {
    @Published private(set) var passwords: [BrowserPasswordRecord] = []
    @Published private(set) var contacts: [BrowserContactRecord] = []
    @Published private(set) var cards: [BrowserPaymentCardRecord] = []
    @Published private(set) var isUnlocked = false
    @Published private(set) var lastError: String?

    var authMode: BrowserAutofillAuthMode = .session
    private let fileURL: URL
    private let keyProvider: any BrowserVaultKeyProviding
    private var key: SymmetricKey?

    init(
        fileURL: URL? = nil,
        keyProvider: any BrowserVaultKeyProviding = KeychainBrowserVaultKeyProvider()
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.keyProvider = keyProvider
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Locus/Browser/Autofill/vault.bin")
    }

    var totalCount: Int { passwords.count + contacts.count + cards.count }

    @discardableResult
    func unlock(reason: String = "Unlock Locus Autofill") async -> Bool {
        if isUnlocked { return true }
        do {
            let data = try await keyProvider.keyData(reason: reason)
            let key = SymmetricKey(data: data)
            let payload = try readPayload(using: key)
            self.key = key
            passwords = payload.passwords.sorted { $0.updatedAt > $1.updatedAt }
            contacts = payload.contacts.sorted { $0.updatedAt > $1.updatedAt }
            cards = payload.cards.sorted { $0.updatedAt > $1.updatedAt }
            isUnlocked = true
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func lock() {
        key = nil
        passwords.removeAll()
        contacts.removeAll()
        cards.removeAll()
        isUnlocked = false
    }

    func save(_ record: BrowserPasswordRecord) throws {
        guard isUnlocked else { throw BrowserVaultError.locked }
        var record = record
        record.origin = Self.normalizedOrigin(record.origin)
        record.updatedAt = Date()
        upsert(record, in: &passwords)
        try persist()
    }

    func save(_ record: BrowserContactRecord) throws {
        guard isUnlocked else { throw BrowserVaultError.locked }
        var record = record
        record.updatedAt = Date()
        upsert(record, in: &contacts)
        try persist()
    }

    func save(_ record: BrowserPaymentCardRecord) throws {
        guard isUnlocked else { throw BrowserVaultError.locked }
        var record = record
        record.number = record.normalizedNumber
        guard record.isValid else { throw BrowserVaultError.invalidCard }
        record.updatedAt = Date()
        upsert(record, in: &cards)
        try persist()
    }

    func removePassword(_ id: UUID) throws { try remove(id, from: &passwords) }
    func removeContact(_ id: UUID) throws { try remove(id, from: &contacts) }
    func removeCard(_ id: UUID) throws { try remove(id, from: &cards) }

    func passwordSuggestions(for origin: String) -> [BrowserPasswordRecord] {
        guard isUnlocked else { return [] }
        let normalized = Self.normalizedOrigin(origin)
        return passwords.filter { Self.normalizedOrigin($0.origin) == normalized }
    }

    func contactSuggestions() -> [BrowserContactRecord] { isUnlocked ? contacts : [] }
    func cardSuggestions() -> [BrowserPaymentCardRecord] { isUnlocked ? cards : [] }

    nonisolated static func normalizedOrigin(_ raw: String) -> String {
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else { return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let standard = (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let port = components.port.map { standard ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func upsert<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.insert(value, at: 0)
        }
    }

    private func remove<T: Identifiable>(_ id: UUID, from values: inout [T]) throws where T.ID == UUID {
        guard isUnlocked else { throw BrowserVaultError.locked }
        values.removeAll { $0.id == id }
        try persist()
    }

    private func readPayload(using key: SymmetricKey) throws -> BrowserVaultPayload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return BrowserVaultPayload()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let box = try AES.GCM.SealedBox(combined: data)
            let clear = try AES.GCM.open(box, using: key)
            return try JSONDecoder.browser.decode(BrowserVaultPayload.self, from: clear)
        } catch {
            throw BrowserVaultError.corruptVault
        }
    }

    private func persist() throws {
        guard let key else { throw BrowserVaultError.locked }
        let payload = BrowserVaultPayload(passwords: passwords, contacts: contacts, cards: cards)
        let clear = try JSONEncoder.browser.encode(payload)
        let sealed = try AES.GCM.seal(clear, using: key)
        guard let combined = sealed.combined else { throw BrowserVaultError.corruptVault }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONEncoder {
    static var browser: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var browser: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Browsing and download activity database

enum BrowserVisitSource: String, Codable, CaseIterable {
    case user
    case agent
}

struct BrowserHistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var profileID: String
    var url: String
    var title: String
    var visitedAt = Date()
    var source: BrowserVisitSource

    var host: String { URL(string: url)?.host ?? url }
}

enum BrowserDownloadState: String, Codable, CaseIterable {
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct BrowserDownloadRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var profileID: String
    var sourceURL: String
    var destinationPath: String
    var fileName: String
    var state: BrowserDownloadState = .running
    var progress: Double = 0
    var errorMessage: String?
    var createdAt = Date()
    var updatedAt = Date()

    var destinationURL: URL? {
        destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath)
    }
}

@MainActor
final class BrowserActivityStore: ObservableObject {
    @Published private(set) var history: [BrowserHistoryEntry] = []
    @Published private(set) var downloads: [BrowserDownloadRecord] = []

    private var db: OpaquePointer?
    private var profileID = "ephemeral"
    private var persistent = false
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
    }

    var currentProfileID: String { profileID }
    var isPersistent: Bool { persistent }

    deinit { if let db { sqlite3_close(db) } }

    static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Locus/Browser/activity.sqlite3")
    }

    func configure(profileID: String, persistent: Bool) {
        guard self.profileID != profileID || self.persistent != persistent else { return }
        if let db { sqlite3_close(db) }
        db = nil
        history.removeAll()
        downloads.removeAll()
        self.profileID = profileID
        self.persistent = persistent
        guard persistent else { return }
        openDatabase()
        reload()
    }

    func recordVisit(
        url: URL,
        title: String,
        visitedAt: Date = Date(),
        source: BrowserVisitSource
    ) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let entry = BrowserHistoryEntry(
            profileID: profileID,
            url: url.absoluteString,
            title: title,
            visitedAt: visitedAt,
            source: source
        )
        history.insert(entry, at: 0)
        if history.count > 1_000 { history.removeLast(history.count - 1_000) }
        guard persistent, let db else { return }
        execute(
            "INSERT INTO history(id, profile, url, title, visited, source) VALUES(?,?,?,?,?,?)",
            bindings: [
                entry.id.uuidString, entry.profileID, entry.url, entry.title,
                entry.visitedAt.timeIntervalSince1970, entry.source.rawValue,
            ],
            db: db
        )
    }

    func searchHistory(query: String = "", limit: Int = 100) -> [BrowserHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history.lazy.filter { entry in
            needle.isEmpty || entry.url.lowercased().contains(needle)
                || entry.title.lowercased().contains(needle)
        }.prefix(max(1, min(limit, 500))).map { $0 }
    }

    func removeHistory(ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        guard persistent, let db, !ids.isEmpty else { return }
        for id in ids {
            execute("DELETE FROM history WHERE id=? AND profile=?", bindings: [id.uuidString, profileID], db: db)
        }
    }

    func clearHistory() {
        history.removeAll()
        if persistent, let db {
            execute("DELETE FROM history WHERE profile=?", bindings: [profileID], db: db)
        }
    }

    func beginDownload(_ record: BrowserDownloadRecord) {
        downloads.removeAll { $0.id == record.id }
        downloads.insert(record, at: 0)
        writeDownload(record)
    }

    func updateDownload(
        id: UUID,
        state: BrowserDownloadState? = nil,
        progress: Double? = nil,
        destinationPath: String? = nil,
        error: String? = nil
    ) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        if let state { downloads[index].state = state }
        if let progress { downloads[index].progress = max(0, min(progress, 1)) }
        if let destinationPath { downloads[index].destinationPath = destinationPath }
        downloads[index].errorMessage = error
        downloads[index].updatedAt = Date()
        writeDownload(downloads[index])
    }

    func removeDownload(_ id: UUID) {
        downloads.removeAll { $0.id == id }
        if persistent, let db {
            execute("DELETE FROM downloads WHERE id=? AND profile=?", bindings: [id.uuidString, profileID], db: db)
        }
    }

    func clearDownloads() {
        downloads.removeAll()
        if persistent, let db {
            execute("DELETE FROM downloads WHERE profile=?", bindings: [profileID], db: db)
        }
    }

    private func openDatabase() {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else { return }
        sqlite3_busy_timeout(db, 2_000)
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
        _ = sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS history(
              id TEXT PRIMARY KEY, profile TEXT NOT NULL, url TEXT NOT NULL,
              title TEXT NOT NULL, visited REAL NOT NULL, source TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS history_profile_visited ON history(profile, visited DESC);
            CREATE INDEX IF NOT EXISTS history_profile_url ON history(profile, url);
            CREATE TABLE IF NOT EXISTS downloads(
              id TEXT PRIMARY KEY, profile TEXT NOT NULL, source_url TEXT NOT NULL,
              destination TEXT NOT NULL, filename TEXT NOT NULL, state TEXT NOT NULL,
              progress REAL NOT NULL, error TEXT, created REAL NOT NULL, updated REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS downloads_profile_updated ON downloads(profile, updated DESC);
            """, nil, nil, nil)
    }

    private func reload() {
        guard let db else { return }
        history = query(
            "SELECT id,profile,url,title,visited,source FROM history WHERE profile=? ORDER BY visited DESC LIMIT 1000",
            bindings: [profileID],
            db: db
        ) { row in
            BrowserHistoryEntry(
                id: UUID(uuidString: row.text(0)) ?? UUID(),
                profileID: row.text(1),
                url: row.text(2),
                title: row.text(3),
                visitedAt: Date(timeIntervalSince1970: row.double(4)),
                source: BrowserVisitSource(rawValue: row.text(5)) ?? .user
            )
        }
        downloads = query(
            "SELECT id,profile,source_url,destination,filename,state,progress,error,created,updated FROM downloads WHERE profile=? ORDER BY updated DESC LIMIT 1000",
            bindings: [profileID],
            db: db
        ) { row in
            BrowserDownloadRecord(
                id: UUID(uuidString: row.text(0)) ?? UUID(),
                profileID: row.text(1),
                sourceURL: row.text(2),
                destinationPath: row.text(3),
                fileName: row.text(4),
                state: BrowserDownloadState(rawValue: row.text(5)) ?? .failed,
                progress: row.double(6),
                errorMessage: row.optionalText(7),
                createdAt: Date(timeIntervalSince1970: row.double(8)),
                updatedAt: Date(timeIntervalSince1970: row.double(9))
            )
        }
    }

    private func writeDownload(_ record: BrowserDownloadRecord) {
        guard persistent, let db else { return }
        execute(
            "INSERT OR REPLACE INTO downloads(id,profile,source_url,destination,filename,state,progress,error,created,updated) VALUES(?,?,?,?,?,?,?,?,?,?)",
            bindings: [
                record.id.uuidString, record.profileID, record.sourceURL,
                record.destinationPath, record.fileName, record.state.rawValue,
                record.progress, record.errorMessage as Any,
                record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970,
            ],
            db: db
        )
    }

    private struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: pointer)
        }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
        }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    private func query<T>(
        _ sql: String,
        bindings: [Any],
        db: OpaquePointer,
        map: (Row) -> T
    ) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(map(Row(statement: statement))) }
        return values
    }

    private func execute(_ sql: String, bindings: [Any], db: OpaquePointer) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        _ = sqlite3_step(statement)
    }

    private func bind(_ values: [Any], to statement: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String:
                sqlite3_bind_text(statement, index, value, -1, transient)
            case let value as Double:
                sqlite3_bind_double(statement, index, value)
            case let value as Int:
                sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case Optional<Any>.none:
                sqlite3_bind_null(statement, index)
            default:
                if let value = value as? String {
                    sqlite3_bind_text(statement, index, value, -1, transient)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }
    }
}

// MARK: - Per-site permissions

struct BrowserSitePermissionOverride: Codable, Hashable, Identifiable {
    var id: String { "\(origin)|\(kind.rawValue)" }
    var origin: String
    var kind: BrowserPermissionKind
    var decision: BrowserPermissionDecision
}

@MainActor
final class BrowserPermissionStore: ObservableObject {
    @Published private(set) var overrides: [BrowserSitePermissionOverride] = []
    var defaults: [BrowserPermissionKind: BrowserPermissionDecision] = Dictionary(
        uniqueKeysWithValues: BrowserPermissionKind.allCases.map { ($0, $0.defaultDecision) }
    )

    private var persistent = false
    private var profileID = "ephemeral"

    func configure(profileID: String, persistent: Bool) {
        guard self.profileID != profileID || self.persistent != persistent else { return }
        self.profileID = profileID
        self.persistent = persistent
        overrides = persistent ? ((try? JSONDecoder.browser.decode(
            [BrowserSitePermissionOverride].self,
            from: Data(contentsOf: fileURL)
        )) ?? []) : []
    }

    func decision(for kind: BrowserPermissionKind, url: URL?) -> BrowserPermissionDecision {
        guard let origin = url.map(Self.normalizedOrigin) else {
            return defaults[kind] ?? kind.defaultDecision
        }
        return overrides.first { $0.origin == origin && $0.kind == kind }?.decision
            ?? defaults[kind]
            ?? kind.defaultDecision
    }

    func set(_ decision: BrowserPermissionDecision, kind: BrowserPermissionKind, origin: String) {
        let origin = Self.normalizedOrigin(URL(string: origin) ?? URL(string: "https://invalid")!)
        overrides.removeAll { $0.origin == origin && $0.kind == kind }
        overrides.append(.init(origin: origin, kind: kind, decision: decision))
        persist()
    }

    func remove(_ override: BrowserSitePermissionOverride) {
        overrides.removeAll { $0.id == override.id }
        persist()
    }

    func clear() {
        overrides.removeAll()
        persist()
    }

    static func normalizedOrigin(_ url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme?.lowercased() ?? "https")://\(url.host?.lowercased() ?? "")\(port)"
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Locus/Browser/Permissions/\(profileID).json")
    }

    private func persist() {
        guard persistent else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder.browser.encode(overrides).write(to: fileURL, options: .atomic)
        } catch {
            // A permission write failing must never widen authority. The live
            // in-memory decision remains, and the next launch returns to the
            // conservative configured default.
        }
    }
}

struct BrowserWebsiteDataRecord: Identifiable, Hashable {
    var id: String { displayName }
    var displayName: String
    var dataTypes: Set<String>
}

enum BrowserAutofillCategory: String, Codable {
    case password
    case contact
    case paymentCard
}

struct BrowserAutofillPrompt: Identifiable, Equatable {
    var id = UUID()
    var sessionID: String
    var origin: String
    var category: BrowserAutofillCategory
    var fieldName: String
    var fieldRect: CGRect
}

struct BrowserPasswordSavePrompt: Identifiable, Equatable {
    var id = UUID()
    var sessionID: String
    var origin: String
    var username: String
    /// Held only until the native banner is accepted or dismissed. It is never
    /// published into logs, accessibility values, or an agent response.
    var password: String
}

// MARK: - Import preview

enum BrowserImportKind: String, CaseIterable, Identifiable {
    case passwords
    case contacts
    case history

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct BrowserImportPreview {
    var passwords: [BrowserPasswordRecord] = []
    var contacts: [BrowserContactRecord] = []
    var history: [(url: String, title: String, visitedAt: Date)] = []
    var rejectedRows = 0

    var count: Int { passwords.count + contacts.count + history.count }
}

enum BrowserDataImporter {
    static func preview(url: URL, kind: BrowserImportKind) throws -> BrowserImportPreview {
        let data = try Data(contentsOf: url)
        switch kind {
        case .passwords:
            return previewPasswords(csv: String(decoding: data, as: UTF8.self))
        case .contacts:
            if url.pathExtension.lowercased() == "vcf" {
                return previewVCard(String(decoding: data, as: UTF8.self))
            }
            return previewContacts(csv: String(decoding: data, as: UTF8.self))
        case .history:
            if url.pathExtension.lowercased() == "json" {
                return try previewHistoryJSON(data)
            }
            return previewHistoryCSV(String(decoding: data, as: UTF8.self))
        }
    }

    private static func previewPasswords(csv: String) -> BrowserImportPreview {
        let rows = CSV.rows(csv)
        guard let header = rows.first else { return .init() }
        let keys = header.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        var preview = BrowserImportPreview()
        for row in rows.dropFirst() {
            let values = Dictionary(uniqueKeysWithValues: zip(keys, row))
            let rawOrigin = values["url"] ?? values["origin"] ?? values["website"] ?? ""
            let username = values["username"] ?? values["user"] ?? values["login"] ?? ""
            let password = values["password"] ?? ""
            guard let origin = normalizedWebOrigin(rawOrigin), !password.isEmpty else {
                preview.rejectedRows += 1
                continue
            }
            preview.passwords.append(.init(origin: origin, username: username, password: password))
        }
        return preview
    }

    private static func previewContacts(csv: String) -> BrowserImportPreview {
        let rows = CSV.rows(csv)
        guard let header = rows.first else { return .init() }
        let keys = header.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        var preview = BrowserImportPreview()
        for row in rows.dropFirst() {
            let value = Dictionary(uniqueKeysWithValues: zip(keys, row))
            var contact = BrowserContactRecord()
            contact.fullName = value["name"] ?? value["full_name"] ?? ""
            contact.email = value["email"] ?? ""
            contact.phone = value["phone"] ?? ""
            contact.street = value["address"] ?? value["street"] ?? ""
            contact.city = value["city"] ?? ""
            contact.region = value["state"] ?? value["region"] ?? ""
            contact.postalCode = value["zip"] ?? value["postal_code"] ?? ""
            contact.country = value["country"] ?? ""
            guard !contact.fullName.isEmpty || !contact.email.isEmpty || !contact.phone.isEmpty else {
                preview.rejectedRows += 1
                continue
            }
            preview.contacts.append(contact)
        }
        return preview
    }

    private static func previewVCard(_ text: String) -> BrowserImportPreview {
        var preview = BrowserImportPreview()
        for block in text.components(separatedBy: "BEGIN:VCARD").dropFirst() {
            var contact = BrowserContactRecord()
            for line in block.components(separatedBy: .newlines) {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let key = pair[0].uppercased()
                if key.hasPrefix("FN") { contact.fullName = pair[1] }
                if key.hasPrefix("ORG") { contact.organization = pair[1] }
                if key.hasPrefix("EMAIL") { contact.email = pair[1] }
                if key.hasPrefix("TEL") { contact.phone = pair[1] }
                if key.hasPrefix("ADR") {
                    let parts = pair[1].components(separatedBy: ";")
                    if parts.indices.contains(2) { contact.street = parts[2] }
                    if parts.indices.contains(3) { contact.city = parts[3] }
                    if parts.indices.contains(4) { contact.region = parts[4] }
                    if parts.indices.contains(5) { contact.postalCode = parts[5] }
                    if parts.indices.contains(6) { contact.country = parts[6] }
                }
            }
            if !contact.fullName.isEmpty || !contact.email.isEmpty || !contact.phone.isEmpty {
                preview.contacts.append(contact)
            } else {
                preview.rejectedRows += 1
            }
        }
        return preview
    }

    private static func previewHistoryCSV(_ csv: String) -> BrowserImportPreview {
        let rows = CSV.rows(csv)
        guard let header = rows.first else { return .init() }
        let keys = header.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        var preview = BrowserImportPreview()
        for row in rows.dropFirst() {
            let value = Dictionary(uniqueKeysWithValues: zip(keys, row))
            let url = value["url"] ?? ""
            guard isWebURL(url) else { preview.rejectedRows += 1; continue }
            let title = value["title"] ?? ""
            let date = ISO8601DateFormatter().date(from: value["visited_at"] ?? value["date"] ?? "") ?? Date()
            preview.history.append((url, title, date))
        }
        return preview
    }

    private static func previewHistoryJSON(_ data: Data) throws -> BrowserImportPreview {
        let root = try JSONSerialization.jsonObject(with: data)
        let records = (root as? [[String: Any]])
            ?? ((root as? [String: Any])?["history"] as? [[String: Any]])
            ?? []
        var preview = BrowserImportPreview()
        for record in records {
            let url = record["url"] as? String ?? ""
            guard isWebURL(url) else { preview.rejectedRows += 1; continue }
            let title = record["title"] as? String ?? ""
            let timestamp = record["visited_at"] as? Double ?? record["time_usec"] as? Double
            let date = timestamp.map { value in
                Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000_000 : value)
            } ?? Date()
            preview.history.append((url, title, date))
        }
        return preview
    }

    private static func normalizedWebOrigin(_ raw: String) -> String? {
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func isWebURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else { return false }
        return true
    }
}

private enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = text.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                row.append(field)
                field = ""
            } else if character == "\n", !quoted {
                row.append(field.trimmingCharacters(in: .newlines))
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index = next
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
