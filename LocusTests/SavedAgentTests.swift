import Foundation
import XCTest
@testable import Locus

final class SavedAgentTests: XCTestCase {
    @MainActor
    func testOpeningOwnedAutomationPromotesTheVisibleSavedAgent() {
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let eventOwner = AgentProfile(name: "Alpha", model: "fixture")
        let scheduleOwner = AgentProfile(name: "Zulu", model: "fixture")
        model.agentProfiles = [eventOwner, scheduleOwner]
        let event = EventTrigger(id: "shared", name: "Inbox", connectionID: "gmail",
            targetSessionID: "event-chat", instruction: "Review messages", mode: .work,
            triggerKind: .event, filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [],
            enabled: true, createdAt: 1, updatedAt: 1)
        let schedule = ScheduledTask(id: "shared", name: "Digest", prompt: "Review messages",
            workspaceRoot: "/tmp", mode: .work, executionEnvironment: .local, runner: .solo,
            provider: "ollama", model: "fixture", timezone: "UTC",
            rule: ScheduleRule(kind: .daily, hour: 9, minute: 0), enabled: true, createdAt: 1, updatedAt: 1)
        model.eventAutomations.seedForUITesting(connections: [], triggers: [event], deliveries: [])
        model.schedule.seedForUITesting(tasks: [schedule])
        model.sessions = [
            SessionSummary(id: "event-chat", name: "event-chat", preview: "", mtime: 1, size: 0,
                agentTriggerID: "shared", agentProfileID: eventOwner.id.uuidString, agentKind: "event"),
            SessionSummary(id: "schedule-chat", name: "schedule-chat", preview: "", mtime: 1, size: 0,
                agentTriggerID: "shared", agentProfileID: scheduleOwner.id.uuidString, agentKind: "schedule"),
        ]

        model.selectAgent(AgentInspectorAgent(.trigger(event)))
        model.selectAgent(AgentInspectorAgent(.schedule(schedule)))

        XCTAssertEqual(model.recentSidebarAgentIDs, [
            "profile:\(scheduleOwner.id.uuidString)", "profile:\(eventOwner.id.uuidString)",
        ])
        let groups = AgentSidebarCatalog.groups(definitions: model.agentDefinitions, sessions: model.sessions,
            query: "", showArchived: false, runningSessionIDs: [], profiles: model.agentProfiles,
            recentAgentIDs: model.recentSidebarAgentIDs)
        XCTAssertEqual(groups.map(\.profileID), [scheduleOwner.id, eventOwner.id])
        XCTAssertEqual(model.agentInspector.context, .agent(AgentInspectorAgent(.schedule(schedule))))
    }

    @MainActor
    func testMixedOwnershipRecencyFollowsTheOpenedSidebarRowOrChat() {
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let eventOwner = AgentProfile(name: "Event owner", model: "fixture")
        let scheduleOwner = AgentProfile(name: "Schedule owner", model: "fixture")
        model.agentProfiles = [eventOwner, scheduleOwner]
        let event = EventTrigger(id: "shared", name: "Inbox", connectionID: "gmail",
            targetSessionID: "owned-event", instruction: "Review messages", mode: .work,
            triggerKind: .event, filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [],
            enabled: true, createdAt: 1, updatedAt: 1)
        let schedule = ScheduledTask(id: "shared", name: "Digest", prompt: "Review messages",
            workspaceRoot: "/tmp", mode: .work, executionEnvironment: .local, runner: .solo,
            provider: "ollama", model: "fixture", timezone: "UTC",
            rule: ScheduleRule(kind: .daily, hour: 9, minute: 0), enabled: true, createdAt: 1, updatedAt: 1)
        model.eventAutomations.seedForUITesting(connections: [], triggers: [event], deliveries: [])
        model.schedule.seedForUITesting(tasks: [schedule])
        let cases: [(AgentInspectorAgent, AgentProfile, SessionSummary, SessionSummary)] = [
            (AgentInspectorAgent(.trigger(event)), eventOwner,
             SessionSummary(id: "legacy-event", name: "Earlier event chat", preview: "", mtime: 1, size: 0,
                agentTriggerID: "shared", agentKind: "event"),
             SessionSummary(id: "owned-event", name: "Current event chat", preview: "", mtime: 2, size: 0,
                agentTriggerID: "shared", agentProfileID: eventOwner.id.uuidString, agentKind: "event")),
            (AgentInspectorAgent(.schedule(schedule)), scheduleOwner,
             SessionSummary(id: "legacy-schedule", name: "Earlier schedule chat", preview: "", mtime: 1, size: 0,
                agentTriggerID: "shared", agentKind: "schedule"),
             SessionSummary(id: "owned-schedule", name: "Current schedule chat", preview: "", mtime: 2, size: 0,
                agentTriggerID: "shared", agentProfileID: scheduleOwner.id.uuidString, agentKind: "schedule")),
        ]
        model.sessions = cases.flatMap { [$0.2, $0.3] }

        func groups() -> [AgentSidebarGroupModel] {
            AgentSidebarCatalog.groups(definitions: model.agentDefinitions, sessions: model.sessions,
                query: "", showArchived: false, runningSessionIDs: [], profiles: model.agentProfiles,
                recentAgentIDs: model.recentSidebarAgentIDs)
        }
        XCTAssertEqual(groups().count, 4, "Retained unowned chats keep their standalone automation rows")

        for (reference, owner, legacyChat, ownedChat) in cases {
            let ownerIdentity = "profile:\(owner.id.uuidString)"
            model.selectAgent(reference)
            XCTAssertEqual(groups().first?.id, ownerIdentity,
                "Opening an owned automation's configuration still promotes its saved agent")

            model.selectAgent(reference, fromSidebarRow: true)
            XCTAssertEqual(groups().first?.id, reference.id)
            XCTAssertEqual(model.agentInspector.context, .agent(reference))

            model.inspectAgentChat(ownedChat)
            XCTAssertEqual(groups().first?.id, ownerIdentity)
            model.inspectAgentChat(legacyChat)
            XCTAssertEqual(groups().first?.id, reference.id,
                "Opening a retained legacy chat promotes the row containing that chat")
            XCTAssertEqual(model.agentInspector.context, .chat(reference, sessionID: legacyChat.id))
        }
        XCTAssertEqual(Set(model.recentSidebarAgentIDs).count, 4,
            "Event and schedule identities must remain distinct even when their storage IDs match")
    }

