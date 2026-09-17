import Foundation

/// An event-trigger editor the Configure Agent sheet opens once it exists.
/// A nil `trigger` asks for a new agent of `triggerKind` rather than an edit.
struct PendingEventTriggerEdit: Equatable {
    let trigger: EventTrigger?
    let targetSessionID: String
    var isDedicatedAgent = false
    var triggerKind: EventTriggerKind = .event
}

/// Chats that belong to a persistent agent. An agent's chats are ordinary
/// sessions tagged with its trigger, so "new chat" in Agents mode means the
/// agent's next chat rather than a fresh workspace conversation.
extension AppModel {
    /// Only ordinary conversations may override their owner's default route.
    /// Scheduled/event receiving chats always retain their configured model.
    func agentChatProfile(_ profile: AgentProfile, sessionID: String) -> AgentProfile {
        guard sessionCatalog.snapshot.sessionsByID[sessionID]?.isAgentEventChat != true,
              let selection = settings.agentChatModelSelections[sessionID],
              selection.profileID == profile.id else { return profile }
        var result = profile
        result.route = selection.accountID.map(AgentRoute.providerAccount) ?? .localOllama
        result.model = selection.model
        return result
    }

    var modelSelectionLockReason: String? {
        if !canAcceptTranscriptInput {
            return "Model selection is unavailable while this task is opening. Wait for the conversation to load."
        }
        if isIdentityTask {
            return "This Identity task uses its original model and account. Start a new Identity task to choose another model."
        }
        if let session = sessionCatalog.snapshot.sessionsByID[currentSessionID], session.isAgentEventChat {
            return "This task uses the model configured for its automation. Edit the agent or schedule to change future runs, or open a new agent chat to choose a model."
        }
        if selectedMode == .duo {
            return "Duo uses the planner and executor selected for this task. Change those agents in the Duo controls."
        }
        if taskCapsules.activeStageSessions[currentSessionID] != nil
            || taskCapsules.pendingPlanningRequest(for: currentSessionID) != nil {
            return "This task stage uses its saved specialist model. Finish the stage to change the model for ordinary chat messages."
        }
        if let profileID = savedAgentProfileID(for: currentSessionID),
           !agentProfiles.contains(where: { $0.id == profileID }) {
            return "This chat’s saved agent is unavailable. Restore the agent or start a new chat to choose a model."
        }
        return nil
    }

    /// The route the next owner turn will use, independent of global settings
    /// and of a different agent selected in the sidebar or inspector.
    var currentAgentChatProfile: AgentProfile? {
        guard let id = savedAgentProfileID(for: currentSessionID),
              let profile = agentProfiles.first(where: { $0.id == id }) else { return nil }
        return agentChatProfile(profile, sessionID: currentSessionID)
    }

    /// Fixed task routes are displayed from their own execution snapshot. A
    /// profile edited after a run must not relabel that run's recorded model.
    var modelPickerTaskRoute: (model: String, accountID: UUID?, provider: String)? {
        if let goal = goals.goal(for: currentSessionID), goal.status == .active,
           let name = goal.execution["model"]?.string {
            return (name, goal.execution["provider_account_id"]?.string.flatMap(UUID.init(uuidString:)),
                    goal.execution["provider"]?.string ?? "")
        }
        let specialist: AgentProfile?
        if selectedMode == .duo {
            specialist = duoTask.map { [.executing, .paused, .completed].contains($0.phase) ? $0.executor : $0.planner }
                ?? duo.saved.planner
        } else if let pending = taskCapsules.pendingPlanningRequest(for: currentSessionID) {
            specialist = capsuleProfiles.first { $0.id.uuidString.caseInsensitiveCompare(pending.recipe.plannerProfileID) == .orderedSame }
        } else { specialist = nil }
        if let specialist {
            let account = providerAccounts.first { $0.id == specialist.route.accountID }
            return (specialist.model, specialist.route.accountID, account?.kind.backendProvider ?? "ollama")
        }
        if isIdentityTask, let identity = taskWorkers[currentSessionID]?.identityProvider {
            return (identity.model, UUID(uuidString: identity.accountID), identity.provider)
        }
        let session = sessionCatalog.snapshot.sessionsByID[currentSessionID]
        if session?.isAgentEventChat == true {
            let schedule = session?.agentReference(in: agentDefinitions).flatMap(inspectorAgentDefinition)?.schedule
            let info = taskWorkers[currentSessionID]?.sessionInfo
            let name = info?.model ?? session?.model ?? schedule?.model
            let provider = info?.provider ?? session?.provider ?? schedule?.provider ?? ""
            if let name {
                let accountID = schedule.flatMap { $0.model == name && $0.provider == provider ? $0.providerAccountID : nil }
                    .flatMap(UUID.init(uuidString:))
                return (name, accountID, provider)
            }
        }
        if taskCapsules.activeStageSessions[currentSessionID] != nil,
           let info = taskWorkers[currentSessionID]?.sessionInfo {
            return (info.model, nil, info.provider ?? "")
        }
        return nil
    }

