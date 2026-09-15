import Combine
import Foundation
import XCTest
@testable import Locus

final class AgentInspectorTests: XCTestCase {
    private let eventAgent = AgentInspectorAgent(kind: .event, agentID: "shared-id")
    private let scheduleAgent = AgentInspectorAgent(kind: .schedule, agentID: "shared-id")

    func testContextsKeepKindsAndRecordIDsDistinct() {
        XCTAssertNotEqual(eventAgent, scheduleAgent)
        let contexts: Set<AgentInspectorContext> = [
            .agent(eventAgent), .agent(scheduleAgent),
            .chat(eventAgent, sessionID: "same-id"),
            .event(eventAgent, deliveryID: "same-id"),
            .occurrence(scheduleAgent, occurrenceID: "same-id"),
            .run(eventAgent, runID: "same-id", origin: nil),
        ]
        XCTAssertEqual(contexts.count, 6)
    }

    func testBackNavigationPreservesTheExactOrigin() {
        let event = AgentInspectorContext.event(eventAgent, deliveryID: "earlier-event")
        let run = AgentInspectorContext.run(eventAgent, runID: "retry-2", origin: .event("earlier-event"))
        XCTAssertEqual(run.parent, event)
        XCTAssertEqual(event.parent, .agent(eventAgent))
        XCTAssertEqual(event.parent?.parent, .fleet)
        XCTAssertEqual(
            AgentInspectorContext.run(scheduleAgent, runID: "run", origin: .occurrence("slot")).parent,
            .occurrence(scheduleAgent, occurrenceID: "slot")
        )
    }

    func testHistoryCountsNeverTreatQueuedOrSkippedAsCompleted() throws {
        let data = Data("""
        {"total":11,"counts":{"completed":1,"queued":2,"running":1,"skipped":1,
        "cancelled":1,"waiting_permission":1,"waiting_computer":1,"paused":1,
        "advancing":1,"planning":1},"next_cursor":null}
        """.utf8)
        let history = try JSONDecoder().decode(AgentInspectorHistory.self, from: data)
        XCTAssertEqual(history.completedCount, 1)
        XCTAssertEqual(history.activeCount, 5)
        XCTAssertEqual(history.attentionCount, 3)
        XCTAssertEqual(history.total, 11)
        XCTAssertEqual(AgentInspectorCopy.state("skipped"), "Skipped this time")
        XCTAssertEqual(AgentInspectorCopy.state("dispatching"), "Getting ready")
        XCTAssertEqual(AgentInspectorCopy.state("unknown_future_state"), "Status unavailable")
    }