    @MainActor
    func testSelectingAgentsPromotesTheLatestSelectionAndKeepsEarlierVisitOrder() {
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let alpha = AgentProfile(name: "Alpha", model: "fixture")
        let bravo = AgentProfile(name: "Bravo", model: "fixture")
        let charlie = AgentProfile(name: "Charlie", model: "fixture")
        model.agentProfiles = [alpha, bravo, charlie]

        model.selectSavedAgent(charlie)
        model.selectSavedAgent(bravo)
        model.selectSavedAgent(charlie)
        model.selectSavedAgent(charlie)

        XCTAssertEqual(model.recentSidebarAgentIDs, [
            "profile:\(charlie.id.uuidString)", "profile:\(bravo.id.uuidString)",
        ])
        let groups = AgentSidebarCatalog.groups(
            definitions: [], sessions: [], query: "", showArchived: false, runningSessionIDs: [],
            profiles: model.agentProfiles, recentAgentIDs: model.recentSidebarAgentIDs
        )
        XCTAssertEqual(groups.map(\.profileID), [charlie.id, bravo.id, alpha.id])
    }

    @MainActor
    func testOpeningAnAgentChatPromotesItsOwnerAndRejectsRemovedAgentSelections() {
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let first = AgentProfile(name: "First", model: "fixture")
        let second = AgentProfile(name: "Second", model: "fixture")
        model.agentProfiles = [first, second]
        model.selectSavedAgent(first)

        model.inspectAgentChat(cleanupSession("second-chat", owner: second.id))
        XCTAssertEqual(model.recentSidebarAgentIDs, [
            "profile:\(second.id.uuidString)", "profile:\(first.id.uuidString)",
        ])

        model.agentProfiles = [second]
        model.selectSavedAgent(first)
        XCTAssertEqual(model.recentSidebarAgentIDs.first, "profile:\(second.id.uuidString)")
    }

    @MainActor
    func testSelectingOverviewKeepsCurrentChatDraftModelAndRunningTask() async {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "agent-model")
        model.agentProfiles = [profile]
        model.sessions = [cleanupSession("agent-chat", owner: profile.id)]
        model.installTranscriptSession("work-chat", blocks: [ChatBlock(kind: .assistant, text: "Keep this result")])
        model.draftText = "An unfinished work draft"
        let foregroundModel = model.selectedModel
        model.isBusy = true
        let ownership = model.transcriptPresentation.sessionOwnershipToken
        let collapsed = model.inspectorCollapsed

        model.selectSavedAgent(profile)
        await Task.yield()

