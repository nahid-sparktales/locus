import AppKit
import Foundation

extension AppModel {
    func configureAgentWorld() {
        agentWorld.appModel = self
        configureAgentCrewChat()
        agentWorld.configure(
            extensions: extensionsModel,
            profiles: { [weak self] in self?.agentProfiles ?? [] },
            workspace: { [weak self] in self?.workspacePath ?? "" },
            availability: { [weak self] profile in
                guard let self else { return "The agent is unavailable." }
                do { _ = try self.agentProfileProvider(profile); return nil }
                catch { return error.localizedDescription }
            },
            state: { [weak self] id in self?.agentWorldConversationState(id) ?? .init() },
            create: { [weak self] workspace, profile in
                guard let self else { throw AgentWorldError.unavailable("The agent is unavailable.") }
                return try await self.createSavedAgentConversation(profile, workspace: workspace).id
            },
            load: { [weak self] id in
                guard let self else { throw CancellationError() }
                let detail = try await self.backend.get("/api/sessions/\(id)", as: SessionDetailResponse.self)
                guard detail.archived != true else { throw AgentWorldError.conversationUnavailable("This conversation is archived.") }
                self.splitPaneBlocks[id] = ChatTranscriptBuilder.blocks(from: detail.messages)
            },
            activity: { [weak self] profile, workspace in
                if let activity = self?.agentWorldSavedChatActivity(profileID: profile.id, workspace: workspace) { return activity }
                if let activity = self?.agentCrewChat.activity(for: profile.id, workspace: workspace), activity.busy { return activity }
                guard let self, SessionSummary.canonicalWorkspacePath(self.workspacePath) == workspace,
                      let activity = self.teamRunLive.agentActivities.first(where: {
                          $0.id.caseInsensitiveCompare(profile.id.uuidString) == .orderedSame && !$0.state.isTerminal
                      }) else { return nil }
                let needsAttention: Bool = [.waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused].contains(activity.state)
                return .init(status: needsAttention ? "needs_attention" : "working", detail: "Active in another Locus task", busy: true)
            },
            dispatch: { [weak self] sessionID, workspace, profileID, text, mode in
                guard let self else { throw AgentWorldError.unavailable("The agent is unavailable.") }
                try await self.sendAgentWorldTurn(sessionID: sessionID, workspace: workspace, profileID: profileID, text: text, mode: mode)
            },
            stop: { [weak self] id in self?.stopGoalTurn(sessionID: id) },
            open: { [weak self] id in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshMetadata()
                    guard let session = self.sessions.first(where: { $0.id == id }) else {
                        self.agentWorld.error = "This conversation is unavailable or was removed from history."
                        return
                    }
                    self.resume(session)
                    LocusApplicationDelegate.mainWindow(in: NSApp.windows)?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            },
            manage: { [weak self] in self?.settingsPage = .agents; self?.settingsPresented = true },
            defaults: persistenceEnabled ? .standard : nil
        )
    }

    /// A ship represents its agent across saved chats, including work started on
    /// the regular agent page rather than the world's most recent chat binding.
    func agentWorldSavedChatActivity(profileID: UUID, workspace: String) -> AgentWorldConversationState? {
        let priority = ["needs_attention": 0, "working": 1, "queued": 2]
        return sessions.filter {
            !$0.isArchived && $0.belongsToWorkspace(workspace) && savedAgentProfileID(for: $0.id) == profileID
        }.map { agentWorldConversationState($0.id) }
            .filter(\.busy)
            .min { (priority[$0.status] ?? 3) < (priority[$1.status] ?? 3) }
    }

    func agentWorldProfileDispatch(profileID: UUID, mode: WorkMode, sessionID: String? = nil,
                                   queuedRoute: [String: JSONValue]? = nil) throws -> TaskCapsuleDispatch {
        guard !removingSavedAgentIDs.contains(profileID) else {
            throw AgentWorldError.unavailable("This saved agent is being removed.")
        }
        guard let savedProfile = agentProfiles.first(where: { $0.id == profileID }) else {
            throw AgentWorldError.unavailable("This conversation's agent profile was removed. Choose another agent or start a regular chat.")
        }
        var profile = sessionID.map { agentChatProfile(savedProfile, sessionID: $0) } ?? savedProfile
        if let queuedRoute {
            guard queuedRoute["profile_id"]?.string.flatMap(UUID.init(uuidString:)) == profileID,
                  let name = queuedRoute["model"]?.string?.nilIfEmpty,
                  let provider = queuedRoute["provider"]?.string,
                  sessionID.flatMap({ sessionCatalog.snapshot.sessionsByID[$0] })?.isAgentEventChat != true else {
                throw AgentWorldError.unavailable("This queued chat’s saved model route is invalid.")
            }
            if provider == "ollama" {
                profile.route = .localOllama
            } else if let id = queuedRoute["provider_account_id"]?.string.flatMap(UUID.init(uuidString:)) {
                profile.route = .providerAccount(id)
            } else {
                throw AgentWorldError.unavailable("This queued chat’s saved model account is unavailable.")
            }
            profile.model = name
        }
        let route = try agentProfileProvider(profile)
        if let queuedRoute, queuedRoute["provider"]?.string != route.provider {
            throw AgentWorldError.unavailable("This queued chat’s model account changed. Choose an account and send again.")
        }
        var dispatch = TaskCapsuleDispatch(profile: profile, provider: route.provider, accountID: route.accountID,
                                          providerBody: route.body, context: [:], mode: mode)
        dispatch.profileOnly = true
        return dispatch
    }

