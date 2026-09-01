import Foundation

/// Owns scheduled tasks: the list, editor draft, refresh/save flags, the
/// 30-second coordinator loop, and dispatching due schedules. Validation and
/// editor prefill read cross-feature state, so they stay on the composition
/// root and arrive here as closures — as does the hop that admits a freshly
/// queued run into the chat runtime. AppModel wires it via configure(...)
/// and bridges its publication; it never retains AppModel.
@MainActor
final class ScheduleModel: ObservableObject {
    @Published private(set) var scheduledTasks: [ScheduledTask] = []
    @Published var scheduleEditorDraft: ScheduleEditorDraft?
    @Published private(set) var isSavingSchedule = false
    @Published private(set) var isRefreshingSchedules = false
    @Published private(set) var occurrencesBySchedule: [String: [ScheduleOccurrence]] = [:]

    private var scheduleCoordinatorTask: Task<Void, Never>?
    private var isDispatchingSchedules = false

    private var backend: BackendService?
    private var persistenceEnabled = false
    private var isShuttingDown: () -> Bool = { false }
    private var draftIssue: (ScheduleEditorDraft) -> String? = { _ in nil }
    private var taskIssue: (ScheduledTask) -> String? = { _ in nil }
    private var refreshMetadata: () async -> Void = {}
    private var refreshActivity: () async -> Void = {}
    private var restoreQueuedRuns: () -> Void = {}
    private var admitQueuedRun: (OrchestrationRun) async -> Void = { _ in }
    private var openRun: (OrchestrationRun) -> Void = { _ in }
    private var notifyPaused: (String) -> Void = { _ in }
    private var toastHandler: (String) -> Void = { _ in }

    var nextScheduledTask: ScheduledTask? {
        scheduledTasks
            .filter { $0.enabled && $0.nextRunAt != nil }
            .min { ($0.nextRunAt ?? .greatestFiniteMagnitude) < ($1.nextRunAt ?? .greatestFiniteMagnitude) }
    }

    func configure(
        backend: BackendService,
        persistenceEnabled: Bool,
        isShuttingDown: @escaping () -> Bool,
        draftIssue: @escaping (ScheduleEditorDraft) -> String?,
        taskIssue: @escaping (ScheduledTask) -> String?,
        refreshMetadata: @escaping () async -> Void,
        refreshActivity: @escaping () async -> Void,
        restoreQueuedRuns: @escaping () -> Void,
        admitQueuedRun: @escaping (OrchestrationRun) async -> Void,
        openRun: @escaping (OrchestrationRun) -> Void,
        notifyPaused: @escaping (String) -> Void,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.persistenceEnabled = persistenceEnabled
        self.isShuttingDown = isShuttingDown
        self.draftIssue = draftIssue
        self.taskIssue = taskIssue
        self.refreshMetadata = refreshMetadata
        self.refreshActivity = refreshActivity
        self.restoreQueuedRuns = restoreQueuedRuns
        self.admitQueuedRun = admitQueuedRun
        self.openRun = openRun
        self.notifyPaused = notifyPaused
        self.toastHandler = toastHandler
    }

    func cancelAll() {
        scheduleCoordinatorTask?.cancel()
        scheduleCoordinatorTask = nil
    }

