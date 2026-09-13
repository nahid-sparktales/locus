import CryptoKit
import Foundation

/// Native-only targets accompany the small public map metadata. A plugin can
/// ask to open a known token; it cannot invent a session, request or file path.
struct AgentWorldAttention: Identifiable, Equatable {
    let id: String
    let agentID: String
    let kind: String
    let title: String
    let sessionID: String

    var snapshot: [String: Any] {
        ["id": id, "agentID": agentID, "kind": kind, "title": String(title.prefix(256))]
    }
}

struct AgentWorldTransfer: Identifiable, Equatable {
    let id: String
    let fromAgentID: String
    let toAgentID: String
    let kind: String
    let title: String
    let occurredAt: Date
    let sessionID: String
    var runID: String?
    var detail: String

    var snapshot: [String: Any] {
        ["id": id, "fromAgentID": fromAgentID, "toAgentID": toAgentID, "kind": kind,
         "title": String(title.prefix(256)), "occurredAt": occurredAt.timeIntervalSince1970]
    }
}

/// Retain identity only; tool arguments, questions and answers stay in the
/// native transcript. Request keys are scoped to their session and run.
struct AgentWorldRequestOwner {
    let sessionID: String
    let workspace: String
    let runID: String?
    let agentID: UUID
    let recordedAt: Date
}

struct AgentWorldSignals {
    var attention: [AgentWorldAttention] = []
    var transfers: [AgentWorldTransfer] = []

