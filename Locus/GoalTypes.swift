import Foundation

enum GoalStatus: String, Codable, Hashable {
    case active, paused, blocked, completed, cancelled
    case limitReached = "limit_reached"
    case needsReview = "needs_review"

    var title: String {
        switch self {
        case .active: "Working toward goal"
        case .paused: "Goal paused"
        case .needsReview: "Needs review"
        case .blocked: "Goal needs attention"
        case .limitReached: "Goal allowance reached"
        case .completed: "Goal completed"
        case .cancelled: "Goal ended"
        }
    }

    var isTerminal: Bool { self == .completed || self == .cancelled }
    var canResume: Bool { self == .paused || self == .blocked || self == .limitReached || self == .needsReview }
}

/// The backend owns this session-scoped record. Execution contains saved route
/// identifiers and behavior, never account credentials.
struct PersistentGoal: Codable, Hashable, Identifiable {
    var id: String
    var sessionID: String
    var objective: String
    var revision: Int = 1
    var status: GoalStatus = .active
    var reason: String?
    var summary: String?
    var evidence: [String] = []
    var verificationStatus: String = "legacy_unverified"
    var acceptanceChecks: [[String: JSONValue]] = []
    var evidenceIDs: [String] = []
    var nextStep: String?
    var modelCallBudget: Int?
    var tokenBudget: Int?
    var modelCalls: Int = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var tokenUsageAvailable = true
    var modelCallUsageAvailable = true
    var execution: [String: JSONValue] = [:]
    var currentRunID: String?
    var pendingUserInput: Bool = false
    var createdAt: JSONValue?
    var updatedAt: JSONValue?

    var totalTokens: Int {
        let (total, overflow) = promptTokens.addingReportingOverflow(completionTokens)
        return overflow ? Int.max : total
    }

    var routeLabel: String {
        [execution["model"]?.string, execution["provider"]?.string]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case id, objective, revision, status, reason, summary, evidence, execution
        case verificationStatus = "verification_status"
        case acceptanceChecks = "acceptance_checks", evidenceIDs = "evidence_ids"
        case sessionID = "session_id", nextStep = "next_step"
        case modelCallBudget = "model_call_budget", tokenBudget = "token_budget"
        case modelCalls = "model_calls", promptTokens = "prompt_tokens", completionTokens = "completion_tokens"
        case tokenUsageAvailable = "token_usage_available", modelCallUsageAvailable = "model_call_usage_available"
        case currentRunID = "current_run_id", pendingUserInput = "pending_user_input"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    init(id: String, sessionID: String, objective: String, revision: Int = 1,
         status: GoalStatus = .active, execution: [String: JSONValue] = [:]) {
        self.id = id
        self.sessionID = sessionID
        self.objective = objective
        self.revision = revision
        self.status = status
        self.execution = execution
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        objective = try c.decode(String.self, forKey: .objective)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        status = try c.decode(GoalStatus.self, forKey: .status)
        verificationStatus = try c.decodeIfPresent(String.self, forKey: .verificationStatus) ?? "legacy_unverified"
        acceptanceChecks = try c.decodeIfPresent([[String: JSONValue]].self, forKey: .acceptanceChecks) ?? []
        evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        if let items = try? c.decode([String].self, forKey: .evidence) { evidence = items }
        else if let value = try? c.decode(String.self, forKey: .evidence), !value.isEmpty { evidence = [value] }
        nextStep = try c.decodeIfPresent(String.self, forKey: .nextStep)
        modelCallBudget = try c.decodeIfPresent(Int.self, forKey: .modelCallBudget)
        tokenBudget = try c.decodeIfPresent(Int.self, forKey: .tokenBudget)
        modelCalls = try c.decodeIfPresent(Int.self, forKey: .modelCalls) ?? 0
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        tokenUsageAvailable = try c.decodeIfPresent(Bool.self, forKey: .tokenUsageAvailable) ?? true
        modelCallUsageAvailable = try c.decodeIfPresent(Bool.self, forKey: .modelCallUsageAvailable) ?? true
        execution = try c.decodeIfPresent([String: JSONValue].self, forKey: .execution) ?? [:]
        currentRunID = try c.decodeIfPresent(String.self, forKey: .currentRunID)
        pendingUserInput = try c.decodeIfPresent(Bool.self, forKey: .pendingUserInput) ?? false
        createdAt = try c.decodeIfPresent(JSONValue.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(JSONValue.self, forKey: .updatedAt)
    }
}

struct GoalsResponse: Decodable { var goals: [PersistentGoal] }
struct SessionGoalResponse: Decodable { var goal: PersistentGoal? }
struct GoalClaimResponse: Decodable { var goal: PersistentGoal; var run: OrchestrationRun? }
