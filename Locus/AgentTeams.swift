import Foundation

enum AgentRole: String, Codable, CaseIterable, Identifiable {
    case dispatcher
    case planner
    case researcher
    case implementer
    case tester
    case reviewer
    case generalist

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var defaultInstructions: String {
        switch self {
        case .dispatcher:
            "Break the request into a small dependency graph, select only useful specialists, enforce the budget, and synthesize their evidence. Do not perform specialist work yourself."
        case .planner:
            "Inspect the supplied evidence and return a decision-complete implementation plan with risks and verification. Do not edit files."
        case .researcher:
            "Investigate the question from the supplied workspace evidence. Separate facts from inferences and cite exact paths or outputs. Do not edit files."
        case .implementer:
            "Own all workspace mutations for the run. Use specialist evidence critically, make focused changes, and verify them under the active permission mode."
        case .tester:
            "Design and run the most relevant verification available to the writer. Report failures precisely and do not edit product files."
        case .reviewer:
            "Review the baseline-relative diff and test evidence for correctness, regressions, security boundaries, and missing coverage. Do not edit files."
        case .generalist:
            "Solve the assigned bounded job, inspect evidence carefully, and return concise findings with uncertainties."
        }
    }
}

enum AgentAccessCeiling: String, Codable, CaseIterable, Identifiable {
    case readOnly = "read_only"
    case workspaceWrite = "workspace_write"
    case computerControl = "computer_control"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .readOnly: "Read only"
        case .workspaceWrite: "Workspace edits"
        case .computerControl: "Computer control"
        }
    }

    var canWrite: Bool { self != .readOnly }
}

enum AgentMetering: String, Codable, CaseIterable, Identifiable {
    case selfHosted = "self_hosted"
    case metered

    var id: String { rawValue }
    var title: String { self == .selfHosted ? "Self-hosted" : "Metered hosted" }
}

struct MCPAgentPolicy: Codable, Hashable {
    var serverIDs: [String] = []
    var tools: [String] = []
    var resources: [String] = []
    var prompts: [String] = []

    enum CodingKeys: String, CodingKey {
        case tools, resources, prompts
        case serverIDs = "server_ids"
    }

    mutating func clamp() {
        serverIDs = bounded(serverIDs)
        tools = bounded(tools)
        resources = bounded(resources)
        prompts = bounded(prompts)
    }

    private func bounded(_ values: [String]) -> [String] {
        Array(Set(values.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        }.filter { !$0.isEmpty })).sorted().prefix(256).map { $0 }
    }
}

enum DispatchApprovalMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case preview
    var id: String { rawValue }
    var title: String { self == .automatic ? "Automatic" : "Preview each plan" }
}

enum AgentRoutingMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case scorecard
    var id: String { rawValue }
    var title: String { self == .manual ? "Manual assignments" : "Balanced scorecard" }
}

struct AgentScoreWeights: Codable, Hashable {
    var quality = 0.40
    var reliability = 0.20
    var privacy = 0.15
    var latency = 0.15
    var cost = 0.10

    mutating func normalize() {
        quality = max(quality, 0)
        reliability = max(reliability, 0)
        privacy = max(privacy, 0)
        latency = max(latency, 0)
        cost = max(cost, 0)
        let total = quality + reliability + privacy + latency + cost
        guard total > 0 else { self = .init(); return }
        quality /= total
        reliability /= total
        privacy /= total
        latency /= total
        cost /= total
    }
}

enum AgentRoute: Codable, Hashable {
    case localOllama
    case providerAccount(UUID)

    private enum CodingKeys: String, CodingKey { case kind, accountID }
    private enum Kind: String, Codable { case localOllama = "ollama", providerAccount = "account" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .localOllama {
        case .localOllama:
            self = .localOllama
        case .providerAccount:
            guard let id = try container.decodeIfPresent(UUID.self, forKey: .accountID) else {
                self = .localOllama
                return
            }
            self = .providerAccount(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localOllama:
            try container.encode(Kind.localOllama, forKey: .kind)
        case .providerAccount(let id):
            try container.encode(Kind.providerAccount, forKey: .kind)
            try container.encode(id, forKey: .accountID)
        }
    }

