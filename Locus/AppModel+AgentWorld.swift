import AppKit
import Foundation

extension AppModel {
    func configureAgentWorld() {
        agentWorld.appModel = self
        agentWorld.configure(
            extensions: extensionsModel, conversations: savedAgentConversations,
            profiles: { [weak self] in self?.agentProfiles ?? [] },
            workspace: { [weak self] in self?.workspacePath ?? "" },
            availability: { [weak self] profile in
                guard let self else { return "The agent is unavailable." }
                do { _ = try self.agentProfileProvider(profile); return nil }
                catch { return error.localizedDescription }
            },
            state: { [weak self] id in self?.savedAgentConversationState(id) ?? .init() },
            create: { [weak self] workspace, profile in
                guard let self else { throw SavedAgentConversationError.unavailable("The agent is unavailable.") }
                return try await self.createSavedAgentConversation(profile, workspace: workspace).id
            },
            load: { [weak self] id in
                guard let self else { throw CancellationError() }
                let detail = try await self.backend.get("/api/sessions/\(id)", as: SessionDetailResponse.self)
                guard detail.archived != true else { throw SavedAgentConversationError.conversationUnavailable("This conversation is archived.") }
                self.splitPaneBlocks[id] = ChatTranscriptBuilder.blocks(from: detail.messages)
            },
            activity: { [weak self] profile, workspace in
                if let activity = self?.savedAgentChatActivity(profileID: profile.id, workspace: workspace) { return activity }
                if let activity = self?.agentCrewChat.activity(for: profile.id, workspace: workspace), activity.busy { return activity }
                guard let self, SessionSummary.canonicalWorkspacePath(self.workspacePath) == workspace,
                      let activity = self.teamRunLive.agentActivities.first(where: {
                          $0.id.caseInsensitiveCompare(profile.id.uuidString) == .orderedSame && !$0.state.isTerminal
                      }) else { return nil }
                let needsAttention: Bool = [.waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused].contains(activity.state)
                return .init(status: needsAttention ? "needs_attention" : "working", detail: "Active in another Locus task", busy: true)
            },
            dispatch: { [weak self] sessionID, workspace, profileID, text, mode in
                guard let self else { throw SavedAgentConversationError.unavailable("The agent is unavailable.") }
                try await self.sendSavedAgentTurn(sessionID: sessionID, workspace: workspace, profileID: profileID, text: text, mode: mode)
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

}
