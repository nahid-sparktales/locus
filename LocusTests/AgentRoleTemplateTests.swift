import XCTest
@testable import Locus

final class AgentRoleTemplateTests: XCTestCase {
    private func catalog() throws -> AgentRoleCatalog {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try AgentRoleCatalog.load(backendRoot: root.appendingPathComponent("agent").path, resources: nil)
    }
    private func role(_ id: String) throws -> AgentRoleTemplate {
        try XCTUnwrap(catalog().roles.first { $0.id == id })
    }

    func testCatalogHasEveryRoleAndSearchesNamesDescriptionsAndTags() throws {
        let roles = try catalog().roles
        XCTAssertEqual(roles.count, 27)
        XCTAssertEqual(Set(roles.map(\.id)).count, 27)
        XCTAssertTrue(try role("version-control").matches("version"))
        XCTAssertTrue(try role("ui-ux-designer").matches("design"))
        XCTAssertFalse(try role("planner").matches("not-a-role"))
        XCTAssertTrue(roles.allSatisfy { !$0.instructions.contains("ExitPlanMode") })
    }

    func testTemplateApplicationPreservesIdentityWorkspaceAndEditableInstructions() throws {
        var original = AgentProfile(name: "Custom", model: "my-model", instructions: "Before")
        original.workspacePreferences = .init()
        let selected = try role("architect").applying(to: original)
        XCTAssertEqual(selected.id, original.id)
        XCTAssertEqual(selected.workspacePreferences, original.workspacePreferences)
        XCTAssertEqual(selected.route, original.route)
        XCTAssertEqual(selected.model, "my-model")
        XCTAssertEqual(selected.role, .planner)
        XCTAssertEqual(selected.accessCeiling, .readOnly)
        XCTAssertEqual(selected.defaultMode, .plan)
        XCTAssertEqual(selected.resolvedBehavior.specialistRoleID, "architect")
        XCTAssertEqual(selected.instructions, selected.resolvedBehavior.customInstructions)
        var edited = selected
        edited.behavior?.customInstructions = "My edited instructions"
        edited.clamp()
        let roundTrip = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundTrip.instructions, "My edited instructions")
        XCTAssertEqual(roundTrip.resolvedBehavior.specialistRoleID, "architect")
        XCTAssertEqual(roundTrip.defaultMode, .plan)
    }

    func testLegacyProfileDecodesWithoutTemplateOrDefaultMode() throws {
        let original = AgentProfile(name: "Existing", model: "model", instructions: "Keep my behavior")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        raw.removeValue(forKey: "defaultMode")
        var behavior = try XCTUnwrap(raw["behavior"] as? [String: Any])
        behavior.removeValue(forKey: "specialist_role_id")
        raw["behavior"] = behavior
        let restored = try JSONDecoder().decode(AgentProfile.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(restored.defaultMode)
        XCTAssertNil(restored.resolvedBehavior.specialistRoleID)
        XCTAssertEqual(restored.instructions, "Keep my behavior")
        XCTAssertEqual(restored.id, original.id)
    }

    func testRoleMappingsPreserveTeamContractsAndAccessCeilings() throws {
        XCTAssertEqual(try role("security-auditor").executionRole, .reviewer)
        XCTAssertEqual(try role("explorer").executionRole, .researcher)
        XCTAssertEqual(try role("data-engineer").executionRole, .implementer)
        XCTAssertEqual(try role("content-copywriter").executionRole, .generalist)
        for template in try catalog().roles {
            XCTAssertNotEqual(template.accessCeiling, .computerControl)
            let profile = template.applying(to: AgentProfile(name: "Blank", model: "model"))
            XCTAssertEqual(profile.resolvedBehavior.capabilityPolicy.workspaceWrite, template.accessCeiling.canWrite)
        }
    }

    func testRecommendationsPreferRelevantCapabilitiesAndPreserveAccountIdentity() throws {
        let first = AgentRoleModelCandidate(route: .providerAccount(UUID()), model: "same-model", contextWindow: 16_000)
        let second = AgentRoleModelCandidate(route: .providerAccount(UUID()), model: "same-model", contextWindow: 128_000,
                                             supportsVision: true, supportsReasoning: true)
        let draft = AgentProfile(name: "Agent", route: first.route, model: first.model)
        for id in ["ui-ux-designer", "researcher", "implementer"] {
            let result = AgentRoleModelRecommendation.choose(role: try role(id), candidates: [first, second], current: draft)
            XCTAssertEqual(result.candidate?.route, second.route)
        }
        let general = AgentRoleModelRecommendation.choose(role: try role("content-copywriter"),
                                                          candidates: [second, first], current: draft)
        XCTAssertEqual(general.candidate?.route, first.route)
    }

    func testRecommendationsNeedFiveEvaluationsAndHandleNoModels() throws {
        let current = AgentRoleModelCandidate(route: .localOllama, model: "current")
        let evaluated = AgentRoleModelCandidate(route: .localOllama, model: "evaluated")
        let draft = AgentProfile(name: "Agent", model: "current")
        func score(_ count: Int) -> ModelRoutingScorecard {
            .init(routeID: evaluated.id, name: "evaluated", model: "evaluated", provider: "ollama", local: true,
                  current: false, selected: true, score: 95, components: ["quality": 95], weights: [:],
                  sampleCount: count, evaluationCount: count, limitedData: count < 5)
        }
        let template = try role("generalist")
        XCTAssertEqual(AgentRoleModelRecommendation.choose(role: template, candidates: [current, evaluated],
            current: draft, scorecards: [score(4)]).candidate?.model, "current")
        XCTAssertEqual(AgentRoleModelRecommendation.choose(role: template, candidates: [current, evaluated],
            current: draft, scorecards: [score(5)]).candidate?.model, "evaluated")
        let unavailable = AgentRoleModelRecommendation.choose(role: template, candidates: [], current: draft)
        XCTAssertNil(unavailable.candidate)
        XCTAssertTrue(unavailable.reason.contains("Choose or connect"))
    }

    func testTiesAreStableForLargeCatalogAndUnknownMetadata() throws {
        let models = (0..<205).map { AgentRoleModelCandidate(route: .localOllama, model: String(format: "model-%03d", $0)) }
        let draft = AgentProfile(name: "Agent", model: "not-available")
        let template = try role("generalist")
        let forward = AgentRoleModelRecommendation.choose(role: template, candidates: models, current: draft)
        let reversed = AgentRoleModelRecommendation.choose(role: template, candidates: models.reversed(), current: draft)
        XCTAssertEqual(forward.candidate, reversed.candidate)
        XCTAssertEqual(forward.candidate?.model, "model-000")
    }

    @MainActor
    func testKimiSavedKeyAndCuratedModelsAreNotRecommendationEvidence() {
        let fixture = RoleModelVerificationFixture()
        fixture.model.accountModels[fixture.account.id] = ["kimi-for-coding", "kimi-k2"]
        fixture.model.accountStatus[fixture.account.id] = .keySaved

        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
        XCTAssertEqual(fixture.testedModels, [], "Recommendations must not send model inference requests")
    }

    @MainActor
    func testKimiExactSuccessfulProbeMakesOnlyThatModelEligible() async {
        let fixture = RoleModelVerificationFixture()
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        // A routine non-listing catalog refresh returns Key saved; it must
        // neither discard fresh exact proof nor promote its fallback menu.
        fixture.model.accountStatus[fixture.account.id] = .keySaved
        fixture.model.accountModels[fixture.account.id] = ["kimi-for-coding", "kimi-k2"]
        let candidates = fixture.model.agentRoleModelCandidates()

        XCTAssertEqual(candidates.map(\.model), ["kimi-for-coding"])
        XCTAssertEqual(candidates.first?.route, .providerAccount(fixture.account.id))
        XCTAssertEqual(candidates.first?.subscription, true)
        XCTAssertFalse(fixture.model.hasAuthoritativeModelCatalog(for: fixture.account.id))
        XCTAssertEqual(fixture.testedModels, ["kimi-for-coding"])
    }

    @MainActor
    func testFailedKimiProbeInvalidatesEarlierConfirmationUsingTypedOutcome() async {
        let fixture = RoleModelVerificationFixture()
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        XCTAssertEqual(fixture.model.agentRoleModelCandidates().count, 1)
        fixture.outcome = .init(ok: false, message: "Connected account, but model unavailable")
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        fixture.model.accountStatus[fixture.account.id] = .keySaved

        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
    }

    @MainActor
    func testKimiConfirmationExpiresAndForgetEvictsIt() async {
        let fixture = RoleModelVerificationFixture()
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        fixture.now += ProviderAccountsModel.accountCatalogTTL - 1
        XCTAssertEqual(fixture.model.agentRoleModelCandidates().count, 1)
        fixture.now += 1
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        XCTAssertEqual(fixture.model.agentRoleModelCandidates().count, 1)
        fixture.model.forgetAccountCatalog(fixture.account.id)
        fixture.model.accountStatus[fixture.account.id] = .keySaved
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
    }

    @MainActor
    func testKimiConfirmationIsBoundToAccountSettingsAndCredential() async {
        let fixture = RoleModelVerificationFixture()
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        fixture.model.providerAccounts[0].preferredModel = "kimi-k2"
        fixture.model.providerAccounts[0] = fixture.account
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty,
            "Returning to previous settings must not revive invalidated evidence")
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        fixture.credentials.set("replacement-fixture-key", account: fixture.account.credentialAccount)
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
        fixture.credentials.set("fixture-key", account: fixture.account.credentialAccount)
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
        _ = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")
        fixture.model.providerAccounts = []
        fixture.model.providerAccounts = [fixture.account]
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
    }

    @MainActor
    func testKimiProbeCannotConfirmAnAccountEditedWhileAwaitingResponse() async {
        let fixture = RoleModelVerificationFixture()
        fixture.onTest = { [weak fixture] in
            guard let fixture else { return }
            fixture.model.providerAccounts[0].baseURLOverride = "https://example.invalid/v1"
            fixture.model.providerAccounts[0] = fixture.account
        }
        let result = await fixture.model.testConnection(for: fixture.account.id, model: "kimi-for-coding")

        XCTAssertTrue(result.contains("account changed"))
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
    }

    @MainActor
    func testSettingsProbeOnlyBecomesEligibleAfterMatchingDraftAndKeyAreSaved() throws {
        let fixture = RoleModelVerificationFixture()
        fixture.model.providerAccounts = []
        let evidence = try XCTUnwrap(fixture.model.exactModelConnectionEvidence(
            for: fixture.account, model: "kimi-for-coding", apiKey: "new-fixture-key", outcome: fixture.outcome))
        XCTAssertFalse(fixture.model.acceptExactModelConnectionEvidence(evidence))
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)

        // Mirrors account Save: commit settings/key, forget the old catalog,
        // then revalidate the original test evidence without another probe.
        fixture.model.providerAccounts = [fixture.account]
        fixture.model.forgetAccountCatalog(fixture.account.id)
        XCTAssertFalse(fixture.model.acceptExactModelConnectionEvidence(evidence), "The saved key still differs")
        fixture.credentials.set("new-fixture-key", account: fixture.account.credentialAccount)
        XCTAssertTrue(fixture.model.acceptExactModelConnectionEvidence(evidence))
        XCTAssertEqual(fixture.model.agentRoleModelCandidates().map(\.model), ["kimi-for-coding"])
        XCTAssertTrue(fixture.testedModels.isEmpty)
    }

    @MainActor
    func testSettingsProbeCannotBeTransferredToEditedOrExpiredDraft() throws {
        let fixture = RoleModelVerificationFixture()
        let evidence = try XCTUnwrap(fixture.model.exactModelConnectionEvidence(
            for: fixture.account, model: "kimi-for-coding", apiKey: "fixture-key", outcome: fixture.outcome))
        fixture.model.providerAccounts[0].contextWindow = 32_000
        XCTAssertFalse(fixture.model.acceptExactModelConnectionEvidence(evidence))
        fixture.model.providerAccounts[0] = fixture.account
        fixture.now += ProviderAccountsModel.accountCatalogTTL
        XCTAssertFalse(fixture.model.acceptExactModelConnectionEvidence(evidence))
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
    }

    @MainActor
    func testFailedSettingsProbeRevokesPreviouslyVerifiedModel() throws {
        let fixture = RoleModelVerificationFixture()
        let evidence = try XCTUnwrap(fixture.model.exactModelConnectionEvidence(
            for: fixture.account, model: "kimi-for-coding", apiKey: "fixture-key", outcome: fixture.outcome))
        XCTAssertTrue(fixture.model.acceptExactModelConnectionEvidence(evidence))
        let failure = try XCTUnwrap(fixture.model.exactModelConnectionEvidence(
            for: fixture.account, model: "kimi-for-coding", apiKey: "fixture-key",
            outcome: .init(ok: false, message: "Model rejected")))
        XCTAssertFalse(fixture.model.acceptExactModelConnectionEvidence(failure))
        fixture.model.accountStatus[fixture.account.id] = .keySaved
        XCTAssertTrue(fixture.model.agentRoleModelCandidates().isEmpty)
    }
}

@MainActor
private final class RoleModelVerificationFixture {
    let account = ProviderAccount(kind: .kimiCode, preferredModel: "kimi-for-coding")
    let credentials = InMemoryCredentialStore()
    var now = Date(timeIntervalSince1970: 1_000)
    var outcome = RemoteEndpointTester.Outcome(ok: true, message: "Probe succeeded")
    var testedModels: [String] = []
    var onTest: (() -> Void)?
    lazy var model: ProviderAccountsModel = {
        let model = ProviderAccountsModel(credentialStore: credentials, verificationDate: { [weak self] in
            self?.now ?? .distantFuture
        }, endpointConnectionTest: { [weak self] _, model, _, _ in
            guard let self else { return .init(ok: false, message: "Fixture released") }
            testedModels.append(model)
            onTest?()
            return outcome
        })
        model.providerAccounts = [account]
        return model
    }()

    init() {
        credentials.set("fixture-key", account: account.credentialAccount)
    }
}
