import Foundation

/// Owns the Activity Center: the runs list, presentation state, and the
/// per-run seen/dismissed bookkeeping with its pruned persistence. AppModel
/// wires it via configure(...) and bridges its publication; it never retains
/// AppModel.
@MainActor
final class ActivityCenterModel: ObservableObject {
    enum Focus: Hashable {
        case run(String)
        case workflow(String)

        func includes(_ item: AttentionItem) -> Bool {
            switch self {
            case .run(let id): item.runID == id
            case .workflow(let id): item.workflowExecutionID == id
            }
        }
        func includes(_ run: OrchestrationRun) -> Bool {
            switch self {
            case .run(let id): run.id == id
            case .workflow(let id): run.manifest?["workflow_execution_id"]?.string == id
            }
        }
        var query: URLQueryItem {
            switch self {
            case .run(let id): URLQueryItem(name: "run_id", value: id)
            case .workflow(let id): URLQueryItem(name: "workflow_execution_id", value: id)
            }
        }
    }
    enum Tab: String, CaseIterable, Identifiable {
        case attention = "Attention"
        case activity = "Activity"
        var id: String { rawValue }
    }

    @Published var activityCenterPresented = false
    @Published var selectedTab: Tab = .activity
    @Published private(set) var focus: Focus?
    @Published private(set) var focusedAttention: [AttentionItem] = []
    @Published private(set) var focusError: String?
    @Published private(set) var isRefreshingFocus = false
    @Published private(set) var focusedRun: OrchestrationRun?
    private var focusGeneration = UUID()
    @Published var activityRuns: [OrchestrationRun] = []
    @Published private(set) var persistedAttentionItems: [AttentionItem] = []
    @Published private(set) var activitySeenUpdates: [String: Double] = [:]
    @Published private(set) var dismissedActivityRunIDs: Set<String> = []
    @Published private(set) var acknowledgedWarningRunIDs: Set<String> = []

    private var backend: BackendService?
    private var persistenceEnabled = false
    private var defaults: UserDefaults = .standard
    private var toastHandler: (String) -> Void = { _ in }
    private var liveAttentionProvider: () -> [AttentionItem] = { [] }

    var activityNeedsAttentionCount: Int {
        attentionItems.count
    }

    var attentionItems: [AttentionItem] {
        let live = liveAttentionProvider()
        var seenKeys: Set<String> = []
        var combined: [AttentionItem] = []
        for item in live + persistedAttentionItems {
            let key = item.runID.map { "run:\($0)" } ?? item.id
            guard seenKeys.insert(key).inserted else { continue }
            combined.append(item)
        }
        let groupOrder: [AttentionGroup: Int] = [
            .decisions: 0, .recoveries: 1, .configuration: 2,
        ]
        return combined.sorted {
            (groupOrder[$0.group, default: 3], $0.timestamp, $0.id)
                < (groupOrder[$1.group, default: 3], $1.timestamp, $1.id)
        }
    }

    var visibleActivityRuns: [OrchestrationRun] {
        activityRuns.filter { !dismissedActivityRunIDs.contains($0.id) }
    }

    var displayedAttentionItems: [AttentionItem] {
        guard let focus else { return attentionItems }
        var seen: Set<String> = []
        return (attentionItems + focusedAttention).filter {
            focus.includes($0) && seen.insert($0.runID.map { "run:\($0)" } ?? $0.id).inserted
        }
    }

    var displayedActivityRuns: [OrchestrationRun] {
        guard let focus else { return visibleActivityRuns }
        var seen: Set<String> = []
        return (visibleActivityRuns + (focusedRun.map { [$0] } ?? [])).filter {
            focus.includes($0) && seen.insert($0.id).inserted
        }
    }

