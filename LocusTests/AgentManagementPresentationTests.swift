import Foundation
import XCTest
@testable import Locus

final class AgentManagementPresentationTests: XCTestCase {
    func testMergedActivitySortsByTimeAndKeepsCollidingProvenanceSeparate() {
        let records = AgentActivityRecord.merged(
            deliveries: [delivery("shared", receivedAt: 20), delivery("newest", receivedAt: 30)],
            occurrences: [occurrence("shared", at: 20), occurrence("oldest", at: 10)],
            definitions: definitions
        )
        XCTAssertEqual(records.map(\.id), ["event:newest", "event:shared", "schedule:shared", "schedule:oldest"])
        let event = records[1]
        let schedule = records[2]
        XCTAssertEqual(event.agent, AgentInspectorAgent(kind: .event, agentID: "same-agent"))
        XCTAssertEqual(schedule.agent, AgentInspectorAgent(kind: .schedule, agentID: "same-agent"))
        XCTAssertEqual(event.agentName, "Inbox agent")
        XCTAssertEqual(schedule.agentName, "Morning agent")
        XCTAssertEqual(event.context, .event(event.agent, deliveryID: "shared"))
        XCTAssertEqual(schedule.context, .occurrence(schedule.agent, occurrenceID: "shared"))
        XCTAssertNotNil(event.delivery)
        XCTAssertNil(schedule.delivery)
    }

    func testCompletedReceiptShowsTheExecutionStillRunningOrWaiting() throws {
        for runState in ["running", "waiting_permission", "waiting_computer", "failed"] {
            let record = try eventRecord(delivery("receipt", state: "completed", runState: runState))
            XCTAssertEqual(record.state, runState)
            XCTAssertEqual(record.isInProgress, runState == "running")
            XCTAssertEqual(record.needsAttention, runState != "running")
            XCTAssertFalse(AgentActivityFilter.completed.includes(record))
        }
        let running = try eventRecord(delivery("running", state: "completed", runState: "running"))
        XCTAssertEqual(running.statusTitle, "Running")
        let waiting = try eventRecord(delivery("waiting", state: "completed", runState: "waiting_permission"))
        XCTAssertEqual(waiting.statusTitle, "Needs your approval")
        XCTAssertEqual(waiting.symbol, "exclamationmark.circle.fill")
    }

    func testTerminalReceiptFailuresOverrideStaleExecutionState() throws {
        for state in ["failed", "interrupted", "cancelled", "skipped"] {
            let record = try eventRecord(delivery("terminal", state: state, runState: "running"))
            XCTAssertEqual(record.state, state)
            XCTAssertFalse(record.isInProgress)
        }
        let failed = try eventRecord(delivery("failed", state: "failed", runState: "completed"))
        XCTAssertEqual(failed.statusTitle, "Failed")
        XCTAssertTrue(failed.needsAttention)
    }

    func testMissingExecutionStateFallsBackToReceiptState() throws {
        for runState in [String?.none, ""] {
            let record = try eventRecord(delivery("queued", state: "queued", runState: runState))
            XCTAssertEqual(record.state, "queued")
            XCTAssertTrue(record.isInProgress)
            XCTAssertEqual(record.statusTitle, "Waiting to start")
        }
    }

    func testSkippedScheduleWithOverlapExplanationIsANormalOutcome() throws {
        let record = try XCTUnwrap(AgentActivityRecord.merged(
            deliveries: [],
            occurrences: [occurrence("overlap", state: "skipped", error: "Previous run still active")],
            definitions: definitions
        ).first)
        XCTAssertEqual(record.error, "Previous run still active")
        XCTAssertFalse(record.needsAttention)
        XCTAssertFalse(record.isInProgress)
        XCTAssertFalse(record.canRetry)
        XCTAssertEqual(record.symbol, "forward.end.circle")
        XCTAssertFalse(AgentActivityFilter.attention.includes(record))
        XCTAssertFalse(AgentActivityFilter.completed.includes(record))
        XCTAssertTrue(AgentActivityFilter.all.includes(record))
    }

    func testRetryEligibilityUsesDeliveryStateRatherThanExecutionState() throws {
        for state in ["failed", "interrupted", "cancelled"] {
            XCTAssertTrue(try eventRecord(delivery("retry", state: state)).canRetry)
        }
        // The execution can fail after a successful handoff. Replaying its
        // receipt is not a supported delivery retry and can duplicate work.
        let executionFailure = try eventRecord(delivery("execution", state: "completed", runState: "failed"))
        XCTAssertTrue(executionFailure.needsAttention)
        XCTAssertFalse(executionFailure.canRetry)
        for state in ["pending", "queued", "running", "completed", "skipped"] {
            XCTAssertFalse(try eventRecord(delivery("no-retry", state: state)).canRetry)
        }
        let scheduleFailure = try XCTUnwrap(AgentActivityRecord.merged(
            deliveries: [], occurrences: [occurrence("failed", state: "failed")], definitions: definitions
        ).first)
        XCTAssertTrue(scheduleFailure.needsAttention)
        XCTAssertFalse(scheduleFailure.canRetry)
    }