    var accountID: UUID? {
        if case .providerAccount(let id) = self { return id }
        return nil
    }
}

struct AgentProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var route: AgentRoute = .localOllama
    var model: String
    var role: AgentRole
    var instructions: String
    var capabilityTags: [String]
    var accessCeiling: AgentAccessCeiling
    var timeoutSeconds: Int
    var tokenLimit: Int
    var metering: AgentMetering
    var inputCostPerMillion: Double?
    var outputCostPerMillion: Double?
    var mcpPolicy: MCPAgentPolicy? = nil

    init(
        id: UUID = UUID(),
        name: String,
        route: AgentRoute = .localOllama,
        model: String = "",
        role: AgentRole = .generalist,
        instructions: String? = nil,
        capabilityTags: [String] = [],
        accessCeiling: AgentAccessCeiling = .readOnly,
        timeoutSeconds: Int = 600,
        tokenLimit: Int = 64_000,
        metering: AgentMetering = .selfHosted,
        inputCostPerMillion: Double? = nil,
        outputCostPerMillion: Double? = nil,
        mcpPolicy: MCPAgentPolicy? = nil
    ) {
        self.id = id
        self.name = name
        self.route = route
        self.model = model
        self.role = role
        self.instructions = instructions ?? role.defaultInstructions
        self.capabilityTags = capabilityTags
        self.accessCeiling = accessCeiling
        self.timeoutSeconds = timeoutSeconds
        self.tokenLimit = tokenLimit
        self.metering = metering
        self.inputCostPerMillion = inputCostPerMillion
        self.outputCostPerMillion = outputCostPerMillion
        self.mcpPolicy = mcpPolicy
        clamp()
    }

    mutating func clamp() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        model = String(model.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        instructions = String(instructions.prefix(16_000))
        capabilityTags = Array(Set(capabilityTags.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(40))
        }.filter { !$0.isEmpty })).sorted().prefix(24).map { $0 }
        timeoutSeconds = min(max(timeoutSeconds, 30), 3_600)
        tokenLimit = min(max(tokenLimit, 1_024), 1_000_000)
        if metering == .selfHosted {
            inputCostPerMillion = nil
            outputCostPerMillion = nil
        }
        mcpPolicy?.clamp()
    }

    var isConfigured: Bool { !name.isEmpty && !model.isEmpty }
}

struct OrchestrationBudget: Codable, Hashable {
    var maxJobs = 4
    var maxRounds = 3
    var maxModelCalls = 12
    var maxConcurrentCalls = 3
    var maxMeteredTokens = 500_000

    private enum CodingKeys: String, CodingKey {
        case maxJobs = "max_jobs"
        case maxRounds = "max_rounds"
        case maxModelCalls = "max_model_calls"
        case maxConcurrentCalls = "max_concurrent_calls"
        case maxMeteredTokens = "max_metered_tokens"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case maxJobs, maxRounds, maxModelCalls, maxConcurrentCalls, maxMeteredTokens
    }

    init(
        maxJobs: Int = 4,
        maxRounds: Int = 3,
        maxModelCalls: Int = 12,
        maxConcurrentCalls: Int = 3,
        maxMeteredTokens: Int = 500_000
    ) {
        self.maxJobs = maxJobs
        self.maxRounds = maxRounds
        self.maxModelCalls = maxModelCalls
        self.maxConcurrentCalls = maxConcurrentCalls
        self.maxMeteredTokens = maxMeteredTokens
    }

