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
        outputCostPerMillion: Double? = nil
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
    }

    var isConfigured: Bool { !name.isEmpty && !model.isEmpty }
}

struct OrchestrationBudget: Codable, Hashable {
    var maxJobs = 4
    var maxRounds = 3
    var maxModelCalls = 12
    var maxConcurrentCalls = 3
    var maxMeteredTokens = 500_000

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

    mutating func clamp() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        memberIDs = Array(Set(memberIDs)).prefix(32).map { $0 }
        budget.clamp()
    }
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
    case reviewing
    case completed
    case failed
    case interrupted

    var title: String {
        switch self {
        case .queued: "Queued"
        case .dispatching: "Dispatching"
        case .running: "Running"
        case .waitingPermission: "Waiting for permission"
        case .waitingComputer: "Waiting for computer control"
        case .reviewing: "Reviewing"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
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
