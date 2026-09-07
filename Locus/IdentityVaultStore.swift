import Combine
import CryptoKit
import Darwin
import Foundation
import Security

protocol IdentityVaultKeyProviding: Sendable {
    func keyData() async throws -> Data
}

/// A separate, edition-specific file-based Keychain item. No additional user-presence ceremony.
struct KeychainIdentityVaultKeyProvider: IdentityVaultKeyProviding {
    static let service = AppEdition.current.keychainService("identity-vault.v1")
    static let account = "identity-vault-master-key-v1"
    static func readQuery() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
    }
    static func addQuery(key: Data) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecValueData: key,
         kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }
    func keyData() async throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery() as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw IdentityVaultError.keychain(status) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw IdentityVaultError.keychain(randomStatus) }
        let key = Data(bytes)
        let added = SecItemAdd(Self.addQuery(key: key) as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let reread = SecItemCopyMatching(Self.readQuery() as CFDictionary, &result)
            if reread == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
            throw IdentityVaultError.keychain(reread)
        }
        guard added == errSecSuccess else { throw IdentityVaultError.keychain(added) }
        return key
    }
}

struct InMemoryIdentityVaultKeyProvider: IdentityVaultKeyProviding {
    let data: Data
    init(data: Data = Data(repeating: 41, count: 32)) { self.data = data }
    func keyData() async throws -> Data { data }
}

private struct IdentityVaultPayload: Codable {
    var version = 1
    var profiles: [IdentityVaultProfile] = []
    var documents: [IdentityVaultDocument] = []
    var drafts: [IdentityVaultDraft] = []
    var disclosures: [IdentityVaultDisclosure] = []
    var snapshotIDs: Set<UUID> = []
}

@MainActor
final class IdentityVaultStore: ObservableObject {
    static let maximumDocumentBytes = 100 * 1_024 * 1_024
    static let maximumTextBytes = 5 * 1_024 * 1_024
    @Published private(set) var profiles: [IdentityVaultProfile] = []
    @Published private(set) var documents: [IdentityVaultDocument] = []
    @Published private(set) var drafts: [IdentityVaultDraft] = []
    @Published private(set) var disclosures: [IdentityVaultDisclosure] = []
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let directoryURL: URL?
    private let keyProvider: any IdentityVaultKeyProviding
    private let writer: (Data, URL) throws -> Void
    private var key: SymmetricKey?
    private var payload = IdentityVaultPayload()
    private var memoryMetadata: Data?
    private var memoryBlobs: [UUID: Data] = [:]
    private var loadingTask: Task<Bool, Never>?
    private var generation = 0

    static var defaultDirectoryURL: URL {
        AppEdition.current.supportDirectory.appendingPathComponent("IdentityVault/v1", isDirectory: true)
    }

    init(
        directoryURL: URL? = nil,
        keyProvider: any IdentityVaultKeyProviding = KeychainIdentityVaultKeyProvider(),
        writer: @escaping (Data, URL) throws -> Void = IdentityVaultStore.writeEncrypted
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.keyProvider = keyProvider
        self.writer = writer
    }

    /// No path lookup, persistent key or disk fallback is possible in a fixture vault.
    init(inMemory: Void) {
        directoryURL = nil
        keyProvider = InMemoryIdentityVaultKeyProvider()
        writer = Self.writeEncrypted
    }

