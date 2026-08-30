import Foundation

/// Owns orchestration run history: the runs list, the selected run with its
/// merged event timeline, per-run detail caches, and the request de-dup
/// machinery that keeps stale responses from clobbering fresh ones. The live
/// turn's run identity and state stay with the composition root and are read
/// and advanced through closures. AppModel wires it via configure(...) and
/// bridges its publication; it never retains AppModel.
@MainActor
final class OrchestrationRunsModel: ObservableObject {
    @Published var orchestrationRuns: [OrchestrationRun] = []
    @Published var selectedOrchestrationRun: OrchestrationRun?
    @Published var runDetailsByID: [String: OrchestrationRun] = [:]
    @Published var orchestrationEvents: [OrchestrationEvent] = []
    @Published private(set) var isLoadingOrchestrationRuns = false
    var orchestrationEventIDs: Set<String> = []

    private var orchestrationRunsTasks: [String: (generation: Int, task: Task<OrchestrationRunsResponse, Error>)] = [:]
    private var orchestrationDetailTasks: [String: Task<OrchestrationRun, Error>] = [:]
    private var orchestrationEventTasks: [String: Task<OrchestrationEventsResponse, Error>] = [:]
    private var orchestrationRunsGeneration = 0
    private var orchestrationSelectionGeneration = 0
    private var requestedOrchestrationRunID: String?
    private var requestedOrchestrationLoadKey: String?

    private var backend: BackendService?
    private var sessionIDProvider: () -> String = { "" }
    private var transportProvider: (String) -> BackendService? = { _ in nil }
    private var liveRunID: () -> String? = { nil }
    private var liveState: () -> TeamRunState? = { nil }
    private var setLiveState: (TeamRunState?) -> Void = { _ in }
    private var toastHandler: (String) -> Void = { _ in }

    func configure(
        backend: BackendService,
        sessionIDProvider: @escaping () -> String,
        transportProvider: @escaping (String) -> BackendService,
        liveRunID: @escaping () -> String?,
        liveState: @escaping () -> TeamRunState?,
        setLiveState: @escaping (TeamRunState?) -> Void,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.sessionIDProvider = sessionIDProvider
        self.transportProvider = { transportProvider($0) }
        self.liveRunID = liveRunID
        self.liveState = liveState
        self.setLiveState = setLiveState
        self.toastHandler = toastHandler
    }

    func cancelAll() {
        orchestrationRunsTasks.values.forEach { $0.task.cancel() }
        orchestrationDetailTasks.values.forEach { $0.cancel() }
        orchestrationEventTasks.values.forEach { $0.cancel() }
        orchestrationRunsTasks = [:]
        orchestrationDetailTasks = [:]
        orchestrationEventTasks = [:]
    }

    func refreshOrchestrationRuns(
        select runID: String? = nil,
        terminal: Bool = false
    ) async {
        guard let backend else { return }
        let sessionID = sessionIDProvider()
        let requestKey = [sessionID, terminal ? "terminal:\(runID ?? "")" : "routine"]
            .joined(separator: "|")
        let request: (generation: Int, task: Task<OrchestrationRunsResponse, Error>)
        if let existing = orchestrationRunsTasks[requestKey] {
            request = existing
        } else {
            orchestrationRunsGeneration += 1
            let generation = orchestrationRunsGeneration
            isLoadingOrchestrationRuns = true
            let query = sessionID.isEmpty
                ? []
                : [URLQueryItem(name: "session_id", value: sessionID)]
            let task = Task { [backend] in
                try await backend.get(
                    "/api/orchestrations",
                    query: query,
                    as: OrchestrationRunsResponse.self
                )
            }
            request = (generation, task)
            orchestrationRunsTasks[requestKey] = request
        }
        do {
            let response = try await request.task.value
            if orchestrationRunsTasks[requestKey]?.generation == request.generation {
                orchestrationRunsTasks.removeValue(forKey: requestKey)
            }
            guard request.generation == orchestrationRunsGeneration,
                  sessionIDProvider() == sessionID
            else { return }
            isLoadingOrchestrationRuns = false
            if orchestrationRuns != response.runs {
                orchestrationRuns = response.runs
            }
            let selectedInCurrentSession = selectedOrchestrationRun.flatMap { selected in
                selected.sessionID == nil || selected.sessionID == sessionID ? selected.id : nil
            }
            let selectedID = runID ?? liveRunID()
                ?? selectedInCurrentSession ?? response.runs.first?.id
            if let selectedID {
                await loadOrchestrationRun(selectedID, terminal: terminal)
            } else if selectedOrchestrationRun?.sessionID != sessionID {
                selectedOrchestrationRun = nil
                orchestrationEvents = []
                orchestrationEventIDs = []
            }
        } catch {
            if orchestrationRunsTasks[requestKey]?.generation == request.generation {
                orchestrationRunsTasks.removeValue(forKey: requestKey)
            }
            guard !Task.isCancelled, request.generation == orchestrationRunsGeneration else { return }
            isLoadingOrchestrationRuns = false
            toastHandler("Could not load runs: \(error.localizedDescription)")
        }
    }

