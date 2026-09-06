import AppKit
import Combine
import Foundation

@MainActor
final class OutputsLibraryModel: ObservableObject {
    @Published private(set) var items: [LibraryOutput] = []
    @Published var query = ""
    @Published var typeFilter = "all"
    @Published var selectedItemID: String?
    @Published var selectedVersionID: String?
    @Published private(set) var sourceSessionID: String?
    @Published private(set) var sourceRunID: String?
    @Published private(set) var error: String?
    @Published private(set) var storageLimit = OutputsLibraryStore.defaultWorkspaceLimit
    @Published private(set) var isRefreshing = false
    let store: OutputsLibraryStore
    private var workspace = ""
    private var captureTail: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var seenTouches: [String: Int] = [:]
    private var enabled = false
    private var refreshGeneration = UUID()
    private var runs: [String: CaptureRun] = [:]
    private var retiredRunIDs: [String: Set<String>] = [:]
    private struct CaptureRun {
        let workspace: String
        let sessionID: String
        var runID: String?
        let watcher: SessionOutputWatcher
        let startedAt = Date()
        var paths: Set<String> = []
        var provenPaths: Set<String> = []
        var ambiguous = false
    }

    init(store: OutputsLibraryStore = OutputsLibraryStore()) { self.store = store }

    var visibleItems: [LibraryOutput] {
        items.filter { (typeFilter == "all" || $0.kind == typeFilter)
            && $0.versions.contains { version in
                version.belongsTo(sessionID: sourceSessionID, runID: sourceRunID)
            }
            && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.target.localizedCaseInsensitiveContains(query)) }
    }
    var selectedItem: LibraryOutput? { items.first { $0.id == selectedItemID } }
    var selectedVersion: OutputVersion? {
        selectedItem?.versions.first { $0.id == selectedVersionID }
            ?? selectedItem?.versions.last { $0.belongsTo(sessionID: sourceSessionID, runID: sourceRunID) }
    }
    var storageUsed: Int64 {
        Dictionary(items.flatMap(\.versions).compactMap { v in v.hash.map { ($0, v.byteCount) } }, uniquingKeysWith: { a, _ in a }).values.reduce(0, +)
    }
    func sourceSession(for version: OutputVersion) -> String {
        let primary = OutputOrigin(sessionID: version.sessionID, runID: version.runID, capturedAt: version.capturedAt)
        return ((version.origins ?? []) + [primary]).last(where: {
            (sourceSessionID == nil || $0.sessionID == sourceSessionID)
                && (sourceRunID == nil || $0.runID == sourceRunID)
        })?.sessionID ?? version.sessionID
    }

    func configure(emitter: SessionStateEmitter, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { return }
        // Seed the observation before migration so historical timestamps do
        // not produce pretend versions on first launch.
        for (session, state) in emitter.states {
            for file in state.files { seenTouches[session + "|" + file.path] = file.lastTouchedAt }
        }
        let states = emitter.states
        enqueue { [store] in try await store.migrate(states) }
        observation = emitter.$states.sink { [weak self] states in
            self?.ingest(states)
        }
    }

    func activate(workspace: String) {
        let canonical = OutputsLibraryStore.canonical(workspace)
        if self.workspace != canonical {
            self.workspace = canonical
            items = []
            selectedItemID = nil
            selectedVersionID = nil
            query = ""
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard enabled, !workspace.isEmpty else { return }
        let generation = UUID()
        refreshGeneration = generation
        let target = workspace
        isRefreshing = true
        do {
            let values = try await store.list(workspace: target)
            let limit = try await store.workspaceLimit(target)
            guard generation == refreshGeneration, target == workspace else { return }
            items = values
            storageLimit = limit
            error = nil
        } catch {
            guard generation == refreshGeneration, target == workspace else { return }
            self.error = error.localizedDescription
        }
        if generation == refreshGeneration { isRefreshing = false }
    }

    func capture(workspace: String, path: String, sessionID: String, runID: String? = nil, website: Bool = false) {
        guard enabled, !workspace.isEmpty else { return }
        let request = OutputCapture(workspace: workspace, path: path, sessionID: sessionID, runID: runID, website: website)
        enqueue { [store] in _ = try await store.capture(request) }
    }

    /// Called before sending a new run; its predecessor has already finished
    /// flushing, so a later run cannot overwrite files awaiting snapshots.
    func beginRun(workspace: String, sessionID: String, runID: String? = nil) {
        guard enabled, !workspace.isEmpty, !sessionID.isEmpty else { return }
        endRun(sessionID: sessionID)
        if let runID { retiredRunIDs[sessionID]?.remove(runID) }
        let watcher = SessionOutputWatcher()
        let overlapping = runs.keys.filter { OutputsLibraryStore.canonical(runs[$0]!.workspace) == OutputsLibraryStore.canonical(workspace) }
        for key in overlapping { runs[key]?.ambiguous = true }
        runs[sessionID] = CaptureRun(workspace: workspace, sessionID: sessionID, runID: runID, watcher: watcher, ambiguous: !overlapping.isEmpty)
        watcher.start(path: workspace, since: Date()) { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, let run = self.runs[sessionID], run.watcher === watcher else { return }
                self.recordObservedChanges(changes, sessionID: sessionID)
            }
        }
    }

    func recordObservedChanges(_ changes: [SessionOutputWatcher.Change], sessionID: String) {
        guard let run = runs[sessionID] else { return }
        for change in changes {
            runs[sessionID]?.paths.insert(change.path)
            capture(workspace: run.workspace, path: change.path,
                    sessionID: run.ambiguous ? "" : sessionID, runID: run.ambiguous ? nil : run.runID)
        }
    }

    /// Legacy retry sends do not reserve an ID. Bind the backend's actual
    /// start acknowledgment without replacing the watcher or losing paths.
    /// Older acknowledgments cannot retarget a newer capture window.
    @discardableResult
    func bindRunIdentity(workspace: String, sessionID: String, runID: String, occurredAt: Date? = nil) -> Bool {
        guard !runID.isEmpty, var run = runs[sessionID],
              OutputsLibraryStore.canonical(workspace) == OutputsLibraryStore.canonical(run.workspace),
              occurredAt.map({ $0 >= run.startedAt }) ?? true,
              retiredRunIDs[sessionID]?.contains(runID) != true else { return false }
        if let existing = run.runID { return existing == runID }
        run.runID = runID
        runs[sessionID] = run
        for path in run.paths where !run.ambiguous || run.provenPaths.contains(path) {
            capture(workspace: run.workspace, path: path, sessionID: sessionID, runID: runID)
        }
        return true
    }

    func recordToolEffects(_ event: [String: Any], workspace: String, sessionID: String, runID: String? = nil) {
        let stampedID = (event["run_id"] as? String)?.nilIfEmpty ?? runID
        if let stampedID, retiredRunIDs[sessionID]?.contains(stampedID) == true { return }
        if let active = runs[sessionID] {
            guard OutputsLibraryStore.canonical(workspace) == OutputsLibraryStore.canonical(active.workspace),
                  active.runID == nil || stampedID == nil || active.runID == stampedID else { return }
            if let time = event["occurred_at"] as? Double, Date(timeIntervalSince1970: time) < active.startedAt { return }
        }
        let resolvedID = stampedID ?? runs[sessionID]?.runID
        guard let effects = event["file_effects"] as? [[String: Any]] else { return }
        for effect in effects {
            guard let path = effect["path"] as? String, let action = effect["effect"] as? String,
                  action == "create" || action == "edit" else { continue }
            runs[sessionID]?.paths.insert(path)
            runs[sessionID]?.provenPaths.insert(path)
            capture(workspace: workspace, path: path, sessionID: sessionID, runID: resolvedID)
        }
    }

    func endRun(sessionID: String) {
        guard let run = runs.removeValue(forKey: sessionID) else { return }
        if let runID = run.runID { retiredRunIDs[sessionID, default: []].insert(runID) }
        let pending = run.watcher.finish()
        for path in run.paths.union(pending.map(\.path)) {
            let attributed = !run.ambiguous || run.provenPaths.contains(path)
            capture(workspace: run.workspace, path: path, sessionID: attributed ? sessionID : "", runID: attributed ? run.runID : nil)
        }
    }

    func flush() async { await captureTail?.value }

    var hasCaptureWork: Bool { !runs.isEmpty || captureTail != nil }

    func finishCapturesForShutdown() async {
        for sessionID in Array(runs.keys) { endRun(sessionID: sessionID) }
        await flush()
    }

    func hasSavedVersion(workspace: String, relativePath: String, sessionID: String, since: Date, runID: String? = nil) async -> Bool {
        await flush()
        guard let values = try? await store.list(workspace: workspace) else { return false }
        return values.contains { $0.target == relativePath && $0.versions.contains {
            $0.hash != nil && (($0.sessionID == sessionID && $0.capturedAt >= since && (runID == nil || $0.runID == runID))
                || ($0.origins ?? []).contains {
                    $0.sessionID == sessionID && $0.capturedAt >= since && (runID == nil || $0.runID == runID)
                })
        } }
    }

    func open(itemID: String, versionID: String? = nil) {
        selectedItemID = itemID
        selectedVersionID = versionID
    }
    func filterOrigin(sessionID: String?, runID: String?) {
        sourceSessionID = sessionID
        sourceRunID = runID
        selectedVersionID = nil
    }
    func clearOriginFilter() { sourceSessionID = nil; sourceRunID = nil }
    func remove(_ item: LibraryOutput) {
        enqueue { [store] in try await store.remove(item) }
    }
    func setStorageLimit(gigabytes: Int) {
        let target = workspace
        enqueue { [store] in try await store.setWorkspaceLimit(Int64(gigabytes) * 1_000_000_000, workspace: target) }
    }
    func export(_ item: LibraryOutput, version: OutputVersion) {
        Task {
            guard let source = await store.versionURL(item, version: version) else { error = "This version has no saved file"; return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = item.title
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func enqueue(_ work: @escaping () async throws -> Void) {
        let previous = captureTail
        captureTail = Task { [weak self] in
            await previous?.value
            do { try await work() }
            catch { self?.error = error.localizedDescription; return }
            await self?.refresh()
        }
    }

    private func ingest(_ states: [String: SessionState]) {
        for (sessionID, state) in states where !state.workspace.path.isEmpty {
            for file in state.files where file.kind == .create || file.kind == .edit {
                let key = sessionID + "|" + file.path
                guard seenTouches[key] != file.lastTouchedAt else { continue }
                seenTouches[key] = file.lastTouchedAt
                // Tool and per-run watcher feeds own attribution while work is
                // active. Aggregate git/overview state has no exact run origin.
                if runs.values.contains(where: { OutputsLibraryStore.canonical($0.workspace) == OutputsLibraryStore.canonical(state.workspace.path) }) { continue }
                // New source files are outputs too; existing source edits only
                // join the library once a run has identified them as outputs.
                if file.kind == .create || items.contains(where: { $0.workspace == OutputsLibraryStore.canonical(state.workspace.path) && $0.target == file.path })
                    || Self.isDeliverable(file.path) {
                    // Overview/git do not carry exact producing-run evidence.
                    // Keep the deliverable but leave its origin unspecified;
                    // a tool report can subsequently attach the exact origin.
                    capture(workspace: state.workspace.path, path: file.path, sessionID: "", runID: nil)
                }
            }
            for output in state.outputs {
                let key = sessionID + "|" + output.target
                guard seenTouches[key] != output.lastSeenAt else { continue }
                seenTouches[key] = output.lastSeenAt
                capture(workspace: state.workspace.path, path: output.target, sessionID: sessionID, website: true)
            }
        }
    }
    private static func isDeliverable(_ path: String) -> Bool {
        ContextFileTypes.deliverableExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
