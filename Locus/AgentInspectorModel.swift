import Combine
import Foundation

/// A schedule and an event trigger can have the same storage ID. Their
/// inspector identity must still be different.
struct AgentInspectorAgent: Hashable, Identifiable {
    enum Kind: String, Hashable { case event, schedule }
    let kind: Kind
    let agentID: String
    var id: String { "\(kind.rawValue):\(agentID)" }

    init(kind: Kind, agentID: String) {
        self.kind = kind
        self.agentID = agentID
    }

    init(_ definition: AgentDefinition) {
        kind = definition.isSchedule ? .schedule : .event
        agentID = definition.id
    }
}

enum AgentInspectorOrigin: Hashable {
    case chat(String)
    case event(String)
    case occurrence(String)
}

enum AgentInspectorContext: Hashable {
    case fleet
    case agent(AgentInspectorAgent)
    case chat(AgentInspectorAgent, sessionID: String)
    case event(AgentInspectorAgent, deliveryID: String)
    case occurrence(AgentInspectorAgent, occurrenceID: String)
    case run(AgentInspectorAgent, runID: String, origin: AgentInspectorOrigin?)

    var agent: AgentInspectorAgent? {
        switch self {
        case .fleet: nil
        case .agent(let agent), .chat(let agent, _), .event(let agent, _),
             .occurrence(let agent, _), .run(let agent, _, _): agent
        }
    }

    var parent: AgentInspectorContext? {
        switch self {
        case .fleet: nil
        case .agent: .fleet
        case .chat(let agent, _), .event(let agent, _), .occurrence(let agent, _): .agent(agent)
        case .run(let agent, _, let origin):
            switch origin {
            case .chat(let id): .chat(agent, sessionID: id)
            case .event(let id): .event(agent, deliveryID: id)
            case .occurrence(let id): .occurrence(agent, occurrenceID: id)
            case nil: .agent(agent)
            }
        }
    }
}

struct AgentInspectorHistory: Decodable {
    var deliveries: [EventDelivery]?
    var occurrences: [ScheduleOccurrence]?
    let total: Int
    let counts: [String: Int]
    var nextCursor: String?
    var workflowExecutionIDs: [String: String]? = nil

    enum CodingKeys: String, CodingKey {
        case deliveries, occurrences, total, counts
        case nextCursor = "next_cursor"
        case workflowExecutionIDs = "workflow_execution_ids"
    }

    var completedCount: Int { counts["completed", default: 0] }
    var attentionCount: Int {
        ["failed", "interrupted", "paused", "waiting_permission", "waiting_computer",
         "waiting_dispatch_approval", "waiting_approval"]
            .reduce(0) { $0 + counts[$1, default: 0] }
    }
    var activeCount: Int {
        ["pending", "claiming", "queued", "dispatching", "planning", "advancing", "awaiting_run", "running"]
            .reduce(0) { $0 + counts[$1, default: 0] }
    }

    struct Boundary: Comparable {
        let timestamp: Double
        let createdAt: Double
        let id: String
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    var loadedBoundary: Boundary? {
        if let last = deliveries?.last {
            return Boundary(timestamp: last.receivedAt, createdAt: last.createdAt, id: last.id)
        }
        if let last = occurrences?.last {
            return Boundary(timestamp: last.scheduledFor, createdAt: last.createdAt, id: last.id)
        }
        return nil
    }

    func appending(_ page: Self) -> Self {
        var merged = page
        var events = deliveries ?? []
        for item in page.deliveries ?? [] {
            if let index = events.firstIndex(where: { $0.id == item.id }) { events[index] = item }
            else { events.append(item) }
        }
        var slots = occurrences ?? []
        for item in page.occurrences ?? [] {
            if let index = slots.firstIndex(where: { $0.id == item.id }) { slots[index] = item }
            else { slots.append(item) }
        }
        merged.deliveries = events
        merged.occurrences = slots
        merged.workflowExecutionIDs = (workflowExecutionIDs ?? [:])
            .merging(page.workflowExecutionIDs ?? [:]) { _, fresh in fresh }
        return merged
    }
}

struct AgentInspectorExecution: Decodable, Identifiable {
    let runID: String
    let attempt: Int
    let createdAt: Double?
    let state: String?
    let sessionID: String?
    let retryParentID: String?
    var id: String { runID }

    enum CodingKeys: String, CodingKey {
        case attempt, state
        case runID = "run_id"
        case createdAt = "created_at"
        case sessionID = "session_id"
        case retryParentID = "retry_parent_id"
    }
}

struct AgentInspectorItem: Decodable {
    let delivery: EventDelivery?
    let occurrence: ScheduleOccurrence?
    let executions: [AgentInspectorExecution]
    let workflowExecutionID: String?
    var deliveryState: String? = nil
    var executionState: String? = nil

