import Combine
import XCTest

@testable import Locus

@MainActor
final class AgentTeamsModelTests: XCTestCase {
    private var toasts: [String] = []
    private var workspacePersistRequests = 0
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        toasts = []
        workspacePersistRequests = 0
        suiteName = "agent-teams-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeModel(persistenceEnabled: Bool = true) -> AgentTeamsModel {
        let model = AgentTeamsModel(credentialStore: InMemoryCredentialStore())
        model.restore(persistenceEnabled: persistenceEnabled, defaults: defaults)
        model.configure(
            isBusyProvider: { false },
            workspacePersistenceRequested: { [weak self] in self?.workspacePersistRequests += 1 },
            localModelsProvider: { [] },
            accountsProvider: { [] },
            accountModelsProvider: { _ in nil },
            toastHandler: { [weak self] in self?.toasts.append($0) }
        )
        return model
    }

    func testMemoryDefaultsEnableAutomaticRecallAndSaving() throws {
        let policies = [
            AgentMemoryPolicy(),
            try JSONDecoder().decode(AgentMemoryPolicy.self, from: Data("{}".utf8)),
            try JSONDecoder().decode(AgentBehavior.self, from: Data("{}".utf8)).memoryPolicy,
        ]
        for policy in policies {
            XCTAssertTrue(policy.recallEnabled)
            XCTAssertTrue(policy.proposalsEnabled)
            XCTAssertTrue(policy.autoSaveEnabled)
            XCTAssertTrue(policy.searchEnabled)
            XCTAssertTrue(policy.nativeCodexEnabled)
        }
    }

    func testLegacyMemoryPolicyPreservesExplicitOptOuts() throws {
        let policy = try JSONDecoder().decode(
            AgentMemoryPolicy.self,
            from: Data(#"{"recall_enabled":false,"proposals_enabled":false,"search_enabled":false,"native_codex_enabled":false}"#.utf8)
        )

        XCTAssertFalse(policy.recallEnabled)
        XCTAssertFalse(policy.proposalsEnabled)
        XCTAssertFalse(policy.searchEnabled)
        XCTAssertFalse(policy.nativeCodexEnabled)
        XCTAssertTrue(policy.autoSaveEnabled)
    }

    func testMemoryReviewModeRoundTripsWithAutomaticRecallEnabled() throws {
        var policy = AgentMemoryPolicy()
        policy.autoSaveEnabled = false
        let data = try JSONEncoder().encode(policy)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(encoded["auto_save_enabled"] as? Bool, false)

        let restored = try JSONDecoder().decode(AgentMemoryPolicy.self, from: data)
        XCTAssertFalse(restored.autoSaveEnabled)
        XCTAssertTrue(restored.recallEnabled)
        XCTAssertTrue(restored.proposalsEnabled)
    }

    func testAutomaticMemorySettingsPersistForPrimaryAndSpecialist() {
        let model = makeModel()
        var primary = model.primaryAgentBehavior
        primary.memoryPolicy.autoSaveEnabled = false
        primary.memoryPolicy.recallEnabled = false
        model.savePrimaryAgentBehavior(primary)

        var profile = AgentProfile(name: "Researcher", model: "llama3")
        var behavior = profile.resolvedBehavior
        behavior.memoryPolicy.autoSaveEnabled = false
        behavior.memoryPolicy.nativeCodexEnabled = false
        profile.behavior = behavior
        model.saveAgentProfile(profile)

        let restored = makeModel()
        XCTAssertFalse(restored.primaryAgentBehavior.memoryPolicy.autoSaveEnabled)
        XCTAssertFalse(restored.primaryAgentBehavior.memoryPolicy.recallEnabled)
        XCTAssertFalse(restored.agentProfiles[0].resolvedBehavior.memoryPolicy.autoSaveEnabled)
        XCTAssertFalse(restored.agentProfiles[0].resolvedBehavior.memoryPolicy.nativeCodexEnabled)
        XCTAssertTrue(restored.agentProfiles[0].resolvedBehavior.memoryPolicy.recallEnabled)
    }

    func testSelectingATeamDisablesSoloDelegationAndBack() {
        let model = makeModel()
        let profile = AgentProfile(name: "Coder", model: "llama3", role: .dispatcher)
        let team = AgentTeam(
            name: "Team A",
            dispatcherID: profile.id,
            fallbackDispatcherID: nil,
            memberIDs: [profile.id],
            defaultWriterID: nil
        )
        model.agentProfiles = [profile]
        model.agentTeams = [team]

        model.selectAgentTeam(team.id)
        XCTAssertEqual(model.selectedAgentTeamID, team.id)
        XCTAssertFalse(model.soloSwarmEnabled)

        model.selectSoloRoute()
        XCTAssertNil(model.selectedAgentTeamID)
        XCTAssertTrue(model.soloSwarmEnabled)
        XCTAssertEqual(toasts, ["Team mode", "Solo mode"])
        XCTAssertGreaterThan(workspacePersistRequests, 0)
    }

    func testProfileNameCollisionIsRejected() {
        let model = makeModel()
        let first = AgentProfile(name: "Coder", model: "llama3")
        model.saveAgentProfile(first)
        let duplicate = AgentProfile(name: "coder", model: "llama3")
        model.saveAgentProfile(duplicate)

        XCTAssertEqual(model.agentProfiles.count, 1)
        XCTAssertTrue(toasts.contains("Agent names must be unique"))
        XCTAssertEqual(AgentTeamStore.loadProfiles(from: defaults).map(\.id), [first.id],
                       "Profile saves must use the model's injected defaults, including in tests")
    }

    func testRemovingAProfileCascadesThroughTeams() {
        let model = makeModel()
        let profile = AgentProfile(name: "Coder", model: "llama3")
        let team = AgentTeam(
            name: "Team A",
            dispatcherID: profile.id,
            fallbackDispatcherID: nil,
            memberIDs: [profile.id],
            defaultWriterID: nil
        )
        model.agentProfiles = [profile]
        model.agentTeams = [team]
        model.selectedAgentTeamID = team.id

        model.removeAgentProfile(profile)
        XCTAssertEqual(model.agentProfiles, [])
        XCTAssertEqual(model.agentTeams[0].memberIDs, [])
        XCTAssertNil(model.agentTeams[0].dispatcherID)
    }

    func testRestoreDropsSelectionForDeletedTeams() {
        let team = AgentTeam(
            name: "Kept",
            dispatcherID: nil,
            fallbackDispatcherID: nil,
            memberIDs: [],
            defaultWriterID: nil
        )
        AgentTeamStore.save(profiles: [], teams: [team], to: defaults)
        defaults.set(UUID().uuidString, forKey: AgentTeamStore.selectionKey)

        let model = makeModel()
        XCTAssertEqual(model.agentTeams.map(\.name), ["Kept"])
        XCTAssertNil(model.selectedAgentTeamID, "a selection pointing at a deleted team must clear")
    }

    func testDisabledPersistenceNeverTouchesDefaults() {
        let model = makeModel(persistenceEnabled: false)
        let team = AgentTeam(
            name: "Team A",
            dispatcherID: nil,
            fallbackDispatcherID: nil,
            memberIDs: [],
            defaultWriterID: nil
        )
        model.agentTeams = [team]
        model.selectAgentTeam(team.id)
        XCTAssertNil(defaults.object(forKey: AgentTeamStore.selectionKey))
        XCTAssertNil(defaults.object(forKey: AgentTeamStore.consentKey))
    }

}
