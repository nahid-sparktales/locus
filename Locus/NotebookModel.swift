// Feature-owned Notebook state. Content discovery and full-document search run
// away from the main actor; user metadata and selected editors remain native.

import Combine
import Foundation
import SwiftUI

struct NotebookEntry: Identifiable, Hashable {
    struct Origin: Hashable {
        var title: String
        var workspaceName: String
        var workspacePath: String
    }

    let documentID: NotesDocumentID
    let scope: NotesScope
    let origin: Origin?
    let preview: String
    let modifiedAt: Date?
    let characterCount: Int
    var customTitle: String? = nil
    var isPinned = false
    var createdAt: Date? = nil
    var deletedAt: Date? = nil
    var isTrashed = false
    var isPurgePending = false

    var id: NotesDocumentID { documentID }
    var isStandalone: Bool { documentID.isStandalone }
    var canRestore: Bool { isTrashed && !isPurgePending }
    var isUnlinked: Bool { !isStandalone && origin == nil }
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let origin, !origin.title.isEmpty { return origin.title }
        return isStandalone ? "Untitled Note" : scope.documentTitle
    }
    var subtitle: String {
        if isStandalone { return "Only in your notebook" }
        guard let origin else { return "Unlinked · #\(documentID.digest.prefix(8))" }
        switch scope {
        case .workspace: return origin.workspacePath.isEmpty ? scope.documentTitle : abbreviatedPath
        case .chat: return origin.workspaceName.isEmpty ? scope.documentTitle : origin.workspaceName
        case .global: return "Every chat, every workspace"
        }
    }
    var abbreviatedPath: String {
        guard let origin, !origin.workspacePath.isEmpty else { return "" }
        return NSString(string: origin.workspacePath).abbreviatingWithTildeInPath
    }
}

struct NotebookSection: Identifiable, Hashable {
    let title: String
    let entries: [NotebookEntry]
    var id: String { title }
}

@MainActor
final class NotebookModel: ObservableObject {
    typealias StoreProvider = @MainActor (NotesDocumentID, NotesScope) -> NotesStore
    nonisolated static let previewCharacters = 2_000
    nonisolated private static let maximumScannedDocuments = 10_000

    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var showingTrash = false {
        didSet {
            guard showingTrash != oldValue else { return }
            if let selection, selection.isTrashed != showingTrash { clearSelection() }
            scheduleSearch()
        }
    }
    @Published var sortOrder: NotebookSortOrder = .modifiedNewest {
        didSet {
            guard sortOrder != oldValue, !updatingSort else { return }
            do {
                try catalog.setSortOrder(sortOrder)
                operationSucceeded()
                rebuildEntries()
            } catch {
                pendingOperation = .sort(sortOrder)
                updatingSort = true
                sortOrder = oldValue
                updatingSort = false
                errorMessage = error.localizedDescription
            }
        }
    }
    @Published private(set) var entries: [NotebookEntry] = []
    @Published private(set) var recentlyDeleted: [NotebookEntry] = []
    @Published private(set) var selection: NotebookEntry?
    /// Assigned only when the document changes. A list update must never replace
    /// the editor, its selection, undo history, or pending save.
    @Published private(set) var selectedStore: NotesStore?
    @Published private(set) var namingIsIncomplete = false
    @Published private(set) var isSearching = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var createdSelectionToken: UUID?
    @Published private var searchMatches: Set<NotesDocumentID> = []

    private let applicationSupport: URL
    private let storeProvider: StoreProvider
    private let catalog: NotebookCatalog
    private var lastWorkspaces: [WorkspaceProfile] = []
    private var lastSessions: [SessionSummary] = []
    private var found: [NotesDocumentID: Found] = [:]
    private var names: [NotesDocumentID: NotebookEntry.Origin] = [:]
    private var openedStores: [NotesDocumentID: NotesStore] = [:]
    private var storeObservers: [NotesDocumentID: AnyCancellable] = [:]
    private var catalogObserver: AnyCancellable?
    private var contentObserver: AnyCancellable?
    private var scanTask: Task<Void, Never>?
    private var scanWorker: Task<ScanResult, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchWorker: Task<Set<NotesDocumentID>, Never>?
    private var scanGeneration = UUID()
    private var searchGeneration = UUID()
    private var updatingSort = false
    private var contentRevision = 0
    private var documentRevisions: [NotesDocumentID: Int] = [:]
    private enum Operation {
        case create, rename(NotebookEntry, String), duplicate(NotebookEntry), pin(NotebookEntry)
        case trash(NotebookEntry), restore(NotebookEntry), delete(NotebookEntry), emptyTrash
        case sort(NotebookSortOrder)
    }
    private var pendingOperation: Operation?