    func loadOrchestrationRun(_ runID: String, terminal: Bool = false) async {
        guard backend != nil else { return }
        let sameRun = selectedOrchestrationRun?.id == runID
        // Sequences are numbered per run, and the array can hold a second,
        // still-executing run's events: a watermark taken across both would
        // skip this run's tail whenever the other run had counted further.
        let afterSequence = sameRun
            ? orchestrationEvents(for: runID).map(\.sequence).max() ?? 0 : 0
        guard let transport = transportProvider(runID) else { return }
        let transportKey = transport.currentBaseURL.absoluteString
        let loadKey = "\(transportKey)|\(runID)|\(afterSequence)|\(terminal ? "terminal" : "routine")"
        let generation: Int
        if requestedOrchestrationLoadKey == loadKey {
            generation = orchestrationSelectionGeneration
        } else {
            orchestrationSelectionGeneration += 1
            generation = orchestrationSelectionGeneration
            requestedOrchestrationLoadKey = loadKey
            requestedOrchestrationRunID = runID
        }
        let detailKey = "\(transportKey)|\(runID)|\(terminal ? "terminal" : "routine")"
        let eventsKey = "\(transportKey)|\(runID)|\(afterSequence)|\(terminal ? "terminal" : "routine")"
        let detailTask = orchestrationDetailTask(
            runID: runID, key: detailKey, transport: transport
        )
        let eventsTask = orchestrationEventsTask(
            runID: runID,
            afterSequence: afterSequence,
            key: eventsKey,
            transport: transport
        )
        do {
            let detail = try await detailTask.value
            let response = try await eventsTask.value
            if orchestrationDetailTasks[detailKey] != nil {
                orchestrationDetailTasks.removeValue(forKey: detailKey)
            }
            if orchestrationEventTasks[eventsKey] != nil {
                orchestrationEventTasks.removeValue(forKey: eventsKey)
            }
            guard generation == orchestrationSelectionGeneration,
                  requestedOrchestrationRunID == runID
            else { return }
            let base = sameRun ? orchestrationEvents : []
            let merged = Self.mergeOrchestrationEvents(base, with: response.events)
            if selectedOrchestrationRun != detail {
                selectedOrchestrationRun = detail
            }
            runDetailsByID[runID] = detail
            if orchestrationEvents != merged {
                orchestrationEvents = merged
            }
            orchestrationEventIDs = Set(merged.map(\.id))
            if liveRunID() == runID,
               liveState() == nil,
               let state = TeamRunState(rawValue: detail.state),
               liveState() != state
            {
                setLiveState(state)
            }
        } catch {
            orchestrationDetailTasks.removeValue(forKey: detailKey)
            orchestrationEventTasks.removeValue(forKey: eventsKey)
            guard !Task.isCancelled, generation == orchestrationSelectionGeneration else { return }
            toastHandler("Could not inspect that run: \(error.localizedDescription)")
        }
    }