    init(from decoder: Decoder) throws {
        let current = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        maxJobs = try current.decodeIfPresent(Int.self, forKey: .maxJobs)
            ?? legacy.decodeIfPresent(Int.self, forKey: .maxJobs) ?? 4
        maxRounds = try current.decodeIfPresent(Int.self, forKey: .maxRounds)
            ?? legacy.decodeIfPresent(Int.self, forKey: .maxRounds) ?? 3
        maxModelCalls = try current.decodeIfPresent(Int.self, forKey: .maxModelCalls)
            ?? legacy.decodeIfPresent(Int.self, forKey: .maxModelCalls) ?? 12
        maxConcurrentCalls = try current.decodeIfPresent(Int.self, forKey: .maxConcurrentCalls)
            ?? legacy.decodeIfPresent(Int.self, forKey: .maxConcurrentCalls) ?? 3
        maxMeteredTokens = try current.decodeIfPresent(Int.self, forKey: .maxMeteredTokens)
            ?? legacy.decodeIfPresent(Int.self, forKey: .maxMeteredTokens) ?? 500_000
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxJobs, forKey: .maxJobs)
        try container.encode(maxRounds, forKey: .maxRounds)
        try container.encode(maxModelCalls, forKey: .maxModelCalls)
        try container.encode(maxConcurrentCalls, forKey: .maxConcurrentCalls)
        try container.encode(maxMeteredTokens, forKey: .maxMeteredTokens)
    }

    mutating func clamp() {
        maxJobs = min(max(maxJobs, 1), 16)
        maxRounds = min(max(maxRounds, 1), 8)
        maxModelCalls = min(max(maxModelCalls, 1), 48)
        maxConcurrentCalls = min(max(maxConcurrentCalls, 1), 8)
        maxMeteredTokens = min(max(maxMeteredTokens, 1_000), 2_000_000)
    }
}

struct AgentTeam: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var dispatcherID: UUID?
    var fallbackDispatcherID: UUID?
    var memberIDs: [UUID]
    var defaultWriterID: UUID?
    var budget = OrchestrationBudget()
    var useManagedWorktree = true
    var dispatchApprovalMode: DispatchApprovalMode? = nil
    var routingMode: AgentRoutingMode? = nil
    var routingWeights: AgentScoreWeights? = nil
    var evaluationTags: [String]? = nil
    var maximumEstimatedCost: Double? = nil

    mutating func clamp() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        // Preserve the editor's order (dispatcher first in the common case)
        // while removing duplicates. Converting through Set made the team
        // model picker reshuffle on every save.
        var seenMemberIDs: Set<UUID> = []
        memberIDs = memberIDs.filter { seenMemberIDs.insert($0).inserted }
        memberIDs = Array(memberIDs.prefix(32))
        budget.clamp()
        if routingMode == .scorecard, routingWeights == nil { routingWeights = .init() }
        routingWeights?.normalize()
        evaluationTags = Array(Set((evaluationTags ?? []).map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(40))
        }.filter { !$0.isEmpty })).sorted().prefix(24).map { $0 }
        maximumEstimatedCost = min(max(maximumEstimatedCost ?? 0, 0), 100_000)
    }

    var resolvedDispatchApprovalMode: DispatchApprovalMode { dispatchApprovalMode ?? .automatic }
    var resolvedRoutingMode: AgentRoutingMode { routingMode ?? .manual }
    var resolvedRoutingWeights: AgentScoreWeights { routingWeights ?? .init() }
}