    func taskModelPickerLabel(model: String, accountID: UUID?, provider: String) -> String {
        if let accountID {
            return "\(providerAccounts.first { $0.id == accountID }?.shortName ?? "Unavailable account") · \(model)"
        }
        let source: String?
        switch provider {
        case "chatgpt": source = "ChatGPT"
        case "claude_plan": source = "Claude plan"
        case "remote": source = "API"
        default: source = nil
        }
        return source.map { "\($0) · \(model)" } ?? model
    }

    /// Runtime admission can win the race with the desktop worker or resume
    /// after relaunch. Persist the same credential-free route with the run;
    /// provision its exact account privately before making it runnable.
    func prepareAgentChatQueueRoute(_ dispatch: TaskCapsuleDispatch, sessionID: String) async throws -> [String: Any]? {
        guard dispatch.profileOnly,
              sessionCatalog.snapshot.sessionsByID[sessionID]?.isAgentEventChat != true else { return nil }
        if RuntimeInstallation.enabled, persistenceEnabled, !isUITesting {
            var provider = dispatch.providerBody
            provider["model"] = dispatch.profile.model
            if dispatch.provider == "ollama" { provider["host"] = lastOllamaHost }
            let _: [String: Bool] = try await backend.post("/api/runtime/credentials", body: [
                "kind": "account", "id": dispatch.accountID ?? "local", "configuration": provider,
            ], as: [String: Bool].self)
        }
        var route: [String: Any] = ["profile_id": dispatch.profile.id.uuidString,
                                   "provider": dispatch.provider, "model": dispatch.profile.model]
        if let accountID = dispatch.accountID { route["provider_account_id"] = accountID }
        return route
    }

