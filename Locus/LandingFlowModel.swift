import Foundation

/// Owns the worktree landing flow: the Review & Land sheet's preflight,
/// patch, and check-run state, plus applying and landing the active task.
/// The task record and session identity stay with the composition root and
/// are read and replaced through closures, as are the workspace-profile
/// check commands. AppModel wires it via configure(...) and bridges its
/// publication; it never retains AppModel.
@MainActor
final class LandingFlowModel: ObservableObject {
    @Published var landingPreflight: LandingPreflight?
    @Published private(set) var landingCheckRun: LandingCheckRun?
    @Published var landingPatch = ""
    @Published private(set) var activeLandingCheckRunID: String?
    @Published var isLandingOperationRunning = false
    @Published var reviewAndLandPresented = false
    @Published var taskHasChanges = false
    @Published var taskPatchBytes = 0

    private var backend: BackendService?
    private var isUITesting = false
    private var isBusy: () -> Bool = { false }
    private var hasPendingPermission: () -> Bool = { false }
    private var activeTask: () -> TaskRecord? = { nil }
    private var setActiveTask: (TaskRecord) -> Void = { _ in }
    private var replaceSessionTask: (TaskRecord) -> Void = { _ in }
    private var sourceRunID: () -> String = { "" }
    private var saveCheckCommands: ([String]) -> Void = { _ in }
    private var gitRefresh: () -> Void = {}
    private var toastHandler: (String) -> Void = { _ in }

    func configure(
        backend: BackendService,
        isUITesting: Bool,
        isBusy: @escaping () -> Bool,
        hasPendingPermission: @escaping () -> Bool,
        activeTask: @escaping () -> TaskRecord?,
        setActiveTask: @escaping (TaskRecord) -> Void,
        replaceSessionTask: @escaping (TaskRecord) -> Void,
        sourceRunID: @escaping () -> String,
        saveCheckCommands: @escaping ([String]) -> Void,
        gitRefresh: @escaping () -> Void,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.isUITesting = isUITesting
        self.isBusy = isBusy
        self.hasPendingPermission = hasPendingPermission
        self.activeTask = activeTask
        self.setActiveTask = setActiveTask
        self.replaceSessionTask = replaceSessionTask
        self.sourceRunID = sourceRunID
        self.saveCheckCommands = saveCheckCommands
        self.gitRefresh = gitRefresh
        self.toastHandler = toastHandler
    }

    /// Backend task_* events, routed here by AppModel's dispatcher after it
    /// updates the task record itself.
    func ingest(_ type: String, _ event: [String: Any]) {
        switch type {
        case "task_ready":
            taskHasChanges = false
            taskPatchBytes = 0

        case "task_changes":
            taskHasChanges = event["has_changes"] as? Bool == true
            taskPatchBytes = event["patch_bytes"] as? Int ?? 0

        case "task_applied":
            taskHasChanges = false
            taskPatchBytes = 0

        default:
            break
        }
    }

