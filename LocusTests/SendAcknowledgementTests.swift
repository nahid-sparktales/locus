import XCTest
@testable import Locus

@MainActor
final class SendAcknowledgementTests: XCTestCase {
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
}
