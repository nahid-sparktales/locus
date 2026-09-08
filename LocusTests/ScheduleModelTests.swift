import Combine
import XCTest

@testable import Locus

@MainActor
final class ScheduleModelTests: XCTestCase {
    private var toasts: [String] = []
    private var pausedNotices: [String] = []
    private var admittedRuns: [String] = []
    private var taskIssueAnswer: String?

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
        pausedNotices = []
        admittedRuns = []
        taskIssueAnswer = nil
    }

    private func makeModel(persistenceEnabled: Bool = true) -> ScheduleModel {
        let model = ScheduleModel()
        model.configure(
            backend: stubbedBackendService(),
            persistenceEnabled: persistenceEnabled,
            isShuttingDown: { false },
            draftIssue: { _ in nil },
            taskIssue: { [weak self] _ in self?.taskIssueAnswer },
            refreshMetadata: {},
            refreshActivity: {},
            restoreQueuedRuns: {},
            admitQueuedRun: { [weak self] run in self?.admittedRuns.append(run.id) },
            openRun: { _ in },
            notifyPaused: { [weak self] in self?.pausedNotices.append($0) },
            toastHandler: { [weak self] in self?.toasts.append($0) }
        )
        return model
    }

    private static func scheduleJSON(
        id: String,
        enabled: Bool = true,
        nextRunAt: Double? = 1,
        lastError: String? = nil
    ) -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "name": "Nightly",
            "prompt": "run the checks",
            "workspace_root": "/tmp",
            "mode": "work",
            "execution_environment": "local",
            "runner": "solo",
            "provider": "ollama",
            "model": "llama3",
            "timezone": "UTC",
            "rule": ["kind": "daily", "hour": 3, "minute": 0],
            "enabled": enabled,
            "created_at": 1.0,
            "updated_at": 1.0,
            "last_error": lastError ?? NSNull(),
        ]
        if let nextRunAt { json["next_run_at"] = nextRunAt }
        return json
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testDueScheduleDispatchesAndAdmitsQueuedRun() async throws {
        BackendStub.respond(toPath: "/api/schedules") { _ in
            ["schedules": [Self.scheduleJSON(id: "sched-1")], "read_only": false]
        }
        BackendStub.respond(whenPathHasPrefix: "/api/schedules/sched-1/dispatch") { _ in
            [
                "ok": true,
                "claimed": true,
                "occurrence": [
                    "id": "occ-1", "schedule_id": "sched-1", "schedule_name": "Nightly",
                    "scheduled_for": 100.0, "trigger": "due", "state": "claimed",
                    "created_at": 100.0, "updated_at": 100.0,
                ],
                "run": [
                    "id": "run-1", "session_id": "s", "team_id": "", "team_name": "",
                    "worker_id": "", "workspace_root": "/tmp", "execution_path": "/tmp",
                    "state": "queued", "request": "r", "created_at": 1.0, "updated_at": 1.0,
                    "last_seq": 0, "pinned": false, "legacy": false, "recoverable": false,
                ],
            ]
        }
        let model = makeModel()
        await model.processDueSchedules(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(admittedRuns, ["run-1"])
        XCTAssertEqual(pausedNotices, [])
    }

    func testMisconfiguredDueSchedulePausesInsteadOfDispatching() async throws {
        taskIssueAnswer = "The configured team no longer exists"
        BackendStub.respond(toPath: "/api/schedules") { _ in
            ["schedules": [Self.scheduleJSON(id: "sched-2")], "read_only": false]
        }
        BackendStub.respond(whenPathHasPrefix: "/api/schedules/sched-2/pause") { _ in
            Self.scheduleJSON(id: "sched-2", enabled: false)
        }
        let model = makeModel()
        await model.processDueSchedules(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(admittedRuns, [])
        XCTAssertEqual(pausedNotices, ["Nightly was paused: The configured team no longer exists"])
        XCTAssertTrue(
            BackendStub.requestPaths.contains("/api/schedules/sched-2/pause"),
            "a misconfigured due schedule must be durably paused"
        )
    }

    func testClearWarningIsSingleFlightAndLeavesTheAgentPaused() async {
        BackendStub.respond(toPath: "/api/schedules/sched-warning/acknowledge") { _ in
            Self.scheduleJSON(
                id: "sched-warning", enabled: false, lastError: nil
            )
        }
        let task = decode(ScheduledTask.self, from: Self.scheduleJSON(
            id: "sched-warning", enabled: false, lastError: "worker stopped"
        ))!
        let model = makeModel()
        model.seedForUITesting(tasks: [task])

        model.clearWarning(task)
        model.clearWarning(task)
        for _ in 0..<100 {
            if model.scheduledTasks.first?.lastError == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            BackendStub.requestPaths.filter {
                $0 == "/api/schedules/sched-warning/acknowledge"
            }.count,
            1
        )
        XCTAssertEqual(model.scheduledTasks.first?.enabled, false)
        XCTAssertNil(model.scheduledTasks.first?.lastError)
        XCTAssertTrue(model.clearingWarningIDs.isEmpty)
        XCTAssertEqual(toasts, ["Agent warning cleared; the agent remains paused"])
    }

    func testFailedScheduleLoadExposesErrorAndSuccessfulRetryClearsIt() async {
        BackendStub.respond(toPath: "/api/schedules", status: 503) { _ in ["detail": "temporarily unavailable"] }
        let model = makeModel()

        await model.refreshScheduledTasks(announceFailure: false)

        XCTAssertNotNil(model.lastLoadError)
        XCTAssertTrue(model.lastLoadError?.contains("Could not load scheduled Agents") == true)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.isRefreshingSchedules)
        XCTAssertTrue(model.scheduledTasks.isEmpty)
        XCTAssertTrue(toasts.isEmpty, "The inline error should not require a toast")

        BackendStub.reset()
        BackendStub.respond(toPath: "/api/schedules") { _ in
            ["schedules": [Self.scheduleJSON(id: "restored")], "read_only": false]
        }
        await model.refreshScheduledTasks(announceFailure: false)

        XCTAssertNil(model.lastLoadError)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isRefreshingSchedules)
        XCTAssertEqual(model.scheduledTasks.map(\.id), ["restored"])
    }

    func testFailedScheduleRefreshPreservesLastLoadedAgents() async {
        BackendStub.respond(toPath: "/api/schedules") { _ in
            ["schedules": [Self.scheduleJSON(id: "kept", enabled: false)], "read_only": false]
        }
        let model = makeModel()
        await model.refreshScheduledTasks()
        let previouslyLoaded = model.scheduledTasks

        BackendStub.reset()
        BackendStub.respond(toPath: "/api/schedules", status: 500) { _ in ["detail": "load failed"] }
        await model.refreshScheduledTasks()

        XCTAssertEqual(model.scheduledTasks, previouslyLoaded)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNotNil(model.lastLoadError)
        XCTAssertFalse(model.isRefreshingSchedules)
        XCTAssertEqual(toasts.count, 1)
    }

    func testOccurrenceFailurePreservesHistoryAndRetryClearsOnlyItsOwnError() async throws {
        let first = try XCTUnwrap(decode(ScheduledTask.self, from: Self.scheduleJSON(id: "first")))
        let second = try XCTUnwrap(decode(ScheduledTask.self, from: Self.scheduleJSON(id: "second")))
        BackendStub.respond(toPath: "/api/schedules/first/occurrences") { _ in
            ["occurrences": [Self.occurrenceJSON(id: "retained", scheduleID: "first")]]
        }
        let model = makeModel()
        await model.refreshOccurrences(for: first, announceFailure: false)
        let previousHistory = model.occurrencesBySchedule["first"]

        BackendStub.reset()
        BackendStub.respond(whenPathHasPrefix: "/api/schedules/", status: 503) { _ in ["detail": "history unavailable"] }
        await model.refreshOccurrences(for: first, announceFailure: false)
        await model.refreshOccurrences(for: second, announceFailure: false)

        XCTAssertEqual(model.occurrencesBySchedule["first"], previousHistory)
        XCTAssertNotNil(model.occurrenceLoadErrors["first"])
        XCTAssertNotNil(model.occurrenceLoadErrors["second"])
        XCTAssertTrue(model.loadingOccurrenceIDs.isEmpty)
        XCTAssertNil(model.lastLoadError, "An activity error must not replace the agent-list error")
        XCTAssertTrue(toasts.isEmpty)

        BackendStub.reset()
        BackendStub.respond(toPath: "/api/schedules/first/occurrences") { _ in
            ["occurrences": [Self.occurrenceJSON(id: "newest", scheduleID: "first")]]
        }
        await model.refreshOccurrences(for: first, announceFailure: false)

        XCTAssertNil(model.occurrenceLoadErrors["first"])
        XCTAssertNotNil(model.occurrenceLoadErrors["second"])
        XCTAssertEqual(model.occurrencesBySchedule["first"]?.map(\.id), ["newest"])
        XCTAssertTrue(model.loadingOccurrenceIDs.isEmpty)
        let request = try XCTUnwrap(BackendStub.requests.first)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "limit" }?.value, "100")
    }

    func testOverlappingOccurrenceLoadsShareTheExistingRequest() async throws {
        let task = try XCTUnwrap(decode(ScheduledTask.self, from: Self.scheduleJSON(id: "one")))
        let requested = expectation(description: "First occurrence request started")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/schedules/one/occurrences") { _ in
            requested.fulfill()
            // This is the URL loading thread, not the main actor. The test
            // explicitly releases the response after attempting an overlap.
            _ = release.wait(timeout: .now() + 3)
            return ["occurrences": [Self.occurrenceJSON(id: "once", scheduleID: "one")]]
        }
        defer { release.signal() }
        let model = makeModel()
        let firstLoad = Task { await model.refreshOccurrences(for: task, announceFailure: false) }
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(model.loadingOccurrenceIDs, ["one"])

        await model.refreshOccurrences(for: task, announceFailure: false)
        XCTAssertEqual(model.loadingOccurrenceIDs, ["one"], "An overlapping caller must not clear the active request")
        release.signal()
        await firstLoad.value

        XCTAssertEqual(BackendStub.requestPaths.filter { $0 == "/api/schedules/one/occurrences" }.count, 1)
        XCTAssertEqual(model.occurrencesBySchedule["one"]?.map(\.id), ["once"])
        XCTAssertTrue(model.loadingOccurrenceIDs.isEmpty)
        XCTAssertTrue(model.occurrenceLoadErrors.isEmpty)
    }

    func testCancelledScheduleLoadKeepsSavedAgentsWithoutPublishingAnError() async throws {
        let retained = try XCTUnwrap(decode(ScheduledTask.self, from: Self.scheduleJSON(id: "retained")))
        let requested = expectation(description: "Schedule response held")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/schedules") { _ in
            requested.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ["schedules": [Self.scheduleJSON(id: "cancelled-result")], "read_only": false]
        }
        defer { release.signal() }
        let model = makeModel()
        model.seedForUITesting(tasks: [retained])
        let load = Task { await model.refreshScheduledTasks() }
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertTrue(model.isRefreshingSchedules)

        load.cancel()
        release.signal()
        await load.value

        XCTAssertEqual(model.scheduledTasks, [retained])
        XCTAssertNil(model.lastLoadError)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isRefreshingSchedules)
        XCTAssertTrue(toasts.isEmpty)
    }

    func testCancelledOccurrenceLoadKeepsHistoryAndReleasesItsLoadingSlot() async throws {
        let task = try XCTUnwrap(decode(ScheduledTask.self, from: Self.scheduleJSON(id: "retained")))
        let previous = try XCTUnwrap(decode(ScheduleOccurrence.self,
            from: Self.occurrenceJSON(id: "existing", scheduleID: task.id)))
        let requested = expectation(description: "Occurrence response held")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/schedules/retained/occurrences", status: 503) { _ in
            requested.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ["detail": "A response from a screen we already left"]
        }
        defer { release.signal() }
        let model = makeModel()
        model.seedForUITesting(tasks: [task], occurrences: [task.id: [previous]])
        let load = Task { await model.refreshOccurrences(for: task) }
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(model.loadingOccurrenceIDs, [task.id])

        load.cancel()
        release.signal()
        await load.value

        XCTAssertEqual(model.occurrencesBySchedule[task.id], [previous])
        XCTAssertNil(model.occurrenceLoadErrors[task.id])
        XCTAssertTrue(model.loadingOccurrenceIDs.isEmpty)
        XCTAssertTrue(toasts.isEmpty)

        BackendStub.reset()
        BackendStub.respond(toPath: "/api/schedules/retained/occurrences") { _ in
            ["occurrences": [Self.occurrenceJSON(id: "retried", scheduleID: "retained")]]
        }
        await model.refreshOccurrences(for: task)
        XCTAssertEqual(model.occurrencesBySchedule[task.id]?.map(\.id), ["retried"])
        XCTAssertTrue(model.loadingOccurrenceIDs.isEmpty)
    }

    private static func occurrenceJSON(id: String, scheduleID: String) -> [String: Any] {
        [
            "id": id, "schedule_id": scheduleID, "schedule_name": "Nightly",
            "scheduled_for": 100.0, "trigger": "due", "state": "completed",
            "session_id": "chat", "run_id": "run-\(id)", "created_at": 100.0, "updated_at": 101.0,
        ]
    }

    func testProcessDueSchedulesIsInertWithoutPersistence() async {
        let model = makeModel(persistenceEnabled: false)
        await model.processDueSchedules()
        XCTAssertNoBackendTraffic()
    }

}
