import Foundation

extension AppModel {
    func syncSavedAgentsToRuntime() async throws {
        guard RuntimeInstallation.enabled, !isUITesting else { return }
        savedAgentRuntimeSyncPending = true
        guard !savedAgentRuntimeSyncInFlight else { return }
        savedAgentRuntimeSyncInFlight = true
        defer { savedAgentRuntimeSyncInFlight = false }
        while savedAgentRuntimeSyncPending {
            savedAgentRuntimeSyncPending = false
            let profiles: [[String: Any]] = agentProfiles.map { profile in
                var item: [String: Any] = ["profile": Self.agentWorldProfileBody(profile)]
                do {
                    let route = try agentProfileProvider(profile)
                    var provider = route.body
                    provider["model"] = profile.model
                    if route.provider == "ollama" { provider["host"] = lastOllamaHost }
                    item["provider"] = provider
                } catch { item["unavailable"] = error.localizedDescription }
                return item
            }
            let _: [String: Bool] = try await backend.post("/api/runtime/agent-profiles",
                body: ["profiles": profiles], as: [String: Bool].self)
        }
    }

    var selectedSavedAgentProfile: AgentProfile? {
        if selectedSavedAgentID == nil,
           selectedAgentID != nil || agentInspector.selectedAgent != nil { return nil }
        let id = selectedSavedAgentID ?? savedAgentProfileID(for: currentSessionID)
        return agentProfiles.first { $0.id == id }
    }

    var configuredSavedAgent: AgentProfile? {
        agentProfiles.first { $0.id == configureAgentProfileID }
    }

    func savedAgentProfileID(for sessionID: String) -> UUID? {
        sessionCatalog.snapshot.sessionsByID[sessionID]?.savedAgentProfileID
            ?? agentWorld.boundProfileID(for: sessionID)
            ?? agentCrewChat.boundProfileID(for: sessionID)
    }

    func newSavedAgentDraft() -> AgentProfile {
        let route = settings.activeAccountID.flatMap(UUID.init(uuidString:))
            .map(AgentRoute.providerAccount) ?? .localOllama
        return AgentProfile(name: "", route: route, model: selectedModel, role: .generalist,
                            instructions: "", accessCeiling: .readOnly,
                            behavior: AgentBehavior(selfDescription: "A specialist for delegated tasks."))
    }

    func presentSavedAgentEditor(_ profile: AgentProfile) {
        if configureAgentPresented {
            pendingSavedAgentEditor = profile
            configureAgentPresented = false
        } else {
            savedAgentEditor = profile
        }
    }

    func saveSidebarAgent(_ profile: AgentProfile) {
        let isNew = !agentProfiles.contains { $0.id == profile.id }
        agentTeamsModel.saveAgentProfile(profile)
        guard let saved = agentProfiles.first(where: { $0.id == profile.id }) else { return }
        savedAgentEditor = nil
        agentWorld.refresh()
        if isNew { newSavedAgentChat(saved) }
    }

    func selectSavedAgent(_ profile: AgentProfile) {
        agentCrewChatPresented = false
        selectedSavedAgentID = profile.id
        selectedAgentID = nil
        agentInspector.clearAgentSelection()
        agentInspector.show(.fleet)
        sidebarDestination = .agents
        if let chat = savedAgentChats(profile.id).first {
            resume(chat)
        } else {
            newSavedAgentChat(profile)
        }
    }

    func savedAgentChats(_ profileID: UUID) -> [SessionSummary] {
        sessionCatalog.snapshot.sessions.filter {
            $0.savedAgentProfileID == profileID && !$0.isArchived
                && agentCrewChat.boundProfileID(for: $0.id) == nil
        }.sorted { $0.mtime > $1.mtime }
    }

    func newSavedAgentChat(_ profile: AgentProfile) {
        guard creatingSavedAgentChatIDs.insert(profile.id).inserted else { return }
        let workspace = workspacePath
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { creatingSavedAgentChatIDs.remove(profile.id) }
            do {
                let session = try await createSavedAgentConversation(profile, workspace: workspace)
                guard !chatNavigationDisabled else {
                    showToast("\(profile.name)’s chat is ready in Agent.")
                    return
                }
                selectedSavedAgentID = profile.id
                selectedAgentID = nil
                agentInspector.clearAgentSelection()
                agentInspector.show(.fleet)
                configureAgentPresented = false
                sidebarDestination = .agents
                selectedMode = .work
                resume(session)
            } catch {
                showToast("Could not open \(profile.name)’s chat: \(error.localizedDescription)")
            }
        }
    }

    func createSavedAgentConversation(_ profile: AgentProfile, workspace: String) async throws -> SessionSummary {
        guard agentProfiles.contains(where: { $0.id == profile.id }) else {
            throw AgentWorldError.unavailable("This saved agent was removed.")
        }
        struct Created: Decodable { let session_id: String }
        let count = sessionCatalog.snapshot.sessions.filter { $0.savedAgentProfileID == profile.id }.count
        let response = try await backend.post("/api/sessions/detached", body: [
            "cwd": workspace, "title": "Chat \(count + 1)", "agent_profile_id": profile.id.uuidString,
        ], as: Created.self)
        agentWorld.bindConversation(response.session_id, workspace: workspace, profileID: profile.id)
        await refreshMetadata()
        guard let session = sessionCatalog.snapshot.sessionsByID[response.session_id] else {
            throw AgentWorldError.unavailable("The saved conversation could not be loaded. Refresh the agent list to reopen it.")
        }
        return session
    }

    func manageSavedAgent(_ profile: AgentProfile) {
        selectedSavedAgentID = profile.id
        presentConfigureAgent(draftText: "")
        configureAgentProfileID = profile.id
    }

    /// Automation editors capture their owner's identity and route when opened.
    /// Changing the foreground chat or model picker cannot retarget the draft.
    func presentSavedAgentAutomation(_ kind: AgentConfigurationKind, profile: AgentProfile) {
        do {
            let route = try agentProfileProvider(profile)
            if kind == .schedule {
                presentScheduleEditor(prompt: configureAgentDraftSuggestion)
                guard var draft = schedule.scheduleEditorDraft else { return }
                draft.agentProfileID = profile.id.uuidString
                draft.provider = route.provider
                draft.providerAccountID = route.accountID
                draft.model = profile.model
                draft.runner = .solo
                draft.teamID = nil
                draft.teamName = ""
                schedule.scheduleEditorDraft = draft
                return
            }
            let workspace = workspacePath
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let template: SessionSummary
                    if let existing = savedAgentChats(profile.id).first(where: {
                        $0.workspacePath == SessionSummary.canonicalWorkspacePath(workspace)
                    }) { template = existing }
                    else { template = try await createSavedAgentConversation(profile, workspace: workspace) }
                    guard configureAgentPresented, configureAgentProfileID == profile.id else { return }
                    eventAutomations.presentEditor(targetSessionID: template.id,
                        naturalLanguageRequest: configureAgentDraftSuggestion,
                        triggerKind: kind == .price ? .price : .event)
                    guard var draft = eventAutomations.editorDraft else { return }
                    draft.agentProfileID = profile.id.uuidString
                    draft.profileRoute = ["provider": route.provider, "model": profile.model,
                                          "provider_account_id": route.accountID ?? ""]
                    eventAutomations.editorDraft = draft
                } catch { showToast(error.localizedDescription) }
            }
        } catch { showToast(error.localizedDescription) }
    }
}
