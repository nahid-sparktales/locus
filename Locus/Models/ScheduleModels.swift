import Combine
import Foundation

enum WorkMode: String, CaseIterable, Codable, Identifiable {
    case ask
    case work
    case plan
    case grill

    var id: String { rawValue }

    /// Resolve a stored or wire mode, accepting history. "build" was the GSD
    /// mode, retired in favor of Grill; its profiles and older mobile clients
    /// land on Work, the mode that kept GSD's implement-things behavior.
    static func canonical(_ raw: String) -> WorkMode? {
        WorkMode(rawValue: raw) ?? (raw == "build" ? .work : nil)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let mode = WorkMode.canonical(raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown work mode: \(raw)"
            ))
        }
        self = mode
    }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .work: "Work"
        case .plan: "Plan"
        case .grill: "Grill"
        }
    }

    var description: String {
        switch self {
        case .ask: "Answers without workspace access"
        case .work: "Chooses the right approach for the request"
        case .plan: "Maps the work before editing"
        case .grill: "Stress-tests an idea one question at a time"
        }
    }

    var instruction: String {
        switch self {
        case .ask:
            "Answer conversationally using only the conversation and files or images the user explicitly attached to this message. Do not inspect attachment paths or browse, read, search, or modify any other workspace files. Do not call tools, skills, or external integrations."
        case .work:
            "Solve the request using the workspace and tools when useful. Choose whether to answer, inspect, plan, or implement from the request itself. Follow the current permission policy for every action."
        case .plan:
            "Inspect files if useful, but do not modify anything. Ask clarifying questions when needed by calling ask_question with your options and recommended answer. When the plan is final and decision-complete, call submit_plan exactly once with its title, summary, ordered steps, and test scenarios; do not call submit_plan for a question or partial plan."
        case .grill:
            "Stress-test the request with the activated $grilling skill: map the design tree of decisions, ask exactly one highest-leverage frontier question at a time with your recommended answer, and discover facts from the workspace yourself instead of asking for them. Deliver each question by calling ask_question and wait for its result before continuing. Do not modify anything, and do not implement until the user explicitly confirms the shared understanding."
        }
    }
}

enum AutomationWorkflowStepType: String, CaseIterable, Codable, Identifiable {
    case agent
    case condition
    case approval
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AutomationWorkflowOutputType: String, CaseIterable, Codable, Identifiable {
    case string
    case number
    case boolean
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AutomationWorkflowOutput: Identifiable, Codable, Hashable {
    var name: String
    var type: AutomationWorkflowOutputType
    var id: String { name }
}

/// One flat, forward-only step. Optional fields keep the wire format additive
/// and make legacy/new backend combinations decode safely.
struct AutomationWorkflowStep: Identifiable, Codable, Hashable {
    var id: String
    var type: AutomationWorkflowStepType
    var title: String
    var instructionTemplate: String? = nil
    var mode: WorkMode? = nil
    var outputs: [AutomationWorkflowOutput]? = nil
    var allowedConnectionIDs: [String]? = nil
    var nextStepID: String? = nil
    var reference: String? = nil
    var conditionOperator: String? = nil
    var compareValue: JSONValue? = nil
    var trueStepID: String? = nil
    var falseStepID: String? = nil
    var explanationTemplate: String? = nil
    var approveStepID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, title, outputs, reference
        case instructionTemplate = "instruction_template"
        case mode
        case allowedConnectionIDs = "allowed_connection_ids"
        case nextStepID = "next_step_id"
        case conditionOperator = "operator"
        case compareValue = "compare_value"
        case trueStepID = "true_step_id"
        case falseStepID = "false_step_id"
        case explanationTemplate = "explanation_template"
        case approveStepID = "approve_step_id"
    }

    static func stableID(prefix: String = "step") -> String {
        prefix + "_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func agent(instruction: String = "", mode: WorkMode = .work) -> Self {
        Self(
            id: stableID(prefix: "agent"), type: .agent, title: "Run agent",
            instructionTemplate: instruction, mode: mode, outputs: [],
            allowedConnectionIDs: nil, nextStepID: "finish"
        )
    }

    static func condition() -> Self {
        Self(
            id: stableID(prefix: "condition"), type: .condition, title: "Check condition",
            reference: "trigger.subject", conditionOperator: "equals",
            compareValue: .string(""), trueStepID: "finish", falseStepID: "finish"
        )
    }

    static func approval() -> Self {
        Self(
            id: stableID(prefix: "approval"), type: .approval, title: "Approve next step",
            explanationTemplate: "Review this workflow before it continues.",
            approveStepID: "finish"
        )
    }
}

struct AutomationWorkflow: Codable, Hashable {
    var version = 1
    var entryStepID: String
    var steps: [AutomationWorkflowStep]

