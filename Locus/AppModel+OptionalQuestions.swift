import Foundation

extension AppModel {
    func configureOptionalQuestions() {
        optionalQuestions.send = { [weak self] sessionID, payload in
            self?.sendConversationControl(payload, sessionID: sessionID) ?? false
        }
        soloCollaboration.send = { [weak self] sessionID, payload in
            self?.sendConversationControl(payload, sessionID: sessionID) ?? false
        }
    }

    /// A background conversation keeps its own socket. Never fall back to the
    /// foreground socket when a response belongs to another conversation.
    @discardableResult
    func sendConversationControl(_ payload: [String: Any], sessionID: String) -> Bool {
        if let runtime = taskWorkers[sessionID] {
            return runtime.service.send(payload)
        }
        guard sessionID == currentSessionID else { return false }
        return conversationBackend.send(payload)
    }

    func sendOptionalQuestionCapability(to transport: BackendService) {
        _ = transport.send([
            "type": "set_question_capability", "enabled": true, "version": 1,
            "async_questions_v1": true, "collaboration_v1": true,
        ])
    }

    @discardableResult
    func handleOptionalQuestionEvent(_ event: [String: Any], sessionID: String) -> Bool {
        guard let type = event["type"] as? String else { return false }
        if ["solo_collaboration_snapshot", "collaboration_snapshot", "solo_agent_action_result"].contains(type) {
            soloCollaboration.receive(event, sessionID: sessionID)
            return true
        }
        guard ["question_async_snapshot", "question_async_response_ack", "question_async_applied", "question_capability"].contains(type)
        else { return false }
        optionalQuestions.receive(event, sessionID: sessionID)
        return true
    }

    func useOptionalQuestionDraft(_ request: OptionalQuestionRequest) {
        guard request.sessionID == currentSessionID else { return }
        let text = optionalQuestions.followupText(sessionID: request.sessionID, request: request)
        guard !text.isEmpty else { return }
        // Preserve an ordinary composer draft as well as the expired answer.
        draftText = [draftText, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        optionalQuestions.discardDraft(sessionID: request.sessionID, requestID: request.id)
    }

    func seedOptionalQuestionFixture() {
        let sessionID = currentSessionID
        var request: [String: Any] = [
            "request_id": "seed-optional-question", "session_id": sessionID, "run_id": "seed-optional-run",
            "status": "pending", "revision": 1, "remaining_ms": 60_000.0, "paused": false,
            "deadline_at": Date().timeIntervalSince1970 + 60, "updated_at": Date().timeIntervalSince1970,
            "questions": [["id": "q1", "header": "Storage", "question": "Where should the response cache live?",
                "multi_select": false, "options": [
                    ["id": "memory", "label": "In memory", "description": "Fast, temporary storage"],
                    ["id": "sqlite", "label": "SQLite", "description": "Keeps the cache after restarting"],
                ], "recommended_option_ids": ["sqlite"], "recommended_text": ""]],
        ]
        optionalQuestions.receive(["type": "question_async_snapshot", "requests": [request]], sessionID: sessionID)
        optionalQuestions.send = { [weak self] _, payload in
            guard let self else { return false }
            if payload["type"] as? String == "question_editing" {
                request["paused"] = payload["active"] as? Bool ?? false
                request["revision"] = (request["revision"] as? Int ?? 0) + 1
                self.optionalQuestions.receive(["type": "question_async_snapshot", "requests": [request]], sessionID: sessionID)
            } else if payload["type"] as? String == "question_async_response" {
                let action = payload["action"] as? String ?? "answer"
                request["status"] = action == "skip" ? "skipped" : "answered"
                request["delivery_status"] = "accepted"
                request["revision"] = (request["revision"] as? Int ?? 0) + 1
                let accepted = request
                Task { @MainActor [weak self] in
                    self?.optionalQuestions.receive(["type": "question_async_response_ack", "accepted": true,
                        "request": accepted, "response_id": payload["response_id"] ?? ""], sessionID: sessionID)
                }
            }
            return true
        }
    }

    func seedSoloHelperFixture() {
        let sessionID = currentSessionID
        var helper: [String: Any] = ["id": "seed-helper", "session_id": sessionID,
            "run_id": orchestrationRunID ?? "seed-run", "label": "Inspect retries",
            "goal": "Find the retry policy and report the missing checks", "state": "running", "revision": 1]
        soloCollaboration.receive(["type": "solo_collaboration_snapshot", "agents": [helper]], sessionID: sessionID)
        soloCollaboration.send = { [weak self] _, payload in
            guard let self else { return false }
            helper["state"] = payload["action"] as? String == "interrupt" ? "interrupted" : "running"
            helper["revision"] = (helper["revision"] as? Int ?? 0) + 1
            self.soloCollaboration.receive(["type": "solo_collaboration_snapshot", "agents": [helper]], sessionID: sessionID)
            Task { @MainActor [weak self] in
                self?.soloCollaboration.receive(["type": "solo_agent_action_result",
                    "request_id": payload["request_id"] ?? "", "result": ["ok": true]], sessionID: sessionID)
            }
            return true
        }
    }
}
