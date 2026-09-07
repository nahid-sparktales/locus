import Foundation

enum TaskCapsuleWorkspace {
    static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// A planner's durable instructions for one independently verifiable step.
struct CapsulePlanStep: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var instructions: String
    var dependencies: [String]
    var files: [String]
    var checks: [String]

    init(id: String = UUID().uuidString, title: String = "", instructions: String = "",
         dependencies: [String] = [], files: [String] = [], checks: [String] = []) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.dependencies = dependencies
        self.files = files
        self.checks = checks
    }

    private enum CodingKeys: String, CodingKey { case id, title, instructions, dependencies, files, checks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        checks = try c.decodeIfPresent([String].self, forKey: .checks) ?? []
    }
}

struct TaskCapsuleRecipe: Codable, Hashable {
    var plannerProfileID = ""
    var executorProfileID = ""
    var reviewerProfileID: String?
    var planningCallLimit = 12
    var executionCallLimit = 60
    var maxRepairAttempts = 2
    var maxPlannerEscalations = 1
    var maximumEstimatedCost: Double?

    private enum CodingKeys: String, CodingKey {
        case plannerProfileID = "planner_profile_id", executorProfileID = "executor_profile_id"
        case reviewerProfileID = "reviewer_profile_id", planningCallLimit = "planning_call_limit"
        case executionCallLimit = "execution_call_limit", maxRepairAttempts = "max_repair_attempts"
        case maxPlannerEscalations = "max_planner_escalations", maximumEstimatedCost = "maximum_estimated_cost"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plannerProfileID = try c.decodeIfPresent(String.self, forKey: .plannerProfileID) ?? ""
        executorProfileID = try c.decodeIfPresent(String.self, forKey: .executorProfileID) ?? ""
        reviewerProfileID = try c.decodeIfPresent(String.self, forKey: .reviewerProfileID)
        planningCallLimit = try c.decodeIfPresent(Int.self, forKey: .planningCallLimit) ?? 12
        executionCallLimit = try c.decodeIfPresent(Int.self, forKey: .executionCallLimit) ?? 60
        maxRepairAttempts = try c.decodeIfPresent(Int.self, forKey: .maxRepairAttempts) ?? 2
        maxPlannerEscalations = try c.decodeIfPresent(Int.self, forKey: .maxPlannerEscalations) ?? 1
        maximumEstimatedCost = try c.decodeIfPresent(Double.self, forKey: .maximumEstimatedCost)
    }
}

struct TaskCapsule: Codable, Hashable, Identifiable {
    var id: String
    var revision: Int
    var title: String
    var request: String
    var workspaceRoot: String
    var plan: PlanDocument
    var recipe: TaskCapsuleRecipe
    var createdAt: String?
    var updatedAt: String?
    var runs: [TaskCapsuleRun]

    var plannerHelpRequestsUsed: Int {
        runs.filter { $0.stage == "escalate" && $0.continuationOfRunID == nil }.count
    }
    var plannerHelpRequestsRemaining: Int { max(0, recipe.maxPlannerEscalations - plannerHelpRequestsUsed) }

    private enum CodingKeys: String, CodingKey {
        case id, revision, title, request, plan, recipe, runs
        case workspaceRoot = "workspace_root", createdAt = "created_at", updatedAt = "updated_at"
    }

    init(id: String = UUID().uuidString, revision: Int = 1, title: String, request: String,
         workspaceRoot: String, plan: PlanDocument, recipe: TaskCapsuleRecipe,
         createdAt: String? = nil, updatedAt: String? = nil, runs: [TaskCapsuleRun] = []) {
        self.id = id
        self.revision = revision
        self.title = title
        self.request = request
        self.workspaceRoot = TaskCapsuleWorkspace.canonicalPath(workspaceRoot)
        self.plan = plan
        self.recipe = recipe
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runs = runs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        title = try c.decode(String.self, forKey: .title)
        request = try c.decodeIfPresent(String.self, forKey: .request) ?? ""
        workspaceRoot = TaskCapsuleWorkspace.canonicalPath(try c.decode(String.self, forKey: .workspaceRoot))
        plan = try c.decode(PlanDocument.self, forKey: .plan)
        recipe = try c.decode(TaskCapsuleRecipe.self, forKey: .recipe)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        runs = try c.decodeIfPresent([TaskCapsuleRun].self, forKey: .runs) ?? []
    }
}

