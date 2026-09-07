import Combine
import Foundation
import Darwin

enum NotebookNoteLifecycle: String, Codable {
    case active, trashed, purged
}

enum NotebookSortOrder: String, CaseIterable, Codable, Identifiable {
    case modifiedNewest, createdNewest, titleAscending

    var id: String { rawValue }
    var title: String {
        switch self {
        case .modifiedNewest: "Recently updated"
        case .createdNewest: "Recently created"
        case .titleAscending: "Title"
        }
    }
}

struct NotebookNoteMetadata: Codable, Equatable {
    let documentID: NotesDocumentID
    var title: String?
    var isPinned = false
    var createdAt: Date
    var deletedAt: Date?
    var lifecycle: NotebookNoteLifecycle = .active
    var purgePending = false
    /// A new lifetime of a contextual note must invalidate old editor callbacks.
    var generation = UUID()

    init(documentID: NotesDocumentID, title: String? = nil, isPinned: Bool = false,
         createdAt: Date, deletedAt: Date? = nil, lifecycle: NotebookNoteLifecycle = .active,
         purgePending: Bool = false, generation: UUID = UUID()) {
        self.documentID = documentID
        self.title = title
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.deletedAt = deletedAt
        self.lifecycle = lifecycle
        self.purgePending = purgePending
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey {
        case documentID, title, isPinned, createdAt, deletedAt, lifecycle, purgePending, generation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(NotesDocumentID.self, forKey: .documentID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        lifecycle = try values.decode(NotebookNoteLifecycle.self, forKey: .lifecycle)
        purgePending = try values.decodeIfPresent(Bool.self, forKey: .purgePending) ?? false
        generation = try values.decode(UUID.self, forKey: .generation)
    }
}

enum NotebookStorageError: LocalizedError {
    case unavailable, invalidDocument, notEditable, notTrashed, standaloneTool, invalidTitle, tooLong

    var errorDescription: String? {
        switch self {
        case .unavailable: "Notebook information could not be loaded. Retry before changing notes."
        case .invalidDocument: "This note has an invalid document identity."
        case .notEditable: "This note was deleted. Restore it or start fresh to edit it."
        case .notTrashed: "Move this note to Recently Deleted first."
        case .standaloneTool: "Notebook notes are private to the Notebook and are not available through Notes tools."
        case .invalidTitle: "Give the note a title of 200 characters or fewer."
        case .tooLong: "Notes are limited to 100,000 characters."
        }
    }
}

/// User-owned metadata is separate from inferred workspace/chat names. Tombstones
/// survive permanent deletion so stale stores cannot recreate a deleted note.
@MainActor
final class NotebookCatalog: ObservableObject {
    private struct Archive: Codable {
        var version = 1
        var notes: [NotebookNoteMetadata] = []
        var sortOrder: NotebookSortOrder = .modifiedNewest
    }

    private static var catalogs: [String: NotebookCatalog] = [:]

    static func shared(in applicationSupport: URL) -> NotebookCatalog {
        let key = applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path
        if let catalog = catalogs[key] { return catalog }
        let catalog = NotebookCatalog(applicationSupport: applicationSupport)
        catalogs[key] = catalog
        return catalog
    }

    /// Failure injection for a fresh fixture root, before any store is opened.
    static func testingShared(
        in applicationSupport: URL,
        writeData: @escaping (Data, URL) throws -> Void
    ) -> NotebookCatalog {
        let key = applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path
        precondition(catalogs[key] == nil, "Use a fresh temporary Notebook root")
        let catalog = NotebookCatalog(applicationSupport: applicationSupport, writeData: writeData)
        catalogs[key] = catalog
        return catalog
    }

    static func fileURL(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
            .appendingPathComponent("Notebook Catalog.json")
    }

    static func initializationMarkerURL(in applicationSupport: URL) -> URL {
        fileURL(in: applicationSupport).deletingLastPathComponent()
            .appendingPathComponent(".Notebook Catalog Initialized")
    }

    @Published private(set) var revision = UUID()
    @Published private(set) var loadError: String?
    private(set) var sortOrder: NotebookSortOrder = .modifiedNewest
    private var records: [NotesDocumentID: NotebookNoteMetadata] = [:]
    private var hasPersisted = false
    private let url: URL
    private let markerURL: URL
    private let writeData: (Data, URL) throws -> Void

    init(
        applicationSupport: URL,
        writeData: @escaping (Data, URL) throws -> Void = NotebookFileIO.write
    ) {
        url = Self.fileURL(in: applicationSupport)
        markerURL = Self.initializationMarkerURL(in: applicationSupport)
        hasPersisted = FileManager.default.fileExists(atPath: markerURL.path)
        self.writeData = writeData
        try? reload()
    }

    func snapshot() throws -> [NotesDocumentID: NotebookNoteMetadata] {
        guard loadError == nil else { throw NotebookStorageError.unavailable }
        return records
    }

    func metadata(for documentID: NotesDocumentID) throws -> NotebookNoteMetadata? {
        try snapshot()[documentID]
    }

    /// A damaged catalog must never become an empty catalog: that would expose
    /// deleted notes again and let background writes revive them.
    func reload() throws {
        do {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                guard !hasPersisted else { throw NotebookStorageError.unavailable }
                publish(records: [:], sort: .modifiedNewest)
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(Archive.self, from: data)
            guard archive.version == 1,
                  archive.notes.allSatisfy({ $0.documentID.isValid }),
                  Set(archive.notes.map(\.documentID)).count == archive.notes.count
            else { throw NotebookStorageError.unavailable }
            hasPersisted = true
            publish(records: Dictionary(uniqueKeysWithValues: archive.notes.map { ($0.documentID, $0) }),
                    sort: archive.sortOrder)
        } catch {
            let message = NotebookStorageError.unavailable.localizedDescription
            if loadError != message {
                loadError = message
                revision = UUID()
            }
            throw error
        }
    }

    func setSortOrder(_ value: NotebookSortOrder) throws {
        try reload()
        try persist(records, sort: value)
    }

    func update(
        _ documentID: NotesDocumentID,
        createdAt: Date = Date(),
        _ change: (inout NotebookNoteMetadata) throws -> Void
    ) throws {
        guard documentID.isValid else { throw NotebookStorageError.invalidDocument }
        try reload()
        var next = records
        var record = next[documentID] ?? NotebookNoteMetadata(documentID: documentID, createdAt: createdAt)
        try change(&record)
        next[documentID] = record
        try persist(next, sort: sortOrder)
    }

    private func persist(_ next: [NotesDocumentID: NotebookNoteMetadata], sort: NotebookSortOrder) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let archive = Archive(notes: next.values.sorted { $0.documentID.identity < $1.documentID.identity },
                              sortOrder: sort)
        let data = try encoder.encode(archive)
        // Establish an empty, valid catalog before its durable format marker.
        // A crash at any boundary leaves either legacy state or a valid catalog;
        // once marked, a missing catalog must fail closed even after relaunch.
        if !FileManager.default.fileExists(atPath: markerURL.path) {
            if !hasPersisted {
                try writeData(encoder.encode(Archive()), url)
                hasPersisted = true
            }
            try NotebookFileIO.write(Data("1\n".utf8), to: markerURL)
        }
        try writeData(data, url)
        // Normalize date precision once, so reloading our own JSON does not
        // emit a spurious metadata change or restart list refreshes.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let committed = try decoder.decode(Archive.self, from: data)
        hasPersisted = true
        publish(records: Dictionary(uniqueKeysWithValues: committed.notes.map { ($0.documentID, $0) }), sort: sort)
    }

    private func publish(records next: [NotesDocumentID: NotebookNoteMetadata], sort: NotebookSortOrder) {
        let changed = records != next || sortOrder != sort || loadError != nil
        records = next
        sortOrder = sort
        loadError = nil
        if changed { revision = UUID() }
    }
}

/// Write a complete sibling with restrictive permissions before making it
/// visible. The catalog never reports success for a failed atomic replacement.
enum NotebookFileIO {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".notebook-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.rename(temporary.path, url.path) == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func removeFileIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true || values.isSymbolicLink == true else {
            throw NotebookStorageError.invalidDocument
        }
        try FileManager.default.removeItem(at: url)
    }
}