    enum CodingKeys: String, CodingKey {
        case delivery, occurrence, executions
        case workflowExecutionID = "workflow_execution_id"
        case deliveryState = "delivery_state"
        case executionState = "execution_state"
    }
}

struct AgentInspectorSnapshot {
    var history: AgentInspectorHistory?
    var item: AgentInspectorItem?
    var runs: [OrchestrationRun] = []
    var run: OrchestrationRun?
    var events: [OrchestrationEvent] = []
}

struct AgentInspectorPresentation {
    var scrollAnchor: String?
    var expandedDetails = false
    var expandedInstructions = false
    var expandedIncomingContent = false
}

/// Selection and remote state share a generation boundary. A response for A
/// cannot replace B after navigation, including when the user returns to A.
@MainActor
final class AgentInspectorModel: ObservableObject {
    @Published private(set) var context: AgentInspectorContext = .fleet
    @Published private(set) var selectedAgent: AgentInspectorAgent?
    private(set) var hasSelectedContext = false
    @Published private(set) var snapshot = AgentInspectorSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedAt: Date?
    @Published var presentation: [AgentInspectorContext: AgentInspectorPresentation] = [:]
    private var generation = UUID()
    private var requestID = UUID()
    private var cached: [AgentInspectorContext: (AgentInspectorSnapshot, Date)] = [:]

    func show(_ context: AgentInspectorContext) {
        hasSelectedContext = true
        if let agent = context.agent { selectedAgent = agent }
        guard self.context != context else { return }
        self.context = context
        generation = UUID()
        snapshot = cached[context]?.0 ?? AgentInspectorSnapshot()
        isLoading = false
        error = nil
        loadedAt = cached[context]?.1
    }

    func back() {
        if let parent = context.parent { show(parent) }
    }

    func clearAgentSelection() { selectedAgent = nil }

    func seedForUITesting(_ snapshot: AgentInspectorSnapshot) {
        self.snapshot = snapshot
        loadedAt = Date()
        error = nil
    }

    func refresh(backend: BackendService, append: Bool = false) async {
        await load(append: append) { context, cursor in
            try await Self.fetch(context, cursor: cursor, backend: backend)
        }
    }

    /// Injectable boundary for deterministic out-of-order response tests.
    func load(
        append: Bool = false,
        loader: (AgentInspectorContext, String?) async throws -> AgentInspectorSnapshot
    ) async {
        guard context != .fleet else { return }
        if append && (isLoading || snapshot.history?.nextCursor == nil) { return }
        let requestedContext = context
        let requestedGeneration = generation
        let requestedID = UUID()
        requestID = requestedID
        let cursor = append ? snapshot.history?.nextCursor : nil
        let refreshBoundary = !append &&
            ((snapshot.history?.deliveries?.count ?? 0) + (snapshot.history?.occurrences?.count ?? 0) > 30)
            ? snapshot.history?.loadedBoundary : nil
        isLoading = true
        defer {
            if generation == requestedGeneration && requestID == requestedID { isLoading = false }
        }
        do {
            var result = try await loader(requestedContext, cursor)
            guard !Task.isCancelled, requestedGeneration == generation,
                  requestID == requestedID else { return }
            if append, let history = result.history, let existing = snapshot.history {
                result.history = existing.appending(history)
            } else if let boundary = refreshBoundary, var history = result.history {
                // Refresh every loaded page through the old visible boundary.
                // New arrivals and deleted boundary rows cannot skip old rows;
                // selection and scroll stay tied to their exact stable IDs.
                var seenCursors: Set<String> = []
                while let next = history.nextCursor,
                      history.loadedBoundary.map({ $0 > boundary }) ?? true {
                    guard seenCursors.insert(next).inserted else { throw AgentInspectorError.invalidPage }
                    let page = try await loader(requestedContext, next)
                    guard !Task.isCancelled, requestedGeneration == generation,
                          requestID == requestedID else { return }
                    guard let nextHistory = page.history else { throw AgentInspectorError.invalidPage }
                    history = history.appending(nextHistory)
                }
                result.history = history
            }
            snapshot = result
            loadedAt = Date()
            cached[requestedContext] = (result, loadedAt!)
            if cached.count > 64, let oldest = cached.min(by: { $0.value.1 < $1.value.1 })?.key {
                cached.removeValue(forKey: oldest)
                presentation.removeValue(forKey: oldest)
            }
            error = nil
        } catch {
            guard !Task.isCancelled, generation == requestedGeneration, requestID == requestedID else { return }
            self.error = loadedAt == nil
                ? "This information could not be loaded. It may no longer be available."
                : "Could not refresh. Showing the last saved information."
        }
    }

