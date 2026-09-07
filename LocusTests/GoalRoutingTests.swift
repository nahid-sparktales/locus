import XCTest
@testable import Locus

@MainActor
final class GoalRoutingTests: XCTestCase {
    private func app() -> AppModel {
        let model = AppModel(startImmediately: false)
        model.sessionInfo = SessionInfo(
            model: "local-test", host: "localhost", cwd: "/tmp", session: "goal-chat", sessionID: "goal-chat",
            messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            contextLimit: 0, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )
        model.installTranscriptSession("goal-chat", blocks: [])
        model.agentRuntimePhase = .online
        model.backendCapabilities["persistent_goals_v1"] = true
        return model
    }

    func testGoalSetupPreservesUnsentDraftAndUsesCurrentChat() {
        let model = app()
        model.draftText = "Finish the retry behavior"
        XCTAssertTrue(model.canStartGoal)
        model.presentGoalEditor()
        XCTAssertTrue(model.goals.isPresented)
        XCTAssertEqual(model.goals.draftObjective, "Finish the retry behavior")
        XCTAssertEqual(model.currentSessionID, "goal-chat")
        model.goals.draftObjective = "Revised goal"
        XCTAssertEqual(model.draftText, "Finish the retry behavior")
    }

    func testForegroundGoalWaitsForQueuedInputAndTranscriptRestoration() {
        let model = app()
        let goal = PersistentGoal(id: "g", sessionID: "goal-chat", objective: "Finish")
        XCTAssertTrue(model.canContinueGoal(goal))
        model.queuedMessages = ["Use a different approach"]
        XCTAssertFalse(model.canContinueGoal(goal))
        model.queuedMessages = []
        _ = model.beginTranscriptSessionLoad("goal-chat")
        XCTAssertFalse(model.canContinueGoal(goal))
    }

    func testBackgroundGoalDoesNotReadForegroundDraftOrMode() {
        let model = app()
        model.draftText = "Unsent text in another chat"
        model.queuedMessages = ["Foreground follow-up"]
        model.selectedMode = .plan
        model.isBusy = true
        let goal = PersistentGoal(id: "g", sessionID: "background", objective: "Finish")
        XCTAssertTrue(model.canContinueGoal(goal))
        XCTAssertEqual(model.draftText, "Unsent text in another chat")
    }

    func testPausedGoalAndUnavailableBackendNeverAdmitContinuation() {
        let model = app()
        var goal = PersistentGoal(id: "g", sessionID: "goal-chat", objective: "Finish", status: .paused)
        XCTAssertFalse(model.canContinueGoal(goal))
        goal.status = .active
        model.agentRuntimePhase = .unavailable("Disconnected")
        XCTAssertFalse(model.canContinueGoal(goal))
        XCTAssertFalse(model.canContinueGoal(PersistentGoal(id: "other", sessionID: "background", objective: "Finish")))
    }

    func testCapabilityAndScheduledChatPreventGoalSetup() {
        let model = app()
        model.backendCapabilities = [:]
        XCTAssertFalse(model.canStartGoal)
        model.backendCapabilities["persistent_goals_v1"] = true
        model.sessions = [SessionSummary(id: "goal-chat", name: "goal-chat", preview: "", mtime: 0, size: 0,
                                         agentTriggerID: "schedule", agentKind: "schedule")]
        XCTAssertFalse(model.canStartGoal)
    }

    func testPausedGoalDoesNotDrainSubmittedInstructionsAsOrdinaryWork() throws {
        let model = app()
        let paused = PersistentGoal(id: "g", sessionID: "goal-chat", objective: "Finish", status: .paused)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(paused)) as? [String: Any])
        model.goals.handleEvent(["type": "goal_snapshot", "goal": record], sessionID: "goal-chat")
        model.queuedMessages = ["Keep the existing API"]
        model.draftText = "Unsubmitted context"
        model.drainQueuedMessages()
        XCTAssertEqual(model.queuedMessages, ["Keep the existing API"])
        XCTAssertEqual(model.draftText, "Unsubmitted context")
        XCTAssertFalse(model.isBusy)
    }

    func testRestoringATeamSelectionDoesNotActLikeAUserRouteEdit() {
        let teams = AgentTeamsModel()
        var edits = 0
        teams.configure(isBusyProvider: { false }, workspacePersistenceRequested: {},
                        localModelsProvider: { [] }, accountsProvider: { [] },
                        accountModelsProvider: { _ in nil }, toastHandler: { _ in },
                        executionRouteWillChange: { edits += 1 })
        let teamID = UUID()
        teams.selectedAgentTeamID = teamID
        XCTAssertEqual(edits, 0)
        teams.selectSoloRoute()
        XCTAssertEqual(edits, 1)
        teams.selectSoloRoute()
        XCTAssertEqual(edits, 1)
    }
}