    static func agentWorldProfileBody(_ profile: AgentProfile) -> [String: Any] {
        var value: [String: Any] = [
            "id": profile.id.uuidString, "name": profile.name, "model": profile.model,
            "role": profile.role.rawValue, "instructions": profile.instructions,
            "capabilities": profile.capabilityTags, "access_ceiling": profile.accessCeiling.rawValue,
            "timeout_seconds": profile.timeoutSeconds, "token_limit": profile.tokenLimit,
        ]
        value["behavior"] = encodedJSONObject(profile.resolvedBehavior)
        if let mode = profile.defaultMode { value["default_mode"] = mode.rawValue }
        if let policy = profile.mcpPolicy { value["mcp_policy"] = encodedJSONObject(policy) }
        return value
    }

    func agentWorldConversationState(_ sessionID: String) -> AgentWorldConversationState {
        let worker = taskWorkers[sessionID]
        let state = taskConversationStates[sessionID]?.state ?? worker?.executionState
        let question = worker?.pendingQuestion != nil || worker?.pendingBlockingQuestion != nil
            || worker?.pendingForegroundEvent != nil
        let busy = pendingChatTurns[sessionID] != nil || worker?.occupiesExecutionSlot == true || question
            || state == .queued || (sessionID == currentSessionID && (isBusy || hasPendingPermission))
        let status: String
        if question || (sessionID == currentSessionID && hasPendingPermission) { status = "needs_attention" }
        else if pendingChatTurns[sessionID] != nil && worker?.occupiesExecutionSlot != true { status = "queued" }
        else {
            switch state {
            case .running, .dispatching, .reviewing: status = "working"
            case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused: status = "needs_attention"
            case .queued: status = "queued"
            case .completed: status = "completed"
            case .failed, .interrupted: status = "failed"
            default: status = "idle"
            }
        }
        return .init(status: status, detail: taskConversationStates[sessionID]?.errorMessage ?? worker?.lastError,
                     busy: busy, blocks: paneBlocks(for: sessionID))
    }

