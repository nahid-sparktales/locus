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
    /// The sidebar's primary button and ⌘N share this. Each destination creates
    /// the thing it is about: Ask makes a chat in the workspace, Agents makes an
    /// agent. Chatting with an existing agent is a per-agent action, reached
    /// from that agent's row or from the Agent panel, because it needs to name
    /// which agent it belongs to.
    func newChatForSidebarDestination() {
        if sidebarDestination == .agents {
            presentNewAgent()
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

    /// Starts another chat for an agent. Without a trigger id it uses the
    /// current chat's agent, then the most recent agent; with no agents at
    /// all it opens Configure Agent, which is where one is made.
    func newAgentChat(triggerID: String? = nil) {
        let snapshot = sessionCatalog.snapshot
        guard let agent = agentSession(for: triggerID, in: snapshot) else {
            presentConfigureAgent(draftText: draftText)
            return
        }
        // Chats outlive their trigger. Once the trigger list has loaded, a
        // missing trigger means the backend would refuse the chat anyway.
        let triggers = eventAutomations.triggers
        if !triggers.isEmpty, !triggers.contains(where: { $0.id == agent.agentTriggerID }) {
            showToast("This agent's trigger was deleted. Configure a new agent to start chats.")
            return
        }
        let number = snapshot.sessions.filter {
            $0.agentTriggerID == agent.agentTriggerID
        }.count + 1
        Task { @MainActor [weak self] in
            await self?.eventAutomations.createTask(for: agent, name: "Chat \(number)")
        }
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
