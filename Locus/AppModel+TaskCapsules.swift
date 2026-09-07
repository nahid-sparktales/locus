import Foundation
import SwiftUI

struct TaskCapsulePresentation: ViewModifier {
    @ObservedObject var capsules: TaskCapsuleModel
    func body(content: Content) -> some View {
        content.sheet(isPresented: $capsules.isPresented) { TaskCapsuleView(model: capsules) }
    }
}

/// A per-turn route snapshot. Credential-bearing fields live in memory only.
struct TaskCapsuleDispatch {
    let profile: AgentProfile
    let provider: String
    let accountID: String?
    let providerBody: [String: Any]
    let context: [String: Any]
    let mode: WorkMode
}

extension AppModel {
    /// Generic team recovery cannot carry a capsule's saved constraints and
    /// baseline checks. Return to the saved plan without changing workspaces.
    func redirectCapsuleRecovery(_ run: OrchestrationRun) -> Bool {
        guard let teamID = run.teamID, teamID.hasPrefix("capsule-") else { return false }
        taskCapsules.open(
            selecting: String(teamID.dropFirst("capsule-".count)),
            notice: "Review the partial work and ask the planner for an updated plan before running again."
        )
        return true
    }

    func configureTaskCapsules() {
        taskCapsules.configure(
            backend: backend,
            workspacePathProvider: { [weak self] in self?.workspacePath ?? "" },
            profilesProvider: { [weak self] in self?.agentProfiles ?? [] },
            profileLabelProvider: { [weak self] profile in
                let account = self?.providerAccounts.first { $0.id == profile.route.accountID }
                return "\(profile.name) · \(profile.model) · \(account?.displayName ?? "Local Ollama")"
            },
            activePlanProvider: { [weak self] in self?.activePlan },
            isBusyProvider: { [weak self] in self?.isBusy == true || self?.hasPendingPermission == true },
            startPlanning: { [weak self] request in self?.startCapsulePlanning(request) },
            startExecution: { [weak self] capsule in self?.startCapsuleStage(capsule, stage: "execute") },
            startReview: { [weak self] capsule in self?.startCapsuleStage(capsule, stage: "review") },
            askPlanner: { [weak self] capsule, blocker in
                let savedPlan = (try? JSONEncoder().encode(capsule.plan))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self?.startCapsulePlanning(TaskCapsulePlanningRequest(
                    title: capsule.title, request: capsule.request, workspaceRoot: capsule.workspaceRoot,
                    recipe: capsule.recipe, capsuleID: capsule.id, expectedRevision: capsule.revision,
                    blocker: "\(blocker)\n\nPrevious saved plan (revision \(capsule.revision)):\n\(savedPlan)"))
            },
            manageProfiles: { [weak self] in
                self?.settingsPage = .agents
                self?.settingsPresented = true
            },
            openConversation: { [weak self] sessionID in
                guard let self else { return }
                guard sessionID != currentSessionID else { return }
                guard let session = sessions.first(where: { $0.id == sessionID }) else {
                    showToast("This capsule's conversation is no longer available")
                    return
                }
                resume(session)
            }
        )
    }

    func startCapsulePlanning(_ request: TaskCapsulePlanningRequest) {
        guard !isIdentityTask, !isBusy, !hasPendingPermission, isAgentOnline,
              TaskCapsuleModel.canonicalWorkspace(request.workspaceRoot) == TaskCapsuleModel.canonicalWorkspace(workspacePath) else {
            taskCapsules.error = "Open an idle regular task in this capsule's workspace and connect the agent."
            return
        }
        guard let dispatch = capsulePlanningDispatch(request) else { return }
        taskCapsules.planningStarted(request, sessionID: currentSessionID)
        taskCapsules.isPresented = false
        let prompt = """
        Create a durable task capsule plan for the request below. Inspect relevant sources first.
        Resolve design decisions so a different implementation model can follow the plan later.
        Do not implement. Call submit_plan with ordered steps and tests, plus step_details,
        constraints and decisions. Use at most 16 steps. Each detail needs a stable id, title,
        specific instructions, earlier-step dependencies, workspace-relative source/destination
        files (including files to create), and concrete completion checks. Include enough
        evidence and references for the implementation model. Ask a structured question if blocked.
        \(request.capsuleID == nil ? "" : "This revises a saved capsule. Reinspect the current source files and submit the complete updated plan.")

        Request: \(request.request)
        \(request.blocker.map { "Planner help requested: \($0)" } ?? "")
        """
        send(prompt, preservingDraftOnFailure: false, includeAttachments: true,
             consumeMatchingDraft: false, allowLocalCommands: false, capsuleDispatch: dispatch)
    }

    func capsulePlanningDispatch(_ request: TaskCapsulePlanningRequest) -> TaskCapsuleDispatch? {
        var context: [String: Any] = ["stage": request.capsuleID == nil ? "plan" : "escalate",
                                      "call_limit": request.recipe.planningCallLimit]
        if let id = request.capsuleID { context["id"] = id }
        if let revision = request.expectedRevision { context["revision"] = revision }
        if request.capsuleID != nil, let runID = request.originRunID {
            context["continuation_of_run_id"] = runID
        }
        return capsuleDispatch(profileID: request.recipe.plannerProfileID, context: context, mode: .plan)
    }

