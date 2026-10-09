import Foundation

extension AppModel {
    /// Readiness checks may use any explicitly assigned route. This does not
    /// choose a task model or borrow another account with a matching name.
    func readyAgentModelProfiles(_ profile: AgentProfile) -> [AgentProfile] {
        profile.resolvedModelChoices.compactMap { choice in
            var candidate = profile
            candidate.route = choice.route
            candidate.model = choice.model
            return (try? agentProfileProvider(candidate)) == nil ? nil : candidate
        }
    }

    func firstReadyAgentModelProfile(_ profile: AgentProfile) throws -> AgentProfile {
        if let ready = readyAgentModelProfiles(profile).first { return ready }
        _ = try agentProfileProvider(profile)
        return profile
    }

    func agentModelChoiceReferences(_ profiles: [AgentProfile]) -> [[String: Any]] {
        profiles.compactMap { profile in
            guard let resolved = try? agentProfileProvider(profile) else { return nil }
            var value: [String: Any] = ["model": profile.model, "provider": resolved.provider]
            if let accountID = resolved.accountID { value["provider_account_id"] = accountID }
            return value
        }
    }

    /// Chooses only from this agent's assigned accounts. The returned profile is
    /// a per-task snapshot; it never edits the saved agent or workspace defaults.
    func prepareAgentModelChoice(
        profile: AgentProfile,
        sessionID: String?,
        text: String,
        mode: WorkMode,
        requiresVision: Bool
    ) async -> AgentProfile {
        if let sessionID, hasManualChatModelSelection(sessionID: sessionID) {
            return agentChatProfile(profile, sessionID: sessionID)
        }
        let choices = profile.resolvedModelChoices
        guard choices.count > 1 else { return profile }
        var ready: [(choice: AgentModelChoice, candidate: AutomaticModelRouteCandidate)] = []
        for choice in choices {
            var candidateProfile = profile
            candidateProfile.route = choice.route
            candidateProfile.model = choice.model
            guard let resolved = try? agentProfileProvider(candidateProfile) else { continue }
            let local = choice.route.accountID == nil
            let localInfo = local ? localModels.first { $0.name.caseInsensitiveCompare(choice.model) == .orderedSame } : nil
            if requiresVision, localInfo?.visionCapable == false { continue }
            let account = choice.route.accountID.flatMap { id in providerAccounts.first { $0.id == id } }
            let id = Self.modelRouteID(accountID: choice.route.accountID, model: choice.model)
            ready.append((choice, AutomaticModelRouteCandidate(
                id: id, name: "\(choice.model) · \(account?.shortName ?? "Local")",
                model: choice.model, provider: resolved.provider, accountID: choice.route.accountID,
                local: local, metering: local ? "self_hosted" : (account?.kind.isManagedPlan == true || account?.kind == .kimiCode ? "subscription" : "metered"),
                memoryBytes: localInfo?.size ?? 0,
                current: choice.id == choices.first?.id,
                sampleIDs: [id]
            )))
        }
        guard !ready.isEmpty else { return profile }
        if ready.count > 1 {
            do {
                let decision = try await requestModelRoutingDecision(
                    candidates: ready.map(\.candidate), tags: Self.modelRoutingTags(for: text, mode: mode))
                let scores = Dictionary(decision.candidates.map { ($0.routeID, $0.score) }, uniquingKeysWith: { first, _ in first })
                let originalOrder = Dictionary(uniqueKeysWithValues: ready.enumerated().map { ($0.element.candidate.id, $0.offset) })
                ready.sort { left, right in
                    if left.candidate.id == right.candidate.id { return false }
                    if left.candidate.id == decision.selectedID { return true }
                    if right.candidate.id == decision.selectedID { return false }
                    let lhs = scores[left.candidate.id] ?? -.infinity
                    let rhs = scores[right.candidate.id] ?? -.infinity
                    return lhs == rhs ? originalOrder[left.candidate.id, default: 0] < originalOrder[right.candidate.id, default: 0] : lhs > rhs
                }
            } catch {
                // Scorecards are advisory. An unavailable router must not
                // prevent an otherwise ready, explicitly assigned route.
            }
        }
        var selected = profile
        selected.route = ready[0].choice.route
        selected.model = ready[0].choice.model
        selected.additionalModels = ready.dropFirst().map(\.choice)
        return selected
    }
}
