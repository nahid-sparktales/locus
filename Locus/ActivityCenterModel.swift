import Foundation

/// Owns the Activity Center: the runs list, presentation state, and the
/// per-run seen/dismissed bookkeeping with its pruned persistence. AppModel
/// wires it via configure(...) and bridges its publication; it never retains
/// AppModel.
@MainActor
final class ActivityCenterModel: ObservableObject {
    @Published var activityCenterPresented = false
    @Published var activityRuns: [OrchestrationRun] = []
    @Published private(set) var activitySeenUpdates: [String: Double] = [:]
    @Published private(set) var dismissedActivityRunIDs: Set<String> = []
    @Published private(set) var acknowledgedWarningRunIDs: Set<String> = []

    private var backend: BackendService?
    private var persistenceEnabled = false
    private var defaults: UserDefaults = .standard
    private var toastHandler: (String) -> Void = { _ in }

    var activityNeedsAttentionCount: Int {
        let states = Set(["waiting_permission", "waiting_computer",
                          "waiting_dispatch_approval", "paused", "interrupted", "failed"])
        return visibleActivityRuns.filter {
            states.contains($0.state) && activityIsUnseen($0)
        }.count
    }

    var visibleActivityRuns: [OrchestrationRun] {
        activityRuns.filter { !dismissedActivityRunIDs.contains($0.id) }
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
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
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
            if activityCenterPresented { markAllActivitySeen() }
        } catch where announceFailure {
            toastHandler("Could not load activity: \(error.localizedDescription)")
        } catch {
            // Coordinator refreshes are best-effort. Runtime recovery owns
            // persistent service errors so a hidden app never repeats toasts.
        }
    }

    func openActivityCenter() {
        activityCenterPresented = true
        markAllActivitySeen()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshActivityRuns()
            markAllActivitySeen()
        }
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
        for run in visibleActivityRuns where activityIsUnseen(run) {
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
