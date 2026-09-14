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

    private func makeModel(
        persistenceEnabled: Bool = true,
        liveAttention: @escaping () -> [AttentionItem] = { [] }
    ) -> ActivityCenterModel {
        let model = ActivityCenterModel()
        model.restore(persistenceEnabled: persistenceEnabled, defaults: defaults)
        model.configure(
            backend: stubbedBackendService(),
            liveAttentionProvider: liveAttention,
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
        let attention = AttentionItem(
            id: "run:run-done", kind: "recoverable_run", group: .recoveries,
            runID: "run-done", title: "Needs recovery", detail: "Failed",
            actions: ["retry"]
        )
        let model = makeModel(liveAttention: { [attention] })
        let live = run(id: "run-live", state: "running")
        let done = run(id: "run-done", state: "failed")
        model.activityRuns = [live, done]
        XCTAssertEqual(model.activityNeedsAttentionCount, 1)

        model.dismissActivityRun(live)
        XCTAssertEqual(model.visibleActivityRuns.count, 2)

        model.dismissActivityRun(done)
        XCTAssertEqual(model.visibleActivityRuns.map(\.id), ["run-live"])
        // Hiding an Activity history row never resolves its authoritative
        // Attention item or lowers the badge.
        XCTAssertEqual(model.activityNeedsAttentionCount, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "Locus.dismissedActivityRunIDs"), ["run-done"])
    }

    func testAttentionBadgeDeduplicatesRelatedRowsByRunAndPrefersDetail() {
        let detailed = AttentionItem(
            id: "permission:1", kind: "permission_request", group: .decisions,
            runID: "same-run", title: "Permission requested", detail: "shell: /tmp",
            actions: ["allow_once", "deny"]
        )
        let generic = AttentionItem(
            id: "run:same-run", kind: "recoverable_run", group: .recoveries,
            runID: "same-run", title: "Needs recovery", detail: "Waiting",
            actions: ["retry"]
        )
        let model = makeModel(liveAttention: { [detailed, generic] })

        XCTAssertEqual(model.activityNeedsAttentionCount, 1)
        XCTAssertEqual(model.attentionItems.first?.kind, "permission_request")
    }

    func testUnavailableRecoveryClearActionSurvivesAttentionDeduplication() {
        let unavailable = AttentionItem(
            id: "run:missing-chat", kind: "recoverable_run", group: .recoveries,
            runID: "missing-chat", title: "Work needs recovery",
            detail: "The original chat was deleted. Clear this recovery item.",
            actions: ["clear"], unavailable: true
        )
        let model = makeModel(liveAttention: { [unavailable] })

        XCTAssertEqual(model.activityNeedsAttentionCount, 1)
        XCTAssertEqual(model.attentionItems.first?.actions, ["clear"])
        XCTAssertEqual(model.attentionItems.first?.unavailable, true)
    }

    func testPersistedWorkflowAttentionReplacesSyntheticRecoveryAndKeepsTypedFocus() async throws {
        let workflowItems = [
            AttentionItem(id: "workflow-failure:failed", kind: "workflow_failure", group: .recoveries,
                sessionID: "session-1", runID: "failed-run", workflowExecutionID: "failed-workflow",
                title: "Workflow step failed", detail: "Model was unavailable", actions: ["retry", "cancel"]),
            AttentionItem(id: "workflow-approval:waiting", kind: "workflow_approval", group: .decisions,
                sessionID: "session-1", runID: "waiting-run", workflowExecutionID: "waiting-workflow",
                title: "Approval needed", detail: "Review this step", actions: ["approve", "reject"]),
        ]
        let generic = workflowItems.map {
            AttentionItem(id: "run:\($0.runID!)", kind: "recoverable_run", group: .recoveries,
                sessionID: "session-1", runID: $0.runID, title: "Work needs recovery", detail: "Stopped",
                actions: ["retry", "open_chat", "clear"])
        }
        BackendStub.respond(toPath: "/api/runs") { _ in ["runs": [], "read_only": false] }
        let response = try JSONEncoder().encode(AttentionResponse(items: workflowItems,
            unresolvedCount: workflowItems.count, readOnly: false))
        BackendStub.respond(toPath: "/api/attention") { _ in response }
        for item in workflowItems {
            let detail = try JSONEncoder().encode(run(id: item.runID!, state: "failed"))
            BackendStub.respond(toPath: "/api/runs/\(item.runID!)") { _ in detail }
        }
        let model = makeModel(liveAttention: { generic })

        await model.refreshActivityRuns()

        XCTAssertEqual(model.activityNeedsAttentionCount, 2, "Each run has one actionable item")
        XCTAssertEqual(Set(model.attentionItems.map(\.id)), Set(workflowItems.map(\.id)))
        for item in workflowItems {
            await openAndFinishRefresh(model, focus: .workflow(item.workflowExecutionID!))
            XCTAssertEqual(model.displayedAttentionItems, [item], "Workflow identity and actions must survive merging")
            await openAndFinishRefresh(model, focus: .run(item.runID!))
            XCTAssertEqual(model.displayedAttentionItems, [item], "Run focus must retain workflow recovery actions")
        }
        model.clearFocus()
    }

    private func openAndFinishRefresh(_ model: ActivityCenterModel, focus: ActivityCenterModel.Focus) async {
        model.openActivityCenter(focus: focus)
        let finished = expectation(description: "Opening refresh finished")
        // Opening sets the tab synchronously, then publishes its final tab only
        // after both the inbox and focused detail requests have completed.
        let observer = model.$selectedTab.dropFirst().first().sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        observer.cancel()
        XCTAssertFalse(model.isRefreshingFocus)
        XCTAssertNil(model.focusError)
    }

    func testLiveQuestionsKeepTheirRequestsWhenPersistedAttentionSharesTheRun() async throws {
        let questions = ["structured_question", "completed_question"].map { kind in
            AttentionItem(id: "live:\(kind)", kind: kind, group: .decisions,
                sessionID: "session-1", runID: kind, title: "Live question", detail: "Current prompt",
                actions: ["answer", "open_chat"], request: ["id": .string("live-request")])
        }
        let persisted = questions.map {
            AttentionItem(id: "persisted:\($0.kind)", kind: $0.kind, group: .decisions,
                sessionID: "session-1", runID: $0.runID, title: "Saved question", detail: "Older prompt",
                actions: ["answer"], request: ["id": .string("old-request")])
        }
        BackendStub.respond(toPath: "/api/runs") { _ in ["runs": [], "read_only": false] }
        let response = try JSONEncoder().encode(AttentionResponse(items: persisted,
            unresolvedCount: persisted.count, readOnly: false))
        BackendStub.respond(toPath: "/api/attention") { _ in response }
        let model = makeModel(liveAttention: { questions })

        await model.refreshActivityRuns()

        XCTAssertEqual(model.activityNeedsAttentionCount, 2)
        XCTAssertEqual(Set(model.attentionItems), Set(questions), "Live answer requests remain current")
    }

}
