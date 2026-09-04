import Combine
import XCTest

@testable import Locus

@MainActor
final class ActivityCenterModelTests: XCTestCase {
    private var toasts: [String] = []
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
        suiteName = "activity-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func run(
        id: String,
        state: String = "completed",
        updatedAt: Double = 10
    ) -> OrchestrationRun {
        decode(OrchestrationRun.self, from: [
            "id": id,
            "session_id": "session-1",
            "team_id": "team-1",
            "team_name": "Team",
            "worker_id": "worker-1",
            "workspace_root": "/tmp",
            "execution_path": "/tmp",
            "state": state,
            "request": "req",
            "created_at": 1.0,
            "updated_at": updatedAt,
            "last_seq": 1,
            "pinned": false,
            "legacy": false,
            "recoverable": false,
        ])!
    }

    private func makeModel(persistenceEnabled: Bool = true) -> ActivityCenterModel {
        let model = ActivityCenterModel()
        model.restore(persistenceEnabled: persistenceEnabled, defaults: defaults)
        model.configure(
            backend: stubbedBackendService(),
            toastHandler: { [weak self] in self?.toasts.append($0) }
        )
        return model
    }

    func testConstructionRestoreAndConfigureAreInert() {
        _ = makeModel(persistenceEnabled: false)
        XCTAssertNoBackendTraffic()
        XCTAssertNil(defaults.object(forKey: "Locus.activitySeenUpdates"))
    }

    func testSeenBookkeepingPersistsAndFiltersUnseenRuns() throws {
        let model = makeModel()
        model.activityRuns = [run(id: "run-1", updatedAt: 10), run(id: "run-2", updatedAt: 20)]
        XCTAssertTrue(model.activityIsUnseen(model.activityRuns[0]))

        model.markAllActivitySeen()
        XCTAssertFalse(model.activityIsUnseen(model.activityRuns[0]))
        XCTAssertFalse(model.activityIsUnseen(model.activityRuns[1]))
        XCTAssertNotNil(defaults.data(forKey: "Locus.activitySeenUpdates"))

        // A later update makes the run unseen again.
        model.activityRuns[1] = run(id: "run-2", updatedAt: 30)
        XCTAssertTrue(model.activityIsUnseen(model.activityRuns[1]))
    }

    func testRestoreReadsTheKeysThisModelNowOwns() throws {
        let seen = try JSONEncoder().encode(["run-9": 42.0])
        defaults.set(seen, forKey: "Locus.activitySeenUpdates")
        defaults.set(["run-8"], forKey: "Locus.dismissedActivityRunIDs")
        defaults.set(["run-7"], forKey: "Locus.acknowledgedWarningRunIDs")

        let model = makeModel()
        XCTAssertEqual(model.activitySeenUpdates, ["run-9": 42.0])
        XCTAssertEqual(model.dismissedActivityRunIDs, ["run-8"])
        XCTAssertTrue(model.warningIsAcknowledged("run-7"))
    }

    func testWarningAcknowledgementPersistsWithoutRemovingRunHistory() {
        let model = makeModel()
        let interrupted = run(id: "run-warning", state: "interrupted")
        model.activityRuns = [interrupted]

        model.acknowledgeRunWarning(interrupted.id)

        XCTAssertTrue(model.warningIsAcknowledged(interrupted.id))
        XCTAssertEqual(model.visibleActivityRuns.map(\.id), [interrupted.id])
        XCTAssertEqual(
            defaults.stringArray(forKey: "Locus.acknowledgedWarningRunIDs"),
            [interrupted.id]
        )
    }

    func testDismissOnlyAcceptsTerminalRunsAndHidesThem() {
        let model = makeModel()
        let live = run(id: "run-live", state: "running")
        let done = run(id: "run-done", state: "failed")
        model.activityRuns = [live, done]
        XCTAssertEqual(model.activityNeedsAttentionCount, 1)

        model.dismissActivityRun(live)
        XCTAssertEqual(model.visibleActivityRuns.count, 2)

        model.dismissActivityRun(done)
        XCTAssertEqual(model.visibleActivityRuns.map(\.id), ["run-live"])
        XCTAssertEqual(model.activityNeedsAttentionCount, 0)
        XCTAssertEqual(defaults.stringArray(forKey: "Locus.dismissedActivityRunIDs"), ["run-done"])
    }

}