    init(
        applicationSupport: URL = NotesStore.applicationSupportDirectory,
        storeProvider: StoreProvider? = nil
    ) {
        self.applicationSupport = applicationSupport
        self.storeProvider = storeProvider ?? {
            NotesStore.shared(documentID: $0, scope: $1, applicationSupport: applicationSupport)
        }
        catalog = NotebookCatalog.shared(in: applicationSupport)
        sortOrder = catalog.sortOrder
        errorMessage = catalog.loadError
        catalogObserver = catalog.$revision.dropFirst().sink { [weak self] _ in
            // Published revisions are emitted before their property changes.
            Task { @MainActor [weak self] in self?.rebuildEntries() }
        }
        contentObserver = NotificationCenter.default.publisher(for: .notesDocumentDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self,
                      let root = notification.userInfo?["applicationSupport"] as? URL,
                      root.standardizedFileURL == self.applicationSupport.standardizedFileURL,
                      let store = notification.object as? NotesStore else { return }
                let needsName = self.found[store.documentID] == nil
                self.capture(store)
                if needsName {
                    self.names = self.resolveNames(for: self.found.keys,
                        workspaces: self.lastWorkspaces, sessions: self.lastSessions)
                }
                self.rebuildEntries()
            }
    }

    deinit {
        scanTask?.cancel()
        scanWorker?.cancel()
        searchTask?.cancel()
        searchWorker?.cancel()
    }

    // MARK: - Discovery

    func refresh(workspaces: [WorkspaceProfile], sessions: [SessionSummary]) {
        lastWorkspaces = workspaces
        lastSessions = sessions
        scanTask?.cancel()
        scanWorker?.cancel()
        let generation = UUID()
        scanGeneration = generation
        do { try catalog.reload() }
        catch { errorMessage = error.localizedDescription; isLoading = false; return }
        isLoading = true
        let startingRevision = contentRevision
        let base = applicationSupport.appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
        let directories = NotesScope.allCases.map { Directory(name: NotesStore.directoryName(for: $0), scopeRaw: $0.rawValue) }
            + [Directory(name: NotesDocumentID.standaloneDirectoryName, scopeRaw: NotesScope.global.rawValue)]
        let worker = Task.detached(priority: .utility) { Self.scan(base: base, directories: directories) }
        scanWorker = worker
        scanTask = Task { [weak self] in
            let result = await worker.value
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            var documents = result.documents
            // A scan is a snapshot. Edits and newly created notes that arrived
            // after it began must remain newer than that snapshot.
            for (id, revision) in self.documentRevisions where revision > startingRevision {
                documents[id] = self.found[id]
            }
            self.found = documents
            self.names = self.resolveNames(for: self.found.keys, workspaces: self.lastWorkspaces, sessions: self.lastSessions)
            if let error = result.error { self.errorMessage = error }
            self.rebuildEntries()
            self.isLoading = false
        }
    }

    func retry() {
        let operation = pendingOperation
        errorMessage = nil
        do { try catalog.reload() }
        catch { errorMessage = error.localizedDescription; return }
        switch operation {
        case .create: createNote()
        case let .rename(entry, title): rename(entry, title: title)
        case let .duplicate(entry): duplicate(entry)
        case let .pin(entry): togglePin(entry)
        case let .trash(entry): trash(entry)
        case let .restore(entry): restore(entry)
        case let .delete(entry): deletePermanently(entry)
        case .emptyTrash: emptyTrash()
        case let .sort(value): sortOrder = value
        case nil: refresh(workspaces: lastWorkspaces, sessions: lastSessions)
        }
    }
    func clearError() { errorMessage = nil; pendingOperation = nil }
    private func operationSucceeded() { clearError() }

