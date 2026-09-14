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
        case inbox = "Inbox"
        case inProgress = "In progress"
        case read = "Read"
        var id: String { rawValue }
    }

    @Published var activityCenterPresented = false
    @Published var selectedTab: Tab = .inbox
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshError: String?
    @Published private(set) var hasLoadedActivity = false
    @Published private(set) var focus: Focus?
    @Published private(set) var focusedAttention: [AttentionItem] = []
    @Published private(set) var focusError: String?
    @Published private(set) var isRefreshingFocus = false
    @Published private(set) var focusedRun: OrchestrationRun?
    private var focusGeneration = UUID()
    private var refreshCount = 0
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
    private var observedCompletionRunIDs: Set<String> = []

    var activityNeedsAttentionCount: Int {
        attentionItems.count
    }

    var unreadResultCount: Int {
        let requestRunIDs = Set(attentionItems.compactMap(\.runID))
        return visibleActivityRuns.filter {
            isFinished($0) && activityIsUnseen($0) && !requestRunIDs.contains($0.id)
        }.count
    }

    var attentionItems: [AttentionItem] {
        Self.mergedAttention(liveAttentionProvider() + persistedAttentionItems)
    }

    private static func mergedAttention(_ items: [AttentionItem]) -> [AttentionItem] {
        func priority(_ item: AttentionItem) -> Int {
            switch item.kind {
            case "permission_request", "structured_question", "completed_question",
                 "computer_control", "team_plan", "workflow_approval": 0
            case "workflow_failure": 1
            case "recoverable_run": 2
            case "schedule_warning", "event_warning": 3
            default: 4
            }
        }
        var combined: [String: AttentionItem] = [:]
        for item in items {
            let key = item.runID.map { "run:\($0)" } ?? item.id
            // Keep live questions on ties, but replace a synthetic run recovery
            // with the workflow's actual decision and supported recovery actions.
            if let existing = combined[key], priority(existing) <= priority(item) { continue }
            combined[key] = item
        }
        let groupOrder: [AttentionGroup: Int] = [
            .decisions: 0, .recoveries: 1, .configuration: 2,
        ]
        return combined.values.sorted {
            (groupOrder[$0.group, default: 3], $0.timestamp, $0.id)
                < (groupOrder[$1.group, default: 3], $1.timestamp, $1.id)
        }
    }

    var visibleActivityRuns: [OrchestrationRun] {
        activityRuns.filter { !dismissedActivityRunIDs.contains($0.id) }
    }

    var displayedAttentionItems: [AttentionItem] {
        guard let focus else { return attentionItems }
        return Self.mergedAttention((attentionItems + focusedAttention).filter { focus.includes($0) })
    }

    var displayedActivityRuns: [OrchestrationRun] {
        guard let focus else { return visibleActivityRuns }
        var seen: Set<String> = []
        return (visibleActivityRuns + (focusedRun.map { [$0] } ?? [])).filter {
            focus.includes($0) && !dismissedActivityRunIDs.contains($0.id)
                && seen.insert($0.id).inserted
        }
    }

    /// Requests stay in the inbox until resolved, independently of read status.
    var inboxRuns: [OrchestrationRun] {
        let requestRunIDs = Set(displayedAttentionItems.compactMap(\.runID))
        return displayedActivityRuns.filter {
            isFinished($0) && activityIsUnseen($0) && !requestRunIDs.contains($0.id)
        }
    }

    var inProgressRuns: [OrchestrationRun] {
        displayedActivityRuns.filter { !isFinished($0) }
    }

    var readRuns: [OrchestrationRun] {
        displayedActivityRuns.filter { isFinished($0) && !activityIsUnseen($0) }
    }

    var inboxCount: Int { displayedAttentionItems.count + inboxRuns.count }

    func isFinished(_ run: OrchestrationRun) -> Bool {
        TeamRunState(rawValue: run.state)?.isTerminal == true
    }

    /// A saved agent's name takes precedence over the schedule/event name
    /// stored on its chat. Ordinary team work uses the recorded team name.
    static func agentName(
        for run: OrchestrationRun,
        session: SessionSummary?,
        profiles: [AgentProfile]
    ) -> String? {
        if run.runKind == "team", let name = run.teamName?.nilIfEmpty {
            return name
        }
        let profileID = session?.savedAgentProfileID
            ?? run.manifest?["agent_profile_id"]?.string.flatMap(UUID.init(uuidString:))
        if let profileID, let profile = profiles.first(where: { $0.id == profileID }) {
            return profile.name.nilIfEmpty
        }
        return run.manifest?["agent_name"]?.string?.nilIfEmpty
            ?? session?.agentName?.nilIfEmpty
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
        refreshCount += 1
        isRefreshing = true
        defer {
            refreshCount -= 1
            isRefreshing = refreshCount > 0
        }
        do {
            let response: OrchestrationRunsResponse = try await backend.get(
                "/api/runs", query: [URLQueryItem(name: "limit", value: "200")],
                as: OrchestrationRunsResponse.self
            )
            activityRuns = response.runs
            hasLoadedActivity = true
            let attention: AttentionResponse = try await backend.get(
                "/api/attention", query: [URLQueryItem(name: "limit", value: "500")],
                as: AttentionResponse.self
            )
            persistedAttentionItems = attention.items
            refreshError = nil
        } catch {
            refreshError = "Couldn’t refresh activity. Showing the last available updates."
            if announceFailure { toastHandler("Could not load activity: \(error.localizedDescription)") }
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
        selectedTab = .inbox
        activityCenterPresented = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshActivityRuns(announceFailure: false)
            guard generation == focusGeneration, selectedTab == .inbox else { return }
            // A deep link must reveal the selected work even if it was already read.
            if focus != nil, displayedAttentionItems.isEmpty, inboxRuns.isEmpty {
                selectedTab = !inProgressRuns.isEmpty ? .inProgress : !readRuns.isEmpty ? .read : .inbox
            } else {
                selectedTab = .inbox
            }
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
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let segment = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
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
        for run in inboxRuns {
            activitySeenUpdates[run.id] = run.updatedAt
            changed = true
        }
        if changed { persistActivityPresentationState() }
    }

    func markActivityUnread(_ run: OrchestrationRun) {
        guard isFinished(run) else { return }
        activitySeenUpdates.removeValue(forKey: run.id)
        dismissedActivityRunIDs.remove(run.id)
        persistActivityPresentationState()
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

    /// Called at the live completion boundary, before its runtime becomes
    /// idle. History reads never call this: opening an old result is not
    /// evidence that the person saw it finish. The first observation also
    /// prevents a replay from reclassifying a background result as viewed.
    func recordCompletion(runID: String, succeeded: Bool, wasRunning: Bool, isViewed: Bool) {
        guard !runID.isEmpty, succeeded, observedCompletionRunIDs.insert(runID).inserted else { return }
        guard wasRunning, isViewed, !activityCenterPresented else { return }
        dismissedActivityRunIDs.insert(runID)
        persistActivityPresentationState()
    }

    /// Only clears results that are still read at the time of the action.
    /// A search can supply its matching IDs; focus is already applied by readRuns.
    /// Chats, run records, and unresolved attention requests are kept intact.
    func clearReadActivityRuns(matching runIDs: Set<String>? = nil) {
        let cleared = readRuns.filter { runIDs?.contains($0.id) ?? true }.map(\.id)
        guard !cleared.isEmpty else { return }
        dismissedActivityRunIDs.formUnion(cleared)
        persistActivityPresentationState()
        toastHandler("Cleared \(cleared.count) read \(cleared.count == 1 ? "update" : "updates")")
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