        XCTAssertEqual(model.savedAgentOverviewProfile?.id, profile.id)
        XCTAssertEqual(model.sidebarDestination, .agents)
        XCTAssertEqual(model.currentSessionID, "work-chat")
        XCTAssertEqual(model.draftText, "An unfinished work draft")
        XCTAssertEqual(model.selectedModel, foregroundModel)
        XCTAssertEqual(model.blocks.last?.text, "Keep this result")
        XCTAssertEqual(model.transcriptPresentation.sessionOwnershipToken, ownership)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.inspectorCollapsed, collapsed)
        XCTAssertNil(model.activeTranscriptLoad)
        XCTAssertTrue(model.creatingSavedAgentChatIDs.isEmpty)
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().isEmpty)
    }

    @MainActor
    func testAgentTabOpensOverviewAndWorkTabReturnsToRunningDraft() {
        let model = AppModel(startImmediately: false)
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "fixture")
        model.agentProfiles = [profile]
        let work = SessionSummary(id: "work-chat", name: "Work", preview: "", mtime: 1, size: 0)
        model.sessions = [work]
        model.installTranscriptSession(work.id, blocks: [])
        model.draftText = "Keep this draft"
        model.isBusy = true

        model.switchSidebarDestination(.agents)
        XCTAssertEqual(model.savedAgentOverviewProfile?.id, profile.id)
        model.switchSidebarDestination(.ask)

        XCTAssertNil(model.savedAgentOverviewProfile)
        XCTAssertNil(model.savedAgentOverviewID)
        XCTAssertEqual(model.currentSessionID, work.id)
        XCTAssertEqual(model.draftText, "Keep this draft")
        XCTAssertTrue(model.isBusy)
        XCTAssertNil(model.activeTranscriptLoad)
    }

    @MainActor
    func testOverviewDoesNotCreateFirstChatAndRejectsRemovedProfile() async {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "New agent", model: "fixture")
        model.agentProfiles = [profile]
        model.selectSavedAgent(profile)
        await Task.yield()
        XCTAssertEqual(model.savedAgentOverviewProfile?.id, profile.id)
        XCTAssertTrue(model.savedAgentChats(profile.id).isEmpty)
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().isEmpty)

        model.agentProfiles = []
        model.savedAgentOverviewID = nil
        model.selectSavedAgent(profile)
        XCTAssertNil(model.savedAgentOverviewID)
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().isEmpty)
    }

    @MainActor
    func testUnavailableChatKeepsOverviewUntilAnExplicitChatCanOpen() async {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "fixture")
        model.agentProfiles = [profile]
        model.selectSavedAgent(profile)
        let unavailable = SessionSummary(id: "gone", name: "Gone", preview: "", mtime: 1, size: 0,
            cwd: "/missing-locus-overview-test-\(UUID().uuidString)", agentProfileID: profile.id.uuidString)
        model.resume(unavailable)
        XCTAssertEqual(model.savedAgentOverviewProfile?.id, profile.id)
        XCTAssertNil(model.activeTranscriptLoad)

        let available = SessionSummary(id: "agent-chat", name: "Chat", preview: "", mtime: 1, size: 0,
            agentProfileID: profile.id.uuidString)
        model.sessions = [available]
        model.resume(available)
        XCTAssertNil(model.savedAgentOverviewID)
        await model.activeTranscriptLoad?.task.value
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().contains("/api/sessions/agent-chat/resume"))
    }

    @MainActor
    func testSameWorldConversationClosesMainOverviewWithoutReloadingChat() async throws {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "fixture")
        model.agentProfiles = [profile]
        let session = SessionSummary(id: "agent-chat", name: "Chat", preview: "", mtime: 1, size: 0,
            cwd: "/tmp", agentProfileID: profile.id.uuidString)
        model.sessions = [session]
        model.installTranscriptSession(session.id, blocks: [])
        model.selectSavedAgent(profile)
        try await model.activateAgentWorldConversation(session.id, workspace: "/tmp", expectedProfileID: profile.id)
        XCTAssertNil(model.savedAgentOverviewID)
        XCTAssertEqual(model.currentSessionID, session.id)
        XCTAssertNil(model.activeTranscriptLoad)
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().isEmpty)
    }

    @MainActor
    func testOverviewAutomationDraftKeepsCapturedProjectAndAgentRoute() {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "weather-model")
        model.agentProfiles = [profile]
        model.manageSavedAgent(profile, workspace: "/tmp/world-project")
        let workspace = SessionSummary.canonicalWorkspacePath("/tmp/world-project")
        XCTAssertEqual(model.configureAgentWorkspace, workspace)

        model.presentSavedAgentAutomation(.schedule, profile: profile)

        XCTAssertEqual(model.schedule.scheduleEditorDraft?.workspaceRoot, workspace)
        XCTAssertEqual(model.schedule.scheduleEditorDraft?.agentProfileID, profile.id.uuidString)
        XCTAssertEqual(model.schedule.scheduleEditorDraft?.model, "weather-model")
        XCTAssertEqual(model.schedule.scheduleEditorDraft?.provider, "ollama")
        XCTAssertEqual(model.schedule.scheduleEditorDraft?.runner, .solo)
        model.dismissConfigureAgent()
        XCTAssertNil(model.configureAgentWorkspace)
    }

    @MainActor
    func testNewAutomationFromAClosedHubMountsTheOwnersScheduleDraft() {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let account = ProviderAccount(kind: .chatGPT, name: "Plan", preferredModel: "plan-model")
        model.providerAccounts = [account]
        let profile = AgentProfile(name: "Jinbei", route: .providerAccount(account.id), model: "plan-model")
        model.agentProfiles = [profile]
        XCTAssertFalse(model.configureAgentPresented)

        model.newSavedAgentAutomation(.schedule, profile: profile)

        XCTAssertTrue(model.configureAgentPresented)
        XCTAssertEqual(model.configureAgentProfileID, profile.id)
        XCTAssertEqual(model.configureAgentPendingSavedAgentAutomation, .schedule)
        XCTAssertNil(model.schedule.scheduleEditorDraft, "The editor waits for the hub that hosts its sheet")
        model.mountPendingConfigureAgentEditor() // The hub's onAppear.

        XCTAssertNil(model.configureAgentPendingSavedAgentAutomation)
        let draft = model.schedule.scheduleEditorDraft
        XCTAssertEqual(draft?.agentProfileID, profile.id.uuidString)
        XCTAssertEqual(draft?.provider, "chatgpt")
        XCTAssertEqual(draft?.providerAccountID, account.id.uuidString)
        XCTAssertEqual(draft?.model, "plan-model")
        XCTAssertEqual(draft?.runner, .solo)
        XCTAssertEqual(draft?.workspaceRoot, model.configureAgentWorkspace)
        model.dismissConfigureAgent()
    }

    @MainActor
    func testNewAutomationFromAClosedHubMountsTheOwnersEventDraft() {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let account = ProviderAccount(kind: .chatGPT, name: "Plan", preferredModel: "plan-model")
        model.providerAccounts = [account]
        let profile = AgentProfile(name: "Jinbei", route: .providerAccount(account.id), model: "plan-model")
        model.agentProfiles = [profile]

        model.newSavedAgentAutomation(.event, profile: profile, workspace: "/tmp/world-project")
        XCTAssertNil(model.eventAutomations.editorDraft)
        model.mountPendingConfigureAgentEditor()

        let draft = model.eventAutomations.editorDraft
        XCTAssertEqual(draft?.agentProfileID, profile.id.uuidString)
        XCTAssertEqual(draft?.targetSessionID, EventTriggerEditorDraft.newOwnedAgentChat)
        XCTAssertEqual(draft?.triggerKind, .event)
        XCTAssertEqual(draft?.workspaceRoot, SessionSummary.canonicalWorkspacePath("/tmp/world-project"))
        XCTAssertEqual(draft?.profileRoute?["provider"], "chatgpt")
        XCTAssertEqual(draft?.profileRoute?["provider_account_id"], account.id.uuidString)
        XCTAssertEqual(draft?.profileRoute?["model"], "plan-model")
        XCTAssertTrue(SavedAgentURLProtocol.detachedRequests().isEmpty, "Opening a draft must not allocate a chat")
        model.dismissConfigureAgent()
    }

    @MainActor
    func testNewAutomationInAnOpenHubForTheSameAgentPresentsImmediately() {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "weather-model")
        model.agentProfiles = [profile]
        model.manageSavedAgent(profile)

        model.newSavedAgentAutomation(.price, profile: profile)

        XCTAssertNil(model.configureAgentPendingSavedAgentAutomation)
        XCTAssertEqual(model.eventAutomations.editorDraft?.triggerKind, .price)
        XCTAssertEqual(model.eventAutomations.editorDraft?.agentProfileID, profile.id.uuidString)
        model.dismissConfigureAgent()
    }

    @MainActor
    func testNewAutomationForAnUnusableAgentExplainsWithoutOpeningTheHub() {
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let disconnected = AgentProfile(name: "Orphaned", route: .providerAccount(UUID()), model: "fixture")
        let unconfigured = AgentProfile(name: "Draft", model: "")
        model.agentProfiles = [disconnected, unconfigured]
        for (profile, message) in [
            (disconnected, "The selected account is unavailable. Reconnect it or explicitly choose another profile."),
            (unconfigured, "Configure an exact model for Draft."),
        ] {
            model.newSavedAgentAutomation(.schedule, profile: profile)
            XCTAssertEqual(model.toast?.message, message)
            XCTAssertFalse(model.configureAgentPresented)
            XCTAssertNil(model.configureAgentProfileID)
            XCTAssertNil(model.configureAgentPendingSavedAgentAutomation)
            XCTAssertNil(model.schedule.scheduleEditorDraft)
        }
    }

    @MainActor
    func testDismissingTheHubDropsAPendingNewAutomation() {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let profile = AgentProfile(name: "Weather", model: "weather-model")
        model.agentProfiles = [profile]
        model.newSavedAgentAutomation(.price, profile: profile)
        XCTAssertEqual(model.configureAgentPendingSavedAgentAutomation, .price)

        model.dismissConfigureAgent()
        XCTAssertNil(model.configureAgentPendingSavedAgentAutomation, "Dismissing must drop the pending editor")

        // Reopening the hub for another reason must not mount an editor nobody asked for.
        model.manageSavedAgent(profile)
        model.mountPendingConfigureAgentEditor() // The hub's onAppear.

        XCTAssertNil(model.configureAgentPendingSavedAgentAutomation)
        XCTAssertNil(model.eventAutomations.editorDraft)
        XCTAssertNil(model.schedule.scheduleEditorDraft)
        model.dismissConfigureAgent()
    }

    @MainActor
    func testSavedAgentSendsChatWorkPlanAndGrill() {
        for mode in [WorkMode.ask, .work, .plan, .grill] {
            let model = savedAgentModel()
            model.selectedMode = mode
            model.send("Handle this assignment")
            XCTAssertTrue(model.isBusy, "\(mode) must reach dispatch")
            XCTAssertEqual(model.turnDispatchedMode, mode)
            XCTAssertEqual(model.turnDispatchedInPlanMode, mode == .plan)
            XCTAssertEqual(model.blocks.last(where: { $0.kind == .user })?.text, "Handle this assignment")
            cancelPendingWork(model)
        }
    }

    @MainActor
    func testSavedAgentCanImplementAnApprovedPlan() {
        let model = savedAgentModel()
        model.selectedMode = .work
        model.send("Implement the approved plan", preservingDraftOnFailure: true,
                   approvedPlan: ["revision": .number(1)])
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.turnDispatchedMode, .work)
        cancelPendingWork(model)
    }

    @MainActor
    func testSavedAgentDuoDispatchesItsSelectedPlannerAndPreservesOwner() {
        let model = savedAgentModel()
        let owner = model.savedAgentProfileID(for: model.currentSessionID)
        let planner = AgentProfile(name: "Duo planner", model: "planner-model", role: .planner)
        let builder = AgentProfile(name: "Duo builder", model: "builder-model", role: .implementer,
                                   accessCeiling: .workspaceWrite)
        model.duo.setChoice(planner, planner: true)
        model.duo.setChoice(builder, planner: false)
        model.selectedMode = .duo
        model.send("Build the requested feature")
        XCTAssertEqual(model.duoTask?.planner.id, planner.id)
        XCTAssertEqual(model.duoTask?.executor.id, builder.id)
        XCTAssertEqual(model.turnDispatchedMode, .plan)
        XCTAssertTrue(model.turnDispatchedInPlanMode)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.savedAgentProfileID(for: model.currentSessionID), owner)
        cancelPendingWork(model)
    }

    @MainActor
    func testSavedAgentCanDispatchASelectedTeam() {
        let model = savedAgentModel()
        let dispatcher = AgentProfile(name: "Coordinator", model: "fixture", role: .dispatcher)
        let writer = AgentProfile(name: "Writer", model: "fixture", role: .implementer,
                                  accessCeiling: .workspaceWrite)
        model.agentProfiles += [dispatcher, writer]
        let team = AgentTeam(name: "Crew", dispatcherID: dispatcher.id, fallbackDispatcherID: nil,
                             memberIDs: [dispatcher.id, writer.id], defaultWriterID: writer.id)
        model.agentTeams = [team]
        model.agentTeamsModel.selectAgentTeam(team.id)
        model.selectedMode = .work
        model.send("Complete the assigned task together")
        XCTAssertTrue(model.isBusy)
        XCTAssertNotNil(model.turnDispatchedTeamRunID)
        cancelPendingWork(model)
    }

    @MainActor
    func testSavedAgentCanOpenGoalWithItsOwnModel() {
        let model = savedAgentModel()
        model.backendCapabilities["persistent_goals_v1"] = true
        XCTAssertTrue(model.canStartGoal)
        model.presentGoalEditor()
        XCTAssertTrue(model.goals.isPresented)
        XCTAssertEqual(model.goals.draftRouteLabel, "fixture")
        cancelPendingWork(model)
    }

    @MainActor
    private func savedAgentModel() -> AppModel {
        let model = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Saved agent", model: "fixture", accessCeiling: .workspaceWrite)
        model.agentProfiles = [profile]
        let session = SessionSummary(id: "saved-chat", name: "saved-chat", preview: "", mtime: 1, size: 0,
                                     cwd: model.workspacePath, agentProfileID: profile.id.uuidString)
        model.sessions = [session]
        model.installTranscriptSession(session.id, blocks: [])
        model.agentRuntimePhase = .online
        model.settings.automaticModelRoutingEnabled = false
        model.configureTaskCapsules()
        return model
    }

    @MainActor
    private func cancelPendingWork(_ model: AppModel) {
        model.pendingChatTurns.values.forEach { $0.cancel() }
        model.pendingChatTurns.removeAll()
        model.knowledge.cancelAll()
        model.agentInstructions.cancelAll()
        model.toastCenter.cancelPendingDismissal()
    }

    func testExistingAgentProfileRestoresAfterServicePolicyUpgrade() throws {
        let json = #"{"route":{"kind":"account","accountID":"11111111-2222-3333-4444-555555555555"},"capabilityTags":[],"accessCeiling":"computer_control","tokenLimit":64000,"name":"Existing agent","instructions":"Review evidence","behavior":{"custom_instructions":"Review evidence","version":1,"mode_instructions":{"grill":"","work":"","plan":"","ask":""},"memory_policy":{"scopes":["personal","workspace","agent"],"max_automatic_memories":8,"recall_enabled":true,"proposals_enabled":true,"max_automatic_tokens":1200,"search_enabled":true,"cross_chat_context_enabled":true,"max_automatic_context_snapshots":2,"max_automatic_context_tokens":1200},"runtime_policy":{},"display_name":"Existing agent","response_style":{"cite_evidence":true,"tone":"balanced","use_markdown":true,"verbosity":"balanced"},"self_description":"A specialist for delegated tasks.","capability_policy":{"mcp":true,"network":true,"workspace_write":true,"computer_control":true,"workspace_read":true,"shell":true,"simulator_control":true}},"role":"generalist","mcpPolicy":{"prompts":[],"tools":[],"resources":[],"server_ids":[]},"metering":"self_hosted","id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","timeoutSeconds":600,"model":"fixture"}"#
        let profile = try JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
        let suite = "saved-agent-restore-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(("[" + json + "]").utf8), forKey: AgentTeamStore.profilesKey)
        XCTAssertEqual(AgentTeamStore.loadProfiles(from: defaults).map(\.name), ["Existing agent"])
        XCTAssertEqual(profile.name, "Existing agent")
        XCTAssertEqual(profile.accessCeiling, .computerControl)
        XCTAssertEqual(profile.mcpPolicy?.allowsAllServices, false)
        XCTAssertNil(profile.workspacePreferences, "Older profiles must load without rewriting existing chats")
    }

    @MainActor
    func testAgentHomeIsStableAcrossRenameAndIndependentOfForeground() throws {
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.agentHomesRootOverride = root
        let profile = AgentProfile(name: "Garp", model: "fixture")
        model.agentProfiles = [profile]
        let first = model.savedAgentHomePath(profile)
        model.sessions = [SessionSummary(id: "work", name: "work", preview: "", mtime: 1, size: 0, cwd: "/tmp/unrelated")]
        model.installTranscriptSession("work", blocks: [])
        XCTAssertEqual(model.savedAgentWorkspacePath(profile), first)
        var renamed = profile
        renamed.name = "Admiral"
        model.agentProfiles = [renamed]
        XCTAssertEqual(model.savedAgentHomePath(renamed), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Reading preferences must be inert")
        let restored = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(renamed))
        XCTAssertEqual(model.savedAgentHomePath(restored), first)
        XCTAssertNotEqual(model.savedAgentHomePath(AgentProfile(name: "Other", model: "fixture")), first)
    }

    @MainActor
    func testLinkingSharedProjectChangesOnlyFutureDefaultAndUnlinkKeepsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.txt")
        try Data("Keep project content".utf8).write(to: file)
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        model.agentHomesRootOverride = root.appendingPathComponent("Homes")
        let first = AgentProfile(name: "Garp", model: "fixture")
        let second = AgentProfile(name: "Robin", model: "fixture")
        model.agentProfiles = [first, second]
        let old = cleanupSession("old", owner: first.id)
        model.sessions = [old]
        model.setSavedAgentDefaultWorkspace(first, path: root.path)
        model.setSavedAgentDefaultWorkspace(second, path: root.path)
        let canonical = SessionSummary.canonicalWorkspacePath(root.path)
        XCTAssertEqual(model.savedAgentWorkspacePath(first), canonical)
        XCTAssertEqual(model.savedAgentWorkspacePath(second), canonical)
        XCTAssertEqual(model.sessions.first, old, "Changing a default never moves a saved chat")
        let persisted = try JSONDecoder().decode([AgentProfile].self, from: JSONEncoder().encode(model.agentProfiles))
        XCTAssertEqual(persisted.first?.workspacePreferences?.defaultProjectPath, canonical)
        model.unlinkSavedAgentProject(first, path: root.path)
        XCTAssertEqual(model.savedAgentWorkspacePath(first), model.savedAgentHomePath(first))
        XCTAssertEqual(model.savedAgentWorkspacePath(second), canonical)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.sessions.first, old)
    }

    @MainActor
    func testHomeCreationIsLazyAndRejectsRedirectedOrForeignHomes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = cleanupModel()
        defer { cancelPendingWork(model); try? FileManager.default.removeItem(at: root) }
        model.agentHomesRootOverride = root
        let first = AgentProfile(name: "Garp", model: "fixture")
        let second = AgentProfile(name: "Robin", model: "fixture")
        model.agentProfiles = [first, second]
        _ = model.savedAgentWorkspaceChoices(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let home = model.savedAgentHomePath(first)
        try model.prepareSavedAgentWorkspace(first, workspace: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home))
        XCTAssertThrowsError(try model.prepareSavedAgentWorkspace(second, workspace: home))
        let otherHome = URL(fileURLWithPath: model.savedAgentHomePath(second))
        try FileManager.default.createDirectory(at: otherHome.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: otherHome.path, withDestinationPath: home)
        XCTAssertThrowsError(try model.prepareSavedAgentWorkspace(second, workspace: otherHome.path))
        XCTAssertThrowsError(try model.prepareSavedAgentWorkspace(first, workspace: root.appendingPathComponent("missing-project").path))
    }

    @MainActor
    func testAgentHomeDraftAndNewChatPinWorkspaceWithoutForegroundInheritance() async throws {
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.agentHomesRootOverride = root
        defer { cancelPendingWork(model); try? FileManager.default.removeItem(at: root) }
        let profile = AgentProfile(name: "Weather", model: "fixture")
        model.agentProfiles = [profile]
        model.installTranscriptSession("foreground", blocks: [])
        model.manageSavedAgent(profile)
        model.presentSavedAgentAutomation(.event, profile: profile)
        let home = model.savedAgentHomePath(profile)
        XCTAssertEqual(model.eventAutomations.editorDraft?.workspaceRoot, home)
        XCTAssertEqual(model.eventAutomations.editorDraft?.targetSessionID, EventTriggerEditorDraft.newOwnedAgentChat)
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().isEmpty, "Opening a draft must not allocate a chat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home))
        let chat = try await model.createSavedAgentConversation(profile, workspace: model.savedAgentWorkspacePath(profile))
        XCTAssertEqual(chat.workspacePath, home)
        XCTAssertEqual(model.currentSessionID, "foreground")
        XCTAssertEqual(SavedAgentURLProtocol.detachedRequests().last?["cwd"] as? String, home)
        XCTAssertEqual(SavedAgentURLProtocol.detachedRequests().last?["execution_environment"] as? String, "automatic")
        XCTAssertEqual(SavedAgentURLProtocol.detachedRequests().last?["agent_home"] as? Bool, true)
    }

    func testNewWritableAgentsDefaultToAllServicesWithoutUndoingOptOuts() {
        for ceiling in [AgentAccessCeiling.workspaceWrite, .computerControl] {
            var profile = AgentProfile(name: "Test", model: "fixture", accessCeiling: ceiling)
            profile.applyNewAgentServiceDefaults()
            XCTAssertTrue(profile.mcpPolicy?.allowsAllServices == true)
            profile.mcpPolicy?.setServer("mail", enabled: false)
            profile.applyNewAgentServiceDefaults()
            XCTAssertFalse(profile.mcpPolicy?.allowsServer("mail") == true)
            profile.mcpPolicy = MCPAgentPolicy()
            profile.applyNewAgentServiceDefaults()
            XCTAssertFalse(profile.mcpPolicy?.allowsAllServices == true)
        }
        var readOnly = AgentProfile(name: "Review", model: "fixture")
        readOnly.applyNewAgentServiceDefaults()
        XCTAssertNil(readOnly.mcpPolicy)
    }

    @MainActor
    func testWorldConversationUsesSavedAgentChatFlowAndSidebarOwnership() async throws {
        SavedAgentURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SavedAgentURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: config))
        let model = AppModel(startImmediately: false, backendOverride: backend)
        let profile = AgentProfile(name: "World Agent", model: "fixture")
        model.agentProfiles = [profile]
        model.configureAgentWorld()
        let firstID = try await model.agentWorld.conversation(workspace: "/tmp", profile: profile)
        XCTAssertEqual(model.savedAgentChats(profile.id).first?.id, firstID)
        XCTAssertEqual(model.savedAgentChats(profile.id).first?.displayTitle, "Chat 1")
        XCTAssertEqual(model.agentTeamsModel.agentProfiles.first?.id, profile.id)
        let next = try await model.createSavedAgentConversation(profile, workspace: "/tmp")
        let worldID = try await model.agentWorld.conversation(workspace: "/tmp", profile: profile)
        XCTAssertEqual(worldID, next.id)
        XCTAssertEqual(model.savedAgentChats(profile.id).count, 2)
        XCTAssertEqual(model.agentWorld.residents.map(\.id), [profile.id.uuidString])
        model.knowledge.cancelAll()
        model.agentInstructions.cancelAll()
        model.toastCenter.cancelPendingDismissal()
    }

    func testServiceDefaultsRoundTripWithIndividualOptOutsAndLegacyPolicy() throws {
        var policy = MCPAgentPolicy.allConnected
        XCTAssertTrue(policy.allowsServer("new-extension"))
        policy.setServer("mail", enabled: false)
        policy.excludedConnectionIDs = ["gmail"]
        policy.clamp()
        let restored = try JSONDecoder().decode(MCPAgentPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(restored.allowsServer("mail"))
        XCTAssertTrue(restored.allowsServer("new-extension"))
        XCTAssertEqual(restored.excludedConnectionIDs, ["gmail"])
        policy.setServer("mail", enabled: true)
        XCTAssertTrue(policy.allowsServer("mail"))
        let legacy = try JSONDecoder().decode(MCPAgentPolicy.self,
            from: Data(#"{"server_ids":["mail"],"tools":["read"],"resources":[],"prompts":[]}"#.utf8))
        XCTAssertTrue(legacy.allowsServer("mail"))
        XCTAssertFalse(legacy.allowsServer("new-extension"))
    }

    func testProfileGroupsOwnManualAndAutomationChatsWithoutDuplicateParents() {
        let profile = AgentProfile(name: "Bob", model: "fixture")
        let chats = [
            SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0,
                           title: "Chat 1", agentProfileID: profile.id.uuidString.lowercased()),
            SessionSummary(id: "event", name: "event", preview: "", mtime: 2, size: 0,
                           title: "Price watch", agentTriggerID: "price", agentProfileID: profile.id.uuidString,
                           agentKind: "event", agentPrimary: true),
        ]
        var trigger = EventTrigger(id: "price", name: "Price watch", connectionID: "prices",
            targetSessionID: "event", instruction: "Review the quote", mode: .work, triggerKind: .price,
            filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [], enabled: true,
            createdAt: 1, updatedAt: 1)
        let groups = AgentSidebarCatalog.groups(definitions: [.trigger(trigger)], sessions: chats,
            query: "", showArchived: false, runningSessionIDs: [], profiles: [profile])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Bob")
        XCTAssertEqual(groups.first?.profileID, profile.id)
        XCTAssertEqual(groups.first?.totalChatCount, 2)
        XCTAssertFalse(groups.first?.needsAttention ?? true)
        XCTAssertTrue(chats[0].isAgentChat)
        XCTAssertEqual(chats[0].withOrganization(folderID: nil, sortOrder: 3).savedAgentProfileID, profile.id)
        trigger.lastError = "Quote source disconnected"
        let warning = AgentSidebarCatalog.groups(definitions: [.trigger(trigger)], sessions: chats,
            query: "", showArchived: false, runningSessionIDs: [], profiles: [profile])
        XCTAssertEqual(warning.count, 1)
        XCTAssertEqual(warning.first?.needsAttention, true)
        XCTAssertEqual(warning.first?.statusTitle, "Needs attention")
    }

    @MainActor
    func testProfileAndAutomationSelectionKeepTheCorrectInspectorContext() {
        let model = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Bob", model: "fixture")
        model.agentProfiles = [profile]
        let chat = SessionSummary(id: "chat", name: "chat", preview: "", mtime: 1, size: 0,
            title: "Chat 1", agentProfileID: profile.id.uuidString)
        model.sessions = [chat]
        model.installTranscriptSession(chat.id, blocks: [])
        let automation = AgentInspectorAgent(kind: .event, agentID: "inbox")
        model.selectAgent(automation)
        XCTAssertNil(model.selectedSavedAgentProfile)
        XCTAssertEqual(model.agentInspector.context, .agent(automation))
        model.agentInspector.show(.event(automation, deliveryID: "delivery"))
        model.inspectAgentChat(chat)
        XCTAssertEqual(model.selectedSavedAgentProfile?.id, profile.id)
        XCTAssertEqual(model.agentInspector.context, .fleet)
        XCTAssertNil(model.agentInspector.selectedAgent)
    }

    @MainActor
    func testChatCreationPersistsOwnershipAndKeepsEarlierChatsBound() async throws {
        SavedAgentURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SavedAgentURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!,
            session: URLSession(configuration: config))
        let model = AppModel(startImmediately: false, backendOverride: backend)
        let profile = AgentProfile(name: "Bob", model: "fixture")
        model.agentProfiles = [profile]
        model.installTranscriptSession("foreground", blocks: [])
        let first = try await model.createSavedAgentConversation(profile, workspace: "/tmp")
        let second = try await model.createSavedAgentConversation(profile, workspace: "/tmp")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.displayTitle, "Chat 1")
        XCTAssertEqual(second.displayTitle, "Chat 2")
        XCTAssertEqual(first.savedAgentProfileID, profile.id)
        XCTAssertEqual(second.savedAgentProfileID, profile.id)
        XCTAssertEqual(model.agentWorld.boundProfileID(for: first.id), profile.id)
        XCTAssertEqual(model.agentWorld.boundProfileID(for: second.id), profile.id)
        XCTAssertEqual(model.currentSessionID, "foreground")
        XCTAssertEqual(model.savedAgentChats(profile.id).count, 2)
        model.knowledge.cancelAll()
        model.agentInstructions.cancelAll()
        model.toastCenter.cancelPendingDismissal()
    }

    @MainActor
    func testProfileEditorWaitsUntilManagementDismisses() {
        let model = AppModel(startImmediately: false)
        model.configureAgentPresented = true
        model.presentNewAgent()
        XCTAssertFalse(model.configureAgentPresented)
        XCTAssertNotNil(model.pendingSavedAgentEditor)
        XCTAssertNil(model.savedAgentEditor)
        model.dismissConfigureAgent()
        XCTAssertNotNil(model.savedAgentEditor)
        XCTAssertNil(model.pendingSavedAgentEditor)
    }

    @MainActor
    func testRemovingSavedAgentArchivesAllOwnedChatsBeforeRemovingProfile() async throws {
        let profile = AgentProfile(name: "Test agent", model: "fixture")
        let other = AgentProfile(name: "Keep agent", model: "fixture")
        SavedAgentURLProtocol.reset(rows: [
            cleanupRow("visible", owner: profile.id),
            cleanupRow("outside-catalog", owner: profile.id),
            cleanupRow("unrelated", owner: other.id),
        ])
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        model.agentProfiles = [profile, other]
        model.sessions = [cleanupSession("visible", owner: profile.id), cleanupSession("unrelated", owner: other.id)]
        model.installTranscriptSession("foreground", blocks: [])
        model.selectedSavedAgentID = profile.id
        model.savedAgentOverviewID = profile.id
        model.configureAgentProfileID = profile.id

        try await model.removeSavedAgent(profile)

        XCTAssertEqual(model.agentProfiles.map(\.id), [other.id])
        XCTAssertEqual(model.sessions.map(\.id), ["unrelated"])
        XCTAssertEqual(SavedAgentURLProtocol.archivedIDs(), ["visible", "outside-catalog"])
        XCTAssertNil(model.selectedSavedAgentID)
        XCTAssertNil(model.savedAgentOverviewID)
        XCTAssertNil(model.configureAgentProfileID)
        XCTAssertTrue(model.removingSavedAgentIDs.isEmpty)
        XCTAssertEqual(SavedAgentURLProtocol.cleanupActions(), ["archive"])
    }

    @MainActor
    func testUnavailableAgentCleanupDeletesHiddenAndArchivedChatsWithSingleUndo() async throws {
        let removedID = UUID()
        let other = AgentProfile(name: "Keep agent", model: "fixture")
        SavedAgentURLProtocol.reset(rows: [
            cleanupRow("outside-search", owner: removedID),
            cleanupRow("active", owner: removedID),
            cleanupRow("archived", owner: removedID, archived: true),
            cleanupRow("unrelated", owner: other.id),
        ], current: "active")
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        model.agentProfiles = [other]
        let active = cleanupSession("active", owner: removedID)
        model.sessions = [active, cleanupSession("unrelated", owner: other.id)]
        model.installTranscriptSession(active.id, blocks: [])
        model.agentWorld.bindConversation(active.id, workspace: "/tmp", profileID: removedID)
        model.searchQuery = "active"

        try await model.deleteUnavailableSavedAgent(profileID: removedID)

        XCTAssertEqual(model.sessions.map(\.id), ["unrelated"])
        XCTAssertEqual(model.agentProfiles.map(\.id), [other.id])
        XCTAssertEqual(model.currentSessionID, "replacement")
        XCTAssertFalse(model.pendingSessionReset)
        XCTAssertEqual(model.agentWorld.boundProfileID(for: active.id), removedID,
                       "Recovery must retain saved-agent routing and access restrictions")
        XCTAssertEqual(model.pendingDeletedChat?.trashBatch, "profile-recovery")
        XCTAssertEqual(model.toast?.actionTitle, "Undo")
        XCTAssertEqual(SavedAgentURLProtocol.cleanupActions(), ["delete"])

        model.performToastAction()
        for _ in 0..<100 {
            if SavedAgentURLProtocol.requestedPaths().contains("/api/sessions/active/resume") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(SavedAgentURLProtocol.rowIDs()), ["outside-search", "active", "archived", "unrelated"])
        XCTAssertTrue(SavedAgentURLProtocol.requestedPaths().contains("/api/sessions/active/resume"),
                      "Undo must reopen the original active chat, not the first chat in the batch")
    }

    @MainActor
    func testSavedAgentRemovalRejectsBackgroundRunBeforeSendingCleanup() async throws {
        let profile = AgentProfile(name: "Working agent", model: "fixture")
        SavedAgentURLProtocol.reset(rows: [cleanupRow("background", owner: profile.id)])
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        model.agentProfiles = [profile]
        model.sessions = [cleanupSession("background", owner: profile.id)]
        model.installTranscriptSession("foreground", blocks: [])
        model.taskConversationStates["background"] = TaskConversationState(sessionID: "background",
            state: .running, updatedAt: Date())

        do {
            try await model.removeSavedAgent(profile)
            XCTFail("A background run must prevent profile removal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("runs"))
        }
        XCTAssertEqual(model.agentProfiles.map(\.id), [profile.id])
        XCTAssertEqual(SavedAgentURLProtocol.cleanupActions(), [])
        XCTAssertTrue(model.removingSavedAgentIDs.isEmpty)
    }

    @MainActor
    func testRejectedCleanupKeepsProfileAndChatsAndReleasesActiveTransition() async throws {
        let profile = AgentProfile(name: "Protected agent", model: "fixture")
        SavedAgentURLProtocol.reset(rows: [cleanupRow("active", owner: profile.id)], current: "active", rejectCleanup: true)
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        model.agentProfiles = [profile]
        model.sessions = [cleanupSession("active", owner: profile.id)]
        model.installTranscriptSession("active", blocks: [])

        do {
            try await model.removeSavedAgent(profile)
            XCTFail("A rejected cleanup must not remove its profile")
        } catch {}
        XCTAssertEqual(model.agentProfiles.map(\.id), [profile.id])
        XCTAssertEqual(model.sessions.map(\.id), ["active"])
        XCTAssertEqual(model.currentSessionID, "active")
        XCTAssertFalse(model.pendingSessionReset)
        XCTAssertTrue(model.removingSavedAgentIDs.isEmpty)
        XCTAssertEqual(SavedAgentURLProtocol.archivedIDs(), [])
    }

    @MainActor
    func testCleanupFailureAfterReplacementKeepsNativeSessionSynchronizedAndProfileIntact() async throws {
        for loseResponse in [false, true] {
            let profile = AgentProfile(name: "Retry agent", model: "fixture")
            SavedAgentURLProtocol.reset(rows: [cleanupRow("active", owner: profile.id)], current: "active",
                                       failAfterReplacement: true, loseCleanupResponse: loseResponse)
            let model = cleanupModel()
            defer { cancelPendingWork(model) }
            model.agentProfiles = [profile]
            model.sessions = [cleanupSession("active", owner: profile.id)]
            model.installTranscriptSession("active", blocks: [ChatBlock(kind: .user, text: "Old conversation")])

            do {
                try await model.removeSavedAgent(profile)
                XCTFail("A partial archive failure must retain the saved profile")
            } catch {}

            XCTAssertEqual(model.currentSessionID, "replacement", "Lost response: \(loseResponse)")
            XCTAssertEqual(model.sessionInfo?.sessionID, "replacement")
            XCTAssertTrue(model.blocks.isEmpty, "The old transcript must not appear under the replacement chat")
            XCTAssertEqual(model.agentProfiles.map(\.id), [profile.id])
            XCTAssertTrue(model.sessions.isEmpty, "Partially archived history must be refreshed even on failure")
            XCTAssertEqual(SavedAgentURLProtocol.archivedIDs(), ["active"])
            XCTAssertFalse(model.pendingSessionReset)
            XCTAssertTrue(model.removingSavedAgentIDs.isEmpty)
        }
    }

    @MainActor
    func testOrphanCleanupRefusesAProfileThatIsAvailableAgain() async throws {
        let profile = AgentProfile(name: "Restored agent", model: "fixture")
        SavedAgentURLProtocol.reset()
        let model = cleanupModel()
        defer { cancelPendingWork(model) }
        model.agentProfiles = [profile]
        do {
            try await model.deleteUnavailableSavedAgent(profileID: profile.id)
            XCTFail("The orphan action must not delete a restored saved agent")
        } catch {}
        XCTAssertEqual(model.agentProfiles.map(\.id), [profile.id])
        XCTAssertEqual(SavedAgentURLProtocol.cleanupActions(), [])
    }

    @MainActor
    private func cleanupModel() -> AppModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SavedAgentURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: config))
        return AppModel(startImmediately: false, backendOverride: backend)
    }

    private func cleanupSession(_ id: String, owner: UUID) -> SessionSummary {
        SessionSummary(id: id, name: id, preview: "", mtime: 1, size: 0, cwd: "/tmp", agentProfileID: owner.uuidString)
    }

    private func cleanupRow(_ id: String, owner: UUID, archived: Bool = false) -> [String: Any] {
        ["id": id, "name": id, "preview": "", "mtime": 1, "size": 0, "cwd": "/tmp",
         "agent_profile_id": owner.uuidString.lowercased(), "archived": archived]
    }
}