    enum CodingKeys: String, CodingKey {
        case version, steps
        case entryStepID = "entry_step_id"
    }

    init(version: Int = 1, entryStepID: String, steps: [AutomationWorkflowStep]) {
        self.version = version
        self.entryStepID = entryStepID
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entryStepID = try container.decode(String.self, forKey: .entryStepID)
        steps = try container.decode([AutomationWorkflowStep].self, forKey: .steps)
        // The backend canonicalizes an explicit Finish edge as JSON null.
        // Preserve that intent through a later edit instead of omitting the
        // edge and letting it silently become the next vertical step.
        for index in steps.indices {
            switch steps[index].type {
            case .agent:
                if steps[index].nextStepID == nil { steps[index].nextStepID = "finish" }
            case .condition:
                if steps[index].trueStepID == nil { steps[index].trueStepID = "finish" }
                if steps[index].falseStepID == nil { steps[index].falseStepID = "finish" }
            case .approval:
                if steps[index].approveStepID == nil { steps[index].approveStepID = "finish" }
            }
        }
    }

    static func singleAgent(instruction: String = "", mode: WorkMode = .work) -> Self {
        let step = AutomationWorkflowStep.agent(instruction: instruction, mode: mode)
        return Self(entryStepID: step.id, steps: [step])
    }

    var firstAgent: AutomationWorkflowStep? { steps.first { $0.type == .agent } }

    mutating func repairForwardEdges() -> [String] {
        entryStepID = steps.first?.id ?? ""
        let indexes = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($0.element.id, $0.offset) })
        var repaired: [String] = []
        for index in steps.indices {
            let natural = index + 1 < steps.count ? steps[index + 1].id : "finish"
            func valid(_ target: String?, default defaultTarget: String) -> String? {
                guard let target else { return defaultTarget }
                if target == "finish" { return target }
                guard let targetIndex = indexes[target], targetIndex > index else {
                    repaired.append(steps[index].id)
                    return "finish"
                }
                return target
            }
            switch steps[index].type {
            case .agent:
                steps[index].nextStepID = valid(steps[index].nextStepID, default: natural)
            case .condition:
                steps[index].trueStepID = valid(steps[index].trueStepID, default: natural)
                steps[index].falseStepID = valid(steps[index].falseStepID, default: "finish")
            case .approval:
                steps[index].approveStepID = valid(steps[index].approveStepID, default: natural)
            }
        }
        return repaired
    }
}

enum ChatExecutionEnvironment: String, CaseIterable, Codable, Identifiable {
    case local
    case worktree

    var id: String { rawValue }
    var title: String { self == .worktree ? "Worktree" : "Local" }
}

enum ScheduleRunner: String, CaseIterable, Codable, Identifiable {
    case solo
    case soloSwarm = "solo_swarm"
    case team

    var id: String { rawValue }
    /// `solo_swarm` remains decodable for existing schedules; new schedules
    /// use Solo because adaptive delegation is now part of that runner.
    static var selectableCases: [ScheduleRunner] { [.solo, .team] }

    var title: String {
        switch self {
        case .solo: "Solo"
        case .soloSwarm: "Solo"
        case .team: "Team"
        }
    }
}

enum ScheduleRuleKind: String, CaseIterable, Codable, Identifiable {
    case once
    case daily
    case weekdays
    case weekly
    case interval

    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: "Once"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .interval: "Custom interval"
        }
    }
}

enum ScheduleIntervalUnit: String, CaseIterable, Codable, Identifiable {
    case minutes
    case hours
    case days
    case weeks

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AgentConfigurationKind: String, CaseIterable, Identifiable {
    case schedule
    case event
    case price

    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: "Time Trigger"
        case .event: "Incoming Event"
        case .price: "Price Alert"
        }
    }

    var symbol: String {
        switch self {
        case .schedule: "calendar.badge.clock"
        case .event: "bolt.badge.clock"
        case .price: "chart.line.uptrend.xyaxis"
        }
    }
}

enum ConfigureAgentTab: String, CaseIterable, Identifiable {
    case configurations
    case agents
    case sources
    case runHistory = "run_history"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .configurations: "Configurations"
        case .agents: "Agents"
        case .sources: "Sources"
        case .runHistory: "Run History"
        }
    }
}

struct ScheduleRule: Codable, Hashable {
    var kind: ScheduleRuleKind
    var at: Double? = nil
    var hour: Int? = nil
    var minute: Int? = nil
    var weekday: Int? = nil
    var every: Int? = nil
    var unit: ScheduleIntervalUnit? = nil
    var anchor: Double? = nil
}

