import Foundation

extension AppModel {
    var primaryCompanionProfile: AgentProfile? {
        agentProfiles.first { $0.id == agentTeamsModel.primaryCompanionID }
    }

    /// The selected project is the chat's canonical root, not a worktree's
    /// execution directory or the companion's most recent unrelated project.
    var companionWorkspacePath: String {
        let selected = SessionSummary.canonicalWorkspacePath(pendingWorkspacePath ?? workspacePath)
        guard pendingWorkspacePath == nil,
              let session = sessionCatalog.snapshot.sessionsByID[currentSessionID],
              let root = session.workspacePath,
              [session.executionPath, session.cwd].compactMap({ $0 }).contains(where: {
                  SessionSummary.canonicalWorkspacePath($0) == selected
              }) else { return selected }
        return root
    }

    var canSwitchToCompanionChat: Bool {
        !pendingSessionReset && ((!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil)
    }

    func companionChats(in workspace: String? = nil) -> [SessionSummary] {
        guard let profile = primaryCompanionProfile else { return [] }
        let root = SessionSummary.canonicalWorkspacePath(workspace ?? companionWorkspacePath)
        return savedAgentChats(profile.id).filter {
            !$0.isAgentEventChat && $0.agentTriggerID?.nilIfEmpty == nil
                && $0.workspacePath == root
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.id < $1.id
        }
    }

    var companionConversationIsSelected: Bool {
        sidebarDestination == .companion && emptySidebarDestination == nil
            && companionChats().contains { $0.id == currentSessionID }
    }

    func companionSessionKey(workspace: String) -> String {
        "companion:\(agentTeamsModel.primaryCompanionID?.uuidString ?? "none"):\(SessionSummary.canonicalWorkspacePath(workspace))"
    }

    /// Navigation may reopen an existing normal chat; it never creates an
    /// agent, conversation, task or permission. First chat creation is explicit.
    func openCompanionDestination() {
        let workspace = companionWorkspacePath
        let chats = companionChats(in: workspace)
        let remembered = lastSidebarSessionIDs[companionSessionKey(workspace: workspace)]
        let target = chats.first { $0.id == currentSessionID }
            ?? chats.first { $0.id == remembered } ?? chats.first
        rememberSidebarSession(sessionCatalog.snapshot.sessionsByID[currentSessionID])
        agentCrewChatPresented = false
        savedAgentOverviewID = nil
        selectedSavedAgentID = primaryCompanionProfile?.id
        selectedAgentID = nil
        sidebarDestination = .companion
        emptySidebarDestination = .companion
        activity.activityCenterPresented = false
        dismissOverview()
        guard let target else { return }
        if target.id == currentSessionID {
            emptySidebarDestination = nil
            // A failed load already selected this ID. An explicit return may
            // retry it, without reloading a ready chat or superseding a load.
            if transcriptInputState == .unavailable, isAgentOnline, canSwitchToCompanionChat {
                resume(target, destination: .companion)
            }
        } else if isAgentOnline && canSwitchToCompanionChat {
            resume(target, destination: .companion)
        }
    }

    func openCompanionChat(_ session: SessionSummary) {
        guard companionChats().contains(where: { $0.id == session.id }) else { return }
        if session.id == currentSessionID {
            openCompanionDestination()
            return
        }
        guard isAgentOnline else {
            showToast("Reconnect Locus before opening another conversation.")
            return
        }
        guard canSwitchToCompanionChat else {
            showToast("Finish or stop the active run before switching chats")
            return
        }
        resume(session, destination: .companion)
    }

    /// The normal detached-session API owns routing and persistence. This
    /// action creates only an empty chat, never a model turn or scheduled run.
    func startCompanionConversation() {
        guard let profile = primaryCompanionProfile else {
            onboarding.beginCompanionSetup()
            return
        }
        guard isAgentOnline else {
            showToast("Reconnect Locus before opening a new conversation.")
            return
        }
        guard canSwitchToCompanionChat else {
            showToast("Finish or stop the active run before opening a new conversation")
            return
        }
        newSavedAgentChat(profile, workspace: companionWorkspacePath, destination: .companion)
    }
}
