import Foundation

/// Composition of durable goals with ordinary session workers. GoalModel owns
/// feature state; this adapter supplies account resolution and chat admission.
extension AppModel {
    func configureGoals() {
        goals.configure(
            backend: backend,
            canContinue: { [weak self] goal in self?.canContinueGoal(goal) == true },
            dispatch: { [weak self] goal, run in
                guard let self else { return false }
                return await self.dispatchGoal(goal, run: run)
            },
            stopTurn: { [weak self] sessionID in self?.stopGoalTurn(sessionID: sessionID) },
            prepareResume: { [weak self] sessionID in
                guard let self else { return }
                self.splitPaneModes[sessionID] = .work
                if self.currentSessionID == sessionID { self.selectedMode = .work }
                self.drainGoalQueuedMessages(sessionID: sessionID)
            },
            notify: { [weak self] goal in
                guard let self else { return }
                if goal.status == .completed {
                    self.notifyTurnCompleteIfInactive(sessionID: goal.sessionID, runID: goal.currentRunID)
                } else {
                    self.notifyNeedsAttentionIfInactive(
                        body: goal.reason?.nilIfEmpty ?? "A goal needs your attention.",
                        sessionID: goal.sessionID, runID: goal.currentRunID
                    )
                }
            },
            isShuttingDown: { [weak self] in self?.isShuttingDown ?? true }
        )
    }

    var canStartGoal: Bool {
        backendCapabilities["persistent_goals_v1"] == true && canAcceptTranscriptInput
            && !currentSessionID.isEmpty && !isIdentityTask && !isBusy && !hasPendingPermission
            && taskCapsules.activeStageSessions[currentSessionID] == nil
            && taskCapsules.pendingPlanningRequest(for: currentSessionID) == nil
            && sessions.first(where: { $0.id == currentSessionID })?.isAgentChat != true
    }

    func presentGoalEditor() {
        guard canStartGoal else { return }
        var execution: [String: Any] = [
            "workspace_root": sessionInfo?.workspaceRoot ?? workspacePath,
            "execution_path": activeTaskRecord?.executionPath ?? workspacePath,
            "execution_environment": currentExecutionEnvironment.rawValue,
            "provider": activeAccount.map { $0.kind.backendProvider } ?? "ollama",
            "model": activeAccount.map { routedModel(for: $0) } ?? selectedModel,
            "runner": selectedAgentTeam == nil ? "solo" : "team",
            "solo_swarm": true,
        ]
        if let account = activeAccount { execution["provider_account_id"] = account.id.uuidString }
        if let behavior = encodedJSONObject(primaryAgentBehavior) { execution["agent_config"] = behavior }
        if let team = selectedAgentTeam {
            guard teamManifest(for: "", teamID: team.id) != nil else { return }
            execution["team_id"] = team.id.uuidString
            execution["team_name"] = team.name
            execution["team_configuration"] = goalTeamConfiguration(team)
        }
        goals.open(sessionID: currentSessionID, objective: draftText, execution: execution,
                   routeLabel: selectedAgentTeam?.name ?? execution["model"] as? String ?? "Solo")
    }

    func canContinueGoal(_ goal: PersistentGoal) -> Bool {
        guard !isShuttingDown, isAgentOnline, goal.status == .active,
              pendingChatTurns[goal.sessionID] == nil,
              taskCapsules.activeStageSessions[goal.sessionID] == nil,
              taskCapsules.pendingPlanningRequest(for: goal.sessionID) == nil else { return false }
        if goal.sessionID == currentSessionID {
            guard canAcceptTranscriptInput, selectedMode == .work, !isBusy,
                  !hasPendingPermission, !planApprovalPending, pendingBlockingQuestion == nil,
                  pendingUserQuestion == nil, queuedMessages.isEmpty, pendingStopAndSend == nil else { return false }
        }
        if let worker = taskWorkers[goal.sessionID] {
            guard !worker.occupiesExecutionSlot, worker.acceptsNewTurns,
                  worker.queuedMessages.isEmpty, worker.pendingQuestion == nil,
                  worker.pendingBlockingQuestion == nil, worker.pendingForegroundEvent == nil else { return false }
        }
        return true
    }

    private func dispatchGoal(_ goal: PersistentGoal, run: OrchestrationRun) async -> Bool {
        guard canContinueGoal(goal) else { return false }
        if let issue = goalExecutionIssue(goal) {
            await goals.block(sessionID: goal.sessionID, reason: issue)
            return false
        }
        if run.runKind == "team", ["paused", "interrupted"].contains(run.state) {
            return await resumeGoalTeam(goal, run: run)
        }
        await dispatchPersistedQueuedRun(run)
        return taskWorkers[goal.sessionID]?.reservedRunID == run.id
            && taskWorkers[goal.sessionID]?.lastError == nil
    }