    @discardableResult
    func selectAgentChatModel(account: ProviderAccount?, model: String) -> Bool {
        guard let profile = currentAgentChatProfile else { return false }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return true }
        var selected = profile
        selected.route = account.map { .providerAccount($0.id) } ?? .localOllama
        selected.model = name
        do { _ = try agentProfileProvider(selected) }
        catch { showToast(error.localizedDescription); return true }
        if selected.route != profile.route || selected.model != profile.model { pauseGoalForRouteChange() }
        settings.agentChatModelSelections[currentSessionID] = AgentChatModelSelection(
            profileID: profile.id, accountID: account?.id, model: name
        )
        persistSettings()
        showToast("\(name) will be used for your next message in this chat")
        return true
    }

    func resetAgentChatModel() {
        guard modelSelectionLockReason == nil, let profile = currentAgentChatProfile else { return }
        pauseGoalForRouteChange()
        settings.agentChatModelSelections.removeValue(forKey: currentSessionID)
        persistSettings()
        showToast("This chat will use \(profile.name)’s default model for the next message")
    }

    func rememberSidebarAgent(_ identity: String) {
        guard !identity.isEmpty, recentSidebarAgentIDs.first != identity else { return }
        recentSidebarAgentIDs = [identity] + recentSidebarAgentIDs.filter { $0 != identity }
    }

    private func rememberSidebarAgent(_ reference: AgentInspectorAgent) {
        let definition = inspectorAgentDefinition(reference)
        let ownerID: UUID?
        if let targetID = definition?.trigger?.targetSessionID,
           let target = sessionCatalog.snapshot.sessionsByID[targetID] {
            ownerID = target.savedAgentProfileID
        } else {
            let definitions = agentDefinitions
            let owners = Set(sessions.filter { $0.agentReference(in: definitions) == reference }
                .compactMap(\.savedAgentProfileID))
            ownerID = owners.count == 1 ? owners.first : nil
        }
        rememberSidebarAgent(ownerID.map { "profile:\($0.uuidString)" } ?? reference.id)
    }

    var agentDefinitions: [AgentDefinition] {
        eventAutomations.triggers.map(AgentDefinition.trigger) + schedule.scheduledTasks.map(AgentDefinition.schedule)
    }

    var inspectedAgentReference: AgentInspectorAgent? {
        agentInspector.selectedAgent
            ?? agentDefinition(for: selectedAgentID).map(AgentInspectorAgent.init)
            ?? sessionCatalog.snapshot.sessionsByID[currentSessionID]?.agentReference(in: agentDefinitions)
    }
    /// The agent represented by the Agent inspector and footer picker. A
    /// directly resumed agent chat supplies the initial selection for older
    /// state and test fixtures that predate explicit agent selection.
    var inspectedAgentID: String? {
        selectedAgentID?.nilIfEmpty
            ?? sessionCatalog.snapshot.sessionsByID[currentSessionID]?.agentTriggerID?.nilIfEmpty
    }

    /// Selects an agent as a parent object without changing the open chat.
    /// Its complete overview is revealed in the inspector, while New Chat is
    /// retargeted to this agent.
    func selectAgent(_ agentID: String) {
        guard let agentID = agentID.nilIfEmpty else { return }
        guard let definition = agentDefinition(for: agentID) else {
            showToast("Choose the event agent or schedule from its own row.")
            return
        }
        selectAgent(AgentInspectorAgent(definition))
    }

    func selectAgent(_ reference: AgentInspectorAgent, fromSidebarRow: Bool = false) {
        if fromSidebarRow {
            // Legacy unowned chats can keep this automation's own row visible
            // beside the saved agent that owns its current receiving chat.
            rememberSidebarAgent(reference.id)
        } else {
            rememberSidebarAgent(reference)
        }
        savedAgentOverviewID = nil
        selectedSavedAgentID = nil
        let agentID = reference.agentID
        selectedAgentID = agentID
        agentInspector.show(.agent(reference))
        sidebarDestination = .agents
        selectInspectorTab(.agent)
    }

    func inspectAgentChat(_ session: SessionSummary) {
        guard session.isAgentChat else { return }
        if let profileID = session.savedAgentProfileID {
            rememberSidebarAgent("profile:\(profileID.uuidString)")
            selectedSavedAgentID = profileID
            selectedAgentID = nil
            agentInspector.clearAgentSelection()
            agentInspector.show(.fleet)
            return
        }
        selectedSavedAgentID = nil
        guard let reference = session.agentReference(in: agentDefinitions) else {
            agentInspector.clearAgentSelection()
            selectedAgentID = nil
            agentInspector.show(.fleet)
            showToast("This saved chat’s agent kind is unavailable. Choose an agent to start a new conversation.")
            return
        }
        rememberSidebarAgent(reference.id)
        agentInspector.show(.chat(reference, sessionID: session.id))
    }

    func inspectorAgentDefinition(_ reference: AgentInspectorAgent) -> AgentDefinition? {
        switch reference.kind {
        case .event: eventAutomations.triggers.first { $0.id == reference.agentID }.map(AgentDefinition.trigger)
        case .schedule: schedule.scheduledTasks.first { $0.id == reference.agentID }.map(AgentDefinition.schedule)
        }
    }

    func inspectAgentEvent(_ context: EventTranscriptContext) {
        let agent = AgentInspectorAgent(kind: .event, agentID: context.triggerID)
        selectedAgentID = agent.agentID
        agentInspector.show(.event(agent, deliveryID: context.deliveryID))
        selectInspectorTab(.agent)
    }

    /// Resolve from durable provenance, never from whichever run happens to
    /// be selected in the Runs tab or newest in the chat.
    func inspectAgentRun(_ run: OrchestrationRun, reveal: Bool = true) {
        let agent: AgentInspectorAgent
        let origin: AgentInspectorOrigin?
        if let scheduleID = run.scheduleID?.nilIfEmpty {
            agent = AgentInspectorAgent(kind: .schedule, agentID: scheduleID)
            origin = run.occurrenceID.map(AgentInspectorOrigin.occurrence)
        } else if let triggerID = run.manifest?["event_trigger_id"]?.string?.nilIfEmpty {
            agent = AgentInspectorAgent(kind: .event, agentID: triggerID)
            origin = run.manifest?["event_delivery_id"]?.string.map(AgentInspectorOrigin.event)
        } else if let sessionID = run.sessionID,
                  let session = sessionCatalog.snapshot.sessionsByID[sessionID],
                  let reference = session.agentReference(in: agentDefinitions),
                  let definition = inspectorAgentDefinition(reference) {
            agent = AgentInspectorAgent(definition)
            origin = .chat(sessionID)
        } else { return }
        selectedAgentID = agent.agentID
        agentInspector.show(.run(agent, runID: run.id, origin: origin))
        if reveal { selectInspectorTab(.agent) }
    }

    /// The primary action creates the parent object for the active destination.
    func newChatForSidebarDestination() {
        if sidebarDestination == .agents {
            presentNewAgent()
        } else {
            newSession()
        }
    }

    /// Saved agents share the same profile editor as Agent World. A trigger
    /// kind supplied by a contextual action still opens that editor directly.
    func presentNewAgent(kind: EventTriggerKind? = nil) {
        guard let kind else {
            presentSavedAgentEditor(newSavedAgentDraft())
            return
        }
        configureAgentPendingTriggerEdit = PendingEventTriggerEdit(
            trigger: nil, targetSessionID: currentSessionID, triggerKind: kind
        )
        presentConfigureAgent(draftText: draftText)
    }

    /// The trigger or schedule behind an agent id, whichever kind it is.
    func agentDefinition(for agentID: String?) -> AgentDefinition? {
        AgentDefinition.resolve(
            agentID: agentID,
            triggers: eventAutomations.triggers,
            schedules: schedule.scheduledTasks
        )
    }

    /// Whether both stores have answered. Until each has, a missing
    /// definition says nothing about whether the agent still exists — one
    /// store having loaded tells us nothing about the other's kind.
    private var agentDefinitionsLoaded: Bool {
        eventAutomations.hasLoaded && schedule.hasLoaded
    }

    /// Starts a side conversation for an agent. Without an id it uses the
    /// selected agent, then the current chat's agent, then the most recent
    /// agent; with no agents at all it opens Manage Agents, where one is made.
    func newAgentChat(triggerID: String? = nil) {
        if triggerID == nil, let profile = selectedSavedAgentProfile {
            newSavedAgentChat(profile)
            return
        }
        let snapshot = sessionCatalog.snapshot
        let reference: AgentInspectorAgent?
        if let triggerID = triggerID?.nilIfEmpty {
            reference = inspectedAgentReference.flatMap { $0.agentID == triggerID ? $0 : nil }
                ?? agentDefinition(for: triggerID).map(AgentInspectorAgent.init)
        } else {
            reference = inspectedAgentReference
                ?? agentSession(for: nil, in: snapshot)?.agentReference(in: agentDefinitions)
        }
        guard let reference else {
            if let oldID = triggerID ?? snapshot.sessionsByID[currentSessionID]?.agentTriggerID,
               agentDefinitionsLoaded {
                showToast(agentDefinitions.contains(where: { $0.id == oldID })
                    ? "This saved chat’s agent kind is unavailable. Choose the event agent or schedule from its own row."
                    : "This agent was deleted. Configure a new agent to start chats.")
                return
            }
            presentConfigureAgent(draftText: draftText)
            return
        }
        newAgentChat(reference: reference)
    }

    func newAgentChat(reference: AgentInspectorAgent) {
        if agentDefinitionsLoaded && inspectorAgentDefinition(reference) == nil {
            showToast("This agent was deleted. Configure a new agent to start chats.")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !agentDefinitionsLoaded {
                await eventAutomations.refresh(announceFailure: false)
                await schedule.refreshScheduledTasks(announceFailure: false)
            }
            guard let definition = inspectorAgentDefinition(reference) else {
                showToast("This agent was deleted. Configure a new agent to start chats.")
                return
            }
            let chats = sessionCatalog.snapshot.sessions.filter { $0.agentReference(in: self.agentDefinitions) == reference }
            let name = "Chat \(chats.count + 1)"
            if let task = definition.schedule { await createScheduleChat(task, name: name); return }
            guard let chat = chats.first(where: { $0.id == self.currentSessionID }) ?? chats.max(by: { $0.mtime < $1.mtime }) else {
                showToast("This agent’s receiving chat is unavailable. Review its settings.")
                return
            }
            await eventAutomations.createTask(for: chat, name: name)
        }
    }

    /// A schedule's side chat comes from its own endpoint; it shares the
    /// agent's identity, workspace, and model but never receives a run.
    func createScheduleChat(_ task: ScheduledTask, name: String) async {
        do {
            let response: AgentTargetSessionResponse = try await backend.post(
                "/api/schedules/\(task.id)/tasks",
                body: ["name": name],
                as: AgentTargetSessionResponse.self
            )
            await refreshMetadata()
            sidebarDestination = .agents
            resume(response.session)
            showToast("New chat opened in \(task.name)")
        } catch {
            showToast("Could not start a chat for this agent: \(error.localizedDescription)")
        }
    }

    /// The per-agent actions, routed by kind so the sidebar row and the Agent
    /// panel do not each need to know which store an agent lives in.
    func editAgent(_ definition: AgentDefinition) {
        switch definition {
        case .trigger(let trigger):
            editAgentTrigger(trigger, isDedicatedAgent: true)
        case .schedule(let task):
            presentScheduleEditor(task: task)
        }
    }

    func setAgentEnabled(_ definition: AgentDefinition, enabled: Bool) {
        switch definition {
        case .trigger(let trigger):
            eventAutomations.setTrigger(trigger, enabled: enabled)
        case .schedule(let task):
            schedule.setScheduleEnabled(task, enabled: enabled)
        }
    }

    func clearAgentWarning(_ definition: AgentDefinition) {
        switch definition {
        case .trigger(let trigger):
            eventAutomations.clearWarning(trigger)
        case .schedule(let task):
            schedule.clearWarning(task)
        }
    }

    func isChangingAgentEnabled(_ definition: AgentDefinition) -> Bool {
        switch definition {
        case .trigger(let trigger): eventAutomations.changingEnabledIDs.contains(trigger.id)
        case .schedule(let task): schedule.changingEnabledIDs.contains(task.id)
        }
    }

    func isClearingAgentWarning(_ definition: AgentDefinition) -> Bool {
        switch definition {
        case .trigger(let trigger):
            eventAutomations.clearingWarningIDs.contains(trigger.id)
        case .schedule(let task):
            schedule.clearingWarningIDs.contains(task.id)
        }
    }

    func deleteAgent(_ definition: AgentDefinition) {
        switch definition {
        case .trigger(let trigger):
            eventAutomations.deleteTrigger(trigger)
        case .schedule(let task):
            schedule.deleteSchedule(task)
        }
    }

    /// Only schedules can be run on demand; an event agent waits for events.
    func runAgentNow(_ definition: AgentDefinition) {
        if case .schedule(let task) = definition {
            schedule.runScheduleNow(task)
        }
    }

    /// The agent whose events land in this chat, if that agent still exists.
    /// Deleting the chat would strand the agent, so callers refuse.
    func agentOwningEventChat(_ session: SessionSummary) -> AgentDefinition? {
        if let trigger = eventAutomations.triggers.first(where: { $0.targetSessionID == session.id }) {
            return .trigger(trigger)
        }
        guard session.isAgentEventChat else { return nil }
        return session.agentReference(in: agentDefinitions).flatMap(inspectorAgentDefinition)
    }

    /// Any existing chat of the agent, which is what the backend's task
    /// endpoint keys on. Prefers the current chat, so New chat from inside an
    /// agent's conversation stays with that agent.
    func agentSession(
        for triggerID: String?,
        in snapshot: SessionCatalogSnapshot
    ) -> SessionSummary? {
        let current = snapshot.sessionsByID[currentSessionID]
        if let triggerID = triggerID?.nilIfEmpty {
            let reference = inspectedAgentReference.flatMap { $0.agentID == triggerID ? $0 : nil }
                ?? agentDefinition(for: triggerID).map(AgentInspectorAgent.init)
            guard let reference else { return nil }
            if current?.agentReference(in: agentDefinitions) == reference { return current }
            return snapshot.sessions
                .filter { $0.agentReference(in: agentDefinitions) == reference }
                .max { $0.mtime < $1.mtime }
        }
        if current?.agentReference(in: agentDefinitions) != nil { return current }
        return snapshot.sessions
            .filter { $0.agentReference(in: agentDefinitions) != nil }
            .max { $0.mtime < $1.mtime }
    }

    /// Opens Configure Agent on a tab with this agent's configuration
    /// selected, so Run History shows its deliveries rather than the first
    /// configuration's.
    func presentConfigureAgent(focusing trigger: EventTrigger, tab: ConfigureAgentTab) {
        presentConfigureAgent(draftText: "")
        configureAgentTab = tab
        configureAgentFocusConfigurationID =
            "\(trigger.triggerKind == .price ? "price" : "event"):\(trigger.id)"
    }

    /// Opens the trigger's editor inside Configure Agent, presenting the
    /// sheet first when it is not already up.
    func editAgentTrigger(_ trigger: EventTrigger, isDedicatedAgent: Bool) {
        let edit = PendingEventTriggerEdit(
            trigger: trigger,
            targetSessionID: trigger.targetSessionID,
            isDedicatedAgent: isDedicatedAgent
        )
        if configureAgentPresented {
            eventAutomations.presentEditor(
                trigger: edit.trigger,
                targetSessionID: edit.targetSessionID,
                isDedicatedAgent: edit.isDedicatedAgent
            )
        } else {
            configureAgentPendingTriggerEdit = edit
            presentConfigureAgent(draftText: "")
            configureAgentTab = .agents
        }
    }

    /// Session ids whose chat is currently executing, for the agent panel's
    /// running markers.
    var runningChatSessionIDs: Set<String> {
        var ids = Set(taskWorkers.compactMap { id, runtime in
            [.running, .dispatching, .reviewing].contains(runtime.executionState) ? id : nil
        })
        if isBusy { ids.insert(currentSessionID) }
        return ids
    }

    /// Start times for running chats, keyed by session id.
    var runningChatStartTimes: [String: Date] {
        Dictionary(uniqueKeysWithValues: taskWorkers.compactMap { id, runtime in
            runtime.startedAt.map { (id, $0) }
        })
    }
}
