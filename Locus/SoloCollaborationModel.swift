import Combine
import Foundation

struct SoloHelper: Decodable, Identifiable, Equatable {
    var id: String
    var sessionID: String
    var runID: String
    var label: String
    var goal: String
    var state: String
    var revision: Int
    var output: String?
    var reason: String?
    enum CodingKeys: String, CodingKey {
        case id, label, goal, state, revision, output, reason
        case sessionID = "session_id", runID = "run_id"
    }
    var isRunning: Bool { ["queued", "running", "stopping"].contains(state) }
}

@MainActor
final class SoloCollaborationModel: ObservableObject {
    @Published private(set) var agents: [String: [SoloHelper]] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var receipts: [String: String] = [:]
    @Published var drafts: [String: String] = [:]
    var send: ((String, [String: Any]) -> Bool)?
    private var actions: [String: (sessionID: String, agentID: String, text: String, action: String)] = [:]

    func receive(_ event: [String: Any], sessionID: String) {
        switch event["type"] as? String {
        case "solo_collaboration_snapshot", "collaboration_snapshot":
            if let raw = event["agents"] as? [[String: Any]] { merge(raw, sessionID: sessionID) }
        case "solo_agent_action_result":
            guard let requestID = event["request_id"] as? String,
                  let action = actions.removeValue(forKey: requestID) else { return }
            let key = Self.key(action.sessionID, action.agentID)
            pending.remove(key)
            let result = event["result"] as? [String: Any] ?? event
            if result["ok"] as? Bool == true {
                if let raw = result["agents"] as? [[String: Any]] { merge(raw, sessionID: action.sessionID) }
                if let raw = result["agent"] as? [String: Any] { merge([raw], sessionID: action.sessionID) }
                if drafts[key] == action.text { drafts.removeValue(forKey: key) }
                receipts[key] = action.action == "interrupt" ? "Stop requested." : "Instruction accepted."
                errors.removeValue(forKey: key)
            } else {
                errors[key] = result["error"] as? String ?? "That helper action could not be accepted."
            }
        default: break
        }
    }

    private func merge(_ raw: [[String: Any]], sessionID: String) {
        var values = agents[sessionID] ?? []
        for item in raw {
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  let helper = try? JSONDecoder().decode(SoloHelper.self, from: data),
                  helper.sessionID == sessionID else { continue }
            if let index = values.firstIndex(where: { $0.id == helper.id }) {
                if helper.revision >= values[index].revision { values[index] = helper }
            } else { values.append(helper) }
        }
        agents[sessionID] = values
    }

    static func key(_ sessionID: String, _ agentID: String) -> String { sessionID + "/" + agentID }

    /// Running turns can reuse this conversation's saved helpers. Historical
    /// run views retain only helpers whose latest attempt belongs to that run;
    /// the run's persisted attempt rows provide the rest of its history.
    func visibleHelpers(sessionID: String, runID: String, isParentRunning: Bool) -> [SoloHelper] {
        (agents[sessionID] ?? [])
            .filter { $0.sessionID == sessionID && (isParentRunning || $0.runID == runID) }
            .sorted { lhs, rhs in
                let leftIsCurrent = lhs.runID == runID
                let rightIsCurrent = rhs.runID == runID
                if leftIsCurrent != rightIsCurrent { return leftIsCurrent }
                let labelOrder = lhs.label.localizedStandardCompare(rhs.label)
                if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
    }

    @discardableResult
    func act(_ action: String, agentID: String, sessionID: String, text: String = "") -> Bool {
        let key = Self.key(sessionID, agentID)
        guard !pending.contains(key) else { return false }
        let requestID = UUID().uuidString
        let payload: [String: Any] = ["type": "solo_agent_action", "request_id": requestID,
                                    "action": action, "agent_id": agentID, "text": text]
        guard send?(sessionID, payload) == true else {
            errors[key] = "This chat is disconnected. Your instruction is kept."
            return false
        }
        pending.insert(key)
        actions[requestID] = (sessionID, agentID, text, action)
        receipts.removeValue(forKey: key)
        return true
    }

    func disconnected(sessionID: String) {
        // A helper action can start work; unlike an idempotent question answer,
        // never silently repeat it after losing the acknowledgement.
        for (id, action) in actions where action.sessionID == sessionID {
            let key = Self.key(sessionID, action.agentID)
            errors[key] = "Connection lost before confirmation. Check the helper’s state before retrying."
            pending.remove(key)
            actions.removeValue(forKey: id)
        }
    }
}
