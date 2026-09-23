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

    func testProfileActivityKeepsSameIDEventAndScheduleOwnersSeparate() {
        let inboxOwner = UUID(), scheduleOwner = UUID()
        let sessions = [
            ownedChat("inbox-chat", profileID: inboxOwner, kind: "event"),
            ownedChat("schedule-chat", profileID: scheduleOwner, kind: "schedule"),
        ]
        let records = AgentActivityRecord.merged(
            deliveries: [delivery("inbox-failure", state: "failed")],
            occurrences: [occurrence("schedule-success")], definitions: definitions)

        let inboxActivity = AgentActivityRecord.scoped(records, to: inboxOwner,
            sessions: sessions, definitions: definitions)
        XCTAssertEqual(inboxActivity.map(\.id), ["event:inbox-failure"])
        XCTAssertTrue(inboxActivity.allSatisfy(AgentActivityFilter.attention.includes))
        let scheduleActivity = AgentActivityRecord.scoped(records, to: scheduleOwner,
            sessions: sessions, definitions: definitions)
        XCTAssertEqual(scheduleActivity.map(\.id), ["schedule:schedule-success"])
        XCTAssertTrue(scheduleActivity.filter(AgentActivityFilter.attention.includes).isEmpty)
        XCTAssertEqual(AgentActivityRecord.scoped(records, to: nil,
            sessions: sessions, definitions: definitions).map(\.id), records.map(\.id))
    }

    func testProfileWithNoKnownAutomationOwnershipNeverFallsBackToGlobalActivity() {
        let owner = UUID()
        let records = AgentActivityRecord.merged(deliveries: [delivery("other-agent")],
            occurrences: [occurrence("other-schedule")], definitions: definitions)
        XCTAssertTrue(AgentActivityRecord.scoped(records, to: owner,
            sessions: [], definitions: definitions).isEmpty)
        // A manual chat does not claim an unrelated automation just because it
        // shares this profile. Legacy ambiguous identities are also not guessed.
        let sessions = [
            SessionSummary(id: "manual", name: "manual", preview: "", mtime: 1, size: 0,
                agentProfileID: owner.uuidString),
            ownedChat("ambiguous", profileID: owner, kind: nil),
        ]
        XCTAssertTrue(AgentActivityRecord.scoped(records, to: owner,
            sessions: sessions, definitions: definitions).isEmpty)
    }

    func testProfileActivityRetainsArchivedChatOwnershipAfterAutomationRemoval() {
        let owner = UUID()
        let sessions = [ownedChat("archived", profileID: owner, kind: "event", archived: true)]
        let records = AgentActivityRecord.merged(deliveries: [delivery("removed-inbox")],
            occurrences: [occurrence("unrelated-removed-schedule")], definitions: [])
        let activity = AgentActivityRecord.scoped(records, to: owner, sessions: sessions, definitions: [])
        XCTAssertEqual(activity.map(\.id), ["event:removed-inbox"])
        XCTAssertEqual(activity.first?.agentName, "Removed Agent")
    }

    func testSavedOverviewReadyWithoutAutomationsDoesNotInventResults() {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let manual = SessionSummary(id: "manual", name: "manual", preview: "User prompt is not a result",
            mtime: 20, size: 0, agentProfileID: profile.id.uuidString)
        let snapshot = overview(profile, sessions: [manual])
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertFalse(snapshot.needsAttention)
        XCTAssertFalse(snapshot.isBusy)
        XCTAssertTrue(snapshot.automations.isEmpty)
        XCTAssertTrue(snapshot.connections.isEmpty)
        XCTAssertNil(snapshot.latestResult)
        XCTAssertEqual(snapshot.chats.map(\.id), ["manual"])
    }

    func testSavedOverviewBusyAndAttentionOnlyUseOwnedConversations() {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("own", profileID: profile.id, kind: "schedule")
        let other = ownedChat("other", profileID: UUID(), kind: "event")
        let quiet = overview(profile, sessions: [own, other], running: ["other"], attention: ["other"])
        XCTAssertEqual(quiet.status, .ready)
        let busy = overview(profile, sessions: [own, other], running: ["own"], attention: ["other"])
        XCTAssertEqual(busy.status, .working)
        XCTAssertTrue(busy.isBusy)
        XCTAssertFalse(busy.needsAttention)
        let waiting = overview(profile, sessions: [own, other], running: ["own"], attention: ["own"])
        XCTAssertEqual(waiting.status, .needsAttention)
        XCTAssertTrue(waiting.isBusy)
        XCTAssertEqual(waiting.issues.first?.action, .chat("own"))
    }

    func testSavedOverviewMissingAccountAndModelAvailabilityAreExplicit() {
        let account = ProviderAccount(kind: .chatGPT, name: "Exact account")
        let profile = AgentProfile(name: "Reader", route: .providerAccount(account.id), model: "saved-model")
        let missing = overview(profile)
        XCTAssertEqual(missing.status, .needsAttention)
        XCTAssertEqual(missing.route.accountID, account.id)
        XCTAssertEqual(missing.issues.first?.action, .manageAccount(account.id))
        let wrongModel = overview(profile, accounts: [account], models: [account.id: ["other-model"]],
            statuses: [account.id: .connected(models: 1)])
        XCTAssertFalse(wrongModel.route.isVerified)
        XCTAssertTrue(wrongModel.route.issue?.contains("saved-model") == true)
        let ready = overview(profile, accounts: [account], models: [account.id: ["SAVED-MODEL"]],
            statuses: [account.id: .signedIn(email: nil, plan: nil)])
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.route.title, account.displayName)
    }

    func testSavedOverviewUnknownCredentialsAreNotCalledVerifiedOrFailed() {
        let account = ProviderAccount(kind: .claude, name: "Research")
        let profile = AgentProfile(name: "Reader", route: .providerAccount(account.id), model: "fixture")
        let observations: [[UUID: ProviderAccountStatus]] = [[:], [account.id: .keySaved]]
        for statuses in observations {
            let snapshot = overview(profile, accounts: [account], statuses: statuses)
            XCTAssertEqual(snapshot.status, .unverified)
            XCTAssertFalse(snapshot.route.isVerified)
            XCTAssertFalse(snapshot.needsAttention)
            XCTAssertTrue(snapshot.route.detail.contains("not checked"))
        }
        let signedOut = overview(profile, accounts: [account], statuses: [account.id: .signedOut])
        XCTAssertEqual(signedOut.route.issue, "Not signed in")
        XCTAssertTrue(signedOut.needsAttention)
        let noObservations = SavedAgentOverviewSnapshot.resolve(profile: profile, sessions: [],
            definitions: [], connections: [], deliveries: [], occurrences: [], accounts: [account],
            readyAccountIDs: [])
        XCTAssertEqual(noObservations.status, .unverified)
        XCTAssertNil(noObservations.route.issue)
        XCTAssertFalse(noObservations.needsAttention)
    }

    func testSavedOverviewShowsOnlyRequiredConnectionHealthIncludingMissingServices() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "event")
        var trigger = try XCTUnwrap(definitions.first?.trigger)
        trigger.actionConnectionIDs = ["missing-action"]
        let good = connection("gmail")
        let unrelated = connection("unrelated", health: "failed")
        let snapshot = overview(profile, sessions: [own], definitions: [.trigger(trigger)],
            connections: [good, unrelated])
        XCTAssertEqual(Set(snapshot.connections.map(\.id)), ["gmail", "missing-action"])
        XCTAssertEqual(snapshot.connections.first { $0.id == "gmail" }?.isHealthy, true)
        XCTAssertEqual(snapshot.connections.first { $0.id == "missing-action" }?.needsAttention, true)
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertEqual(snapshot.issues.first?.action, .connections)
        let disabled = overview(profile, sessions: [own], definitions: definitions,
            connections: [connection("gmail", enabled: false)])
        XCTAssertEqual(disabled.connections.first?.detail, "Disabled")
        XCTAssertTrue(disabled.needsAttention)
    }

    func testSavedOverviewPausedSchedulesAreQuietUntilAnActualFailure() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "schedule")
        var schedule = try XCTUnwrap(definitions.last?.schedule)
        schedule.enabled = false
        schedule.nextRunAt = 100
        let paused = overview(profile, sessions: [own], definitions: [.schedule(schedule)],
            occurrences: [occurrence("success")])
        XCTAssertEqual(paused.status, .paused)
        XCTAssertFalse(paused.needsAttention)
        XCTAssertNil(paused.automations.first?.nextRunAt)
        XCTAssertEqual(paused.latestResult?.state, "completed")
        schedule.lastError = "The workspace needs reconnecting"
        let failed = overview(profile, sessions: [own], definitions: [.schedule(schedule)])
        XCTAssertEqual(failed.status, .needsAttention)
        XCTAssertEqual(failed.automations.first?.statusTitle, "Needs attention")
        XCTAssertEqual(failed.issues.first?.action, .automation(.init(kind: .schedule, agentID: schedule.id)))
    }

    func testSavedOverviewPendingDecisionShowsReviewWithoutRetryOrResume() {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "event")
        let snapshot = overview(profile, sessions: [own], definitions: definitions,
            connections: [connection("gmail")],
            deliveries: [delivery("pending-review", state: "completed", runState: "waiting_permission")])
        XCTAssertEqual(snapshot.status, .needsAttention)
        XCTAssertEqual(snapshot.latestResult?.statusTitle, "Needs your approval")
        XCTAssertEqual(snapshot.latestResult?.action,
            .activity(.event(.init(kind: .event, agentID: "same-agent"), deliveryID: "pending-review")))
    }

    func testSavedOverviewArchiveKeepsTypedHistoryAndNeverBorrowsOtherProfile() {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let sessions = [ownedChat("chat", profileID: profile.id, kind: "event", archived: true),
                        ownedChat("other", profileID: UUID(), kind: "schedule")]
        let snapshot = overview(profile, sessions: sessions, definitions: definitions,
            connections: [connection("gmail")], deliveries: [delivery("owned")],
            occurrences: [occurrence("foreign", at: 999)])
        XCTAssertEqual(snapshot.automations.map(\.reference), [.init(kind: .event, agentID: "same-agent")])
        XCTAssertEqual(snapshot.latestResult?.id, "event:owned")
        XCTAssertTrue(snapshot.chats.isEmpty)
        let removed = overview(profile, sessions: sessions, deliveries: [delivery("retained")])
        XCTAssertTrue(removed.automations.isEmpty)
        XCTAssertEqual(removed.latestResult?.id, "event:retained")
    }

    func testSavedOverviewReassignedAutomationDoesNotExposeForeignHistory() {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let sessions = [ownedChat("former", profileID: profile.id, kind: "event", archived: true),
                        ownedChat("chat", profileID: UUID(), kind: "event")]
        let snapshot = overview(profile, sessions: sessions, definitions: definitions,
            deliveries: [delivery("foreign-result", state: "failed", error: "Other agent error")])
        XCTAssertTrue(snapshot.automations.isEmpty)
        XCTAssertNil(snapshot.latestResult)
        XCTAssertFalse(snapshot.needsAttention)
    }

    func testSavedOverviewWorkspaceScopesChatsButPreservesWholeAgentAutomation() {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let sessions = [SessionSummary(id: "here", name: "here", preview: "", mtime: 2, size: 0,
            cwd: "/tmp/here", agentProfileID: profile.id.uuidString),
            SessionSummary(id: "chat", name: "there", preview: "", mtime: 3, size: 0,
                cwd: "/tmp/there", agentTriggerID: "same-agent", agentProfileID: profile.id.uuidString,
                agentKind: "schedule")]
        let snapshot = overview(profile, sessions: sessions, definitions: definitions, workspace: "/tmp/here")
        XCTAssertEqual(snapshot.chats.map(\.id), ["here"])
        XCTAssertEqual(snapshot.automations.map(\.reference), [.init(kind: .schedule, agentID: "same-agent")])
    }

    func testSavedOverviewResultUsesExactRunFinalAnswerAndBoundsDisplay() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "schedule")
        let saved = try transcript("chat", profile: profile.id, messages: [
            ["role": "assistant", "phase": "final_answer", "run_id": "old-run", "content": "Old answer"],
            ["role": "assistant", "phase": "final_answer", "run_id": "run", "content": String(repeating: "a", count: 2_050)],
            ["role": "assistant", "phase": "commentary", "run_id": "run", "content": "Not a final answer"],
            ["role": "user", "run_id": "run", "content": "Not output"],
            ["role": "assistant", "phase": "final_answer", "run_id": "different-run", "content": "Another answer"],
        ])
        let snapshot = overview(profile, sessions: [own], definitions: definitions,
            occurrences: [occurrence("result")], transcript: saved)
        XCTAssertEqual(snapshot.resultSessionID, "chat")
        XCTAssertEqual(snapshot.latestResult?.summary, String(repeating: "a", count: 2_000))
        XCTAssertEqual(snapshot.latestResult?.fullResponse, String(repeating: "a", count: 2_050))
        XCTAssertEqual(snapshot.latestResult?.runID, "run")
    }

    func testSavedOverviewNeverBorrowsAnotherAttemptOrChangedSessionOwner() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "schedule")
        let candidates = [
            try transcript("chat", profile: profile.id, messages: [
                ["role": "assistant", "run_id": "old-run", "content": "Wrong attempt"]]),
            try transcript("chat", profile: UUID(), messages: [
                ["role": "assistant", "run_id": "run", "content": "Wrong owner"]]),
            try transcript("another-chat", profile: profile.id, messages: [
                ["role": "assistant", "run_id": "run", "content": "Wrong chat"]]),
        ]
        for candidate in candidates {
            let snapshot = overview(profile, sessions: [own], definitions: definitions,
                occurrences: [occurrence("result")], transcript: candidate)
            XCTAssertTrue(snapshot.latestResult?.summary.hasPrefix("No saved output") == true)
            XCTAssertNil(snapshot.latestResult?.fullResponse)
        }
    }

    func testSavedOverviewManualConversationCanShowActualFinalOutputWithoutRunHistory() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = SessionSummary(id: "manual", name: "manual", preview: "User request", mtime: 50,
            size: 0, agentProfileID: profile.id.uuidString)
        let saved = try transcript("manual", profile: profile.id, messages: [
            ["role": "user", "content": "User request"],
            ["role": "assistant", "phase": "final_answer", "content": "The temperature is 21°C."],
        ])
        let snapshot = overview(profile, sessions: [own], transcript: saved)
        XCTAssertEqual(snapshot.resultSessionID, "manual")
        XCTAssertEqual(snapshot.latestResult?.summary, "The temperature is 21°C.")
        XCTAssertEqual(snapshot.latestResult?.statusTitle, "Saved response")
        XCTAssertEqual(snapshot.latestResult?.action, .chat("manual"))
    }

    func testSavedOverviewNewerAutomationOutcomeWinsOverManualChatAndOldFailure() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let manual = SessionSummary(id: "manual", name: "manual", preview: "", mtime: 10,
            size: 0, agentProfileID: profile.id.uuidString)
        let schedule = ownedChat("chat", profileID: profile.id, kind: "schedule")
        let saved = try transcript("manual", profile: profile.id, messages: [
            ["role": "assistant", "content": "An older manual result"],
        ])
        let snapshot = overview(profile, sessions: [manual, schedule], definitions: definitions,
            occurrences: [occurrence("failure", state: "failed", at: 20, error: "Old failure"),
                          occurrence("retry-success", at: 30)], transcript: saved)
        XCTAssertEqual(snapshot.resultSessionID, "chat")
        XCTAssertEqual(snapshot.latestResult?.id, "schedule:retry-success")
        XCTAssertFalse(snapshot.needsAttention)
        XCTAssertFalse(snapshot.latestResult?.summary.contains("manual") == true)
    }

    func testSavedOverviewReceiptFailureIsNotHiddenByItsPreviousCompletedRun() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "event")
        let saved = try transcript("chat", profile: profile.id, messages: [
            ["role": "assistant", "run_id": "run", "content": "Previous handoff output"],
        ])
        let snapshot = overview(profile, sessions: [own], definitions: definitions,
            connections: [connection("gmail")],
            deliveries: [delivery("failed-retry", state: "failed", receivedAt: 40, error: "Retry could not start")],
            runs: [try run("run", sessionID: "chat", state: "completed", at: 30)], transcript: saved)
        XCTAssertEqual(snapshot.latestResult?.state, "failed")
        XCTAssertEqual(snapshot.latestResult?.summary, "Retry could not start")
        XCTAssertNil(snapshot.latestResult?.fullResponse)
        XCTAssertTrue(snapshot.latestResult?.needsAttention == true)
        XCTAssertFalse(snapshot.needsAttention, "Historical failure is not a current blocker after its warning is cleared")
    }

    func testSavedOverviewLoadedRunEnrichesOnlyExactOwnedActivity() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "schedule")
        let waiting = overview(profile, sessions: [own], definitions: definitions,
            occurrences: [occurrence("receipt")],
            runs: [try run("run", sessionID: "chat", state: "waiting_permission", at: 60),
                   try run("foreign", sessionID: "other", state: "failed", at: 100)])
        XCTAssertEqual(waiting.latestResult?.id, "schedule:receipt")
        XCTAssertEqual(waiting.latestResult?.state, "waiting_permission")
        XCTAssertEqual(waiting.latestResult?.timestamp, Date(timeIntervalSince1970: 60))
        XCTAssertTrue(waiting.needsAttention)
        XCTAssertEqual(waiting.latestResult?.runID, "run")
    }

    func testSavedOverviewKnownOccurrenceWithoutRunCannotBorrowTranscriptOutput() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "schedule")
        let receipt = ScheduleOccurrence(id: "no-run", scheduleID: "same-agent", scheduleName: "Morning agent",
            scheduledFor: 20, trigger: "due", state: "completed", sessionID: "chat", runID: nil,
            error: nil, createdAt: 20, updatedAt: 21)
        let saved = try transcript("chat", profile: profile.id, messages: [
            ["role": "assistant", "content": "Another attempt's output"],
        ])
        let snapshot = overview(profile, sessions: [own], definitions: definitions,
            occurrences: [receipt], transcript: saved)
        XCTAssertNil(snapshot.latestResult?.runID)
        XCTAssertTrue(snapshot.latestResult?.summary.hasPrefix("No saved output") == true)
    }

    func testReconnectedAgentDoesNotPromoteClearedDeliveryFailureIntoCurrentHealth() throws {
        let account = ProviderAccount(kind: .claudePlan, name: "Claude Test")
        let profile = AgentProfile(name: "Garp", route: .providerAccount(account.id), model: "opus[1m]")
        let own = ownedChat("chat", profileID: profile.id, kind: "event")
        let oldError = "Claude Test does not report opus[1m]. Choose an available model."
        let snapshot = overview(profile, sessions: [own], definitions: definitions,
            connections: [connection("gmail")], deliveries: [delivery("old", state: "failed", error: oldError)],
            accounts: [account], models: [account.id: ["opus[1m]"]], statuses: [account.id: .signedIn(email: nil, plan: nil)])
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertTrue(snapshot.route.isVerified)
        XCTAssertEqual(snapshot.automations.first?.statusTitle, "Listening")
        XCTAssertEqual(snapshot.latestResult?.summary, oldError, "History remains accurate")
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testReconnectedAgentKeepsExplicitWorkflowRecoveryWithoutCallingModelUnavailable() {
        let profile = AgentProfile(name: "Garp", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "event")
        let recovery = AttentionItem(id: "recovery", kind: "workflow_failure", group: .recoveries,
            sessionID: "chat", runID: "run", workflowExecutionID: "workflow",
            automationKind: "event", automationID: "same-agent", title: "Workflow failed",
            detail: "Old model was unavailable", actions: ["retry", "cancel"])
        let snapshot = overview(profile, sessions: [own], definitions: definitions,
            connections: [connection("gmail")], deliveries: [delivery("old", state: "failed", error: "Old model was unavailable")],
            attention: ["chat"], attentionItems: [recovery])
        XCTAssertEqual(snapshot.status, .needsAttention)
        XCTAssertEqual(snapshot.detail, "Connected now. Earlier work still needs review.")
        XCTAssertEqual(snapshot.issues.count, 1, "No duplicate conversation warning")
        XCTAssertEqual(snapshot.issues.first?.action, .attention(.workflow("workflow")))
        XCTAssertFalse(snapshot.issues.first?.detail.contains("unavailable") == true)
    }

    func testRecoveryCannotLeakFromAnotherAgentOrReappearAfterDismissal() {
        let profile = AgentProfile(name: "Garp", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: "event")
        let foreign = AttentionItem(id: "foreign", kind: "workflow_failure", group: .recoveries,
            sessionID: "another-chat", workflowExecutionID: "other-workflow",
            automationKind: "event", automationID: "same-agent", title: "Other failure", detail: "Other error", actions: ["retry"])
        for items in [[foreign], []] {
            let snapshot = overview(profile, sessions: [own], definitions: definitions,
                connections: [connection("gmail")], deliveries: [delivery("old", state: "failed", error: "Old error")],
                attentionItems: items)
            XCTAssertEqual(snapshot.status, .ready)
            XCTAssertTrue(snapshot.issues.isEmpty)
        }
    }

    func testWaitingManualRunRemainsActionableWithoutAttentionInbox() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: nil)
        for state in ["waiting_permission", "waiting_computer", "waiting_dispatch_approval"] {
            let snapshot = overview(profile, sessions: [own], runs: [
                try run("waiting", sessionID: "chat", state: state, at: 60),
                try run("foreign", sessionID: "other-chat", state: state, at: 100),
            ])
            XCTAssertEqual(snapshot.status, .needsAttention)
            XCTAssertEqual(snapshot.issues.count, 1)
            XCTAssertEqual(snapshot.issues.first?.action, .attention(.run("waiting")))
            XCTAssertFalse(snapshot.detail.contains("Earlier work"))
        }
    }

    func testWaitingRunFallbackDoesNotDuplicateDetailedRequestOrPersistAfterCompletion() throws {
        let profile = AgentProfile(name: "Reader", model: "fixture")
        let own = ownedChat("chat", profileID: profile.id, kind: nil)
        let request = AttentionItem(id: "permission", kind: "permission_request", group: .decisions,
            sessionID: "chat", runID: "run", title: "Read website", detail: "Allow this website request?",
            actions: ["allow_once", "deny"])
        let waiting = overview(profile, sessions: [own],
            runs: [try run("run", sessionID: "chat", state: "waiting_permission", at: 60)],
            attentionItems: [request])
        XCTAssertEqual(waiting.issues.count, 1)
        XCTAssertEqual(waiting.issues.first?.detail, request.detail)
        let completed = overview(profile, sessions: [own],
            runs: [try run("run", sessionID: "chat", state: "completed", at: 70)])
        XCTAssertEqual(completed.status, .ready)
        XCTAssertTrue(completed.issues.isEmpty)
    }

    func testResultExcerptKeepsReadableMarkdownHierarchyAndEmphasis() {
        let excerpt = SavedAgentResultExcerpt("""
        Reviewed **three messages**. See [the source](https://example.com) and `invoice.pdf`.

        ## Next steps
        - Review the draft.
        - Send it when ready.
        - This remains in the full result.
        """)
        XCTAssertEqual(excerpt.lines.map(\.text), [
            "Reviewed three messages. See the source and invoice.pdf.", "Next steps",
            "Review the draft.", "Send it when ready.",
        ])
        XCTAssertEqual(excerpt.lines.map(\.kind), [.body, .heading, .list("•"), .list("•")])
        XCTAssertTrue(excerpt.lines[0].runs.contains { $0.text == "three messages" && $0.style.contains(.strong) })
        XCTAssertFalse(excerpt.lines[0].text.contains("https://"))
    }

    func testResultExcerptKeepsOrderedAndTaskListMeaning() {
        let ordered = SavedAgentResultExcerpt("3. Review\n4. Send")
        XCTAssertEqual(ordered.lines.map(\.kind), [.list("3."), .list("4.")])
        let tasks = SavedAgentResultExcerpt("- [x] Read\n- [ ] Reply")
        XCTAssertEqual(tasks.lines.map(\.kind), [.list("☑"), .list("☐")])
        let excerpt = SavedAgentResultExcerpt("First.\n\nSecond.\n\nThird.\n\n## More\n\nFourth.")
        XCTAssertEqual(excerpt.lines.map(\.text), ["First.", "Second.", "Third."])
    }

    func testResultExcerptHandlesTablesCodeAndEmptyOutput() {
        XCTAssertTrue(SavedAgentResultExcerpt("").lines.isEmpty)
        let table = SavedAgentResultExcerpt("| Item | State |\n| --- | --- |\n| Draft | Ready |")
        XCTAssertEqual(table.lines.map(\.text), ["Item · State", "Draft · Ready"])
        XCTAssertEqual(table.lines.first?.kind, .table)
        let code = SavedAgentResultExcerpt("```swift\nlet ready = true\n```")
        XCTAssertEqual(code.lines.first?.kind, .code)
        XCTAssertTrue(code.lines.first?.text.contains("let ready = true") == true)
    }

    private func overview(
        _ profile: AgentProfile, sessions: [SessionSummary] = [], definitions: [AgentDefinition] = [],
        connections: [ConnectorConnection] = [], deliveries: [EventDelivery] = [],
        occurrences: [ScheduleOccurrence] = [], runs: [OrchestrationRun] = [],
        accounts: [ProviderAccount] = [], models: [UUID: [String]] = [:],
        statuses: [UUID: ProviderAccountStatus] = [:], running: Set<String> = [],
        attention: Set<String> = [], attentionItems: [AttentionItem] = [], workspace: String? = nil,
        transcript: SavedAgentOverviewSnapshot.ResultTranscript? = nil
    ) -> SavedAgentOverviewSnapshot {
        .resolve(profile: profile, sessions: sessions, definitions: definitions, connections: connections,
            deliveries: deliveries, occurrences: occurrences, runs: runs, accounts: accounts,
            readyAccountIDs: Set(accounts.map(\.id)), accountModels: models, accountStatuses: statuses,
            localModels: ["fixture"], runningSessionIDs: running, attentionSessionIDs: attention, attentionItems: attentionItems,
            workspace: workspace, resultTranscript: transcript)
    }

    private func transcript(_ id: String, profile: UUID, messages: [[String: Any]]) throws -> SavedAgentOverviewSnapshot.ResultTranscript {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "agent_profile_id": profile.uuidString, "messages": messages])
        return try JSONDecoder().decode(SavedAgentOverviewSnapshot.ResultTranscript.self, from: data)
    }

    private func run(_ id: String, sessionID: String, state: String, at: Double) throws -> OrchestrationRun {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "session_id": sessionID, "state": state, "request": "Fixture request",
            "created_at": 1, "updated_at": at, "last_seq": 0,
            "pinned": false, "legacy": false, "recoverable": false,
        ])
        return try JSONDecoder().decode(OrchestrationRun.self, from: data)
    }

    private func connection(_ id: String, enabled: Bool = true, health: String = "connected") -> ConnectorConnection {
        ConnectorConnection(id: id, kind: .gmail, displayName: id, publicConfig: [:], cursor: [:],
            enabled: enabled, health: health, createdAt: 1, updatedAt: 1)
    }

    private func ownedChat(_ id: String, profileID: UUID, kind: String?, archived: Bool = false) -> SessionSummary {
        SessionSummary(id: id, name: id, preview: "", mtime: 1, size: 0,
            archived: archived, agentTriggerID: "same-agent", agentProfileID: profileID.uuidString,
            agentKind: kind)
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