    @discardableResult
    func load() async -> Bool {
        if isReady { return true }
        if let loadingTask { return await loadingTask.value }
        let epoch = generation
        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                let keyData = try await self.keyProvider.keyData()
                guard !Task.isCancelled, self.generation == epoch else { return false }
                guard keyData.count == 32 else { throw IdentityVaultError.corrupt }
                let key = SymmetricKey(data: keyData)
                let encrypted: Data?
                if let directoryURL = self.directoryURL {
                    let url = directoryURL.appendingPathComponent("vault.bin")
                    encrypted = FileManager.default.fileExists(atPath: url.path) ? try Self.readBounded(url, limit: 256 * 1_024 * 1_024) : nil
                } else {
                    encrypted = self.memoryMetadata
                }
                var next = IdentityVaultPayload()
                if let encrypted {
                    do {
                        let clear = try Self.open(encrypted, key: key, context: "metadata")
                        next = try JSONDecoder().decode(IdentityVaultPayload.self, from: clear)
                    } catch { throw IdentityVaultError.corrupt }
                    guard next.version == 1 else { throw IdentityVaultError.unsupportedVersion }
                    guard Set(next.profiles.map(\.id)).count == next.profiles.count,
                          Set(next.documents.map(\.id)).count == next.documents.count,
                          Set(next.drafts.map(\.id)).count == next.drafts.count,
                          Set(next.disclosures.map(\.id)).count == next.disclosures.count
                    else { throw IdentityVaultError.corrupt }
                }
                self.key = key
                self.publish(next)
                self.isReady = true
                self.lastError = nil
                return true
            } catch {
                guard self.generation == epoch else { return false }
                self.key = nil
                self.isReady = false
                self.lastError = error.localizedDescription
                return false
            }
        }
        loadingTask = task
        let result = await task.value
        if generation == epoch {
            loadingTask = nil
            isLoading = false
        }
        return result
    }

    /// Called on Mac lock/sleep and app lifecycle transitions. Existing grants belong to the coordinator.
    func lock() {
        generation += 1
        loadingTask?.cancel()
        loadingTask = nil
        key = nil
        payload = IdentityVaultPayload()
        profiles = []; documents = []; drafts = []; disclosures = []
        isReady = false
        isLoading = false
        lastError = nil
    }

    @discardableResult
    func saveProfile(_ profile: IdentityVaultProfile) throws -> IdentityVaultProfile {
        try requireReady()
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.name.count <= 200, profile.fields.count <= 500,
              Set(profile.fields.map(\.id)).count == profile.fields.count,
              Set(profile.fields.map(\.key)).count == profile.fields.count,
              profile.fields.allSatisfy({
                  !$0.key.isEmpty && $0.key.utf8.count <= 128
                    && $0.key.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0) }
                    && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 200
                    && $0.value.utf8.count <= Self.maximumTextBytes
              }) else { throw IdentityVaultError.invalidRecord }
        var next = payload
        if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) {
            guard profile.revision == next.profiles[index].revision else { throw IdentityVaultError.staleRevision }
            profile.revision += 1
            profile.createdAt = next.profiles[index].createdAt
            profile.updatedAt = Date()
            next.profiles[index] = profile
        } else {
            profile.revision = 1
            next.profiles.append(profile)
        }
        try commit(next)
        return profile
    }

    func deleteProfile(_ id: UUID) throws {
        try requireReady()
        var next = payload
        next.profiles.removeAll { $0.id == id }
        // Document versions retain their source profile ID for history; deleting a profile never deletes originals.
        try commit(next)
    }

    @discardableResult
    func addDocument(
        name: String, kind: IdentityVaultDocumentKind, mimeType: String, data: Data,
        extractedText: String = "", profileID: UUID? = nil, replacingDocumentID: UUID? = nil
    ) throws -> IdentityVaultDocument {
        try requireReady()
        guard !data.isEmpty, data.count <= Self.maximumDocumentBytes,
              extractedText.utf8.count <= Self.maximumTextBytes else { throw IdentityVaultError.tooLarge }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 255, !mimeType.isEmpty else { throw IdentityVaultError.invalidRecord }
        if let profileID, !payload.profiles.contains(where: { $0.id == profileID }) { throw IdentityVaultError.invalidRecord }
        let previous = replacingDocumentID.flatMap { id in payload.documents.first { $0.id == id } }
        if replacingDocumentID != nil, previous == nil { throw IdentityVaultError.missingDocument }
        let groupID = previous?.groupID ?? UUID()
        let version = (payload.documents.filter { $0.groupID == groupID }.map(\.version).max() ?? 0) + 1
        let blobID = UUID()
        let record = IdentityVaultDocument(
            id: UUID(), groupID: groupID, version: version, blobID: blobID, profileID: profileID,
            name: name, kind: kind, mimeType: mimeType, byteCount: data.count,
            contentHash: Self.digest(data), extractedText: extractedText, createdAt: Date()
        )
        try writeBlob(data, id: blobID)
        var next = payload
        next.documents.append(record)
        do { try commit(next) } catch { removeBlob(blobID); throw error }
        return record
    }

    func documentData(id: UUID) throws -> Data {
        try requireReady()
        guard let record = payload.documents.first(where: { $0.id == id }) else { throw IdentityVaultError.missingDocument }
        let data = try readBlob(record.blobID)
        guard data.count == record.byteCount, Self.digest(data) == record.contentHash else { throw IdentityVaultError.corrupt }
        return data
    }

    func deleteDocument(_ id: UUID) throws {
        try requireReady()
        guard let record = payload.documents.first(where: { $0.id == id }) else { return }
        var next = payload
        next.documents.removeAll { $0.id == id }
        try commit(next)
        removeBlob(record.blobID)
    }

    @discardableResult
    func saveDraft(_ draft: IdentityVaultDraft) throws -> IdentityVaultDraft {
        try requireReady()
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.title.count <= 255, draft.sections.count <= 500,
              draft.sections.reduce(0, { $0 + $1.heading.utf8.count + $1.text.utf8.count }) <= Self.maximumTextBytes
        else { throw IdentityVaultError.invalidRecord }
        var draft = draft
        var next = payload
        if let index = next.drafts.firstIndex(where: { $0.id == draft.id }) {
            guard draft.revision == next.drafts[index].revision else { throw IdentityVaultError.staleRevision }
            draft.revision += 1
            draft.updatedAt = Date()
            draft.createdAt = next.drafts[index].createdAt
            next.drafts[index] = draft
        } else { next.drafts.append(draft) }
        try commit(next)
        return draft
    }

    func deleteDraft(_ id: UUID) throws {
        try requireReady()
        var next = payload
        next.drafts.removeAll { $0.id == id }
        try commit(next)
    }

    @discardableResult
    func saveSnapshot(text: String) throws -> UUID {
        guard text.utf8.count <= Self.maximumTextBytes else { throw IdentityVaultError.tooLarge }
        return try saveSnapshot(data: Data(text.utf8))
    }

    @discardableResult
    func saveSnapshot(data: Data) throws -> UUID {
        try requireReady()
        guard data.count <= Self.maximumDocumentBytes else { throw IdentityVaultError.tooLarge }
        let id = UUID()
        try writeBlob(data, id: id)
        var next = payload
        next.snapshotIDs.insert(id)
        do { try commit(next) } catch { removeBlob(id); throw error }
        return id
    }

    func snapshotText(id: UUID) throws -> String {
        let bytes = try disclosureSnapshot(id: id)
        guard let value = String(data: bytes, encoding: .utf8) else { throw IdentityVaultError.corrupt }
        return value
    }

    func disclosureSnapshot(id: UUID) throws -> Data {
        try requireReady()
        guard payload.snapshotIDs.contains(id) else { throw IdentityVaultError.missingDocument }
        return try readBlob(id)
    }

    func deleteSnapshot(id: UUID) throws {
        try requireReady()
        guard payload.snapshotIDs.contains(id) else { return }
        var next = payload
        next.snapshotIDs.remove(id)
        for index in next.disclosures.indices where next.disclosures[index].snapshotID == id {
            next.disclosures[index].snapshotID = nil
            next.disclosures[index].outcome = "Revoked for future use"
        }
        try commit(next)
        removeBlob(id)
    }

    @discardableResult
    func recordDisclosure(_ disclosure: IdentityVaultDisclosure, snapshot: Data? = nil) throws -> IdentityVaultDisclosure {
        try requireReady()
        guard !payload.disclosures.contains(where: { $0.id == disclosure.id }),
              !disclosure.taskID.isEmpty, !disclosure.recipientID.isEmpty else { throw IdentityVaultError.invalidRecord }
        var disclosure = disclosure
        var next = payload
        var createdBlob: UUID?
        if let snapshot {
            guard snapshot.count <= Self.maximumDocumentBytes else { throw IdentityVaultError.tooLarge }
            let id = UUID()
            try writeBlob(snapshot, id: id)
            createdBlob = id
            disclosure.snapshotID = id
            next.snapshotIDs.insert(id)
        } else if let id = disclosure.snapshotID, !next.snapshotIDs.contains(id) {
            throw IdentityVaultError.missingDocument
        }
        next.disclosures.append(disclosure)
        do { try commit(next) } catch { if let createdBlob { removeBlob(createdBlob) }; throw error }
        return disclosure
    }

    /// Revokes future snapshot reuse. A recipient's already received copy cannot be recalled.
    func revokeDisclosure(id: UUID) throws {
        try requireReady()
        guard let disclosure = payload.disclosures.first(where: { $0.id == id }), let snapshotID = disclosure.snapshotID else { return }
        try deleteSnapshot(id: snapshotID)
    }

    private func requireReady() throws {
        guard isReady, key != nil else { throw IdentityVaultError.unavailable }
    }

    private func commit(_ next: IdentityVaultPayload) throws {
        try requireReady()
        let clear = try JSONEncoder().encode(next)
        guard clear.count <= 256 * 1_024 * 1_024 else { throw IdentityVaultError.tooLarge }
        guard let key else { throw IdentityVaultError.unavailable }
        let sealed = try Self.seal(clear, key: key, context: "metadata")
        if let directoryURL { try writer(sealed, directoryURL.appendingPathComponent("vault.bin")) }
        else { memoryMetadata = sealed }
        // Disk commit is the point at which observable state may change.
        publish(next)
        lastError = nil
    }

    private func publish(_ next: IdentityVaultPayload) {
        payload = next
        profiles = next.profiles
        documents = next.documents
        drafts = next.drafts
        disclosures = next.disclosures
    }

    private func writeBlob(_ data: Data, id: UUID) throws {
        try requireReady()
        guard let key else { throw IdentityVaultError.unavailable }
        let sealed = try Self.seal(data, key: key, context: "blob/\(id.uuidString)")
        if let url = blobURL(id) { try writer(sealed, url) }
        else { memoryBlobs[id] = sealed }
    }

    private func readBlob(_ id: UUID) throws -> Data {
        guard let key else { throw IdentityVaultError.unavailable }
        do {
            let encrypted: Data
            if let url = blobURL(id) { encrypted = try Self.readBounded(url, limit: Self.maximumDocumentBytes + 1_024) }
            else if let data = memoryBlobs[id] { encrypted = data }
            else { throw IdentityVaultError.missingDocument }
            return try Self.open(encrypted, key: key, context: "blob/\(id.uuidString)")
        } catch { throw IdentityVaultError.corrupt }
    }

    private func blobURL(_ id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(id.uuidString + ".bin")
    }
    private func removeBlob(_ id: UUID) {
        if let url = blobURL(id) { try? FileManager.default.removeItem(at: url) }
        memoryBlobs.removeValue(forKey: id)
    }
    private static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        guard let result = try AES.GCM.seal(data, using: key, authenticating: Data("locus.identity.v1/\(context)".utf8)).combined
        else { throw IdentityVaultError.corrupt }
        return result
    }
    private static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data("locus.identity.v1/\(context)".utf8))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? limit + 1) <= limit else { throw IdentityVaultError.corrupt }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= limit else { throw IdentityVaultError.corrupt }
        return bytes
    }
    nonisolated static func writeEncrypted(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let pending = directory.appendingPathComponent(".\(UUID().uuidString).encrypted-pending")
        defer { try? FileManager.default.removeItem(at: pending) }
        try data.write(to: pending, options: [.withoutOverwriting, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        // Rename is the only commit point. A failed permission change cannot report
        // failure after replacing the saved metadata and leave published state behind.
        let status = pending.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
