import Foundation

/// Shared with the runtime: this is a bundled content catalog, not 27 saved agents.
struct AgentRoleCatalog: Decodable {
    let roles: [AgentRoleTemplate]
    static let bundled = try? load()

    static func load(backendRoot: String = "", resources: URL? = Bundle.main.resourceURL) throws -> Self {
        let relative = "ollama_code/builtin_skills/agent-dispatcher/catalog.json"
        var candidates: [URL] = []
        if let resources {
            candidates.append(resources.appendingPathComponent("AgentRuntime/source/" + relative))
            candidates.append(resources.appendingPathComponent("catalog.json"))
        }
        if !backendRoot.isEmpty { candidates.append(URL(fileURLWithPath: backendRoot).appendingPathComponent(relative)) }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CatalogError.unavailable
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.roles.count == 27, Set(catalog.roles.map(\.id)).count == 27,
              catalog.roles.allSatisfy({ !$0.instructions.isEmpty && $0.instructions.count <= 16_000 }) else {
            throw CatalogError.invalid
        }
        return catalog
    }

    enum CatalogError: LocalizedError {
        case unavailable, invalid
        var errorDescription: String? {
            switch self {
            case .unavailable: "The role library is unavailable. You can still create a custom agent."
            case .invalid: "The role library could not be read. You can still create a custom agent."
            }
        }
    }
}

extension AgentProfile {
    var specialtyTitle: String {
        guard let id = resolvedBehavior.specialistRoleID else { return role.title }
        return AgentRoleCatalog.bundled?.roles.first { $0.id == id }?.name ?? role.title
    }
}

struct AgentRoleTemplate: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let summary: String
    let useWhen: String
    let notFor: String
    let tags: [String]
    let instructions: String
    let executionRole: AgentRole
    let defaultMode: WorkMode
    let accessCeiling: AgentAccessCeiling

    enum CodingKeys: String, CodingKey {
        case id, name, category, summary, tags, instructions
        case useWhen = "use_when", notFor = "not_for"
        case executionRole = "execution_role", defaultMode = "default_mode", accessCeiling = "access_ceiling"
    }

    func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let content = ([name, id, category, summary, useWhen] + tags).joined(separator: " ").lowercased()
        return terms.allSatisfy { content.contains($0) }
    }

    func applying(to profile: AgentProfile) -> AgentProfile {
        var result = profile
        result.name = name
        result.role = executionRole
        result.instructions = instructions
        result.capabilityTags = tags
        result.accessCeiling = accessCeiling
        result.defaultMode = defaultMode
        var behavior = result.resolvedBehavior
        behavior.specialistRoleID = id
        behavior.displayName = name
        behavior.selfDescription = summary
        behavior.customInstructions = instructions
        behavior.modeInstructions = .init()
        // The access ceiling still enforces the boundary; this avoids carrying
        // a previous template's disabled writes into a newly chosen writing role.
        behavior.capabilityPolicy.workspaceWrite = accessCeiling.canWrite
        behavior.capabilityPolicy.computerControl = false
        behavior.capabilityPolicy.simulatorControl = false
        result.behavior = behavior
        result.clamp()
        return result
    }

    var prefersVision: Bool { id == "ui-ux-designer" }
    var prefersContext: Bool {
        ["architect", "explorer", "researcher", "reviewer", "documentation-writer"].contains(id)
    }
    var prefersReasoning: Bool {
        category == "Engineering" || [.planner, .reviewer, .tester, .dispatcher, .implementer].contains(executionRole)
            || ["data-analyst", "product-manager"].contains(id)
    }
    var routingTags: [String] {
        var result = [id]
        if category == "Engineering" || executionRole == .implementer { result.append("coding") }
        if executionRole == .reviewer { result.append("review") }
        if executionRole == .tester { result.append("testing") }
        if executionRole == .researcher { result.append("research") }
        if ["content-copywriter", "documentation-writer", "growth-marketing-strategist"].contains(id) {
            result.append("writing")
        }
        if prefersContext { result.append("long_context") }
        return result
    }
}