    private struct Directory: Sendable {
        let name: String
        let scopeRaw: String
    }
    private struct Found: Sendable {
        let scopeRaw: String
        let preview: String
        let modifiedAt: Date?
        let createdAt: Date?
        let characterCount: Int
    }
    private struct ScanResult {
        var documents: [NotesDocumentID: Found] = [:]
        var error: String?
    }

    nonisolated private static func scan(base: URL, directories: [Directory]) -> ScanResult {
        var result = ScanResult()
        for descriptor in directories {
            if Task.isCancelled { return result }
            let directory = base.appendingPathComponent(descriptor.name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue,
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                result.error = "A notes folder could not be read safely. Check its location and retry."
                continue
            }
            let urls: [URL]
            do { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey]) }
            catch { result.error = "Some notes could not be read. Check file permissions and retry."; continue }
            var digests: Set<String> = []
            for url in urls {
                guard ["txt", "styled"].contains(url.pathExtension) else { continue }
                let digest = url.deletingPathExtension().lastPathComponent.lowercased()
                guard digest.count == 64, digest.allSatisfy(\.isHexDigit),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                digests.insert(digest)
            }
            for digest in digests.sorted() {
                if Task.isCancelled { return result }
                guard result.documents.count < maximumScannedDocuments else {
                    result.error = "The Notebook can load up to 10,000 notes at once. Some notes were not loaded."
                    return result
                }
                let plain = directory.appendingPathComponent("\(digest).txt")
                let styled = directory.appendingPathComponent("\(digest).styled")
                let text = NotesStore.storedText(plain: plain, styled: styled)
                let dates = [plain, styled].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) }
                result.documents[NotesDocumentID(directoryName: descriptor.name, digest: digest)] = Found(
                    scopeRaw: descriptor.scopeRaw, preview: preview(from: text),
                    modifiedAt: dates.compactMap(\.contentModificationDate).max(),
                    createdAt: dates.compactMap(\.creationDate).min(), characterCount: text.count
                )
            }
        }
        return result
    }

    nonisolated static func preview(from text: String) -> String {
        let body = text.prefix(previewCharacters).components(separatedBy: .newlines).lazy
            .map { NotesMarkers.strippingMarker($0).rest.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(body.prefix(140))
    }

    private func rebuildEntries() {
        do {
            let metadata = try catalog.snapshot()
            updatingSort = true
            sortOrder = catalog.sortOrder
            updatingSort = false
            var rows: [NotebookEntry] = []
            for id in Set(found.keys).union(metadata.keys) {
                guard let scope = scope(for: id) else { continue }
                let record = metadata[id]
                let pending = record?.lifecycle == .purged && record?.purgePending == true
                if record?.lifecycle == .purged && !pending { continue }
                let stored = found[id]
                let live = openedStores[id]
                let text = live?.hasUnsavedChanges == true ? live?.text : nil
                rows.append(NotebookEntry(
                    documentID: id, scope: scope, origin: names[id],
                    preview: pending ? "" : text.map(Self.preview) ?? stored?.preview ?? "",
                    modifiedAt: stored?.modifiedAt, characterCount: pending ? 0 : text?.count ?? stored?.characterCount ?? 0,
                    customTitle: record?.title, isPinned: record?.isPinned ?? false,
                    createdAt: record?.createdAt ?? stored?.createdAt,
                    deletedAt: record?.deletedAt, isTrashed: record?.lifecycle == .trashed || pending,
                    isPurgePending: pending
                ))
            }
            entries = sorted(rows.filter { !$0.isTrashed })
            recentlyDeleted = sorted(rows.filter(\.isTrashed))
            namingIsIncomplete = lastSessions.isEmpty && entries.contains { $0.scope == .chat && $0.isUnlinked }
            if let current = selection {
                let replacement = rows.first { $0.documentID == current.documentID }
                if let replacement, replacement.isTrashed == showingTrash {
                    if selection != replacement { selection = replacement }
                } else { clearSelection() }
            }
            scheduleSearch()
        } catch { errorMessage = error.localizedDescription }
    }

    private func scope(for id: NotesDocumentID) -> NotesScope? {
        if id.isStandalone { return .global }
        return NotesScope.allCases.first { NotesStore.directoryName(for: $0) == id.directoryName }
    }

    // MARK: - Naming

    /// Name each digest from the durable index first, then backfill by
    /// recomputing digests from what the app currently knows — recording every
    /// fresh hit, so a name resolved once survives deleting the chat that
    /// produced it.
    ///
    /// Recomputation is lossy by construction: `canonicalWorkspacePath`
    /// resolves symlinks only for a path that still exists, so the digest
    /// written while a workspace was mounted may be unreachable afterwards.
    /// That is why the index exists, and why a digest is never "repaired" by
    /// rewriting its note under a corrected one — that would fork the document.
    private func resolveNames(
        for documentIDs: some Collection<NotesDocumentID>,
        workspaces: [WorkspaceProfile],
        sessions: [SessionSummary]
    ) -> [NotesDocumentID: NotebookEntry.Origin] {
        let known = Set(documentIDs)
        var discovered: [NotesDocumentID: NotesNameRecord] = [:]
        let now = Date()

        func record(
            _ documentID: NotesDocumentID,
            _ scope: NotesScope,
            workspacePath: String,
            sessionID: String,
            title: String
        ) {
            guard known.contains(documentID), discovered[documentID] == nil else { return }
            discovered[documentID] = NotesNameRecord(
                directoryName: documentID.directoryName,
                digest: documentID.digest,
                scopeRaw: scope.rawValue,
                workspacePath: workspacePath,
                sessionID: sessionID,
                title: title,
                updatedAt: now
            )
        }

        record(
            NotesStore.globalDocumentID, .global,
            workspacePath: "", sessionID: "", title: NotesScope.global.documentTitle
        )

        var workspaceNames: [String: String] = [:]
        for path in workspaces.map(\.path) + sessions.flatMap({ [$0.cwd, $0.workspaceRoot] })
            .compactMap({ $0 })
        {
            let canonical = SessionSummary.canonicalWorkspacePath(path)
            guard !canonical.isEmpty, workspaceNames[canonical] == nil else { continue }
            workspaceNames[canonical] = URL(fileURLWithPath: canonical).lastPathComponent
        }

        for (path, name) in workspaceNames {
            record(
                NotesStore.documentID(workspacePath: path, sessionID: "", scope: .workspace),
                .workspace, workspacePath: path, sessionID: "", title: name
            )
            // A note written before its chat had an id keeps the sentinel key,
            // so name it for its workspace rather than orphaning it.
            record(
                NotesStore.documentID(workspacePath: path, sessionID: "", scope: .chat),
                .chat, workspacePath: path, sessionID: "", title: "Unsaved chat"
            )
        }

        // A chat note is keyed by whichever workspace was open when it was
        // written, which is usually but not always the session's own, so each
        // session is tried against every known workspace. The session's own
        // workspace is registered first so a cross-product hit cannot displace
        // it.
        for session in sessions {
            let own = session.cwd.map(SessionSummary.canonicalWorkspacePath)
            for path in [own].compactMap({ $0 }) + workspaceNames.keys.filter({ $0 != own }) {
                record(
                    NotesStore.documentID(
                        workspacePath: path, sessionID: session.id, scope: .chat
                    ),
                    .chat,
                    workspacePath: path,
                    sessionID: session.id,
                    title: session.displayTitle
                )
            }
        }

        let merged = NotesNameIndex.merge(Array(discovered.values), in: applicationSupport)
        return merged.compactMapValues { record in
            let path = record.workspacePath
            return NotebookEntry.Origin(
                title: record.title,
                workspaceName: path.isEmpty
                    ? "" : URL(fileURLWithPath: path).lastPathComponent,
                workspacePath: path
            )
        }
        .filter { !$0.value.title.isEmpty || !$0.value.workspacePath.isEmpty }
    }

    // MARK: - Presentation and search

    private var visibleEntries: [NotebookEntry] { showingTrash ? recentlyDeleted : entries }

    var sections: [NotebookSection] {
        let matches = filteredEntries
        if showingTrash { return matches.isEmpty ? [] : [NotebookSection(title: "Recently Deleted", entries: matches)] }
        let groups: [(String, (NotebookEntry) -> Bool)] = [
            ("Pinned", { $0.isPinned }),
            ("My Notes", { !$0.isPinned && $0.isStandalone }),
            ("Shared", { !$0.isPinned && !$0.isStandalone && $0.scope == .global && !$0.isUnlinked }),
            ("Workspaces", { !$0.isPinned && $0.scope == .workspace && !$0.isUnlinked }),
            ("Chats", { !$0.isPinned && $0.scope == .chat && !$0.isUnlinked }),
            ("Unlinked", { !$0.isPinned && $0.isUnlinked }),
        ]
        return groups.compactMap { title, belongs in
            let values = matches.filter(belongs)
            return values.isEmpty ? nil : NotebookSection(title: title, entries: values)
        }
    }

    var filteredEntries: [NotebookEntry] {
        normalizedQuery.isEmpty ? visibleEntries : visibleEntries.filter { searchMatches.contains($0.id) }
    }
    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sorted(_ values: [NotebookEntry]) -> [NotebookEntry] {
        values.sorted { left, right in
            switch sortOrder {
            case .modifiedNewest:
                let a = left.isTrashed ? left.deletedAt : left.modifiedAt
                let b = right.isTrashed ? right.deletedAt : right.modifiedAt
                if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
            case .createdNewest:
                if left.createdAt != right.createdAt { return (left.createdAt ?? .distantPast) > (right.createdAt ?? .distantPast) }
            case .titleAscending:
                let order = left.title.localizedStandardCompare(right.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return left.documentID.identity < right.documentID.identity
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchWorker?.cancel()
        let generation = UUID()
        searchGeneration = generation
        let needle = normalizedQuery
        guard !needle.isEmpty else {
            searchMatches = []
            isSearching = false
            return
        }
        let candidates = visibleEntries
        // Names and opening words can update immediately; full body matching is
        // debounced and never reads files from a SwiftUI computed property.
        searchMatches = Set(candidates.filter {
            [$0.title, $0.subtitle, $0.preview].contains { $0.localizedStandardContains(needle) }
        }.map(\.id))
        isSearching = true
        let base = applicationSupport.appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
        let liveText = openedStores.filter { $0.value.hasUnsavedChanges }.mapValues(\.text)
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            let worker = Task.detached(priority: .utility) { () -> Set<NotesDocumentID> in
                var matches: Set<NotesDocumentID> = []
                for entry in candidates {
                    if Task.isCancelled { return matches }
                    if [entry.title, entry.subtitle].contains(where: { $0.localizedStandardContains(needle) }) {
                        matches.insert(entry.id)
                        continue
                    }
                    guard !entry.isPurgePending else { continue }
                    let directory = base.appendingPathComponent(entry.documentID.directoryName, isDirectory: true)
                    let body = liveText[entry.id] ?? NotesStore.storedText(
                        plain: directory.appendingPathComponent("\(entry.documentID.digest).txt"),
                        styled: directory.appendingPathComponent("\(entry.documentID.digest).styled")
                    )
                    if body.localizedStandardContains(needle) { matches.insert(entry.id) }
                }
                return matches
            }
            self.searchWorker = worker
            let matches = await worker.value
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            self.searchMatches = matches
            self.isSearching = false
        }
    }

    // MARK: - Selection and lifecycle

    private func store(for entry: NotebookEntry) -> NotesStore {
        if let value = openedStores[entry.id] { return value }
        let value = storeProvider(entry.documentID, entry.scope)
        register(value)
        return value
    }

    private func register(_ store: NotesStore) {
        openedStores[store.documentID] = store
        guard storeObservers[store.documentID] == nil else { return }
        storeObservers[store.documentID] = store.$text.dropFirst()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self, weak store] text in
                guard let self, let store else { return }
                self.capture(store, text: text)
                self.rebuildEntries()
            }
    }

    private func capture(_ store: NotesStore, text: String? = nil) {
        contentRevision += 1
        documentRevisions[store.documentID] = contentRevision
        let body = text ?? store.text
        found[store.documentID] = Found(scopeRaw: store.scope.rawValue, preview: Self.preview(from: body),
            modifiedAt: Date(), createdAt: found[store.documentID]?.createdAt ?? Date(), characterCount: body.count)
    }

    func select(_ entry: NotebookEntry) {
        guard let current = visibleEntries.first(where: { $0.id == entry.id }) else { return }
        if selection?.id == entry.id, selectedStore != nil {
            selectedStore?.reloadFromDiskIfClean()
            selection = current
            return
        }
        let value = store(for: current)
        value.reloadFromDiskIfClean()
        selection = current
        selectedStore = value
    }

    private func clearSelection() {
        selection = nil
        selectedStore = nil
    }

    @discardableResult
    func createNote() -> NotebookEntry? {
        pendingOperation = .create
        do {
            let value = try NotesStore.create(title: "Untitled Note", applicationSupport: applicationSupport)
            register(value)
            capture(value)
            showingTrash = false
            query = ""
            rebuildEntries()
            guard let entry = entries.first(where: { $0.id == value.documentID }) else { return nil }
            select(entry)
            createdSelectionToken = UUID()
            operationSucceeded()
            return entry
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func rename(_ entry: NotebookEntry, title: String) -> Bool {
        pendingOperation = .rename(entry, title)
        do {
            try store(for: entry).rename(to: title)
            operationSucceeded()
            rebuildEntries()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func duplicate(_ entry: NotebookEntry) -> NotebookEntry? {
        pendingOperation = .duplicate(entry)
        do {
            let source = store(for: entry)
            source.reloadFromDiskIfClean()
            guard source.isEditable else { throw NotebookStorageError.notEditable }
            let currentTitle = try catalog.snapshot()[entry.id]?.title ?? entry.title
            let title = String(currentTitle.prefix(190)) + " copy"
            let value = try NotesStore.create(title: title, attributed: source.attributedText, applicationSupport: applicationSupport)
            register(value)
            capture(value)
            showingTrash = false
            query = ""
            rebuildEntries()
            guard let created = entries.first(where: { $0.id == value.documentID }) else { return nil }
            select(created)
            createdSelectionToken = UUID()
            operationSucceeded()
            return created
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func togglePin(_ entry: NotebookEntry) {
        pendingOperation = .pin(entry)
        do {
            try store(for: entry).setPinned(!entry.isPinned)
            operationSucceeded()
            rebuildEntries()
        } catch { errorMessage = error.localizedDescription }
    }

    func trash(_ entry: NotebookEntry) {
        pendingOperation = .trash(entry)
        let wasSelected = selection?.id == entry.id
        do {
            try store(for: entry).moveToTrash()
            operationSucceeded()
            rebuildEntries()
            if wasSelected, let next = filteredEntries.first { select(next) }
        } catch { errorMessage = error.localizedDescription }
    }

    func restore(_ entry: NotebookEntry) {
        pendingOperation = .restore(entry)
        guard entry.canRestore else { errorMessage = NotebookStorageError.notTrashed.localizedDescription; return }
        let wasSelected = selection?.id == entry.id
        do {
            try store(for: entry).restore()
            operationSucceeded()
            rebuildEntries()
            if wasSelected, let next = filteredEntries.first { select(next) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deletePermanently(_ entry: NotebookEntry) {
        pendingOperation = .delete(entry)
        let wasSelected = selection?.id == entry.id
        do {
            try store(for: entry).deletePermanently()
            contentRevision += 1
            documentRevisions[entry.id] = contentRevision
            found.removeValue(forKey: entry.id)
            operationSucceeded()
            rebuildEntries()
            if wasSelected, let next = filteredEntries.first { select(next) }
        } catch { errorMessage = error.localizedDescription; rebuildEntries() }
    }

    func emptyTrash() {
        pendingOperation = .emptyTrash
        do {
            // Retain purged tombstones in metadata; retry cleanup if an earlier
            // permanent deletion could not remove both content files.
            let metadata = try catalog.snapshot()
            for record in metadata.values where record.lifecycle == .trashed || record.purgePending {
                guard let scope = scope(for: record.documentID) else { continue }
                let value = openedStores[record.documentID] ?? storeProvider(record.documentID, scope)
                try value.deletePermanently()
                contentRevision += 1
                documentRevisions[record.documentID] = contentRevision
                found.removeValue(forKey: record.documentID)
            }
            operationSucceeded()
            rebuildEntries()
        } catch { errorMessage = error.localizedDescription; rebuildEntries() }
    }
}
