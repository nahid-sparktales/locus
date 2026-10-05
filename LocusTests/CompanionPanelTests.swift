import Combine
import Foundation
import XCTest
@testable import Locus

@MainActor
final class CompanionPanelTests: XCTestCase {
    func testOpeningAndLoadingPanelPreservesCentralDraftTaskAndApproval() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.isBusy = true
        app.handleEventForTesting(["type": "permission_request", "id": "tool", "tool": "write_file", "request_id": "center-approval"])
        let ownership = app.transcriptPresentation.sessionOwnershipToken
        let blocks = app.blocks.map(\.id)
        app.openCompanionDestination()
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.profileID, profile.id)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.sidebarDestination, .ask)
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.activePermissionRequest?.requestID, "center-approval")
        XCTAssertEqual(app.blocks.map(\.id), blocks)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, ownership)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") || $0 == "/api/sessions/detached" })
        app.companionPanel.draft = "Independent draft"
        app.companionPanel.activate()
        XCTAssertEqual(app.companionPanel.draft, "Independent draft")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testFailedLoadRetriesWithoutTouchingCenter() async throws {
        let (app, _, _) = try fixture(failures: 1)
        defer { cleanup(app) }
        app.companionPanel.activate()
        XCTAssertFalse(app.companionPanel.canRetryLoading, "An in-flight read cannot be restarted")
        await app.companionPanel.loadTask?.value
        XCTAssertNotNil(app.companionPanel.error)
        XCTAssertTrue(app.companionPanel.blocks.isEmpty)
        XCTAssertTrue(app.companionPanel.canRetryLoading)
        app.companionPanel.retryLoading()
        await app.companionPanel.loadTask?.value
        XCTAssertNil(app.companionPanel.error)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertFalse(app.companionPanel.canRetryLoading, "A loaded transcript does not show Retry")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testActualOwnerWorkspaceAndArchiveAreValidatedBeforeDisplaying() async throws {
        for mismatch in ["owner", "workspace", "archive"] {
            let (app, _, chat) = try fixture(mismatch: mismatch)
            defer { cleanup(app) }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
            XCTAssertNotNil(app.companionPanel.error, mismatch)
            XCTAssertTrue(app.companionPanel.blocks.isEmpty, mismatch)
            XCTAssertNil(app.splitPaneBlocks[chat.id], mismatch)
            XCTAssertFalse(app.companionPanel.canSend)
        }
    }

    func testLateReadCannotDisplayAFormerExplicitCompanionFolder() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        let oldTask = app.companionPanel.loadTask
        app.selectCompanionWorkspace("/var/tmp")
        await oldTask?.value
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/var/tmp"))
        XCTAssertNil(app.companionPanel.selectedSessionID)
        XCTAssertTrue(app.companionPanel.blocks.isEmpty)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testCenterProjectChangesDoNotChangeCompanionSelectionOrDraft() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Independent companion draft"
        let requestCount = CompanionPanelURLProtocol.paths().count
        app.initialWorkspacePath = "/var/tmp"
        app.pendingWorkspacePath = "/different-center-project"
        app.companionPanel.activate()
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Independent companion draft")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().count, requestCount)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testConversationArtifactsUseExecutionFolderWithoutChangingCompanionScope() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        let execution = "/tmp/companion-execution"
        let executingChat = SessionSummary(id: chat.id, name: chat.name, preview: "", mtime: 1, size: 0,
                                           cwd: execution, workspaceRoot: "/tmp", executionPath: execution,
                                           agentProfileID: profile.id.uuidString)
        app.sessions = app.sessions.map { $0.id == chat.id ? executingChat : $0 }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.conversationWorkspacePath, execution)
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.companionWorkspacePath, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.initialWorkspacePath, "/tmp")
        app.selectCompanionWorkspace("/var/tmp")
        XCTAssertEqual(app.companionPanel.conversationWorkspacePath,
                       SessionSummary.canonicalWorkspacePath("/var/tmp"), "Stale execution paths cannot escape the selected scope")
    }

    func testExplicitFolderChangeCancelsStaleSendPreflightWithoutLosingDraft() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep in the original folder"
        app.companionPanel.send()
        let oldSubmission = app.companionPanel.sendingTask
        app.selectCompanionWorkspace("/var/tmp")
        await oldSubmission?.value
        XCTAssertFalse(dispatched)
        XCTAssertNil(app.companionPanel.selectedSessionID)
        XCTAssertEqual(app.paneDraft(for: chat.id), "Keep in the original folder")
        XCTAssertEqual(app.currentSessionID, "center")
        app.selectCompanionWorkspace("/tmp")
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Keep in the original folder")
    }

    func testSendingUsesCapturedCanonicalScopeAndPreservesCenterAndLaterEdits() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        var captured: (String, String, UUID, String, WorkMode)?
        app.companionPanel.configure(app: app) { id, workspace, owner, text, mode in
            captured = (id, workspace, owner, text, mode)
            app.companionPanel.draft = "Later edit"
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "  Hello companion  "
        app.companionPanel.mode = .ask
        app.isBusy = true
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(captured?.0, chat.id)
        XCTAssertEqual(captured?.1, SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(captured?.2, profile.id)
        XCTAssertEqual(captured?.3, "Hello companion")
        XCTAssertEqual(captured?.4, .ask)
        XCTAssertEqual(app.companionPanel.draft, "Later edit")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
    }

    func testFailedSendPreservesPanelDraftAndCentralExecutionAndProvider() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.configure(app: app) { _, _, _, _, _ in
            throw SavedAgentConversationError.unavailable("Fixture provider unavailable")
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep after failure"
        app.isBusy = true
        app.orchestrationRunID = "central-run"
        app.orchestrationState = .running
        let provider = app.settings.activeAccountID
        let selectedModel = app.selectedModel
        let owner = app.transcriptPresentation.sessionOwnershipToken
        app.companionPanel.send()
        await app.companionPanel.sendingTask?.value
        XCTAssertEqual(app.companionPanel.error, "Fixture provider unavailable")
        XCTAssertFalse(app.companionPanel.canRetryLoading, "A send failure is not a transcript load failure")
        XCTAssertEqual(app.companionPanel.draft, "Keep after failure")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertEqual(app.orchestrationRunID, "central-run")
        XCTAssertEqual(app.orchestrationState, .running)
        XCTAssertEqual(app.selectedModel, selectedModel)
        XCTAssertEqual(app.settings.activeAccountID, provider)
        XCTAssertEqual(app.transcriptPresentation.sessionOwnershipToken, owner)
    }

    func testStoppingAnotherSelectionDoesNotCancelPendingSubmission() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        let other = SessionSummary(id: "other", name: "Other", preview: "", mtime: 0, size: 0,
                                   cwd: "/tmp", agentProfileID: profile.id.uuidString)
        app.sessions.append(other)
        let enteredDispatch = expectation(description: "First chat awaits normal admission")
        var continuation: CheckedContinuation<Void, Never>?
        var firstSubmissionWasCancelled = false
        app.companionPanel.configure(app: app) { _, _, _, _, _ in
            await withCheckedContinuation { continuation = $0; enteredDispatch.fulfill() }
            firstSubmissionWasCancelled = Task.isCancelled
        }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "First submission"
        app.companionPanel.send()
        let firstTask = app.companionPanel.sendingTask
        await fulfillment(of: [enteredDispatch], timeout: 2)
        defer { continuation?.resume() }
        XCTAssertTrue(app.companionPanel.isSending)
        app.companionPanel.select(other)
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(app.companionPanel.selectedSessionID, other.id)
        XCTAssertFalse(app.companionPanel.isSending, "Another chat's admission is not this chat's state")
        XCTAssertNil(app.companionPanel.sendingTask)
        app.companionPanel.draft = "Second chat draft"
        app.companionPanel.stop()
        let pending = try XCTUnwrap(continuation)
        continuation = nil
        pending.resume()
        await firstTask?.value
        XCTAssertFalse(firstSubmissionWasCancelled)
        XCTAssertEqual(app.companionPanel.draft, "Second chat draft")
        XCTAssertEqual(app.paneDraft(for: chat.id), "", "Only the accepted first draft is cleared")
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testCatalogOnlyRenamePublishesPanelHistoryWithoutReloadingTranscript() async throws {
        let (app, profile, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Preserved draft"
        var publications = 0
        let observation = app.companionPanel.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        let renamed = SessionSummary(id: chat.id, name: "Renamed", preview: "", mtime: 2, size: 0,
                                     cwd: "/tmp", agentProfileID: profile.id.uuidString)
        let requestCount = CompanionPanelURLProtocol.paths().count
        app.sessions = app.sessions.map { $0.id == chat.id ? renamed : $0 }
        XCTAssertGreaterThan(publications, 0)
        XCTAssertEqual(app.companionPanel.chats.first?.name, "Renamed")
        XCTAssertEqual(app.companionPanel.selectedSessionID, chat.id)
        XCTAssertEqual(app.companionPanel.draft, "Preserved draft")
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Saved companion answer")
        XCTAssertEqual(CompanionPanelURLProtocol.paths().count, requestCount)
    }

    func testCatalogRemovalArchiveOrOwnershipChangeImmediatelyHidesPrivateSelection() async throws {
        for change in ["remove", "archive", "owner", "workspace", "deleted-profile"] {
            let (app, profile, chat) = try fixture()
            defer { cleanup(app) }
            app.companionPanel.activate()
            await app.companionPanel.loadTask?.value
            app.companionPanel.draft = "Private draft"
            if change == "deleted-profile" {
                app.agentProfiles = []
                app.companionPanel.activate()
            } else if change == "remove" {
                app.sessions.removeAll { $0.id == chat.id }
            } else {
                let updated = SessionSummary(id: chat.id, name: chat.name, preview: "", mtime: 1, size: 0,
                                             archived: change == "archive",
                                             cwd: change == "workspace" ? "/var/tmp" : "/tmp",
                                             agentProfileID: (change == "owner" ? UUID() : profile.id).uuidString)
                app.sessions = app.sessions.map { $0.id == chat.id ? updated : $0 }
            }
            XCTAssertNil(app.companionPanel.selectedSessionID, change)
            XCTAssertTrue(app.companionPanel.blocks.isEmpty, change)
            XCTAssertEqual(app.companionPanel.draft, "", change)
            XCTAssertFalse(app.companionPanel.canSend, change)
            XCTAssertEqual(app.currentSessionID, "center", change)
            XCTAssertEqual(app.draftText, "Central draft", change)
        }
    }

    func testExistingBackgroundWorkerPublishesStreamingAndApprovalStateToPanel() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        let runtime = ChatWorkerRuntime(requestedSessionID: chat.id, workspacePath: "/tmp",
                                        process: BackendProcess(), endpoint: URL(string: "http://127.0.0.1:9")!)
        app.taskWorkers[chat.id] = runtime
        defer { app.taskWorkers[chat.id] = nil; runtime.stop() }
        var publications = 0
        let observation = app.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        runtime.streamingBlockID = UUID()
        runtime.streamingText = "Live worker output"
        runtime.executionState = .running
        app.updateBackgroundChatState(runtime)
        XCTAssertGreaterThan(publications, 0, "The panel observes AppModel's existing worker publications")
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Live worker output")
        XCTAssertEqual(app.companionPanel.blocks.last?.isStreaming, true)
        XCTAssertEqual(app.companionPanel.state.status, "working")
        runtime.pendingForegroundEvent = ["type": "permission_request", "request_id": "panel-approval"]
        runtime.executionState = .waitingPermission
        app.updateBackgroundChatState(runtime)
        XCTAssertEqual(app.companionPanel.state.status, "needs_attention")
        XCTAssertFalse(app.companionPanel.canSend)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertFalse(app.hasPendingPermission, "Background approval does not replace the center's permission state")
    }

    func testNoModelOrOfflineSendNeverDispatchesOrClearsDraft() async throws {
        let (app, _, _) = try fixture()
        defer { cleanup(app) }
        var dispatched = false
        app.companionPanel.configure(app: app) { _, _, _, _, _ in dispatched = true }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.draft = "Keep this draft"
        app.agentProfiles[0].model = ""
        XCTAssertNotNil(app.companionPanel.availabilityIssue)
        app.companionPanel.send()
        app.agentProfiles[0].model = "fixture"
        app.agentRuntimePhase = .unavailable("Offline")
        app.companionPanel.send()
        XCTAssertFalse(dispatched)
        XCTAssertEqual(app.companionPanel.draft, "Keep this draft")
        XCTAssertNil(app.companionPanel.sendingTask)
    }

    func testExplicitCreateIsIdempotentAndDoesNotReconcileCenter() async throws {
        let (app, profile, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.isBusy = true
        app.companionPanel.createConversation()
        app.companionPanel.createConversation()
        await app.companionPanel.creationTask?.value
        await app.companionPanel.loadTask?.value
        XCTAssertEqual(CompanionPanelURLProtocol.paths().filter { $0 == "/api/sessions/detached" }.count, 1)
        XCTAssertEqual(app.companionPanel.selectedSessionID, "companion-created")
        XCTAssertEqual(app.savedAgentProfileID(for: "companion-created"), profile.id)
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertTrue(app.isBusy)
        XCTAssertNil(app.activeTranscriptLoad)
        XCTAssertNil(app.companionPanel.error)
        XCTAssertFalse(CompanionPanelURLProtocol.paths().contains { $0.hasSuffix("/resume") || $0 == "/api/runs/queue" })
    }

    func testLateCreationStaysInItsFolderHistoryWithoutSelectingNewCompanionFolder() async throws {
        let (app, profile, _) = try fixture()
        defer { cleanup(app) }
        app.companionPanel.activate()
        await app.companionPanel.loadTask?.value
        app.companionPanel.createConversation()
        app.selectCompanionWorkspace("/var/tmp")
        await app.companionPanel.creationTask?.value
        XCTAssertNil(app.companionPanel.selectedSessionID)
        XCTAssertEqual(app.companionPanel.workspace, SessionSummary.canonicalWorkspacePath("/var/tmp"))
        XCTAssertEqual(app.savedAgentProfileID(for: "companion-created"), profile.id)
        XCTAssertEqual(app.sessions.first { $0.id == "companion-created" }?.workspacePath,
                       SessionSummary.canonicalWorkspacePath("/tmp"))
        XCTAssertEqual(app.currentSessionID, "center")
        XCTAssertEqual(app.draftText, "Central draft")
    }

    func testForegroundConversationIsReadOnlyInPanel() async throws {
        let (app, _, chat) = try fixture()
        defer { cleanup(app) }
        app.installTranscriptSession(chat.id, blocks: [ChatBlock(kind: .assistant, text: "Live central answer")])
        app.companionPanel.activate()
        XCTAssertNil(app.companionPanel.selectedSessionID)
        app.companionPanel.select(chat)
        await app.companionPanel.loadTask?.value
        XCTAssertTrue(app.companionPanel.isForegroundConversation)
        XCTAssertEqual(app.companionPanel.blocks.last?.text, "Live central answer")
        app.companionPanel.draft = "Do not replace center"
        app.companionPanel.send()
        app.companionPanel.stop()
        XCTAssertEqual(app.draftText, "Central draft")
        XCTAssertFalse(app.companionPanel.canSend)
        XCTAssertNil(app.companionPanel.sendingTask)
    }

    private func fixture(failures: Int = 0, mismatch: String? = nil) throws -> (AppModel, AgentProfile, SessionSummary) {
        let profile = AgentProfile(name: "Pitou", model: "fixture", workspacePreferences: .init(defaultProjectPath: "/tmp"))
        let chat = SessionSummary(id: "companion", name: "Companion", preview: "", mtime: 1, size: 0,
                                  cwd: "/tmp", agentProfileID: profile.id.uuidString)
        CompanionPanelURLProtocol.reset(profileID: profile.id, failures: failures, mismatch: mismatch)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompanionPanelURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!, session: URLSession(configuration: config))
        let app = AppModel(startImmediately: false, backendOverride: backend)
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        app.sessions = [chat, SessionSummary(id: "center", name: "Center", preview: "", mtime: 2, size: 0, cwd: "/tmp")]
        app.initialWorkspacePath = "/tmp"
        app.installTranscriptSession("center", blocks: [ChatBlock(kind: .assistant, text: "Central work")])
        app.draftText = "Central draft"
        app.agentRuntimePhase = .online
        return (app, profile, chat)
    }

    private func cleanup(_ app: AppModel) {
        app.companionPanel.loadTask?.cancel()
        app.companionPanel.creationTask?.cancel()
        app.companionPanel.sendingTask?.cancel()
        app.knowledge.cancelAll()
        app.agentInstructions.cancelAll()
        app.toastCenter.cancelPendingDismissal()
    }
}

