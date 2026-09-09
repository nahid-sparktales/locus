import Combine
import Foundation

enum DuoPhase: String, Codable {
    case planning, saving, ready, executing, paused, completed
}

/// Routes contain account identifiers, never credentials. The saved pair is
/// independent of the ordinary model picker and of later default-pair edits.
struct DuoTask: Codable {
    var sessionID: String
    var workspaceRoot: String
    var planner: AgentProfile
    var executor: AgentProfile
    var phase: DuoPhase = .planning
    var request: TaskCapsulePlanningRequest
    var capsule: TaskCapsule?
    var submittedPlan: PlanDocument?
    var handoffID = UUID().uuidString
    var activeRunID: String?
    var error: String?
}

@MainActor
final class DuoModel: ObservableObject {
    struct Saved: Codable {
        var planner: AgentProfile?
        var executor: AgentProfile?
        var tasks: [String: DuoTask] = [:]
        // Keep routes available to capsules from earlier Duo tasks as well.
        var profiles: [AgentProfile] = []
    }

    @Published private(set) var saved: Saved
    private let defaults: UserDefaults?
    private static let key = "locus.duo.v1"

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        // Reopening restores a decision, never an automatic model call.
        for id in Array(saved.tasks.keys) where saved.tasks[id]?.phase == .executing {
            saved.tasks[id]?.phase = .paused
        }
    }

    func task(sessionID: String, workspace: String) -> DuoTask? {
        guard let task = saved.tasks[sessionID],
              task.workspaceRoot == TaskCapsuleWorkspace.canonicalPath(workspace) else { return nil }
        return task
    }

    func setChoice(_ profile: AgentProfile, planner: Bool) {
        if planner { saved.planner = profile } else { saved.executor = profile }
        remember(profile)
        persist()
    }

    func put(_ task: DuoTask) {
        saved.tasks[task.sessionID] = task
        remember(task.planner)
        remember(task.executor)
        persist()
    }

    func remove(sessionID: String) {
        saved.tasks[sessionID] = nil
        persist()
    }

    private func remember(_ profile: AgentProfile) {
        if !saved.profiles.contains(where: { $0.id == profile.id }) { saved.profiles.append(profile) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults?.set(data, forKey: Self.key) }
    }

    func planSaved(_ capsule: TaskCapsule, request: TaskCapsulePlanningRequest) {
        guard let id = request.originSessionID, var task = saved.tasks[id],
              task.phase == .planning || task.phase == .saving,
              task.workspaceRoot == capsule.workspaceRoot,
              task.request.originRunID == request.originRunID,
              task.request.recipe == request.recipe else { return }
        task.capsule = capsule
        task.submittedPlan = nil
        task.phase = .ready
        task.handoffID = UUID().uuidString
        task.activeRunID = nil
        task.error = nil
        put(task)
    }

    func handleEvent(_ event: [String: Any], sessionID: String) {
        guard var task = saved.tasks[sessionID] else { return }
        let type = event["type"] as? String
        if let runID = event["run_id"] as? String,
           type != "run_started", type != "capsule_stage",
           let active = task.activeRunID, runID != active { return }
        switch type {
        case "run_started", "capsule_stage":
            guard task.phase == .planning || task.phase == .executing else { return }
            task.activeRunID = event["run_id"] as? String ?? task.activeRunID
            if task.phase == .planning { task.request.originRunID = task.activeRunID }
        case "plan_ready" where task.phase == .planning:
            if let raw = event["plan"], let data = try? JSONSerialization.data(withJSONObject: raw),
               let plan = try? JSONDecoder().decode(PlanDocument.self, from: data) {
                task.submittedPlan = plan
            }
        case "capsule_progress":
            guard event["capsule_id"] as? String == task.capsule?.id,
                  let raw = event["attempt"], let data = try? JSONSerialization.data(withJSONObject: raw),
                  let attempt = try? JSONDecoder().decode(CapsuleAttempt.self, from: data) else { return }
            task.capsule?.attempts.removeAll { $0.id == attempt.id }
            task.capsule?.attempts.insert(attempt, at: 0)
            task.phase = attempt.state == "completed" ? .completed : attempt.state == "running" ? .executing : .paused
        case "error" where task.phase == .planning || task.phase == .executing:
            task.error = event["message"] as? String
        case "turn_done":
            if task.phase == .planning, task.submittedPlan != nil,
               (event["reason"] as? String ?? "complete") == "complete" {
                task.phase = .saving
            } else if task.phase == .executing {
                task.phase = .paused
            }
        default: return
        }
        put(task)
    }
}

