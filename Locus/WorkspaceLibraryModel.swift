import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum WorkspaceLibraryTab: String, CaseIterable, Identifiable { case documents = "Documents", outputs = "Outputs"; var id: String { rawValue } }

@MainActor
final class WorkspaceLibraryModel: ObservableObject {
    @Published var isPresented = false
    @Published var tab: WorkspaceLibraryTab = .documents
    @Published var query = ""
    @Published var previewRequest: DocumentPreviewRequest?
    @Published private(set) var workspace = ""
    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var jobs: [String: DocumentExtractionJob] = [:]
    @Published private(set) var total = 0
    @Published private(set) var searchResults: [DocumentSearchHit] = []
    @Published private(set) var documentsEnabled = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var pending: Set<String> = []
    private var backend: BackendService?
    private var generation = UUID()
    private var catalogRequest = UUID()
    private var loadedCatalogQuery: String?
    private var pollingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private struct Catalog: Decodable { let documents: [LibraryDocument]; let total: Int }
    private struct Settings: Decodable {
        let enabled: Bool?
        let documentsEnabled: Bool?
        enum CodingKeys: String, CodingKey { case enabled; case documentsEnabled = "documents_enabled" }
    }
    private struct JobResponse: Decodable { let job: DocumentExtractionJob }
    private struct JobsResponse: Decodable { let jobs: [DocumentExtractionJob] }
    private struct DocumentResponse: Decodable { let document: LibraryDocument }
    private struct SearchResponse: Decodable { let results: [DocumentSearchHit] }

