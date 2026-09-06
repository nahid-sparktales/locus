import Foundation

extension AppModel {
    /// The same seeded store rows feed parent and child screens. Fixtures
    /// never fetch a real backend or manufacture a newest-event substitute.
    func seedAgentInspectorContextForUITesting() {
        guard isUITesting else { return }
        var snapshot = AgentInspectorSnapshot()
        switch agentInspector.context {
        case .fleet: return
        case .agent(let agent):
            let deliveries = eventAutomations.deliveries.filter { $0.triggerID == agent.agentID }
            let occurrences = schedule.occurrencesBySchedule[agent.agentID] ?? []
            let states = agent.kind == .event ? deliveries.map { $0.runState ?? $0.state } : occurrences.map(\.state)
            snapshot.history = AgentInspectorHistory(
                deliveries: agent.kind == .event ? deliveries : nil,
                occurrences: agent.kind == .schedule ? occurrences : nil,
                total: states.count, counts: states.reduce(into: [:]) { $0[$1, default: 0] += 1 }
            )
        case .chat(_, let sessionID):
            snapshot.runs = orchestrationRuns.filter { $0.sessionID == sessionID }
        case .event(_, let deliveryID):
            if let delivery = eventAutomations.deliveries.first(where: { $0.id == deliveryID }) {
                let run = agentInspectorFixtureRun(for: delivery)
                snapshot.item = AgentInspectorItem(delivery: delivery, occurrence: nil,
                    executions: run.map { [AgentInspectorExecution(runID: $0.id, attempt: 1,
                        createdAt: $0.createdAt, state: $0.state, sessionID: $0.sessionID, retryParentID: nil)] } ?? [],
                    workflowExecutionID: nil, deliveryState: delivery.state,
                    executionState: delivery.runState)
            }
        case .occurrence(_, let occurrenceID):
            if let occurrence = schedule.occurrencesBySchedule.values.flatMap({ $0 }).first(where: { $0.id == occurrenceID }) {
                snapshot.item = AgentInspectorItem(delivery: nil, occurrence: occurrence, executions: [], workflowExecutionID: nil)
            }
        case .run(_, let runID, _):
            snapshot.run = runDetailsByID[runID] ?? orchestrationRuns.first { $0.id == runID }
                ?? eventAutomations.deliveries.compactMap { agentInspectorFixtureRun(for: $0) }.first { $0.id == runID }
            snapshot.events = orchestrationEvents(for: runID)
        }
        agentInspector.seedForUITesting(snapshot)
    }

    private func agentInspectorFixtureRun(for delivery: EventDelivery) -> OrchestrationRun? {
        guard delivery.id == "seed-delivery-done" else { return nil }
        let workspace = workspacePath
        let value: [String: Any] = [
            "id": "agent-inspector-\(delivery.id)", "session_id": delivery.conversationSessionID ?? "seed-agent-chat",
            "state": "completed", "request": "Summarize the invoice", "workspace_root": workspace,
            "created_at": delivery.receivedAt, "admitted_at": delivery.receivedAt + 10,
            "completed_at": delivery.updatedAt, "updated_at": delivery.updatedAt,
            "last_seq": 0, "pinned": false, "legacy": false, "recoverable": false,
            "usage": ["prompt_tokens": 1200, "completion_tokens": 300, "model_calls": 1],
            "manifest": ["event_triggered": true, "event_trigger_id": delivery.triggerID,
                         "event_delivery_id": delivery.id],
        ]
        return (try? JSONSerialization.data(withJSONObject: value))
            .flatMap { try? JSONDecoder().decode(OrchestrationRun.self, from: $0) }
    }
}