struct ScheduledTask: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var prompt: String
    var workspaceRoot: String
    var mode: WorkMode
    var executionEnvironment: ChatExecutionEnvironment
    var runner: ScheduleRunner
    var teamID: String?
    var teamName: String?
    var provider: String
    var providerAccountID: String?
    var model: String
    var timezone: String
    var rule: ScheduleRule
    var enabled: Bool
    var nextRunAt: Double?
    var createdAt: Double
    var updatedAt: Double
    var lastRunAt: Double?
    var lastRunID: String?
    var lastError: String?
    var workflow: AutomationWorkflow? = nil
    var workflowPersisted: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, mode, runner, provider, model, timezone, rule, enabled
        case workspaceRoot = "workspace_root"
        case executionEnvironment = "execution_environment"
        case teamID = "team_id"
        case teamName = "team_name"
        case providerAccountID = "provider_account_id"
        case nextRunAt = "next_run_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRunAt = "last_run_at"
        case lastRunID = "last_run_id"
        case lastError = "last_error"
        case workflow
        case workflowPersisted = "workflow_persisted"
    }

    var nextRunDate: Date? { nextRunAt.map(Date.init(timeIntervalSince1970:)) }
    var lastRunDate: Date? { lastRunAt.map(Date.init(timeIntervalSince1970:)) }
}

struct ScheduleOccurrence: Identifiable, Codable, Hashable {
    let id: String
    let scheduleID: String
    let scheduleName: String
    let scheduledFor: Double
    let trigger: String
    let state: String
    let sessionID: String?
    let runID: String?
    let error: String?
    let createdAt: Double
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, trigger, state, error
        case scheduleID = "schedule_id"
        case scheduleName = "schedule_name"
        case scheduledFor = "scheduled_for"
        case sessionID = "session_id"
        case runID = "run_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ScheduleEditorDraft: Identifiable, Hashable {
    var id: String?
    var name = ""
    var prompt = ""
    var workspaceRoot = ""
    var mode: WorkMode = .work
    var executionEnvironment: ChatExecutionEnvironment = .local
    var runner: ScheduleRunner = .solo
    var teamID: String?
    var teamName = ""
    var provider = "ollama"
    var providerAccountID: String?
    var model = ""
    var timezone = TimeZone.current.identifier
    var ruleKind: ScheduleRuleKind = .once
    var oneTimeDate = Date().addingTimeInterval(3_600)
    var clockTime = Date()
    var weekday = Calendar.current.component(.weekday, from: Date()).mondayBasedWeekday
    var intervalEvery = 1
    var intervalUnit: ScheduleIntervalUnit = .hours
    var workflow = AutomationWorkflow.singleAgent()

    init() {}

    init(task: ScheduledTask) {
        id = task.id
        name = task.name
        prompt = task.prompt
        workspaceRoot = task.workspaceRoot
        mode = task.mode
        workflow = task.workflow ?? .singleAgent(instruction: task.prompt, mode: task.mode)
        executionEnvironment = task.executionEnvironment
        runner = task.runner == .soloSwarm ? .solo : task.runner
        teamID = task.teamID
        teamName = task.teamName ?? ""
        provider = task.provider
        providerAccountID = task.providerAccountID
        model = task.model
        timezone = task.timezone
        ruleKind = task.rule.kind
        oneTimeDate = Date(timeIntervalSince1970: task.rule.at ?? Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let calendar = Calendar(identifier: .gregorian)
        clockTime = calendar.date(
            bySettingHour: task.rule.hour ?? 9,
            minute: task.rule.minute ?? 0,
            second: 0,
            of: Date()
        ) ?? Date()
        weekday = task.rule.weekday ?? 0
        intervalEvery = task.rule.every ?? 1
        intervalUnit = task.rule.unit ?? .hours
        if task.rule.kind == .interval, let anchor = task.rule.anchor {
            oneTimeDate = Date(timeIntervalSince1970: anchor)
        }
    }

    var stableID: String { id ?? "new" }

    func rule(now: Date = Date()) -> ScheduleRule {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: clockTime)
        let minute = calendar.component(.minute, from: clockTime)
        switch ruleKind {
        case .once:
            return ScheduleRule(kind: .once, at: oneTimeDate.timeIntervalSince1970)
        case .daily, .weekdays:
            return ScheduleRule(kind: ruleKind, hour: hour, minute: minute)
        case .weekly:
            return ScheduleRule(kind: .weekly, hour: hour, minute: minute, weekday: weekday)
        case .interval:
            return ScheduleRule(
                kind: .interval, every: intervalEvery, unit: intervalUnit,
                anchor: max(oneTimeDate.timeIntervalSince1970, now.timeIntervalSince1970)
            )
        }
    }
}

private extension Int {
    var mondayBasedWeekday: Int { (self + 5) % 7 }
}

/// The answer to the "implement this plan?" prompt that follows a completed
/// Plan-mode turn.