private final class CompanionPanelURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var profileID = UUID()
    private static var failures = 0
    private static var mismatch: String?
    private static var requestedPaths: [String] = []
    private static var created = false
    static func reset(profileID: UUID, failures: Int, mismatch: String?) {
        lock.lock(); defer { lock.unlock() }
        self.profileID = profileID; self.failures = failures; self.mismatch = mismatch; requestedPaths = []; created = false
    }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return requestedPaths }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        Self.requestedPaths.append(path)
        let status = Self.failures > 0 ? 503 : 200
        Self.failures = max(0, Self.failures - 1)
        let owner = Self.mismatch == "owner" ? UUID() : Self.profileID
        let workspace = Self.mismatch == "workspace" ? "/var/tmp" : "/tmp"
        let archived = Self.mismatch == "archive"
        let payload: [String: Any]
        if status == 503 {
            payload = ["detail": "Temporary fixture failure"]
        } else if path == "/api/sessions/detached" {
            Self.created = true
            payload = ["session_id": "companion-created"]
        } else if path == "/api/sessions" {
            let ids = Self.created ? ["companion", "companion-created"] : ["companion"]
            let rows = ids.map { id -> [String: Any] in
                ["id": id, "name": id, "preview": "", "mtime": 1, "size": 0,
                 "cwd": "/tmp", "agent_profile_id": Self.profileID.uuidString]
            }
            payload = ["sessions": rows, "current": "must-not-replace-center"]
        } else {
            payload = ["id": request.url!.lastPathComponent, "preview": "", "cwd": workspace,
                       "archived": archived, "agent_profile_id": owner.uuidString,
                       "messages": [["role": "assistant", "content": "Saved companion answer"]]]
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
}
