import Foundation

extension AppModel {
    func startAgentWork(_ source: AgentWorkSource, profileID: UUID, prompt: String, at date: Date?) async throws {
        let ledger = AgentWorkLedger.shared
        guard ledger.latest(for: source)?.canStartAgain != false else {
            throw SavedAgentConversationError.unavailable("This task already has an assignment. Open its progress before starting another.")
        }
        guard let profile = agentProfiles.first(where: { $0.id == profileID }),
              !removingSavedAgentIDs.contains(profileID),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SavedAgentConversationError.unavailable("Choose an agent and describe the work.")
        }
        savedAgentConversationCreationCounts[profileID, default: 0] += 1
        defer { savedAgentConversationCreationCounts[profileID, default: 0] -= 1 }
        let workspace = BoardStore.canonicalWorkspace(source.workspace)
        let readyProfile = try firstReadyAgentModelProfile(profile)
        let route = try agentProfileProvider(readyProfile)
        try prepareSavedAgentWorkspace(profile, workspace: workspace)
        var scheduledDraft: ScheduleEditorDraft?
        if let date {
            guard date > Date() else { throw SavedAgentConversationError.unavailable("Choose a start time in the future.") }
            var draft = ScheduleEditorDraft()
            draft.name = source.title; draft.prompt = prompt; draft.workspaceRoot = workspace
            draft.agentProfileID = profileID.uuidString; draft.mode = profile.defaultMode == .ask ? .ask : .work
            draft.provider = route.provider; draft.providerAccountID = route.accountID; draft.model = readyProfile.model
            draft.oneTimeDate = date; draft.workflow = .singleAgent(instruction: prompt, mode: draft.mode)
            if let issue = scheduleConfigurationIssue(for: draft) { throw SavedAgentConversationError.unavailable(issue) }
            scheduledDraft = draft
        }
        var record = AgentWorkRecord(sourceID: source.sourceID, kind: source.kind, workspace: workspace,
                                     title: source.title, profileID: profileID)
        if let draft = scheduledDraft {
            record.scheduleID = UUID().uuidString; record.scheduledAt = draft.oneTimeDate
        }
        try ledger.save(record)
        do {
            if let draft = scheduledDraft {
                guard let id = await schedule.saveScheduleWithID(draft, creationID: record.scheduleID) else {
                    throw SavedAgentConversationError.unavailable("The schedule could not be confirmed. Check Automations before trying again.")
                }
                record.scheduleID = id; record.scheduledAt = draft.oneTimeDate; record.state = "scheduled"
                try ledger.save(record)
            } else {
                struct Created: Decodable { let session_id: String }
                let session = try await backend.post("/api/sessions/detached", body: [
                    "cwd": workspace, "title": source.title, "agent_profile_id": profileID.uuidString,
                    "execution_environment": "local",
                ], as: Created.self)
                record.sessionID = session.session_id; record.runID = UUID().uuidString
                try ledger.save(record)
                await refreshMetadata()
                try await sendSavedAgentTurn(sessionID: session.session_id, workspace: workspace, profileID: profileID,
                                            text: prompt, mode: profile.defaultMode == .ask ? .ask : .work, runID: record.runID!)
                record.state = "queued"
                try ledger.save(record)
                await activity.refreshActivityRuns(announceFailure: false)
            }
        } catch {
            record.state = "uncertain"; record.error = error.localizedDescription
            try? ledger.save(record)
            throw error
        }
    }

    @discardableResult
    func requestActivityRevision(_ run: OrchestrationRun, instructions: String) async throws -> String {
        guard let sessionID = run.sessionID,
              let profileID = savedAgentProfileID(for: sessionID)
                ?? run.manifest?["agent_profile_id"]?.string.flatMap(UUID.init(uuidString:)),
              let workspace = run.workspaceRoot?.nilIfEmpty,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SavedAgentConversationError.unavailable("Open the original chat to revise this result; its saved agent is unavailable.")
        }
        guard run.state == "completed", pendingChatTurns[sessionID] == nil,
              !savedAgentConversationState(sessionID).busy, goals.goal(for: sessionID)?.status != .active else {
            throw SavedAgentConversationError.unavailable("Wait for this agent’s current work to finish before requesting changes.")
        }
        let mode: WorkMode = agentProfiles.first { $0.id == profileID }?.defaultMode == .ask ? .ask : .work
        if let profile = agentProfiles.first(where: { $0.id == profileID }) {
            _ = try firstReadyAgentModelProfile(agentChatProfile(profile, sessionID: sessionID))
        }
        let runID = UUID().uuidString
        let ledger = AgentWorkLedger.shared
        var linked = ledger.records.last { $0.runID == run.id }
        if linked != nil {
            linked?.runID = runID; linked?.scheduleID = nil; linked?.state = "preparing"; linked?.reviewed = false; linked?.error = nil
            try ledger.save(linked!)
        }
        do {
            try await sendSavedAgentTurn(sessionID: sessionID, workspace: workspace, profileID: profileID,
                text: "Revise the result of task \(run.id).\n\nRequested changes:\n\(instructions)", mode: mode, runID: runID)
            if var record = linked { record.state = "queued"; try ledger.save(record) }
            await activity.refreshActivityRuns(announceFailure: false)
            return runID
        } catch {
            if var record = linked {
                record.state = "uncertain"; record.error = error.localizedDescription
                try? ledger.save(record)
            }
            await activity.refreshActivityRuns(announceFailure: false)
            throw error
        }
    }
}