    func testFiltersSeparateCompletedProgressAndActionableAttention() throws {
        let cases: [(String, String?, Bool, Bool, Bool)] = [
            ("completed", nil, false, false, true),
            ("completed", "Output could not be saved", true, false, false),
            ("running", nil, false, true, false),
            ("awaiting_run", nil, false, true, false),
            ("waiting_dispatch_approval", nil, true, false, false),
            ("waiting_approval", nil, true, false, false),
            ("interrupted", nil, true, false, false),
            ("cancelled", nil, false, false, false),
            ("skipped", "Overlap", false, false, false),
        ]
        for (state, error, attention, progress, completed) in cases {
            let record = try eventRecord(delivery("filter", state: state, error: error))
            XCTAssertTrue(AgentActivityFilter.all.includes(record), state)
            XCTAssertEqual(AgentActivityFilter.attention.includes(record), attention, state)
            XCTAssertEqual(AgentActivityFilter.inProgress.includes(record), progress, state)
            XCTAssertEqual(AgentActivityFilter.completed.includes(record), completed, state)
        }
    }

    func testRemovedAgentsRetainInspectableHistoricalIdentity() throws {
        let records = AgentActivityRecord.merged(
            deliveries: [delivery("old-event")], occurrences: [occurrence("old-schedule")], definitions: []
        )
        let event = try XCTUnwrap(records.first { $0.delivery != nil })
        let schedule = try XCTUnwrap(records.first { $0.delivery == nil })
        XCTAssertEqual(event.agentName, "Removed Agent")
        XCTAssertEqual(schedule.agentName, "Historical schedule name")
        XCTAssertEqual(event.context, .event(event.agent, deliveryID: "old-event"))
        XCTAssertEqual(schedule.context, .occurrence(schedule.agent, occurrenceID: "old-schedule"))
    }

    func testActivityDistinguishesManualStartsAndSourceSubjects() throws {
        let record = try eventRecord(delivery("subject"))
        XCTAssertEqual(record.title, "New invoice")
        XCTAssertEqual(record.sourceTitle, "Gmail")
        let manual = try XCTUnwrap(AgentActivityRecord.merged(
            deliveries: [], occurrences: [occurrence("manual", trigger: "manual")], definitions: definitions
        ).first)
        XCTAssertEqual(manual.title, "Started manually")
        XCTAssertEqual(manual.sourceTitle, "Schedule")
    }

    private func eventRecord(_ delivery: EventDelivery) throws -> AgentActivityRecord {
        try XCTUnwrap(AgentActivityRecord.merged(
            deliveries: [delivery], occurrences: [], definitions: definitions
        ).first)
    }

    private func delivery(
        _ id: String, state: String = "completed", runState: String? = nil,
        receivedAt: Double = 20, error: String? = nil
    ) -> EventDelivery {
        EventDelivery(
            id: id, triggerID: "same-agent", sourceEventID: "source-\(id)", source: .gmail,
            receivedAt: receivedAt, occurredAt: receivedAt - 1,
            event: InboundEvent(
                source: .gmail, sourceEventID: "source-\(id)", eventType: "email.received",
                occurredAt: receivedAt - 1, actor: [:], subject: "New invoice", text: "",
                recipients: [], labels: [], attachments: [], data: [:]
            ),
            state: state, runState: runState, attempt: 1, sessionID: "chat", runID: "run",
            error: error, createdAt: receivedAt, updatedAt: receivedAt + 1
        )
    }

    private func occurrence(
        _ id: String, state: String = "completed", at: Double = 20,
        trigger: String = "due", error: String? = nil
    ) -> ScheduleOccurrence {
        ScheduleOccurrence(
            id: id, scheduleID: "same-agent", scheduleName: "Historical schedule name",
            scheduledFor: at, trigger: trigger, state: state, sessionID: "chat", runID: "run",
            error: error, createdAt: at, updatedAt: at + 1
        )
    }

    private var definitions: [AgentDefinition] {
        [
            .trigger(EventTrigger(
                id: "same-agent", name: "Inbox agent", connectionID: "gmail", targetSessionID: "chat",
                instruction: "Review inbox", mode: .work, triggerKind: .event,
                filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [],
                enabled: true, createdAt: 1, updatedAt: 1
            )),
            .schedule(ScheduledTask(
                id: "same-agent", name: "Morning agent", prompt: "Review workspace", workspaceRoot: "/tmp/locus",
                mode: .work, executionEnvironment: .local, runner: .solo, provider: "ollama", model: "test",
                timezone: "UTC", rule: ScheduleRule(kind: .daily, hour: 9, minute: 0), enabled: true,
                createdAt: 1, updatedAt: 1
            )),
        ]
    }
}