struct TaskCapsuleRun: Codable, Hashable, Identifiable {
    var id: String { runID }
    var runID: String
    var stage: String
    var status: String
    var sessionID: String?
    var modelCalls: Int?
    var totalTokens: Int?
    var estimatedCost: Double?
    var continuationOfRunID: String?

    var stageTitle: String {
        switch stage {
        case "plan": "Planning"
        case "execute": "Implementation"
        case "review": "Review"
        case "escalate": "Planner help"
        case "repair": "Review repair"
        default: stage.capitalized
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, stage, status, state, usage
        case runID = "run_id", sessionID = "session_id", modelCalls = "model_calls"
        case totalTokens = "total_tokens", estimatedCost = "estimated_cost"
        case continuationOfRunID = "continuation_of_run_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decodeIfPresent(String.self, forKey: .runID)
            ?? c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? "execution"
        status = try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .state) ?? "saved"
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        modelCalls = try c.decodeIfPresent(Int.self, forKey: .modelCalls)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
        estimatedCost = try c.decodeIfPresent(Double.self, forKey: .estimatedCost)
        continuationOfRunID = try c.decodeIfPresent(String.self, forKey: .continuationOfRunID)
        if let usage = try c.decodeIfPresent(Usage.self, forKey: .usage) {
            modelCalls = usage.modelCalls ?? modelCalls
            totalTokens = usage.totalTokens ?? totalTokens
            estimatedCost = usage.estimatedCost ?? estimatedCost
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runID, forKey: .runID)
        try c.encode(stage, forKey: .stage)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(modelCalls, forKey: .modelCalls)
        try c.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try c.encodeIfPresent(estimatedCost, forKey: .estimatedCost)
        try c.encodeIfPresent(continuationOfRunID, forKey: .continuationOfRunID)
    }

    private struct Usage: Decodable {
        var modelCalls: Int?
        var totalTokens: Int?
        var estimatedCost: Double?
        private enum CodingKeys: String, CodingKey {
            case modelCalls = "model_calls", meteredTokens = "metered_tokens"
            case promptTokens = "prompt_tokens", completionTokens = "completion_tokens"
            case estimatedCost = "estimated_cost"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func count(_ key: CodingKeys) throws -> Int? {
                guard let value = try c.decodeIfPresent(Double.self, forKey: key), value.isFinite,
                      value >= 0, value < Double(Int.max) else { return nil }
                return Int(value)
            }
            modelCalls = try count(.modelCalls)
            let prompt = try count(.promptTokens)
            let completion = try count(.completionTokens)
            if let prompt, let completion, prompt <= Int.max - completion {
                totalTokens = prompt + completion
            } else { totalTokens = try count(.meteredTokens) }
            estimatedCost = try c.decodeIfPresent(Double.self, forKey: .estimatedCost)
        }
    }
}

struct TaskCapsulePlanningRequest {
    var title: String
    var request: String
    var workspaceRoot: String
    var recipe: TaskCapsuleRecipe
    var capsuleID: String?
    var expectedRevision: Int?
    var blocker: String?
    var originRunID: String?
    var originSessionID: String?
}

struct TaskCapsulesResponse: Decodable { var capsules: [TaskCapsule] }
struct TaskCapsuleResponse: Decodable { var capsule: TaskCapsule }

struct TaskCapsuleValidation: Decodable {
    var valid: Bool
    var changes: [Change]
    struct Change: Decodable { var path: String; var reason: String }
}
