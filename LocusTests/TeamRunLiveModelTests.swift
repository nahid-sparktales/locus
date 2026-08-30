import Combine
import XCTest

@testable import Locus

@MainActor
final class TeamRunLiveModelTests: XCTestCase {
    private var liveState: TeamRunState?
    private var busy = false

    private func makeModel() -> TeamRunLiveModel {
        let model = TeamRunLiveModel()
        model.configure(
            isBusyProvider: { [weak self] in self?.busy ?? false },
            liveRunID: { "run-1" },
            liveState: { [weak self] in self?.liveState },
            selectedRunTeamID: { nil },
            teamLookup: { _ in nil },
            selectedTeamProvider: { nil }
        )
        return model
    }

    func testDispatcherLifecycleUpdatesTheActivityCard() {
        let model = makeModel()
        model.apply("dispatcher_started", ["run_id": "run-1", "model": "llama3"])
        XCTAssertEqual(model.dispatcherActivity?.id, "dispatcher-run-1")
        XCTAssertEqual(model.dispatcherActivity?.state, .running)

        model.apply("dispatcher_plan_rejected", ["reason": "missing writer"])
        XCTAssertEqual(model.dispatcherValidationReason, "missing writer")

        model.apply("dispatcher_completed", [
            "state": "completed",
            "message": "Plan ready",
            "usage": ["model_calls": 3, "metered_tokens": 1200],
        ])
        XCTAssertEqual(model.dispatcherActivity?.state, .completed)
        XCTAssertEqual(model.teamModelCalls, 3)
        XCTAssertEqual(model.teamMeteredTokens, 1200)
    }

    func testAgentSpawnDeduplicatesByNode() {
        let model = makeModel()
        model.apply("agent_spawned", ["node_id": "n1", "agent_name": "Scout"])
        model.apply("agent_spawned", ["node_id": "n1", "agent_name": "Scout"])
        XCTAssertEqual(model.agentActivities.count, 1)
    }

    func testJobCompletionCarriesIdentityFromTheStartedRow() {
        let model = makeModel()
        model.apply("agent_job_started", [
            "job_id": "job-1", "agent_name": "Coder", "provider": "ollama",
            "model": "qwen3", "goal": "Implement it",
        ])
        model.apply("agent_job_completed", [
            "result": ["job_id": "job-1", "agent_name": "Coder", "output": "done"],
            "state": "completed",
            "usage": ["model_calls": 7, "delegated_tokens": 900],
        ])
        XCTAssertEqual(model.agentActivities.count, 1)
        XCTAssertEqual(model.agentActivities[0].state, .completed)
        XCTAssertEqual(model.agentActivities[0].model, "qwen3")
        XCTAssertEqual(model.agentActivities[0].goal, "Implement it")
        XCTAssertEqual(model.teamMeteredTokens, 900)
    }

    func testNewRunResetsPresentation() {
        let model = makeModel()
        model.apply("agent_spawned", ["node_id": "n1"])
        model.apply("swarm_telemetry", ["usage": ["model_calls": 2, "delegated_tokens": 10]])
        model.apply("orchestration_started", [:])
        XCTAssertEqual(model.agentActivities, [])
        XCTAssertEqual(model.teamModelCalls, 0)
        XCTAssertEqual(model.teamMeteredTokens, 0)
        XCTAssertNil(model.dispatcherActivity)
        XCTAssertNil(model.pendingDispatchPlan)
    }

    func testDispatchApprovalRequiresStateAndPlan() {
        let model = makeModel()
        XCTAssertFalse(model.shouldShowTeamDispatchApproval)
        liveState = .waitingDispatchApproval
        XCTAssertFalse(model.shouldShowTeamDispatchApproval, "state without a plan must not prompt")
        model.pendingDispatchPlan = DispatchPlan(summary: "plan", jobs: [])
        XCTAssertTrue(model.shouldShowTeamDispatchApproval)
    }

    func testAppModelRepublishesLiveRunChanges() async throws {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.teamRunLive.objectWillChange.send()
        await fulfillment(of: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