extension AppModel {
    var duoTask: DuoTask? { duo.task(sessionID: currentSessionID, workspace: workspacePath) }
    var capsuleProfiles: [AgentProfile] { agentProfiles + duo.saved.profiles }

    func selectDuoModel(account: ProviderAccount?, model: String, planner: Bool) {
        let subscription = account == nil || account?.kind == .chatGPT || account?.kind == .kimiCode
        let profile = AgentProfile(name: planner ? "Duo planner" : "Duo builder",
            route: account.map { .providerAccount($0.id) } ?? .localOllama, model: model,
            role: planner ? .planner : .implementer,
            accessCeiling: planner ? .readOnly : .workspaceWrite,
            metering: subscription ? .selfHosted : .metered)
        duo.setChoice(profile, planner: planner)
    }

    func duoLabel(_ profile: AgentProfile?) -> String {
        guard let profile else { return "Choose model" }
        let account = Self.capsuleAccount(profile: profile, accounts: providerAccounts)
        return "\(profile.model) · \(account?.displayName ?? (profile.route == .localOllama ? "Ollama" : "Unavailable account"))"
    }

    /// All Duo messages leave this method with an explicit, temporary route.
    /// The backend continues to receive its existing plan/work modes.
    func sendDuo(_ text: String, includeAttachments: Bool) {
        guard !isIdentityTask, !currentSessionID.isEmpty, isAgentOnline,
              !isBusy, !hasPendingPermission else {
            showToast("Open an idle, connected regular task to use Duo")
            return
        }
        guard goals.goal(for: currentSessionID)?.status != .active else {
            showToast("Pause the current goal before using Duo")
            return
        }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { showToast("Describe what you want Duo to build"); return }
        taskCapsules.error = nil
        if var task = duoTask {
            switch task.phase {
            case .ready:
                reviseDuo(feedback: prompt)
            case .saving:
                showToast("Save the finished plan before continuing")
            case .paused, .executing:
                showToast("Resume the build or ask the planner for help before continuing")
            case .planning:
                guard let dispatch = capsulePlanningDispatch(task.request) else { return }
                task.submittedPlan = nil
                task.activeRunID = nil
                task.error = nil
                if task.request.capsuleID != nil, task.request.originRunID == nil,
                   taskCapsules.pendingPlanningRequest(for: currentSessionID) == nil {
                    task.request.blocker = "\(task.request.blocker ?? "")\n\nRequested revision: \(prompt)"
                    duo.put(task)
                    startCapsulePlanning(task.request)
                    if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { draftText = "" }
                    return
                }
                if taskCapsules.pendingPlanningRequest(for: currentSessionID) == nil {
                    taskCapsules.planningStarted(task.request, sessionID: currentSessionID)
                }
                task.error = nil
                duo.put(task)
                send(prompt, preservingDraftOnFailure: true, includeAttachments: includeAttachments,
                     allowLocalCommands: false, capsuleDispatch: dispatch)
            case .completed:
                guard let capsule = task.capsule,
                      let dispatch = capsuleDispatch(profileID: task.executor.id.uuidString,
                        context: ["id": capsule.id, "revision": capsule.revision, "stage": "followup"], mode: .work) else { return }
                // A follow-up is ordinary executor work; keep the completed
                // capsule's evidence separate from this additional request.
                send(prompt, preservingDraftOnFailure: true, includeAttachments: includeAttachments,
                     allowLocalCommands: false, capsuleDispatch: dispatch)
            }
            return
        }
        guard let planner = duo.saved.planner, let executor = duo.saved.executor else {
            showToast("Choose Plan with and Build with before sending")
            return
        }
        // Validate both exact routes before consuming the user's request.
        guard capsuleDispatch(profileID: planner.id.uuidString, context: [:], mode: .plan) != nil,
              capsuleDispatch(profileID: executor.id.uuidString, context: [:], mode: .work) != nil else { return }
        var recipe = TaskCapsuleRecipe()
        recipe.plannerProfileID = planner.id.uuidString
        recipe.executorProfileID = executor.id.uuidString
        let request = TaskCapsulePlanningRequest(title: "", request: prompt,
            workspaceRoot: TaskCapsuleWorkspace.canonicalPath(workspacePath), recipe: recipe,
            originSessionID: currentSessionID)
        duo.put(DuoTask(sessionID: currentSessionID, workspaceRoot: request.workspaceRoot,
                        planner: planner, executor: executor, request: request))
        startCapsulePlanning(request)
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { draftText = "" }
    }

