import Foundation
import XCTest
@testable import Locus

@MainActor
final class CompanionActivitySummaryTests: XCTestCase {
    private let ready = CompanionActivitySummary.Availability(runtimeConnected: true, modelConnected: true, detail: "Ready on this Mac")

    func testMultipleTasksRetainApprovalsFailuresAndUnreadSeparately() {
        let summary = CompanionActivitySummary.make(availability: ready, runs: [
            .init(id: "active", state: .running, updatedAt: 10),
            .init(id: "decision", state: .waitingPermission, updatedAt: 10),
            .init(id: "failed", state: .failed, updatedAt: 8, unread: true),
            .init(id: "queued", state: .queued, updatedAt: 10),
        ], approvalRunIDs: ["decision"])
        XCTAssertEqual(summary.execution, .needsApproval)
        XCTAssertEqual(summary.approvalCount, 1)
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.workingCount, 1)
        XCTAssertEqual(summary.queuedCount, 1)
        XCTAssertEqual(summary.unreadCount, 1)
    }

    func testAvailabilityDoesNotEraseExecutionOrUnreadTruth() {
        let disconnected = CompanionActivitySummary.Availability(runtimeConnected: false, modelConnected: false, detail: "Reconnecting")
        let summary = CompanionActivitySummary.make(availability: disconnected,
            runs: [.init(id: "r", state: .waitingPermission, updatedAt: 1)])
        XCTAssertFalse(summary.availability.isAvailable)
        XCTAssertEqual(summary.execution, .needsApproval)
        XCTAssertEqual(summary.approvalCount, 1)
        XCTAssertEqual(CompanionActivitySummary.make(availability: disconnected, runs: []).statusText, "Reconnecting")
    }

    func testStaleLiveCachesCannotResurrectCompletedRun() {
        let history = CompanionActivitySummary.Run(id: "r", state: .completed, updatedAt: 20, sequence: 8, unread: true)
        let stale = CompanionActivitySummary.Run(id: "r", state: .running, updatedAt: 999)
        let first = CompanionActivitySummary.make(availability: ready, runs: [history, stale])
        let second = CompanionActivitySummary.make(availability: ready, runs: [stale, history])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.execution, .idle)
        XCTAssertEqual(first.unreadCount, 1)
        XCTAssertNil(first.latestCompletion)
    }

    func testQueuedPausedFailedAndWorkingAreDistinct() {
        for (state, expected) in [(TeamRunState.queued, CompanionActivitySummary.Execution.queued),
                                  (.paused, .paused), (.failed, .failed), (.running, .working), (.completed, .idle)] {
            XCTAssertEqual(CompanionActivitySummary.make(availability: ready,
                runs: [.init(id: "r", state: state, updatedAt: 1)]).execution, expected)
        }
    }

    func testCompletionIsLiveUniqueAndSurvivesReconnectDeduplication() {
        let suite = "CompanionCompletionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let activity = ActivityCenterModel()
        activity.restore(persistenceEnabled: true, defaults: defaults)
        activity.recordCompletion(runID: "r", succeeded: true, wasRunning: true, isViewed: false)
        let original = activity.liveCompletionEvents["r"]
        XCTAssertNotNil(original)
        activity.recordCompletion(runID: "r", succeeded: true, wasRunning: true, isViewed: false)
        XCTAssertEqual(activity.liveCompletionEvents["r"], original)
        let restored = ActivityCenterModel()
        restored.restore(persistenceEnabled: true, defaults: defaults)
        restored.recordCompletion(runID: "r", succeeded: true, wasRunning: true, isViewed: false)
        XCTAssertTrue(restored.liveCompletionEvents.isEmpty)
        restored.recordCompletion(runID: "old", succeeded: true, wasRunning: false, isViewed: false)
        restored.recordCompletion(runID: "failed", succeeded: false, wasRunning: true, isViewed: false)
        XCTAssertTrue(restored.liveCompletionEvents.isEmpty)
    }

    func testCompletionEventsCannotCrossAgentRunOwnership() {
        let summary = CompanionActivitySummary.make(availability: ready,
            runs: [.init(id: "owned", state: .completed, updatedAt: 1)],
            completionEvents: [.init(runID: "other", occurredAt: Date())])
        XCTAssertNil(summary.latestCompletion)
    }

    func testPreviewRejectsInvalidOrOversizedPayload() {
        XCTAssertThrowsError(try CompanionPortraitPreviewResponse(pngBase64: "not-base64").normalizedImage())
        let active = Data("<svg onload='bad()'/>".utf8).base64EncodedString()
        XCTAssertThrowsError(try CompanionPortraitPreviewResponse(pngBase64: active).normalizedImage())
    }

    func testReactionMountScopeChangesAndRepeatedRefreshNeverReplayCompletion() {
        let now = Date()
        let old = ActivityCompletionEvent(runID: "old", occurredAt: now)
        let fresh = ActivityCompletionEvent(runID: "fresh", occurredAt: now)
        var gate = CompanionCompletionReactionGate()
        gate.establishBaseline(scopeID: "project-a", event: old)
        XCTAssertFalse(gate.receive(scopeID: "project-a", event: old, now: now))
        XCTAssertTrue(gate.receive(scopeID: "project-a", event: fresh, now: now))
        XCTAssertFalse(gate.receive(scopeID: "project-a", event: fresh, now: now))
        XCTAssertFalse(gate.receive(scopeID: "project-b", event: fresh, now: now))
        XCTAssertFalse(gate.receive(scopeID: "project-a", event: fresh, now: now))
        var remounted = CompanionCompletionReactionGate()
        remounted.establishBaseline(scopeID: "project-a", event: fresh)
        XCTAssertFalse(remounted.receive(scopeID: "project-a", event: fresh, now: now))
        XCTAssertFalse(remounted.receive(scopeID: "project-a",
            event: .init(runID: "stale", occurredAt: now.addingTimeInterval(-4)), now: now))
    }

    func testSavedAgentAvailabilityDoesNotBorrowAnotherProfilesOnlineModel() {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let profile = AgentProfile(name: "No model", model: "", role: .generalist)
        model.agentProfiles = [profile]
        model.agentRuntimePhase = .online
        model.modelRuntimePhase = .online
        XCTAssertFalse(model.companionActivitySummary(profileID: profile.id).availability.modelConnected)
        XCTAssertEqual(model.companionActivitySummary(profileID: profile.id).pose, .unavailable)
    }

    func testLiveActivityStaysWithItsProfileAndWorkspace() {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let first = AgentProfile(name: "First", model: "", role: .generalist)
        let second = AgentProfile(name: "Second", model: "", role: .generalist)
        model.agentProfiles = [first, second]
        model.sessionInfo = SessionInfo(model: "m", host: "localhost", cwd: "/tmp/companion-one",
            session: "s", sessionID: "s", messages: 0, approxTokens: 0, promptTokens: 0,
            completionTokens: 0, contextLimit: 0, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: []))
        model.sessionCatalog.replaceSessions([
            SessionSummary(id: "one", name: "one", preview: "", mtime: 1, size: 0,
                cwd: "/tmp/companion-one", agentProfileID: first.id.uuidString),
            SessionSummary(id: "two", name: "two", preview: "", mtime: 1, size: 0,
                cwd: "/tmp/companion-two", agentProfileID: first.id.uuidString),
            SessionSummary(id: "other", name: "other", preview: "", mtime: 1, size: 0,
                cwd: "/tmp/companion-one", agentProfileID: second.id.uuidString),
        ])
        model.taskConversationStates = [
            "one": .init(sessionID: "one", runID: "run-one", state: .queued, updatedAt: Date()),
            "two": .init(sessionID: "two", runID: "run-two", state: .waitingPermission, updatedAt: Date()),
            "other": .init(sessionID: "other", runID: "run-other", state: .failed, updatedAt: Date()),
        ]
        let summary = model.companionActivitySummary(profileID: first.id)
        XCTAssertEqual(summary.execution, .queued)
        XCTAssertEqual(summary.approvalCount, 0)
        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertEqual(summary.queuedCount, 1)
    }
}
