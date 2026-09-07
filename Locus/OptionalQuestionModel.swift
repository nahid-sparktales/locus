import Foundation
import Combine

struct OptionalQuestionOption: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var description: String
}

struct OptionalQuestionAnswer: Codable, Hashable {
    var id: String
    var selected: [String]?
    var text: String?
    var source: String?
}

struct OptionalAgentQuestion: Codable, Hashable, Identifiable {
    var id: String
    var header: String
    var question: String
    var multiSelect: Bool
    var options: [OptionalQuestionOption]
    var recommendedOptionIDs: [String]
    var recommendedText: String
    var answer: OptionalQuestionAnswer?

    enum CodingKeys: String, CodingKey {
        case id, header, question, options, answer
        case multiSelect = "multi_select"
        case recommendedOptionIDs = "recommended_option_ids"
        case recommendedText = "recommended_text"
    }

    var recommendation: String {
        let labels = options.filter { recommendedOptionIDs.contains($0.id) }.map(\.label)
        return (labels + [recommendedText]).filter { !$0.isEmpty }.joined(separator: "; ")
    }
}

struct OptionalQuestionRequest: Codable, Hashable, Identifiable {
    var id: String
    var sessionID: String
    var runID: String
    var status: String
    var revision: Int
    var questions: [OptionalAgentQuestion]
    var remainingMS: Double
    var paused: Bool
    var deadlineAt: Double?
    var updatedAt: Double
    var deliveryStatus: String?
    var appliedAt: Double?
    var supersededReason: String?

    enum CodingKeys: String, CodingKey {
        case id = "request_id", sessionID = "session_id", runID = "run_id"
        case status, revision, questions, paused
        case remainingMS = "remaining_ms", deadlineAt = "deadline_at", updatedAt = "updated_at"
        case deliveryStatus = "delivery_status", appliedAt = "applied_at"
        case supersededReason = "superseded_reason"
    }

    var isPending: Bool { status == "pending" }
    var isOpen: Bool { isPending || status == "suspended" }

    func remainingSeconds(at date: Date, connected: Bool) -> Int {
        let milliseconds = isPending && connected && !paused
            ? deadlineAt.map { ($0 - date.timeIntervalSince1970) * 1_000 } ?? remainingMS
            : remainingMS
        return max(0, Int(ceil(milliseconds / 1_000)))
    }
}