private final class SavedAgentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var rows: [[String: Any]] = []
    private static var recoveryRows: [[String: Any]] = []
    private static var current = "foreground"
    private static var rejectCleanup = false
    private static var failAfterReplacement = false
    private static var loseCleanupResponse = false
    private static var actions: [String] = []
    private static var paths: [String] = []
    private static var detachedBodies: [[String: Any]] = []
    static func reset(rows: [[String: Any]] = [], current: String = "foreground", rejectCleanup: Bool = false,
                      failAfterReplacement: Bool = false, loseCleanupResponse: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.rows = rows; self.current = current; self.rejectCleanup = rejectCleanup
        self.failAfterReplacement = failAfterReplacement; self.loseCleanupResponse = loseCleanupResponse
        recoveryRows = []; actions = []; paths = []; detachedBodies = []
    }
    static func archivedIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(rows.filter { $0["archived"] as? Bool == true }.compactMap { $0["id"] as? String })
    }
    static func rowIDs() -> [String] { lock.lock(); defer { lock.unlock() }; return rows.compactMap { $0["id"] as? String } }
    static func cleanupActions() -> [String] { lock.lock(); defer { lock.unlock() }; return actions }
    static func requestedPaths() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    static func detachedRequests() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return detachedBodies }
    private static func sessionInfo() -> [String: Any] {
        let info = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp", session: current,
            sessionID: current, messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            maxIterations: 10, hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
        return try! JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var result: [String: Any] = [:]
        var statusCode = 200
        Self.paths.append(request.url!.path)
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch request.url!.path {
        case "/api/sessions/detached":
            Self.detachedBodies.append(body)
            let id = "saved-\(Self.rows.count + 1)"
            Self.rows.append(["id": id, "name": id, "preview": "", "mtime": Self.rows.count + 1,
                "size": 0, "title": body["title"] ?? "", "cwd": body["cwd"] ?? "/tmp",
                "agent_profile_id": body["agent_profile_id"] ?? ""])
            result = ["session_id": id]
        case let path where path.hasPrefix("/api/sessions/agent-profile/") && path.hasSuffix("/cleanup"):
            let profileID = UUID(uuidString: request.url!.pathComponents.dropLast().last ?? "")
            let action = body["action"] as? String ?? ""
            Self.actions.append(action)
            if Self.rejectCleanup {
                statusCode = 409; result = ["detail": "This chat receives an automation's runs."]
                break
            }
            let matches = Self.rows.filter { UUID(uuidString: $0["agent_profile_id"] as? String ?? "") == profileID }
            let ids = matches.compactMap { $0["id"] as? String }
            let wasActive = ids.contains(Self.current)
            if wasActive { Self.current = "replacement" }
            if action == "delete" {
                Self.recoveryRows = matches
                Self.rows.removeAll { ids.contains($0["id"] as? String ?? "") }
            } else {
                for index in Self.rows.indices where ids.contains(Self.rows[index]["id"] as? String ?? "") {
                    Self.rows[index]["archived"] = true
                }
            }
            result = ["ok": true, "session_ids": ids, "count": ids.count, "deleted_active": wasActive]
            if action == "delete", !ids.isEmpty { result["trash_batch"] = "profile-recovery" }
            if wasActive { result["replacement_session_info"] = Self.sessionInfo() }
            if Self.failAfterReplacement {
                result["ok"] = false; result["error"] = "Worktree archive failed. Try again."
                result["session_ids"] = [String](); result["count"] = 0
                if Self.loseCleanupResponse {
                    statusCode = 500; result = ["detail": "The cleanup response was lost"]
                }
            }
        case "/api/sessions/restore":
            let ids = Self.recoveryRows.compactMap { $0["id"] as? String }
            Self.rows.append(contentsOf: Self.recoveryRows); Self.recoveryRows = []
            result = ["ok": true, "restored": ids.count, "session_ids": ids]
        case "/api/sessions":
            let includeArchived = request.url!.query?.contains("include_archived=true") == true
            result = ["sessions": Self.rows.filter { includeArchived || $0["archived"] as? Bool != true }, "current": Self.current]
        case "/api/config":
            result = ["model": "fixture", "host": "localhost", "cwd": "/tmp", "max_iterations": 10,
                      "session_info": Self.sessionInfo()]
        case "/api/models": result = ["models": ["fixture"]]
        case "/api/chat-folders": result = ["folders": []]
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        client?.urlProtocolDidFinishLoading(self)
    }
}