    private static func fetch(
        _ context: AgentInspectorContext, cursor: String?, backend: BackendService
    ) async throws -> AgentInspectorSnapshot {
        var result = AgentInspectorSnapshot()
        switch context {
        case .fleet: break
        case .agent(let agent):
            let route = agent.kind == .event ? "event-triggers" : "schedules"
            var query = [URLQueryItem(name: "limit", value: "30")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            result.history = try await backend.get(
                "/api/\(route)/\(segment(agent.agentID))/history", query: query,
                as: AgentInspectorHistory.self
            )
        case .chat(_, let sessionID):
            let response = try await backend.get(
                "/api/runs", query: [URLQueryItem(name: "session_id", value: sessionID),
                                     URLQueryItem(name: "limit", value: "30")],
                as: AgentInspectorRunsResponse.self
            )
            result.runs = response.runs
        case .event(let agent, let deliveryID):
            let item = try await backend.get(
                "/api/event-deliveries/\(segment(deliveryID))", as: AgentInspectorItem.self
            )
            guard item.delivery?.triggerID == agent.agentID, agent.kind == .event else {
                throw AgentInspectorError.wrongOwner
            }
            result.item = item
        case .occurrence(let agent, let occurrenceID):
            let item = try await backend.get(
                "/api/schedule-occurrences/\(segment(occurrenceID))", as: AgentInspectorItem.self
            )
            guard item.occurrence?.scheduleID == agent.agentID, agent.kind == .schedule else {
                throw AgentInspectorError.wrongOwner
            }
            result.item = item
        case .run(let agent, let runID, let origin):
            let run = try await backend.get("/api/runs/\(segment(runID))", as: OrchestrationRun.self)
            switch origin {
            case .chat(let sessionID):
                guard run.sessionID == sessionID else { throw AgentInspectorError.wrongOwner }
            case .event(let deliveryID):
                let item = try await backend.get("/api/event-deliveries/\(segment(deliveryID))", as: AgentInspectorItem.self)
                guard agent.kind == .event, item.delivery?.triggerID == agent.agentID,
                      item.executions.contains(where: { $0.runID == runID }) else { throw AgentInspectorError.wrongOwner }
            case .occurrence(let occurrenceID):
                let item = try await backend.get("/api/schedule-occurrences/\(segment(occurrenceID))", as: AgentInspectorItem.self)
                guard agent.kind == .schedule, item.occurrence?.scheduleID == agent.agentID,
                      item.executions.contains(where: { $0.runID == runID }) else { throw AgentInspectorError.wrongOwner }
            case nil:
                guard (agent.kind == .schedule && run.scheduleID == agent.agentID)
                    || (agent.kind == .event && run.manifest?["event_trigger_id"]?.string == agent.agentID)
                else { throw AgentInspectorError.wrongOwner }
            }
            let response = try await backend.get(
                "/api/runs/\(segment(runID))/events",
                query: [URLQueryItem(name: "after_seq", value: "\(max(run.lastSequence - 100, 0))"),
                        URLQueryItem(name: "limit", value: "100")],
                as: AgentInspectorEventsResponse.self
            )
            result.run = run
            result.events = response.events.filter { !$0.isTransientStream }
        }
        return result
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

extension SessionSummary {
    /// Explicit metadata wins. A legacy bare ID is usable only when one
    /// definition owns it, or an event's durable target identifies this chat.
    func agentReference(in definitions: [AgentDefinition]) -> AgentInspectorAgent? {
        guard let id = agentTriggerID?.nilIfEmpty else { return nil }
        if let kind = agentKind?.nilIfEmpty {
            guard let parsed = AgentInspectorAgent.Kind(rawValue: kind) else { return nil }
            return AgentInspectorAgent(kind: parsed, agentID: id)
        }
        let matches = definitions.filter { $0.id == id }
        if matches.count == 1 { return AgentInspectorAgent(matches[0]) }
        if let owner = matches.first(where: { $0.trigger?.targetSessionID == self.id }) {
            return AgentInspectorAgent(owner)
        }
        return nil
    }
}

private enum AgentInspectorError: Error { case wrongOwner, invalidPage }
private struct AgentInspectorRunsResponse: Decodable { let runs: [OrchestrationRun] }
private struct AgentInspectorEventsResponse: Decodable { let events: [OrchestrationEvent] }

enum AgentInspectorCopy {
    static func deliveryState(_ state: String) -> String {
        switch state {
        case "pending": "Received, waiting to start"
        case "claiming": "Preparing the handoff"
        case "queued": "Accepted for processing"
        case "completed": "Processed"
        case "failed", "interrupted": "Could not finish processing"
        case "cancelled": "Cancelled"
        case "skipped": "Skipped this time"
        default: "Received"
        }
    }

    static func state(_ state: String) -> String {
        switch state {
        case "pending", "queued": "Waiting to start"
        case "claiming", "dispatching", "planning": "Getting ready"
        case "running", "advancing", "awaiting_run": "Working"
        case "waiting_permission", "waiting_dispatch_approval", "waiting_approval": "Needs your approval"
        case "waiting_computer": "Waiting for computer access"
        case "completed": "Completed"
        case "failed": "Needs attention"
        case "interrupted": "Stopped before finishing"
        case "cancelled", "discarded": "Cancelled"
        case "skipped": "Skipped this time"
        case "paused": "Paused"
        default: "Status unavailable"
        }
    }
}
