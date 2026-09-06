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
