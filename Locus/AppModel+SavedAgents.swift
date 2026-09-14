import AppKit
import Foundation

private struct SavedAgentCleanupResponse: Decodable {
    let ok: Bool
    let sessionIDs: [String]
    let count: Int
    let deletedActive: Bool
    let replacementSessionInfo: SessionInfo?
    let trashBatch: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, count, error
        case sessionIDs = "session_ids"
        case deletedActive = "deleted_active"
        case replacementSessionInfo = "replacement_session_info"
        case trashBatch = "trash_batch"
    }
}

extension AppModel {
    var agentHomesRoot: URL {
        if let agentHomesRootOverride { return agentHomesRootOverride }
        if !persistenceEnabled {
            return FileManager.default.temporaryDirectory.appendingPathComponent("locus-agent-homes-\(transientAgentHomesID.uuidString)")
        }
        return AppEdition.current.supportDirectory.appendingPathComponent("AgentHomes", isDirectory: true)
    }

    func savedAgentHomePath(_ profile: AgentProfile) -> String {
        agentHomesRoot.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true).path
    }

    func savedAgentWorkspacePath(_ profile: AgentProfile) -> String {
        let current = agentProfiles.first { $0.id == profile.id } ?? profile
        return current.workspacePreferences?.defaultProjectPath ?? savedAgentHomePath(current)
    }

    /// Selection is read-only: opening an overview never creates a directory.
    func savedAgentWorkspaceChoices(_ profile: AgentProfile) -> [(path: String, title: String)] {
        let current = agentProfiles.first { $0.id == profile.id } ?? profile
        let root = agentHomesRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let candidates = (profile.workspacePreferences?.projectPaths ?? [])
            + (current.workspacePreferences?.projectPaths ?? [])
            + workspaceProfiles.map(\.path)
            + sessions.compactMap(\.workspacePath)
        let projects = Set(candidates.filter { $0.hasPrefix("/") }.map(SessionSummary.canonicalWorkspacePath))
            .filter { $0 != root && !$0.hasPrefix(root + "/") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [(savedAgentHomePath(current), "Agent home")] + projects.map {
            ($0, URL(fileURLWithPath: $0).lastPathComponent)
        }
    }

    func savedAgentWorkspaceTitle(_ profile: AgentProfile, path: String) -> String {
        path == savedAgentHomePath(profile) ? "Agent home" : URL(fileURLWithPath: path).lastPathComponent
    }

    func prepareSavedAgentWorkspace(_ profile: AgentProfile, workspace: String) throws {
        guard workspace.hasPrefix("/"), !workspace.contains("\0") else {
            throw AgentWorldError.unavailable("Choose an absolute workspace folder.")
        }
        let expectedHome = savedAgentHomePath(profile)
        let canonical = SessionSummary.canonicalWorkspacePath(workspace)
        let root = agentHomesRoot.standardizedFileURL.resolvingSymlinksInPath().path
        if workspace == expectedHome || canonical == expectedHome {
            // App-created homes must not be redirected into a project or another
            // agent's files by a directory symlink.
            guard URL(fileURLWithPath: expectedHome).resolvingSymlinksInPath().path == expectedHome else {
                throw AgentWorldError.unavailable("This agent’s home points to another folder. Restore its original folder before continuing.")
            }
            try FileManager.default.createDirectory(atPath: expectedHome, withIntermediateDirectories: true)
        } else {
            guard canonical != root, !canonical.hasPrefix(root + "/") else {
                throw AgentWorldError.unavailable("Choose a shared project or this agent’s own home.")
            }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
                throw AgentWorldError.unavailable("This project folder is unavailable. Choose its new location or use Agent home.")
            }
        }
        guard workspaceAccess.activateStored(path: canonical) else {
            throw AgentWorldError.unavailable("Choose that project folder again to restore access.")
        }
    }

    func savedAgentScheduleEnvironment(_ profile: AgentProfile, workspace: String) -> ChatExecutionEnvironment {
        guard workspace != savedAgentHomePath(profile) else { return .local }
        var folder = URL(fileURLWithPath: workspace).standardizedFileURL
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return .worktree }
            folder.deleteLastPathComponent()
        }
        return .local
    }

    func setSavedAgentDefaultWorkspace(_ profile: AgentProfile, path: String) {
        guard var current = agentProfiles.first(where: { $0.id == profile.id }) else { return }
        var preferences = current.workspacePreferences ?? AgentWorkspacePreferences()
        if path == savedAgentHomePath(profile) {
            preferences.defaultProjectPath = nil
        } else {
            do { try prepareSavedAgentWorkspace(profile, workspace: path) }
            catch { showToast(error.localizedDescription); return }
            preferences.defaultProjectPath = SessionSummary.canonicalWorkspacePath(path)
            preferences.projectPaths.append(path)
        }
        preferences.normalize()
        current.workspacePreferences = preferences
        agentTeamsModel.saveAgentProfile(current)
    }

    func unlinkSavedAgentProject(_ profile: AgentProfile, path: String) {
        guard var current = agentProfiles.first(where: { $0.id == profile.id }) else { return }
        var preferences = current.workspacePreferences ?? AgentWorkspacePreferences()
        let canonical = SessionSummary.canonicalWorkspacePath(path)
        preferences.projectPaths.removeAll { SessionSummary.canonicalWorkspacePath($0) == canonical }
        if preferences.defaultProjectPath == canonical { preferences.defaultProjectPath = nil }
        current.workspacePreferences = preferences
        agentTeamsModel.saveAgentProfile(current)
    }

    /// Picking/linking a project does not activate its chat or change the
    /// foreground workspace. The folder can be linked by several agents.
    func chooseSavedAgentProjectFolder() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a shared project"
        panel.message = "Choose an existing project, or use New Folder to create one. Other agents can use the same project."
        panel.prompt = "Use Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard workspaceAccess.rememberAndActivate(url) else {
            showToast("Locus could not retain access to that project.")
            return nil
        }
        return SessionSummary.canonicalWorkspacePath(url.path)
    }

    func revealSavedAgentWorkspace(_ profile: AgentProfile, path: String) {
        do {
            try prepareSavedAgentWorkspace(profile, workspace: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch { showToast(error.localizedDescription) }
    }
}

extension AppModel {
    /// Keep the chat history when removing a configured profile. The backend
    /// resolves every owned session before the profile disappears, including
    /// archived chats and chats outside the sidebar's search and result limit.
    func removeSavedAgent(_ profile: AgentProfile) async throws {
        guard agentProfiles.contains(where: { $0.id == profile.id }) else {
            throw AgentWorldError.unavailable("This saved agent was already removed.")
        }
        try beginSavedAgentRemoval(profile.id)
        defer { removingSavedAgentIDs.remove(profile.id) }
        _ = try await cleanupSavedAgentConversations(profileID: profile.id, action: "archive")
        guard agentTeamsModel.removeAgentProfile(profile) else {
            throw AgentWorldError.unavailable("The chats were archived, but a run started before the agent could be removed. Stop the run and try again.")
        }
        clearRemovedSavedAgentSelection(profile.id)
        await refreshMetadata()
        showToast("Removed \(profile.name). Chats are kept in archived history.")
    }

    /// An unavailable group has no profile to delete. Remove the exact owner's
    /// chats as one recovery batch, preserving their identity for Undo.
    func deleteUnavailableSavedAgent(profileID: UUID) async throws {
        guard !agentProfiles.contains(where: { $0.id == profileID }) else {
            throw AgentWorldError.unavailable("This agent is available again. Remove it from its agent menu.")
        }
        try beginSavedAgentRemoval(profileID)
        defer { removingSavedAgentIDs.remove(profileID) }
        let representative = sessions.first { $0.id == currentSessionID && $0.savedAgentProfileID == profileID }
            ?? sessions.first { $0.savedAgentProfileID == profileID }
        let response = try await cleanupSavedAgentConversations(profileID: profileID, action: "delete")
        clearRemovedSavedAgentSelection(profileID)
        await refreshMetadata()
        if let batch = response.trashBatch, let representative {
            pendingDeletedChat = DeletedChatUndo(session: representative, trashBatch: batch,
                                                 wasActive: response.deletedActive)
            showToast("Removed unavailable agent and moved \(response.count) \(response.count == 1 ? "chat" : "chats") to recovery",
                      actionTitle: "Undo", duration: 7)
        } else {
            showToast("Removed unavailable agent")
        }
    }

    private func beginSavedAgentRemoval(_ profileID: UUID) throws {
        guard removingSavedAgentIDs.isEmpty else {
            throw AgentWorldError.unavailable("Wait for the current agent removal to finish.")
        }
        guard !isBusy, !hasPendingPermission, !pendingSessionReset else {
            throw AgentWorldError.unavailable("Finish or stop the active run before removing an agent.")
        }
        guard !creatingSavedAgentChatIDs.contains(profileID),
              savedAgentConversationCreationCounts[profileID, default: 0] == 0,
              !agentWorld.hasPendingWork(profileID: profileID),
              !agentCrewChat.hasPendingReplies(profileID: profileID) else {
            throw AgentWorldError.unavailable("Wait for this agent's chat or queued reply to finish before removing it.")
        }
        let ownedIDs = Set(sessions.filter { $0.savedAgentProfileID == profileID }.map(\.id))
            .union(taskWorkers.keys.filter { savedAgentProfileID(for: $0) == profileID })
            .union(pendingChatTurns.keys.filter { savedAgentProfileID(for: $0) == profileID })
            .union(taskConversationStates.keys.filter { savedAgentProfileID(for: $0) == profileID })
        guard !ownedIDs.contains(where: {
                  agentWorldConversationState($0).busy || taskConversationStates[$0].map { !$0.state.isTerminal } == true
              }),
              !teamRunLive.agentActivities.contains(where: {
                  UUID(uuidString: $0.id) == profileID && !$0.state.isTerminal
              }) else {
            throw AgentWorldError.unavailable("Finish or stop this agent's runs before removing it.")
        }
        if let session = sessions.first(where: {
            $0.savedAgentProfileID == profileID && agentOwningEventChat($0) != nil
        }), let owner = agentOwningEventChat(session) {
            throw AgentWorldError.unavailable("This agent has a chat that receives \(owner.name)'s runs. Remove that automation first.")
        }
        removingSavedAgentIDs.insert(profileID)
    }

    private func cleanupSavedAgentConversations(profileID: UUID, action: String) async throws -> SavedAgentCleanupResponse {
        let wasActive = savedAgentProfileID(for: currentSessionID) == profileID
        let ownership: TranscriptSessionLoadToken
        if wasActive {
            ownership = beginTranscriptTransition(source: backend, reasons: ["deleted_active"],
                                                   acceptsSocketAcknowledgement: false)
            pendingSessionReset = true
            // The bounded HTTP operation owns this reset. Large histories
            // and worktree snapshots can exceed the ordinary reset watchdog.
        } else {
            ownership = transcriptPresentation.sessionOwnershipToken
        }
        do {
            let response = try await backend.post(
                "/api/sessions/agent-profile/\(profileID.uuidString)/cleanup",
                body: ["action": action], timeout: 120, as: SavedAgentCleanupResponse.self)
            if transcriptPresentation.ownsSessionLoad(ownership), let replacement = response.replacementSessionInfo {
                applySessionStarted(replacement, reason: "deleted_active")
            } else if wasActive, transcriptPresentation.ownsSessionLoad(ownership) {
                invalidatePendingTranscriptTransition()
            }
            guard response.ok else {
                throw AgentWorldError.unavailable(response.error ?? "The agent's chats could not all be removed. Try again.")
            }
            let removedIDs = Set(response.sessionIDs)
            sessions.removeAll { removedIDs.contains($0.id) }
            if action == "delete" {
                for sessionID in response.sessionIDs { browser.closeTabs(ownedBy: sessionID) }
            }
            return response
        } catch {
            if wasActive, transcriptPresentation.ownsSessionLoad(ownership) {
                // A transport failure can lose the replacement response after
                // the backend has already opened a fresh conversation.
                let state = try? await backend.get("/api/config", as: ConfigStateResponse.self)
                if transcriptPresentation.ownsSessionLoad(ownership),
                   let replacement = state?.sessionInfo, replacement.sessionID != currentSessionID {
                    applySessionStarted(replacement, reason: "deleted_active")
                } else if transcriptPresentation.ownsSessionLoad(ownership) {
                    invalidatePendingTranscriptTransition()
                }
            }
            await refreshMetadata()
            throw error
        }
    }

    private func clearRemovedSavedAgentSelection(_ profileID: UUID) {
        if selectedSavedAgentID == profileID { selectedSavedAgentID = nil }
        if savedAgentOverviewID == profileID {
            savedAgentOverviewID = nil
            emptySidebarDestination = .agents
        }
        if configureAgentProfileID == profileID {
            configureAgentProfileID = nil
            configureAgentPresented = false
        }
    }

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

    var savedAgentOverviewProfile: AgentProfile? {
        guard sidebarDestination == .agents, !agentCrewChatPresented else { return nil }
        return agentProfiles.first { $0.id == savedAgentOverviewID }
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
        if isNew { selectSavedAgent(saved) }
    }

    func selectSavedAgent(_ profile: AgentProfile) {
        guard agentProfiles.contains(where: { $0.id == profile.id }),
              !removingSavedAgentIDs.contains(profile.id) else { return }
        rememberSidebarAgent("profile:\(profile.id.uuidString)")
        rememberSidebarSession(sessions.first { $0.id == currentSessionID })
        agentCrewChatPresented = false
        emptySidebarDestination = nil
        savedAgentOverviewID = profile.id
        selectedSavedAgentID = profile.id
        selectedAgentID = nil
        agentInspector.clearAgentSelection()
        agentInspector.show(.fleet)
        sidebarDestination = .agents
        activity.activityCenterPresented = false
        dismissOverview()
    }

    func savedAgentChats(_ profileID: UUID) -> [SessionSummary] {
        sessionCatalog.snapshot.sessions.filter {
            $0.savedAgentProfileID == profileID && !$0.isArchived
                && agentCrewChat.boundProfileID(for: $0.id) == nil
        }.sorted { $0.mtime > $1.mtime }
    }

    func newSavedAgentChat(_ profile: AgentProfile, workspace: String? = nil) {
        guard creatingSavedAgentChatIDs.insert(profile.id).inserted else { return }
        let workspace = workspace ?? savedAgentWorkspacePath(profile)
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
        guard agentProfiles.contains(where: { $0.id == profile.id }),
              !removingSavedAgentIDs.contains(profile.id) else {
            throw AgentWorldError.unavailable("This saved agent was removed.")
        }
        savedAgentConversationCreationCounts[profile.id, default: 0] += 1
        defer { savedAgentConversationCreationCounts[profile.id, default: 0] -= 1 }
        try prepareSavedAgentWorkspace(profile, workspace: workspace)
        let workspace = SessionSummary.canonicalWorkspacePath(workspace)
        struct Created: Decodable { let session_id: String }
        let count = sessionCatalog.snapshot.sessions.filter { $0.savedAgentProfileID == profile.id }.count
        let response = try await backend.post("/api/sessions/detached", body: [
            "cwd": workspace, "title": "Chat \(count + 1)", "agent_profile_id": profile.id.uuidString,
            "execution_environment": "automatic",
            "agent_home": workspace == savedAgentHomePath(profile),
        ], as: Created.self)
        agentWorld.bindConversation(response.session_id, workspace: workspace, profileID: profile.id)
        await refreshMetadata()
        guard let session = sessionCatalog.snapshot.sessionsByID[response.session_id] else {
            throw AgentWorldError.unavailable("The saved conversation could not be loaded. Refresh the agent list to reopen it.")
        }
        return session
    }

    func manageSavedAgent(_ profile: AgentProfile, workspace: String? = nil) {
        selectedSavedAgentID = profile.id
        presentConfigureAgent(draftText: "")
        configureAgentProfileID = profile.id
        configureAgentWorkspace = SessionSummary.canonicalWorkspacePath(workspace ?? savedAgentWorkspacePath(profile))
    }

    /// Automation editors capture their owner's identity and route when opened.
    /// Changing the foreground chat or model picker cannot retarget the draft.
    func presentSavedAgentAutomation(_ kind: AgentConfigurationKind, profile: AgentProfile) {
        let workspace = configureAgentWorkspace ?? savedAgentWorkspacePath(profile)
        do {
            let route = try agentProfileProvider(profile)
            if kind == .schedule {
                presentScheduleEditor(prompt: configureAgentDraftSuggestion)
                guard var draft = schedule.scheduleEditorDraft else { return }
                draft.agentProfileID = profile.id.uuidString
                draft.workspaceRoot = workspace
                draft.executionEnvironment = savedAgentScheduleEnvironment(profile, workspace: workspace)
                draft.provider = route.provider
                draft.providerAccountID = route.accountID
                draft.model = profile.model
                draft.runner = .solo
                draft.teamID = nil
                draft.teamName = ""
                schedule.scheduleEditorDraft = draft
                return
            }
            eventAutomations.presentEditor(targetSessionID: EventTriggerEditorDraft.newOwnedAgentChat,
                naturalLanguageRequest: configureAgentDraftSuggestion,
                triggerKind: kind == .price ? .price : .event)
            guard var draft = eventAutomations.editorDraft else { return }
            draft.targetSessionID = EventTriggerEditorDraft.newOwnedAgentChat
            draft.templateSessionID = ""
            draft.workspaceRoot = workspace
            draft.agentProfileID = profile.id.uuidString
            draft.profileRoute = ["provider": route.provider, "model": profile.model,
                                  "provider_account_id": route.accountID ?? ""]
            eventAutomations.editorDraft = draft
        } catch { showToast(error.localizedDescription) }
    }
}