enum AgentTeamValidation {
    static func errors(team: AgentTeam, profiles: [AgentProfile]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var errors: [String] = []
        if team.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give the team a name.")
        }
        guard let dispatcherID = team.dispatcherID,
              let dispatcher = byID[dispatcherID],
              team.memberIDs.contains(dispatcherID)
        else {
            errors.append("Choose a dispatcher who belongs to the team.")
            return errors
        }
        if dispatcher.role != .dispatcher {
            errors.append("The dispatcher profile must use the Dispatcher role.")
        }
        if dispatcher.accessCeiling != .readOnly {
            errors.append("Dispatchers must be read-only.")
        }
        guard let writerID = team.defaultWriterID,
              let writer = byID[writerID],
              team.memberIDs.contains(writerID)
        else {
            errors.append("Choose one default writer who belongs to the team.")
            return errors
        }
        if !writer.accessCeiling.canWrite {
            errors.append("The default writer needs workspace-write access.")
        }
        let writers = team.memberIDs.compactMap { byID[$0] }.filter { $0.accessCeiling.canWrite }
        if writers.count != 1 {
            errors.append("A team must contain exactly one mutation-capable agent.")
        }
        if let fallback = team.fallbackDispatcherID,
           (!team.memberIDs.contains(fallback) || byID[fallback]?.role != .dispatcher) {
            errors.append("The fallback dispatcher must be a Dispatcher team member.")
        }
        for id in team.memberIDs where byID[id] == nil {
            errors.append("The team contains an unavailable agent.")
        }
        for profile in team.memberIDs.compactMap({ byID[$0] }) where !profile.isConfigured {
            errors.append("Configure a model for \(profile.name.isEmpty ? "an agent" : profile.name).")
        }
        return Array(Set(errors)).sorted()
    }

    /// Validate saved agent models against catalogs the provider has actually
    /// reported. An account's display name is intentionally not evidence that
    /// its endpoint serves a similarly named model.
    static func routeErrors(
        team: AgentTeam,
        profiles: [AgentProfile],
        accounts: [ProviderAccount],
        accountModels: [UUID: [String]]
    ) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var errors: [String] = []

        for profile in team.memberIDs.compactMap({ byID[$0] }) {
            guard case .providerAccount(let accountID) = profile.route,
                  let account = accountsByID[accountID],
                  account.kind.listsModels,
                  let reported = accountModels[accountID],
                  !reported.isEmpty,
                  !reported.contains(where: {
                      $0.caseInsensitiveCompare(profile.model) == .orderedSame
                  })
            else { continue }

            errors.append(
                "\(profile.name) is set to \(profile.model), but \(account.displayName) does not report that model. Choose one from the model picker."
            )
        }
        return Array(Set(errors)).sorted()
    }
}

enum AgentTeamStore {
    static let profilesKey = "Locus.agentProfiles"
    static let teamsKey = "Locus.agentTeams"
    static let consentKey = "Locus.teamRoutingConsentAccounts"
    static let selectionKey = "Locus.selectedAgentTeam"
    static let globalConcurrencyKey = "Locus.globalAgentConcurrency"

    static func loadProfiles(from defaults: UserDefaults = .standard) -> [AgentProfile] {
        decodeElements(AgentProfile.self, data: defaults.data(forKey: profilesKey))
    }

    static func loadTeams(from defaults: UserDefaults = .standard) -> [AgentTeam] {
        decodeElements(AgentTeam.self, data: defaults.data(forKey: teamsKey))
    }

