import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The opt-in per-message model router: policy toggles, scorecard,
/// candidate enumeration, applying and restoring routes.
extension AppModel {
    // MARK: - Optional solo model router

    func setAutomaticModelRoutingEnabled(_ enabled: Bool) {
        guard enabled != settings.automaticModelRoutingEnabled else { return }
        if enabled {
            rememberManualModelRoute(accountID: activeAccount?.id, model: selectedModel)
            settings.automaticModelRoutingEnabled = true
            modelRouterMessage = "Ready — the next solo message will use the scorecard."
            refreshModelRouterScorecard()
        } else {
            isRestoringManualModelRoute = true
            settings.automaticModelRoutingEnabled = false
            modelRouterMessage = "Automatic routing is off. Restoring the manual route…"
            Task { [weak self] in
                guard let self else { return }
                await restoreManualModelRoute()
                isRestoringManualModelRoute = false
            }
        }
    }

    func setAutomaticModelRoutingAllowHosted(_ allowed: Bool) {
        settings.automaticModelRoutingAllowHosted = allowed
        modelRouterMessage = allowed
            ? "Hosted accounts are eligible for future solo messages."
            : "Only models on this Mac are eligible."
        refreshModelRouterScorecard()
    }

    func setModelRoutingPolicy(_ policy: ModelRoutingPolicy) {
        settings.modelRoutingPolicyRaw = policy.rawValue
        refreshModelRouterScorecard()
    }