    func refreshScheduledTasks(announceFailure: Bool = true) async {
        guard let backend else { return }
        guard !isRefreshingSchedules else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }
        do {
            let response: SchedulesResponse = try await backend.get(
                "/api/schedules", as: SchedulesResponse.self
            )
            scheduledTasks = response.schedules
        } catch {
            if announceFailure {
                toastHandler("Could not load schedules: \(error.localizedDescription)")
            }
        }
    }

    func saveSchedule(_ draft: ScheduleEditorDraft) async -> Bool {
        guard let backend else { return false }
        guard let rule = encodedJSONObject(draft.rule()) else {
            toastHandler("The schedule rule could not be saved")
            return false
        }
        if let issue = draftIssue(draft) {
            toastHandler(issue)
            return false
        }
        var body: [String: Any] = [
            "name": draft.name,
            "prompt": draft.prompt,
            "workspace_root": draft.workspaceRoot,
            "mode": draft.mode.rawValue,
            "execution_environment": draft.executionEnvironment.rawValue,
            "runner": draft.runner.rawValue,
            "provider": draft.provider,
            "model": draft.model,
            "timezone": draft.timezone,
            "rule": rule,
        ]
        if draft.runner == .team {
            body["team_id"] = draft.teamID ?? ""
            body["team_name"] = draft.teamName
        }
        if draft.provider != "ollama" {
            body["provider_account_id"] = draft.providerAccountID ?? ""
        }
        if draft.id == nil { body["enabled"] = true }
        isSavingSchedule = true
        defer { isSavingSchedule = false }
        do {
            let saved: ScheduledTask
            if let id = draft.id {
                saved = try await backend.patch(
                    "/api/schedules/\(id)", body: body, as: ScheduledTask.self
                )
            } else {
                saved = try await backend.post(
                    "/api/schedules", body: body, as: ScheduledTask.self
                )
            }
            scheduledTasks.removeAll { $0.id == saved.id }
            scheduledTasks.append(saved)
            scheduledTasks.sort {
                ($0.nextRunAt ?? .greatestFiniteMagnitude) < ($1.nextRunAt ?? .greatestFiniteMagnitude)
            }
            scheduleEditorDraft = nil
            toastHandler(draft.id == nil ? "Schedule created" : "Schedule updated")
            return true
        } catch {
            toastHandler("Could not save schedule: \(error.localizedDescription)")
            return false
        }
    }

    func setScheduleEnabled(_ task: ScheduledTask, enabled: Bool) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated: ScheduledTask = try await backend.patch(
                    "/api/schedules/\(task.id)", body: ["enabled": enabled],
                    as: ScheduledTask.self
                )
                replaceScheduledTask(updated)
                toastHandler(enabled ? "Schedule resumed" : "Schedule paused")
            } catch {
                toastHandler("Could not update schedule: \(error.localizedDescription)")
            }
        }
    }

    func deleteSchedule(_ task: ScheduledTask) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: DeleteScheduleResponse = try await backend.delete(
                    "/api/schedules/\(task.id)", as: DeleteScheduleResponse.self
                )
                scheduledTasks.removeAll { $0.id == task.id }
                toastHandler("Schedule deleted; its chats were kept")
            } catch {
                toastHandler("Could not delete schedule: \(error.localizedDescription)")
            }
        }
    }

    func runScheduleNow(_ task: ScheduledTask) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await dispatchSchedule(
                task, trigger: "manual", requestID: UUID().uuidString,
                announceFailure: true
            )
        }
    }

    func refreshOccurrences(for task: ScheduledTask) async {
        guard let backend else { return }
        do {
            let response: ScheduleOccurrencesResponse = try await backend.get(
                "/api/schedules/\(task.id)/occurrences",
                query: [URLQueryItem(name: "limit", value: "100")],
                as: ScheduleOccurrencesResponse.self
            )
            occurrencesBySchedule[task.id] = response.occurrences
        } catch {
            toastHandler("Could not load time-trigger history: \(error.localizedDescription)")
        }
    }

    func openLatestRun(for task: ScheduledTask) {
        guard let backend, let runID = task.lastRunID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let run: OrchestrationRun = try await backend.get(
                    "/api/runs/\(runID)", as: OrchestrationRun.self
                )
                await refreshMetadata()
                openRun(run)
            } catch {
                toastHandler("That scheduled result is no longer available")
            }
        }
    }

    func startScheduleCoordinator() {
        guard persistenceEnabled, scheduleCoordinatorTask == nil else { return }
        scheduleCoordinatorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await self.processDueSchedules()
            }
        }
    }

    func processDueSchedules(now: Date = Date()) async {
        guard persistenceEnabled, !isDispatchingSchedules, !isShuttingDown() else { return }
        isDispatchingSchedules = true
        defer { isDispatchingSchedules = false }
        await refreshScheduledTasks(announceFailure: false)
        let due = scheduledTasks
            .filter { $0.enabled && ($0.nextRunAt ?? .greatestFiniteMagnitude) <= now.timeIntervalSince1970 }
            .sorted { ($0.nextRunAt ?? 0) < ($1.nextRunAt ?? 0) }
        for task in due {
            if let issue = taskIssue(task) {
                await pauseScheduledTask(task, reason: issue)
                continue
            }
            await dispatchSchedule(task, trigger: "due", requestID: "", announceFailure: false)
        }
        await refreshScheduledTasks(announceFailure: false)
        await refreshActivity()
        restoreQueuedRuns()
    }

    func dispatchSchedule(
        _ task: ScheduledTask, trigger: String, requestID: String,
        announceFailure: Bool
    ) async {
        guard let backend else { return }
        if let issue = taskIssue(task) {
            await pauseScheduledTask(task, reason: issue)
            if announceFailure { toastHandler(issue) }
            return
        }
        do {
            let response: ScheduleDispatchResponse = try await backend.post(
                "/api/schedules/\(task.id)/dispatch",
                body: ["trigger": trigger, "request_id": requestID],
                timeout: 30,
                as: ScheduleDispatchResponse.self
            )
            if let schedule = response.schedule { replaceScheduledTask(schedule) }
            await refreshMetadata()
            await refreshActivity()
            if response.run.state == "queued" {
                await admitQueuedRun(response.run)
            }
            if announceFailure {
                toastHandler(response.claimed ? "Scheduled task queued" : "That run is already queued")
            }
        } catch {
            if announceFailure {
                toastHandler("Could not run schedule: \(error.localizedDescription)")
            }
        }
    }

    private func pauseScheduledTask(_ task: ScheduledTask, reason: String) async {
        guard let backend else { return }
        do {
            let updated: ScheduledTask = try await backend.post(
                "/api/schedules/\(task.id)/pause", body: ["reason": reason],
                as: ScheduledTask.self
            )
            replaceScheduledTask(updated)
            notifyPaused("\(task.name) was paused: \(reason)")
        } catch {
            // Keep the due item in memory so a later refresh can retry the
            // durable pause after a temporary service outage.
        }
    }

    func replaceScheduledTask(_ task: ScheduledTask) {
        if let index = scheduledTasks.firstIndex(where: { $0.id == task.id }) {
            scheduledTasks[index] = task
        } else {
            scheduledTasks.append(task)
        }
    }
}