    static func save(profiles: [AgentProfile], teams: [AgentTeam], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: profilesKey) }
        if let data = try? JSONEncoder().encode(teams) { defaults.set(data, forKey: teamsKey) }
    }

    static func loadConsent(from defaults: UserDefaults = .standard) -> Set<UUID> {
        Set((defaults.stringArray(forKey: consentKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func decodeElements<T: Decodable>(_ type: T.Type, data: Data?) -> [T] {
        guard let data,
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return values.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(withJSONObject: value)
            else { return nil }
            return try? JSONDecoder().decode(T.self, from: encoded)
        }
    }
}

enum TeamRunState: String, Codable, CaseIterable, Hashable {
    case queued
    case dispatching
    case running
    case waitingPermission = "waiting_permission"
    case waitingComputer = "waiting_computer"
    case waitingDispatchApproval = "waiting_dispatch_approval"
    case reviewing
    case paused
    case completed
    case failed
    case interrupted
    case cancelled
    case discarded

    var title: String {
        switch self {
        case .queued: "Queued"
        case .dispatching: "Dispatching"
        case .running: "Running"
        case .waitingPermission: "Waiting for permission"
        case .waitingComputer: "Waiting for computer control"
        case .waitingDispatchApproval: "Waiting for dispatch approval"
        case .reviewing: "Reviewing"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .cancelled: "Cancelled"
        case .discarded: "Discarded"
        }
    }
}

struct AgentActivity: Identifiable, Codable, Hashable {
    let id: String
    var agentName: String
    var role: String
    var provider: String
    var model: String
    var goal: String
    var state: TeamRunState
    var output: String
    var reasoningText: String?
    var tool: String?
    var evidence: [String]
    var startedAt: Date?
    var elapsedMilliseconds: Int
    var promptTokens: Int
    var completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case id, role, provider, model, goal, state, output, tool, evidence
        case agentName = "agent_name"
        case reasoningText = "reasoning_text"
        case startedAt = "started_at"
        case elapsedMilliseconds = "elapsed_milliseconds"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

struct TaskRecord: Identifiable, Codable, Hashable {
    let id: String
    let workspaceRoot: String
    let executionPath: String
    let baselineTree: String
    var appliedTree: String?
    var state: TeamRunState?

    enum CodingKeys: String, CodingKey {
        case id, state
        case workspaceRoot = "workspace_root"
        case executionPath = "execution_path"
        case baselineTree = "baseline_tree"
        case appliedTree = "applied_tree"
    }
}

struct SessionTeamReference: Codable, Hashable {
    let id: String
    let name: String
}

/// Persistable lifecycle metadata for a team-backed chat. Conversation text
/// and agent output stay in the append-only session file; this deliberately
/// contains no prompts, credentials, or provider reasoning metadata.
struct TaskConversationState: Codable, Hashable {
    let sessionID: String
    var taskID: String?
    var teamID: String?
    var workerID: String?
    var runID: String?
    var state: TeamRunState
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case state
        case sessionID = "session_id"
        case taskID = "task_id"
        case teamID = "team_id"
        case workerID = "worker_id"
        case runID = "run_id"
        case updatedAt = "updated_at"
    }
}

indirect enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted()
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var integer: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }
}

struct OrchestrationEvent: Identifiable, Codable, Hashable {
    let values: [String: JSONValue]

    init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    var id: String { text("event_id") ?? "event-\(sequence)" }
    var sequence: Int { values["seq"]?.integer ?? 0 }
    var type: String { text("type") ?? "event" }
    var jobID: String? { text("job_id") }
    var attemptID: String? { text("attempt_id") }
    var occurredAt: Date? {
        guard case .number(let value) = values["occurred_at"] else { return nil }
        return Date(timeIntervalSince1970: value)
    }
    var title: String {
        text("summary") ?? text("message") ?? text("state")
            ?? type.replacingOccurrences(of: "_", with: " ").capitalized
    }
    var detail: String? {
        if type == "routing_decision" {
            var lines = [text("reason") ?? "Routing decision"]
            if text("limited_data") == "true" { lines.append("Limited data") }
            if case .array(let candidates) = values["candidates"] {
                for candidate in candidates.prefix(12) {
                    guard case .object(let object) = candidate else { continue }
                    let name = object["agent_name"]?.string
                        ?? object["agent_id"]?.string ?? "Agent"
                    let score = object["score"]?.string ?? "—"
                    var components: [String] = []
                    if case .object(let values) = object["components"] {
                        for key in ["quality", "reliability", "privacy", "latency", "cost"] {
                            if let value = values[key]?.string {
                                components.append("\(key) \(value)")
                            }
                        }
                    }
                    lines.append("\(name): \(score) · \(components.joined(separator: ", "))")
                }
            }
            return lines.joined(separator: "\n")
        }
        return text("error") ?? text("detail") ?? text("reason")
    }
    func text(_ key: String) -> String? { values[key]?.string }
}