    static func token(_ components: String...) -> String {
        var bytes = Array(SHA256.hash(data: Data(components.joined(separator: "\n").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    /// A declared dependency alone is not a delivery. Both a completed source
    /// attempt and an actually started recipient attempt must be recorded.
    static func transfers(in run: OrchestrationRun, profiles: Set<UUID>, workspace: String) -> [AgentWorldTransfer] {
        guard let sessionID = run.sessionID, !sessionID.isEmpty,
              let runWorkspace = run.workspaceRoot,
              SessionSummary.canonicalWorkspacePath(runWorkspace) == SessionSummary.canonicalWorkspacePath(workspace),
              let plan = run.plan, let attempts = run.attempts else { return [] }
        var result: [AgentWorldTransfer] = []
        for job in plan.jobs {
            let receivers = attempts.filter { $0.jobID == job.id && $0.startedAt != nil }
            for receiver in receivers {
                guard let toID = receiver.agentID.flatMap(UUID.init(uuidString:)), profiles.contains(toID),
                      let started = receiver.startedAt, started.isFinite else { continue }
                for dependency in job.dependencies {
                    guard let source = attempts.filter({
                        $0.jobID == dependency && $0.completedAt != nil && $0.completedAt! <= started
                            && $0.output?.isEmpty == false
                    }).max(by: { ($0.completedAt ?? 0) < ($1.completedAt ?? 0) }),
                          let fromID = source.agentID.flatMap(UUID.init(uuidString:)), profiles.contains(fromID), fromID != toID else { continue }
                    let files = source.evidence.filter { !$0.isEmpty }
                    let title = files.isEmpty ? "Task results delivered" : "Results and evidence delivered"
                    let detail = "\(source.agentName ?? "An agent") shared the recorded results of “\(source.goal)” with \(receiver.agentName ?? "another agent") for “\(job.goal)”.\n\n\(String((source.output ?? "").prefix(12_000)))"
                    result.append(AgentWorldTransfer(
                        id: token("dependency", run.id, source.attemptID, receiver.attemptID),
                        fromAgentID: fromID.uuidString, toAgentID: toID.uuidString,
                        kind: files.isEmpty ? "handoff" : "artifact", title: title,
                        occurredAt: Date(timeIntervalSince1970: started), sessionID: sessionID,
                        runID: run.id, detail: detail))
                }
            }
        }
        return result
    }
}

extension AppModel {
    private func agentWorldAttentionRunID(_ sessionID: String) -> String? {
        if sessionID == currentSessionID, let orchestrationRunID { return orchestrationRunID }
        return taskConversationStates[sessionID]?.runID ?? taskWorkers[sessionID]?.reservedRunID
    }

    private static func agentWorldRequestKey(_ event: [String: Any], runID: String?) -> String? {
        guard let type = event["type"] as? String else { return nil }
        switch type {
        case "permission_request", "computer_action_request":
            guard let id = event["request_id"] as? String, !id.isEmpty else { return nil }
            return type + ":" + id
        case "question_required":
            guard let id = event["request_id"] as? String, !id.isEmpty else { return nil }
            return "input:" + id
        case "question_ready":
            guard let question = event["question"] as? [String: Any],
                  let id = question["id"] as? String, !id.isEmpty else { return nil }
            return "input:" + id
        case "dispatcher_started", "dispatch_plan_ready":
            guard let runID, !runID.isEmpty else { return nil }
            return type + ":" + runID
        default: return nil
        }
    }

    private func agentWorldEventOwner(_ event: [String: Any], sessionID: String, workspace: String,
                                      requestKey: String, runID: String?) -> UUID? {
        if let eventSession = event["session_id"] as? String, eventSession != sessionID { return nil }
        if let eventRun = event["run_id"] as? String, eventRun != runID { return nil }
        for field in ["workspace_root", "workspace"] {
            if let path = event[field] as? String,
               SessionSummary.canonicalWorkspacePath(path) != workspace { return nil }
        }
        guard Self.agentWorldRequestKey(event, runID: runID) == requestKey,
              let id = (event["agent_id"] as? String).flatMap(UUID.init(uuidString:)),
              agentProfiles.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Called on the already routed foreground transport before its event is
    /// reduced to a ToolPayload or question that has no agent identity field.
    func recordAgentWorldRequestOwner(_ event: [String: Any], source: BackendService? = nil) {
        guard let type = event["type"] as? String,
              ["permission_request", "computer_action_request", "question_required", "question_ready",
               "dispatcher_started", "dispatch_plan_ready"].contains(type) else { return }
        guard source == nil || source === conversationBackend else { return }
        let sessionID = currentSessionID
        guard !sessionID.isEmpty else { return }
        let workspace = SessionSummary.canonicalWorkspacePath(workspacePath)
        let runID = agentWorldAttentionRunID(sessionID)
        if let eventSession = event["session_id"] as? String, eventSession != sessionID { return }
        if let eventRun = event["run_id"] as? String, eventRun != runID { return }
        for field in ["workspace_root", "workspace"] {
            if let path = event[field] as? String,
               SessionSummary.canonicalWorkspacePath(path) != workspace { return }
        }
        guard let key = Self.agentWorldRequestKey(event, runID: runID) else { return }
        let storageKey = AgentWorldSignals.token(sessionID, key)
        // A reused request ID with no verified owner must not inherit an old
        // event's agent, even if it arrives in the same session.
        agentWorldRequestOwners[storageKey] = nil
        guard let owner = agentWorldAttentionOwner(sessionID, workspace: workspace, requestKey: key, event: event) else { return }
        agentWorldRequestOwners[storageKey] = AgentWorldRequestOwner(
            sessionID: sessionID, workspace: workspace, runID: runID, agentID: owner, recordedAt: Date())
        if agentWorldRequestOwners.count > 512 {
            agentWorldRequestOwners = Dictionary(uniqueKeysWithValues: agentWorldRequestOwners
                .sorted { $0.value.recordedAt > $1.value.recordedAt }.prefix(512).map { ($0.key, $0.value) })
        }
    }

    private func agentWorldAttentionOwner(_ sessionID: String, workspace: String, requestKey: String,
                                          event: [String: Any]? = nil) -> UUID? {
        let runID = agentWorldAttentionRunID(sessionID)
        if let event, let owner = agentWorldEventOwner(event, sessionID: sessionID, workspace: workspace,
                                                       requestKey: requestKey, runID: runID) { return owner }
        func recorded(_ key: String) -> UUID? {
            guard let owner = agentWorldRequestOwners[AgentWorldSignals.token(sessionID, key)],
                  owner.sessionID == sessionID, owner.workspace == workspace, owner.runID == runID,
                  agentProfiles.contains(where: { $0.id == owner.agentID }) else { return nil }
            return owner.agentID
        }
        if let owner = recorded(requestKey) { return owner }
        if let profile = savedAgentProfileID(for: sessionID) { return profile }
        // Only a plan belongs to the run's dispatcher by definition. A tool
        // request without its own owner must not be assigned to a random team.
        guard requestKey.hasPrefix("dispatch_plan_ready:") || requestKey.hasPrefix("plan:"), let runID else { return nil }
        if let dispatcher = recorded("dispatcher_started:" + runID) { return dispatcher }
        let run = agentWorldRunSignals[runID] ?? runs.runDetailsByID[runID]
            ?? runs.orchestrationRuns.first { $0.id == runID }
            ?? (runs.selectedOrchestrationRun?.id == runID ? runs.selectedOrchestrationRun : nil)
        guard let run, run.id == runID, run.sessionID == sessionID,
              run.workspaceRoot.map({ SessionSummary.canonicalWorkspacePath($0) == workspace }) == true,
              case .object(let team) = run.manifest?["team"],
              let dispatcher = team["dispatcher_id"]?.string.flatMap(UUID.init(uuidString:)),
              agentProfiles.contains(where: { $0.id == dispatcher }) else { return nil }
        return dispatcher
    }

    func agentWorldSignals(workspace: String) -> AgentWorldSignals {
        let workspace = SessionSummary.canonicalWorkspacePath(workspace)
        let profileIDs = Set(agentProfiles.map(\.id))
        var signals = AgentWorldSignals()
        func add(_ sessionID: String, _ profileID: UUID?, _ key: String, _ kind: String, _ title: String) {
            guard let profileID, profileIDs.contains(profileID) else { return }
            signals.attention.append(AgentWorldAttention(
                id: AgentWorldSignals.token("attention", sessionID, key), agentID: profileID.uuidString,
                kind: kind, title: title, sessionID: sessionID))
        }
        for (sessionID, worker) in taskWorkers where SessionSummary.canonicalWorkspacePath(worker.workspacePath) == workspace {
            // Foreground requests are represented by the composer below; the
            // parked event is consumed when its worker becomes foreground.
            guard sessionID != currentSessionID else { continue }
            if let question = worker.pendingBlockingQuestion {
                let owner = agentWorldAttentionOwner(sessionID, workspace: workspace, requestKey: "input:" + question.id, event: worker.pendingForegroundEvent)
                add(sessionID, owner, question.id, "input", "A crew member needs your answer")
            } else if let question = worker.pendingQuestion {
                let owner = agentWorldAttentionOwner(sessionID, workspace: workspace, requestKey: "input:" + question.id)
                add(sessionID, owner, question.id, "input", "A crew member needs your answer")
            } else if let event = worker.pendingForegroundEvent,
                      [.waitingPermission, .waitingComputer, .waitingDispatchApproval].contains(worker.executionState) {
                let type = event["type"] as? String ?? ""
                guard ["permission_request", "computer_action_request", "dispatch_plan_ready", "question_required"].contains(type) else { continue }
                let id = event["request_id"] as? String ?? event["id"] as? String
                    ?? worker.reservedRunID ?? taskConversationStates[sessionID]?.runID ?? type
                let owner = agentWorldAttentionOwner(sessionID, workspace: workspace, requestKey: type + ":" + id, event: event)
                add(sessionID, owner, type + ":" + id, type == "question_required" ? "input" : "approval",
                    type == "question_required" ? "A crew member needs your answer" : "A crew member needs your approval")
            }
        }
        if SessionSummary.canonicalWorkspacePath(workspacePath) == workspace {
            if let request = activePermissionRequest, let id = request.requestID {
                let key = "permission_request:" + id
                add(currentSessionID, agentWorldAttentionOwner(currentSessionID, workspace: workspace, requestKey: key), key, "approval", "A crew member needs your approval")
            } else if let question = pendingBlockingQuestion {
                add(currentSessionID, agentWorldAttentionOwner(currentSessionID, workspace: workspace, requestKey: "input:" + question.id), question.id, "input", "A crew member needs your answer")
            } else if let question = pendingUserQuestion {
                add(currentSessionID, agentWorldAttentionOwner(currentSessionID, workspace: workspace, requestKey: "input:" + question.id), question.id, "input", "A crew member needs your answer")
            } else if planApprovalPending {
                let key = "plan:" + (blocks.last?.id.uuidString ?? currentSessionID)
                add(currentSessionID, agentWorldAttentionOwner(currentSessionID, workspace: workspace, requestKey: key), key, "approval", "Review the captain’s plan")
            } else if teamRunLive.pendingDispatchPlan != nil, orchestrationState == .waitingDispatchApproval {
                let key = "dispatch_plan_ready:" + (orchestrationRunID ?? currentSessionID)
                add(currentSessionID, agentWorldAttentionOwner(currentSessionID, workspace: workspace, requestKey: key), key, "approval", "Review the crew’s task assignments")
            }
        }

        var knownRuns = runs.runDetailsByID
        for run in runs.orchestrationRuns where knownRuns[run.id] == nil { knownRuns[run.id] = run }
        for run in agentWorldRunSignals.values { knownRuns[run.id] = run }
        if let run = runs.selectedOrchestrationRun { knownRuns[run.id] = run }
        signals.transfers = knownRuns.values.flatMap { AgentWorldSignals.transfers(in: $0, profiles: profileIDs, workspace: workspace) }
        for handoff in agentCrewChat.handoffs(for: workspace) {
            guard profileIDs.contains(handoff.fromAgentID), profileIDs.contains(handoff.toAgentID) else { continue }
            signals.transfers.append(AgentWorldTransfer(
                id: handoff.id.uuidString, fromAgentID: handoff.fromAgentID.uuidString, toAgentID: handoff.toAgentID.uuidString,
                kind: "handoff", title: "Crew Chat context delivered", occurredAt: handoff.occurredAt,
                sessionID: handoff.recipientSessionID, detail: handoff.title))
        }
        signals.attention = Array(Dictionary(signals.attention.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }.prefix(256))
        signals.transfers = Array(Dictionary(signals.transfers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.occurredAt < $1.occurredAt }.suffix(128))
        return signals
    }

    /// Read already admitted run records while the world is visible. This does
    /// not select an inspector run, start work, or make a model call.
    func refreshAgentWorldRunSignals(workspace: String) {
        guard agentWorldSignalsRefreshTask == nil, !isUITesting, !isShuttingDown,
              Date().timeIntervalSince(agentWorldSignalsRefreshAt) >= 4 else { return }
        agentWorldSignalsRefreshAt = Date()
        let canonical = SessionSummary.canonicalWorkspacePath(workspace)
        let ids = taskConversationStates.values.filter { state in
            let path = taskWorkers[state.sessionID]?.workspacePath ?? sessionCatalog.snapshot.sessionsByID[state.sessionID]?.workspacePath
            return path.map { SessionSummary.canonicalWorkspacePath($0) == canonical } == true
        }.sorted { $0.updatedAt > $1.updatedAt }.compactMap(\.runID)
        guard !ids.isEmpty else { return }
        agentWorldSignalsRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.agentWorldSignalsRefreshTask = nil }
            var seen = Set<String>()
            for id in ids.filter({ seen.insert($0).inserted }).prefix(8) {
                guard !Task.isCancelled else { return }
                if let run = try? await self.backend.get("/api/runs/\(id)", as: OrchestrationRun.self),
                   run.workspaceRoot.map({ SessionSummary.canonicalWorkspacePath($0) == canonical }) == true {
                    self.agentWorldRunSignals[id] = run
                }
            }
            if self.agentWorldRunSignals.count > 64 {
                let recent = self.agentWorldRunSignals.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(64)
                self.agentWorldRunSignals = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) })
            }
        }
    }
}
