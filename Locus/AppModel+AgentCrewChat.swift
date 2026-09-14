import AppKit
import Foundation

extension AppModel {
    func configureAgentCrewChat() {
        agentCrewChat.configure(
            profiles: { [weak self] in self?.agentProfiles ?? [] },
            workspace: { [weak self] in self?.workspacePath ?? "" },
            availability: { [weak self] profile in
                guard let self else { return "Locus is unavailable." }
                do { _ = try self.agentProfileProvider(profile); return nil }
                catch { return error.localizedDescription }
            },
            state: { [weak self] id in self?.agentWorldConversationState(id) ?? .init() },
            create: { [weak self] workspace, profile in
                guard let self, self.agentProfiles.contains(where: { $0.id == profile.id }),
                      !self.removingSavedAgentIDs.contains(profile.id) else {
                    throw AgentWorldError.unavailable("This agent was removed from the crew.")
                }
                self.savedAgentConversationCreationCounts[profile.id, default: 0] += 1
                defer { self.savedAgentConversationCreationCounts[profile.id, default: 0] -= 1 }
                try self.prepareSavedAgentWorkspace(profile, workspace: workspace)
                struct Created: Decodable { let session_id: String }
                let result = try await self.backend.post("/api/sessions/detached", body: [
                    "cwd": workspace, "title": "Crew Chat · \(profile.name)",
                    "agent_profile_id": profile.id.uuidString,
                    "execution_environment": "automatic",
                    "agent_home": SessionSummary.canonicalWorkspacePath(workspace) == self.savedAgentHomePath(profile),
                ], as: Created.self)
                // The crew owns this binding. Creating a group contribution
                // must not replace the captain's private conversation.
                await self.refreshMetadata()
                return result.session_id
            },
            load: { [weak self] id in
                guard let self else { throw CancellationError() }
                let loaded = try await self.backend.get("/api/sessions/\(id)", as: AgentCrewConversationDetail.self)
                guard let profileID = self.agentCrewChat.boundProfileID(for: id),
                      let workspace = self.agentCrewChat.boundWorkspace(for: id),
                      loaded.identity.matches(sessionID: id, profileID: profileID, workspace: workspace) else {
                    throw AgentWorldError.unavailable("This conversation no longer matches its crew member and project.")
                }
                let detail = loaded.detail
                guard detail.archived != true else { throw AgentWorldError.unavailable("This crew conversation is archived.") }
                self.splitPaneBlocks[id] = ChatTranscriptBuilder.blocks(from: detail.messages)
            },
            dispatch: { [weak self] sessionID, workspace, profileID, text, mode in
                guard let self else { throw CancellationError() }
                try await self.sendAgentWorldTurn(sessionID: sessionID, workspace: workspace,
                                                 profileID: profileID, text: text, mode: mode)
            },
            stop: { [weak self] id in self?.stopGoalTurn(sessionID: id) },
            open: { [weak self] sessionID, profileID in
                guard let self else { return }
                if self.agentWorldOwnsPresentations, self.agentWorld.activeScreen != nil {
                    self.agentWorld.showConversation(sessionID, profileID: profileID.uuidString)
                } else {
                    self.agentCrewChatPresented = false
                    Task { @MainActor in
                        do {
                            let workspace = self.sessionCatalog.snapshot.sessionsByID[sessionID]?.workspacePath ?? self.workspacePath
                            try await self.activateAgentWorldConversation(sessionID, workspace: workspace)
                        } catch { self.showToast(error.localizedDescription) }
                    }
                }
            }
        )
    }

    func openAgentCrewChat(workspace: String? = nil) {
        savedAgentOverviewID = nil
        voiceControl.exitVoiceMode()
        agentCrewChat.activate(workspace: workspace ?? workspacePath)
        emptySidebarDestination = nil
        sidebarDestination = .agents
        activity.activityCenterPresented = false
        agentCrewChatPresented = true
    }

    /// Shares the ordinary native chat lifecycle without moving keyboard focus
    /// to a different window. Its composer owns all approvals and tool access.
    func activateAgentWorldConversation(_ sessionID: String, workspace: String, expectedProfileID: UUID? = nil, stillCurrent: () -> Bool = { true }) async throws {
        let previousSessionID = currentSessionID
        if sessionCatalog.snapshot.sessionsByID[sessionID] == nil { await refreshMetadata() }
        try Task.checkCancellation()
        guard stillCurrent(), currentSessionID == previousSessionID || currentSessionID == sessionID else { throw CancellationError() }
        guard let session = sessionCatalog.snapshot.sessionsByID[sessionID] else {
            // A failed catalog refresh is not proof that a chat was deleted.
            throw AgentWorldError.unavailable("This chat could not be found in the current history. Try again, or start a new chat.")
        }
        guard !session.isArchived else {
            throw AgentWorldError.conversationUnavailable("This conversation is archived.")
        }
        if let expectedProfileID, (session.savedAgentProfileID ?? agentWorld.boundProfileID(for: sessionID)) != expectedProfileID {
            throw AgentWorldError.unavailable("This chat belongs to another agent. Start a new chat for the selected resident.")
        }
        guard session.belongsToWorkspace(workspace) else {
            throw AgentWorldError.unavailable("This conversation is unavailable in this project.")
        }
        if currentSessionID != sessionID {
            guard !chatNavigationDisabled else {
                throw AgentWorldError.unavailable("Finish or stop the current foreground task before opening this conversation.")
            }
            resume(session)
            if let loading = activeTranscriptLoad?.task { await loading.value }
            try Task.checkCancellation()
            guard stillCurrent(), currentSessionID == sessionID, canAcceptTranscriptInput else {
                throw AgentWorldError.unavailable("The conversation changed or could not finish loading. Reopen this captain’s quarters.")
            }
        }
        // Resume owns a cancellable asynchronous transcript load. The World
        // displays its normal loading guard until that exact load completes.
        savedAgentOverviewID = nil
        selectedSavedAgentID = session.savedAgentProfileID
        agentCrewChatPresented = false
        sidebarDestination = .agents
    }
}

/// Decode identity alongside transcript data so recovery cannot load a ledger's
/// stale or mismatched session into another member's visible crew response.
private struct AgentCrewConversationDetail: Decodable {
    let detail: SessionDetailResponse
    let identity: AgentCrewChatSessionIdentity
    init(from decoder: Decoder) throws {
        detail = try SessionDetailResponse(from: decoder)
        identity = try AgentCrewChatSessionIdentity(from: decoder)
    }
}