struct AgentJobAttempt: Identifiable, Codable, Hashable {
    let runID: String
    let jobID: String
    let attempt: Int
    let attemptID: String
    let agentID: String?
    let agentName: String?
    let role: String?
    let provider: String?
    let model: String?
    let state: String
    let goal: String
    let result: [String: JSONValue]?
    let startedAt: Double?
    let completedAt: Double?

    var id: String { attemptID }

    enum CodingKeys: String, CodingKey {
        case attempt, role, provider, model, state, goal, result
        case runID = "run_id"
        case jobID = "job_id"
        case attemptID = "attempt_id"
        case agentID = "agent_id"
        case agentName = "agent_name"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }


    var output: String? { result?["output"]?.string }
    var reasoningText: String? { result?["reasoning_text"]?.string }
    var promptTokens: Int { result?["prompt_tokens"]?.integer ?? 0 }
    var completionTokens: Int { result?["completion_tokens"]?.integer ?? 0 }
    var elapsedMilliseconds: Int { result?["elapsed_ms"]?.integer ?? 0 }
    var evidence: [String] {
        guard case .array(let values) = result?["evidence"] else { return [] }
        return values.compactMap(\.string)
    }
}

struct RunCheckpoint: Codable, Hashable {
    let id: String
    let runID: String
    let sequence: Int
    let kind: String
    let state: [String: JSONValue]
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, state
        case runID = "run_id"
        case sequence = "seq"
        case createdAt = "created_at"
    }
}

struct RunRecoveryAssessment: Codable, Hashable {
    let runID: String
    let canResume: Bool
    let repairChecklist: [String]
    let reusableJobIDs: [String]
    let writerContinuation: Bool

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case canResume = "can_resume"
        case repairChecklist = "repair_checklist"
        case reusableJobIDs = "reusable_job_ids"
        case writerContinuation = "writer_continuation"
    }
}

struct OrchestrationRun: Identifiable, Codable, Hashable {
    let id: String
    let sessionID: String?
    let teamID: String?
    let teamName: String?
    let workerID: String?
    let workspaceRoot: String?
    let executionPath: String?
    let taskID: String?
    let state: String
    let request: String
    let createdAt: Double
    let updatedAt: Double
    let completedAt: Double?
    let lastSequence: Int
    let pinned: Bool
    let legacy: Bool
    let recoverable: Bool
    let recoveryReason: String?
    let checkpoint: RunCheckpoint?
    let attempts: [AgentJobAttempt]?

    enum CodingKeys: String, CodingKey {
        case id, state, request, pinned, legacy, recoverable, checkpoint, attempts
        case sessionID = "session_id"
        case teamID = "team_id"
        case teamName = "team_name"
        case workerID = "worker_id"
        case workspaceRoot = "workspace_root"
        case executionPath = "execution_path"
        case taskID = "task_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case lastSequence = "last_seq"
        case recoveryReason = "recovery_reason"
    }
}

struct DispatchJob: Identifiable, Codable, Hashable {
    var id: String
    var agentID: String
    var goal: String
    var dependencies: [String]
    var kind: String
    var requiredRole: String?
    var capabilityTags: [String]?
    var preferredAgentID: String?

    enum CodingKeys: String, CodingKey {
        case id, goal, dependencies, kind
        case agentID = "agent_id"
        case requiredRole = "required_role"
        case capabilityTags = "capability_tags"
        case preferredAgentID = "preferred_agent_id"
    }
}

struct DispatchPlan: Codable, Hashable {
    var summary: String
    var jobs: [DispatchJob]
    var budget: OrchestrationBudget? = nil
    var maximumEstimatedCost: Double? = nil

    enum CodingKeys: String, CodingKey {
        case summary, jobs, budget
        case maximumEstimatedCost = "maximum_estimated_cost"
    }
}

