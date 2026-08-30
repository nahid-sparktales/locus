import Combine
import XCTest

@testable import Locus

@MainActor
final class OrchestrationRunsModelTests: XCTestCase {
    private var toasts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
    }

    private func makeModel(sessionID: String = "session-1") -> OrchestrationRunsModel {
        let model = OrchestrationRunsModel()
        let service = stubbedBackendService()
        model.configure(
            backend: service,
            sessionIDProvider: { sessionID },
            transportProvider: { _ in service },
            liveRunID: { nil },
            liveState: { nil },
            setLiveState: { _ in },
            toastHandler: { [weak self] in self?.toasts.append($0) }
        )
        return model
    }

    private static func eventJSON(id: String, seq: Int, runID: String = "run-1") -> [String: Any] {
        ["event_id": id, "run_id": runID, "seq": seq, "type": "agent_job_completed", "state": "completed"]
    }

    private static func runJSON(id: String, sessionID: String = "session-1") -> [String: Any] {
        [
            "id": id, "session_id": sessionID, "team_id": "team-1", "team_name": "Team",
            "worker_id": "w", "workspace_root": "/tmp", "execution_path": "/tmp",
            "state": "completed", "request": "req", "created_at": 1.0, "updated_at": 2.0,
            "last_seq": 1, "pinned": false, "legacy": false, "recoverable": false,
        ]
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testMergeDedupesByIDAndSortsBySequence() {
        let a = decode(OrchestrationEvent.self, from: Self.eventJSON(id: "e1", seq: 2))!
        let b = decode(OrchestrationEvent.self, from: Self.eventJSON(id: "e2", seq: 1))!
        let aDup = decode(OrchestrationEvent.self, from: Self.eventJSON(id: "e1", seq: 2))!
        let merged = OrchestrationRunsModel.mergeOrchestrationEvents([a], with: [b, aDup])
        XCTAssertEqual(merged.map(\.id), ["e2", "e1"])
    }

    func testRunScopedEventsKeepsUnstampedAndMatchingEvents() {
        let mine = decode(OrchestrationEvent.self, from: Self.eventJSON(id: "e1", seq: 1, runID: "run-1"))!
        let other = decode(OrchestrationEvent.self, from: Self.eventJSON(id: "e2", seq: 2, runID: "run-2"))!
        let scoped = OrchestrationRunsModel.runScopedEvents([mine, other], runID: "run-1")
        XCTAssertEqual(scoped.map(\.id), ["e1"])
    }

    func testRefreshLoadsRunsAndSelectsTheFirst() async throws {
        BackendStub.respond(toPath: "/api/orchestrations") { _ in
            ["runs": [Self.runJSON(id: "run-1")], "read_only": false]
        }
        BackendStub.respond(toPath: "/api/orchestrations/run-1") { _ in
            Self.runJSON(id: "run-1")
        }
        BackendStub.respond(toPath: "/api/orchestrations/run-1/events") { _ in
            ["run_id": "run-1", "events": [Self.eventJSON(id: "e1", seq: 1)], "last_seq": 1]
        }
        let model = makeModel()
        await model.refreshOrchestrationRuns()
        XCTAssertEqual(model.orchestrationRuns.map(\.id), ["run-1"])
        XCTAssertEqual(model.selectedOrchestrationRun?.id, "run-1")
        XCTAssertEqual(model.orchestrationEvents.map(\.id), ["e1"])
        XCTAssertEqual(model.runDetailsByID["run-1"]?.id, "run-1")
        XCTAssertEqual(toasts, [])
    }

    func testAppModelRepublishesRunChanges() async throws {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.runs.objectWillChange.send()
        await fulfillment(of: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
