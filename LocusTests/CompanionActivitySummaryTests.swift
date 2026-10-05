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

    func testPrimaryCompanionUsesDedicatedHomeWithoutBorrowingCenterOrOtherAgentActivity() throws {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let primary = AgentProfile(name: "Companion", model: "", role: .generalist)
        let other = AgentProfile(name: "Other", model: "", role: .generalist)
        model.agentProfiles = [primary, other]
        try model.agentTeamsModel.commitCompanion(.init(existingProfileID: primary.id))
        model.initialWorkspacePath = "/tmp/activity-center"
        let home = model.savedAgentHomePath(primary)
        model.sessions = [
            activitySession("home", owner: primary.id, workspace: home),
            activitySession("center", owner: primary.id, workspace: model.workspacePath),
            activitySession("other-home", owner: other.id, workspace: home),
            activitySession("other-center", owner: other.id, workspace: model.workspacePath),
        ]
        model.taskConversationStates = [
            "home": .init(sessionID: "home", runID: "home-run", state: .waitingPermission, updatedAt: Date()),
            "center": .init(sessionID: "center", runID: "center-run", state: .failed, updatedAt: Date()),
            "other-home": .init(sessionID: "other-home", runID: "other-home-run", state: .failed, updatedAt: Date()),
            "other-center": .init(sessionID: "other-center", runID: "other-center-run", state: .queued, updatedAt: Date()),
        ]
        let source = CompanionActivityPresentation(app: model)
        let summary = model.companionActivitySummary(profileID: primary.id)
        XCTAssertEqual(summary.execution, .needsApproval)
        XCTAssertEqual(summary.approvalCount, 1)
        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertEqual(model.companionActivitySummary(profileID: other.id).queuedCount, 1)
        XCTAssertEqual(source.scopeID(profileID: primary.id), SessionSummary.canonicalWorkspacePath(home))
        XCTAssertEqual(source.scopeID(profileID: other.id), SessionSummary.canonicalWorkspacePath(model.workspacePath))

        model.initialWorkspacePath = "/tmp/another-center"
        XCTAssertEqual(model.companionActivitySummary(profileID: primary.id), summary)
        XCTAssertEqual(source.scopeID(profileID: primary.id), SessionSummary.canonicalWorkspacePath(home))
        XCTAssertEqual(model.companionActivitySummary(profileID: other.id).queuedCount, 0)
    }

    func testExplicitCompanionFolderScopesUnreadAndCompletionWithoutReplayingHistory() throws {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        var profile = AgentProfile(name: "Companion", model: "", role: .generalist,
                                   workspacePreferences: .init(defaultProjectPath: "/tmp/first-companion"))
        model.agentProfiles = [profile]
        try model.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        model.initialWorkspacePath = "/tmp/unrelated-center"
        model.sessions = [
            activitySession("first", owner: profile.id, workspace: "/tmp/first-companion"),
            activitySession("second", owner: profile.id, workspace: "/tmp/second-companion"),
        ]
        model.activity.activityRuns = [
            activityRun("first-run", owner: profile.id, workspace: "/tmp/first-companion", sessionID: "first"),
            activityRun("second-run", owner: profile.id, workspace: "/tmp/second-companion", sessionID: "second"),
        ]
        for id in ["first-run", "second-run"] {
            model.activity.recordCompletion(runID: id, succeeded: true, wasRunning: true, isViewed: false)
        }
        let source = CompanionActivityPresentation(app: model)
        let first = try XCTUnwrap(source.summary(profileID: profile.id))
        XCTAssertEqual(first.unreadCount, 1)
        XCTAssertEqual(first.latestCompletion?.runID, "first-run")
        let firstScope = source.scopeID(profileID: profile.id)
        var gate = CompanionCompletionReactionGate()
        gate.establishBaseline(scopeID: firstScope, event: first.latestCompletion)

        profile.workspacePreferences?.defaultProjectPath = "/tmp/second-companion"
        model.agentTeamsModel.saveAgentProfile(profile)
        let second = try XCTUnwrap(source.summary(profileID: profile.id))
        XCTAssertEqual(second.unreadCount, 1)
        XCTAssertEqual(second.latestCompletion?.runID, "second-run")
        XCTAssertNotEqual(source.scopeID(profileID: profile.id), firstScope)
        XCTAssertFalse(gate.receive(scopeID: source.scopeID(profileID: profile.id), event: second.latestCompletion))
        XCTAssertEqual(model.workspacePath, "/tmp/unrelated-center")
    }

    func testUnlistedRunsAndAttentionRequireCompanionFolderAndProfileOwnership() throws {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let profile = AgentProfile(name: "Companion", model: "", role: .generalist,
                                   workspacePreferences: .init(defaultProjectPath: "/tmp/companion-activity"))
        model.agentProfiles = [profile]
        try model.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        model.initialWorkspacePath = "/tmp/center-activity"
        model.activity.activityRuns = [
            activityRun("owned", owner: profile.id, workspace: "/tmp/companion-activity", state: "failed"),
            activityRun("other-project", owner: profile.id, workspace: "/tmp/center-activity", state: "failed"),
            activityRun("other-profile", owner: UUID(), workspace: "/tmp/companion-activity", state: "failed"),
        ]
        let decisions = ["owned", "other-project", "other-profile"].map { id in
            AttentionItem(id: "decision-\(id)", kind: "permission_request", group: .decisions,
                          runID: id, title: "Permission", detail: "Review", actions: ["open_chat"])
        }
        model.activity.configure(backend: stubbedBackendService(), liveAttentionProvider: { decisions }, toastHandler: { _ in })
        let summary = model.companionActivitySummary(profileID: profile.id)
        XCTAssertEqual(summary.approvalCount, 1)
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.unreadCount, 1)
    }

    func testCanonicalSessionOwnerAndFolderOverrideConflictingManifest() throws {
        let model = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        let root = "/tmp/companion-canonical"
        let profile = AgentProfile(name: "Companion", model: "", role: .generalist,
                                   workspacePreferences: .init(defaultProjectPath: root))
        model.agentProfiles = [profile]
        try model.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        let otherID = UUID()
        model.sessions = [
            activitySession("owned", owner: profile.id, workspace: root),
            activitySession("other-owner", owner: otherID, workspace: root),
            activitySession("other-folder", owner: profile.id, workspace: "/tmp/foreign-project"),
            SessionSummary(id: "unowned", name: "Unowned", preview: "", mtime: 1, size: 0, cwd: root),
        ]
        model.activity.activityRuns = [
            activityRun("valid", owner: otherID, workspace: "/tmp/stale-root", sessionID: "owned"),
            activityRun("wrong-owner", owner: profile.id, workspace: root, sessionID: "other-owner"),
            activityRun("wrong-folder", owner: profile.id, workspace: root, sessionID: "other-folder"),
            activityRun("no-owner", owner: profile.id, workspace: root, sessionID: "unowned"),
        ]
        XCTAssertEqual(model.activity.activityRuns.filter {
            model.companionActivityIncludes($0, profileID: profile.id)
        }.map(\.id), ["valid"])
        XCTAssertEqual(model.companionActivitySummary(profileID: profile.id).unreadCount, 1)
    }

    private func activitySession(_ id: String, owner: UUID, workspace: String) -> SessionSummary {
        SessionSummary(id: id, name: id, preview: "", mtime: 1, size: 0,
                       cwd: workspace, agentProfileID: owner.uuidString)
    }

    private func activityRun(_ id: String, owner: UUID, workspace: String,
                             sessionID: String? = nil, state: String = "completed") -> OrchestrationRun {
        var value: [String: Any] = [
            "id": id, "workspace_root": workspace, "state": state, "request": "Fixture",
            "created_at": 1.0, "updated_at": 2.0, "last_seq": 1, "pinned": false,
            "legacy": false, "recoverable": false, "manifest": ["agent_profile_id": owner.uuidString],
        ]
        if let sessionID { value["session_id"] = sessionID }
        return decode(OrchestrationRun.self, from: value)!
    }
}