struct EvaluationAssertion: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var kind = "path_exists"
    var path = ""
    var value: JSONValue? = nil
    var command = ""
    var required = true
    var timeoutSeconds = 120

    enum CodingKeys: String, CodingKey {
        case id, kind, path, value, command, required
        case timeoutSeconds = "timeout_seconds"
    }
}

struct EvaluationCase: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var name = "New case"
    var prompt = ""
    var tags: [String] = []
    var mode = "write"
    var target = "team"
    var teamID = ""
    var timeoutSeconds = 1_800
    var budget: OrchestrationBudget? = nil
    var assertions: [EvaluationAssertion] = []
    var rubric = ""
    var judgeProfileID = ""
    var passingScore = 80
    var baselineFixture: EvaluationBaselineFixture? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, tags, mode, target, budget, assertions, rubric
        case teamID = "team_id"
        case timeoutSeconds = "timeout_seconds"
        case judgeProfileID = "judge_profile_id"
        case passingScore = "passing_score"
        case baselineFixture = "baseline_fixture"
    }
}

struct EvaluationBaselineFixture: Codable, Hashable {
    let taskID: String
    let workspaceRoot: String
    let baselineTree: String
    let baselineCommit: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case workspaceRoot = "workspace_root"
        case baselineTree = "baseline_tree"
        case baselineCommit = "baseline_commit"
    }
}

struct EvaluationSuite: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var name = "New suite"
    var workspaceRoot: String
    var description = ""
    var tags: [String] = []
    var readOnlyMCP = false
    var pinned = false
    var cases: [EvaluationCase] = []

    enum CodingKeys: String, CodingKey {
        case id, name, description, tags, pinned, cases
        case workspaceRoot = "workspace_root"
        case readOnlyMCP = "read_only_mcp"
    }
}

struct EvaluationSummary: Codable, Hashable {
    let cases: Int
    let passed: Int
    let passRate: Double
    let averageRubricScore: Double?
    let medianLatencyMilliseconds: Int
    let p95LatencyMilliseconds: Int
    let modelCalls: Int
    let promptTokens: Int
    let completionTokens: Int
    let estimatedCost: Double

    enum CodingKeys: String, CodingKey {
        case cases, passed
        case passRate = "pass_rate"
        case averageRubricScore = "average_rubric_score"
        case medianLatencyMilliseconds = "median_latency_ms"
        case p95LatencyMilliseconds = "p95_latency_ms"
        case modelCalls = "model_calls"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case estimatedCost = "estimated_cost"
    }
}

struct EvaluationComparison: Identifiable, Codable, Hashable {
    var id: String { configuration }
    let configuration: String
    let cases: Int
    let passed: Int
    let passRate: Double
    let averageRubricScore: Double?
    let medianLatencyMilliseconds: Int
    let p95LatencyMilliseconds: Int
    let modelCalls: Int
    let promptTokens: Int
    let completionTokens: Int
    let estimatedCost: Double
    let retries: Int
    let failureCategories: [String: Int]

    enum CodingKeys: String, CodingKey {
        case configuration, cases, passed, retries
        case passRate = "pass_rate"
        case averageRubricScore = "average_rubric_score"
        case medianLatencyMilliseconds = "median_latency_ms"
        case p95LatencyMilliseconds = "p95_latency_ms"
        case modelCalls = "model_calls"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case estimatedCost = "estimated_cost"
        case failureCategories = "failure_categories"
    }
}

struct EvaluationResultRecord: Identifiable, Codable, Hashable {
    let id: String
    let caseID: String
    let state: String
    let target: String?
    let durationMilliseconds: Int?
    let deterministicPassed: Bool?
    let rubricScore: Double?
    let rubricSubjective: Bool?
    let error: String?
    let failureCategory: String?

