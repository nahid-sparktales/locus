import XCTest
@testable import Locus

@MainActor
final class CompanionIntegrationTests: XCTestCase {
    func testExploreCommitsIdentityWithoutChangingTheCurrentWork() throws {
        let app = AppModel(startImmediately: false)
        app.draftText = "An unsent private draft"
        let session = app.currentSessionID
        let workspace = app.workspacePath
        let route = app.selectedModel
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settings = try encoder.encode(app.settings)
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("  みどり 🌿  ")
        let appearance = CompanionAppearance(character: .frog, palette: .violet, accessory: .glasses)
        app.onboarding.selectCompanionAppearance(appearance)
        app.finishCompanionSetup(startChat: false)

        let id = try XCTUnwrap(app.agentTeamsModel.primaryCompanionID)
        let profile = try XCTUnwrap(app.agentProfiles.first { $0.id == id })
        XCTAssertEqual(profile.name, "みどり 🌿")
        XCTAssertEqual(app.agentTeamsModel.agentAppearances[id], appearance)
        XCTAssertEqual(app.currentSessionID, session)
        XCTAssertEqual(app.workspacePath, workspace)
        XCTAssertEqual(app.draftText, "An unsent private draft")
        XCTAssertEqual(app.selectedModel, route)
        XCTAssertEqual(try encoder.encode(app.settings), settings)
        XCTAssertFalse(app.isBusy)
        XCTAssertNil(app.onboarding.progress.run)
        XCTAssertFalse(app.onboarding.progress.firstTaskCompleted)
        XCTAssertFalse(app.onboarding.showsCompanionSetup)
        XCTAssertTrue(app.onboarding.isPresented)
    }

    func testOfflineStartSelectsCanonicalProfileAndRemainsRetryable() throws {
        let app = AppModel(startImmediately: false)
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("Mochi")
        app.finishCompanionSetup(startChat: true)
        let id = try XCTUnwrap(app.agentTeamsModel.primaryCompanionID)
        XCTAssertEqual(app.savedAgentOverviewID, id)
        XCTAssertEqual(app.selectedSavedAgentID, id)
        XCTAssertFalse(app.onboarding.isPresented)
        XCTAssertFalse(app.isBusy)
        XCTAssertFalse(app.pendingSessionReset)
        XCTAssertTrue(app.creatingSavedAgentChatIDs.isEmpty)
        app.finishCompanionSetup(startChat: true)
        XCTAssertEqual(app.agentProfiles.filter { $0.id == id }.count, 1)
        XCTAssertEqual(app.agentTeamsModel.primaryCompanionID, id)
    }

    func testLinkingExistingProfilePreservesRouteAccessMemoryAndCustomPortrait() throws {
        let app = AppModel(startImmediately: false)
        var profile = AgentProfile(name: "Existing", model: "exact-model", instructions: "Keep these instructions",
            accessCeiling: .workspaceWrite, workspacePreferences: AgentWorkspacePreferences())
        profile.behavior?.memoryPolicy.crossChatContextEnabled = false
        app.agentProfiles = [profile]
        let before = try XCTUnwrap(app.agentProfiles.first)
        app.onboarding.beginCompanionSetup()
        app.onboarding.selectExistingCompanion(profile.id)
        app.onboarding.setCompanionName("Must not replace the name")
        app.onboarding.selectCompanionAppearance(.init(character: .fox))
        app.finishCompanionSetup(startChat: false)
        XCTAssertEqual(app.agentProfiles, [before])
        XCTAssertEqual(app.agentTeamsModel.primaryCompanionID, profile.id)
        XCTAssertNil(app.agentTeamsModel.agentAppearances[profile.id])
        XCTAssertNil(app.onboarding.progress.run)
    }

    func testFailedNameValidationNeverCreatesOrLinksProfile() {
        let app = AppModel(startImmediately: false)
        app.onboarding.beginCompanionSetup()
        app.onboarding.setCompanionName("Bad\u{0000}name")
        app.finishCompanionSetup(startChat: false)
        XCTAssertTrue(app.agentProfiles.isEmpty)
        XCTAssertNil(app.agentTeamsModel.primaryCompanionID)
        XCTAssertNotNil(app.onboarding.error)
        XCTAssertNotEqual(app.onboarding.companion.status, .completed)
    }
}
