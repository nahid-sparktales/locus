import CoreServices
import Combine
import Foundation
import UniformTypeIdentifiers

struct WorkspaceBrowserEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case directory, file, package, symbolicLink }
    enum ContextAction: Equatable, Sendable {
        case context, attachment, unavailable
        var label: String? {
            switch self {
            case .context: "Add to context"
            case .attachment: "Attach to message"
            case .unavailable: nil
            }
        }
    }
    var id: String { path }
    let path: String
    let name: String
    let kind: Kind
    let byteCount: Int64?
    let contextAction: ContextAction
    var isDirectory: Bool { kind == .directory }
    var symbol: String {
        if isDirectory { return "folder" }
        if kind == .symbolicLink { return "link" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "doc.richtext" }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext) { return "photo" }
        if ["xlsx", "xls", "csv", "tsv", "numbers"].contains(ext) { return "tablecells" }
        return "doc.text"
    }

    static func contextAction(extension ext: String, size: Int64?, isRegularFile: Bool) -> ContextAction {
        guard isRegularFile, let size else { return .unavailable }
        let type = UTType(filenameExtension: ext)
        if ["pdf", "docx", "xlsx", "csv", "tsv"].contains(ext), size <= 100_000_000 { return .attachment }
        if type?.conforms(to: .image) == true, size <= 15_000_000 { return .attachment }
        if ContextFileTypes.allowedExtensions.contains(ext) || type?.conforms(to: .text) == true {
            if size <= 256_000 { return .context }
            if size <= 500_000 { return .attachment }
        }
        return .unavailable
    }
}

