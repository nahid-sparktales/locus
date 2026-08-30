import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Run-queue control and retry, persisted-run restoration, Activity
/// Center run actions, worktree task git operations, schedule prefill and
/// validation, and provider-account routing verbs.
extension AppModel {
    func openWorkspaceMemorySource(_ memory: WorkspaceMemory) {
        if let runID = memory.sourceRunID, !runID.isEmpty {
            selectInspectorTab(.agents)
            inspectorCollapsed = false
            Task { await loadOrchestrationRun(runID) }
            return
        }
        if let sessionID = memory.sourceSessionID,
           let session = sessions.first(where: { $0.id == sessionID })
        {
            resume(session)
        } else {
            showToast("The source chat is no longer available")
        }
    }

    var currentLandingCheckCommands: [String] {
        workspaceProfiles.first(where: {
            SessionSummary.canonicalWorkspacePath($0.path)
                == SessionSummary.canonicalWorkspacePath(workspacePath)
        })?.resolvedLandingCheckCommands ?? []
    }

    func saveLandingCheckCommands(_ commands: [String]) {
        let clean = Array(commands.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        }.filter { !$0.isEmpty }.prefix(8))
        touchWorkspaceProfile(workspacePath)
        if let index = workspaceProfiles.firstIndex(where: {
            SessionSummary.canonicalWorkspacePath($0.path)
                == SessionSummary.canonicalWorkspacePath(workspacePath)
        }) {
            workspaceProfiles[index].landingCheckCommands = clean
            persistWorkspaceProfiles()
        }
    }

    func presentScheduleEditor(task: ScheduledTask? = nil, prompt: String? = nil) {
        if let task {
            scheduleEditorDraft = ScheduleEditorDraft(task: task)
            return
        }
        var draft = ScheduleEditorDraft()
        draft.prompt = prompt ?? draftText
        draft.workspaceRoot = sessionInfo?.workspaceRoot ?? workspacePath
        draft.mode = selectedMode
        draft.executionEnvironment = sessionInfo?.environment?["type"] == "worktree"
            ? .worktree : .local
        if let team = selectedAgentTeam {
            draft.runner = .team
            draft.teamID = team.id.uuidString
            draft.teamName = team.name
        } else {
            draft.runner = .solo
        }
        if let account = activeAccount {
            draft.provider = account.kind == .chatGPT ? "chatgpt" : "remote"
            draft.providerAccountID = account.id.uuidString
            draft.model = routedModel(for: account)
        } else {
            draft.provider = "ollama"
            draft.model = selectedModel
        }
        scheduleEditorDraft = draft
    }

    func rememberScheduleWorkspace(_ url: URL) -> String? {
        guard workspaceAccess.rememberAndActivate(url) else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func openSchedules() {
        activityCenterSection = .schedules
        activityCenterPresented = true
        Task { @MainActor [weak self] in
            await self?.refreshScheduledTasks()
        }
    }

    func scheduleConfigurationIssue(for draft: ScheduleEditorDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Add a schedule name" }
        guard !prompt.isEmpty else { return "Add a prompt" }
        guard FileManager.default.fileExists(atPath: draft.workspaceRoot),
              workspaceAccess.activateStored(path: draft.workspaceRoot)
        else { return "Choose an available workspace folder" }
        guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.model != "No model"
        else { return "Choose an available model" }
        if draft.ruleKind == .once, draft.oneTimeDate <= Date() {
            return "Choose a future date and time"
        }
        if draft.ruleKind == .interval {
            let seconds = draft.intervalEvery * [
                .minutes: 60, .hours: 3_600, .days: 86_400, .weeks: 604_800,
            ][draft.intervalUnit, default: 0]
            guard seconds >= 900 else { return "Custom intervals must be at least 15 minutes" }
        }
        if draft.runner == .team {
            guard let id = draft.teamID.flatMap(UUID.init(uuidString:)),
                  agentTeams.contains(where: { $0.id == id })
            else { return "Choose an available team" }
        }
        if draft.provider != "ollama" {
            guard let id = draft.providerAccountID.flatMap(UUID.init(uuidString:)),
                  let account = providerAccounts.first(where: { $0.id == id })
            else { return "Choose an available model account" }
            let expected = account.kind == .chatGPT ? "chatgpt" : "remote"
            guard draft.provider == expected else { return "The selected model account changed" }
        }
        return nil
    }

    func scheduleConfigurationIssue(for task: ScheduledTask) -> String? {
        guard FileManager.default.fileExists(atPath: task.workspaceRoot),
              workspaceAccess.activateStored(path: task.workspaceRoot)
        else { return "The workspace bookmark is no longer available" }
        guard !task.model.isEmpty else { return "The configured model is no longer available" }
        if task.runner == .team {
            guard let id = task.teamID.flatMap(UUID.init(uuidString:)),
                  let team = agentTeams.first(where: { $0.id == id })
            else { return "The configured team no longer exists" }
            if let issue = AgentTeamValidation.errors(team: team, profiles: agentProfiles).first {
                return issue
            }
        }
        if task.provider == "ollama" {
            if !installedLocalModels.isEmpty,
               !installedLocalModels.contains(where: { $0.name == task.model }) {
                return "The configured local model is no longer installed"
            }
        } else {
            guard let id = task.providerAccountID.flatMap(UUID.init(uuidString:)),
                  let account = providerAccounts.first(where: { $0.id == id })
            else { return "The configured model account no longer exists" }
            let expected = account.kind == .chatGPT ? "chatgpt" : "remote"
            guard task.provider == expected else { return "The configured model account changed" }
            if let catalog = accountModels[id], !catalog.isEmpty, !catalog.contains(task.model) {
                return "The configured model is no longer offered by this account"
            }
        }
        return nil
    }

    func updateQueuedRun(_ run: OrchestrationRun, action: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: OrchestrationRun = try await backend.patch(
                    "/api/runs/\(run.id)/queue", body: ["action": action],
                    as: OrchestrationRun.self
                )
                if let sessionID = run.sessionID {
                    if action == "cancel" {
                        pendingChatTurns[sessionID]?.cancel()
                        pendingChatTurns.removeValue(forKey: sessionID)
                        pendingChatTurnTokens.removeValue(forKey: sessionID)
                        chatAdmissionQueue.remove(sessionID)
                        if let runtime = taskWorkers[sessionID] {
                            finishChatRuntime(runtime, state: .cancelled)
                        }
                    } else {
                        chatAdmissionQueue.move(sessionID, action: action)
                    }
                }
                await refreshActivityRuns()
            } catch { showToast(error.localizedDescription) }
        }
    }

    func retryRun(_ run: OrchestrationRun) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let retry: OrchestrationRun = try await backend.post(
                    "/api/runs/\(run.id)/retry", body: [:], as: OrchestrationRun.self
                )
                guard let sessionID = retry.sessionID,
                      let session = sessions.first(where: { $0.id == sessionID }),
                      let workspace = retry.workspaceRoot ?? session.workspacePath
                else {
                    showToast("The original chat or workspace is unavailable")
                    return
                }
                guard let worker = await ensureChatWorker(
                    for: sessionID,
                    workspaceRoot: workspace,
                    provider: retry.manifest?["provider"]?.string,
                    providerAccountID: retry.manifest?["provider_account_id"]?.string,
                    model: retry.manifest?["model"]?.string
                ) else {
                    showToast("The original chat worker could not be started")
                    return
                }
                let retryMode = retry.manifest?["mode"]?.string
                    .flatMap { WorkMode.canonical($0) } ?? .work
                worker.reservedRunID = retry.id
                worker.dispatchedMode = retryMode
                worker.executionState = .queued
                taskConversationStates[sessionID] = TaskConversationState(
                    sessionID: sessionID,
                    taskID: retry.taskID,
                    teamID: retry.teamID,
                    workerID: retry.workerID,
                    runID: retry.id,
                    state: .queued,
                    updatedAt: Date()
                )
                guard await waitForChatExecutionSlot(worker) else { return }
                let _: OrchestrationRun = try await backend.patch(
                    "/api/runs/\(retry.id)/queue", body: ["action": "admit"],
                    as: OrchestrationRun.self
                )
                var request: [String: Any] = [
                    "type": "user_message",
                    "text": Self.decoratedPrompt(
                        retry.request,
                        mode: retryMode,
                        chatAttachments: [],
                        contextFiles: [],
                        restoredTranscriptContext: nil
                    ),
                    "mode": retryMode.rawValue,
                    "run_id": retry.id,
                ]
                if let config = encodedJSONObject(primaryAgentBehavior) {
                    request["agent_config"] = config
                }
                if retry.runKind == "team",
                   let teamID = retry.teamID.flatMap(UUID.init(uuidString:)),
                   var manifest = teamManifest(for: retry.request, teamID: teamID) {
                    manifest["run_id"] = retry.id
                    request["team"] = manifest
                    worker.dispatchedTeamRunID = retry.id
                    worker.executionState = .dispatching
                } else {
                    worker.executionState = .running
                    if retry.isSoloSwarm {
                        request["solo_swarm"] = ["enabled": true]
                    }
                }
                guard worker.service.send(request) else {
                    finishChatRuntime(worker, state: .failed, error: "The retry could not be delivered")
                    return
                }
                worker.startedAt = Date()
                updateBackgroundChatState(worker)
                showToast("Retry queued in \(session.displayTitle)")
                await refreshActivityRuns()
            } catch { showToast(error.localizedDescription) }
        }
    }

    func restorePersistedQueuedRuns() {
        let queued = activityRuns.filter { $0.state == "queued" }.sorted {
            ($0.queuePosition ?? .max) < ($1.queuePosition ?? .max)
        }
        for run in queued where restoredQueuedRunIDs.insert(run.id).inserted {
            Task { @MainActor [weak self] in
                await self?.dispatchPersistedQueuedRun(run)
            }
        }
    }

    func dispatchPersistedQueuedRun(_ run: OrchestrationRun) async {  // internal(for: AppModel extension files)
        guard let sessionID = run.sessionID,
              let workspace = run.workspaceRoot,
              let worker = await ensureChatWorker(
                for: sessionID,
                workspaceRoot: workspace,
                provider: run.manifest?["provider"]?.string,
                providerAccountID: run.manifest?["provider_account_id"]?.string,
                model: run.manifest?["model"]?.string
              )
        else {
            restoredQueuedRunIDs.remove(run.id)
            showToast("A saved queued run needs its original chat and workspace")
            return
        }
        let mode = run.manifest?["mode"]?.string.flatMap { WorkMode.canonical($0) } ?? .work
        worker.reservedRunID = run.id
        worker.dispatchedMode = mode
        worker.executionState = .queued
        taskConversationStates[sessionID] = TaskConversationState(
            sessionID: sessionID,
            taskID: run.taskID,
            teamID: run.teamID,
            workerID: run.workerID,
            runID: run.id,
            state: .queued,
            updatedAt: Date()
        )
        guard await waitForChatExecutionSlot(worker) else { return }
        do {
            let _: OrchestrationRun = try await backend.patch(
                "/api/runs/\(run.id)/queue", body: ["action": "admit"],
                as: OrchestrationRun.self
            )
            var request: [String: Any] = [
                "type": "user_message",
                "text": Self.decoratedPrompt(
                    run.request, mode: mode, chatAttachments: [], contextFiles: [],
                    restoredTranscriptContext: nil
                ),
                "mode": mode.rawValue,
                "run_id": run.id,
            ]
            if let config = encodedJSONObject(primaryAgentBehavior) {
                request["agent_config"] = config
            }
            if run.runKind == "team" {
                guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
                      var manifest = teamManifest(for: run.request, teamID: teamID) else {
                    finishChatRuntime(
                        worker, state: .interrupted,
                        error: "The saved team configuration needs attention before resuming"
                    )
                    return
                }
                manifest["run_id"] = run.id
                request["team"] = manifest
                worker.dispatchedTeamRunID = run.id
                worker.executionState = .dispatching
            } else {
                worker.executionState = .running
                if run.isSoloSwarm {
                    request["solo_swarm"] = ["enabled": true]
                }
            }
            guard worker.service.send(request) else {
                finishChatRuntime(worker, state: .interrupted, error: "The saved run could not be delivered")
                return
            }
            worker.startedAt = Date()
            updateBackgroundChatState(worker)
        } catch {
            finishChatRuntime(worker, state: .interrupted, error: error.localizedDescription)
        }
    }

    func openActivityRun(_ run: OrchestrationRun) {
        guard let sessionID = run.sessionID,
              let session = sessions.first(where: { $0.id == sessionID })
        else { showToast("That chat is no longer available"); return }
        markActivitySeen(run)
        activityCenterPresented = false
        resume(session)
        Task { await loadOrchestrationRun(run.id) }
    }

    func openNotification(sessionID: String, runID: String) {
        activityCenterPresented = false
        if let session = sessions.first(where: { $0.id == sessionID }) {
            resume(session)
        }
        if !runID.isEmpty {
            Task { await loadOrchestrationRun(runID) }
        }
    }

    func stopActivityRun(_ run: OrchestrationRun) {
        if run.state == "queued" {
            updateQueuedRun(run, action: "cancel")
            return
        }
        if let sessionID = run.sessionID, let runtime = taskWorkers[sessionID] {
            guard runtime.service.send(["type": "interrupt"]) else {
                showToast("That chat worker could not be reached")
                return
            }
            runtime.executionState = .cancelled
            updateBackgroundChatState(runtime)
            showToast("Stopping the selected run")
            return
        }
        cancelOrchestration(run.id)
    }

    func answerActivityPermission(_ run: OrchestrationRun, decision: String) {
        guard let sessionID = run.sessionID,
              let runtime = taskWorkers[sessionID],
              let event = runtime.pendingForegroundEvent,
              event["type"] as? String == "permission_request",
              let requestID = event["request_id"] as? String,
              runtime.service.send([
                "type": "permission_decision",
                "request_id": requestID,
                "decision": decision,
              ])
        else {
            showToast("Open the chat to review this permission request")
            return
        }
        runtime.pendingForegroundEvent = nil
        runtime.executionState = .running
        updateBackgroundChatState(runtime)
        showToast(decision == "deny" ? "Permission denied" : "Permission granted")
        Task { await refreshActivityRuns() }
    }

    func publishLandedWorktree() {
        guard let task = activeTaskRecord, let branch = task.branch,
              GitRemoteFeatures.isAvailable else { return }
        let client = GitClient(workspaceRoot: task.executionPath)
        isLandingOperationRunning = true
        Task { @MainActor [weak self] in
            defer { self?.isLandingOperationRunning = false }
            do {
                let upstream = try? await client.run([
                    "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
                ])
                try await client.run(
                    GitPushPlan.arguments(
                        branch: branch,
                        upstream: upstream?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    timeout: 120
                )
                self?.showToast("Published \(branch)")
            } catch {
                self?.showToast("Publish failed; the branch and commit are safe: \(error.localizedDescription)")
            }
        }
    }

    func openLandedPullRequest() {
        guard let task = activeTaskRecord, let branch = task.branch else { return }
        let client = GitClient(workspaceRoot: task.executionPath)
        Task { @MainActor [weak self] in
            guard let remote = try? await client.run(["remote", "get-url", "origin"]),
                  let url = GitRemoteURL.githubCompareURL(
                    remote: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    branch: branch
                  ) else {
                self?.showToast("The origin remote is not a GitHub repository")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    var currentExecutionEnvironment: ChatExecutionEnvironment {
        if let raw = sessionInfo?.environment?["type"],
           let environment = ChatExecutionEnvironment(rawValue: raw) {
            return environment
        }
        return activeTaskRecord == nil ? .local : .worktree
    }

    func handoffCurrentChat(to environment: ChatExecutionEnvironment) {
        guard !isBusy, !hasPendingPermission, !currentSessionID.isEmpty else {
            showToast("Wait for the current turn before handing off")
            return
        }
        guard environment != currentExecutionEnvironment else { return }
        let sessionID = currentSessionID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: SessionHandoffResponse = try await conversationBackend.post(
                    "/api/sessions/\(sessionID)/handoff",
                    body: ["environment": environment.rawValue, "base_ref": "HEAD"],
                    timeout: 120,
                    as: SessionHandoffResponse.self
                )
                sessionInfo = response.sessionInfo
                activeTaskRecord = response.task
                if let runtime = taskWorkers[sessionID] {
                    runtime.sessionInfo = response.sessionInfo
                }
                gitWorkspace.refreshStatus()
                await refreshMetadata()
                showToast(
                    environment == .worktree
                        ? "Chat moved to its worktree"
                        : "Chat and changes moved to Local"
                )
            } catch {
                showToast("Handoff left both checkouts unchanged: \(error.localizedDescription)")
            }
        }
    }

    func createBranchForActiveTask(_ rawName: String) {
        guard let task = activeTaskRecord, !isBusy, !hasPendingPermission else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskMutationResponse = try await conversationBackend.post(
                    "/api/tasks/\(task.id)/branch",
                    body: ["branch": name],
                    as: TaskMutationResponse.self
                )
                activeTaskRecord = response.task
                sessionInfo = sessionInfo?.replacingTask(response.task)
                gitWorkspace.refreshBranch()
                showToast("Created branch \(name) in the worktree")
            } catch {
                showToast("Could not create branch: \(error.localizedDescription)")
            }
        }
    }

    func restoreActiveTaskCheckout() {
        guard let task = activeTaskRecord, !isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskMutationResponse = try await conversationBackend.post(
                    "/api/tasks/\(task.id)/restore",
                    body: [:],
                    timeout: 120,
                    as: TaskMutationResponse.self
                )
                activeTaskRecord = response.task
                showToast("Worktree restored")
            } catch {
                showToast("Could not restore the worktree: \(error.localizedDescription)")
            }
        }
    }

    func restoreWorktree(for session: SessionSummary) {
        guard let task = session.task else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: TaskMutationResponse = try await backend.post(
                    "/api/tasks/\(task.id)/restore",
                    body: [:],
                    timeout: 120,
                    as: TaskMutationResponse.self
                )
                await refreshMetadata()
                showToast("Worktree restored")
            } catch {
                showToast("Could not restore worktree: \(error.localizedDescription)")
            }
        }
    }

    func copyActiveTaskPatch() {
        guard let task = activeTaskRecord else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: TaskDetailResponse = try await backend.get(
                    "/api/tasks/\(task.id)",
                    as: TaskDetailResponse.self
                )
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(response.patch, forType: .string)
                showToast("Copied task patch")
            } catch {
                showToast("Could not copy the task patch: \(error.localizedDescription)")
            }
        }
    }

    func openActiveTaskCheckout() {
        guard let path = activeTaskRecord?.executionPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func revealActiveTaskCheckout() {
        guard let path = activeTaskRecord?.executionPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    /// Adds or updates an account. The key is written here rather than in the
    /// editor so an abandoned sheet leaves nothing behind; `apiKey` nil means
    /// "keep the saved one".
    @discardableResult
    func saveProviderAccount(_ account: ProviderAccount, apiKey: String?) -> Bool {
        if account.kind != .chatGPT {
            let effectiveKey = apiKey ?? CredentialStore.get(account: account.credentialAccount) ?? ""
            if let error = RemoteEndpointTester.securityError(
                baseURL: account.resolvedBaseURL,
                apiKey: effectiveKey
            ) {
                showToast(error)
                return false
            }
        }
        var updated = account
        updated.name = ProviderAccountStore.uniqueName(
            account.name,
            kind: account.kind,
            existing: providerAccounts,
            excluding: account.id
        )
        // Write the credential before publishing the account. Otherwise a disk
        // or permission failure produces a convincing "Saved" account whose
        // key never survived, and closing the editor loses the only copy the
        // user may have of a one-time key.
        if let apiKey, updated.kind.requiresAPIKey,
           !providerCredentialWriter(apiKey, updated.credentialAccount)
        {
            showToast("Could not save the API key to \(CredentialStore.displayPath)")
            return false
        }
        if let index = providerAccounts.firstIndex(where: { $0.id == updated.id }) {
            providerAccounts[index] = updated
        } else {
            providerAccounts.append(updated)
        }
        persistProviderAccounts()
        forgetAccountCatalog(updated.id)
        Task {
            await refreshAccountCatalogs(force: true)
            // The live agent is holding the old endpoint or key until it is
            // told otherwise.
            if updated.id.uuidString == settings.activeAccountID {
                await applyProvider(announce: false)
            }
        }
        showToast("Saved \(updated.displayName)")
        return true
    }

    /// Removes an account, its key, and — if it was the one in use — the
    /// routing that depended on it.
    func removeProviderAccount(_ account: ProviderAccount) {
        providerAccounts.removeAll { $0.id == account.id }
        CredentialStore.remove(account: account.credentialAccount)
        persistProviderAccounts()
        forgetAccountCatalog(account.id)
        guard account.id.uuidString == settings.activeAccountID else {
            showToast("Removed \(account.displayName)")
            return
        }
        if isBusy {
            pendingProviderSwitch = (nil, "")
            showToast("Removed \(account.displayName) — local Ollama takes over after this turn")
        } else {
            applyProviderSwitch(accountID: nil, model: "")
            showToast("Removed \(account.displayName) — using local Ollama")
        }
    }

    /// Deletes the stored key. When it belongs to the account in use the
    /// agent is told at once: it holds the key in memory, so leaving it be
    /// would keep spending a credential the user just revoked.
    func removeProviderAccountKey(_ account: ProviderAccount) {
        CredentialStore.remove(account: account.credentialAccount)
        accountStatus[account.id] = .noKey
        forgetAccountCatalog(account.id)
        guard account.id.uuidString == settings.activeAccountID else { return }
        // Sends an empty key, which the agent treats as "clear it". Held until
        // the turn finishes when one is running, because /api/provider refuses
        // mid-turn — and a dropped revocation is the one failure here that
        // costs the user money.
        if isBusy {
            pendingProviderSwitch = (account.id, account.preferredModel)
            showToast("Key removed — the agent drops it when this turn finishes")
        } else {
            Task { await applyProvider(announce: false) }
        }
    }

    /// Records that the endpoint rejected this account's key, so Settings and
    /// the picker can say so instead of leaving the user to guess.
    func noteAccountKeyRejected() {
        guard let account = activeAccount else { return }
        accountStatus[account.id] = .keyRejected
    }

    func activateInstalledModel(_ reference: String) async {
        await refreshMetadata()
        let lowerReference = reference.lowercased()
        // Ollama lists HF pulls as "hf.co/owner/repo:QUANT". Prefer the exact
        // name, then the owner-qualified repository, and only fall back to the
        // bare repo name when it matches a single installed model.
        let repoID = lowerReference
            .replacingOccurrences(of: "hf.co/", with: "")
            .split(separator: ":")
            .first.map(String.init) ?? lowerReference
        let repoName = repoID.split(separator: "/").last.map(String.init) ?? repoID
        var match = models.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
            ?? models.first { $0.name.lowercased().contains(repoID) }
        if match == nil {
            let candidates = models.filter { $0.name.lowercased().contains(repoName) }
            match = candidates.count == 1 ? candidates.first : nil
        }
        guard let match else {
            showToast("Model installed — refresh the model list to select it")
            return
        }
        selectModel(match.name)
        switch HuggingFaceVariant.fit(
            bytes: match.size,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        ) {
        case .fits:
            showToast("Installed and selected \(match.name)")
        case .tight:
            showToast("Installed \(match.name) — it will use most of this Mac's memory")
        case .exceeds:
            showToast("Installed \(match.name) — likely too large for this Mac")
        }
    }

    /// Hides an Ollama model from Locus without touching its downloaded files.
    /// The complete Ollama list stays in memory so Settings can restore it.
    func removeLocalModelFromLocus(_ model: ModelInfo) {
        guard !isLocalModelHidden(model.name) else { return }
        settings.hiddenLocalModels.append(model.name)
        settings.hiddenLocalModels.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        localModels = visibleLocalModels(in: installedLocalModels)
        if activeAccount == nil { models = localModels }
        showToast("Removed \(model.name) from Locus — it is still installed")
    }

    func restoreLocalModelToLocus(_ model: ModelInfo) {
        settings.hiddenLocalModels.removeAll {
            $0.caseInsensitiveCompare(model.name) == .orderedSame
        }
        localModels = visibleLocalModels(in: installedLocalModels)
        if activeAccount == nil { models = localModels }
        showToast("Restored \(model.name) to Locus")
    }

    /// Permanently asks Ollama to remove the model's downloaded data. The UI
    /// owns the confirmation because this operation cannot be undone by Locus.
    func deleteLocalModelFromComputer(_ model: ModelInfo) async {
        do {
            try await LocalModelManagement.delete(ollamaHost: ollamaHost, model: model.name)
        } catch {
            showToast("Could not delete \(model.name): \(error.localizedDescription)")
            return
        }

        installedLocalModels.removeAll {
            $0.name.caseInsensitiveCompare(model.name) == .orderedSame
        }
        settings.hiddenLocalModels.removeAll {
            $0.caseInsensitiveCompare(model.name) == .orderedSame
        }
        localModels = visibleLocalModels(in: installedLocalModels)
        if activeAccount == nil {
            models = localModels
            if selectedModel.caseInsensitiveCompare(model.name) == .orderedSame,
               let replacement = localModels.first
            {
                selectModel(replacement.name)
            }
        }
        showToast("Deleted \(model.name) from this Mac")
    }
}
