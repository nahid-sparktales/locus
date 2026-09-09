import Combine
import Foundation

/// Workspace-scoped capsule persistence and presentation. Construction and
/// configuration perform no IO; AppModel supplies routing through narrow closures.
@MainActor
final class TaskCapsuleModel: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var capsules: [TaskCapsule] = []
    @Published var selectedID: String?
    @Published var draftTitle = ""
    @Published var draftRequest = ""
    @Published var draftRecipe = TaskCapsuleRecipe()
    @Published var plannerQuestion = ""
    @Published var error: String?
    @Published private(set) var status: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSaving = false
    @Published private(set) var workspaceRoot = ""
    @Published private(set) var activeStageSessions: [String: String] = [:]
    @Published private(set) var editingCapsuleID: String?

    private var backend: BackendService?
    private var workspacePathProvider: () -> String = { "" }
    private var profilesProvider: () -> [AgentProfile] = { [] }
    private var profileLabelProvider: (AgentProfile) -> String = { "\($0.name) · \($0.model)" }
    private var activePlanProvider: () -> PlanDocument? = { nil }
    private var isBusyProvider: () -> Bool = { false }
    private var startPlanning: (TaskCapsulePlanningRequest) -> Void = { _ in }
    private var startExecution: (TaskCapsule) -> Void = { _ in }
    private var resumeExecution: (TaskCapsule, String, Bool) -> Void = { _, _, _ in }
    private var startReview: (TaskCapsule) -> Void = { _ in }
    private var askPlanner: (TaskCapsule, String) -> Void = { _, _ in }
    private var manageProfilesHandler: () -> Void = {}
    private var openConversationHandler: (String) -> Void = { _ in }
    @Published private var pendingPlanning: [String: TaskCapsulePlanningRequest] = [:]
    private var submittedPlans: [String: PlanDocument] = [:]
    var didSavePlan: (TaskCapsule, TaskCapsulePlanningRequest) -> Void = { _, _ in }
    var didFailToSavePlan: (TaskCapsulePlanningRequest) -> Void = { _ in }
    private var refreshGeneration = UUID()
    private var editingRevision: Int?
    private var currentWorkspacePath: String { TaskCapsuleWorkspace.canonicalPath(workspacePathProvider()) }

    static func canonicalWorkspace(_ path: String) -> String { TaskCapsuleWorkspace.canonicalPath(path) }

    struct WaitingPlan: Identifiable {
        var id: String
        var title: String
    }

    var waitingPlans: [WaitingPlan] {
        pendingPlanning.compactMap { sessionID, request in
            guard request.workspaceRoot == currentWorkspacePath, activeStageSessions[sessionID] == nil else { return nil }
            return WaitingPlan(id: sessionID, title: request.title.nilIfEmpty ?? String(request.request.prefix(80)))
        }.sorted { $0.id < $1.id }
    }

    func cancelPlanning(sessionID: String) {
        guard let request = pendingPlanning[sessionID], request.workspaceRoot == currentWorkspacePath,
              activeStageSessions[sessionID] == nil else { return }
        pendingPlanning[sessionID] = nil
        submittedPlans[sessionID] = nil
        status = "Capsule planning cancelled. You can continue the conversation normally."
    }

    func configure(
        backend: BackendService,
        workspacePathProvider: @escaping () -> String,
        profilesProvider: @escaping () -> [AgentProfile],
        profileLabelProvider: @escaping (AgentProfile) -> String = { "\($0.name) · \($0.model)" },
        activePlanProvider: @escaping () -> PlanDocument?,
        isBusyProvider: @escaping () -> Bool,
        startPlanning: @escaping (TaskCapsulePlanningRequest) -> Void,
        startExecution: @escaping (TaskCapsule) -> Void,
        startReview: @escaping (TaskCapsule) -> Void,
        askPlanner: @escaping (TaskCapsule, String) -> Void,
        resumeExecution: @escaping (TaskCapsule, String, Bool) -> Void = { _, _, _ in },
        manageProfiles: @escaping () -> Void = {},
        openConversation: @escaping (String) -> Void = { _ in }
    ) {
        self.backend = backend
        self.workspacePathProvider = workspacePathProvider
        self.profilesProvider = profilesProvider
        self.profileLabelProvider = profileLabelProvider
        self.activePlanProvider = activePlanProvider
        self.isBusyProvider = isBusyProvider
        self.startPlanning = startPlanning
        self.startExecution = startExecution
        self.resumeExecution = resumeExecution
        self.startReview = startReview
        self.askPlanner = askPlanner
        manageProfilesHandler = manageProfiles
        openConversationHandler = openConversation
    }

    var profiles: [AgentProfile] { profilesProvider().filter(\.isConfigured) }
    var implementationProfiles: [AgentProfile] { profiles.filter { $0.accessCeiling.canWrite } }
    var selectedCapsule: TaskCapsule? { capsules.first { $0.id == selectedID } }
    var isEditingRecipe: Bool { editingCapsuleID != nil && editingCapsuleID == selectedID }
    var hasActivePlan: Bool { activePlanProvider().map(Self.hasSteps) ?? false }
    var isBusy: Bool { isBusyProvider() || isSaving || !activeStageSessions.isEmpty }
    /// Share the button's availability with its visible explanation so setup
    /// never leaves a disabled primary action without a next step.
    var planningUnavailableReason: String? {
        if workspaceRoot.isEmpty { return "Open a workspace to save your capsule in." }
        if isBusy { return "Finish the active task before starting a new plan." }
        if let issue = recipeError(draftRecipe) { return issue }
        if draftRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Describe your task above, or choose an example to get started."
        }
        return nil
    }
    var canGenerate: Bool { planningUnavailableReason == nil }
    var canCapturePlan: Bool { hasActivePlan && recipeError(draftRecipe) == nil && !workspaceRoot.isEmpty && !isBusy }
    func profileLabel(_ profile: AgentProfile) -> String { profileLabelProvider(profile) }
    func profileLabel(id: String?) -> String {
        guard let id else { return "No review model" }
        return profiles.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
            .map(profileLabelProvider) ?? "Profile unavailable"
    }

    func open(selecting capsuleID: String? = nil, notice: String? = nil, prefillingRequest: String? = nil) {
        activateWorkspace()
        // Opening from the composer may seed an empty new capsule, but must
        // never replace an unfinished capsule or the currently selected plan.
        if capsuleID == nil, selectedID == nil,
           draftRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let prefillingRequest {
            draftRequest = prefillingRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let capsuleID {
            cancelRecipeEditing()
            selectedID = capsuleID
            plannerQuestion = ""
        }
        if let notice {
            status = notice
            error = nil
        }
        isPresented = true
        Task { await refresh() }
    }

    func manageProfiles() {
        isPresented = false
        manageProfilesHandler()
    }

    func openConversation(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        isPresented = false
        openConversationHandler(sessionID)
    }

    func newCapsule() {
        cancelRecipeEditing()
        selectedID = nil
        draftTitle = ""
        draftRequest = ""
        plannerQuestion = ""
        error = nil
        status = nil
        seedProfiles()
    }

    private func activateWorkspace() {
        let current = currentWorkspacePath
        if current != workspaceRoot {
            workspaceRoot = current
            capsules = []
            refreshGeneration = UUID()
            isRefreshing = false
            newCapsule()
        }
        seedProfiles()
    }

    private func seedProfiles() {
        if draftRecipe.plannerProfileID.isEmpty {
            draftRecipe.plannerProfileID = profiles.first?.id.uuidString ?? ""
        }
        if draftRecipe.executorProfileID.isEmpty {
            draftRecipe.executorProfileID = implementationProfiles.first(where: {
                $0.id.uuidString != draftRecipe.plannerProfileID
            })?.id.uuidString ?? implementationProfiles.first?.id.uuidString ?? ""
        }
    }

    func refresh() async {
        activateWorkspace()
        guard let backend, !workspaceRoot.isEmpty else { return }
        let workspace = workspaceRoot
        let generation = UUID()
        refreshGeneration = generation
        isRefreshing = true
        defer { if refreshGeneration == generation { isRefreshing = false } }
        do {
            let response = try await backend.get(
                "/api/capsules", query: [URLQueryItem(name: "workspace_root", value: workspace)],
                as: TaskCapsulesResponse.self
            )
            guard generation == refreshGeneration, workspace == currentWorkspacePath else { return }
            capsules = response.capsules.filter { $0.workspaceRoot == workspace }
            if let selectedID, !capsules.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            error = nil
            if let selectedID { await loadCapsule(id: selectedID, workspace: workspace) }
        } catch {
            guard generation == refreshGeneration, workspace == currentWorkspacePath else { return }
            self.error = "Could not load capsules: \(error.localizedDescription)"
        }
    }

    func select(_ capsule: TaskCapsule) {
        cancelRecipeEditing()
        selectedID = capsule.id
        plannerQuestion = ""
        error = nil
        Task { await loadCapsule(id: capsule.id, workspace: capsule.workspaceRoot) }
    }

    func beginEditingRecipe() {
        guard !isBusy, let capsule = selectedCapsule else { return }
        draftRecipe = capsule.recipe
        editingRevision = capsule.revision
        editingCapsuleID = capsule.id
        error = nil
    }

    func cancelRecipeEditing() {
        if let capsule = selectedCapsule, editingCapsuleID == capsule.id { draftRecipe = capsule.recipe }
        editingCapsuleID = nil
        editingRevision = nil
    }

    func saveRecipeChanges() async {
        guard let backend, !isBusy, let capsule = selectedCapsule,
              editingCapsuleID == capsule.id, let revision = editingRevision else { return }
        guard capsule.workspaceRoot == currentWorkspacePath else {
            error = "Open this capsule's workspace before changing its model choices."
            return
        }
        if let issue = recipeError(draftRecipe) { error = issue; return }
        isSaving = true
        defer { isSaving = false }
        do {
            let data = try JSONEncoder().encode(draftRecipe)
            let recipe = try JSONSerialization.jsonObject(with: data)
            let response = try await backend.patch("/api/capsules/\(capsule.id)", body: [
                "workspace_root": capsule.workspaceRoot, "expected_revision": revision, "recipe": recipe,
            ], as: TaskCapsuleResponse.self)
            guard capsule.workspaceRoot == currentWorkspacePath, capsule.workspaceRoot == workspaceRoot else { return }
            if let index = capsules.firstIndex(where: { $0.id == capsule.id }) { capsules[index] = response.capsule }
            if editingCapsuleID == capsule.id { cancelRecipeEditing() }
            status = "Model choices and limits saved as revision \(response.capsule.revision)."
            error = nil
        } catch {
            guard capsule.workspaceRoot == currentWorkspacePath else { return }
            self.error = "Could not save the model choices: \(error.localizedDescription). Your saved plan was not changed."
        }
    }

    private func loadCapsule(id: String, workspace: String) async {
        guard let backend, workspace == currentWorkspacePath else { return }
        do {
            let response = try await backend.get("/api/capsules/\(id)",
                query: [URLQueryItem(name: "workspace_root", value: workspace)], as: TaskCapsuleResponse.self)
            guard workspace == workspaceRoot, workspace == currentWorkspacePath,
                  response.capsule.workspaceRoot == workspace else { return }
            if let index = capsules.firstIndex(where: { $0.id == id }) { capsules[index] = response.capsule }
        } catch {
            guard selectedID == id, workspace == currentWorkspacePath else { return }
            self.error = "Could not refresh capsule details: \(error.localizedDescription)"
        }
    }

    func generatePlan() {
        activateWorkspace()
        guard canGenerate else {
            if workspaceRoot.isEmpty { error = "Open a workspace before creating a capsule." }
            else if isBusy { error = "Finish the active task before starting the planner." }
            else { error = recipeError(draftRecipe) ?? "Describe what the task should accomplish." }
            return
        }
        let request = TaskCapsulePlanningRequest(
            title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            request: draftRequest.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceRoot: workspaceRoot, recipe: draftRecipe
        )
        error = nil
        startPlanning(request)
    }

    func captureActivePlan() {
        activateWorkspace()
        guard canCapturePlan, let plan = activePlanProvider() else { return }
        let request = TaskCapsulePlanningRequest(
            title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            request: draftRequest.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? plan.summary.nilIfEmpty ?? plan.steps.joined(separator: "\n").nilIfEmpty ?? plan.title,
            workspaceRoot: workspaceRoot, recipe: draftRecipe
        )
        Task { _ = await savePlan(plan, request: request) }
    }

    /// Bind before sending; events from another conversation cannot become this capsule's plan.
    func planningStarted(_ request: TaskCapsulePlanningRequest, sessionID: String) {
        var normalized = request
        normalized.workspaceRoot = TaskCapsuleWorkspace.canonicalPath(request.workspaceRoot)
        normalized.originSessionID = sessionID
        pendingPlanning[sessionID] = normalized
        submittedPlans[sessionID] = nil
        activeStageSessions[sessionID] = request.capsuleID == nil ? "Planning" : "Planner help"
        status = "Planning with \(profileLabel(id: request.recipe.plannerProfileID))"
    }

    func handlePlan(_ plan: PlanDocument, sessionID: String) {
        guard pendingPlanning[sessionID] != nil else { return }
        submittedPlans[sessionID] = plan
    }

    func pendingPlanningRequest(for sessionID: String) -> TaskCapsulePlanningRequest? {
        pendingPlanning[sessionID]
    }

    /// Receives events before the foreground/background conversation split.
    /// Returns whether the event belongs to a capsule planning conversation.
    @discardableResult
    func handleEvent(_ event: [String: Any], sessionID: String) -> Bool {
        let ownsPlanning = pendingPlanning[sessionID] != nil
        switch event["type"] as? String {
        case "task_verification":
            if let taskID = event["task_id"] as? String, let state = event["state"] as? String,
               let index = capsules.firstIndex(where: {
                   $0.workspaceRoot == currentWorkspacePath && $0.attempts.first.map { taskID.hasPrefix("capsule:" + $0.id + ":") } == true
               }), !capsules[index].attempts.isEmpty {
                capsules[index].attempts[0].verificationStatus = state == "checking" ? "checking" : "pending"
            }
        case "capsule_progress":
            if let id = event["capsule_id"] as? String,
               let index = capsules.firstIndex(where: { $0.id == id && $0.workspaceRoot == currentWorkspacePath }),
               let raw = event["attempt"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let attempt = try? JSONDecoder().decode(CapsuleAttempt.self, from: data) {
                capsules[index].attempts.removeAll { $0.id == attempt.id }
                capsules[index].attempts.insert(attempt, at: 0)
                status = attempt.title
            }
        case "run_started" where ownsPlanning:
            if let runID = event["run_id"] as? String, !runID.isEmpty {
                pendingPlanning[sessionID]?.originRunID = runID
                pendingPlanning[sessionID]?.originSessionID = sessionID
            }
        case "plan_ready" where ownsPlanning:
            if let raw = event["plan"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let plan = try? JSONDecoder().decode(PlanDocument.self, from: data) {
                handlePlan(plan, sessionID: sessionID)
            }
        case "turn_done":
            let succeeded = (event["reason"] as? String ?? "complete") == "complete"
            Task {
                if ownsPlanning { await planningFinished(sessionID: sessionID, succeeded: succeeded) }
                else { await stageFinished(sessionID: sessionID) }
            }
        default: break
        }
        return ownsPlanning
    }

    func planningFinished(sessionID: String, succeeded: Bool) async {
        guard let request = pendingPlanning[sessionID] else { return }
        let plan = submittedPlans.removeValue(forKey: sessionID)
        activeStageSessions[sessionID] = nil
        guard succeeded, let plan, Self.hasSteps(plan) else {
            if !succeeded { pendingPlanning[sessionID] = nil }
            if request.workspaceRoot == currentWorkspacePath {
                status = succeeded ? "Continue in the conversation to finish the capsule plan."
                    : "Planning stopped. No incomplete plan was saved."
            }
            return
        }
        pendingPlanning[sessionID] = nil
        _ = await savePlan(plan, request: request)
    }

    func stageStarted(capsule: TaskCapsule, stage: String, sessionID: String) {
        // An explicitly selected execution/review replaces a waiting planner
        // in this conversation; its events must not finish the older plan.
        pendingPlanning[sessionID] = nil
        submittedPlans[sessionID] = nil
        activeStageSessions[sessionID] = stage
        status = "\(stage.capitalized): \(capsule.title)"
    }

    func stageFinished(sessionID: String) async {
        guard activeStageSessions.removeValue(forKey: sessionID) != nil else { return }
        await refresh()
    }

    @discardableResult
    func savePlan(_ plan: PlanDocument, request: TaskCapsulePlanningRequest) async -> TaskCapsule? {
        guard let backend, Self.hasSteps(plan) else { return nil }
        let workspace = TaskCapsuleWorkspace.canonicalPath(request.workspaceRoot)
        guard !workspace.isEmpty else {
            error = "Open a workspace before saving a capsule."
            return nil
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let capsule = TaskCapsule(
                title: request.title.nilIfEmpty ?? plan.title,
                request: request.request, workspaceRoot: workspace,
                plan: plan, recipe: request.recipe
            )
            let data = try JSONEncoder().encode(capsule)
            guard var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            body.removeValue(forKey: "id")
            body.removeValue(forKey: "revision")
            body.removeValue(forKey: "runs")
            if let runID = request.originRunID { body["origin_run_id"] = runID }
            if let sessionID = request.originSessionID { body["origin_session_id"] = sessionID }
            let response: TaskCapsuleResponse
            if let id = request.capsuleID, let revision = request.expectedRevision {
                body["expected_revision"] = revision
                response = try await backend.patch("/api/capsules/\(id)", body: body, as: TaskCapsuleResponse.self)
            } else {
                response = try await backend.post("/api/capsules", body: body, as: TaskCapsuleResponse.self)
            }
            if workspace == currentWorkspacePath, workspace == workspaceRoot {
                capsules.removeAll { $0.id == response.capsule.id }
                capsules.insert(response.capsule, at: 0)
                selectedID = response.capsule.id
                status = "Plan saved. Ready to run with \(profileLabel(id: response.capsule.recipe.executorProfileID))."
                error = nil
            }
            didSavePlan(response.capsule, request)
            return response.capsule
        } catch {
            didFailToSavePlan(request)
            if workspace == currentWorkspacePath {
                self.error = "Could not save the capsule: \(error.localizedDescription). Your plan remains in the conversation."
            }
            return nil
        }
    }

    func runSelected() {
        guard let capsule = selectedCapsule, validateAction(capsule) else { return }
        startExecution(capsule)
    }

    func resumeSelected(checksOnly: Bool = false) {
        guard let capsule = selectedCapsule, let attempt = capsule.resumableAttempt, attempt.canResume, validateAction(capsule) else { return }
        resumeExecution(capsule, attempt.id, checksOnly)
    }

    func acceptSelectedResult() async {
        guard let backend, let capsule = selectedCapsule, let attempt = capsule.resumableAttempt,
              attempt.state == "needs_review", validateAction(capsule) else { return }
        do {
            let _: TaskCapsuleResponse = try await backend.patch("/api/capsules/\(capsule.id)", body: [
                "workspace_root": capsule.workspaceRoot, "expected_revision": capsule.revision,
                "action": "accept", "attempt_id": attempt.id], as: TaskCapsuleResponse.self)
            await refresh()
        } catch { self.error = "Could not accept result: \(error.localizedDescription)" }
    }

    func recordActionOutcome(_ note: String) async {
        guard let backend, let capsule = selectedCapsule, let attempt = capsule.resumableAttempt,
              let actionID = attempt.uncertainAction?["id"]?.string, validateAction(capsule) else { return }
        do {
            let _: TaskCapsuleResponse = try await backend.patch("/api/capsules/\(capsule.id)", body: [
                "workspace_root": capsule.workspaceRoot, "expected_revision": capsule.revision,
                "action": "resolve_action", "attempt_id": attempt.id, "action_id": actionID, "note": note],
                as: TaskCapsuleResponse.self)
            await refresh()
        } catch { self.error = "Could not record the outcome: \(error.localizedDescription)" }
    }

    func recordUsage(calls: Int, tokens: Int, cost: Double) async {
        guard let backend, let capsule = selectedCapsule, let attempt = capsule.resumableAttempt,
              attempt.pendingUsage != nil, validateAction(capsule) else { return }
        do {
            let _: TaskCapsuleResponse = try await backend.patch("/api/capsules/\(capsule.id)", body: [
                "workspace_root": capsule.workspaceRoot, "expected_revision": capsule.revision,
                "action": "resolve_usage", "attempt_id": attempt.id,
                "usage": ["model_calls": calls, "metered_tokens": tokens, "estimated_cost": cost]],
                as: TaskCapsuleResponse.self)
            await refresh()
        } catch { self.error = "Could not save reviewed usage: \(error.localizedDescription)" }
    }

    func reviewSelected() {
        guard let capsule = selectedCapsule, validateAction(capsule),
              capsule.recipe.reviewerProfileID != nil else { return }
        startReview(capsule)
    }

    func askPlannerForSelected() {
        guard let capsule = selectedCapsule, validateAction(capsule) else { return }
        let question = plannerQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { error = "Describe the blocker for the planner."; return }
        guard capsule.recipe.maxPlannerEscalations > 0 else {
            error = "Planner help is disabled. Use Edit models and limits to allow it."
            return
        }
        guard capsule.plannerHelpRequestsRemaining > 0 else {
            error = "This capsule has used its planner help allowance. Use Edit models and limits to allow another request."
            return
        }
        askPlanner(capsule, question)
    }

    func reportError(_ message: String) { error = message }

    private func validateAction(_ capsule: TaskCapsule) -> Bool {
        guard capsule.workspaceRoot == currentWorkspacePath else {
            error = "Open this capsule's workspace before running it."
            return false
        }
        guard !isBusy else { error = "Finish the active task before starting another capsule stage."; return false }
        guard !isEditingRecipe else { error = "Save or cancel your model changes before starting this stage."; return false }
        if let issue = recipeError(capsule.recipe) { error = issue; return false }
        error = nil
        return true
    }

    func recipeError(_ recipe: TaskCapsuleRecipe) -> String? {
        let available = Set(profiles.map { $0.id.uuidString.lowercased() })
        guard available.contains(recipe.plannerProfileID.lowercased()) else { return "Choose a planning profile. Use Manage agent profiles to create or restore one." }
        guard available.contains(recipe.executorProfileID.lowercased()) else { return "Choose an implementation profile. Use Manage agent profiles to create or restore one." }
        guard implementationProfiles.contains(where: { $0.id.uuidString.caseInsensitiveCompare(recipe.executorProfileID) == .orderedSame }) else {
            return "Choose an implementation profile with workspace write access in Agent Profiles."
        }
        if let reviewer = recipe.reviewerProfileID, !available.contains(reviewer.lowercased()) {
            return "The review profile is unavailable. Restore it in Agent Profiles."
        }
        guard (1...100).contains(recipe.planningCallLimit), (1...100).contains(recipe.executionCallLimit),
              (0...7).contains(recipe.maxRepairAttempts), (0...10).contains(recipe.maxPlannerEscalations) else {
            return "Check the capsule's call and retry limits."
        }
        if let cost = recipe.maximumEstimatedCost, !cost.isFinite || cost <= 0 {
            return "The optional API estimate limit must be greater than zero."
        }
        return nil
    }

    private static func hasSteps(_ plan: PlanDocument) -> Bool {
        !plan.steps.isEmpty || !plan.stepDetails.isEmpty
    }
}
