import Foundation

/// A single timeline preserves typed provenance even if a schedule and an
/// incoming event share the same storage ID. Duration belongs to executions,
/// not receipt timestamps, and is deliberately left to the run inspector.
struct AgentActivityRecord: Identifiable {
    let id: String
    let agent: AgentInspectorAgent
    let agentName: String
    let title: String
    let sourceTitle: String
    let timestamp: Double
    let state: String
    let error: String?
    let context: AgentInspectorContext
    let delivery: EventDelivery?

    var needsAttention: Bool {
        ["failed", "interrupted", "waiting_permission", "waiting_computer",
         "waiting_dispatch_approval", "waiting_approval"].contains(state)
            || (state != "skipped" && error?.isEmpty == false)
    }
    var isInProgress: Bool {
        ["pending", "queued", "claiming", "dispatching", "planning", "running", "advancing", "awaiting_run"].contains(state)
    }
    var canRetry: Bool {
        delivery.map { ["failed", "interrupted", "cancelled"].contains($0.state) } ?? false
    }
    var statusTitle: String {
        switch state {
        case "running", "advancing": "Running"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        default: AgentInspectorCopy.state(state)
        }
    }
    var symbol: String {
        if needsAttention { return "exclamationmark.circle.fill" }
        if isInProgress { return "circle.dotted" }
        switch state {
        case "completed": return "checkmark.circle.fill"
        case "skipped": return "forward.end.circle"
        case "cancelled", "discarded": return "xmark.circle"
        case "paused": return "pause.circle"
        default: return "questionmark.circle"
        }
    }

    static func merged(deliveries: [EventDelivery], occurrences: [ScheduleOccurrence], definitions: [AgentDefinition]) -> [Self] {
        let events = deliveries.map { delivery in
            let agent = AgentInspectorAgent(kind: .event, agentID: delivery.triggerID)
            let name = definitions.first { !$0.isSchedule && $0.id == delivery.triggerID }?.name ?? "Removed Agent"
            let state = AgentInspectorCopy.effectiveActivityState(
                deliveryState: delivery.state, runState: delivery.runState
            )
            return Self(id: "event:\(delivery.id)", agent: agent, agentName: name,
                title: delivery.event.subject.isEmpty ? delivery.event.eventType : delivery.event.subject,
                sourceTitle: delivery.source.title, timestamp: delivery.receivedAt, state: state,
                error: delivery.error, context: .event(agent, deliveryID: delivery.id), delivery: delivery)
        }
        let runs = occurrences.map { occurrence in
            let agent = AgentInspectorAgent(kind: .schedule, agentID: occurrence.scheduleID)
            return Self(id: "schedule:\(occurrence.id)", agent: agent,
                agentName: definitions.first { $0.isSchedule && $0.id == occurrence.scheduleID }?.name ?? occurrence.scheduleName,
                title: occurrence.trigger == "manual" ? "Started manually" : "Scheduled run",
                sourceTitle: "Schedule", timestamp: occurrence.scheduledFor, state: occurrence.state,
                error: occurrence.error, context: .occurrence(agent, occurrenceID: occurrence.id), delivery: nil)
        }
        return (events + runs).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }
    }
}

enum AgentActivityFilter: String, CaseIterable, Identifiable {
    case all, attention, inProgress, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All statuses"
        case .attention: "Needs attention"
        case .inProgress: "In progress"
        case .completed: "Completed"
        }
    }
    func includes(_ record: AgentActivityRecord) -> Bool {
        switch self {
        case .all: true
        case .attention: record.needsAttention
        case .inProgress: record.isInProgress
        case .completed: record.state == "completed" && !record.needsAttention
        }
    }
}
