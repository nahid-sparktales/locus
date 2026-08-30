import Foundation

/// Owns the live team run's presentation: the dispatcher's activity card,
/// per-agent activity rows, the pending dispatch plan, and team metering.
/// It is fed one event at a time by AppModel's dispatcher through apply(_:_:);
/// the run's identity and state scalars stay with the composition root and
/// are read through closures. AppModel wires it via configure(...) and
/// bridges its publication; it never retains AppModel.
@MainActor
final class TeamRunLiveModel: ObservableObject {
    @Published var dispatcherActivity: AgentActivity?
    @Published var dispatcherValidationReason: String?
    @Published private(set) var agentActivities: [AgentActivity] = []
    @Published private(set) var teamModelCalls = 0
    @Published private(set) var teamMeteredTokens = 0
    @Published var pendingDispatchPlan: DispatchPlan?

    private var isBusyProvider: () -> Bool = { false }
    private var liveRunID: () -> String? = { nil }
    private var liveState: () -> TeamRunState? = { nil }
    private var selectedRunTeamID: () -> String? = { nil }
    private var teamLookup: (UUID) -> AgentTeam? = { _ in nil }
    private var selectedTeamProvider: () -> AgentTeam? = { nil }

    func configure(
        isBusyProvider: @escaping () -> Bool,
        liveRunID: @escaping () -> String?,
        liveState: @escaping () -> TeamRunState?,
        selectedRunTeamID: @escaping () -> String?,
        teamLookup: @escaping (UUID) -> AgentTeam?,
        selectedTeamProvider: @escaping () -> AgentTeam?
    ) {
        self.isBusyProvider = isBusyProvider
        self.liveRunID = liveRunID
        self.liveState = liveState
        self.selectedRunTeamID = selectedRunTeamID
        self.teamLookup = teamLookup
        self.selectedTeamProvider = selectedTeamProvider
    }

    /// Session restore and reset write the activity rows wholesale — a
    /// resumed session republishes what the backend persisted, and a reset
    /// clears the panel before the next run's events arrive.
    func restoreActivities(_ activities: [AgentActivity]) {
        agentActivities = activities
    }

    func resetMetering() {
        teamModelCalls = 0
        teamMeteredTokens = 0
    }

    var shouldShowTeamDispatchProgress: Bool {
        isBusyProvider() && liveRunID() != nil && liveState() == .dispatching
            && pendingDispatchPlan == nil
    }

    var shouldShowTeamDispatchApproval: Bool {
        liveState() == .waitingDispatchApproval && pendingDispatchPlan != nil
    }

    var activeOrchestrationTeam: AgentTeam? {
        if let id = selectedRunTeamID().flatMap(UUID.init(uuidString:)),
           let team = teamLookup(id)
        {
            return team
        }
        return selectedTeamProvider()
    }

