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
        let model = AgentTeamsModel()
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
