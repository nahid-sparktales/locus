import Foundation

struct AgentRoleModelCandidate: Identifiable, Hashable {
    let route: AgentRoute
    let model: String
    var provider = "ollama"
    var contextWindow = 0
    var supportsVision = false
    var supportsReasoning = false
    var preferred = false
    var providerDefault = false
    var subscription = false
    var sampleIDs: [String] = []

    var id: String { "model-route:\(route.accountID?.uuidString.lowercased() ?? "ollama"):\(model.lowercased())" }
    func isCurrent(_ draft: AgentProfile) -> Bool {
        route == draft.route && model.caseInsensitiveCompare(draft.model) == .orderedSame
    }
    func payload(current draft: AgentProfile) -> [String: Any] {
        ["id": id, "name": model, "model": model, "provider": provider,
         "local": route.accountID == nil, "current": isCurrent(draft),
         "metering": route.accountID == nil ? "self_hosted" : subscription ? "subscription" : "metered",
         "sample_ids": [id] + sampleIDs]
    }
}

struct AgentRoleModelRecommendation {
    let candidate: AgentRoleModelCandidate?
    let reason: String

    static func choose(
        role: AgentRoleTemplate, candidates: [AgentRoleModelCandidate],
        current: AgentProfile, scorecards: [ModelRoutingScorecard] = []
    ) -> Self {
        let evidence = Dictionary(scorecards.filter {
            !$0.limitedData && $0.evaluationCount >= 5 && $0.score.isFinite
        }.map { ($0.routeID, $0.score) }, uniquingKeysWith: max)
        let sorted = candidates.sorted { lhs, rhs in
            let l = evidence[lhs.id], r = evidence[rhs.id]
            if (l != nil) != (r != nil) { return l != nil }
            if let l, let r, l != r { return l > r }
            if role.prefersVision, lhs.supportsVision != rhs.supportsVision { return lhs.supportsVision }
            if role.prefersContext, lhs.contextWindow != rhs.contextWindow { return lhs.contextWindow > rhs.contextWindow }
            if role.prefersReasoning, lhs.supportsReasoning != rhs.supportsReasoning { return lhs.supportsReasoning }
            if lhs.isCurrent(current) != rhs.isCurrent(current) { return lhs.isCurrent(current) }
            if lhs.preferred != rhs.preferred { return lhs.preferred }
            if lhs.providerDefault != rhs.providerDefault { return lhs.providerDefault }
            return lhs.id < rhs.id
        }
        guard let selected = sorted.first else {
            return Self(candidate: nil, reason: "Choose or connect a model. No available model could be confirmed.")
        }
        let reason: String
        if evidence[selected.id] != nil { reason = "Recommended from evaluated performance on related tasks." }
        else if role.prefersVision, selected.supportsVision { reason = "Supports image input for design work." }
        else if role.prefersContext, selected.contextWindow > 0 { reason = "Larger reported context for this role’s reading tasks." }
        else if role.prefersReasoning, selected.supportsReasoning { reason = "Supports reasoning controls for this role." }
        else if selected.isCurrent(current) || selected.preferred { reason = "Uses your preferred model; role performance is unverified." }
        else { reason = "Available from a connected provider; role performance is unverified." }
        return Self(candidate: selected, reason: reason)
    }
}

extension ProviderAccountsModel {
    /// Enumerates all confirmed models, independently of per-message auto routing.
    func agentRoleModelCandidates() -> [AgentRoleModelCandidate] {
        var candidates: [AgentRoleModelCandidate] = []
        if hasAuthoritativeLocalModelCatalog {
            candidates = localModels.map {
                AgentRoleModelCandidate(route: .localOllama, model: $0.name,
                    contextWindow: max($0.contextLength, $0.trainedContextLength),
                    supportsVision: $0.visionCapable == true)
            }
        }
        for account in providerAccounts {
            let confirmedModels: [String]
            if hasAuthoritativeModelCatalog(for: account.id) {
                switch accountStatus[account.id] {
                case .connected?, .signedIn?: break
                default: continue
                }
                confirmedModels = accountModels[account.id] ?? []
            } else {
                confirmedModels = confirmedExactModels(for: account.id)
            }
            guard !confirmedModels.isEmpty else { continue }
            let options = AgentProfileModelOptions(account: account, reportedModels: confirmedModels,
                                                   hasAuthoritativeCatalog: true)
            for name in options.choices {
                let metadata = accountModelCatalogs[account.id]?.first { $0.id == name }
                candidates.append(AgentRoleModelCandidate(route: .providerAccount(account.id), model: name,
                    provider: account.kind.rawValue,
                    contextWindow: account.kind.publishedContextWindow(for: name) ?? 0,
                    supportsVision: metadata?.supportsImageInput == true,
                    supportsReasoning: !(metadata?.supportedReasoningEfforts ?? []).isEmpty
                        || !account.kind.publishedReasoningEfforts(for: name).isEmpty,
                    preferred: name.caseInsensitiveCompare(account.preferredModel) == .orderedSame,
                    providerDefault: metadata?.isDefault == true,
                    subscription: account.kind.isManagedPlan || account.kind == .kimiCode))
            }
        }
        return candidates.sorted { $0.id < $1.id }
    }
}

extension AppModel {
    func recommendAgentRoleModel(_ role: AgentRoleTemplate, draft: AgentProfile) async -> AgentRoleModelRecommendation {
        async let local: Void = providerAccountsModel.refreshLocalModels()
        async let hosted: Void = providerAccountsModel.refreshAccountCatalogs()
        _ = await (local, hosted)
        var candidates = providerAccountsModel.agentRoleModelCandidates()
        for index in candidates.indices {
            candidates[index].sampleIDs = agentProfiles.filter {
                $0.route == candidates[index].route
                    && $0.model.caseInsensitiveCompare(candidates[index].model) == .orderedSame
            }.map { $0.id.uuidString }
        }
        var scorecards: [ModelRoutingScorecard] = []
        for start in stride(from: 0, to: candidates.count, by: 100) {
            guard !Task.isCancelled else { return .init(candidate: nil, reason: "") }
            let batch = Array(candidates[start..<min(start + 100, candidates.count)])
            let response = try? await backend.post("/api/model-router/decision", body: [
                "tags": role.routingTags, "weights": ModelRoutingPolicy.bestAnswer.weights,
                "candidates": batch.map { $0.payload(current: draft) },
            ], as: ModelRoutingDecision.self)
            scorecards += response?.candidates ?? []
        }
        // An account may have signed out while scorecards were being fetched.
        let available = Set(providerAccountsModel.agentRoleModelCandidates().map(\.id))
        candidates.removeAll { !available.contains($0.id) }
        return .choose(role: role, candidates: candidates, current: draft, scorecards: scorecards)
    }
}