    func restore(persistenceEnabled: Bool, defaults: UserDefaults = .standard) {
        self.persistenceEnabled = persistenceEnabled
        self.defaults = defaults
        guard persistenceEnabled else { return }
        if let data = defaults.data(forKey: "Locus.activitySeenUpdates"),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            activitySeenUpdates = saved
        }
        dismissedActivityRunIDs = Set(
            defaults.stringArray(forKey: "Locus.dismissedActivityRunIDs") ?? []
        )
        acknowledgedWarningRunIDs = Set(
            defaults.stringArray(forKey: "Locus.acknowledgedWarningRunIDs") ?? []
        )
    }

    func configure(
        backend: BackendService,
        liveAttentionProvider: @escaping () -> [AttentionItem] = { [] },
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.liveAttentionProvider = liveAttentionProvider
        self.toastHandler = toastHandler
    }

    func refreshActivityRuns(announceFailure: Bool = true) async {
        guard let backend else { return }
        do {
            let response: OrchestrationRunsResponse = try await backend.get(
                "/api/runs", query: [URLQueryItem(name: "limit", value: "200")],
                as: OrchestrationRunsResponse.self
            )
            activityRuns = response.runs
            if activityCenterPresented, selectedTab == .activity { markAllActivitySeen() }
            if let attention: AttentionResponse = try? await backend.get(
                "/api/attention", query: [URLQueryItem(name: "limit", value: "500")],
                as: AttentionResponse.self
            ) {
                persistedAttentionItems = attention.items
            }
        } catch where announceFailure {
            toastHandler("Could not load activity: \(error.localizedDescription)")
        } catch {
            // Coordinator refreshes are best-effort. Runtime recovery owns
            // persistent service errors so a hidden app never repeats toasts.
        }
        await refreshFocusedAttention()
    }

    func openActivityCenter(focus: Focus? = nil) {
        self.focus = focus
        focusGeneration = UUID()
        focusedAttention = []
        focusedRun = nil
        focusError = nil
        isRefreshingFocus = false
        let generation = focusGeneration
        // Resolve the opening tab after the fresh inbox projection arrives.
        // Starting on Attention prevents a cold first open from marking
        // ordinary Activity as seen before we know whether blockers exist.
        selectedTab = .attention
        activityCenterPresented = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshActivityRuns()
            guard generation == focusGeneration else { return }
            selectedTab = focus != nil || !attentionItems.isEmpty ? .attention : .activity
            if selectedTab == .activity { markAllActivitySeen() }
        }
    }

    func clearFocus() {
        focus = nil
        focusGeneration = UUID()
        focusedAttention = []
        focusedRun = nil
        focusError = nil
        isRefreshingFocus = false
    }

    private func refreshFocusedAttention() async {
        guard let focus, let backend else { return }
        let generation = focusGeneration
        isRefreshingFocus = true
        defer { if generation == focusGeneration { isRefreshingFocus = false } }
        do {
            let response = try await backend.get(
                "/api/attention", query: [focus.query], as: AttentionResponse.self
            )
            guard generation == focusGeneration else { return }
            focusedAttention = response.items
            focusError = nil
            if case .run(let id) = focus {
                let segment = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
                let run = try await backend.get("/api/runs/\(segment)", as: OrchestrationRun.self)
                guard generation == focusGeneration else { return }
                focusedRun = run
            }
        } catch {
            guard generation == focusGeneration else { return }
            focusError = "Could not refresh this work’s requests. Try Refresh."
        }
    }

    func selectTab(_ tab: Tab) {
        selectedTab = tab
        if tab == .activity { markAllActivitySeen() }
    }

    func toggleActivityCenter() {
        if activityCenterPresented {
            activityCenterPresented = false
        } else {
            openActivityCenter()
        }
    }

    func activityIsUnseen(_ run: OrchestrationRun) -> Bool {
        guard !dismissedActivityRunIDs.contains(run.id) else { return false }
        return (activitySeenUpdates[run.id] ?? -Double.greatestFiniteMagnitude) < run.updatedAt
    }

    func markActivitySeen(_ run: OrchestrationRun) {
        guard activityIsUnseen(run) else { return }
        activitySeenUpdates[run.id] = run.updatedAt
        persistActivityPresentationState()
    }

    func markAllActivitySeen() {
        var changed = false
        for run in displayedActivityRuns where activityIsUnseen(run) {
            activitySeenUpdates[run.id] = run.updatedAt
            changed = true
        }
        if changed { persistActivityPresentationState() }
    }

    func acknowledgeRunWarning(_ runID: String) {
        guard !runID.isEmpty, acknowledgedWarningRunIDs.insert(runID).inserted else { return }
        persistActivityPresentationState()
    }

    func warningIsAcknowledged(_ runID: String?) -> Bool {
        runID.map(acknowledgedWarningRunIDs.contains) ?? false
    }

    func dismissActivityRun(_ run: OrchestrationRun) {
        guard TeamRunState(rawValue: run.state)?.isTerminal == true else { return }
        dismissedActivityRunIDs.insert(run.id)
        persistActivityPresentationState()
    }

    func clearFinishedActivityRuns() {
        let finished = visibleActivityRuns.compactMap { run in
            TeamRunState(rawValue: run.state)?.isTerminal == true ? run.id : nil
        }
        guard !finished.isEmpty else { return }
        dismissedActivityRunIDs.formUnion(finished)
        persistActivityPresentationState()
        toastHandler("Cleared finished activity")
    }

    private func persistActivityPresentationState() {
        guard persistenceEnabled else { return }
        if activitySeenUpdates.count > 1_000 {
            activitySeenUpdates = Dictionary(
                uniqueKeysWithValues: activitySeenUpdates
                    .sorted { $0.value > $1.value }
                    .prefix(1_000)
                    .map { ($0.key, $0.value) }
            )
        }
        if let data = try? JSONEncoder().encode(activitySeenUpdates) {
            defaults.set(data, forKey: "Locus.activitySeenUpdates")
        }
        defaults.set(
            Array(dismissedActivityRunIDs.prefix(1_000)),
            forKey: "Locus.dismissedActivityRunIDs"
        )
        defaults.set(
            Array(acknowledgedWarningRunIDs.prefix(1_000)),
            forKey: "Locus.acknowledgedWarningRunIDs"
        )
    }
}