    func applyActiveTaskToWorkspace() {
        guard let backend else { return }
        guard let task = activeTask() else { return }
        guard !isBusy(), !hasPendingPermission() else {
            toastHandler("Wait for the team run to finish before applying changes")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskApplyResponse = try await backend.post(
                    "/api/tasks/\(task.id)/apply",
                    body: [:],
                    timeout: 120,
                    as: TaskApplyResponse.self
                )
                setActiveTask(response.task)
                taskHasChanges = false
                taskPatchBytes = 0
                gitRefresh()
                toastHandler(response.applied ? "Applied task changes to the workspace" : "No new task changes to apply")
            } catch {
                toastHandler("Workspace left untouched: \(error.localizedDescription)")
            }
        }
    }

    func prepareReviewAndLand() {
        guard let backend else { return }
        guard let task = activeTask(), !isBusy() else { return }
        if isUITesting, landingPreflight != nil {
            reviewAndLandPresented = true
            return
        }
        isLandingOperationRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLandingOperationRunning = false }
            do {
                async let preflight: LandingPreflight = backend.get(
                    "/api/tasks/\(task.id)/landing/preflight", as: LandingPreflight.self
                )
                async let detail: TaskDetailResponse = backend.get(
                    "/api/tasks/\(task.id)", as: TaskDetailResponse.self
                )
                landingPreflight = try await preflight
                let loadedDetail = try await detail
                landingPatch = loadedDetail.patch
                landingCheckRun = nil
                reviewAndLandPresented = true
            } catch {
                toastHandler("Could not review the worktree: \(error.localizedDescription)")
            }
        }
    }

    func refreshLandingReview() async {
        guard let backend else { return }
        guard reviewAndLandPresented, !isLandingOperationRunning,
              let task = activeTask() else { return }
        do {
            async let preflight: LandingPreflight = backend.get(
                "/api/tasks/\(task.id)/landing/preflight", as: LandingPreflight.self
            )
            async let detail: TaskDetailResponse = backend.get(
                "/api/tasks/\(task.id)", as: TaskDetailResponse.self
            )
            let refreshedPreflight = try await preflight
            let refreshedDetail = try await detail
            guard reviewAndLandPresented, activeTask()?.id == task.id else { return }
            landingPreflight = refreshedPreflight
            landingPatch = refreshedDetail.patch
        } catch {
            // The next poll retries. Landing still performs its own atomic,
            // current-tree validation before making any change.
        }
    }

    func runLandingChecks(commands: [String]) {
        guard let backend else { return }
        guard let task = activeTask(), !commands.isEmpty else { return }
        saveCheckCommands(commands)
        isLandingOperationRunning = true
        let runID = UUID().uuidString
        activeLandingCheckRunID = runID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isLandingOperationRunning = false
                activeLandingCheckRunID = nil
            }
            do {
                landingCheckRun = try await backend.post(
                    "/api/tasks/\(task.id)/checks",
                    body: ["commands": commands, "run_id": runID],
                    timeout: 4_900, as: LandingCheckRun.self
                )
                landingPreflight = try await backend.get(
                    "/api/tasks/\(task.id)/landing/preflight", as: LandingPreflight.self
                )
            } catch {
                toastHandler("Checks stopped: \(error.localizedDescription)")
            }
        }
    }

    func stopLandingChecks() {
        guard let backend else { return }
        guard let runID = activeLandingCheckRunID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.post(
                    "/api/runs/\(runID)/cancel", body: [:],
                    as: SimpleActionResponse.self
                )
                toastHandler("Stopping checks")
            } catch {
                toastHandler("Could not stop checks: \(error.localizedDescription)")
            }
        }
    }

    func landActiveTask(
        destination: String, branch: String, commitMessage: String,
        overrideFailedChecks: Bool
    ) {
        guard let backend else { return }
        guard let task = activeTask(), let preflight = landingPreflight else { return }
        isLandingOperationRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLandingOperationRunning = false }
            do {
                let response: TaskLandingResponse = try await backend.post(
                    "/api/tasks/\(task.id)/landing",
                    body: [
                        "destination": destination,
                        "expected_tree": preflight.tree,
                        "check_tree": landingCheckRun?.tree ?? "",
                        "check_run_id": landingCheckRun?.runID ?? "",
                        "checks_passed": landingCheckRun?.passed ?? false,
                        "override_failed_checks": overrideFailedChecks,
                        "branch": branch,
                        "commit_message": commitMessage,
                        "source_run_id": sourceRunID(),
                    ],
                    timeout: 120,
                    as: TaskLandingResponse.self
                )
                setActiveTask(response.task)
                replaceSessionTask(response.task)
                if destination == "local" { reviewAndLandPresented = false }
                gitRefresh()
                if let detail = try? await backend.get(
                    "/api/tasks/\(task.id)", as: TaskDetailResponse.self
                ) {
                    taskHasChanges = detail.patchBytes > 0
                    taskPatchBytes = detail.patchBytes
                }
                toastHandler(destination == "local" ? "Applied changes to Local" : "Created worktree commit")
            } catch {
                toastHandler("Landing stopped safely: \(error.localizedDescription)")
            }
        }
    }
}
