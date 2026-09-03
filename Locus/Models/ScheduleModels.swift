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
            "Inspect files if useful, but do not modify anything. Ask clarifying questions when needed by calling ask_user_question with your options and recommended answer. When the plan is final and decision-complete, call submit_plan exactly once with its title, summary, ordered steps, and test scenarios; do not call submit_plan for a question or partial plan."
        case .grill:
            "Stress-test the request with the activated $grilling skill: map the design tree of decisions, ask exactly one highest-leverage frontier question at a time with your recommended answer, and discover facts from the workspace yourself instead of asking for them. Deliver each question by calling ask_user_question with its title, question, options, and your recommended answer, then end your turn. Do not modify anything, and do not implement until the user explicitly confirms the shared understanding."
        }
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

    init() {}

    init(task: ScheduledTask) {
        id = task.id
        name = task.name
        prompt = task.prompt
        workspaceRoot = task.workspaceRoot
        mode = task.mode
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
