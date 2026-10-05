import XCTest
@testable import Locus

@MainActor
final class CompanionInspectorNavigationTests: XCTestCase {
    func testOpeningCompanionInspectorPreservesForegroundWorkAndIdentity() throws {
        let model = AppModel(startImmediately: false)
        let companionID = try model.agentTeamsModel.commitCompanion(CompanionOnboardingDraft())
        let profile = try XCTUnwrap(model.agentProfiles.first { $0.id == companionID })
        let session = model.currentSessionID
        let workspace = model.workspacePath
        let selectedModel = model.selectedModel
        model.blocks = [ChatBlock(kind: .assistant, text: "Current work")]
        model.draftText = "An unsent work draft"
        model.isBusy = true
        model.sidebarDestination = .ask

        model.selectInspectorTab(.companion)
        model.selectInspectorTab(.companion)

        XCTAssertEqual(model.inspectorTab, .companion)
        XCTAssertEqual(model.openInspectorTabs.filter { $0 == .companion }.count, 1)
        XCTAssertFalse(model.inspectorCollapsed)
        XCTAssertEqual(model.sidebarDestination, .ask)
        XCTAssertEqual(model.currentSessionID, session)
        XCTAssertEqual(model.workspacePath, workspace)
        XCTAssertEqual(model.selectedModel, selectedModel)
        XCTAssertEqual(model.draftText, "An unsent work draft")
        XCTAssertEqual(model.blocks.map(\.text), ["Current work"])
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.agentTeamsModel.primaryCompanionID, companionID)
        XCTAssertEqual(model.agentProfiles.first { $0.id == companionID }, profile)
        XCTAssertTrue(model.creatingSavedAgentChatIDs.isEmpty)
    }

    func testCompanionInspectorRemainsOpenAcrossAgentAndWorkModes() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.files)
        model.sidebarDestination = .agents
        XCTAssertTrue(model.openInspectorTabs.contains(.agent))
        model.selectInspectorTab(.companion)

        model.sidebarDestination = .ask
        XCTAssertEqual(model.inspectorTab, .companion)
        XCTAssertEqual(model.openInspectorTabs, [.files, .companion])
        XCTAssertFalse(model.inspectorCollapsed)

        model.sidebarDestination = .agents
        XCTAssertEqual(model.inspectorTab, .companion)
        XCTAssertEqual(model.openInspectorTabs, [.files, .companion])
        XCTAssertFalse(model.inspectorCollapsed)
    }

    func testCompanionInspectorRestoresThroughExistingSettings() throws {
        var settings = AppSettings()
        settings.inspectorLastTab = InspectorTab.companion.rawValue
        settings.inspectorLastWorkspaceTab = InspectorTab.context.rawValue
        settings.inspectorOpenTabs = ["agent", "companion", "files", "companion", "future"]
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(restored.resolvedInspectorTab, .companion)
        XCTAssertEqual(restored.resolvedRestoredInspectorTab, .companion)
        XCTAssertEqual(restored.resolvedInspectorOpenTabs, [.companion, .files])
        XCTAssertEqual(restored.resolvedInspectorWorkspaceTab, .context)
        XCTAssertFalse(InspectorRail.menuTabs.contains(.companion), "Companion has a dedicated rail button")
    }

    func testGeneralInspectorCommandDoesNotRepurposeCompanionAsAWorkspacePanel() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.context)
        model.selectInspectorTab(.companion)

        model.toggleInspector()

        XCTAssertEqual(model.inspectorTab, .context)
        XCTAssertEqual(model.settings.resolvedInspectorWorkspaceTab, .context)
        XCTAssertTrue(model.openInspectorTabs.contains(.companion))
        XCTAssertFalse(model.inspectorCollapsed)
    }

    func testCompanionPanelCanCloseAndReopenWithoutCreatingAnAgent() {
        let model = AppModel(startImmediately: false)
        model.openInspectorTabs = []
        model.selectInspectorTab(.companion)
        model.closeInspectorTab(.companion)
        XCTAssertTrue(model.inspectorCollapsed)
        XCTAssertTrue(model.openInspectorTabs.isEmpty)

        model.toggleInspectorPanel()

        XCTAssertEqual(model.inspectorTab, .companion)
        XCTAssertEqual(model.openInspectorTabs, [.companion])
        XCTAssertFalse(model.inspectorCollapsed)
        XCTAssertNil(model.agentTeamsModel.primaryCompanionID)
        XCTAssertTrue(model.agentProfiles.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testJustChatKeepsItsExistingNoInspectorContract() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.context)
        model.setJustChatEnabled(true)

        model.selectInspectorTab(.companion)
        model.toggleInspectorTab(.companion)

        XCTAssertTrue(model.inspectorCollapsed)
        XCTAssertEqual(model.inspectorTab, .context)
        XCTAssertFalse(model.openInspectorTabs.contains(.companion))
    }
}
