import XCTest
@testable import Locus

@MainActor
final class SendAcknowledgementTests: XCTestCase {
    func testAssignedModelRoutingAcknowledgesMainAndDesktopBeforeScoringAndPreservesDraftEdits() async throws {
        for desktop in [false, true] {
            for edit in ["untouched", "new text", "cleared"] {
                let started = expectation(description: "Model scoring started")
                let (app, _) = try routedCompanion(started: started)
                defer { cleanup(app) }
                app.draftText = "Submitted message"
                if desktop { app.sendCompanionDesktopMessage(sessionID: "send-fixture") }
                else { app.submitDraft() }

                XCTAssertEqual(app.draftText, "", "Model scoring must not delay composer acknowledgement")
                XCTAssertEqual(app.blocks.filter { $0.kind == .user }.map(\.text), ["Submitted message"])
                XCTAssertTrue(app.isBusy)
                let pending = try XCTUnwrap(app.pendingChatTurns["send-fixture"])
                await fulfillment(of: [started], timeout: 2)
                XCTAssertFalse(RoutingAcknowledgementProtocol.paths.contains("/api/runs/queue"))
                if edit != "untouched" { app.draftText = "Newer draft" }
                if edit == "cleared" { app.draftText = "" }
                let laterAttachment = ChatAttachment(url: URL(fileURLWithPath: "/tmp/later.txt"), kind: .text,
                                                     textContent: "For the next message")
                app.chatAttachments = [laterAttachment]
                RoutingAcknowledgementProtocol.finishScoring()
                await pending.value

                XCTAssertFalse(app.isBusy)
                XCTAssertEqual(app.draftText, edit == "untouched" ? "Submitted message" : edit == "cleared" ? "" : "Newer draft")
                XCTAssertEqual(app.chatAttachments, [laterAttachment], "Scoring must not consume a later attachment")
                XCTAssertEqual(app.blocks.filter { $0.kind == .user }.map(\.text), ["Submitted message"],
                               "A routed turn must neither duplicate nor replace its submitted row")
                let queued = try XCTUnwrap(RoutingAcknowledgementProtocol.queuedBodies.first)
                XCTAssertEqual((queued["agent_chat_route"] as? [String: Any])?["model"] as? String, "secondary")
                XCTAssertEqual((queued["agent_model_choices"] as? [[String: Any]])?.compactMap { $0["model"] as? String },
                               ["secondary", "primary"])
            }
        }
    }

    func testAssignedModelRoutingKeepsSubmittedTaskWhenNavigatingAndChangingNextTaskModel() async throws {
        let started = expectation(description: "Model scoring started")
        let (app, profile) = try routedCompanion(started: started)
        defer { cleanup(app) }
        app.draftText = "Submitted message"
        app.submitDraft()
        let pending = try XCTUnwrap(app.pendingChatTurns["send-fixture"])
        await fulfillment(of: [started], timeout: 2)
        app.settings.chatModelRoutes["send-fixture"] = ChatModelRoute(model: "next-task-pin", provider: "ollama",
            accountID: nil, profileID: profile.id, selection: "manual", established: true)
        app.installTranscriptSession("elsewhere", blocks: [])
        app.draftText = "Other chat's draft"
        RoutingAcknowledgementProtocol.finishScoring()
        await pending.value

        let queued = try XCTUnwrap(RoutingAcknowledgementProtocol.queuedBodies.first)
        XCTAssertEqual(queued["session_id"] as? String, "send-fixture")
        XCTAssertEqual((queued["agent_chat_route"] as? [String: Any])?["model"] as? String, "secondary")
        XCTAssertEqual((queued["agent_model_choices"] as? [[String: Any]])?.compactMap { $0["model"] as? String },
                       ["secondary", "primary"], "A later pin applies to the next task, not the submitted fallback pool")
        XCTAssertEqual(app.settings.chatModelRoutes["send-fixture"]?.model, "next-task-pin")
        XCTAssertEqual(app.currentSessionID, "elsewhere")
        XCTAssertEqual(app.draftText, "Other chat's draft")
        XCTAssertTrue(app.blocks.isEmpty)
    }