    enum CodingKeys: String, CodingKey {
        case id, state, target, error
        case caseID = "case_id"
        case durationMilliseconds = "duration_ms"
        case deterministicPassed = "deterministic_passed"
        case rubricScore = "rubric_score"
        case rubricSubjective = "rubric_subjective"
        case failureCategory = "failure_category"
    }
}

struct EvaluationReport: Identifiable, Codable, Hashable {
    var id: String { suite.id }
    let suite: EvaluationSuite
    let results: [EvaluationResultRecord]
    let summary: EvaluationSummary
    let comparison: [EvaluationComparison]
}

struct WorkspaceKnowledgeStatus: Codable, Hashable {
    let workspace: String
    var enabled: Bool
    var embeddingModel: String
    var ollamaHost: String
    var exclusions: [String]?
    let vectorGeneration: Int
    let lastIndexed: Double?
    let lastError: String?
    let documentCount: Int
    let chunkCount: Int
    let memoryCount: Int
    let vectorAvailable: Bool
    let vectorBackend: String

    enum CodingKeys: String, CodingKey {
        case workspace, enabled, exclusions
        case embeddingModel = "embedding_model"
        case ollamaHost = "ollama_host"
        case vectorGeneration = "vector_generation"
        case lastIndexed = "last_indexed"
        case lastError = "last_error"
        case documentCount = "document_count"
        case chunkCount = "chunk_count"
        case memoryCount = "memory_count"
        case vectorAvailable = "vector_available"
        case vectorBackend = "vector_backend"
    }
}

struct WorkspaceMemory: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var content: String
    var tags: [String]
    var sourceSessionID: String?
    var sourceRunID: String?
    var pinned: Bool
    var stale: Bool
    let createdAt: Double
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title, content, tags, pinned, stale
        case sourceSessionID = "source_session_id"
        case sourceRunID = "source_run_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct MCPTaskRecord: Identifiable, Codable, Hashable {
    let id: String
    let serverID: String
    let runID: String?
    let jobID: String?
    let toolCallID: String?
    let toolName: String
    let state: String
    let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, state
        case serverID = "server_id"
        case runID = "run_id"
        case jobID = "job_id"
        case toolCallID = "tool_call_id"
        case toolName = "tool_name"
        case statusMessage = "status_message"
    }
}

struct MCPInputRequest: Identifiable, Codable, Hashable {
    let id: String
    let serverID: String
    let mode: String
    let message: String
    let url: String?
    let elicitationID: String?
    let schema: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case mode, message, url, schema
        case id = "request_id"
        case serverID = "server_id"
        case elicitationID = "elicitation_id"
    }
}

enum TeamMentionResolver {
    static func selection(
        in text: String,
        profiles: [AgentProfile],
        teams: [AgentTeam]
    ) -> (agent: AgentProfile?, team: AgentTeam?) {
        let words = text.split(whereSeparator: { $0.isWhitespace || ",.;:!?()[]{}".contains($0) })
        let mentions = Set(words.compactMap { word -> String? in
            guard word.first == "@" else { return nil }
            return String(word.dropFirst()).lowercased()
        })
        let normalized: (String) -> String = {
            $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
        let agent = profiles.first { mentions.contains(normalized($0.name)) }
        let team = teams.first { mentions.contains(normalized($0.name)) }
        return (agent, team)
    }
}

enum TeamMentionTarget: Identifiable, Hashable {
    case agent(AgentProfile)
    case team(AgentTeam)

    var id: String {
        switch self {
        case .agent(let profile): "agent:\(profile.id)"
        case .team(let team): "team:\(team.id)"
        }
    }

    var name: String {
        switch self {
        case .agent(let profile): profile.name
        case .team(let team): team.name
        }
    }

    var subtitle: String {
        switch self {
        case .agent(let profile): "Force \(profile.role.title) · \(profile.model)"
        case .team(let team): "Use team · \(team.memberIDs.count) members"
        }
    }

    var symbol: String {
        switch self {
        case .agent: "person.fill"
        case .team: "person.3.fill"
        }
    }
}
