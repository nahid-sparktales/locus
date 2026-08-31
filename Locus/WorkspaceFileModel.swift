import Combine
import Foundation

struct WorkspacePreviewLocation: Hashable, Sendable {
    let line: Int
    let column: Int?
}

/// A request to read one workspace file in the large viewer sheet.
struct WorkspaceFileViewerRequest: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    let location: WorkspacePreviewLocation?

    var id: String { relativePath }
}

/// Feature-owned state for workspace file discovery and inline previews.
///
/// The application root supplies only the current workspace and whether a
/// session is ready to index. Scan and preview tasks stay with the state they
/// update so a workspace change cannot publish stale results into another
/// session.
@MainActor
final class WorkspaceFileModel: ObservableObject {
    typealias Scanner = @Sendable (String) -> [URL]

    @Published var query = ""
    @Published private(set) var files: [URL] = []
    @Published private(set) var previewedPath: String?
    @Published private(set) var previewedContents: String?
    @Published private(set) var previewedLocation: WorkspacePreviewLocation?

    private let scanner: Scanner
    private var isUITesting = false
    private var workspacePathProvider: () -> String = {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
    private var canIndexProvider: () -> Bool = { false }
    private var indexedWorkspacePath: String?
    private var indexTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init(scanner: @escaping Scanner = { WorkspaceIndex.scan(root: $0) }) {
        self.scanner = scanner
    }

    func configure(
        isUITesting: Bool,
        workspacePath: @escaping () -> String,
        canIndex: @escaping () -> Bool
    ) {
        self.isUITesting = isUITesting
        workspacePathProvider = workspacePath
        canIndexProvider = canIndex
    }

    var filteredFiles: [URL] {
        WorkspaceIndex.matches(
            query: query,
            in: files,
            root: workspacePath,
            limit: 200
        )
    }

    func refresh(force: Bool = false) {
        // UI tests run against a seeded index; scanning the runner would make
        // their file browser depend on unrelated host files.
        guard !isUITesting else { return }
        let root = workspacePath
        // Before session metadata arrives AppModel's workspace is a fallback
        // path. Never walk that broad directory for a result that will be
        // discarded as soon as the real workspace becomes available.
        guard canIndexProvider() else { return }
        guard force || indexedWorkspacePath != root || files.isEmpty else { return }
        indexTask?.cancel()
        let scanner = scanner
        indexTask = Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                scanner(root)
            }.value
            // Cancellation alone is not a staleness boundary: two overlapping
            // scans of the same root have the same valid answer. Workspace
            // identity is the condition that determines whether to publish.
            guard let self, self.workspacePath == root else { return }
            indexedWorkspacePath = root
            self.files = files
        }
    }

    func preview(_ url: URL, line: Int? = nil, column: Int? = nil) {
        let root = workspacePath
        let relativePath = WorkspaceIndex.relativePath(url, root: root)
        previewedPath = relativePath
        previewedContents = nil
        previewedLocation = line.map {
            WorkspacePreviewLocation(line: max($0, 1), column: column.map { max($0, 1) })
        }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let result = await Self.previewText(at: url)
            guard !Task.isCancelled, let self, self.workspacePath == root,
                  self.previewedPath == relativePath
            else { return }
            previewedContents = result
        }
    }

    /// Reads a file for on-screen preview: size-capped, UTF-8 text only. The
    /// failure strings render in place of content.
    static func previewText(at url: URL, byteLimit: Int = 256_000) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= byteLimit
            else {
                let limit = ByteCountFormatter.string(
                    fromByteCount: Int64(byteLimit), countStyle: .file
                )
                return "This file is larger than \(limit)."
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data, encoding: .utf8)
            else { return "This file is not readable as UTF-8 text." }
            return text
        }.value
    }

    func closePreview() {
        previewTask?.cancel()
        previewedPath = nil
        previewedContents = nil
        previewedLocation = nil
    }

    func stop() {
        indexTask?.cancel()
        previewTask?.cancel()
    }

    /// Deterministic fixture setup without exposing mutable production state.
    func seed(_ files: [URL], workspacePath: String) {
        indexedWorkspacePath = workspacePath
        self.files = files
    }

    private var workspacePath: String { workspacePathProvider() }
}
