import Foundation

extension AppModel {
    var primaryCompanionProfile: AgentProfile? {
        agentProfiles.first { $0.id == agentTeamsModel.primaryCompanionID }
    }

    /// The companion uses its saved agent home unless the user explicitly
    /// selected a project in its existing profile preferences. Center navigation
    /// must never change this independent scope.
    var companionWorkspacePath: String {
        guard let profile = primaryCompanionProfile else { return "" }
        return savedAgentWorkspacePath(profile)
    }

    /// This changes future companion selection only. Existing conversations,
    /// drafts and running workers keep their captured workspace and identity.
    func selectCompanionWorkspace(_ path: String) {
        guard var profile = primaryCompanionProfile else { return }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            showToast("Choose an absolute workspace folder.")
            return
        }
        let home = savedAgentHomePath(profile)
        let selectsHome = path == home || SessionSummary.canonicalWorkspacePath(path) == home
        // Preserve the raw home path for its existing symlink guard at actual
        // creation; choosing home itself must not create the directory.
        if !selectsHome {
            do { try prepareSavedAgentWorkspace(profile, workspace: path) }
            catch { showToast(error.localizedDescription); return }
        }
        var preferences = profile.workspacePreferences ?? AgentWorkspacePreferences()
        preferences.defaultProjectPath = selectsHome ? nil : path
        if preferences.defaultProjectPath != nil { preferences.projectPaths.append(path) }
        preferences.normalize()
        profile.workspacePreferences = preferences
        agentTeamsModel.saveAgentProfile(profile)
        companionPanel.activate()
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

    var companionConversationIsSelected: Bool { companionPanel.selectedSessionID != nil }

    func companionSessionKey(workspace: String) -> String {
        "companion:\(agentTeamsModel.primaryCompanionID?.uuidString ?? "none"):\(SessionSummary.canonicalWorkspacePath(workspace))"
    }

    func rememberCompanionPanelSession(_ id: String, workspace: String) {
        lastSidebarSessionIDs[companionSessionKey(workspace: workspace)] = id
        if persistenceEnabled {
            UserDefaults.standard.set(lastSidebarSessionIDs, forKey: "Locus.lastSidebarSessionIDs")
        }
    }

    /// The left shortcut opens the ordinary profile-bound conversation. The
    /// inspector remains an independent destination with its own selection.
    func openCompanionMainConversation() {
        guard let profile = primaryCompanionProfile else {
            onboarding.beginCompanionSetup()
            return
        }
        let workspace = companionWorkspacePath
        let candidates = companionChats(in: workspace)
        if let current = candidates.first(where: { $0.id == currentSessionID }) {
            agentCrewChatPresented = false
            savedAgentOverviewID = nil
            emptySidebarDestination = nil
            activity.activityCenterPresented = false
            inspectAgentChat(current)
            sidebarDestination = .agents
            rememberSidebarSession(current)
            // Revealing the selected chat must not reload active work, an
            // approval or an in-flight transcript. Explicit failure retry is safe.
            if transcriptInputState == .unavailable, canSwitchToCompanionChat {
                resume(current, destination: .agents)
            }
            return
        }
        guard canSwitchToCompanionChat else {
            showToast("Finish or stop the active run before switching chats")
            return
        }
        let remembered = lastSidebarSessionIDs[companionSessionKey(workspace: workspace)]
        if let existing = candidates.first(where: { $0.id == remembered }) ?? candidates.first {
            resume(existing, destination: .agents)
            return
        }
        guard isAgentOnline else {
            showToast("Reconnect Locus before opening a new companion conversation.")
            return
        }
        guard creatingSavedAgentChatIDs.insert(profile.id).inserted else { return }
        let ownership = transcriptPresentation.sessionOwnershipToken
        let sourceDestination = sidebarDestination
        let sourceOverview = savedAgentOverviewID
        let sourceAgent = selectedSavedAgentID
        let sourceWorkspace = SessionSummary.canonicalWorkspacePath(pendingWorkspacePath ?? workspacePath)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { creatingSavedAgentChatIDs.remove(profile.id) }
            do {
                // Use canonical empty-chat creation, but defer foreground
                // selection until this explicit navigation still owns its scope.
                let created = try await createSavedAgentConversation(profile, workspace: workspace,
                                                                      preservingForeground: true)
                guard !Task.isCancelled, canSwitchToCompanionChat,
                      primaryCompanionProfile?.id == profile.id, companionWorkspacePath == workspace,
                      SessionSummary.canonicalWorkspacePath(pendingWorkspacePath ?? workspacePath) == sourceWorkspace,
                      transcriptPresentation.sessionOwnershipToken == ownership,
                      sidebarDestination == sourceDestination, savedAgentOverviewID == sourceOverview,
                      selectedSavedAgentID == sourceAgent,
                      companionChats(in: workspace).contains(where: { $0.id == created.id }) else { return }
                resume(created, destination: .agents)
            } catch {
                guard primaryCompanionProfile?.id == profile.id, companionWorkspacePath == workspace,
                      SessionSummary.canonicalWorkspacePath(pendingWorkspacePath ?? workspacePath) == sourceWorkspace,
                      transcriptPresentation.sessionOwnershipToken == ownership else { return }
                showToast("Could not open \(profile.name)’s chat: \(error.localizedDescription)")
            }
        }
    }

    /// Compatibility entry points now reveal an inspector. They never select a
    /// central transcript or move an active task's draft or keyboard focus.
    func openCompanionDestination() {
        if sidebarDestination == .companion {
            sidebarDestination = sessions.first(where: { $0.id == currentSessionID })?.isAgentChat == true ? .agents : .ask
            if emptySidebarDestination == .companion { emptySidebarDestination = nil }
        }
        selectInspectorTab(.companion)
        companionPanel.activate()
    }

    func openCompanionChat(_ session: SessionSummary) {
        openCompanionDestination()
        companionPanel.select(session)
    }

    func startCompanionConversation() {
        guard primaryCompanionProfile != nil else {
            onboarding.beginCompanionSetup()
            return
        }
        openCompanionDestination()
        companionPanel.createConversation()
    }
}