    /// Uses the existing worker lifecycle and global admission queue, pinned to
    /// the resident's workspace and profile for every submitted turn, including
    /// an explicit model choice saved for this conversation.
    func sendAgentWorldTurn(sessionID: String, workspace: String, profileID: UUID, text: String, mode: WorkMode) async throws {
        guard [.ask, .work].contains(mode), !isShuttingDown,
              let profile = agentProfiles.first(where: { $0.id == profileID }) else {
            throw AgentWorldError.unavailable("This agent profile is unavailable.")
        }
        guard savedAgentProfileID(for: sessionID) == profileID else {
            throw AgentWorldError.unavailable("This conversation belongs to a different saved agent.")
        }
        guard pendingChatTurns[sessionID] == nil, !agentWorldConversationState(sessionID).busy else {
            throw AgentWorldError.unavailable("This conversation is still working or needs your attention in Locus.")
        }
        guard goals.goal(for: sessionID)?.status != .active else {
            throw AgentWorldError.unavailable("Pause the current goal before continuing this agent conversation.")
        }
        let dispatch = try agentWorldProfileDispatch(profileID: profile.id, mode: mode, sessionID: sessionID)
        let runID = UUID().uuidString
        let token = UUID()
        var failure: Error?
        let turn = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let detail = try await backend.get("/api/sessions/\(sessionID)", as: SessionDetailResponse.self)
                guard detail.belongsToWorkspace(workspace), detail.archived != true else {
                    throw AgentWorldError.unavailable("This conversation belongs to another project or is archived. Restore it in Locus before continuing.")
                }
                var queueBody = detail.executionQueueContext
                queueBody.merge([
                    "run_id": runID, "session_id": sessionID, "message_id": UUID().uuidString,
                    "request": text, "run_kind": "solo",
                    "solo_swarm": false,
                ]) { _, new in new }
                if let route = try await prepareAgentChatQueueRoute(dispatch, sessionID: sessionID) {
                    queueBody["agent_chat_route"] = route
                    queueBody["mode"] = mode.rawValue
                }
                let _: OrchestrationRun = try await backend.post("/api/runs/queue", body: queueBody, as: OrchestrationRun.self)
                let previous = taskConversationStates[sessionID]
                taskConversationStates[sessionID] = TaskConversationState(
                    sessionID: sessionID, taskID: previous?.taskID, teamID: nil,
                    workerID: previous?.workerID, runID: runID, state: .queued, updatedAt: Date())
                try Task.checkCancellation()
                guard let worker = await ensureChatWorker(for: sessionID, workspaceRoot: detail.workspaceRoot?.nilIfEmpty ?? detail.cwd ?? workspace,
                    provider: dispatch.provider, providerAccountID: dispatch.accountID, model: dispatch.profile.model) else {
                    throw AgentWorldError.unavailable("This agent's worker could not connect. Reconnect its account and try again.")
                }
                guard worker.sessionID == sessionID else { throw AgentWorldError.unavailable("The conversation changed while connecting. Reopen it before sending.") }
                worker.lastError = nil
                worker.dispatchedMode = mode; worker.dispatchedTeamRunID = nil
                worker.dispatchedInPlanMode = false; worker.reservedRunID = runID
                guard await waitForChatExecutionSlot(worker) else { throw CancellationError() }
                try Task.checkCancellation()
                // Set the restoration marker before setup so a partial failure
                // cannot leak this route into an ordinary Locus conversation.
                worker.hasCapsuleProviderOverride = true
                _ = try await prepareChatWorkerCapsuleRoute(using: worker.service, capsuleDispatch: dispatch,
                                                           restoringOverride: true, ordinaryProviderBody: [:])
                let _: OrchestrationRun = try await backend.patch("/api/runs/\(runID)/queue", body: ["action": "admit"], as: OrchestrationRun.self)
                try Task.checkCancellation()
                let request: [String: Any] = [
                    "type": "user_message", "text": text, "mode": mode.rawValue,
                    "request_id": runID, "run_id": runID,
                    "agent_profile": Self.agentWorldProfileBody(dispatch.profile),
                    "agent_config": encodedJSONObject(dispatch.profile.resolvedBehavior) ?? [:],
                ]
                if currentSessionID == sessionID {
                    blocks.append(ChatBlock(kind: .user, text: text))
                }
                worker.prepareForTurnAcceptance(runID)
                guard worker.service.send(request), await waitForTurnAcceptance(runID, from: worker) else {
                    let recovered = await recoverUnacknowledgedDispatch(runID: runID, sessionID: sessionID,
                                                                        worker: worker, eventDeliveryID: nil)
                    if recovered { throw AgentWorldError.unavailable("The agent did not accept this message. It is ready to retry.") }
                    // Recovery lost its race with durable acceptance: retain the
                    // running task and do not invite duplicate submission.
                    return
                }
                refreshSplitPane(sessionID)
                await refreshMetadata()
            } catch {
                failure = error
                if let worker = taskWorkers[sessionID] {
                    finishChatRuntime(worker, state: error is CancellationError ? .cancelled : .failed, error: error.localizedDescription)
                } else {
                    let previous = taskConversationStates[sessionID]
                    taskConversationStates[sessionID] = TaskConversationState(
                        sessionID: sessionID, taskID: previous?.taskID, teamID: nil,
                        workerID: previous?.workerID, runID: runID,
                        state: error is CancellationError ? .cancelled : .failed, updatedAt: Date(), errorMessage: error.localizedDescription)
                }
                if currentSessionID == sessionID { isBusy = false; turnStartedAt = nil; turnDispatchedMode = nil }
                _ = try? await backend.patch("/api/runs/\(runID)/queue", body: ["action": "cancel"], as: OrchestrationRun.self)
            }
        }
        pendingChatTurnTokens[sessionID] = token
        pendingChatTurns[sessionID] = turn
        if currentSessionID == sessionID { isBusy = true; turnStartedAt = Date(); turnDispatchedMode = mode }
        await withTaskCancellationHandler(operation: { await turn.value }, onCancel: { turn.cancel() })
        if pendingChatTurnTokens[sessionID] == token {
            pendingChatTurnTokens[sessionID] = nil; pendingChatTurns[sessionID] = nil
        }
        if let failure { throw failure }
        try Task.checkCancellation()
    }
}