/// File metadata is read on an actor; viewing a directory never walks its children.
actor WorkspaceBrowserProvider {
    struct SearchBatch: Sendable {
        let entries: [WorkspaceBrowserEntry]
        let examined: Int
        let finished: Bool
        let errors: [String]
    }
    private struct SearchCursor {
        let enumerator: FileManager.DirectoryEnumerator
        let root: String
        let term: String
        var examined = 0
        let errors: ErrorLog
    }
    private final class ErrorLog {
        var paths: [String] = []
    }
    private var searches: [UUID: SearchCursor] = [:]
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
    ]

    func children(workspace: String, directory: String, showHidden: Bool) throws -> [WorkspaceBrowserEntry] {
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let url = try Self.directoryURL(root: root, path: directory)
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(Self.resourceKeys), options: options
        )
        var entries: [WorkspaceBrowserEntry] = []
        for (index, child) in urls.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if let entry = Self.entry(child, root: root.path) { entries.append(entry) }
        }
        return entries.sorted(by: Self.ordered)
    }

    func beginSearch(id: UUID, workspace: String, query: String, showHidden: Bool) throws {
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        _ = try Self.directoryURL(root: root, path: "")
        let log = ErrorLog()
        let options: FileManager.DirectoryEnumerationOptions = showHidden
            ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(Self.resourceKeys), options: options,
            errorHandler: { url, _ in
                if log.paths.count < 5 { log.paths.append(Self.relativePath(url, root: root.path)) }
                return true
            }
        ) else { throw CocoaError(.fileReadNoPermission) }
        searches[id] = SearchCursor(enumerator: enumerator, root: root.path, term: query.lowercased(), errors: log)
    }

    func nextSearchBatch(id: UUID, maximumMatches: Int) throws -> SearchBatch {
        guard var cursor = searches[id] else { throw CancellationError() }
        var entries: [WorkspaceBrowserEntry] = []
        var finished = false
        for _ in 0..<256 {
            try Task.checkCancellation()
            guard let url = cursor.enumerator.nextObject() as? URL else { finished = true; break }
            cursor.examined += 1
            guard let entry = Self.entry(url, root: cursor.root) else { continue }
            if entry.kind == .symbolicLink || entry.kind == .package { cursor.enumerator.skipDescendants() }
            if entry.path.lowercased().contains(cursor.term) { entries.append(entry) }
            if entries.count >= maximumMatches { break }
        }
        if finished { searches.removeValue(forKey: id) } else { searches[id] = cursor }
        return SearchBatch(entries: entries, examined: cursor.examined, finished: finished, errors: cursor.errors.paths)
    }

    func cancelSearch(id: UUID) { searches.removeValue(forKey: id) }

    private static func directoryURL(root: URL, path: String) throws -> URL {
        let url = path.isEmpty ? root : root.appendingPathComponent(path)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved == root || resolved.path.hasPrefix(prefix) else { throw CocoaError(.fileReadNoPermission) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isDirectory == true, path.isEmpty || (values.isSymbolicLink != true && values.isPackage != true)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        return url
    }

    private static func entry(_ url: URL, root: String) -> WorkspaceBrowserEntry? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        let kind: WorkspaceBrowserEntry.Kind = values.isSymbolicLink == true ? .symbolicLink
            : values.isPackage == true ? .package : values.isDirectory == true ? .directory : .file
        let resolved = url.resolvingSymlinksInPath()
        let contained = resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        let regular = values.isRegularFile == true && contained && kind != .package
        let size = values.fileSize.map(Int64.init)
        return WorkspaceBrowserEntry(
            path: relativePath(url, root: root), name: url.lastPathComponent,
            kind: kind, byteCount: size,
            contextAction: WorkspaceBrowserEntry.contextAction(extension: url.pathExtension.lowercased(), size: size, isRegularFile: regular)
        )
    }

    private static func ordered(_ lhs: WorkspaceBrowserEntry, _ rhs: WorkspaceBrowserEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Directory enumeration may spell /var as /private/var and add a trailing
    /// slash. Standardize both without resolving the leaf symlink's identity.
    private static func relativePath(_ url: URL, root: String) -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

@MainActor
final class WorkspaceBrowserModel: ObservableObject {
    nonisolated static let pageSize = 200
    nonisolated static let searchMatchBudget = 10_000
    enum LoadState: Equatable { case idle, loading, ready, failed(String) }
    struct DirectoryState: Equatable {
        var entries: [WorkspaceBrowserEntry] = []
        var visibleCount = WorkspaceBrowserModel.pageSize
        var state: LoadState = .idle
        var dirty = false
    }
    struct Row: Identifiable {
        enum Content { case entry(WorkspaceBrowserEntry), loading(String), failure(String, String), more(String, Int), empty(String) }
        let id: String
        let depth: Int
        let content: Content
    }
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var showHidden = false { didSet { if showHidden != oldValue { refresh() } } }
    @Published private(set) var workspace = ""
    @Published private(set) var directories: [String: DirectoryState] = [:]
    @Published private(set) var expanded: Set<String> = [""]
    @Published private(set) var searchResults: [WorkspaceBrowserEntry] = []
    @Published private(set) var searchState: LoadState = .idle
    @Published private(set) var searchExamined = 0
    @Published private(set) var searchPaused = false
    @Published private(set) var searchWarnings: [String] = []
    @Published private(set) var searchVisibleCount = pageSize
    @Published private(set) var selectedPath: String?
    var onContentsChanged: ((String) -> Void)?
    private let provider: WorkspaceBrowserProvider
    private let watcher = WorkspaceBrowserWatcher()
    private var generation = UUID()
    private var directoryGenerations: [String: UUID] = [:]
    private var directoryTasks: [String: Task<Void, Never>] = [:]
    private var searchID: UUID?
    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var invalidatedParents: Set<String> = []
    private var invalidateEverything = false
    private var fixtureEntries: [WorkspaceBrowserEntry]?
    private var fixtureSignature: Set<String>?

    init(provider: WorkspaceBrowserProvider = WorkspaceBrowserProvider()) { self.provider = provider }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var visibleSearchResults: [WorkspaceBrowserEntry] { Array(searchResults.prefix(searchVisibleCount)) }
    var rootState: LoadState { directories[""]?.state ?? .idle }

    func activate(workspace root: String, watch: Bool = true) {
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        guard root != workspace else { if directories[""] == nil { loadDirectory("") }; return }
        stop()
        generation = UUID()
        workspace = root
        directories = [:]
        expanded = [""]
        selectedPath = nil
        fixtureEntries = nil
        fixtureSignature = nil
        query = ""
        searchResults = []
        searchState = .idle
        if watch {
            watcher.start(root: root) { [weak self] paths, full in
                Task { @MainActor [weak self] in
                    guard let self, self.workspace == root else { return }
                    self.invalidate(paths: paths, full: full)
                }
            }
        }
        loadDirectory("")
    }

    func select(_ path: String) { selectedPath = path }
    func revealDirectory(_ path: String) {
        query = ""
        var parent = path
        while !parent.isEmpty {
            expanded.insert(parent)
            loadDirectory(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        loadDirectory("")
    }
    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else {
            expanded.insert(path)
            if directories[path] == nil || directories[path]?.dirty == true { loadDirectory(path) }
        }
    }
    func showMore(in path: String) { directories[path]?.visibleCount += Self.pageSize }
    func showMoreSearchResults() { searchVisibleCount += Self.pageSize }

    func loadDirectory(_ path: String) {
        guard !workspace.isEmpty else { return }
        directoryTasks[path]?.cancel()
        let request = UUID(), currentGeneration = generation, root = workspace, hidden = showHidden
        directoryGenerations[path] = request
        var state = directories[path] ?? DirectoryState()
        state.state = .loading
        state.dirty = false
        directories[path] = state
        if let fixtureEntries {
            let children = fixtureEntries.filter { ($0.path as NSString).deletingLastPathComponent == path }
                .filter { hidden || !$0.name.hasPrefix(".") }
            directories[path]?.entries = children.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            directories[path]?.state = .ready
            return
        }
        directoryTasks[path] = Task { [weak self, provider] in
            do {
                let entries = try await provider.children(workspace: root, directory: path, showHidden: hidden)
                guard !Task.isCancelled, let self, self.generation == currentGeneration,
                      self.directoryGenerations[path] == request else { return }
                self.directories[path]?.entries = entries
                self.directories[path]?.state = .ready
                if let selected = self.selectedPath, (selected as NSString).deletingLastPathComponent == path,
                   !entries.contains(where: { $0.path == selected }) { self.selectedPath = nil }
            } catch {
                guard !Task.isCancelled, let self, self.generation == currentGeneration,
                      self.directoryGenerations[path] == request else { return }
                self.directories[path]?.state = .failed(error.localizedDescription)
            }
        }
    }

    func refresh() {
        guard !workspace.isEmpty else { return }
        for path in Array(directories.keys) { directories[path]?.dirty = true }
        for path in expanded { loadDirectory(path) }
        if isSearching { scheduleSearch() }
        onContentsChanged?(workspace)
    }

    /// Event paths include vanished files. Invalidate parents instead of classifying outputs.
    func invalidate(paths: [String], full: Bool = false) {
        invalidateEverything = invalidateEverything || full
        for raw in paths {
            let normalized = raw.hasPrefix("/") ? URL(fileURLWithPath: raw).standardizedFileURL.path : raw
            let relative = normalized.hasPrefix(workspace + "/") ? String(normalized.dropFirst(workspace.count + 1)) : normalized
            if normalized == workspace { invalidateEverything = true; continue }
            invalidatedParents.insert((relative as NSString).deletingLastPathComponent)
            if directories[relative] != nil { invalidatedParents.insert(relative) }
        }
        refreshTask?.cancel()
        let currentGeneration = generation
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            let parents = self.invalidateEverything ? Set(self.directories.keys) : self.invalidatedParents
            self.invalidatedParents = []
            self.invalidateEverything = false
            for path in parents where self.directories[path] != nil {
                self.directories[path]?.dirty = true
                if self.expanded.contains(path) { self.loadDirectory(path) }
            }
            if self.isSearching { self.scheduleSearch() }
            self.onContentsChanged?(self.workspace)
        }
    }

    var rows: [Row] {
        var result: [Row] = []
        func append(_ path: String, depth: Int) {
            let directory = directories[path] ?? DirectoryState()
            for entry in directory.entries.prefix(directory.visibleCount) {
                result.append(Row(id: "entry:" + entry.path, depth: depth, content: .entry(entry)))
                if entry.isDirectory, expanded.contains(entry.path) { append(entry.path, depth: depth + 1) }
            }
            switch directory.state {
            case .idle, .loading: result.append(Row(id: "loading:" + path, depth: depth, content: .loading(path)))
            case .failed(let error): result.append(Row(id: "error:" + path, depth: depth, content: .failure(path, error)))
            case .ready:
                if directory.entries.isEmpty { result.append(Row(id: "empty:" + path, depth: depth, content: .empty(path))) }
            }
            if directory.entries.count > directory.visibleCount {
                result.append(Row(id: "more:" + path, depth: depth, content: .more(path, directory.entries.count - directory.visibleCount)))
            }
        }
        append("", depth: 0)
        return result
    }

    private func scheduleSearch() {
        cancelSearch()
        searchResults = []
        searchVisibleCount = Self.pageSize
        searchExamined = 0
        searchPaused = false
        searchWarnings = []
        guard isSearching, !workspace.isEmpty else { searchState = .idle; return }
        searchState = .loading
        let id = UUID(), root = workspace, term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGeneration = generation, hidden = showHidden
        searchID = id
        if let fixtureEntries {
            searchResults = fixtureEntries.filter { $0.path.localizedCaseInsensitiveContains(term) && (hidden || !$0.path.split(separator: "/").contains(where: { $0.hasPrefix(".") })) }
            searchState = .ready
            return
        }
        searchTask = Task { [weak self, provider] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await provider.beginSearch(id: id, workspace: root, query: term, showHidden: hidden)
                guard !Task.isCancelled, let self, self.generation == currentGeneration, self.searchID == id else {
                    await provider.cancelSearch(id: id); return
                }
                await self.consumeSearch(id: id, generation: currentGeneration, matchLimit: Self.searchMatchBudget)
            } catch {
                guard !Task.isCancelled, let self, self.generation == currentGeneration, self.searchID == id else { return }
                self.searchState = .failed(error.localizedDescription)
            }
        }
    }

    func continueSearch() {
        guard searchPaused, let id = searchID else { return }
        searchPaused = false
        searchState = .loading
        let currentGeneration = generation, limit = searchResults.count + Self.searchMatchBudget
        searchTask = Task { [weak self] in await self?.consumeSearch(id: id, generation: currentGeneration, matchLimit: limit) }
    }

    private func consumeSearch(id: UUID, generation currentGeneration: UUID, matchLimit: Int) async {
        do {
            while !Task.isCancelled {
                let batch = try await provider.nextSearchBatch(id: id, maximumMatches: matchLimit - searchResults.count)
                guard !Task.isCancelled, generation == currentGeneration, searchID == id else { return }
                searchResults.append(contentsOf: batch.entries)
                searchExamined = batch.examined
                searchWarnings = batch.errors
                if batch.finished { searchState = .ready; return }
                if searchResults.count >= matchLimit { searchPaused = true; searchState = .ready; return }
                await Task.yield()
            }
        } catch {
            guard !Task.isCancelled, generation == currentGeneration, searchID == id else { return }
            searchState = .failed(error.localizedDescription)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        if let id = searchID { Task { [provider] in await provider.cancelSearch(id: id) } }
        searchID = nil
    }
    func stop() {
        watcher.stop()
        refreshTask?.cancel()
        directoryTasks.values.forEach { $0.cancel() }
        directoryTasks = [:]
        invalidatedParents = []
        invalidateEverything = false
        cancelSearch()
    }

    /// Deterministic UI fixtures use their existing text-file seed without reading the host.
    func seed(urls: [URL], workspace root: String) {
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let signature = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        if workspace == root, fixtureSignature == signature { return }
        stop()
        generation = UUID()
        workspace = root
        directories = [:]
        expanded = [""]
        selectedPath = nil
        query = ""
        searchResults = []
        searchState = .idle
        fixtureSignature = signature
        var entries: [String: WorkspaceBrowserEntry] = [:]
        for url in urls {
            let path = WorkspaceIndex.relativePath(url.standardizedFileURL.resolvingSymlinksInPath(), root: root)
            entries[path] = .init(path: path, name: url.lastPathComponent, kind: .file, byteCount: nil, contextAction: .context)
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" {
                entries[parent] = .init(path: parent, name: (parent as NSString).lastPathComponent, kind: .directory, byteCount: nil, contextAction: .unavailable)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        fixtureEntries = Array(entries.values)
        loadDirectory("")
    }
}

/// A browser needs every directory change, including removals and generated files.
/// Output-capture watchers intentionally discard those, so reuse native FSEvents
/// directly with the same bounded serial callback lifecycle.
final class WorkspaceBrowserWatcher {
    private var stream: FSEventStreamRef?
    private var handler: (([String], Bool) -> Void)?
    private let queue = DispatchQueue(label: "com.locus.workspace-browser", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    init() { queue.setSpecific(key: queueKey, value: true) }

    func start(root: String, handler: @escaping ([String], Bool) -> Void) {
        stop()
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<WorkspaceBrowserWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var changed: [String] = []
            var full = count > 512
            for index in 0..<min(count, 512) {
                if let path = paths[index] { changed.append(String(cString: path)) }
                let invalidating = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
                if flags[index] & invalidating != 0 { full = true }
            }
            owner.handler?(changed, full)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
        FSEventStreamRelease(stream)
        self.stream = nil
        handler = nil
    }
    deinit { stop() }
}
