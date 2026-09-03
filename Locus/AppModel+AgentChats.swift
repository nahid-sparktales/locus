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
    /// The sidebar's primary button and ⌘N share this. Both destinations start
    /// chats: Ask starts a workspace chat, while Agents starts the next chat for
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
    /// current chat's agent, then the most recent agent; with no agents at
    /// all it opens Manage Agents, which is where one is made.
    func newAgentChat(triggerID: String? = nil) {
        let snapshot = sessionCatalog.snapshot
        guard let agent = agentSession(for: triggerID, in: snapshot) else {
            presentConfigureAgent(draftText: draftText)
            return
        }
        // Chats outlive their agent. Once the definitions are in, a missing
        // one means the backend would refuse the chat anyway.
        if agentDefinition(for: agent.agentTriggerID) == nil, agentDefinitionsLoaded {
            showToast("This agent was deleted. Configure a new agent to start chats.")
            return
        }
        let number = snapshot.sessions.filter {
            $0.agentTriggerID == agent.agentTriggerID
        }.count + 1
        Task { @MainActor [weak self] in
            await self?.openAgentSideChat(for: agent, name: "Chat \(number)")
        }
    }

    /// Opens a side chat once it is known which kind of agent owns it. The two
    /// kinds have different endpoints, so guessing before both stores have
    /// answered would post a schedule's chat to the trigger route.
    private func openAgentSideChat(for agent: SessionSummary, name: String) async {
        var definition = agentDefinition(for: agent.agentTriggerID)
        if definition == nil, !agentDefinitionsLoaded {
            await eventAutomations.refresh(announceFailure: false)
            await schedule.refreshScheduledTasks(announceFailure: false)
            definition = agentDefinition(for: agent.agentTriggerID)
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
        return agentDefinition(for: session.agentTriggerID)
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
            if current?.agentTriggerID == triggerID { return current }
            return snapshot.sessions
                .filter { $0.agentTriggerID == triggerID }
                .max { $0.mtime < $1.mtime }
        }
        if current?.isAgentChat == true { return current }
        return snapshot.sessions
            .filter(\.isAgentChat)
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
