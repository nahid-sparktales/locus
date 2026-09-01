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
        nextRunAt: Double? = 1
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

    func testProcessDueSchedulesIsInertWithoutPersistence() async {
        let model = makeModel(persistenceEnabled: false)
        await model.processDueSchedules()
        XCTAssertNoBackendTraffic()
    }

}
