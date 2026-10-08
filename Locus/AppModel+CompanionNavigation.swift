import Foundation

extension AppModel {
    var primaryCompanionProfile: AgentProfile? {
        agentProfiles.first { $0.id == agentTeamsModel.primaryCompanionID }
    }

    /// An existing companion chat keeps its captured folder. Profile preferences
    /// only choose the folder for its first chat or its next cleared chat.
    var companionWorkspacePath: String {
        guard let profile = primaryCompanionProfile else { return "" }
        if let session = companionConversation {
            if let source = session.environment?["source_workspace"], session.belongsToWorkspace(source) {
                return SessionSummary.canonicalWorkspacePath(source)
            }
            if let workspace = session.workspacePath { return workspace }
        }
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

    /// One durable conversation belongs to the companion across all folders.
    /// Earlier chats stay available in saved-agent history; adopting one here
    /// never deletes or combines their transcripts.
    var companionConversation: SessionSummary? {
        guard let profile = primaryCompanionProfile else { return nil }
        let candidates = savedAgentChats(profile.id).filter {
            !$0.isAgentEventChat && $0.agentTriggerID?.nilIfEmpty == nil
        }.sorted {
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.id < $1.id
        }
        if let remembered = lastSidebarSessionIDs[companionSessionKey(workspace: "")],
           let session = candidates.first(where: { $0.id == remembered }) { return session }
        let preferredWorkspace = savedAgentWorkspacePath(profile)
        let legacyKey = "companion:\(profile.id.uuidString):\(SessionSummary.canonicalWorkspacePath(preferredWorkspace))"
        if let remembered = lastSidebarSessionIDs[legacyKey],
           let session = candidates.first(where: { $0.id == remembered }) { return session }
        return candidates.first(where: { $0.belongsToWorkspace(preferredWorkspace) }) ?? candidates.first
    }

    var currentCompanionConversationProfile: AgentProfile? {
        guard companionConversation?.id == currentSessionID else { return nil }
        return primaryCompanionProfile
    }

    /// Only the durable companion conversation receives Locus-wide retrieval.
    /// The same saved agent's ordinary task/event chats retain their own modes.
    func usesCompanionContext(sessionID: String, profileID: UUID? = nil) -> Bool {
        guard let companion = companionConversation, companion.id == sessionID,
              let owner = primaryCompanionProfile?.id else { return false }
        return profileID == nil || profileID == owner
    }

    func conversationMode(_ requested: WorkMode, sessionID: String) -> WorkMode {
        usesCompanionContext(sessionID: sessionID) ? .ask : requested
    }

    func companionChats(in workspace: String? = nil) -> [SessionSummary] {
        companionConversation.map { [$0] } ?? []
    }

    var companionConversationIsSelected: Bool { companionPanel.selectedSessionID != nil }

    func companionSessionKey(workspace: String) -> String {
        "companion:\(agentTeamsModel.primaryCompanionID?.uuidString ?? "none")"
    }

    func rememberCompanionPanelSession(_ id: String, workspace: String, profileID: UUID? = nil) {
        let key = profileID.map { "companion:\($0.uuidString)" } ?? companionSessionKey(workspace: workspace)
        lastSidebarSessionIDs[key] = id
        if persistenceEnabled {
            UserDefaults.standard.set(lastSidebarSessionIDs, forKey: "Locus.lastSidebarSessionIDs")
        }
    }

    func openCompanionOverview() {
        guard let profile = primaryCompanionProfile else {
            onboarding.beginCompanionSetup()
            return
        }
        selectSavedAgent(profile)
    }

    /// The dedicated chat entry opens the durable profile-bound conversation.
    func openCompanionMainConversation() {
        guard let profile = primaryCompanionProfile else {
            onboarding.beginCompanionSetup()
            return
        }
        let workspace = companionWorkspacePath
        let candidates = companionChats(in: workspace)
        if let current = candidates.first(where: { $0.id == currentSessionID }) {
            rememberCompanionPanelSession(current.id, workspace: workspace)
            agentCrewChatPresented = false
            savedAgentOverviewID = nil
            emptySidebarDestination = nil
            activity.activityCenterPresented = false
            inspectAgentChat(current)
            sidebarDestination = .agents
            rememberSidebarSession(current)
            if transcriptInputState == .ready { markCompanionRead() }
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
            rememberCompanionPanelSession(existing.id, workspace: workspace)
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
        let requestedPreference = savedAgentWorkspacePath(profile)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { creatingSavedAgentChatIDs.remove(profile.id) }
            do {
                // Use canonical empty-chat creation, but defer foreground
                // selection until this explicit navigation still owns its scope.
                let created = try await createSavedAgentConversation(profile, workspace: workspace,
                                                                      preservingForeground: true)
                rememberCompanionPanelSession(created.id, workspace: workspace, profileID: profile.id)
                guard !Task.isCancelled, canSwitchToCompanionChat,
                      primaryCompanionProfile?.id == profile.id, companionWorkspacePath == workspace,
                      primaryCompanionProfile.map(savedAgentWorkspacePath) == requestedPreference,
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
