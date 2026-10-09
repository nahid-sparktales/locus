import XCTest

@testable import Locus

@MainActor
final class AgentModelRoutingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    func testTaskScoreChoosesAnAssignedAlternativeAndKeepsRemainingFallbacks() async throws {
        let account = ProviderAccount(kind: .chatGPT, name: "Assigned account")
        let preferred = AgentModelChoice(route: .localOllama, model: "preferred")
        let ranked = AgentModelChoice(route: .providerAccount(account.id), model: "ranked")
        let spare = AgentModelChoice(route: .localOllama, model: "spare")
        let profile = AgentProfile(name: "Reviewer", model: preferred.model,
            additionalModels: [ranked, spare])
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        model.providerAccounts = [account]
        model.agentProfiles = [profile]
        registerDecision(selected: ranked, scores: [(preferred, 50), (ranked, 95), (spare, 25)])

        let selected = await model.prepareAgentModelChoice(profile: profile, sessionID: nil,
            text: "Review the Swift code", mode: .work, requiresVision: false)

        XCTAssertEqual(selected.route, ranked.route)
        XCTAssertEqual(selected.model, ranked.model)
        XCTAssertEqual(selected.additionalModels, [preferred, spare])
        XCTAssertEqual(selected.id, profile.id)
        XCTAssertEqual(selected.instructions, profile.instructions)
        XCTAssertEqual(model.agentProfiles, [profile], "Task routing must not edit the saved profile")
        XCTAssertNil(model.settings.activeAccountID, "Task routing must not change workspace defaults")
        XCTAssertEqual(BackendStub.requestPaths, ["/api/model-router/decision"])
    }

    func testUnassignedRouterSelectionCannotIntroduceAnotherAccount() async throws {
        let preferred = AgentModelChoice(route: .localOllama, model: "preferred")
        let alternative = AgentModelChoice(route: .localOllama, model: "alternative")
        let unassigned = AgentModelChoice(route: .providerAccount(UUID()), model: "not-assigned")
        let profile = AgentProfile(name: "Reviewer", model: preferred.model, additionalModels: [alternative])
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        registerDecision(selected: unassigned, scores: [(unassigned, 100)])

        let selected = await model.prepareAgentModelChoice(profile: profile, sessionID: nil,
            text: "Review", mode: .ask, requiresVision: false)

        XCTAssertEqual(selected.resolvedModelChoices, [preferred, alternative])
        let payload = try requestBody(XCTUnwrap(BackendStub.requests.first))
        let candidates = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.compactMap { $0["model"] as? String }, ["preferred", "alternative"])
        XCTAssertFalse(candidates.contains { ($0["id"] as? String) == routeID(unassigned) })
        XCTAssertTrue(candidates.allSatisfy { $0["api_key"] == nil })
    }

    func testUnavailableScorecardsKeepThePreferredAssignedModel() async {
        BackendStub.respond(toPath: "/api/model-router/decision", status: 503) { _ in ["error": "unavailable"] }
        let profile = AgentProfile(name: "Reviewer", model: "preferred",
            additionalModels: [.init(route: .localOllama, model: "alternative")])
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())

        let selected = await model.prepareAgentModelChoice(profile: profile, sessionID: nil,
            text: "Review", mode: .work, requiresVision: false)

        XCTAssertEqual(selected.resolvedModelChoices, profile.resolvedModelChoices)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/model-router/decision"])
    }

    func testRemovedPrimaryAccountUsesAnAssignedAlternativeWithoutAdoptingAnotherAccount() async {
        let missing = ProviderAccount(kind: .chatGPT, name: "Same name", preferredModel: "same-model")
        let unassigned = ProviderAccount(kind: .chatGPT, name: "Same name", preferredModel: "same-model")
        let fallback = AgentModelChoice(route: .localOllama, model: "assigned-local")
        let profile = AgentProfile(name: "Reviewer", route: .providerAccount(missing.id),
            model: "same-model", additionalModels: [fallback])
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        model.providerAccounts = [unassigned]

        let selected = await model.prepareAgentModelChoice(profile: profile, sessionID: nil,
            text: "Review", mode: .work, requiresVision: false)

        XCTAssertEqual(selected.route, fallback.route)
        XCTAssertEqual(selected.model, fallback.model)
        XCTAssertEqual(selected.resolvedModelChoices, [fallback])
        XCTAssertNoBackendTraffic()
    }

    func testExplicitChatSelectionBypassesAutomaticAssignmentScores() async {
        let profile = AgentProfile(name: "Reviewer", model: "preferred",
            additionalModels: [.init(route: .localOllama, model: "alternative")])
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        model.agentProfiles = [profile]
        model.sessions = [SessionSummary(id: "model-chat", name: "Chat", preview: "", mtime: 1, size: 0,
            agentProfileID: profile.id.uuidString)]
        model.installTranscriptSession("model-chat", blocks: [])
        model.settings.chatModelRoutes["model-chat"] = ChatModelRoute(model: "manually-chosen", provider: "ollama",
            accountID: nil, profileID: profile.id, selection: "manual", established: true)

        let selected = await model.prepareAgentModelChoice(profile: profile, sessionID: "model-chat",
            text: "Review", mode: .work, requiresVision: false)

        XCTAssertEqual(selected.model, "manually-chosen")
        XCTAssertEqual(selected.route, .localOllama)
        XCTAssertEqual(model.agentProfiles, [profile])
        XCTAssertNoBackendTraffic()
    }

    func testTeamManifestUsesAssignedAlternativesAfterThePrimaryAccountIsRemoved() throws {
        let missing = ProviderAccount(kind: .chatGPT, name: "Same name", preferredModel: "same-model")
        let unrelated = ProviderAccount(kind: .chatGPT, name: "Same name", preferredModel: "same-model")
        let dispatcher = AgentProfile(name: "Dispatch", route: .providerAccount(missing.id), model: "same-model",
            role: .dispatcher, additionalModels: [
                .init(route: .localOllama, model: "assigned-local"),
                .init(route: .localOllama, model: "spare-local"),
            ])
        let model = teamModel(dispatcher: dispatcher)
        model.providerAccounts = [unrelated]
        model.agentTeamsModel.grantAutomaticRoutingConsent(for: unrelated.id)

        let manifest = try XCTUnwrap(model.teamManifest(for: "Review"))
        let entry = try dispatcherEntry(in: manifest, id: dispatcher.id)
        let route = try XCTUnwrap(entry["route"] as? [String: Any])
        let choices = try XCTUnwrap(entry["agent_model_choices"] as? [[String: Any]])

        XCTAssertEqual(entry["model"] as? String, "assigned-local")
        XCTAssertEqual(route["provider"] as? String, "ollama")
        XCTAssertEqual(choices.compactMap { $0["model"] as? String }, ["assigned-local", "spare-local"])
        XCTAssertTrue(choices.allSatisfy { $0["provider_account_id"] == nil })
        XCTAssertEqual(model.agentProfiles.first { $0.id == dispatcher.id }?.route, dispatcher.route)
    }

    func testTeamManifestRejectsAnUnassignedAccountEvenWhenItsNameAndModelMatch() {
        let missing = ProviderAccount(kind: .chatGPT, name: "Same name", preferredModel: "same-model")
        let unrelated = ProviderAccount(kind: .chatGPT, name: "Same name", preferredModel: "same-model")
        let dispatcher = AgentProfile(name: "Dispatch", route: .providerAccount(missing.id), model: "same-model", role: .dispatcher)
        let model = teamModel(dispatcher: dispatcher)
        model.providerAccounts = [unrelated]
        model.agentTeamsModel.grantAutomaticRoutingConsent(for: unrelated.id)

        XCTAssertNil(model.teamManifest(for: "Review"))
        XCTAssertNoBackendTraffic()
    }

    func testTeamManifestOmitsAnAssignedHostedModelUntilRoutingConsentExists() throws {
        let hosted = ProviderAccount(kind: .chatGPT, name: "Assigned hosted")
        let dispatcher = AgentProfile(name: "Dispatch", model: "preferred", role: .dispatcher,
            additionalModels: [
                .init(route: .providerAccount(hosted.id), model: "hosted-model"),
                .init(route: .localOllama, model: "spare-local"),
            ])
        let model = teamModel(dispatcher: dispatcher)
        model.providerAccounts = [hosted]
        let initial = try dispatcherEntry(in: XCTUnwrap(model.teamManifest(for: "Review")), id: dispatcher.id)
        let initialChoices = try XCTUnwrap(initial["agent_model_choices"] as? [[String: Any]])
        XCTAssertEqual(initialChoices.compactMap { $0["model"] as? String }, ["preferred", "spare-local"])

        model.agentTeamsModel.grantAutomaticRoutingConsent(for: hosted.id)
        let consented = try dispatcherEntry(in: XCTUnwrap(model.teamManifest(for: "Review")), id: dispatcher.id)
        let choices = try XCTUnwrap(consented["agent_model_choices"] as? [[String: Any]])
        XCTAssertEqual(choices.compactMap { $0["model"] as? String }, ["preferred", "hosted-model", "spare-local"])
        XCTAssertEqual(choices[1]["provider_account_id"] as? String, hosted.id.uuidString)
    }

    func testResponsesDispatcherPoolIncludesOnlyAssignedOpenAIAPIGPT56Models() throws {
        let api = ProviderAccount(kind: .codex, name: "Assigned API")
        let plan = ProviderAccount(kind: .chatGPT, name: "Assigned plan")
        let dispatcher = AgentProfile(name: "Dispatch", model: "local-dispatch", role: .dispatcher,
            additionalModels: [
                .init(route: .providerAccount(api.id), model: "gpt-5.6"),
                .init(route: .providerAccount(api.id), model: "gpt-5.6-mini"),
                .init(route: .providerAccount(api.id), model: "gpt-4.1"),
                .init(route: .providerAccount(plan.id), model: "gpt-5.6"),
            ])
        let model = teamModel(dispatcher: dispatcher, engine: .openAIResponses)
        model.providerAccounts = [api, plan]
        model.credentialStore.set("fixture-key", account: api.credentialAccount)
        model.agentTeamsModel.grantAutomaticRoutingConsent(for: api.id)
        model.agentTeamsModel.grantAutomaticRoutingConsent(for: plan.id)

        let entry = try dispatcherEntry(in: XCTUnwrap(model.teamManifest(for: "Review")), id: dispatcher.id)
        let route = try XCTUnwrap(entry["route"] as? [String: Any])
        let choices = try XCTUnwrap(entry["agent_model_choices"] as? [[String: Any]])

        XCTAssertEqual(entry["model"] as? String, "gpt-5.6")
        XCTAssertEqual(route["account_kind"] as? String, ProviderKind.codex.rawValue)
        XCTAssertEqual(choices.compactMap { $0["model"] as? String }, ["gpt-5.6", "gpt-5.6-mini"])
        XCTAssertTrue(choices.allSatisfy { ($0["provider_account_id"] as? String) == api.id.uuidString })
        XCTAssertTrue(choices.allSatisfy { $0["api_key"] == nil })
    }

    private func teamModel(dispatcher: AgentProfile, engine: SwarmPolicy.Engine = .locusManaged) -> AppModel {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let writer = AgentProfile(name: "Writer", model: "local-writer", role: .implementer, accessCeiling: .workspaceWrite)
        model.agentTeamsModel.saveAgentProfile(dispatcher)
        model.agentTeamsModel.saveAgentProfile(writer)
        var team = AgentTeam(name: "Assigned model team", dispatcherID: dispatcher.id,
            memberIDs: [dispatcher.id, writer.id], defaultWriterID: writer.id)
        team.swarmPolicy = SwarmPolicy(engine: engine)
        model.agentTeamsModel.saveAgentTeam(team)
        model.agentTeamsModel.selectAgentTeam(team.id)
        return model
    }

    private func dispatcherEntry(in manifest: [String: Any], id: UUID) throws -> [String: Any] {
        let profiles = try XCTUnwrap(manifest["profiles"] as? [[String: Any]])
        return try XCTUnwrap(profiles.first { ($0["id"] as? String) == id.uuidString })
    }

    func testNewAgentDraftKeepsTheChatsAccountAndModelTogether() {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let global = ProviderAccount(kind: .chatGPT, preferredModel: "global-model")
        let chat = ProviderAccount(kind: .claudePlan, preferredModel: "chat-model")
        model.providerAccounts = [global, chat]
        model.settings.activeAccountID = global.id.uuidString
        model.installTranscriptSession("draft-chat", blocks: [])
        model.settings.chatModelRoutes["draft-chat"] = ChatModelRoute(model: "chat-model", provider: "claude_plan",
            accountID: chat.id, profileID: nil, established: true)
        XCTAssertEqual(model.newSavedAgentDraft().route, .providerAccount(chat.id))
        XCTAssertEqual(model.newSavedAgentDraft().model, "chat-model")
        model.settings.chatModelRoutes["draft-chat"] = ChatModelRoute(model: "local-model", provider: "ollama",
            accountID: nil, profileID: nil, established: true)
        XCTAssertEqual(model.newSavedAgentDraft().route, .localOllama)
        XCTAssertEqual(model.newSavedAgentDraft().model, "local-model")
    }

    private func routeID(_ choice: AgentModelChoice) -> String {
        AppModel.modelRouteID(accountID: choice.route.accountID, model: choice.model)
    }

    private func registerDecision(selected: AgentModelChoice, scores: [(AgentModelChoice, Double)]) {
        let candidates: [[String: Any]] = scores.map { choice, score in
            ["route_id": routeID(choice), "name": choice.model, "model": choice.model,
             "provider": choice.route.accountID == nil ? "ollama" : "chatgpt",
             "local": choice.route.accountID == nil, "current": false,
             "selected": choice == selected, "score": score, "components": [:], "weights": [:],
             "sample_count": 8, "evaluation_count": 8, "limited_data": false]
        }
        let body: [String: Any] = ["selected_id": routeID(selected), "limited_data": false,
            "reason": "fixture scorecard", "tags": ["code"], "candidates": candidates]
        BackendStub.respond(toPath: "/api/model-router/decision") { _ in body }
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