    func configure(backend: BackendService) { self.backend = backend }
    func installUITestDocuments(_ documents: [LibraryDocument], workspace: String) {
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else { return }
        pollingTask?.cancel()
        backend = nil
        self.workspace = OutputsLibraryStore.canonical(workspace)
        self.documents = documents
        total = documents.count
        documentsEnabled = true
        isLoading = false
    }
    func activate(workspace: String) {
        let root = OutputsLibraryStore.canonical(workspace)
        if root != self.workspace {
            generation = UUID()
            previewGeneration = UUID()
            self.workspace = root
            documents = []
            loadedCatalogQuery = nil
            jobs = [:]
            searchResults = []
            query = ""
            previewRequest = nil
            documentsEnabled = false
            pending = []
        }
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                if !isPresented { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func refresh(loadMore: Bool = false) async {
        guard let backend, !workspace.isEmpty else { return }
        let root = workspace, token = generation
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendPage = loadMore && loadedCatalogQuery == search
        let previousCount = loadedCatalogQuery == search ? documents.count : 0
        let request = UUID()
        catalogRequest = request
        isLoading = true
        do {
            async let settings = backend.get("/api/knowledge/status", query: [.init(name: "workspace", value: root)], as: Settings.self)
            let response = try await backend.get("/api/documents", query: [
                .init(name: "workspace", value: root), .init(name: "limit", value: "100"),
                .init(name: "query", value: search),
                .init(name: "offset", value: appendPage ? String(previousCount) : "0")
            ], as: Catalog.self)
            var rows = response.documents
            if !appendPage {
                let visibleCount = min(max(previousCount, 100), response.total)
                while rows.count < visibleCount {
                    let page = try await backend.get("/api/documents", query: [.init(name: "workspace", value: root),
                        .init(name: "query", value: search), .init(name: "limit", value: "100"),
                        .init(name: "offset", value: String(rows.count))], as: Catalog.self)
                    guard !page.documents.isEmpty else { break }
                    rows.append(contentsOf: page.documents)
                }
            }
            let configuration = try await settings
            var activeJobs: [DocumentExtractionJob] = []
            if rows.contains(where: { $0.status == "running" || $0.status == "queued" }) {
                activeJobs = try await backend.get("/api/document-jobs", query: [.init(name: "workspace", value: root), .init(name: "limit", value: "100")], as: JobsResponse.self).jobs
            }
            guard !Task.isCancelled, token == generation, request == catalogRequest,
                  search == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if appendPage { documents.append(contentsOf: rows.filter { row in !documents.contains { $0.id == row.id } }) }
            else { var seen = Set<String>(); documents = rows.filter { seen.insert($0.id).inserted } }
            loadedCatalogQuery = search
            total = response.total
            jobs = Dictionary(activeJobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            documentsEnabled = configuration.documentsEnabled == true && configuration.enabled != false
            error = nil
        } catch {
            guard !Task.isCancelled, token == generation, request == catalogRequest,
                  search == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.error = "Library could not refresh. \(error.localizedDescription)"
        }
        if token == generation, request == catalogRequest { isLoading = false }
    }
    func setEnabled(_ value: Bool) {
        perform(key: "settings") { backend, root in
            var settings: [String: Any] = ["workspace": root, "documents_enabled": value]
            if value { settings["enabled"] = true }
            let _: Settings = try await backend.post("/api/knowledge/settings", body: settings, as: Settings.self)
            if value {
                let _: Settings = try await backend.post("/api/knowledge/reindex", body: ["workspace": root], timeout: 120, as: Settings.self)
            }
        }
    }
    func importDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["pdf", "docx", "xlsx", "csv", "tsv"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        importDocuments(panel.urls)
    }
    func importDocuments(_ urls: [URL]) {
        perform(key: "import") { backend, root in
            for source in urls {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let copy = try Self.importCopy(source, workspace: root)
                let relative = String(copy.path.dropFirst(OutputsLibraryStore.canonical(root).count + 1))
                let _: JobResponse = try await backend.post("/api/document-jobs", body: [
                    "workspace": root, "path": relative, "persistent": true, "ocr_mode": "auto"
                ], as: JobResponse.self)
            }
        }
    }
    nonisolated static func importCopy(_ source: URL, workspace: String) throws -> URL {
        let folder = URL(fileURLWithPath: workspace).appendingPathComponent("Locus Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolvedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedFolder.path.hasPrefix(OutputsLibraryStore.canonical(workspace) + "/") else {
            throw OutputsLibraryStore.StoreError("The Documents folder points outside this workspace")
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw OutputsLibraryStore.StoreError("Choose a document file") }
        guard (values.fileSize ?? 0) <= 100_000_000 else { throw OutputsLibraryStore.StoreError("Documents must be 100 MB or smaller") }
        let stem = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
        for number in 0..<10_000 {
            let name = stem + (number == 0 ? "" : " (\(number + 1))") + (ext.isEmpty ? "" : "." + ext)
            let destination = folder.appendingPathComponent(name)
            do {
                // copyItem fails if another import wins the same name. Never
                // replace a destination after a racy existence check.
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw OutputsLibraryStore.StoreError("Could not find an available filename")
    }
    func retry(_ document: LibraryDocument, recognizeAllPages: Bool = false) {
        perform(key: document.id) { backend, root in
            let _: JobResponse = try await backend.post("/api/document-jobs", body: ["workspace": root, "path": document.path,
                "persistent": true, "ocr_mode": recognizeAllPages ? "always" : "auto"], as: JobResponse.self)
        }
    }
    func cancel(_ document: LibraryDocument) {
        guard let jobID = document.jobID else { return }
        perform(key: document.id) { backend, root in
            let _: JobResponse = try await backend.post("/api/document-jobs/\(jobID)/cancel", body: ["workspace": root], as: JobResponse.self)
        }
    }
    func exclude(_ document: LibraryDocument, excluded: Bool) {
        perform(key: document.id) { backend, root in
            let _: DocumentResponse = try await backend.post("/api/documents/\(document.id)/exclude", body: ["workspace": root, "excluded": excluded], as: DocumentResponse.self)
        }
    }
    func remove(_ document: LibraryDocument) {
        perform(key: document.id) { backend, root in
            let _: SimpleActionResponse = try await backend.delete("/api/documents/\(document.id)", query: [.init(name: "workspace", value: root)], as: SimpleActionResponse.self)
        }
    }
    func search() {
        searchTask?.cancel()
        catalogRequest = UUID()
        searchResults = []
        let root = workspace, token = generation, search = query
        searchTask = Task {
            guard let backend else { return }
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            async let catalog: Void = refresh()
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await catalog
                return
            }
            do {
                let response = try await backend.get("/api/knowledge/search", query: [.init(name: "workspace", value: root), .init(name: "query", value: search), .init(name: "limit", value: "20")], timeout: 30, as: SearchResponse.self)
                guard !Task.isCancelled, token == generation, search == query else { return }
                searchResults = response.results.filter { !$0.path.isEmpty }
            } catch {
                guard !Task.isCancelled, token == generation, search == query else { return }
                self.error = error.localizedDescription
            }
            await catalog
        }
    }
    func open(_ document: LibraryDocument) {
        open(DocumentReference(workspace: workspace, path: document.path, contentHash: document.contentHash, location: nil), jobID: document.jobID)
    }
    func open(_ reference: DocumentReference, jobID: String? = nil) {
        guard OutputsLibraryStore.canonical(reference.workspace) == workspace,
              let url = OutputsLibraryStore.containedURL(reference.path, workspace: workspace),
              FileManager.default.fileExists(atPath: url.path) else { error = "This source is no longer available in the workspace"; return }
        let token = UUID()
        previewGeneration = token
        Task {
            let hash = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return OutputsLibraryStore.digest(data)
            }.value
            guard token == previewGeneration else { return }
            var checked = reference
            let stale = reference.contentHash != nil && hash != reference.contentHash
            if stale { checked.location = nil }
            var result: DocumentExtractionResult?
            if !stale, let jobID, let backend {
                result = try? await backend.get("/api/document-jobs/\(jobID)/result", query: [.init(name: "workspace", value: workspace)], as: DocumentExtractionResult.self)
            }
            guard token == previewGeneration else { return }
            if let result, let expected = reference.contentHash, result.contentHash != expected {
                self.previewRequest = DocumentPreviewRequest(url: url, title: url.lastPathComponent, warning: "This source changed. Reindex it before following the old citation.")
            } else {
                self.previewRequest = DocumentPreviewRequest(url: url, title: url.lastPathComponent, reference: checked, result: result,
                    warning: stale ? "This source changed since it was indexed. The current file is shown without the old citation highlight." : nil)
            }
        }
    }
    func openSearchHit(_ hit: DocumentSearchHit) {
        let document = documents.first { $0.path == hit.path }
        open(DocumentReference(workspace: workspace, path: hit.path, contentHash: hit.contentHash,
            location: hit.locator ?? DocumentLocation(kind: "line", lineStart: hit.lineStart, lineEnd: hit.lineEnd)), jobID: document?.jobID)
    }
    func showPreview(url: URL, title: String, reference: DocumentReference? = nil) {
        previewGeneration = UUID()
        previewRequest = DocumentPreviewRequest(url: url, title: title, reference: reference)
    }

    /// Attachments and snapshot previews use bounded uploads so they never
    /// enroll an external file in persistent workspace knowledge.
    func extractTemporary(_ url: URL, workspace target: String? = nil) async throws -> DocumentExtractionResult {
        guard let backend else { throw OutputsLibraryStore.StoreError("The local agent is unavailable") }
        let root = target ?? workspace
        let data = try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 100_000_000 else {
                throw OutputsLibraryStore.StoreError("Documents must be 100 MB or smaller")
            }
            return try Data(contentsOf: url)
        }.value
        let submitted = try await backend.upload("/api/document-jobs/upload", query: [
            .init(name: "workspace", value: root), .init(name: "filename", value: url.lastPathComponent), .init(name: "persistent", value: "false")
        ], data: data, as: JobResponse.self)
        let jobID = submitted.job.id
        return try await withTaskCancellationHandler {
            var job = submitted.job
            for _ in 0..<300 {
                try Task.checkCancellation()
                if !job.isActive {
                    guard job.resultAvailable else { throw OutputsLibraryStore.StoreError(job.error ?? "The document could not be extracted") }
                    return try await backend.get("/api/document-jobs/\(jobID)/result", query: [.init(name: "workspace", value: root)], timeout: 30, as: DocumentExtractionResult.self)
                }
                try await Task.sleep(for: .seconds(1))
                job = try await backend.get("/api/document-jobs/\(jobID)", query: [.init(name: "workspace", value: root)], as: JobResponse.self).job
            }
            let _: JobResponse = try await backend.post("/api/document-jobs/\(jobID)/cancel", body: ["workspace": root], as: JobResponse.self)
            throw OutputsLibraryStore.StoreError("Document extraction took too long. Try a smaller document.")
        } onCancel: {
            Task { @MainActor in
                let _: JobResponse? = try? await backend.post("/api/document-jobs/\(jobID)/cancel", body: ["workspace": root], as: JobResponse.self)
            }
        }
    }
    private func perform(key: String, action: @escaping (BackendService, String) async throws -> Void) {
        guard let backend, !pending.contains(key) else { return }
        let root = workspace, token = generation
        pending.insert(key)
        Task {
            defer { if token == generation { pending.remove(key) } }
            do {
                try await action(backend, root)
                if token == generation { await refresh() }
            } catch {
                if token == generation { self.error = error.localizedDescription }
            }
        }
    }
}
