import XCTest
@testable import Locus

@MainActor
final class OptionalQuestionModelTests: XCTestCase {
    private func payload(session: String = "chat-a", status: String = "pending", revision: Int = 1) -> [String: Any] {
        ["request_id": "request-1", "session_id": session, "run_id": "run-a", "status": status,
         "revision": revision, "remaining_ms": 60_000.0, "paused": false,
         "deadline_at": 1_060.0, "updated_at": 1_000.0,
         "questions": [
            ["id": "q1", "header": "Storage", "question": "Where should the cache live?",
             "multi_select": false, "options": [["id": "sqlite", "label": "SQLite", "description": "Keeps data"]],
             "recommended_option_ids": ["sqlite"], "recommended_text": ""],
            ["id": "q2", "header": "Naming", "question": "Choose a name", "multi_select": false,
             "options": [], "recommended_option_ids": [], "recommended_text": "cache.db"],
         ]]
    }

    private func snapshot(_ raw: [String: Any]) -> [String: Any] {
        ["type": "question_async_snapshot", "session_id": raw["session_id"]!, "requests": [raw]]
    }

    func testCountdownUsesServerDeadlineAndFreezesOfflineOrPaused() throws {
        let store = OptionalQuestionModel()
        store.receive(snapshot(payload()), sessionID: "chat-a")
        let request = try XCTUnwrap(store.request(sessionID: "chat-a", requestID: "request-1"))
        XCTAssertEqual(request.remainingSeconds(at: Date(timeIntervalSince1970: 1_010), connected: true), 50)
        XCTAssertEqual(request.remainingSeconds(at: Date(timeIntervalSince1970: 1_200), connected: false), 60)
        XCTAssertEqual(request.remainingSeconds(at: Date(timeIntervalSince1970: 1_200), connected: true), 0)
        XCTAssertTrue(request.isPending, "A local timer must never resolve a server question")
        var paused = request
        paused.paused = true
        XCTAssertEqual(paused.remainingSeconds(at: Date(timeIntervalSince1970: 1_200), connected: true), 60)
    }

    func testDraftsAreScopedToConversationAndSurviveTimeoutAndStaleSnapshot() throws {
        let store = OptionalQuestionModel()
        store.receive(snapshot(payload()), sessionID: "chat-a")
        store.receive(snapshot(payload(session: "chat-b")), sessionID: "chat-b")
        store.updateDraft(.init(selected: ["sqlite"], text: "Keep my detail"), sessionID: "chat-a", requestID: "request-1", questionID: "q1")
        store.receive(snapshot(payload(status: "defaulted", revision: 2)), sessionID: "chat-a")
        store.receive(snapshot(payload()), sessionID: "chat-a")
        XCTAssertEqual(store.request(sessionID: "chat-a", requestID: "request-1")?.status, "defaulted")
        XCTAssertFalse(store.hasDraft(sessionID: "chat-b", requestID: "request-1"))
        XCTAssertEqual(store.visibleRequests(sessionID: "chat-a").count, 1)
        let request = try XCTUnwrap(store.request(sessionID: "chat-a", requestID: "request-1"))
        XCTAssertEqual(store.followupText(sessionID: "chat-a", request: request), "Storage: SQLite; Keep my detail")
    }

    func testAnswerRetainsDraftUntilAckAndPreservesEditsMadeInFlight() throws {
        let store = OptionalQuestionModel()
        var messages: [[String: Any]] = []
        store.send = { _, payload in messages.append(payload); return true }
        store.receive(snapshot(payload()), sessionID: "chat-a")
        store.updateDraft(.init(text: "First answer"), sessionID: "chat-a", requestID: "request-1", questionID: "q1")
        XCTAssertTrue(store.respond(sessionID: "chat-a", requestID: "request-1", questionID: "q1"))
        XCTAssertTrue(store.hasDraft(sessionID: "chat-a", requestID: "request-1"))
        let sent = try XCTUnwrap(messages.first { $0["type"] as? String == "question_async_response" })
        XCTAssertEqual((sent["answers"] as? [[String: Any]])?.count, 1)
        store.updateDraft(.init(text: "Revised answer"), sessionID: "chat-a", requestID: "request-1", questionID: "q1")
        store.receive(["type": "question_async_response_ack", "response_id": sent["response_id"]!, "accepted": true], sessionID: "chat-a")
        XCTAssertEqual(store.draft(sessionID: "chat-a", requestID: "request-1", questionID: "q1").text, "Revised answer")
        XCTAssertTrue(store.sending.isEmpty)
    }

