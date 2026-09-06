import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Composition-root team operations: profile connection tests, the
/// credential-carrying run manifest, run lifecycle verbs and exports, and
/// dispatch-plan decisions.
extension AppModel {
    // MARK: - Agents and teams

    func testAgentProfileConnection(_ profile: AgentProfile) async -> String {
        switch profile.route {
        case .localOllama:
            guard let url = URL(string: lastOllamaHost + "/api/tags") else {
                return "The local Ollama URL is invalid."
            }
            do {
                let (data, response) = try await ProxyRuntime.shared.urlSession.data(from: url)
                guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1) else {
                    return "Ollama did not accept the connection."
                }
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let names = (object?["models"] as? [[String: Any]] ?? []).compactMap {
                    $0["name"] as? String
                }
                if !profile.model.isEmpty,
                   !names.contains(where: { $0.caseInsensitiveCompare(profile.model) == .orderedSame })
                {
                    return "Connected, but that exact model is not installed in Ollama."
                }
                return "Connected to local Ollama."
            } catch {
                return "Could not connect to Ollama: \(error.localizedDescription)"
            }
        case .providerAccount(let id):
            guard let account = providerAccounts.first(where: { $0.id == id }) else {
                return "That provider account is unavailable."
            }
            let result = await ProviderModelCatalog.fetch(for: account, credentialStore: credentialStore)
            accountModels[id] = result.models
            accountStatus[id] = result.status
            guard result.status.isHealthy else { return result.status.summary }
            if account.kind.listsModels,
               !profile.model.isEmpty,
               !result.models.contains(where: { $0.caseInsensitiveCompare(profile.model) == .orderedSame })
            {
                return "Connected, but the exact model was not in this account's catalog."
            }
            return result.status.summary
        }
    }

    /// Builds an in-memory manifest for one run. Provider credentials are
    /// included only in the WebSocket payload and are never written into the
    /// profile/team stores or transcript.
    func teamManifest(for text: String, teamID: UUID? = nil) -> [String: Any]? {
        let mention = TeamMentionResolver.selection(
            in: text,
            profiles: agentProfiles,
            teams: agentTeams
        )
        let team = teamID.flatMap { requested in
            agentTeams.first(where: { $0.id == requested })
        } ?? mention.team
            ?? selectedAgentTeam
            ?? mention.agent.flatMap { agent in
                agentTeams.first(where: { $0.memberIDs.contains(agent.id) })
            }
        guard let team else { return nil }
        let errors = AgentTeamValidation.errors(team: team, profiles: agentProfiles)
        guard errors.isEmpty else {
            showToast(errors[0])
            return nil
        }
        let routeErrors = AgentTeamValidation.routeErrors(
            team: team,
            profiles: agentProfiles,
            accounts: providerAccounts,
            accountModels: accountModels
        )
        guard routeErrors.isEmpty else {
            showToast(routeErrors[0])
            return nil
        }
        let members = team.memberIDs.compactMap { id in agentProfiles.first(where: { $0.id == id }) }
        for profile in members {
            guard let accountID = profile.route.accountID else { continue }
            guard teamRoutingConsentAccountIDs.contains(accountID) else {
                let label = providerAccounts.first(where: { $0.id == accountID })?.displayName
                    ?? "hosted account"
                showToast("Allow automatic team routing for \(label) in Agents & Teams")
                return nil
            }
        }
        let routes: [[String: Any]] = members.compactMap { profile in
            var route: [String: Any]
            switch profile.route {
            case .localOllama:
                route = [
                    "provider": "ollama",
                    "host": lastOllamaHost,
                ]
            case .providerAccount(let accountID):
                guard let account = providerAccounts.first(where: { $0.id == accountID }),
                      account.isCredentialReady(in: credentialStore)
                else { return nil }
                if account.kind == .chatGPT {
                    route = [
                        "provider": "chatgpt",
                        "account_id": account.id.uuidString,
                        "codex_home_id": account.codexHomeIdentifier,
                        "account_label": account.displayName,
                        // Always sent: a missing field means "keep the
                        // current server-side value", not "use the default".
                        "native_mode": account.codexNativeModeEnabled,
                        "web_search": account.codexWebSearchEnabled,
                        "reasoning_effort": account.codexReasoningEffortValue,
                    ]
                } else {
                    route = [
                        "provider": "remote",
                        "base_url": account.resolvedBaseURL,
                        "api_key": credentialStore.get(account: account.credentialAccount) ?? "",
                        "auth_style": account.kind.authStyle,
                        "account_kind": account.kind.rawValue,
                        "lists_models": account.kind.listsModels,
                        "account_label": account.displayName,
                    ]
                }
            }
            var entry: [String: Any] = [
                "id": profile.id.uuidString,
                "name": profile.name,
                "model": profile.model,
                "role": profile.role.rawValue,
                "instructions": profile.instructions,
                "capabilities": profile.capabilityTags,
                "access_ceiling": profile.accessCeiling.rawValue,
                "timeout_seconds": profile.timeoutSeconds,
                "token_limit": profile.tokenLimit,
                "metering": route["provider"] as? String == "chatgpt"
                    ? AgentMetering.selfHosted.rawValue
                    : profile.metering.rawValue,
                "route": route,
            ]
            if let behavior = encodedJSONObject(profile.resolvedBehavior) {
                entry["behavior"] = behavior
            }
            if let rate = profile.inputCostPerMillion { entry["input_cost_per_million"] = rate }
            if let rate = profile.outputCostPerMillion { entry["output_cost_per_million"] = rate }
            if let policy = profile.mcpPolicy,
               let data = try? JSONEncoder().encode(policy),
               let value = try? JSONSerialization.jsonObject(with: data)
            {
                entry["mcp_policy"] = value
            }
            return entry
        }
        guard routes.count == members.count else {
            showToast("A team member's provider account is unavailable")
            return nil
        }
        var teamPayload: [String: Any] = [
            "id": team.id.uuidString,
            "name": team.name,
            "member_ids": team.memberIDs.map(\.uuidString),
            "use_managed_worktree": team.useManagedWorktree,
            "parallel_writers": team.resolvedParallelWriters,
            // One approval releases the complete plan. Individual jobs and
            // models do not introduce additional dispatch confirmations.
            "dispatch_approval_mode": DispatchApprovalMode.preview.rawValue,
            "routing_mode": team.resolvedRoutingMode.rawValue,
            "routing_weights": [
                "quality": team.resolvedRoutingWeights.quality,
                "reliability": team.resolvedRoutingWeights.reliability,
                "privacy": team.resolvedRoutingWeights.privacy,
                "latency": team.resolvedRoutingWeights.latency,
                "cost": team.resolvedRoutingWeights.cost,
            ],
            "evaluation_tags": team.evaluationTags ?? [],
            "maximum_estimated_cost": team.maximumEstimatedCost ?? 0,
            "swarm_policy": [
                "version": team.resolvedSwarmPolicy.version,
                "engine": team.resolvedSwarmPolicy.engine.rawValue,
                "delegation_mode": team.resolvedSwarmPolicy.delegationMode.rawValue,
                "sizing_mode": team.resolvedSwarmPolicy.sizingMode.rawValue,
                "max_total_agents": team.resolvedSwarmPolicy.maxTotalAgents,
                "max_depth": team.resolvedSwarmPolicy.maxDepth,
            ],
            "budget": [
                "max_jobs": team.budget.maxJobs,
                "max_rounds": team.budget.maxRounds,
                "max_model_calls": team.budget.maxModelCalls,
                "max_concurrent_calls": team.budget.maxConcurrentCalls,
                "max_metered_tokens": team.budget.maxMeteredTokens,
                "call_budget_mode": team.budget.callBudgetMode.rawValue,
            ],
        ]
        if let id = team.dispatcherID { teamPayload["dispatcher_id"] = id.uuidString }
        if let id = team.fallbackDispatcherID { teamPayload["fallback_dispatcher_id"] = id.uuidString }
        if let id = team.defaultWriterID { teamPayload["default_writer_id"] = id.uuidString }
        var manifest: [String: Any] = [
            "run_id": UUID().uuidString,
            "team": teamPayload,
            "profiles": routes,
        ]
        if let id = mention.agent?.id { manifest["forced_agent_id"] = id.uuidString }
        return manifest
    }

    func exportOrchestration(_ runID: String, includeContent: Bool) async {
        do {
            let value: [String: JSONValue] = try await backend.get(
                "/api/orchestrations/\(runID)/export",
                query: [URLQueryItem(
                    name: "include_content", value: includeContent ? "true" : "false"
                )],
                as: [String: JSONValue].self
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(runID).locusrun"
            panel.allowedContentTypes = [UTType(filenameExtension: "locusrun") ?? .json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            showToast(includeContent ? "Run exported with visible content" : "Redacted run exported")
        } catch {
            showToast("Could not export run: \(error.localizedDescription)")
        }
    }

    func exportRunToOTLP(_ runID: String, includeContent: Bool = false) async {
        guard settings.otlpExportEnabled,
              !settings.otlpEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            let _: SimpleActionResponse = try await backend.post(
                "/api/runs/\(runID)/otlp",
                body: [
                    "endpoint": settings.otlpEndpoint,
                    "authorization": settings.otlpAuthorization,
                    "include_content": includeContent,
                ],
                as: SimpleActionResponse.self
            )
            await refreshOrchestrationRuns(select: runID)
        } catch {
            await refreshOrchestrationRuns(select: runID)
            showToast("Telemetry export failed: \(error.localizedDescription)")
        }
    }

    func exportOrchestrationToOTLP(_ runID: String) async {
        let sample = AppSettings.clampOTLPSamplingRate(settings.otlpSamplingRate)
        guard sample >= 1 || (sample > 0 && Double.random(in: 0..<1) < sample) else { return }
        await exportRunToOTLP(runID, includeContent: false)
    }

    func pauseOrchestration(_ runID: String) {
        orchestrationAction(path: "/api/orchestrations/\(runID)/pause", runID: runID)
    }

    func cancelOrchestration(_ runID: String) {
        let transport = orchestrationBackend(for: runID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await transport.post(
                    "/api/orchestrations/\(runID)/cancel",
                    body: [:],
                    timeout: 30,
                    as: SimpleActionResponse.self
                )
                if orchestrationRunID == runID {
                    pendingDispatchPlan = nil
                    orchestrationState = .cancelled
                    steeringState = "Stopping the team run…"
                    updateTaskConversation(
                        state: .cancelled,
                        event: ["run_id": runID]
                    )
                }
                showToast("Stopping the team run")
                await refreshOrchestrationRuns(select: runID)
            } catch {
                showToast("Could not stop the team run: \(error.localizedDescription)")
            }
        }
    }

    func discardOrchestration(_ runID: String) {
        orchestrationAction(path: "/api/orchestrations/\(runID)/discard", runID: nil)
    }

    func cleanupOrchestrationCheckout(_ run: OrchestrationRun) {
        guard let taskID = run.taskID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskMutationResponse = try await backend.delete(
                    "/api/tasks/\(taskID)", as: TaskMutationResponse.self
                )
                if activeTaskRecord?.id == taskID {
                    activeTaskRecord = response.task
                    landingFlow.taskHasChanges = false
                }
                showToast("Managed checkout archived with a restorable snapshot")
                await refreshOrchestrationRuns(select: run.id)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func setOrchestrationPinned(_ run: OrchestrationRun, pinned: Bool) {
        Task {
            do {
                let updated: OrchestrationRun = try await backend.patch(
                    "/api/orchestrations/\(run.id)",
                    body: ["pinned": pinned],
                    as: OrchestrationRun.self
                )
                selectedOrchestrationRun = updated
                await refreshOrchestrationRuns(select: updated.id)
            } catch {
                showToast("Could not update run: \(error.localizedDescription)")
            }
        }
    }

    func resumeOrchestration(_ run: OrchestrationRun) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("That team run is not paused or interrupted")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team, models, or hosted consent before resuming")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let assessment: RunRecoveryAssessment = try await backend.post(
                    "/api/orchestrations/\(run.id)/recovery-assessment",
                    body: ["manifest": manifest],
                    as: RunRecoveryAssessment.self
                )
                guard assessment.canResume else {
                    showToast(assessment.repairChecklist.first ?? "This run cannot be resumed")
                    return
                }
                orchestrationAction(
                    path: "/api/orchestrations/\(run.id)/resume",
                    body: ["manifest": manifest],
                    runID: run.id
                )
            } catch {
                showToast("Could not assess recovery: \(error.localizedDescription)")
            }
        }
    }

    func retryOrchestrationJob(_ attempt: AgentJobAttempt, in run: OrchestrationRun) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("Pause the team run before retrying a job")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team before retrying this job")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/jobs/\(attempt.jobID)/retry",
            body: ["manifest": manifest],
            runID: run.id
        )
    }

    func stopOrchestrationBranch(_ attempt: AgentJobAttempt, in run: OrchestrationRun) {
        guard teamRunPresentation(for: run.id, durable: run).isActivelyOwned,
              !isCodingAttempt(attempt, in: run)
        else {
            showToast("Only an active read-only branch can be stopped")
            return
        }
        guard let node = encodedAgentNode(attempt.resolvedNodeID) else {
            showToast("That agent branch has an invalid identity")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/agents/\(node)/stop",
            runID: run.id
        )
    }

    func retryOrchestrationBranch(_ attempt: AgentJobAttempt, in run: OrchestrationRun) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("Pause the team run before retrying a branch")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID),
              let node = encodedAgentNode(attempt.resolvedNodeID)
        else {
            showToast("Repair the team before retrying this branch")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/agents/\(node)/retry",
            body: ["manifest": manifest],
            runID: run.id
        )
    }

    func runOrchestrationWithLocus(_ run: OrchestrationRun) {
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team before continuing with Locus")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/run-with-locus",
            body: ["manifest": manifest],
            runID: run.id
        )
    }

    private func encodedAgentNode(_ nodeID: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return nodeID.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    func reassignOrchestrationJob(
        _ attempt: AgentJobAttempt,
        in run: OrchestrationRun,
        to profile: AgentProfile
    ) {
        guard teamRunPresentation(for: run.id, durable: run).canRecover else {
            showToast("Pause the team run before reassigning a job")
            return
        }
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team before reassigning this job")
            return
        }
        orchestrationAction(
            path: "/api/orchestrations/\(run.id)/jobs/\(attempt.jobID)/reassign",
            body: ["manifest": manifest, "agent_id": profile.id.uuidString],
            runID: run.id
        )
    }

    func reassignmentCandidates(
        for attempt: AgentJobAttempt,
        in run: OrchestrationRun
    ) -> [AgentProfile] {
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let team = agentTeams.first(where: { $0.id == teamID })
        else { return [] }
        return team.memberIDs.compactMap { id in
            agentProfiles.first(where: { $0.id == id })
        }.filter { profile in
            !profile.accessCeiling.canWrite
                && profile.id.uuidString != attempt.agentID
                && (attempt.role != "reviewer" || profile.role == .reviewer)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isCodingAttempt(_ attempt: AgentJobAttempt, in run: OrchestrationRun) -> Bool {
        guard case .object(let plan) = run.checkpoint?.state["plan"],
              case .array(let jobs) = plan["jobs"]
        else { return false }
        return jobs.contains { value in
            guard case .object(let job) = value else { return false }
            return job["id"]?.string == attempt.jobID && job["kind"]?.string == "writer"
        }
    }

    func replayOrchestration(_ run: OrchestrationRun) {
        startOrchestrationCopy(run, action: "replay")
    }

    func duplicateOrchestration(_ run: OrchestrationRun) {
        startOrchestrationCopy(run, action: "duplicate")
    }

    private func startOrchestrationCopy(_ run: OrchestrationRun, action: String) {
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID)
        else {
            showToast("Repair the team, models, or hosted consent before continuing")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: OrchestrationMutationResponse = try await backend.post(
                    "/api/orchestrations/\(run.id)/\(action)",
                    body: ["manifest": manifest],
                    timeout: 30,
                    as: OrchestrationMutationResponse.self
                )
                orchestrationRunID = response.runID
                await refreshOrchestrationRuns(select: response.runID)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func decideDispatch(_ action: String, editedPlan: DispatchPlan? = nil) {
        guard let runID = orchestrationRunID else { return }
        if action == "cancel" {
            cancelOrchestration(runID)
            return
        }
        var payload: [String: Any] = ["type": "dispatch_decision", "run_id": runID, "action": action]
        if let editedPlan, let value = encodedJSONObject(editedPlan) { payload["plan"] = value }
        guard orchestrationBackend(for: runID).send(payload) else {
            showToast("The dispatch decision could not be delivered")
            return
        }
        pendingDispatchPlan = nil
        if let runtime = taskWorkers[currentSessionID] {
            runtime.executionState = action == "redispatch" ? .dispatching : .running
            updateBackgroundChatState(runtime)
        }
        if action == "redispatch" {
            orchestrationState = .dispatching
            dispatcherValidationReason = nil
            if var activity = dispatcherActivity {
                activity.state = .running
                activity.output = "Creating a new dispatcher plan…"
                activity.startedAt = Date()
                dispatcherActivity = activity
            }
            updateTaskConversation(state: .dispatching, event: ["run_id": runID])
        }
    }

    func dispatchPlanErrors(_ plan: DispatchPlan) -> [String] {
        let runTeamID = selectedOrchestrationRun?.teamID.flatMap(UUID.init(uuidString:))
        guard let team = runTeamID.flatMap({ id in agentTeams.first(where: { $0.id == id }) })
            ?? selectedAgentTeam
        else { return ["The selected team is unavailable."] }
        let profiles = Dictionary(uniqueKeysWithValues: agentProfiles.map { ($0.id, $0) })
        let budget = plan.budget ?? team.budget
        var errors: [String] = []
        if plan.jobs.isEmpty || plan.jobs.count > budget.maxJobs {
            errors.append("The plan must contain 1…\(budget.maxJobs) jobs.")
        }
        let ids = plan.jobs.map(\.id)
        if ids.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || Set(ids).count != ids.count
        {
            errors.append("Every job needs a unique ID.")
        }
        let known = Set(ids)
        for job in plan.jobs {
            guard let agentID = UUID(uuidString: job.agentID),
                  team.memberIDs.contains(agentID), let profile = profiles[agentID]
            else {
                errors.append("Job \(job.id) uses an unavailable team member.")
                continue
            }
            if job.kind == "writer" && !profile.accessCeiling.canWrite {
                errors.append("Coding job \(job.id) requires a write-capable team member.")
            }
            if job.kind != "writer" && profile.accessCeiling.canWrite {
                errors.append("Write-capable team members may only own coding jobs.")
            }
            if job.kind == "reviewer" && profile.role != .reviewer {
                errors.append("Reviewer jobs require a Reviewer profile.")
            }
            if let role = job.requiredRole, !role.isEmpty, profile.role.rawValue != role {
                errors.append("Job \(job.id) requires the \(role) role.")
            }
            if !Set(job.capabilityTags ?? []).isSubset(of: Set(profile.capabilityTags)) {
                errors.append("Job \(job.id) requires capabilities its agent does not have.")
            }
            if job.dependencies.contains(job.id)
                || job.dependencies.contains(where: { !known.contains($0) })
            {
                errors.append("Job \(job.id) has an invalid dependency.")
            }
        }
        let writerJobs = plan.jobs.filter { $0.kind == "writer" }
        if writerJobs.isEmpty {
            errors.append("The plan must contain at least one coding job.")
        }
        var visiting: Set<String> = []
        var visited: Set<String> = []
        let dependencies = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, $0.dependencies) })
        func visit(_ id: String) -> Bool {
            if visited.contains(id) { return false }
            if visiting.contains(id) { return true }
            visiting.insert(id)
            for dependency in dependencies[id] ?? [] where visit(dependency) { return true }
            visiting.remove(id)
            visited.insert(id)
            return false
        }
        if ids.contains(where: visit) { errors.append("The job graph contains a dependency cycle.") }
        let kindByID = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.id, $0.kind) })
        for job in plan.jobs {
            if job.kind == "specialist",
               job.dependencies.contains(where: { kindByID[$0] != "specialist" })
            {
                errors.append("Specialists may depend only on specialist jobs.")
            }
            if job.kind == "writer",
               job.dependencies.contains(where: {
                   guard let kind = kindByID[$0] else { return false }
                   return kind != "specialist" && kind != "writer"
               })
            {
                errors.append("Coding jobs may depend only on specialists or earlier coding jobs.")
            }
        }
        func transitivelyDepends(_ jobID: String, on targetID: String, seen: inout Set<String>) -> Bool {
            guard seen.insert(jobID).inserted else { return false }
            for dependency in dependencies[jobID] ?? [] {
                if dependency == targetID { return true }
                if transitivelyDepends(dependency, on: targetID, seen: &seen) { return true }
            }
            return false
        }
        if writerJobs.count > 1 {
            for leftIndex in 0..<(writerJobs.count - 1) {
                for rightIndex in (leftIndex + 1)..<writerJobs.count {
                    var leftSeen: Set<String> = []
                    var rightSeen: Set<String> = []
                    let ordered = transitivelyDepends(
                        writerJobs[leftIndex].id,
                        on: writerJobs[rightIndex].id,
                        seen: &leftSeen
                    ) || transitivelyDepends(
                        writerJobs[rightIndex].id,
                        on: writerJobs[leftIndex].id,
                        seen: &rightSeen
                    )
                    if !ordered {
                        errors.append("Every pair of coding jobs must be ordered by a dependency.")
                    }
                }
            }
        }
        let minimumModelCalls = plan.jobs.count + 2 + (budget.maxRounds > 1 ? 1 : 0)
        if budget.maxModelCalls < minimumModelCalls {
            errors.append("This plan needs at least \(minimumModelCalls) model calls for its jobs, synthesis, and possible lead revision.")
        }
        if budget.maxConcurrentCalls > budget.maxModelCalls {
            errors.append("Concurrent calls cannot exceed the model-call budget.")
        }
        for id in team.memberIDs {
            if let accountID = profiles[id]?.route.accountID,
               !teamRoutingConsentAccountIDs.contains(accountID)
            {
                errors.append("Hosted automatic-routing consent is missing.")
                break
            }
        }
        return Array(Set(errors)).sorted()
    }

    private func orchestrationAction(
        path: String,
        body: [String: Any] = [:],
        runID: String?
    ) {
        let transport = runID.map(orchestrationBackend(for:)) ?? backend
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await transport.post(
                    path, body: body, timeout: 30, as: SimpleActionResponse.self
                )
                await refreshOrchestrationRuns(select: runID)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }
}