    private func resumeGoalTeam(_ goal: PersistentGoal, run: OrchestrationRun) async -> Bool {
        guard let teamID = run.teamID.flatMap(UUID.init(uuidString:)),
              let manifest = teamManifest(for: run.request, teamID: teamID),
              let worker = await ensureChatWorker(
                for: goal.sessionID, workspaceRoot: run.workspaceRoot ?? "",
                provider: goal.execution["provider"]?.string,
                providerAccountID: goal.execution["provider_account_id"]?.string,
                model: goal.execution["model"]?.string
              ) else { return false }
        guard !Task.isCancelled else { return false }
        var resumed = false
        defer {
            if !resumed, worker.reservedRunID == run.id,
               taskConversationStates[goal.sessionID]?.runID == run.id {
                finishChatRuntime(worker, state: .interrupted, error: worker.lastError)
                clearUndispatchedGoalPresentation(sessionID: goal.sessionID, runID: run.id)
            }
        }
        worker.reservedRunID = run.id
        worker.lastError = nil
        worker.dispatchedTeamRunID = run.id
        worker.dispatchedMode = .work
        worker.executionState = .queued
        prepareGoalTurnPresentation(sessionID: goal.sessionID, run: run)
        guard await waitForChatExecutionSlot(worker) else { return false }
        do {
            if let issue = await prepareChatWorkerProvider(using: worker.service,
                provider: goal.execution["provider"]?.string,
                providerAccountID: goal.execution["provider_account_id"]?.string,
                model: goal.execution["model"]?.string) {
                throw NSError(domain: "PersistentGoal", code: 409,
                              userInfo: [NSLocalizedDescriptionKey: issue])
            }
            guard !Task.isCancelled else {
                finishChatRuntime(worker, state: .interrupted)
                return false
            }
            let assessment = try await worker.service.post(
                "/api/orchestrations/\(run.id)/recovery-assessment", body: ["manifest": manifest],
                as: RunRecoveryAssessment.self
            )
            guard assessment.canResume else {
                await goals.block(sessionID: goal.sessionID,
                                  reason: assessment.repairChecklist.first ?? "The team checkpoint needs attention.")
                finishChatRuntime(worker, state: .interrupted)
                return false
            }
            worker.executionState = .dispatching
            let _: OrchestrationMutationResponse = try await worker.service.post(
                "/api/orchestrations/\(run.id)/resume", body: ["manifest": manifest],
                as: OrchestrationMutationResponse.self
            )
            resumed = true
            updateBackgroundChatState(worker)
            return true
        } catch {
            finishChatRuntime(worker, state: .interrupted, error: error.localizedDescription)
            return false
        }
    }

    func prepareGoalTurnPresentation(sessionID: String, run: OrchestrationRun) {
        let previous = taskConversationStates[sessionID]
        taskConversationStates[sessionID] = TaskConversationState(
            sessionID: sessionID, taskID: run.taskID ?? previous?.taskID,
            teamID: run.teamID, workerID: run.workerID ?? previous?.workerID,
            runID: run.id, state: .queued, updatedAt: Date()
        )
        guard currentSessionID == sessionID else { return }
        isBusy = true
        turnStartedAt = Date()
        turnDispatchedMode = .work
        turnDispatchedInPlanMode = false
        turnDispatchedTeamRunID = run.runKind == "team" ? run.id : nil
    }

    func clearUndispatchedGoalPresentation(sessionID: String, runID: String) {
        guard currentSessionID == sessionID, taskConversationStates[sessionID]?.runID == runID else { return }
        isBusy = false
        turnStartedAt = nil
        turnDispatchedMode = nil
        turnDispatchedTeamRunID = nil
        guard !isShuttingDown else { return }
        Task { @MainActor [weak self] in self?.drainQueuedMessages() }
    }

    func goalExecutionIssue(_ goal: PersistentGoal) -> String? {
        let execution = goal.execution
        let workspace = execution["workspace_root"]?.string ?? ""
        guard !workspace.isEmpty, FileManager.default.fileExists(atPath: workspace),
              workspaceAccess.activateStored(path: workspace) else { return "The goal's workspace is unavailable." }
        if let path = execution["execution_path"]?.string,
           !FileManager.default.fileExists(atPath: path) { return "The goal's checkout is unavailable." }
        if execution["provider"]?.string != "ollama" {
            guard let rawID = execution["provider_account_id"]?.string,
                  let id = UUID(uuidString: rawID),
                  let account = providerAccounts.first(where: { $0.id == id }),
                  account.isCredentialReady(in: credentialStore) else { return "The goal's model account is unavailable." }
            let kind = account.kind.backendProvider
            guard execution["provider"]?.string == kind else { return "The goal's model account changed." }
        }
        if execution["runner"]?.string == "team" {
            guard let id = execution["team_id"]?.string.flatMap(UUID.init(uuidString:)),
                  let team = agentTeams.first(where: { $0.id == id }) else { return "The goal's team is unavailable." }
            if let saved = execution["team_configuration"]?.string,
               saved != goalTeamConfiguration(team) { return "The goal's team configuration changed. Edit the goal before resuming." }
            if let error = AgentTeamValidation.routeErrors(team: team, profiles: agentProfiles,
                    accounts: providerAccounts, accountModels: accountModels).first { return error }
        }
        return nil
    }