    func testSkipDoesNotSubmitUnsentDraftAndRejectedAnswerKeepsIt() throws {
        let store = OptionalQuestionModel()
        var sent: [String: Any] = [:]
        store.send = { _, payload in sent = payload; return true }
        store.receive(snapshot(payload()), sessionID: "chat-a")
        store.updateDraft(.init(text: "Unsent"), sessionID: "chat-a", requestID: "request-1", questionID: "q1")
        XCTAssertTrue(store.respond(sessionID: "chat-a", requestID: "request-1", action: "skip"))
        XCTAssertTrue((sent["answers"] as? [[String: Any]])?.isEmpty == true)
        store.receive(["type": "question_async_response_ack", "response_id": sent["response_id"]!, "accepted": false, "error": "Already timed out"], sessionID: "chat-a")
        XCTAssertTrue(store.hasDraft(sessionID: "chat-a", requestID: "request-1"))
        XCTAssertEqual(store.errors.values.first, "Already timed out")
    }

    func testOnlyActualEditingStartsLeaseAndReleaseAndReconnectAreScoped() throws {
        let store = OptionalQuestionModel()
        var messages: [[String: Any]] = []
        store.send = { _, payload in messages.append(payload); return true }
        store.receive(snapshot(payload()), sessionID: "chat-a")
        store.renewEditing(sessionID: "chat-a", requestID: "request-1")
        XCTAssertTrue(messages.isEmpty)
        store.beginEditing(sessionID: "chat-a", requestID: "request-1")
        store.beginEditing(sessionID: "chat-a", requestID: "request-1")
        XCTAssertEqual(messages.count, 1, "Keystrokes should not flood the lease channel")
        store.renewEditing(sessionID: "chat-a", requestID: "request-1")
        store.endEditing(sessionID: "chat-a", requestID: "request-1")
        XCTAssertEqual(messages.map { $0["active"] as? Bool }, [true, true, false])
        store.beginEditing(sessionID: "chat-a", requestID: "request-1")
        store.setConnection(false, sessionID: "chat-a")
        let count = messages.count
        store.renewEditing(sessionID: "chat-a", requestID: "request-1")
        XCTAssertEqual(messages.count, count)
    }

    func testReconnectReplaysLostAckOnceUsingSameResponseIdentity() throws {
        let store = OptionalQuestionModel()
        var messages: [[String: Any]] = []
        store.send = { _, payload in messages.append(payload); return true }
        store.receive(snapshot(payload()), sessionID: "chat-a")
        store.updateDraft(.init(text: "Answer"), sessionID: "chat-a", requestID: "request-1", questionID: "q1")
        store.respond(sessionID: "chat-a", requestID: "request-1")
        store.setConnection(false, sessionID: "chat-a")
        store.receive(snapshot(payload(status: "suspended", revision: 2)), sessionID: "chat-a")
        store.receive(snapshot(payload(status: "suspended", revision: 2)), sessionID: "chat-a")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["response_id"] as? String, messages[1]["response_id"] as? String)
        store.receive(["type": "question_async_response_ack", "response_id": messages[0]["response_id"]!, "accepted": true], sessionID: "chat-a")
        XCTAssertFalse(store.hasDraft(sessionID: "chat-a", requestID: "request-1"))
    }

    func testDraftPersistsAcrossRestartAsSuspended() throws {
        let suite = "OptionalQuestionModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OptionalQuestionModel()
        store.restore(defaults: defaults)
        store.receive(snapshot(payload()), sessionID: "chat-a")
        store.updateDraft(.init(text: "Saved locally"), sessionID: "chat-a", requestID: "request-1", questionID: "q2")
        let restored = OptionalQuestionModel()
        restored.restore(defaults: defaults)
        XCTAssertEqual(restored.request(sessionID: "chat-a", requestID: "request-1")?.status, "suspended")
        XCTAssertEqual(restored.draft(sessionID: "chat-a", requestID: "request-1", questionID: "q2").text, "Saved locally")
    }

    func testMobileOptionalReplyUsesOwningSessionAndNeverPermissionRoute() async throws {
        let model = AppModel(startImmediately: false)
        var owner = ""
        var sent: [String: Any] = [:]
        model.optionalQuestions.send = { session, payload in owner = session; sent = payload; return true }
        model.optionalQuestions.receive(snapshot(payload(session: "background-chat")), sessionID: "background-chat")
        let result = await model.handleCompanionRequest(.init(id: "mobile-1", method: .approvalRespond, payload: [
            "kind": .string("optional_question"), "chat_id": .string("background-chat"),
            "request_id": .string("request-1"), "decision": .string("skip"),
        ]))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(owner, "background-chat")
        XCTAssertEqual(sent["type"] as? String, "question_async_response")
        XCTAssertEqual(sent["action"] as? String, "skip")
        let invalid = await model.handleCompanionRequest(.init(id: "mobile-2", method: .approvalRespond, payload: [
            "kind": .string("optional_question"), "chat_id": .string("background-chat"),
            "request_id": .string("request-1"), "decision": .string("approve"),
        ]))
        XCTAssertFalse(invalid.ok)
    }
}