    func backfillOrchestrationEvents(_ runID: String) async {
        guard backend != nil else { return }
        // Strict on the stamp, unlike the selected-run reads: this can run for
        // the live run while a different run's unstamped events fill the array,
        // and counting those would inflate the watermark past unseen events.
        let after = orchestrationEvents
            .filter { $0.runID == runID }
            .map(\.sequence)
            .max() ?? 0
        guard let transport = transportProvider(runID) else { return }
        let key = "\(transport.currentBaseURL.absoluteString)|\(runID)|\(after)|routine"
        let task = orchestrationEventsTask(
            runID: runID, afterSequence: after, key: key, transport: transport
        )
        do {
            let response = try await task.value
            orchestrationEventTasks.removeValue(forKey: key)
            guard selectedOrchestrationRun?.id == runID || liveRunID() == runID else { return }
            let merged = Self.mergeOrchestrationEvents(orchestrationEvents, with: response.events)
            if merged != orchestrationEvents {
                orchestrationEvents = merged
                orchestrationEventIDs = Set(merged.map(\.id))
            }
        } catch {
            orchestrationEventTasks.removeValue(forKey: key)
            // The inspector can still reload the full run on demand. A failed
            // reconnect backfill must not disturb the active transcript.
        }
    }

    /// Events attributable to one run, read out of the shared array.
    ///
    /// `handle(_:)` deliberately appends for both the selected run and the one
    /// currently executing, so while a historical run is open during a live
    /// turn the array interleaves two runs — folding it whole credited the
    /// live run's files, steps, and model to whichever run was on screen.
    /// Every per-run fact must read through this filter. An event without a
    /// `run_id` stamp can only have arrived via the per-run fetch for the
    /// selected run (live appends are admitted by their stamp), so it counts
    /// as the requested run's rather than being dropped.
    func orchestrationEvents(for runID: String) -> [OrchestrationEvent] {
        Self.runScopedEvents(orchestrationEvents, runID: runID)
    }

    nonisolated static func runScopedEvents(
        _ events: [OrchestrationEvent],
        runID: String
    ) -> [OrchestrationEvent] {
        events.filter { $0.runID == nil || $0.runID == runID }
    }

    nonisolated static func mergeOrchestrationEvents(
        _ existing: [OrchestrationEvent],
        with incoming: [OrchestrationEvent]
    ) -> [OrchestrationEvent] {
        var byID: [String: OrchestrationEvent] = [:]
        for event in existing where !event.isTransientStream { byID[event.id] = event }
        for event in incoming where !event.isTransientStream { byID[event.id] = event }
        return byID.values.sorted {
            $0.sequence == $1.sequence ? $0.id < $1.id : $0.sequence < $1.sequence
        }
    }

    nonisolated static func orchestrationPickerRuns(
        _ runs: [OrchestrationRun],
        selected: OrchestrationRun?
    ) -> [OrchestrationRun] {
        guard let selected,
              !runs.contains(where: { $0.id == selected.id })
        else { return runs }
        return [selected] + runs
    }

    private func orchestrationDetailTask(
        runID: String,
        key: String,
        transport: BackendService
    ) -> Task<OrchestrationRun, Error> {
        if let existing = orchestrationDetailTasks[key] { return existing }
        let task = Task {
            try await transport.get(
                "/api/orchestrations/\(runID)", as: OrchestrationRun.self
            )
        }
        orchestrationDetailTasks[key] = task
        return task
    }

    private func orchestrationEventsTask(
        runID: String,
        afterSequence: Int,
        key: String,
        transport: BackendService
    ) -> Task<OrchestrationEventsResponse, Error> {
        if let existing = orchestrationEventTasks[key] { return existing }
        let task = Task {
            try await transport.get(
                "/api/orchestrations/\(runID)/events",
                query: [URLQueryItem(name: "after_seq", value: String(afterSequence))],
                as: OrchestrationEventsResponse.self
            )
        }
        orchestrationEventTasks[key] = task
        return task
    }
}