    func acceptDuo(resume: Bool = false) {
        guard var task = duoTask, let capsule = task.capsule,
              task.phase == .ready || (resume && task.phase == .paused),
              !isBusy, !hasPendingPermission, isAgentOnline else { return }
        guard goals.goal(for: currentSessionID)?.status != .active else { return }
        taskCapsules.error = nil
        guard capsuleDispatch(profileID: task.executor.id.uuidString, context: [:], mode: .work) != nil else { return }
        let attempt = resume ? capsule.resumableAttempt : nil
        if let attempt, !attempt.canResume { openDuoRecovery(); return }
        task.phase = .executing
        task.error = nil
        task.activeRunID = nil
        duo.put(task) // Persist before dispatch; repeated clicks now do nothing.
        startCapsuleStage(capsule, stage: "execute", resumeAttemptID: attempt?.id,
                          handoffID: attempt == nil ? task.handoffID : nil)
    }

    func reviseDuo(feedback: String? = nil) {
        guard var task = duoTask, let capsule = task.capsule,
              !isBusy, !hasPendingPermission, isAgentOnline else { return }
        guard capsuleDispatch(profileID: task.planner.id.uuidString, context: [:], mode: .plan) != nil else { return }
        let previous = (try? JSONEncoder().encode(capsule.plan)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        task.request.capsuleID = capsule.id
        task.request.expectedRevision = capsule.revision
        task.request.originRunID = nil
        task.request.revisionOnly = task.phase == .ready
        task.request.blocker = "\(feedback ?? "Ask which changes the user wants before revising the plan.")\n\nSaved plan:\n\(previous)"
        task.phase = .planning
        task.submittedPlan = nil
        task.activeRunID = nil
        task.error = nil
        duo.put(task)
        if feedback != nil { startCapsulePlanning(task.request) }
    }

    func saveDuoPlanAgain() async {
        guard let task = duoTask, task.phase == .saving, let plan = task.submittedPlan else { return }
        _ = await taskCapsules.savePlan(plan, request: task.request)
    }

    func refreshDuo() async {
        guard let task = duoTask, let capsule = task.capsule, !isBusy, isAgentOnline else { return }
        do {
            let response = try await backend.get("/api/capsules/\(capsule.id)",
                query: [URLQueryItem(name: "workspace_root", value: task.workspaceRoot)], as: TaskCapsuleResponse.self)
            guard var current = duo.saved.tasks[task.sessionID], current.handoffID == task.handoffID,
                  current.capsule?.revision == response.capsule.revision else { return }
            current.capsule = response.capsule
            if current.phase == .paused || current.phase == .executing {
                if response.capsule.attempts.first?.state == "completed" { current.phase = .completed }
                else { current.phase = .paused }
            }
            duo.put(current)
        } catch { /* The saved plan remains available; dispatch revalidates it. */ }
    }

    func openDuoRecovery() {
        guard let capsule = duoTask?.capsule else { return }
        taskCapsules.open(selecting: capsule.id)
    }

    func newDuoPlan() {
        guard !isBusy, !hasPendingPermission else { return }
        taskCapsules.cancelPlanning(sessionID: currentSessionID)
        duo.remove(sessionID: currentSessionID)
        planApprovalPending = false
    }
}