    func startCapsuleStage(_ capsule: TaskCapsule, stage: String) {
        guard !isIdentityTask, !isBusy, !hasPendingPermission, isAgentOnline,
              TaskCapsuleModel.canonicalWorkspace(capsule.workspaceRoot) == TaskCapsuleModel.canonicalWorkspace(workspacePath) else {
            taskCapsules.error = "Open an idle regular task in this capsule's workspace and connect the agent."
            return
        }
        var context: [String: Any] = ["id": capsule.id, "revision": capsule.revision, "stage": stage]
        let profileID = stage == "review" ? capsule.recipe.reviewerProfileID : capsule.recipe.executorProfileID
        guard let profileID else { taskCapsules.error = "Choose a review model first."; return }
        if stage == "execute" {
            let ids = [capsule.recipe.executorProfileID, capsule.recipe.reviewerProfileID].compactMap { $0 }
            var profiles: [[String: Any]] = []
            for id in Set(ids) {
                guard let payload = capsuleProfilePayload(id: id) else { return }
                profiles.append(payload)
            }
            context["profiles"] = profiles
        }
        guard let dispatch = capsuleDispatch(profileID: profileID, context: context,
                                              mode: stage == "execute" ? .work : .plan) else { return }
        taskCapsules.stageStarted(capsule: capsule, stage: stage, sessionID: currentSessionID)
        taskCapsules.isPresented = false
        let planData = (try? JSONEncoder().encode(capsule.plan)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let prompt = stage == "execute"
            ? "Run saved capsule ‘\(capsule.title)’ (revision \(capsule.revision)).\n\n\(capsule.request)"
            : "Review the current workspace against this saved capsule. Inspect the files and completed task evidence. Report which checks pass, fail, or remain unverified. Do not edit files or claim completion without evidence.\n\n\(planData)"
        send(prompt, preservingDraftOnFailure: false, includeAttachments: false,
             consumeMatchingDraft: false, allowLocalCommands: false, capsuleDispatch: dispatch)
    }

    private func capsuleDispatch(profileID: String, context: [String: Any], mode: WorkMode) -> TaskCapsuleDispatch? {
        guard let profile = agentProfiles.first(where: { $0.id.uuidString.caseInsensitiveCompare(profileID) == .orderedSame }),
              let resolved = capsuleProvider(profile) else { return nil }
        return TaskCapsuleDispatch(profile: profile, provider: resolved.provider, accountID: resolved.accountID,
                                   providerBody: resolved.body, context: context, mode: mode)
    }

    /// Exact IDs are mandatory; missing accounts never select a compatible replacement.
    static func capsuleAccount(profile: AgentProfile, accounts: [ProviderAccount]) -> ProviderAccount? {
        guard case .providerAccount(let id) = profile.route else { return nil }
        return accounts.first { $0.id == id }
    }

    private func capsuleProvider(_ profile: AgentProfile) -> (provider: String, accountID: String?, body: [String: Any])? {
        guard profile.isConfigured else { taskCapsules.error = "Configure an exact model for \(profile.name)."; return nil }
        if case .localOllama = profile.route {
            return ("ollama", nil, ["provider": "ollama", "context_window": settings.localContextWindow ?? 0])
        }
        guard let account = Self.capsuleAccount(profile: profile, accounts: providerAccounts),
              account.isCredentialReady(in: credentialStore) else {
            taskCapsules.error = "The selected account is unavailable. Reconnect it or explicitly choose another profile."
            return nil
        }
        if account.kind.listsModels, let catalog = accountModels[account.id], !catalog.isEmpty,
           !catalog.contains(where: { $0.caseInsensitiveCompare(profile.model) == .orderedSame }) {
            taskCapsules.error = "\(account.displayName) does not report \(profile.model). Choose an available model."
            return nil
        }
        if account.kind == .chatGPT {
            return ("chatgpt", account.id.uuidString, ["provider": "chatgpt", "account_id": account.id.uuidString,
                "codex_home_id": account.codexHomeIdentifier, "account_label": account.displayName,
                "model": profile.model, "native_mode": account.codexNativeModeEnabled,
                "web_search": account.codexWebSearchEnabled, "reasoning_effort": account.codexReasoningEffortValue])
        }
        return ("remote", account.id.uuidString, ["provider": "remote", "account_id": account.id.uuidString,
            "base_url": account.resolvedBaseURL, "model": profile.model,
            "api_key": credentialStore.get(account: account.credentialAccount) ?? "",
            "auth_style": account.kind.authStyle, "account_kind": account.kind.rawValue,
            "account_label": account.displayName, "lists_models": account.kind.listsModels,
            "context_window": account.contextWindow ?? 0, "verify": false])
    }

    private func capsuleProfilePayload(id: String) -> [String: Any]? {
        guard let profile = agentProfiles.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }),
              let resolved = capsuleProvider(profile) else { return nil }
        var route = resolved.body
        if resolved.provider == "ollama" { route["host"] = lastOllamaHost }
        let kind = route["account_kind"] as? String
        let subscription = resolved.provider == "chatgpt" || kind == ProviderKind.kimiCode.rawValue
        var payload: [String: Any] = ["id": profile.id.uuidString, "name": profile.name, "model": profile.model,
            "role": profile.role.rawValue, "instructions": profile.instructions, "capabilities": profile.capabilityTags,
            "access_ceiling": profile.accessCeiling.rawValue, "timeout_seconds": profile.timeoutSeconds,
            "token_limit": profile.tokenLimit, "metering": subscription ? "self_hosted" : profile.metering.rawValue,
            "route": route]
        if let behavior = encodedJSONObject(profile.resolvedBehavior) { payload["behavior"] = behavior }
        if let policy = profile.mcpPolicy, let raw = encodedJSONObject(policy) { payload["mcp_policy"] = raw }
        if !subscription {
            payload["input_cost_per_million"] = profile.inputCostPerMillion
            payload["output_cost_per_million"] = profile.outputCostPerMillion
        }
        return payload
    }
}
