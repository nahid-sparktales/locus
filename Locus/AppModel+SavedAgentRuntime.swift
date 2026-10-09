import Foundation

extension AppModel {
    func configureSavedAgentRuntime() {
        configureAgentCrewChat()
        savedAgentConversations.configure(defaults: persistenceEnabled ? .standard : nil,
            state: { [weak self] in self?.savedAgentConversationState($0) ?? .init() },
            create: { [weak self] workspace, profile in
                guard let self else { throw CancellationError() }
                return try await self.createSavedAgentConversation(profile, workspace: workspace).id
            },
            dispatch: { [weak self] sessionID, workspace, profileID, text, mode in
                guard let self else { throw CancellationError() }
                try await self.sendSavedAgentTurn(sessionID: sessionID, workspace: workspace, profileID: profileID, text: text, mode: mode)
            })
    }

    /// Activity across canonical saved-agent chats in the selected workspace.
    func savedAgentChatActivity(profileID: UUID, workspace: String) -> SavedAgentConversationState? {
        let priority = ["needs_attention": 0, "working": 1, "queued": 2]
        return sessions.filter {
            !$0.isArchived && $0.belongsToWorkspace(workspace) && savedAgentProfileID(for: $0.id) == profileID
        }.map { savedAgentConversationState($0.id) }
            .filter(\.busy)
            .min { (priority[$0.status] ?? 3) < (priority[$1.status] ?? 3) }
    }

    func savedAgentProfileDispatch(profileID: UUID, mode: WorkMode, sessionID: String? = nil,
                                   queuedRoute: [String: JSONValue]? = nil,
                                   selectedProfile: AgentProfile? = nil) throws -> TaskCapsuleDispatch {
        guard !removingSavedAgentIDs.contains(profileID) else {
            throw SavedAgentConversationError.unavailable("This saved agent is being removed.")
        }
        guard let savedProfile = agentProfiles.first(where: { $0.id == profileID }) else {
            throw SavedAgentConversationError.unavailable("This conversation's agent profile was removed. Choose another agent or start a regular chat.")
        }
        if queuedRoute == nil, selectedProfile == nil, let sessionID, let retained = chatModelRoute(for: sessionID) {
            _ = try chatModelProviderBody(retained)
        }
        var profile = selectedProfile ?? sessionID.map { agentChatProfile(savedProfile, sessionID: $0) } ?? savedProfile
        if let queuedRoute {
            guard queuedRoute["profile_id"]?.string.flatMap(UUID.init(uuidString:)) == profileID,
                  let name = queuedRoute["model"]?.string?.nilIfEmpty,
                  let provider = queuedRoute["provider"]?.string,
                  sessionID.flatMap({ sessionCatalog.snapshot.sessionsByID[$0] })?.isAgentEventChat != true else {
                throw SavedAgentConversationError.unavailable("This queued chat’s saved model route is invalid.")
            }
            if provider == "ollama" {
                profile.route = .localOllama
            } else if let id = queuedRoute["provider_account_id"]?.string.flatMap(UUID.init(uuidString:)) {
                profile.route = .providerAccount(id)
            } else {
                throw SavedAgentConversationError.unavailable("This queued chat’s saved model account is unavailable.")
            }
            profile.model = name
        }
        let route = try agentProfileProvider(profile)
        if let queuedRoute, queuedRoute["provider"]?.string != route.provider {
            throw SavedAgentConversationError.unavailable("This queued chat’s model account changed. Choose an account and send again.")
        }
        var dispatch = TaskCapsuleDispatch(profile: profile, provider: route.provider, accountID: route.accountID,
                                          providerBody: route.body, context: [:],
                                          mode: sessionID.map { conversationMode(mode, sessionID: $0) } ?? mode)
        dispatch.profileOnly = true
        return dispatch
    }

    static func savedAgentProfileBody(_ profile: AgentProfile) -> [String: Any] {
        var value: [String: Any] = [
            "id": profile.id.uuidString, "name": profile.name, "model": profile.model,
            "role": profile.role.rawValue, "instructions": profile.instructions,
            "capabilities": profile.capabilityTags, "access_ceiling": profile.accessCeiling.rawValue,
            "timeout_seconds": profile.timeoutSeconds, "token_limit": profile.tokenLimit,
        ]
        value["behavior"] = encodedJSONObject(profile.resolvedBehavior)
        if let choices = profile.additionalModels, !choices.isEmpty { value["model_choices"] = choices.compactMap { encodedJSONObject($0) } }
        if let mode = profile.defaultMode { value["default_mode"] = mode.rawValue }
        if let policy = profile.mcpPolicy { value["mcp_policy"] = encodedJSONObject(policy) }
        return value
    }