    @MainActor
    func testSwitchingContextsDiscardsLateResponseAndError() async {
        let model = AgentInspectorModel()
        model.show(.agent(eventAgent))
        let signal = AsyncStream<Void>.makeStream()
        var gate: CheckedContinuation<AgentInspectorSnapshot, Never>?
        let first = Task {
            await model.load { _, _ in
                await withCheckedContinuation { continuation in
                    gate = continuation
                    signal.continuation.yield(())
                }
            }
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        model.show(.agent(scheduleAgent))
        XCTAssertNil(model.loadedAt)
        XCTAssertNil(model.snapshot.history)
        await model.load { _, _ in Self.snapshot(total: 9) }
        gate?.resume(returning: Self.snapshot(total: 99))
        await first.value
        XCTAssertEqual(model.context, .agent(scheduleAgent))
        XCTAssertEqual(model.snapshot.history?.total, 9)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testFailedRefreshRetainsLastGoodInformationOnlyForItsContext() async {
        let model = AgentInspectorModel()
        model.show(.agent(eventAgent))
        await model.load { _, _ in Self.snapshot(total: 3) }
        let loadedAt = model.loadedAt
        await model.load { _, _ in throw LoadFailure.offline }
        XCTAssertEqual(model.snapshot.history?.total, 3)
        XCTAssertEqual(model.loadedAt, loadedAt)
        XCTAssertEqual(model.error, "Could not refresh. Showing the last saved information.")
        model.show(.event(eventAgent, deliveryID: "event-1"))
        XCTAssertNil(model.error)
        XCTAssertNil(model.snapshot.history)
    }

    @MainActor
    func testARepeatedSelectionPreservesLoadedContent() async {
        let model = AgentInspectorModel()
        model.show(.agent(eventAgent))
        await model.load { _, _ in Self.snapshot(total: 2) }
        model.show(.agent(eventAgent))
        XCTAssertEqual(model.snapshot.history?.total, 2)
        model.back()
        XCTAssertEqual(model.context, .fleet)
    }

    @MainActor
    func testPaginationUsesTheServerCursorAndKeepsAuthoritativeTotals() async {
        let model = AgentInspectorModel()
        model.show(.agent(eventAgent))
        await model.load { _, _ in Self.snapshot(total: 42, cursor: "page-two") }
        await model.load(append: true) { context, cursor in
            XCTAssertEqual(context, .agent(self.eventAgent))
            XCTAssertEqual(cursor, "page-two")
            return Self.snapshot(total: 43)
        }
        XCTAssertEqual(model.snapshot.history?.total, 43)
        XCTAssertNil(model.snapshot.history?.nextCursor)
    }

    @MainActor
    func testRefreshReloadsAllVisiblePagesThroughThePriorBoundary() async {
        let model = AgentInspectorModel()
        let context = AgentInspectorContext.agent(scheduleAgent)
        model.show(context)
        await model.load { _, _ in Self.slotPage(31...60, state: "pending", cursor: "old-2") }
        await model.load(append: true) { _, _ in Self.slotPage(1...30, state: "pending", cursor: "old-3") }
        model.presentation[context] = AgentInspectorPresentation(scrollAnchor: "events", expandedDetails: true)
        var fetched: [String?] = []
        await model.load { _, cursor in
            fetched.append(cursor)
            switch cursor {
            case nil: return Self.slotPage(41...70, state: "completed", cursor: "new-2")
            case "new-2": return Self.slotPage(11...40, state: "completed", cursor: "new-3")
            default:
                var page = Self.slotPage(0...10, state: "completed", cursor: "new-4")
                page.history?.occurrences?.removeAll { $0.id == "slot-1" }
                return page
            }
        }
        XCTAssertEqual(fetched, [nil, "new-2", "new-3"])
        XCTAssertEqual(model.context, context)
        XCTAssertEqual(model.snapshot.history?.occurrences?.first(where: { $0.id == "slot-20" })?.state, "completed")
        XCTAssertFalse(model.snapshot.history?.occurrences?.contains { $0.id == "slot-1" } ?? true)
        XCTAssertEqual(model.snapshot.history?.nextCursor, "new-4")
        XCTAssertEqual(model.presentation[context]?.scrollAnchor, "events")
        XCTAssertEqual(model.presentation[context]?.expandedDetails, true)
    }

    @MainActor
    func testBackRestoresTheObjectsScrollDisclosuresAndCachedContent() async {
        let model = AgentInspectorModel()
        let parent = AgentInspectorContext.agent(eventAgent)
        let child = AgentInspectorContext.event(eventAgent, deliveryID: "event-1")
        model.show(parent)
        await model.load { _, _ in Self.snapshot(total: 8) }
        model.presentation[parent] = AgentInspectorPresentation(
            scrollAnchor: "events", expandedDetails: true, expandedInstructions: true
        )
        model.show(child)
        XCTAssertNil(model.snapshot.history)
        XCTAssertNil(model.presentation[child])
        model.presentation[child] = AgentInspectorPresentation(expandedIncomingContent: true)
        model.back()
        XCTAssertEqual(model.snapshot.history?.total, 8)
        XCTAssertEqual(model.presentation[parent]?.scrollAnchor, "events")
        XCTAssertEqual(model.presentation[parent]?.expandedDetails, true)
        XCTAssertEqual(model.presentation[child]?.expandedIncomingContent, true)
    }

    func testRunMetricsRequireReportedValuesAndActualAdmission() throws {
        var value: [String: Any] = [
            "id": "r", "state": "completed", "request": "Read", "created_at": 1.0,
            "updated_at": 200.0, "completed_at": 200.0, "last_seq": 0,
            "pinned": false, "legacy": false, "recoverable": false,
        ]
        func decoded() throws -> OrchestrationRun {
            try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertNil(AgentInspectorCopy.duration(try decoded()))
        XCTAssertNil(AgentInspectorCopy.tokens(try decoded()))
        value["admitted_at"] = 125.0
        value["usage"] = ["prompt_tokens": 10]
        XCTAssertEqual(AgentInspectorCopy.duration(try decoded()), "1 min 15 sec")
        XCTAssertNil(AgentInspectorCopy.tokens(try decoded()))
        value["usage"] = ["prompt_tokens": 10, "completion_tokens": 5]
        XCTAssertEqual(AgentInspectorCopy.tokens(try decoded()), 15)
        value["usage"] = ["metered_tokens": 0]
        XCTAssertEqual(AgentInspectorCopy.tokens(try decoded()), 0)
    }

    func testAgentStatusUsesTheSameVisibleAndAccessibleState() {
        XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(.active), "Ready")
        XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(.active, isRunning: true), "Running")
        XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(.active, sourceNeedsAttention: true), "Needs attention")
        XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(.active, isRunning: true, sourceNeedsAttention: true), "Running")
        XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(.paused), "Paused")
        for status in [AgentOverview.Status.stopped, .failing, .missingTrigger] {
            XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(status), "Needs attention")
        }
        XCTAssertEqual(AgentInspectorCopy.agentStatusTitle(.fired), "Completed")
    }

    func testActivityStatesDistinguishWaitingAttentionAndUnknownFromSuccess() {
        XCTAssertEqual(AgentActivityState(rawState: "completed"), .completed)
        for state in ["pending", "queued"] {
            XCTAssertEqual(AgentActivityState(rawState: state), .waiting, state)
        }
        for state in ["planning", "running", "advancing", "awaiting_run"] {
            XCTAssertEqual(AgentActivityState(rawState: state), .running, state)
        }
        for state in ["failed", "interrupted", "waiting_permission", "waiting_approval", "waiting_computer", "paused"] {
            XCTAssertEqual(AgentActivityState(rawState: state), .attention, state)
        }
        for state in ["skipped", "cancelled", "discarded", "future_backend_state"] {
            XCTAssertEqual(AgentActivityState(rawState: state), .neutral, state)
        }
    }

    func testReadyAgentRequiresAUsableConnectionButPausedAgentsRemainQuiet() {
        var trigger = EventTrigger(id: "agent", name: "Inbox", connectionID: "source",
            targetSessionID: "chat", instruction: "Review messages", mode: .work, triggerKind: .event,
            filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [],
            enabled: true, createdAt: 10, updatedAt: 10, lastEventAt: nil, lastRunID: nil, lastError: nil)
        var connection = ConnectorConnection(id: "source", kind: .gmail, displayName: "Inbox",
            publicConfig: [:], cursor: [:], enabled: true, health: "connected", lastError: nil,
            lastPolledAt: nil, createdAt: 10, updatedAt: 10)
        XCTAssertFalse(AgentInspectorCopy.sourceNeedsAttention(definition: .trigger(trigger), connection: connection))
        XCTAssertTrue(AgentInspectorCopy.sourceNeedsAttention(definition: .trigger(trigger), connection: nil))
        connection.health = "error"
        XCTAssertTrue(AgentInspectorCopy.sourceNeedsAttention(definition: .trigger(trigger), connection: connection))
        connection.health = "connected"
        connection.enabled = false
        XCTAssertTrue(AgentInspectorCopy.sourceNeedsAttention(definition: .trigger(trigger), connection: connection))
        trigger.enabled = false
        XCTAssertFalse(AgentInspectorCopy.sourceNeedsAttention(definition: .trigger(trigger), connection: connection))
    }

    func testDeliveryCompletionDoesNotHideExecutionAttention() {
        let incoming = InboundEvent(source: .gmail, sourceEventID: "event", eventType: "email.received",
            occurredAt: 10, actor: [:], subject: "Review this", text: "Message",
            recipients: [], labels: [], attachments: [], data: [:])
        func event(_ runState: String) -> AgentOverview.Event {
            AgentOverview.Event(delivery: EventDelivery(id: "delivery", triggerID: "agent",
                sourceEventID: "event", source: .gmail, receivedAt: 10, occurredAt: 10,
                event: incoming, state: "completed", runState: runState, attempt: 1,
                sessionID: "chat", runID: "run", error: nil, createdAt: 10, updatedAt: 10))
        }
        XCTAssertEqual(AgentInspectorCopy.activityState(event("waiting_approval")), .attention)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("failed")), .attention)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("running")), .running)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("completed")), .completed)
    }

    func testTerminalDeliveryOutcomeWinsOverStaleExecutionState() {
        let incoming = InboundEvent(source: .gmail, sourceEventID: "event", eventType: "email.received",
            occurredAt: 10, actor: [:], subject: "Review this", text: "Message",
            recipients: [], labels: [], attachments: [], data: [:])
        for state in ["failed", "interrupted", "cancelled", "skipped"] {
            let delivery = EventDelivery(id: "delivery", triggerID: "agent", sourceEventID: "event",
                source: .gmail, receivedAt: 10, occurredAt: 10, event: incoming, state: state,
                runState: "running", attempt: 1, sessionID: "chat", runID: "run", error: nil,
                createdAt: 10, updatedAt: 10)
            let event = AgentOverview.Event(delivery: delivery)
            XCTAssertEqual(event.stateTitle, AgentInspectorCopy.state(state))
            XCTAssertEqual(AgentInspectorCopy.activityState(event), AgentActivityState(rawState: state))
            XCTAssertFalse(event.isInFlight)
            XCTAssertEqual(event.isSkipped, state == "skipped")
            XCTAssertEqual(event.canRetry, state != "skipped")
        }
        XCTAssertEqual(AgentInspectorCopy.effectiveActivityState(deliveryState: "queued", runState: ""), "queued")
        XCTAssertEqual(AgentInspectorCopy.effectiveActivityState(deliveryState: "completed", runState: "failed"), "failed")
        XCTAssertEqual(AgentInspectorCopy.effectiveActivityState(deliveryState: "failed", runState: "completed"), "failed")
    }

    func testScheduleActivityFilterIncludesApprovalWithoutFlaggingSkippedSlots() {
        func event(_ state: String) -> AgentOverview.Event {
            AgentOverview.Event(occurrence: ScheduleOccurrence(id: "slot", scheduleID: "agent",
                scheduleName: "Review", scheduledFor: 10, trigger: "due", state: state,
                sessionID: nil, runID: nil, error: nil, createdAt: 10, updatedAt: 10))
        }
        XCTAssertEqual(AgentInspectorCopy.activityState(event("waiting_approval")), .attention)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("waiting_computer")), .attention)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("skipped")), .neutral)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("completed")), .completed)
        XCTAssertEqual(AgentInspectorCopy.activityState(event("unknown")), .neutral)
    }

    @MainActor
    func testAttentionFocusShowsOnlyTheSelectedRequestAndCanReturnToAll() {
        BackendStub.reset()
        let model = ActivityCenterModel()
        let unrelated = AttentionItem(id: "a", kind: "permission_request", group: .decisions,
            runID: "other", title: "Other work", detail: "", actions: [])
        let selected = AttentionItem(id: "b", kind: "workflow_approval", group: .decisions,
            workflowExecutionID: "chosen", title: "Selected workflow", detail: "", actions: [])
        model.configure(backend: stubbedBackendService(), liveAttentionProvider: { [unrelated, selected] }, toastHandler: { _ in })
        model.openActivityCenter(focus: .workflow("chosen"))
        XCTAssertEqual(model.displayedAttentionItems.map(\.id), ["b"])
        model.clearFocus()
        XCTAssertEqual(Set(model.displayedAttentionItems.map(\.id)), ["a", "b"])
        model.openActivityCenter(focus: .run("other"))
        XCTAssertEqual(model.displayedAttentionItems.map(\.id), ["a"])
        model.openActivityCenter()
        XCTAssertNil(model.focus)
    }

    @MainActor
    func testActivityNavigationSelectsTheExactOlderRunInItsChat() async throws {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        let selected = try activityNavigationRun(id: "selected-run", sessionID: "selected-chat")
        let newer = try activityNavigationRun(id: "newer-run", sessionID: "selected-chat", updatedAt: 30)
        model.sessions = [SessionSummary(id: "selected-chat", name: "Chat", preview: "", mtime: 1, size: 0)]
        model.selectedOrchestrationRun = newer
        model.orchestrationRunID = newer.id
        model.activity.activityCenterPresented = true
        try stubActivityNavigation(selected, list: [newer, selected], messages: [
            ["role": "user", "content": "Earlier request", "run_id": selected.id],
            ["role": "assistant", "content": "Earlier result", "run_id": selected.id, "phase": "final_answer"],
            ["role": "user", "content": "New request", "run_id": newer.id],
            ["role": "assistant", "content": "New result", "run_id": newer.id, "phase": "final_answer"],
        ])

        model.openActivityRun(selected)

        XCTAssertEqual(model.currentSessionID, "selected-chat")
        XCTAssertEqual(model.selectedOrchestrationRun?.id, "selected-run")
        XCTAssertEqual(model.runsNavigationRequest?.runID, "selected-run")
        XCTAssertEqual(model.inspectorTab, .runs)
        XCTAssertFalse(model.inspectorCollapsed)
        XCTAssertFalse(model.activity.activityIsUnseen(selected))
        XCTAssertFalse(model.activity.activityCenterPresented)
        let load = try XCTUnwrap(model.activeTranscriptLoad)
        await load.task.value
        XCTAssertEqual(model.activityResultReveal?.runID, selected.id)
        XCTAssertEqual(model.activityResultReveal?.blockID, model.blocks.first { $0.text == "Earlier result" }?.id)
        XCTAssertNil(model.pendingActivityResultRun)
        await model.refreshOrchestrationRuns(select: selected.id)
        XCTAssertEqual(model.selectedOrchestrationRun?.id, "selected-run", "The newer run must not replace the requested result")
        XCTAssertTrue(BackendStub.requestPaths.contains("/api/orchestrations/selected-run"))
    }

    func testActivityResultUsesTheFinalAnswerAndIgnoresOtherRunsAndCommentary() throws {
        let run = try activityNavigationRun(id: "chosen", sessionID: "chat")
        let answer = ChatBlock(kind: .assistant, text: "Selected result", assistantPhase: .finalAnswer, runID: run.id)
        let blocks = [
            ChatBlock(kind: .assistant, text: "Previous result", runID: "previous"),
            answer,
            ChatBlock(kind: .assistant, text: "Late progress update", assistantPhase: .commentary, runID: run.id),
            ChatBlock(kind: .assistant, text: "Newer result", runID: "newer"),
        ]
        XCTAssertEqual(ChatTranscriptBuilder.activityResultBlockID(for: run, in: blocks), answer.id)
    }

    func testActivityResultUsesLegacyUserRunAnchorWithoutCrossingIntoTheNextTurn() throws {
        let run = try activityNavigationRun(id: "chosen", sessionID: "chat")
        let answer = ChatBlock(kind: .assistant, text: "Selected legacy result")
        let blocks = [
            ChatBlock(kind: .user, text: "Repeated request", runID: run.id), answer,
            ChatBlock(kind: .user, text: "Repeated request", runID: "newer"),
            ChatBlock(kind: .assistant, text: "Latest answer"),
        ]
        XCTAssertEqual(ChatTranscriptBuilder.activityResultBlockID(for: run, in: blocks), answer.id)
        XCTAssertNil(ChatTranscriptBuilder.activityResultBlockID(for: run, in: [blocks[0]] + Array(blocks.dropFirst(2))))
    }

    func testActivityResultDoesNotGuessBetweenRepeatedLegacyRequests() throws {
        let run = try activityNavigationRun(id: "chosen", sessionID: "chat")
        let answer = ChatBlock(kind: .assistant, text: "Legacy answer")
        let blocks = [ChatBlock(kind: .user, text: run.request), answer]
        XCTAssertEqual(ChatTranscriptBuilder.activityResultBlockID(for: run, in: blocks), answer.id)
        XCTAssertNil(ChatTranscriptBuilder.activityResultBlockID(for: run, in: blocks + [
            ChatBlock(kind: .user, text: run.request), ChatBlock(kind: .assistant, text: "Other answer"),
        ]))
    }

    @MainActor
    func testTaskResultCardsSeparateAutomationsAndKeepOrdinaryRepliesUnboxed() throws {
        let owner = AgentProfile(name: "Jinbei")
        let session = SessionSummary(id: "chat", name: "Task chat", preview: "", mtime: 1, size: 0,
            agentProfileID: owner.id.uuidString)
        // Backend shapes: api/schedules.py stores schedule_id, api/event_triggers.py
        // stores manifest.event_trigger_id (price alerts included), and workflow
        // steps carry manifest.workflow_execution_id.
        let scheduled = try activityNavigationRun(id: "scheduled", sessionID: session.id,
            fields: ["schedule_id": "schedule", "occurrence_id": "occurrence", "task_id": ""])
        let triggered = try activityNavigationRun(id: "triggered", sessionID: session.id,
            fields: ["manifest": ["event_triggered": true, "event_trigger_id": "event", "event_trigger_kind": "price"]])
        let workflow = try activityNavigationRun(id: "workflow", sessionID: session.id,
            fields: ["manifest": ["workflow_execution_id": "execution", "automation_kind": "event"]])
        let scheduledTeam = try activityNavigationRun(id: "scheduled-team", sessionID: session.id,
            fields: ["run_kind": "team", "team_name": "Night crew", "schedule_id": "team-schedule"])
        let ordinary = try activityNavigationRun(id: "ordinary", sessionID: session.id)
        let runs = [scheduled, triggered, workflow, scheduledTeam, ordinary]
        let answers = Dictionary(uniqueKeysWithValues: runs.map { run in
            (run.id, ChatBlock(kind: .assistant, text: "Result for \(run.id)", runID: run.id))
        })
        let cards = ChatTranscriptBuilder.taskResults(in: runs.compactMap { answers[$0.id] },
            runs: runs, session: session, profiles: [owner])
        XCTAssertEqual(Set(cards.keys), Set(["scheduled", "triggered", "workflow", "scheduled-team"].compactMap { answers[$0]?.id }))
        XCTAssertEqual(cards[try XCTUnwrap(answers["scheduled"]).id]?.runID, scheduled.id)
        XCTAssertEqual(cards[try XCTUnwrap(answers["triggered"]).id]?.runID, triggered.id)
        XCTAssertEqual(cards[try XCTUnwrap(answers["scheduled"]).id]?.agentName, owner.name)
        XCTAssertEqual(cards[try XCTUnwrap(answers["scheduled-team"]).id]?.agentName, "Night crew")
        XCTAssertNil(cards[try XCTUnwrap(answers["ordinary"]).id])
    }

    @MainActor
    func testOrdinaryChatRunsStayUnboxedWithTaskIDsTeamsAndGoals() throws {
        let owner = AgentProfile(name: "Jinbei")
        // A person typing in a saved agent's ordinary chat, not its event chat.
        let session = SessionSummary(id: "chat", name: "Agent chat", preview: "", mtime: 1, size: 0,
            agentProfileID: owner.id.uuidString)
        // server.py starts every chat turn with task_id "" (or the worktree
        // checkout ID) and schedule_id ""; chats queue team runs directly.
        let unmarked = try activityNavigationRun(id: "unmarked", sessionID: session.id,
            fields: ["task_id": "", "schedule_id": "", "occurrence_id": "", "manifest": ["event_trigger_id": ""]])
        let worktree = try activityNavigationRun(id: "worktree", sessionID: session.id,
            fields: ["task_id": "checkout-1", "execution_environment": "worktree"])
        let team = try activityNavigationRun(id: "team", sessionID: session.id,
            fields: ["run_kind": "team", "team_id": "crew", "team_name": "Crew", "task_id": "checkout-2"])
        let goal = try activityNavigationRun(id: "goal", sessionID: session.id,
            fields: ["manifest": ["goal_id": "goal", "goal_automatic": true, "capsule_context": ["id": "capsule"]]])
        let runs = [unmarked, worktree, team, goal]
        XCTAssertEqual(worktree.taskID, "checkout-1")
        XCTAssertEqual(team.runKind, "team")
        let blocks = runs.flatMap { run in [
            ChatBlock(kind: .user, text: "Request \(run.id)", runID: run.id),
            ChatBlock(kind: .assistant, text: "Reply \(run.id)", assistantPhase: .finalAnswer, runID: run.id),
        ] }
        XCTAssertEqual(ChatTranscriptBuilder.taskResults(in: blocks, runs: runs, session: session, profiles: [owner]), [:])
        XCTAssertEqual(ChatTranscriptBuilder.activityResultBlockID(for: worktree, in: blocks),
            blocks.first { $0.text == "Reply worktree" }?.id,
            "Activity Center still resolves ordinary answers for its highlight")

        let eventChat = SessionSummary(id: "chat", name: "Daily check", preview: "", mtime: 1, size: 0,
            agentTriggerID: "schedule", agentKind: "schedule", agentName: "Daily check", agentPrimary: true)
        XCTAssertEqual(ChatTranscriptBuilder.taskResults(in: blocks, runs: runs, session: eventChat, profiles: []), [:],
            "Replies to questions typed into an agent's event chat stay unboxed once their runs are known")
    }

    @MainActor
    func testTaskResultCardsUsePersistedEventTurnsBeforeRunRecordsLoad() {
        let owner = AgentProfile(name: "Jinbei")
        let session = SessionSummary(id: "chat", name: "Email check", preview: "", mtime: 1, size: 0,
            agentProfileID: owner.id.uuidString)
        let event = InboundEvent(source: .gmail, sourceEventID: "email", eventType: "message",
            occurredAt: 1, actor: [:], subject: "An email", text: "Email body", recipients: [],
            labels: [], attachments: [], data: [:])
        let context = EventTranscriptContext(triggerID: "trigger", deliveryID: "delivery", source: .gmail,
            sourceEventID: "email", instruction: "Summarize the new email", event: event)
        let answer = ChatBlock(kind: .assistant, text: "Email summary", runID: "older-run")
        let ordinary = ChatBlock(kind: .assistant, text: "Unrelated later reply")
        let blocks = [
            ChatBlock(kind: .user, text: "Task", runID: "older-run", eventTrigger: context), answer,
            ChatBlock(kind: .user, text: "Ordinary follow-up"), ordinary,
        ]
        let cards = ChatTranscriptBuilder.taskResults(in: blocks, runs: [], session: session, profiles: [owner])
        XCTAssertEqual(Set(cards.keys), [answer.id])
        XCTAssertEqual(cards[answer.id]?.runID, "older-run")
        XCTAssertEqual(cards[answer.id]?.agentName, owner.name)
        XCTAssertNil(cards[answer.id]?.completedAt, "An event arrival time is not a completion time")
        XCTAssertNil(cards[ordinary.id])
    }

    @MainActor
    func testPrimaryTaskResultsStaySeparateWithoutAnyRunList() {
        let session = SessionSummary(id: "chat", name: "Daily check", preview: "", mtime: 1, size: 0,
            agentTriggerID: "schedule", agentKind: "schedule", agentName: "Daily check", agentPrimary: true)
        let first = ChatBlock(kind: .assistant, text: "First check result")
        let second = ChatBlock(kind: .assistant, text: "Second check result")
        let cards = ChatTranscriptBuilder.taskResults(in: [
            ChatBlock(kind: .user, text: "Scheduled check", runID: "first"), first,
            ChatBlock(kind: .user, text: "Scheduled check", runID: "second"), second,
        ], runs: [], session: session, profiles: [])
        XCTAssertEqual(Set(cards.keys), [first.id, second.id])
        XCTAssertEqual(cards[first.id]?.runID, "first")
        XCTAssertEqual(cards[second.id]?.runID, "second")
    }

    @MainActor
    func testActivityResultRevealClearsOnNavigationAndOlderExpiryCannotClearANewerResult() throws {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        model.installTranscriptSession("chat", blocks: [])
        let first = ActivityResultReveal(sessionID: "chat", runID: "first", blockID: UUID())
        let second = ActivityResultReveal(sessionID: "chat", runID: "second", blockID: UUID())
        model.activityResultReveal = second
        model.finishActivityResultReveal(first.id)
        XCTAssertEqual(model.activityResultReveal, second)
        model.finishActivityResultReveal(second.id)
        XCTAssertNil(model.activityResultReveal)
        model.activityResultReveal = second
        model.pendingActivityResultRun = try activityNavigationRun(id: "second", sessionID: "chat")
        model.installTranscriptSession("another-chat", blocks: [])
        XCTAssertNil(model.activityResultReveal)
        XCTAssertNil(model.pendingActivityResultRun)
    }

    @MainActor
    func testActivityNavigationRevealsAnArchivedChatHiddenBySearchAndCollapsedFolders() async throws {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        let selected = try activityNavigationRun(id: "archived-run", sessionID: "archived-chat")
        let session = SessionSummary(id: "archived-chat", name: "Saved chat", preview: "", mtime: 1, size: 0,
            title: "Saved chat", archived: true, folderID: "child")
        model.sessions = [session]
        model.sessionCatalog.replaceChatFolders([
            ChatFolderRecord(id: "parent", workspace: "/tmp", parentID: nil, name: "Parent", order: 0),
            ChatFolderRecord(id: "child", workspace: "/tmp", parentID: "parent", name: "Child", order: 0),
        ])
        model.searchQuery = "does not match"
        model.showArchivedSessions = false
        XCTAssertTrue(model.sessionCatalog.snapshot.filteredSessions.isEmpty)
        try stubActivityNavigation(selected)

        model.openActivityRun(selected)

        XCTAssertEqual(model.currentSessionID, session.id)
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertTrue(model.showArchivedSessions)
        XCTAssertEqual(model.sessionCatalog.snapshot.filteredSessions.map(\.id), [session.id])
        XCTAssertTrue(model.sessionCatalog.snapshot.expandedChatFolderIDs.isSuperset(of: ["parent", "child"]))
        XCTAssertEqual(model.sessionCatalog.sessionReveal?.sessionID, session.id)
        XCTAssertTrue(model.sessions[0].isArchived, "Revealing a chat must not change its saved archive status")
        if let load = model.activeTranscriptLoad { await load.task.value }
        await model.refreshOrchestrationRuns(select: selected.id)
    }

    @MainActor
    func testActivityNavigationLooksUpMissingCachedChatAndPreservesItsSavedAgent() async throws {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        let owner = AgentProfile(name: "Jinbei")
        let other = AgentProfile(name: "Luffy")
        model.agentProfiles = [owner, other]
        model.selectedSavedAgentID = other.id
        model.installTranscriptSession("previous-chat", blocks: [])
        var selected = try activityNavigationRun(id: "older-run", sessionID: "older-chat")
        selected.scheduleID = "schedule-1"
        selected.occurrenceID = "occurrence-1"
        BackendStub.respond(toPath: "/api/sessions/older-chat") { _ in
            ["id": "older-chat", "messages": [], "preview": "Older result", "title": "Older task",
             "agent_profile_id": owner.id.uuidString, "archived": true]
        }
        try stubActivityNavigation(selected)
        let revealed = expectation(description: "The exact missing chat was looked up and revealed")
        let observation = model.sessionCatalog.$sessionReveal.compactMap { $0 }
            .filter { $0.sessionID == "older-chat" }.first().sink { _ in revealed.fulfill() }

        model.openActivityRun(selected)
        await fulfillment(of: [revealed], timeout: 3)
        observation.cancel()

        XCTAssertTrue(BackendStub.requestPaths.contains("/api/sessions/older-chat"))
        XCTAssertEqual(model.currentSessionID, "older-chat")
        XCTAssertEqual(model.sessions.first?.savedAgentProfileID, owner.id)
        XCTAssertEqual(model.sessions.first?.agentTriggerID, "schedule-1")
        XCTAssertEqual(model.sessions.first?.agentKind, "schedule")
        XCTAssertEqual(model.selectedSavedAgentID, owner.id)
        XCTAssertEqual(model.sidebarDestination, .agents)
        XCTAssertEqual(model.selectedOrchestrationRun?.id, "older-run")
        XCTAssertEqual(model.runsNavigationRequest?.runID, "older-run")
        if let load = model.activeTranscriptLoad { await load.task.value }
        await model.refreshOrchestrationRuns(select: selected.id)
    }

    @MainActor
    func testActivityNavigationLeavesAnUnavailableWorkspaceResultUnread() throws {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        model.installTranscriptSession("current-chat", blocks: [])
        let selected = try activityNavigationRun(id: "unavailable-run", sessionID: "unavailable-chat")
        model.sessions = [SessionSummary(id: "unavailable-chat", name: "Unavailable", preview: "", mtime: 1, size: 0,
            cwd: "/nonexistent-locus-activity-test-\(UUID().uuidString)")]
        model.activity.activityCenterPresented = true

        model.openActivityRun(selected)

        XCTAssertEqual(model.currentSessionID, "current-chat")
        XCTAssertTrue(model.activity.activityIsUnseen(selected))
        XCTAssertTrue(model.activity.activityCenterPresented)
        XCTAssertNil(model.sessionCatalog.sessionReveal)
        XCTAssertNil(model.selectedOrchestrationRun)
        XCTAssertEqual(model.toastMessage, "That chat's workspace is no longer available")
        XCTAssertNoBackendTraffic()
    }

    @MainActor
    func testActivityCompletionRequiresTheChatToActuallyBeVisible() {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        model.installTranscriptSession("viewed-chat", blocks: [])
        XCTAssertEqual(model.activityViewedSessionID(appIsActive: true), "viewed-chat")
        XCTAssertNil(model.activityViewedSessionID(appIsActive: false))
        model.overviewPresented = true
        XCTAssertEqual(model.activityViewedSessionID(appIsActive: true), "viewed-chat", "The side overview keeps the chat visible")
        model.library.isPresented = true
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
        model.library.isPresented = false
        model.activity.activityCenterPresented = true
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
        model.activity.activityCenterPresented = false
        model.agentCrewChatPresented = true
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
        model.agentCrewChatPresented = false
        model.savedAgentOverviewID = UUID()
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
        model.savedAgentOverviewID = nil
        model.emptySidebarDestination = .agents
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
        model.emptySidebarDestination = nil
        model.settingsPresented = true
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
        model.settingsPresented = false
        _ = model.beginTranscriptSessionLoad("loading-chat")
        XCTAssertNil(model.activityViewedSessionID(appIsActive: true))
    }

    @MainActor
    func testActivityCompletionSuppressesOnlyTheExactLiveRunViewedWhenItFinishes() {
        let model = activityNavigationModel()
        defer { stopActivityNavigationModel(model) }
        model.installTranscriptSession("viewed-chat", blocks: [])
        model.isBusy = true
        model.orchestrationRunID = "current-run"
        model.taskConversationStates["viewed-chat"] = TaskConversationState(
            sessionID: "viewed-chat", runID: "current-run", state: .running, updatedAt: Date())
        model.taskConversationStates["background-chat"] = TaskConversationState(
            sessionID: "background-chat", runID: "background-run", state: .running, updatedAt: Date())

        model.recordActivityCompletion(["type": "turn_done", "run_id": "old-run", "reason": "complete"],
            sessionID: "viewed-chat", appIsActive: true)
        model.recordActivityCompletion(["type": "turn_done", "run_id": "background-run", "reason": "complete"],
            sessionID: "background-chat", appIsActive: true)
        model.recordActivityCompletion(["type": "turn_done", "run_id": "current-run", "reason": "complete"],
            sessionID: "viewed-chat", appIsActive: true)

        XCTAssertEqual(model.activity.dismissedActivityRunIDs, ["current-run"])
        model.installTranscriptSession("background-chat", blocks: [])
        model.orchestrationRunID = "background-run"
        model.recordActivityCompletion(["type": "orchestration_completed", "run_id": "background-run", "state": "completed"],
            sessionID: "background-chat", appIsActive: true)
        XCTAssertEqual(model.activity.dismissedActivityRunIDs, ["current-run"], "A later view cannot reclassify the background completion")
    }

    @MainActor
    private func activityNavigationModel() -> AppModel {
        BackendStub.reset()
        return AppModel(startImmediately: false, backendOverride: stubbedBackendService())
    }

    @MainActor
    private func stopActivityNavigationModel(_ model: AppModel) {
        model.activeTranscriptLoad?.task.cancel()
        model.runs.cancelAll()
        model.knowledge.cancelAll()
        model.agentInstructions.cancelAll()
        model.transcriptSearch.cancelAll()
        model.eventAutomations.stop()
        model.toastCenter.cancelPendingDismissal()
    }

    private func activityNavigationRun(id: String, sessionID: String, updatedAt: Double = 10,
                                       fields: [String: Any] = [:]) throws -> OrchestrationRun {
        let base: [String: Any] = [
            "id": id, "session_id": sessionID, "state": "completed", "request": "Saved result",
            "created_at": 1, "updated_at": updatedAt, "last_seq": 0, "pinned": false,
            "legacy": false, "recoverable": false, "run_kind": "solo",
        ]
        return try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(
            withJSONObject: base.merging(fields) { _, field in field }))
    }

    private func stubActivityNavigation(_ run: OrchestrationRun, list: [OrchestrationRun]? = nil,
                                        messages: [[String: Any]] = []) throws {
        let sessionID = try XCTUnwrap(run.sessionID)
        let detail = try JSONEncoder().encode(run)
        let runs = try JSONEncoder().encode(OrchestrationRunsResponse(runs: list ?? [run], readOnly: false))
        BackendStub.respond(toPath: "/api/sessions/\(sessionID)/resume") { _ in
            ["ok": true, "messages": messages, "session_info": ["session_id": sessionID, "cwd": "/tmp", "model": "fixture"]]
        }
        BackendStub.respond(toPath: "/api/orchestrations") { _ in runs }
        BackendStub.respond(toPath: "/api/orchestrations/\(run.id)") { _ in detail }
        BackendStub.respond(toPath: "/api/orchestrations/\(run.id)/events") { _ in
            ["run_id": run.id, "events": [], "last_seq": 0]
        }
    }

    private static func snapshot(total: Int, cursor: String? = nil) -> AgentInspectorSnapshot {
        AgentInspectorSnapshot(history: AgentInspectorHistory(
            total: total, counts: ["completed": total], nextCursor: cursor
        ))
    }

    private static func slotPage(_ ids: ClosedRange<Int>, state: String, cursor: String?) -> AgentInspectorSnapshot {
        let slots = ids.reversed().map { index in
            ScheduleOccurrence(id: "slot-\(index)", scheduleID: "shared-id", scheduleName: "Review",
                scheduledFor: Double(index), trigger: "due", state: state, sessionID: nil,
                runID: nil, error: nil, createdAt: Double(index), updatedAt: Double(index))
        }
        return AgentInspectorSnapshot(history: AgentInspectorHistory(
            occurrences: slots, total: 100, counts: [state: 100], nextCursor: cursor
        ))
    }
}

private enum LoadFailure: Error { case offline }