struct OptionalQuestionDraft: Codable, Hashable {
    var selected: Set<String> = []
    var text = ""
    var hasContent: Bool { !selected.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Optional questions belong to their conversation, independently of the
/// foreground composer and worker. Only server snapshots resolve questions;
/// a local countdown is a display, never an automatic answer.
@MainActor
final class OptionalQuestionModel: ObservableObject {
    @Published private(set) var requests: [String: [OptionalQuestionRequest]] = [:]
    @Published private(set) var drafts: [String: [String: OptionalQuestionDraft]] = [:]
    @Published private(set) var sending: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var connected: [String: Bool] = [:]
    @Published private(set) var applied: Set<String> = []
    @Published private(set) var dismissed: Set<String> = []

    var send: ((String, [String: Any]) -> Bool)?
    private var editing: Set<String> = []
    private var pending: [String: Submission] = [:]
    private var reconnecting: Set<String> = []
    private var defaults: UserDefaults?
    private let editorID = UUID().uuidString
    private static let persistenceKey = "Locus.optionalQuestionDrafts.v1"

    private struct Submission {
        var sessionID: String
        var requestID: String
        var answers: [String: OptionalQuestionDraft]
        var payload: [String: Any]
    }
    private struct Saved: Codable {
        var requests: [String: [OptionalQuestionRequest]]
        var drafts: [String: [String: OptionalQuestionDraft]]
    }

    func restore(defaults: UserDefaults?) {
        self.defaults = defaults
        guard let data = defaults?.data(forKey: Self.persistenceKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        drafts = saved.drafts
        requests = saved.requests.mapValues { values in
            values.map { value in
                var request = value
                if request.isPending { request.status = "suspended" }
                return request
            }
        }
    }

    static func key(sessionID: String, requestID: String) -> String { sessionID + "\u{1f}" + requestID }

    func request(sessionID: String, requestID: String) -> OptionalQuestionRequest? {
        requests[sessionID]?.first { $0.id == requestID }
    }

    func visibleRequests(sessionID: String) -> [OptionalQuestionRequest] {
        let values = requests[sessionID] ?? []
        let latestReceipt = values.last { !$0.isOpen && $0.deliveryStatus != nil }?.id
        return values.filter { request in
            !dismissed.contains(Self.key(sessionID: sessionID, requestID: request.id))
                && (request.isOpen || request.id == latestReceipt || hasDraft(sessionID: sessionID, requestID: request.id))
        }
    }

    func draft(sessionID: String, requestID: String, questionID: String) -> OptionalQuestionDraft {
        drafts[Self.key(sessionID: sessionID, requestID: requestID)]?[questionID] ?? .init()
    }

    func hasDraft(sessionID: String, requestID: String) -> Bool {
        drafts[Self.key(sessionID: sessionID, requestID: requestID)]?.values.contains { $0.hasContent } == true
    }

    func updateDraft(_ draft: OptionalQuestionDraft, sessionID: String, requestID: String, questionID: String) {
        let key = Self.key(sessionID: sessionID, requestID: requestID)
        var value = draft
        value.text = String(value.text.prefix(16_000))
        drafts[key, default: [:]][questionID] = value
        errors.removeValue(forKey: key)
        persist()
    }

    func setConnection(_ isConnected: Bool, sessionID: String) {
        guard !sessionID.isEmpty else { return }
        connected[sessionID] = isConnected
        if !isConnected {
            editing = editing.filter { !$0.hasPrefix(sessionID + "\u{1f}") }
            reconnecting.insert(sessionID)
        }
    }

    func receive(_ event: [String: Any], sessionID fallbackSession: String) {
        let sessionID = event["session_id"] as? String ?? fallbackSession
        switch event["type"] as? String {
        case "question_async_snapshot":
            guard let raw = event["requests"] as? [[String: Any]] else { return }
            for value in raw { merge(value, sessionID: sessionID) }
            connected[sessionID] = true
            // Reuse the response identity after reconnect, including when its
            // answer already reached the server but its acknowledgement did not.
            if reconnecting.remove(sessionID) != nil {
                for submission in pending.values where submission.sessionID == sessionID {
                    _ = send?(sessionID, submission.payload)
                }
            }
        case "question_async_response_ack":
            if let raw = event["request"] as? [String: Any] { merge(raw, sessionID: sessionID) }
            guard let responseID = event["response_id"] as? String,
                  let submission = pending.removeValue(forKey: responseID) else { return }
            let key = Self.key(sessionID: submission.sessionID, requestID: submission.requestID)
            sending.remove(key)
            if event["accepted"] as? Bool == true {
                // An edit made while the answer was in flight is a new draft.
                for (questionID, sent) in submission.answers where drafts[key]?[questionID] == sent {
                    drafts[key]?.removeValue(forKey: questionID)
                }
                errors.removeValue(forKey: key)
            } else {
                errors[key] = event["error"] as? String ?? "The answer could not be accepted. Your draft is kept."
            }
        case "question_async_applied":
            if let requestID = event["request_id"] as? String {
                applied.insert(Self.key(sessionID: sessionID, requestID: requestID))
            }
        default: return
        }
        persist()
    }

    private func merge(_ raw: [String: Any], sessionID: String) {
        var value = raw
        if value["session_id"] == nil { value["session_id"] = sessionID }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let request = try? JSONDecoder().decode(OptionalQuestionRequest.self, from: data),
              !request.id.isEmpty, request.sessionID == sessionID else { return }
        var values = requests[sessionID] ?? []
        if let index = values.firstIndex(where: { $0.id == request.id }) {
            guard request.revision >= values[index].revision else { return }
            values[index] = request
        } else { values.append(request) }
        requests[sessionID] = values.sorted { $0.updatedAt < $1.updatedAt }
        if !request.isPending { editing.remove(Self.key(sessionID: sessionID, requestID: request.id)) }
    }

    /// Call only after a real edit or choice, never simply because a field
    /// received focus. The card renews this lease while that edit remains active.
    func beginEditing(sessionID: String, requestID: String) {
        guard request(sessionID: sessionID, requestID: requestID)?.isPending == true,
              connected[sessionID] != false else { return }
        let key = Self.key(sessionID: sessionID, requestID: requestID)
        guard editing.insert(key).inserted else { return }
        _ = send?(sessionID, ["type": "question_editing", "request_id": requestID,
                            "active": true, "editor_id": editorID])
    }

    func renewEditing(sessionID: String, requestID: String) {
        guard editing.contains(Self.key(sessionID: sessionID, requestID: requestID)) else { return }
        _ = send?(sessionID, ["type": "question_editing", "request_id": requestID,
                            "active": true, "editor_id": editorID])
    }

    func endEditing(sessionID: String, requestID: String) {
        guard editing.remove(Self.key(sessionID: sessionID, requestID: requestID)) != nil else { return }
        _ = send?(sessionID, ["type": "question_editing", "request_id": requestID,
                            "active": false, "editor_id": editorID])
    }

    @discardableResult
    func respond(sessionID: String, requestID: String, questionID: String? = nil,
                 action: String = "answer", answers supplied: [AgentQuestionAnswer]? = nil) -> Bool {
        guard let request = request(sessionID: sessionID, requestID: requestID), request.isPending else { return false }
        let key = Self.key(sessionID: sessionID, requestID: requestID)
        guard !sending.contains(key) else { return false }
        var sentDrafts: [String: OptionalQuestionDraft] = [:]
        let answers: [[String: Any]]
        if let supplied {
            answers = supplied.map { ["id": $0.id, "selected": $0.selected, "text": $0.text] }
        } else if action == "answer" {
            answers = request.questions.filter { $0.answer == nil && (questionID == nil || $0.id == questionID) }.compactMap { question in
                let value = draft(sessionID: sessionID, requestID: requestID, questionID: question.id)
                guard value.hasContent else { return nil }
                sentDrafts[question.id] = value
                return ["id": question.id, "selected": value.selected.sorted(), "text": value.text]
            }
        } else { answers = [] }
        guard action == "skip" || !answers.isEmpty else { return false }
        let responseID = UUID().uuidString
        let payload: [String: Any] = ["type": "question_async_response", "request_id": requestID,
            "response_id": responseID, "revision": request.revision, "action": action, "answers": answers]
        guard send?(sessionID, payload) == true else {
            errors[key] = "The chat is disconnected. Your answer is kept."
            return false
        }
        pending[responseID] = Submission(sessionID: sessionID, requestID: requestID, answers: sentDrafts, payload: payload)
        sending.insert(key)
        endEditing(sessionID: sessionID, requestID: requestID)
        return true
    }

    func followupText(sessionID: String, request: OptionalQuestionRequest) -> String {
        request.questions.compactMap { question in
            let value = draft(sessionID: sessionID, requestID: request.id, questionID: question.id)
            guard value.hasContent else { return nil }
            let labels = question.options.filter { value.selected.contains($0.id) }.map(\.label)
            let text = (labels + [value.text]).filter { !$0.isEmpty }.joined(separator: "; ")
            return "\(question.header.isEmpty ? question.question : question.header): \(text)"
        }.joined(separator: "\n")
    }

    @discardableResult
    func resume(sessionID: String, requestID: String) -> Bool {
        guard let request = request(sessionID: sessionID, requestID: requestID),
              request.status == "suspended" || request.deliveryStatus == "accepted" else { return false }
        let sent = send?(sessionID, ["type": "resume_async_questions", "request_id": requestID]) == true
        if !sent { errors[Self.key(sessionID: sessionID, requestID: requestID)] = "Reconnect this task to resume the question." }
        return sent
    }

    func discardDraft(sessionID: String, requestID: String) {
        let key = Self.key(sessionID: sessionID, requestID: requestID)
        drafts.removeValue(forKey: key)
        dismissed.insert(key)
        persist()
    }

    func releaseAllEditing() {
        for key in Array(editing) {
            let parts = key.components(separatedBy: "\u{1f}")
            if parts.count == 2 { endEditing(sessionID: parts[0], requestID: parts[1]) }
        }
    }

    private func persist() {
        guard let defaults else { return }
        // Save only cards with an unsent draft. Server state is restored by its
        // snapshot; this local copy keeps a timed-out answer usable after restart.
        let retained = requests.mapValues { values in
            Array(values.filter { hasDraft(sessionID: $0.sessionID, requestID: $0.id) }.suffix(20))
        }.filter { !$0.value.isEmpty }
        let retainedKeys = Set(retained.values.flatMap { $0 }.map { Self.key(sessionID: $0.sessionID, requestID: $0.id) })
        let retainedDrafts = drafts.filter { retainedKeys.contains($0.key) }
        if let data = try? JSONEncoder().encode(Saved(requests: retained, drafts: retainedDrafts)) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }
}