    func savedAgentConversationState(_ sessionID: String) -> SavedAgentConversationState {
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

    /// Installed or remote runtimes may outlive an app update. Older runtimes
    /// expose the same authoritative routing fields only through session detail.
    func loadSavedAgentConversationMetadata(sessionID: String) async throws -> SavedAgentConversationMetadata {
        do {
            return try await backend.get("/api/sessions/\(sessionID)/execution-context",
                                         as: SavedAgentConversationMetadata.self)
        } catch {
            let responseError = error as NSError
            guard responseError.domain == "Locus.Backend", [404, 405].contains(responseError.code) else {
                throw error
            }
            // Never turn a cancelled preflight into a new legacy request.
            try Task.checkCancellation()
            return try await backend.get("/api/sessions/\(sessionID)", as: SavedAgentConversationMetadata.self)
        }
    }

    /// Uses the existing worker lifecycle and global admission queue, pinned to
    /// the resident's workspace and profile for every submitted turn, including
    /// an explicit model choice saved for this conversation.
    func sendSavedAgentTurn(sessionID: String, workspace: String, profileID: UUID, text: String, mode: WorkMode, runID: String = UUID().uuidString,
                            preservingForeground: Bool = false, attachments: [ChatAttachment] = [],
                            validatedSession: SavedAgentConversationMetadata? = nil) async throws {
        let companionTurn = usesCompanionContext(sessionID: sessionID, profileID: profileID)
        let mode: WorkMode = companionTurn ? .ask : mode
        guard [.ask, .work].contains(mode), !isShuttingDown,
              let profile = agentProfiles.first(where: { $0.id == profileID }) else {
            throw SavedAgentConversationError.unavailable("This agent profile is unavailable.")
        }
        guard savedAgentProfileID(for: sessionID) == profileID else {
            throw SavedAgentConversationError.unavailable("This conversation belongs to a different saved agent.")
        }
        guard pendingChatTurns[sessionID] == nil, pendingChatTurnTokens[sessionID] == nil,
              !savedAgentConversationState(sessionID).busy else {
            throw SavedAgentConversationError.unavailable("This conversation is still working or needs your attention in Locus.")
        }
        guard goals.goal(for: sessionID)?.status != .active else {
            throw SavedAgentConversationError.unavailable("Pause the current goal before continuing this agent conversation.")
        }
        let token = UUID()
        pendingChatTurnTokens[sessionID] = token
        defer {
            if pendingChatTurnTokens[sessionID] == token {
                pendingChatTurnTokens[sessionID] = nil
                pendingChatTurns[sessionID] = nil
            }
        }
        let chosen: AgentProfile?
        if !hasManualChatModelSelection(sessionID: sessionID), profile.resolvedModelChoices.count > 1 {
            chosen = await prepareAgentModelChoice(profile: profile, sessionID: sessionID, text: text, mode: mode,
                requiresVision: attachments.contains { $0.kind == .image || $0.kind == .applicationSnapshot })
        } else { chosen = nil }
        try Task.checkCancellation()
        let dispatch = try savedAgentProfileDispatch(profileID: profile.id, mode: mode, sessionID: sessionID, selectedProfile: chosen)
        let agentChoices = agentModelChoicesForDispatch(dispatch, sessionID: sessionID)
        let payload = attachments.isEmpty ? text : Self.decoratedPrompt(text, mode: mode,
            chatAttachments: attachments, contextFiles: [], restoredTranscriptContext: nil, companionContext: companionTurn)
        let imageAttachments: [[String: Any]] = attachments.compactMap { attachment in
            guard attachment.isAvailable, attachment.kind != .text,
                  let data = attachment.imageData, let mime = attachment.mimeType else { return nil }
            return ["name": attachment.name, "mime_type": mime, "data": data.base64EncodedString()]
        }
        let allowsSpecialists = profileID == primaryCompanionProfile?.id && mode == .work
        var failure: Error?
        var accepted = false
        let turn = Task { @MainActor [weak self] in
            guard let self else { return }
            var provisionalForegroundBlockID: UUID?
            do {
                let detail: SavedAgentConversationMetadata
                if let validatedSession { detail = validatedSession }
                else { detail = try await loadSavedAgentConversationMetadata(sessionID: sessionID) }
                try Task.checkCancellation()
                guard detail.matches(sessionID: sessionID, profileID: profileID, workspace: workspace) else {
                    throw SavedAgentConversationError.unavailable("This conversation belongs to another agent or project, or is archived. Restore it in Locus before continuing.")
                }
                var queueBody = detail.executionQueueContext
                queueBody.merge([
                    "run_id": runID, "session_id": sessionID, "message_id": UUID().uuidString,
                    "request": payload, "run_kind": "solo",
                    "solo_swarm": allowsSpecialists,
                ]) { _, new in new }
                if let route = try await prepareAgentChatQueueRoute(dispatch, sessionID: sessionID) {
                    queueBody["agent_chat_route"] = route
                    if let agentChoices {
                        try await prepareAgentModelChoiceCredentials(agentChoices)
                        queueBody["agent_model_choices"] = agentChoices.map(\.wireValue)
                    }
                    queueBody["mode"] = mode.rawValue
                    if companionTurn { queueBody["companion_context"] = true }
                }
                try Task.checkCancellation()
                let _: OrchestrationRun = try await backend.post("/api/runs/queue", body: queueBody, as: OrchestrationRun.self)
                retainAcceptedChatRoute(ChatModelRoute(model: dispatch.profile.model, provider: dispatch.provider,
                    accountID: dispatch.accountID.flatMap(UUID.init(uuidString:)), profileID: profileID,
                    selection: hasManualChatModelSelection(sessionID: sessionID) ? "manual" : "automatic"), sessionID: sessionID)
                let previous = taskConversationStates[sessionID]
                taskConversationStates[sessionID] = TaskConversationState(
                    sessionID: sessionID, taskID: previous?.taskID, teamID: nil,
                    workerID: previous?.workerID, runID: runID, state: .queued, updatedAt: Date())
                try Task.checkCancellation()
                guard let worker = await ensureChatWorker(for: sessionID, workspaceRoot: detail.workspaceRoot?.nilIfEmpty ?? detail.cwd ?? workspace,
                    provider: dispatch.provider, providerAccountID: dispatch.accountID, model: dispatch.profile.model) else {
                    throw SavedAgentConversationError.unavailable("This agent's worker could not connect. Reconnect its account and try again.")
                }
                guard worker.sessionID == sessionID else { throw SavedAgentConversationError.unavailable("The conversation changed while connecting. Reopen it before sending.") }
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
                var request: [String: Any] = [
                    "type": "user_message", "text": payload, "mode": mode.rawValue,
                    "request_id": runID, "run_id": runID,
                    "agent_profile": Self.savedAgentProfileBody(dispatch.profile),
                    "agent_config": encodedJSONObject(dispatch.profile.resolvedBehavior) ?? [:],
                ]
                var route: [String: Any] = ["profile_id": dispatch.profile.id.uuidString,
                    "provider": dispatch.provider, "model": dispatch.profile.model]
                if let accountID = dispatch.accountID { route["provider_account_id"] = accountID }
                request["agent_chat_route"] = route
                if let agentChoices { request["agent_model_choices"] = agentChoices.map(\.wireValue) }
                if companionTurn { request["companion_context"] = true }
                if !imageAttachments.isEmpty { request["attachments"] = imageAttachments }
                if allowsSpecialists { request["solo_swarm"] = ["enabled": true] }
                if currentSessionID == sessionID,
                   !blocks.contains(where: { $0.kind == .user && $0.runID == runID }) {
                    let submitted = ChatBlock(kind: .user, text: text, runID: runID)
                    provisionalForegroundBlockID = submitted.id
                    blocks.append(submitted)
                }
                worker.prepareForTurnAcceptance(runID)
                guard worker.service.send(request), await waitForTurnAcceptance(runID, from: worker) else {
                    let recovered = await recoverUnacknowledgedDispatch(runID: runID, sessionID: sessionID,
                                                                        worker: worker, eventDeliveryID: nil)
                    if recovered { throw SavedAgentConversationError.unavailable("The agent did not accept this message. It is ready to retry.") }
                    // Recovery lost its race with durable acceptance: retain the
                    // running task and do not invite duplicate submission.
                    accepted = true
                    return
                }
                accepted = true
                refreshSplitPane(sessionID)
                if preservingForeground {
                    // Acceptance is complete; catalog decoration must not keep
                    // the companion composer in its Sending state.
                    Task { [weak self] in try? await self?.refreshCompanionConversationCatalog() }
                } else { await refreshMetadata() }
            } catch {
                failure = error
                if !accepted, let provisionalForegroundBlockID {
                    // The user may have opened or left this chat during setup.
                    // Remove only our unaccepted local row, never a restored
                    // durable message or a different foreground conversation.
                    if currentSessionID == sessionID {
                        blocks.removeAll { $0.id == provisionalForegroundBlockID }
                    }
                    splitPaneBlocks[sessionID]?.removeAll { $0.id == provisionalForegroundBlockID }
                }
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
        // A stop racing with durable acceptance must not restore an already
        // accepted message as a fresh draft and invite duplicate submission.
        if !accepted { try Task.checkCancellation() }
    }
}

/// The send preflight needs durable ownership and execution routing, not the
/// complete conversation. This matches the backend's bounded metadata endpoint.
struct SavedAgentConversationMetadata: Decodable {
    let id: String
    let agentProfileID: UUID?
    let cwd: String?
    let workspaceRoot: String?
    let executionPath: String?
    let environment: [String: String]?
    let archived: Bool?
    let task: TaskRecord?

    enum CodingKeys: String, CodingKey {
        case id, cwd, environment, archived, task
        case agentProfileID = "agent_profile_id"
        case workspaceRoot = "workspace_root"
        case executionPath = "execution_path"
    }

    func matches(sessionID: String, profileID: UUID, workspace: String) -> Bool {
        id == sessionID && agentProfileID == profileID && archived != true
            && SessionSummary.matchesWorkspace(root: workspaceRoot?.nilIfEmpty ?? cwd,
                                                environment: environment, requested: workspace)
    }

    var executionQueueContext: [String: Any] {
        var context: [String: Any] = [
            "workspace_root": workspaceRoot?.nilIfEmpty ?? cwd ?? "",
            "execution_path": executionPath?.nilIfEmpty ?? cwd ?? "",
            "execution_environment": environment?["type"] ?? (task == nil ? "local" : "worktree"),
        ]
        if let task { context["task_id"] = task.id }
        return context
    }
}