    func testStoppingAssignedModelScoringCannotAdmitTheForegroundTurn() async throws {
        let started = expectation(description: "Model scoring started")
        let (app, _) = try routedCompanion(started: started)
        defer { cleanup(app) }
        app.draftText = "Submitted message"
        app.submitDraft()
        let pending = try XCTUnwrap(app.pendingChatTurns["send-fixture"])
        await fulfillment(of: [started], timeout: 2)
        app.stop()
        RoutingAcknowledgementProtocol.finishScoring()
        await pending.value
        XCTAssertFalse(RoutingAcknowledgementProtocol.paths.contains("/api/runs/queue"))
        XCTAssertNil(app.pendingChatTurns["send-fixture"])
        XCTAssertFalse(app.isBusy)
        XCTAssertEqual(app.draftText, "Submitted message", "Stopping without a replacement keeps unsent draft recovery")
        XCTAssertEqual(app.blocks.filter { $0.kind == .user }.map(\.text), ["Submitted message"])
    }

    func testBackgroundAssignedModelScoringIsBusyAndCancellableBeforeAdmission() async throws {
        let started = expectation(description: "Model scoring started")
        let (app, profile) = try routedCompanion(started: started)
        defer { cleanup(app) }
        app.installTranscriptSession("elsewhere", blocks: [])
        app.draftText = "Other chat's draft"
        let submission = Task { @MainActor in
            try await app.sendSavedAgentTurn(sessionID: "send-fixture", workspace: "/tmp", profileID: profile.id,
                                            text: "Submitted message", mode: .ask)
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(app.savedAgentConversationState("send-fixture").busy)
        XCTAssertNotNil(app.pendingChatTurns["send-fixture"], "Stop needs an actual task while scoring is pending")
        app.stopGoalTurn(sessionID: "send-fixture")
        RoutingAcknowledgementProtocol.finishScoring()
        do { try await submission.value; XCTFail("The stopped submission should be cancelled") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
        XCTAssertFalse(RoutingAcknowledgementProtocol.paths.contains("/api/runs/queue"))
        XCTAssertNil(app.pendingChatTurns["send-fixture"])
        XCTAssertFalse(app.savedAgentConversationState("send-fixture").busy)
        XCTAssertEqual(app.currentSessionID, "elsewhere")
        XCTAssertEqual(app.draftText, "Other chat's draft")
    }

    func testCancelledScoringCannotClearAnImmediateReplacementTurn() async throws {
        for replacementAdmitted in [false, true] {
            let started = expectation(description: "Original model scoring started")
            let (app, _) = try routedCompanion(started: started)
            defer { cleanup(app) }
            app.draftText = "Original message"
            app.submitDraft()
            let original = try XCTUnwrap(app.pendingChatTurns["send-fixture"])
            await fulfillment(of: [started], timeout: 2)

            app.stop()
            RoutingAcknowledgementProtocol.onNextScoringStarted({})
            app.draftText = "Replacement message"
            app.submitDraft()
            let replacement = try XCTUnwrap(app.pendingChatTurns["send-fixture"])
            let replacementRunID = try XCTUnwrap(app.taskConversationStates["send-fixture"]?.runID)
            if replacementAdmitted {
                // Model the worker handoff: its run remains authoritative
                // after pending admission bookkeeping has been released.
                app.pendingChatTurns["send-fixture"] = nil
                app.pendingChatTurnTokens["send-fixture"] = nil
                app.taskConversationStates["send-fixture"]?.state = .running
            }
            await original.value

            XCTAssertTrue(app.isBusy, "An old cancellation must not clear the replacement's busy state")
            XCTAssertEqual(app.taskConversationStates["send-fixture"]?.runID, replacementRunID)
            XCTAssertEqual(app.taskConversationStates["send-fixture"]?.state, replacementAdmitted ? .running : .queued)
            XCTAssertEqual(app.draftText, "")
            XCTAssertEqual(app.blocks.filter { $0.kind == .user }.map(\.text), ["Original message", "Replacement message"])
            XCTAssertFalse(RoutingAcknowledgementProtocol.paths.contains("/api/runs/queue"))

            replacement.cancel()
            RoutingAcknowledgementProtocol.finishScoring()
            await replacement.value
        }
    }

    func testForegroundSendAcknowledgesBeforeQueueRequestAndPreservesNewerDraftOnFailure() async throws {
        for edit in ["untouched", "new text", "cleared"] {
            BackendStub.reset()
            BackendStub.respond(toPath: "/api/runs/queue", status: 503) { _ in ["detail": "Fixture queue unavailable"] }
            let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
            app.installTranscriptSession("send-fixture", blocks: [])
            app.sessionInfo = SessionInfo(model: "fixture", host: "localhost", cwd: "/tmp", session: "send-fixture",
                sessionID: "send-fixture", messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
                maxIterations: 10, hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
            app.agentRuntimePhase = .online
            app.selectedMode = .ask
            app.draftText = "Submitted message"
            app.submitDraft()

            XCTAssertEqual(app.draftText, "", "Submission must clear without waiting for network work")
            XCTAssertEqual(app.blocks.last?.text, "Submitted message")
            XCTAssertTrue(app.isBusy)
            XCTAssertTrue(BackendStub.requests.isEmpty, "The message is visible before the first async request")
            if edit != "untouched" { app.draftText = "Newer draft" }
            if edit == "cleared" { app.draftText = "" }
            await app.pendingChatTurns["send-fixture"]?.value

            XCTAssertFalse(app.isBusy)
            XCTAssertEqual(app.draftText, edit == "untouched" ? "Submitted message" : edit == "cleared" ? "" : "Newer draft")
            XCTAssertEqual(app.blocks.filter { $0.kind == .user }.map(\.text), ["Submitted message"],
                "The failed message stays available to copy without overwriting later edits")
            app.toastCenter.cancelPendingDismissal()
            app.knowledge.cancelAll()
            app.agentInstructions.cancelAll()
        }
    }

    private func routedCompanion(started: XCTestExpectation) throws -> (AppModel, AgentProfile) {
        let profile = AgentProfile(name: "Companion", model: "primary",
            additionalModels: [.init(route: .localOllama, model: "secondary")])
        RoutingAcknowledgementProtocol.reset(profileID: profile.id, started: { started.fulfill() })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingAcknowledgementProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!,
                                     session: URLSession(configuration: configuration))
        let app = AppModel(startImmediately: false, backendOverride: backend)
        app.agentProfiles = [profile]
        try app.agentTeamsModel.commitCompanion(.init(existingProfileID: profile.id))
        app.sessions = [SessionSummary(id: "send-fixture", name: "Companion", preview: "", mtime: 1, size: 0,
                                       cwd: "/tmp", agentProfileID: profile.id.uuidString)]
        app.initialWorkspacePath = "/tmp"
        app.installTranscriptSession("send-fixture", blocks: [])
        app.sessionInfo = SessionInfo(model: "primary", host: "localhost", cwd: "/tmp", session: "send-fixture",
            sessionID: "send-fixture", messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            maxIterations: 10, hasProjectContext: false, permissions: SessionPermissions(skipAll: false, allowed: []))
        app.agentRuntimePhase = .online
        app.selectedMode = .ask
        return (app, profile)
    }

    private func cleanup(_ app: AppModel) {
        RoutingAcknowledgementProtocol.finishScoring()
        app.toastCenter.cancelPendingDismissal()
        app.knowledge.cancelAll()
        app.agentInstructions.cancelAll()
    }
}

/// Holds just the model decision response so tests can inspect and cancel a
/// real suspended send without relying on timing or launching a worker.
private final class RoutingAcknowledgementProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var profileID = UUID()
    private static var started: (() -> Void)?
    private static var held: RoutingAcknowledgementProtocol?
    private static var recordedPaths: [String] = []
    private static var recordedQueueBodies: [[String: Any]] = []
    private var stopped = false

    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedPaths
    }
    static var queuedBodies: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return recordedQueueBodies
    }
    static func reset(profileID: UUID, started: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.profileID = profileID; self.started = started; held = nil
        recordedPaths = []; recordedQueueBodies = []
    }
    static func finishScoring() {
        lock.lock()
        let response = held
        held = nil
        lock.unlock()
        response?.respond(status: 200, body: ["selected_id": "model-route:ollama:secondary", "limited_data": false,
            "reason": "Fixture decision", "tags": ["general"], "candidates": []])
    }
    static func onNextScoringStarted(_ callback: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        started = callback
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        stopped = true
        if Self.held === self { Self.held = nil }
    }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        Self.recordedPaths.append(path)
        let profileID = Self.profileID
        if path == "/api/model-router/decision" {
            Self.held = self
            let started = Self.started
            Self.lock.unlock()
            started?()
            return
        }
        Self.lock.unlock()
        if path == "/api/sessions/send-fixture/execution-context" {
            respond(status: 200, body: ["id": "send-fixture", "agent_profile_id": profileID.uuidString,
                                       "cwd": "/tmp", "archived": false])
        } else if path == "/api/runs/queue" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Self.lock.lock(); Self.recordedQueueBodies.append(body); Self.lock.unlock()
            respond(status: 503, body: ["detail": "Fixture queue unavailable"])
        } else {
            respond(status: 404, body: ["detail": "Unstubbed fixture route"])
        }
    }
    private func respond(status: Int, body: [String: Any]) {
        Self.lock.lock()
        let stopped = self.stopped
        Self.lock.unlock()
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}
