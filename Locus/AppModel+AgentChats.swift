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

    func selectAgent(_ reference: AgentInspectorAgent) {
        let agentID = reference.agentID
        selectedAgentID = agentID
        agentInspector.show(.agent(reference))
        sidebarDestination = .agents
        selectInspectorTab(.agent)
    }

    func inspectAgentChat(_ session: SessionSummary) {
        guard session.isAgentChat else { return }
        guard let reference = session.agentReference(in: agentDefinitions) else {
            agentInspector.clearAgentSelection()
            selectedAgentID = nil
            agentInspector.show(.fleet)
            showToast("This saved chat’s agent kind is unavailable. Choose an agent to start a new conversation.")
            return
        }
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

    /// The sidebar's primary button and ⌘N share this. Both destinations start
    /// chats: Work starts a workspace chat, while Agent starts the next chat for
    /// the current (or most recently used) agent.
    func newChatForSidebarDestination() {
        if sidebarDestination == .agents {
            newAgentChat()
        } else {
            newSession()
        }
    }

    /// Opens Configure Agent straight into an empty trigger editor. The first
    /// field there is the kind, so a person who wanted a price alert is one
    /// control away rather than back at the sheet's creation cards.
    func presentNewAgent(kind: EventTriggerKind = .event) {
        configureAgentPendingTriggerEdit = PendingEventTriggerEdit(
            trigger: nil,
            targetSessionID: currentSessionID,
            triggerKind: kind
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

    /// Opens a side chat once it is known which kind of agent owns it. The two
    /// kinds have different endpoints, so guessing before both stores have
    /// answered would post a schedule's chat to the trigger route.
    private func openAgentSideChat(for agent: SessionSummary, name: String) async {
        var definition = agent.agentReference(in: agentDefinitions).flatMap(inspectorAgentDefinition)
        if definition == nil, !agentDefinitionsLoaded {
            await eventAutomations.refresh(announceFailure: false)
            await schedule.refreshScheduledTasks(announceFailure: false)
            definition = agent.agentReference(in: agentDefinitions).flatMap(inspectorAgentDefinition)
        }
        guard let definition else {
            showToast("This agent was deleted. Configure a new agent to start chats.")
            return
        }
        if let task = definition.schedule {
            await createScheduleChat(task, name: name)
            return
        }
        await eventAutomations.createTask(for: agent, name: name)
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
