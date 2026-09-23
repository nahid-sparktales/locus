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
        updatedAt: Double = 10,
        runKind: String = "solo"
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
            "run_kind": runKind,
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

    func testOpeningSwitchingTabsAndRefreshingNeverReadsResults() async throws {
        let finished = run(id: "finished")
        let data = try JSONEncoder().encode(OrchestrationRunsResponse(runs: [finished], readOnly: false))
        BackendStub.respond(toPath: "/api/runs") { _ in data }
        BackendStub.respond(toPath: "/api/attention") { _ in ["items": [], "unresolved_count": 0, "read_only": false] }
        let model = makeModel()
        model.activityRuns = [finished]
        model.openActivityCenter()
        let refreshed = expectation(description: "Opening refresh finished")
        let observer = model.$selectedTab.dropFirst().first().sink { _ in refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 3)
        observer.cancel()
        for tab in ActivityCenterModel.Tab.allCases { model.selectTab(tab) }
        await model.refreshActivityRuns()
        XCTAssertTrue(model.activityIsUnseen(finished))
        XCTAssertEqual(model.inboxRuns.map(\.id), [finished.id])
        XCTAssertTrue(model.readRuns.isEmpty)
    }

    func testReadUnreadAndLaterUpdatesMoveResultsBetweenListsAndPersist() {
        let model = makeModel()
        let finished = run(id: "finished")
        model.activityRuns = [finished, run(id: "active", state: "running"), run(id: "queued", state: "queued")]
        XCTAssertEqual(model.inProgressRuns.map(\.id), ["active", "queued"])
        XCTAssertEqual(model.unreadResultCount, 1)
        model.markActivitySeen(finished)
        XCTAssertTrue(model.inboxRuns.isEmpty)
        XCTAssertEqual(model.readRuns.map(\.id), ["finished"])
        XCTAssertEqual(model.unreadResultCount, 0)

        let restored = makeModel()
        restored.activityRuns = model.activityRuns
        XCTAssertEqual(restored.readRuns.map(\.id), ["finished"])
        restored.markActivityUnread(finished)
        XCTAssertEqual(restored.inboxRuns.map(\.id), ["finished"])
        XCTAssertTrue(restored.readRuns.isEmpty)
        restored.markActivitySeen(finished)
        restored.activityRuns[0] = run(id: "finished", updatedAt: 20)
        XCTAssertEqual(restored.inboxRuns.map(\.id), ["finished"])
    }

    func testBulkReadOnlyAcknowledgesResultsAndNeverResolvesRequests() {
        let request = AttentionItem(id: "recovery", kind: "recoverable_run", group: .recoveries,
            runID: "failed", title: "Needs recovery", detail: "Failed", actions: ["retry"])
        let model = makeModel(liveAttention: { [request] })
        model.activityRuns = [run(id: "done"), run(id: "failed", state: "failed"), run(id: "active", state: "running")]
        XCTAssertEqual(model.inboxCount, 2, "One request and one new result, with no duplicate failed row")
        model.markAllActivitySeen()
        XCTAssertEqual(model.readRuns.map(\.id), ["done"])
        XCTAssertEqual(model.inboxCount, 1)
        XCTAssertEqual(model.displayedAttentionItems, [request])
        XCTAssertTrue(model.activityIsUnseen(model.activityRuns[2]))
        model.markActivitySeen(model.activityRuns[1])
        XCTAssertEqual(model.displayedAttentionItems, [request], "Reading a failed task cannot resolve recovery")
    }

    func testReadingAnActiveRunDoesNotHideItsCompletion() {
        let model = makeModel()
        let active = run(id: "work", state: "running")
        model.activityRuns = [active]
        model.markActivitySeen(active)
        XCTAssertEqual(model.inProgressRuns.map(\.id), ["work"])
        XCTAssertTrue(model.readRuns.isEmpty)
        model.activityRuns = [run(id: "work", updatedAt: 11)]
        XCTAssertEqual(model.inboxRuns.map(\.id), ["work"])
    }

    func testOpeningReadRunFocusRevealsItWithoutChangingReadState() async throws {
        let finished = run(id: "finished")
        let detail = try JSONEncoder().encode(finished)
        BackendStub.respond(toPath: "/api/runs") { _ in ["runs": [], "read_only": false] }
        BackendStub.respond(toPath: "/api/runs/finished") { _ in detail }
        BackendStub.respond(toPath: "/api/attention") { _ in ["items": [], "unresolved_count": 0, "read_only": false] }
        let model = makeModel()
        model.markActivitySeen(finished)
        await openAndFinishRefresh(model, focus: .run("finished"))
        XCTAssertEqual(model.selectedTab, .completed)
        XCTAssertEqual(model.readRuns.map(\.id), ["finished"])
        XCTAssertEqual(model.unreadResultCount, 0)
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

    func testClearingReadKeepsUnreadAndActiveWorkAndPreservesTaskHistory() {
        let request = AttentionItem(id: "recovery", kind: "recoverable_run", group: .recoveries,
            runID: "failed", title: "Needs recovery", detail: "Failed", actions: ["retry"])
        let model = makeModel(liveAttention: { [request] })
        let read = run(id: "read")
        let failed = run(id: "failed", state: "failed")
        let unread = run(id: "unread")
        let active = run(id: "active", state: "running")
        model.activityRuns = [read, failed, unread, active]
        model.markActivitySeen(read)
        model.markActivitySeen(failed)

        model.clearReadActivityRuns()

        XCTAssertEqual(model.visibleActivityRuns.map(\.id), ["unread", "active"])
        XCTAssertEqual(model.inboxRuns.map(\.id), ["unread"])
        XCTAssertEqual(model.inProgressRuns.map(\.id), ["active"])
        XCTAssertTrue(model.readRuns.isEmpty)
        XCTAssertEqual(model.activityRuns, [read, failed, unread, active], "Clearing only removes presentation rows")
        XCTAssertEqual(model.attentionItems, [request], "Clearing cannot resolve an outstanding request")
        XCTAssertEqual(toasts, ["Cleared 2 read updates"])
        XCTAssertNoBackendTraffic()

        let restored = makeModel()
        restored.activityRuns = model.activityRuns
        XCTAssertEqual(restored.visibleActivityRuns.map(\.id), ["unread", "active"])
    }

    func testClearingMatchingReadUpdatesLeavesOtherReadAndNewerResultsVisible() {
        let model = makeModel()
        let matched = run(id: "matched")
        let other = run(id: "other")
        let changed = run(id: "changed")
        model.activityRuns = [matched, other, changed]
        model.markAllActivitySeen()
        model.activityRuns[2] = run(id: "changed", updatedAt: 20)

        model.clearReadActivityRuns(matching: ["matched", "changed"])

        XCTAssertEqual(model.readRuns.map(\.id), ["other"])
        XCTAssertEqual(model.inboxRuns.map(\.id), ["changed"])
        XCTAssertEqual(model.dismissedActivityRunIDs, ["matched"])
    }

    func testClearingFocusedReadRunKeepsItClearedAfterRefresh() async throws {
        let selected = run(id: "selected")
        let other = run(id: "other")
        let detail = try JSONEncoder().encode(selected)
        BackendStub.respond(toPath: "/api/runs") { _ in ["runs": [], "read_only": false] }
        BackendStub.respond(toPath: "/api/runs/selected") { _ in detail }
        BackendStub.respond(toPath: "/api/attention") { _ in ["items": [], "unresolved_count": 0, "read_only": false] }
        let model = makeModel()
        model.markActivitySeen(selected)
        model.markActivitySeen(other)
        await openAndFinishRefresh(model, focus: .run("selected"))
        model.activityRuns = [other]

        model.clearReadActivityRuns()

        XCTAssertTrue(model.displayedActivityRuns.isEmpty)
        XCTAssertEqual(model.dismissedActivityRunIDs, ["selected"], "A focused clear leaves unrelated read updates intact")
        await model.refreshActivityRuns()
        XCTAssertTrue(model.displayedActivityRuns.isEmpty, "Fetching a focused run must not resurrect a cleared update")
    }

    func testAgentAttributionUsesSavedProfileBeforeScheduleNameAndSupportsLegacyAndTeams() {
        let profile = AgentProfile(name: "Jinbei")
        let scheduledChat = SessionSummary(id: "session-1", name: "chat", preview: "", mtime: 1, size: 0,
            agentProfileID: profile.id.uuidString, agentKind: "schedule", agentName: "Test Schedule")
        XCTAssertEqual(ActivityCenterModel.agentName(for: run(id: "saved"), session: scheduledChat, profiles: [profile]), "Jinbei")

        let legacyChat = SessionSummary(id: "session-1", name: "chat", preview: "", mtime: 1, size: 0,
            agentKind: "event", agentName: "Inbox Triage")
        XCTAssertEqual(ActivityCenterModel.agentName(for: run(id: "legacy"), session: legacyChat, profiles: []), "Inbox Triage")
        XCTAssertEqual(ActivityCenterModel.agentName(for: run(id: "team", runKind: "team"), session: scheduledChat, profiles: [profile]), "Team")
        XCTAssertNil(ActivityCenterModel.agentName(for: run(id: "ordinary"), session: nil, profiles: [profile]), "Do not attribute ordinary chats to whichever agent is selected")
    }

    func testCompletionAlreadyViewedInChatStaysAsReadMailAfterRefreshAndRelaunch() async throws {
        let model = makeModel()
        model.activityRuns = [run(id: "viewed", state: "running")]
        let finished = run(id: "viewed", updatedAt: 20)
        let response = try JSONEncoder().encode(OrchestrationRunsResponse(runs: [finished], readOnly: false))
        BackendStub.respond(toPath: "/api/runs") { _ in response }
        BackendStub.respond(toPath: "/api/attention") { _ in ["items": [], "unresolved_count": 0, "read_only": false] }

        model.recordCompletion(runID: "viewed", succeeded: true, wasRunning: true, isViewed: true)
        await model.refreshActivityRuns()

        XCTAssertEqual(model.completedRuns, [finished], "Viewed completions stay available as read mail")
        XCTAssertEqual(model.activityRuns, [finished], "The result itself remains saved")
        XCTAssertEqual(model.unreadResultCount, 0)
        let restored = makeModel()
        restored.activityRuns = [finished]
        XCTAssertEqual(restored.completedRuns, [finished])
        XCTAssertFalse(restored.activityIsUnseen(finished))
        restored.markActivityUnread(finished)
        XCTAssertTrue(restored.activityIsUnseen(finished))
    }

    func testBackgroundCompletionRemainsAvailableWhenOpenedLaterOrReplayed() {
        let model = makeModel()
        let finished = run(id: "background")
        model.recordCompletion(runID: finished.id, succeeded: true, wasRunning: true, isViewed: false)
        model.activityRuns = [finished]
        XCTAssertEqual(model.inboxRuns.map(\.id), [finished.id])

        model.markActivitySeen(finished)
        model.recordCompletion(runID: finished.id, succeeded: true, wasRunning: true, isViewed: true)

        XCTAssertEqual(model.readRuns.map(\.id), [finished.id], "A replay after opening cannot hide an earlier background completion")
        XCTAssertTrue(model.dismissedActivityRunIDs.isEmpty)
    }

    func testInactiveHistoricalFailedAndActivityCenterCompletionsAreNotSuppressed() {
        let model = makeModel()
        model.recordCompletion(runID: "historical", succeeded: true, wasRunning: false, isViewed: true)
        model.recordCompletion(runID: "failed", succeeded: false, wasRunning: true, isViewed: true)
        model.activityCenterPresented = true
        model.recordCompletion(runID: "activity-open", succeeded: true, wasRunning: true, isViewed: true)
        model.activityRuns = [run(id: "historical"), run(id: "failed", state: "failed"), run(id: "activity-open")]

        XCTAssertEqual(model.visibleActivityRuns.count, 3)
        XCTAssertEqual(model.unreadResultCount, 3)
        XCTAssertTrue(model.dismissedActivityRunIDs.isEmpty)
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

    func testCompletedInboxKeepsReadMailAndExcludesFailedWork() {
        let model = makeModel()
        let newer = run(id: "new", updatedAt: 30)
        let older = run(id: "old", updatedAt: 10)
        model.activityRuns = [older, run(id: "failed", state: "failed"), newer, run(id: "active", state: "running")]
        XCTAssertEqual(model.completedRuns.map(\.id), ["new", "old"])
        model.markActivitySeen(newer)
        XCTAssertEqual(model.completedRuns.map(\.id), ["new", "old"], "Reading mail must not remove or reorder it")
        XCTAssertEqual(model.attentionRuns.map(\.id), ["failed"])
        model.markAllActivitySeen(matching: ["old"])
        XCTAssertFalse(model.activityIsUnseen(older))
        XCTAssertTrue(model.activityIsUnseen(model.activityRuns[1]), "Bulk reading must not acknowledge hidden work")
    }

    func testFiltersCombineAgentTimeTypeAndSearch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var filter = ActivityFilter()
        filter.agentID = "agent:luffy"
        filter.time = .week
        filter.kind = .schedule
        filter.search = "stock"
        XCTAssertTrue(filter.matches(agentID: "agent:luffy", timestamp: now.timeIntervalSince1970 - 3600,
            kind: .schedule, text: ["Daily stock check"], now: now))
        XCTAssertFalse(filter.matches(agentID: "agent:law", timestamp: now.timeIntervalSince1970,
            kind: .schedule, text: ["Daily stock check"], now: now))
        XCTAssertFalse(filter.matches(agentID: "agent:luffy", timestamp: now.timeIntervalSince1970 - 8 * 86400,
            kind: .schedule, text: ["Daily stock check"], now: now))
        XCTAssertFalse(filter.matches(agentID: "agent:luffy", timestamp: now.timeIntervalSince1970,
            kind: .event, text: ["Daily stock check"], now: now))
        XCTAssertFalse(filter.matches(agentID: "agent:luffy", timestamp: now.timeIntervalSince1970,
            kind: .schedule, text: ["Email triage"], now: now))
    }

    func testTodayUsesCalendarBoundaryAndRejectsFutureDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let midnight = calendar.startOfDay(for: now).timeIntervalSince1970
        XCTAssertTrue(ActivityFilter.TimeRange.today.includes(midnight, now: now, calendar: calendar))
        XCTAssertFalse(ActivityFilter.TimeRange.today.includes(midnight - 1, now: now, calendar: calendar))
        XCTAssertFalse(ActivityFilter.TimeRange.today.includes(now.timeIntervalSince1970 + 1, now: now, calendar: calendar))
    }

    func testOutputReaderUsesOnlySelectedFinalAndStripsThinking() {
        let selected = run(id: "chosen")
        let blocks = [
            ChatBlock(kind: .user, text: "req", runID: "chosen"),
            ChatBlock(kind: .assistant, text: "Checking…", assistantPhase: .commentary, runID: "chosen"),
            ChatBlock(kind: .assistant, text: "<think>Private reasoning</think>Finished output", assistantPhase: .finalAnswer,
                reasoningText: "More reasoning", runID: "chosen"),
            ChatBlock(kind: .user, text: "Later request", runID: "other"),
            ChatBlock(kind: .assistant, text: "Unrelated later output", assistantPhase: .finalAnswer, runID: "other")
        ]
        let output = ChatTranscriptBuilder.activityOutput(for: selected, in: blocks)
        XCTAssertEqual(output?.text.trimmingCharacters(in: .whitespacesAndNewlines), "Finished output")
        XCTAssertNil(output?.reasoningText)
        XCTAssertNil(output?.reasoningSections)
        XCTAssertNil(ChatTranscriptBuilder.activityOutput(for: run(id: "missing"), in: blocks))
    }

    func testOutputReaderRetainsStructuredOutputsWithoutPlainText() throws {
        let document = ResponseDocument(version: 1, parts: [ResponsePart(type: "image", id: "picture", workspace: "/tmp", path: "panda.png")])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
        let message = decode(HistoryMessage.self, from: ["role": "assistant", "content": "", "phase": "final_answer",
            "run_id": "picture-run", "response_parts": json])!
        let blocks = ChatTranscriptBuilder.blocks(from: [message])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(ChatTranscriptBuilder.activityOutput(for: run(id: "picture-run"), in: blocks)?.responseParts, document)
    }

    func testOutputReaderDoesNotGuessBetweenIdenticalLegacyRequests() {
        let blocks = [
            ChatBlock(kind: .user, text: "req"), ChatBlock(kind: .assistant, text: "First result"),
            ChatBlock(kind: .user, text: "req"), ChatBlock(kind: .assistant, text: "Second result")
        ]
        XCTAssertNil(ChatTranscriptBuilder.activityOutput(for: run(id: "legacy"), in: blocks))
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