    /// The live-run presentation slice of a backend orchestration event; the
    /// dispatcher applies the run's identity and state scalars itself before
    /// routing the event here.
    func apply(_ type: String, _ event: [String: Any]) {
        switch type {
        case "run_started":
            agentActivities = []
            teamModelCalls = 0
            teamMeteredTokens = 0

        case "orchestration_started":
            dispatcherActivity = nil
            dispatcherValidationReason = nil
            agentActivities = []
            teamModelCalls = 0
            teamMeteredTokens = 0
            pendingDispatchPlan = nil

        case "dispatcher_started":
            dispatcherValidationReason = nil
            let runID = event["run_id"] as? String ?? liveRunID() ?? "current"
            dispatcherActivity = AgentActivity(
                id: "dispatcher-\(runID)",
                agentName: event["agent_name"] as? String ?? "Dispatcher",
                role: AgentRole.dispatcher.rawValue,
                provider: event["provider"] as? String ?? "",
                model: event["model"] as? String ?? "",
                goal: event["goal"] as? String ?? "Creating the team plan",
                state: .running,
                output: "",
                reasoningText: nil,
                tool: nil,
                evidence: [],
                startedAt: Date(),
                elapsedMilliseconds: 0,
                promptTokens: 0,
                completionTokens: 0
            )

        case "dispatcher_completed":
            let state = (event["state"] as? String) == TeamRunState.failed.rawValue
                ? TeamRunState.failed : .completed
            if var activity = dispatcherActivity {
                activity.state = state
                activity.output = event["message"] as? String ?? "Dispatch plan ready"
                activity.elapsedMilliseconds = event["elapsed_ms"] as? Int ?? 0
                activity.promptTokens = event["prompt_tokens"] as? Int ?? 0
                activity.completionTokens = event["completion_tokens"] as? Int ?? 0
                dispatcherActivity = activity
            }
            applyMeteredUsage(event, delegated: false)

        case "dispatcher_plan_rejected":
            dispatcherValidationReason = event["reason"] as? String
            if var activity = dispatcherActivity {
                activity.state = .running
                activity.output = event["message"] as? String
                    ?? event["reason"] as? String
                    ?? "Correcting dispatcher plan…"
                dispatcherActivity = activity
            }

        case "dispatch_plan_ready":
            if let raw = event["plan"] as? [String: Any] {
                pendingDispatchPlan = decode(DispatchPlan.self, from: raw)
            }

        case "agent_spawned":
            let nodeID = event["node_id"] as? String ?? UUID().uuidString
            guard !agentActivities.contains(where: { ($0.nodeID ?? $0.id) == nodeID }) else {
                return
            }
            agentActivities.append(AgentActivity(
                id: event["job_id"] as? String ?? nodeID,
                agentName: event["agent_name"] as? String ?? "Hosted agent",
                role: event["role"] as? String ?? "researcher",
                provider: event["provider"] as? String ?? "",
                model: event["model"] as? String ?? "",
                goal: event["goal"] as? String ?? "Gathering evidence",
                state: .running,
                output: "Branch started",
                reasoningText: nil,
                tool: nil,
                evidence: [],
                startedAt: Date(),
                elapsedMilliseconds: 0,
                promptTokens: 0,
                completionTokens: 0,
                writerJobID: nil,
                writerPosition: nil,
                writerTotal: nil,
                nodeID: nodeID,
                parentNodeID: event["parent_node_id"] as? String,
                depth: event["depth"] as? Int ?? 0,
                executionEngine: event["execution_engine"] as? String
                    ?? "locus_managed"
            ))

        case "agent_job_started":
            let jobID = event["job_id"] as? String ?? UUID().uuidString
            if let index = agentActivities.firstIndex(where: { $0.id == jobID }) {
                agentActivities[index].state = .running
                agentActivities[index].startedAt = Date()
                agentActivities[index].writerJobID = event["writer_job_id"] as? String
                agentActivities[index].writerPosition = event["writer_position"] as? Int
                agentActivities[index].writerTotal = event["writer_total"] as? Int
                agentActivities[index].nodeID = event["node_id"] as? String ?? jobID
                agentActivities[index].parentNodeID = event["parent_node_id"] as? String
                agentActivities[index].depth = event["depth"] as? Int ?? 0
                agentActivities[index].executionEngine = event["execution_engine"] as? String
                    ?? "locus_managed"
            } else {
                agentActivities.append(AgentActivity(
                    id: jobID,
                    agentName: event["agent_name"] as? String ?? "Agent",
                    role: event["role"] as? String ?? "generalist",
                    provider: event["provider"] as? String ?? "",
                    model: event["model"] as? String ?? "",
                    goal: event["goal"] as? String ?? "",
                    state: .running,
                    output: "",
                    reasoningText: nil,
                    tool: nil,
                    evidence: [],
                    startedAt: Date(),
                    elapsedMilliseconds: 0,
                    promptTokens: 0,
                    completionTokens: 0,
                    writerJobID: event["writer_job_id"] as? String,
                    writerPosition: event["writer_position"] as? Int,
                    writerTotal: event["writer_total"] as? Int,
                    nodeID: event["node_id"] as? String ?? jobID,
                    parentNodeID: event["parent_node_id"] as? String,
                    depth: event["depth"] as? Int ?? 0,
                    executionEngine: event["execution_engine"] as? String
                        ?? "locus_managed"
                ))
            }

        case "agent_job_continuing":
            let jobID = event["job_id"] as? String ?? ""
            if let index = agentActivities.firstIndex(where: { $0.id == jobID }) {
                agentActivities[index].state = .running
                agentActivities[index].output = event["message"] as? String
                    ?? "Continuing coding job…"
            }
            applyMeteredUsage(event, delegated: false)

        case "agent_branch_stopped":
            let nodeID = event["node_id"] as? String ?? ""
            if let index = agentActivities.firstIndex(where: {
                ($0.nodeID ?? $0.id) == nodeID
            }) {
                agentActivities[index].state = .interrupted
                agentActivities[index].output = event["message"] as? String
                    ?? event["reason"] as? String
                    ?? "This read-only branch stopped."
            }
            applyMeteredUsage(event, delegated: false)

        case "agent_job_incomplete":
            let jobID = event["job_id"] as? String ?? ""
            if let index = agentActivities.firstIndex(where: { $0.id == jobID }) {
                agentActivities[index].state = .paused
                agentActivities[index].output = event["message"] as? String
                    ?? "This coding job stopped before it finished."
                if let result = event["result"] as? [String: Any] {
                    agentActivities[index].elapsedMilliseconds = result["elapsed_ms"] as? Int ?? 0
                    agentActivities[index].promptTokens = result["prompt_tokens"] as? Int ?? 0
                    agentActivities[index].completionTokens = result["completion_tokens"] as? Int ?? 0
                }
            }
            applyMeteredUsage(event, delegated: false)

        case "agent_job_completed":
            guard let result = event["result"] as? [String: Any] else { return }
            let jobID = result["job_id"] as? String ?? ""
            let rawState = event["state"] as? String
            let state = rawState.flatMap(TeamRunState.init(rawValue:))
                ?? (rawState == "stopped" ? .interrupted : .completed)
            let index = agentActivities.firstIndex(where: { $0.id == jobID })
            let activity = AgentActivity(
                id: jobID.isEmpty ? UUID().uuidString : jobID,
                agentName: result["agent_name"] as? String ?? "Agent",
                role: result["role"] as? String ?? "generalist",
                provider: index.map { agentActivities[$0].provider } ?? "",
                model: index.map { agentActivities[$0].model } ?? "",
                goal: index.map { agentActivities[$0].goal } ?? "",
                state: state,
                output: result["output"] as? String ?? result["error"] as? String ?? "",
                reasoningText: result["reasoning_text"] as? String,
                tool: nil,
                evidence: result["evidence"] as? [String] ?? [],
                startedAt: index.flatMap { agentActivities[$0].startedAt },
                elapsedMilliseconds: result["elapsed_ms"] as? Int ?? 0,
                promptTokens: result["prompt_tokens"] as? Int ?? 0,
                completionTokens: result["completion_tokens"] as? Int ?? 0,
                writerJobID: event["writer_job_id"] as? String
                    ?? index.flatMap { agentActivities[$0].writerJobID },
                writerPosition: event["writer_position"] as? Int
                    ?? index.flatMap { agentActivities[$0].writerPosition },
                writerTotal: event["writer_total"] as? Int
                    ?? index.flatMap { agentActivities[$0].writerTotal },
                nodeID: result["node_id"] as? String
                    ?? event["node_id"] as? String
                    ?? index.flatMap { agentActivities[$0].nodeID }
                    ?? jobID,
                parentNodeID: result["parent_node_id"] as? String
                    ?? event["parent_node_id"] as? String
                    ?? index.flatMap { agentActivities[$0].parentNodeID },
                depth: result["depth"] as? Int
                    ?? event["depth"] as? Int
                    ?? index.map { agentActivities[$0].depth }
                    ?? 0,
                executionEngine: result["execution_engine"] as? String
                    ?? event["execution_engine"] as? String
                    ?? index.map { agentActivities[$0].executionEngine }
                    ?? "locus_managed"
            )
            if let index { agentActivities[index] = activity } else { agentActivities.append(activity) }
            applyMeteredUsage(event, delegated: true)

        case "swarm_telemetry":
            applyMeteredUsage(event, delegated: true)

        case "orchestration_completed":
            applyMeteredUsage(event, delegated: false)

        default:
            break
        }
    }

    /// Usage payloads carry either the run's own metered totals or, for
    /// delegated jobs, per-job token counts that substitute when the total is
    /// absent — matching what each event historically reported.
    private func applyMeteredUsage(_ event: [String: Any], delegated: Bool) {
        guard let usage = event["usage"] as? [String: Any] else { return }
        teamModelCalls = usage["model_calls"] as? Int ?? teamModelCalls
        if delegated {
            teamMeteredTokens = usage["delegated_tokens"] as? Int
                ?? ((usage["prompt_tokens"] as? Int ?? 0)
                    + (usage["completion_tokens"] as? Int ?? 0))
        } else {
            teamMeteredTokens = usage["metered_tokens"] as? Int ?? teamMeteredTokens
        }
    }
}