    private func goalTeamConfiguration(_ team: AgentTeam) -> String {
        // Profiles carry account references, never account credentials.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Configuration: Encodable { let team: AgentTeam; let profiles: [AgentProfile] }
        let value = Configuration(team: team, profiles: team.memberIDs.compactMap { id in
            agentProfiles.first(where: { $0.id == id })
        })
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func pauseGoalForModeChange() {
        guard canAcceptTranscriptInput, !isRestoringManualModelRoute,
              goals.goal(for: currentSessionID)?.status == .active else { return }
        let sessionID = currentSessionID
        goals.suspend(sessionID: sessionID)
        Task { [weak self] in
            guard let self, await self.goals.pause(sessionID: sessionID, reason: "Work mode changed.") else { return }
            self.stopGoalTurn(sessionID: sessionID)
        }
    }

    func pauseGoalForRouteChange() {
        guard canAcceptTranscriptInput, !isRestoringManualModelRoute,
              goals.goal(for: currentSessionID)?.status == .active else { return }
        let sessionID = currentSessionID
        goals.suspend(sessionID: sessionID)
        Task { [weak self] in
            guard let self, await self.goals.pause(sessionID: sessionID,
                reason: "The selected agent changed. Use Goal to save the new configuration, then Resume.") else { return }
            self.stopGoalTurn(sessionID: sessionID)
        }
    }

    func stopGoalTurn(sessionID: String) {
        if sessionID == currentSessionID {
            guard isBusy || pendingChatTurns[sessionID] != nil || hasPendingPermission else { return }
            stop(persistingGoalPause: false)
        } else {
            pendingChatTurns[sessionID]?.cancel()
            if let worker = taskWorkers[sessionID], worker.occupiesExecutionSlot {
                _ = worker.service.send(["type": "interrupt"])
            }
        }
    }

    /// Background goals drain only already-submitted text from their own
    /// worker. The selected chat's draft, attachments and route are unrelated.
    func drainGoalQueuedMessages(sessionID: String) {
        guard !isShuttingDown, isAgentOnline,
              !goals.isDiscardingUserInput(sessionID: sessionID),
              goals.goal(for: sessionID)?.status == .active else { return }
        if currentSessionID == sessionID {
            drainQueuedMessages()
            return
        }
        guard pendingChatTurns[sessionID] == nil, let worker = taskWorkers[sessionID],
              worker.acceptsNewTurns, !worker.occupiesExecutionSlot,
              worker.pendingQuestion == nil, worker.pendingBlockingQuestion == nil,
              worker.pendingForegroundEvent == nil, let text = worker.queuedMessages.first else { return }
        let token = UUID()
        pendingChatTurnTokens[sessionID] = token
        pendingChatTurns[sessionID] = Task { @MainActor [weak self, weak worker] in
            guard let self, let worker else { return }
            defer {
                if pendingChatTurnTokens[sessionID] == token {
                    pendingChatTurns[sessionID] = nil
                    pendingChatTurnTokens[sessionID] = nil
                }
                goals.wake()
            }
            guard let goal = await goals.flushUserInput(sessionID: sessionID),
                  goal.status == .active, !Task.isCancelled else { return }
            if let issue = goalExecutionIssue(goal) {
                await goals.block(sessionID: sessionID, reason: issue)
                return
            }
            let inputID = goals.takeUserInput(sessionID: sessionID, text: text)
            var body: [String: Any] = [
                "run_id": UUID().uuidString, "session_id": sessionID,
                "request": text, "goal_id": goal.id, "goal_revision": goal.revision,
            ]
            if let inputID { body["goal_input_id"] = inputID }
            let run: OrchestrationRun
            do {
                run = try await backend.post("/api/runs/queue", body: body, as: OrchestrationRun.self)
            } catch {
                if let inputID { goals.restoreUserInput(sessionID: sessionID, text: text, inputID: inputID) }
                await goals.block(sessionID: sessionID, reason: "The queued instructions could not be saved: \(error.localizedDescription)")
                return
            }
            if worker.queuedMessages.first == text { worker.queuedMessages.removeFirst() }
            paneState(containing: sessionID)?.queuedMessages = worker.queuedMessages
            if currentSessionID == sessionID { queuedMessages = worker.queuedMessages }
            guard !Task.isCancelled else { return }
            await dispatchPersistedQueuedRun(run)
            if worker.lastError != nil {
                await goals.block(sessionID: sessionID, reason: worker.lastError ?? "The queued goal turn could not start.")
            }
        }
    }
}
