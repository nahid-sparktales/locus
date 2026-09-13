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

    private func makeModel(sessionID: String = "session-1", backend: BackendService? = nil) -> OrchestrationRunsModel {
        let model = OrchestrationRunsModel()
        let service = backend ?? stubbedBackendService()
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

    private static func taskJSON(id: String = "task-1", runID: String = "run-1", state: String = "working") -> [String: Any] {
        ["id": id, "run_id": runID, "server_id": "user:fixture", "tool_name": "scan",
         "job_id": "job-1", "tool_call_id": "call-1", "state": state, "status_message": "Scanning"]
    }

    func testMCPTaskListReadsOnlyPersistedRecordsForRequestedRun() async {
        BackendStub.respond(toPath: "/api/mcp/tasks") { _ in
            ["tasks": [Self.taskJSON(), Self.taskJSON(id: "other", runID: "another-run")]]
        }
        let model = makeModel()
        await model.refreshMCPTasks(runID: "run-1")
        XCTAssertEqual(model.mcpTasksByRunID["run-1"]?.map(\.id), ["task-1"])
        XCTAssertEqual(BackendStub.requests.count, 1)
        XCTAssertEqual(BackendStub.requests.first?.httpMethod, "GET")
        XCTAssertTrue(BackendStub.requests.first?.url?.query?.contains("run_id=run-1") ?? false)
        XCTAssertTrue(model.loadingMCPTaskRuns.isEmpty)
    }

    func testMCPTaskEventsPreserveOriginWithoutNetworkTraffic() {
        let model = makeModel()
        model.ingestMCPTaskEvent(["task_id": "task-1", "run_id": "run-1", "server_id": "server",
                                 "tool": "scan", "job_id": "job-1", "tool_call_id": "call-1", "state": "working"])
        model.ingestMCPTaskEvent(["task_id": "task-1", "run_id": "run-1", "state": "completed", "message": "Done"])
        model.ingestMCPTaskEvent(["task_id": "unknown", "state": "working"])
        let task = model.mcpTasksByRunID["run-1"]?.first
        XCTAssertEqual(task?.state, "completed")
        XCTAssertEqual(task?.jobID, "job-1")
        XCTAssertEqual(task?.toolCallID, "call-1")
        XCTAssertEqual(task?.statusMessage, "Done")
        XCTAssertNoBackendTraffic()
    }

    func testExplicitMCPTaskLookupLoadsResultAndUpdatesState() async throws {
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/lookup") { _ in
            ["ok": true, "task": Self.taskJSON(state: "completed"), "result": "Scan finished"]
        }
        let model = makeModel()
        let task = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        await model.lookupMCPTask(task)
        XCTAssertEqual(model.mcpTaskResultsByID["task-1"]?.result, "Scan finished")
        XCTAssertEqual(model.mcpTasksByRunID["run-1"]?.first?.state, "completed")
        XCTAssertEqual(BackendStub.requests.first?.httpMethod, "POST")
        XCTAssertEqual(BackendStub.requests.first?.timeoutInterval, 75)
        XCTAssertTrue(model.activeMCPTaskActions.isEmpty)
    }

    func testMCPTaskCancellationSkipsTerminalTasks() async throws {
        let model = makeModel()
        let terminal = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON(state: "completed")))
        await model.cancelMCPTask(terminal)
        XCTAssertNoBackendTraffic()
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/cancel") { _ in
            ["ok": true, "task": Self.taskJSON(state: "cancelled")]
        }
        let working = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        await model.cancelMCPTask(working)
        XCTAssertEqual(model.mcpTasksByRunID["run-1"]?.first?.state, "cancelled")
        XCTAssertEqual(BackendStub.requests.first?.timeoutInterval, 25)
    }

    func testMCPTaskLookupCannotOverwriteNewerLiveState() async throws {
        let started = expectation(description: "lookup started")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/lookup") { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ["task": Self.taskJSON(state: "working")]
        }
        let model = makeModel()
        let task = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        let pending = Task { await model.lookupMCPTask(task) }
        await fulfillment(of: [started], timeout: 2)
        model.ingestMCPTaskEvent(["task_id": "task-1", "run_id": "run-1", "server_id": "user:fixture",
                                 "tool": "scan", "state": "completed"])
        release.signal()
        await pending.value
        XCTAssertEqual(model.mcpTasksByRunID["run-1"]?.first?.state, "completed")
        XCTAssertNil(model.mcpTaskResultsByID["task-1"])
    }

    func testMCPTaskLookupDiscardsResponseAfterTransportChanges() async throws {
        let started = expectation(description: "lookup started")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/lookup") { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ["task": Self.taskJSON(state: "completed"), "result": "old worker result"]
        }
        let backend = stubbedBackendService()
        let model = makeModel(backend: backend)
        let task = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        let pending = Task { await model.lookupMCPTask(task) }
        await fulfillment(of: [started], timeout: 2)
        backend.updateBaseURL(URL(string: "http://127.0.0.1:10")!)
        release.signal()
        await pending.value
        XCTAssertNil(model.mcpTaskResultsByID["task-1"])
        XCTAssertTrue(model.activeMCPTaskActions.isEmpty)
    }

    func testMCPTaskLookupKeepsResultWhenItsStatusEventArrivesFirst() async throws {
        let started = expectation(description: "lookup started")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/lookup") { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ["task": Self.taskJSON(state: "completed"), "result": "Scan result"]
        }
        let model = makeModel()
        let task = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        let pending = Task { await model.lookupMCPTask(task) }
        await fulfillment(of: [started], timeout: 2)
        model.ingestMCPTaskEvent(["task_id": "task-1", "run_id": "run-1", "server_id": "user:fixture",
                                 "tool": "scan", "state": "completed", "message": "Fresh status"])
        release.signal()
        await pending.value
        XCTAssertEqual(model.mcpTaskResultsByID["task-1"]?.result, "Scan result")
        XCTAssertEqual(model.mcpTasksByRunID["run-1"]?.first?.statusMessage, "Fresh status")
    }

    func testCancellingModelInvalidatesPendingMCPTaskActions() async throws {
        let started = expectation(description: "lookup started")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/lookup") { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ["task": Self.taskJSON(state: "completed"), "result": "old session result"]
        }
        let model = makeModel()
        let task = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        let pending = Task { await model.lookupMCPTask(task) }
        await fulfillment(of: [started], timeout: 2)
        model.cancelAll()
        release.signal()
        await pending.value
        XCTAssertNil(model.mcpTaskResultsByID["task-1"])
        XCTAssertTrue(model.activeMCPTaskActions.isEmpty)
    }

    func testMCPTaskLookupFailureIsVisibleInline() async throws {
        BackendStub.respond(toPath: "/api/mcp/tasks/task-1/lookup", status: 409) { _ in
            ["detail": "The extension is unavailable"]
        }
        let model = makeModel()
        let task = try XCTUnwrap(decode(MCPTaskRecord.self, from: Self.taskJSON()))
        await model.lookupMCPTask(task)
        XCTAssertNotNil(model.mcpTaskErrorsByID["task-1"])
        XCTAssertTrue(model.activeMCPTaskActions.isEmpty)
    }

    func testMCPFormOmitsUnsetValuesAndKeepsInvalidNumbersInvalid() {
        let fields = MCPFormField.fields([
            "properties": .object([
                "count": .object(["type": .string("integer"), "minimum": .number(1)]),
                "optional": .object(["type": .string("string")]),
                "enabled": .object(["type": .string("boolean")]),
            ]), "required": .array([.string("count")]),
        ])
        var draft = MCPFormDraft(fields: fields)
        draft.text["count"] = "nonsense"
        var validation = draft.validate(fields)
        XCTAssertNotNil(validation.errors["count"])
        XCTAssertNil(validation.content["count"])
        XCTAssertNil(validation.content["optional"])
        XCTAssertNil(validation.content["enabled"])
        draft.text["count"] = "0"
        XCTAssertNotNil(draft.validate(fields).errors["count"])
        draft.text["count"] = "2"
        validation = draft.validate(fields)
        XCTAssertTrue(validation.errors.isEmpty)
        XCTAssertEqual(validation.content["count"] as? Int, 2)
    }

    func testMCPFormAppliesEnumDefaultsAndValidatesMultiselect() {
        let fields = MCPFormField.fields([
            "properties": .object([
                "choice": .object(["type": .string("string"), "default": .string("a"), "oneOf": .array([
                    .object(["const": .string("a"), "title": .string("Alpha")]),
                    .object(["const": .string("b"), "title": .string("Beta")]),
                ])]),
                "tags": .object(["type": .string("array"), "minItems": .number(1),
                                  "items": .object(["type": .string("string"), "enum": .array([.string("x"), .string("y")])])]),
            ]), "required": .array([.string("tags")]),
        ])
        var draft = MCPFormDraft(fields: fields)
        XCTAssertEqual(draft.validate(fields).content["choice"] as? String, "a")
        XCTAssertNotNil(draft.validate(fields).errors["tags"])
        draft.arrays["tags"] = [.string("y")]
        XCTAssertTrue(draft.validate(fields).errors.isEmpty)
        XCTAssertEqual(draft.validate(fields).content["tags"] as? [String], ["y"])
        draft.arrays["tags"] = [.string("unknown")]
        XCTAssertNotNil(draft.validate(fields).errors["tags"])
    }

    func testMCPFormRejectsNonfiniteNumbersAndMalformedDates() {
        let fields = MCPFormField.fields(["properties": .object([
            "number": .object(["type": .string("number")]),
            "date": .object(["type": .string("string"), "format": .string("date")]),
        ])])
        var draft = MCPFormDraft(fields: fields)
        draft.text = ["number": "nan", "date": "2026-02-30"]
        XCTAssertNotNil(draft.validate(fields).errors["number"])
        XCTAssertNotNil(draft.validate(fields).errors["date"])
        draft.text = ["number": "1.5", "date": "2026-02-28"]
        XCTAssertTrue(draft.validate(fields).errors.isEmpty)
    }

    func testMCPFormClearingOptionalMultiselectOmitsValue() {
        let fields = MCPFormField.fields(["properties": .object([
            "tags": .object(["type": .string("array"), "minItems": .number(1),
                              "items": .object(["enum": .array([.string("a")])])]),
        ])])
        var draft = MCPFormDraft(fields: fields)
        draft.arrays["tags"] = [.string("a")]
        XCTAssertEqual(draft.validate(fields).content["tags"] as? [String], ["a"])
        draft.arrays["tags"] = []
        XCTAssertTrue(draft.validate(fields).errors.isEmpty)
        XCTAssertNil(draft.validate(fields).content["tags"])
    }

}