    /// Re-scores the available routes for a generic task without changing the
    /// active model. The Router inspector uses this after policy edits and on
    /// explicit refresh.
    func refreshModelRouterScorecard() {
        let candidates = automaticModelRouteCandidates(requiresVision: false)
        guard !candidates.isEmpty else {
            lastModelRoutingDecision = nil
            modelRouterMessage = settings.automaticModelRoutingAllowHosted
                ? "No ready model routes are available."
                : "No visible local models are available. Hosted routing is off."
            return
        }
        modelRouterMessage = "Scoring \(candidates.count) eligible route\(candidates.count == 1 ? "" : "s")…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let decision = try await requestModelRoutingDecision(
                    candidates: candidates,
                    tags: ["general"]
                )
                lastModelRoutingDecision = decision
                modelRouterMessage = decision.reason
            } catch {
                modelRouterMessage = "Could not load scorecards: \(error.localizedDescription)"
            }
        }
    }

    static func modelRoutingTags(for text: String, mode: WorkMode) -> [String] {
        let lower = text.lowercased()
        var tags: [String] = []
        func add(_ tag: String, when condition: Bool) {
            if condition, !tags.contains(tag) { tags.append(tag) }
        }
        add("coding", when: mode != .ask || [
            "code", "function", "class", "api", "compile", "refactor", ".swift",
            ".py", ".js", ".ts", ".rs", ".go",
        ].contains(where: lower.contains))
        add("debugging", when: ["bug", "debug", "crash", "error", "failing", "fix"]
            .contains(where: lower.contains))
        add("testing", when: ["test", "spec", "verify", "regression"]
            .contains(where: lower.contains))
        add("review", when: ["review", "audit", "security", "risk"]
            .contains(where: lower.contains))
        add("research", when: ["research", "compare", "sources", "browse", "latest"]
            .contains(where: lower.contains))
        add("writing", when: ["write", "rewrite", "draft", "summarize", "explain"]
            .contains(where: lower.contains))
        add("long_context", when: text.count > 12_000)
        if tags.isEmpty { tags.append("general") }
        return Array(tags.prefix(24))
    }

    func prepareAutomaticModelRoute(
        text: String,
        mode: WorkMode,
        requiresVision: Bool
    ) async -> ModelRoutingPreparedTurn? {
        let candidates = automaticModelRouteCandidates(requiresVision: requiresVision)
        guard !candidates.isEmpty else {
            modelRouterMessage = "No eligible route; using the manual model."
            return nil
        }
        let tags = Self.modelRoutingTags(for: text, mode: mode)
        do {
            let decision = try await requestModelRoutingDecision(
                candidates: candidates,
                tags: tags
            )
            lastModelRoutingDecision = decision
            modelRouterMessage = decision.reason
            guard let route = candidates.first(where: { $0.id == decision.selectedID }) else {
                return nil
            }
            guard await applyAutomaticModelRoute(route) else {
                modelRouterMessage = "The selected route was unavailable; using the manual model."
                return nil
            }
            let score = decision.candidates.first(where: { $0.routeID == route.id })?.score
            showToast(
                "Auto route: \(route.name)"
                    + (score.map { " · \(Int($0.rounded()))" } ?? "")
            )
            return ModelRoutingPreparedTurn(routeID: route.id, tags: tags, local: route.local)
        } catch {
            modelRouterMessage = "Router unavailable; using the manual model: \(error.localizedDescription)"
            return nil
        }
    }

    private func requestModelRoutingDecision(
        candidates: [AutomaticModelRouteCandidate],
        tags: [String]
    ) async throws -> ModelRoutingDecision {
        try await backend.post(
            "/api/model-router/decision",
            body: [
                "tags": tags,
                "weights": settings.resolvedModelRoutingPolicy.weights,
                "candidates": candidates.map(\.payload),
            ],
            as: ModelRoutingDecision.self
        )
    }

    private func automaticModelRouteCandidates(
        requiresVision: Bool
    ) -> [AutomaticModelRouteCandidate] {
        var routes: [AutomaticModelRouteCandidate] = localModels.compactMap { model in
            if requiresVision, model.visionCapable == false { return nil }
            let id = Self.modelRouteID(accountID: nil, model: model.name)
            let aliases = agentProfiles.compactMap { profile -> String? in
                guard profile.route.accountID == nil,
                      profile.model.caseInsensitiveCompare(model.name) == .orderedSame
                else { return nil }
                return profile.id.uuidString
            }
            return AutomaticModelRouteCandidate(
                id: id,
                name: "\(model.name) · Local",
                model: model.name,
                provider: "ollama",
                accountID: nil,
                local: true,
                metering: "self_hosted",
                memoryBytes: model.size,
                current: activeAccount == nil
                    && selectedModel.caseInsensitiveCompare(model.name) == .orderedSame,
                sampleIDs: [id] + aliases
            )
        }
        guard settings.automaticModelRoutingAllowHosted else { return routes }
        for account in providerAccounts where account.isCredentialReady(in: credentialStore) {
            guard accountStatus[account.id]?.isHealthy == true else { continue }
            let model = account.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let id = Self.modelRouteID(accountID: account.id, model: model)
            let aliases = agentProfiles.compactMap { profile -> String? in
                guard profile.route.accountID == account.id,
                      profile.model.caseInsensitiveCompare(model) == .orderedSame
                else { return nil }
                return profile.id.uuidString
            }
            let subscription = account.kind == .chatGPT || account.kind == .kimiCode
            routes.append(AutomaticModelRouteCandidate(
                id: id,
                name: "\(model) · \(account.shortName)",
                model: model,
                provider: account.kind.rawValue,
                accountID: account.id,
                local: false,
                metering: subscription ? "subscription" : "metered",
                memoryBytes: 0,
                current: activeAccount?.id == account.id
                    && selectedModel.caseInsensitiveCompare(model) == .orderedSame,
                sampleIDs: [id] + aliases
            ))
        }
        return routes
    }

    private static func modelRouteID(accountID: UUID?, model: String) -> String {
        let source = accountID?.uuidString.lowercased() ?? "ollama"
        return "model-route:\(source):\(model.lowercased())"
    }

    private func applyAutomaticModelRoute(_ route: AutomaticModelRouteCandidate) async -> Bool {
        let previousAccountID = settings.activeAccountID
        let previousProvider = settings.provider
        let previousModel = selectedModel
        let sourceChanged = route.accountID?.uuidString != settings.activeAccountID
        if let accountID = route.accountID {
            guard providerAccounts.contains(where: { $0.id == accountID }) else { return false }
            settings.activeAccountID = accountID.uuidString
            settings.provider = .remote
            if !sourceChanged { return true }
            guard await applyProvider(announce: false) else {
                settings.activeAccountID = previousAccountID
                settings.provider = previousProvider
                _ = await applyProvider(announce: false)
                return false
            }
            return true
        }

        settings.activeAccountID = nil
        settings.provider = .ollama
        if sourceChanged, !(await applyProvider(announce: false)) {
            settings.activeAccountID = previousAccountID
            settings.provider = previousProvider
            _ = await applyProvider(announce: false)
            return false
        }
        do {
            let state: ConfigStateResponse = try await backend.post(
                "/api/config", body: ["model": route.model], as: ConfigStateResponse.self
            )
            if let info = state.sessionInfo { sessionInfo = info }
            let transport = conversationBackend
            if transport !== backend {
                let _: ConfigStateResponse = try await transport.post(
                    "/api/config", body: ["model": route.model], as: ConfigStateResponse.self
                )
            }
            return true
        } catch {
            settings.activeAccountID = previousAccountID
            settings.provider = previousProvider
            _ = await applyProvider(announce: false)
            if previousAccountID == nil, !previousModel.isEmpty {
                let _: ConfigStateResponse? = try? await backend.post(
                    "/api/config", body: ["model": previousModel], as: ConfigStateResponse.self
                )
            }
            return false
        }
    }

    func rememberManualModelRoute(accountID: UUID?, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "No model" else { return }
        settings.modelRouterFallbackAccountID = accountID?.uuidString
        settings.modelRouterFallbackModel = trimmed
    }

    private func restoreManualModelRoute() async {
        let model = settings.modelRouterFallbackModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            modelRouterMessage = "Automatic routing is off."
            return
        }
        let accountID = settings.modelRouterFallbackAccountID.flatMap(UUID.init(uuidString:))
        let candidate = AutomaticModelRouteCandidate(
            id: Self.modelRouteID(accountID: accountID, model: model),
            name: model,
            model: model,
            provider: accountID == nil ? "ollama" : "account",
            accountID: accountID,
            local: accountID == nil,
            metering: accountID == nil ? "self_hosted" : "metered",
            memoryBytes: 0,
            current: false,
            sampleIDs: []
        )
        modelRouterMessage = await applyAutomaticModelRoute(candidate)
            ? "Automatic routing is off. Manual route restored."
            : "Automatic routing is off, but the saved manual route is unavailable."
    }

    func discardAutomaticModelRoutingTurn(
        for sessionID: String,
        matching prepared: ModelRoutingPreparedTurn?
    ) {
        guard let prepared,
              automaticModelRoutingTurns[sessionID]?.id == prepared.id
        else { return }
        automaticModelRoutingTurns.removeValue(forKey: sessionID)
    }

    func recordAutomaticModelRoutingOutcome(
        sessionID: String,
        reason: String,
        backendDurationMilliseconds: Int?
    ) {
        guard let routed = automaticModelRoutingTurns.removeValue(forKey: sessionID) else {
            return
        }
        let startedAt = taskWorkers[sessionID]?.startedAt
            ?? (currentSessionID == sessionID ? turnStartedAt : nil)
        let elapsed = startedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        let duration = max(backendDurationMilliseconds ?? elapsed, 0)
        Task { [weak self] in
            guard let self else { return }
            let _: SimpleActionResponse? = try? await backend.post(
                "/api/model-router/sample",
                body: [
                    "route_id": routed.routeID,
                    "tags": routed.tags,
                    "reliable": reason == "complete",
                    "latency_ms": duration,
                    "estimated_cost": 0,
                    "local": routed.local,
                    "evaluation": false,
                ],
                as: SimpleActionResponse.self
            )
        }
    }
}
