import Foundation

struct ModelRoutingPreparedTurn {
    let id = UUID()
    let routeID: String
    let tags: [String]
    let local: Bool
}

struct AutomaticModelRouteCandidate {
    let id: String
    let name: String
    let model: String
    let provider: String
    let accountID: UUID?
    let local: Bool
    let metering: String
    let memoryBytes: Int64
    let current: Bool
    let sampleIDs: [String]

    var payload: [String: Any] {
        [
            "id": id,
            "name": name,
            "model": model,
            "provider": provider,
            "local": local,
            "metering": metering,
            "memory_bytes": memoryBytes,
            "current": current,
            "sample_ids": sampleIDs,
        ]
    }
}

struct ModelsResponse: Codable {
    let models: [ModelInfo]
    let current: String
}

struct SessionsResponse: Codable {
    let sessions: [SessionSummary]
    let current: String
}

struct TaskDetailResponse: Codable {
    let task: TaskRecord
    let tree: String
    let patch: String
    let patchBytes: Int

    enum CodingKeys: String, CodingKey {
        case task, tree, patch
        case patchBytes = "patch_bytes"
    }
}

struct TaskApplyResponse: Codable {
    let task: TaskRecord
    let applied: Bool
    let tree: String
    let paths: [String]
}

struct TaskLandingResponse: Codable {
    let task: TaskRecord
    let destination: String
    let tree: String
    let branch: String?
    let commit: String?
}

struct SimpleActionResponse: Codable {
    let ok: Bool
}

struct OrchestrationMutationResponse: Codable {
    let ok: Bool
    let runID: String

    enum CodingKeys: String, CodingKey {
        case ok
        case runID = "run_id"
    }
}

struct OrchestrationRunsResponse: Codable {
    let runs: [OrchestrationRun]
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case runs
        case readOnly = "read_only"
    }
}

struct SchedulesResponse: Codable {
    let schedules: [ScheduledTask]
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case schedules
        case readOnly = "read_only"
    }
}

struct ScheduleDispatchResponse: Codable {
    let ok: Bool
    let claimed: Bool
    let schedule: ScheduledTask?
    let occurrence: ScheduleOccurrence
    let run: OrchestrationRun?
}

struct ScheduleOccurrencesResponse: Codable {
    let occurrences: [ScheduleOccurrence]
}

struct AutomationExecutionSummary: Codable, Identifiable {
    let id: String
    let state: String
    let automationKind: String?
    let automationID: String?
    let occurrenceID: String?
    let sessionID: String?
    let currentStepID: String?
    let currentRunID: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, state, error
        case automationKind = "automation_kind"
        case automationID = "automation_id"
        case occurrenceID = "occurrence_id"
        case sessionID = "session_id"
        case currentStepID = "current_step_id"
        case currentRunID = "current_run_id"
    }
}

struct AutomationWorkflowActionResponse: Codable {
    let action: String
    let execution: AutomationExecutionSummary
    let run: OrchestrationRun?
    let warning: String?
}

enum AttentionGroup: String, Codable, CaseIterable, Identifiable {
    case decisions
    case recoveries
    case configuration

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AttentionItem: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let group: AttentionGroup
    let sessionID: String?
    let runID: String?
    let workflowExecutionID: String?
    let workflowStepID: String?
    let automationKind: String?
    let automationID: String?
    let title: String
    let detail: String
    let timestamp: Double
    let actions: [String]
    let request: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, kind, group, title, detail, timestamp, actions, request
        case sessionID = "session_id"
        case runID = "run_id"
        case workflowExecutionID = "workflow_execution_id"
        case workflowStepID = "workflow_step_id"
        case automationKind = "automation_kind"
        case automationID = "automation_id"
    }

    init(
        id: String, kind: String, group: AttentionGroup,
        sessionID: String? = nil, runID: String? = nil,
        workflowExecutionID: String? = nil, workflowStepID: String? = nil,
        automationKind: String? = nil, automationID: String? = nil,
        title: String, detail: String, timestamp: Double = Date().timeIntervalSince1970,
        actions: [String], request: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.group = group
        self.sessionID = sessionID
        self.runID = runID
        self.workflowExecutionID = workflowExecutionID
        self.workflowStepID = workflowStepID
        self.automationKind = automationKind
        self.automationID = automationID
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.actions = actions
        self.request = request
    }
}

struct AttentionResponse: Codable {
    let items: [AttentionItem]
    let unresolvedCount: Int
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case unresolvedCount = "unresolved_count"
        case readOnly = "read_only"
    }
}

struct AttentionClearResponse: Codable {
    let ok: Bool
    let clearedCount: Int
    let clearedRunIDs: [String]

    enum CodingKeys: String, CodingKey {
        case ok
        case clearedCount = "cleared_count"
        case clearedRunIDs = "cleared_run_ids"
    }
}

struct CompanionChatDispatchResponse: Codable {
    let ok: Bool
    let claimed: Bool
    let run: OrchestrationRun
}

struct DeleteScheduleResponse: Codable {
    let ok: Bool
    let id: String
}

struct OrchestrationEventsResponse: Codable {
    let runID: String
    let events: [OrchestrationEvent]
    let lastSequence: Int

    enum CodingKeys: String, CodingKey {
        case events
        case runID = "run_id"
        case lastSequence = "last_seq"
    }
}

struct EvaluationSuitesResponse: Codable {
    let suites: [EvaluationSuite]
}

struct EvaluationSuiteResponse: Codable {
    let ok: Bool
    let suite: EvaluationSuite
}

struct EvaluationRunResponse: Codable {
    let ok: Bool
    let evaluationID: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case ok, state
        case evaluationID = "evaluation_id"
    }
}

struct WorkspaceMemoriesResponse: Codable {
    let memories: [WorkspaceMemory]
}

struct WorkspaceMemoryResponse: Codable {
    let ok: Bool
    let memory: WorkspaceMemory
}

struct MemoryExportDocument: Codable {
    let format: String
    let version: Int
    let exportedAt: Double
    let memories: [WorkspaceMemory]

    enum CodingKeys: String, CodingKey {
        case format, version, memories
        case exportedAt = "exported_at"
    }
}

struct MemoryImportResponse: Codable {
    let ok: Bool
    let imported: Int
}

struct NewSessionResponse: Codable {
    let ok: Bool
    let reason: String
    let sessionInfo: SessionInfo

    enum CodingKeys: String, CodingKey {
        case ok, reason
        case sessionInfo = "session_info"
    }
}

struct AgentTargetSessionResponse: Codable {
    let ok: Bool
    let session: SessionSummary
    let created: Bool
}

struct ClearSessionsResponse: Codable {
    let ok: Bool
    let count: Int
    let preservedSessionID: String
    let recoveryPath: String
    let jobActive: Bool

    enum CodingKeys: String, CodingKey {
        case ok, count
        case preservedSessionID = "preserved_session_id"
        case recoveryPath = "recovery_path"
        case jobActive = "job_active"
    }
}

struct DeleteSessionResponse: Codable {
    let ok: Bool
    let id: String
    let trashBatch: String
    let deletedActive: Bool
    let replacementSessionInfo: SessionInfo?

    enum CodingKeys: String, CodingKey {
        case ok, id
        case trashBatch = "trash_batch"
        case deletedActive = "deleted_active"
        case replacementSessionInfo = "replacement_session_info"
    }
}

struct RestoreSessionsResponse: Codable {
    let ok: Bool
    let restored: Int
    let sessionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case ok, restored
        case sessionIDs = "session_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        restored = try container.decode(Int.self, forKey: .restored)
        sessionIDs = try container.decodeIfPresent([String].self, forKey: .sessionIDs) ?? []
    }
}

struct DeletedChatUndo {
    let session: SessionSummary
    let trashBatch: String
    let wasActive: Bool
}

struct ResumeResponse: Codable {
    let ok: Bool
    let text: String
    let messages: [HistoryMessage]
    let sessionInfo: SessionInfo
    let agentActivities: [AgentActivity]
    let orchestrationState: TeamRunState?
    let orchestrationRunID: String?
    let workerID: String?

    enum CodingKeys: String, CodingKey {
        case ok, text, messages
        case sessionInfo = "session_info"
        case agentActivities = "agent_activities"
        case orchestrationState = "orchestration_state"
        case orchestrationRunID = "orchestration_run_id"
        case workerID = "worker_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        messages = try container.decodeIfPresent([HistoryMessage].self, forKey: .messages) ?? []
        sessionInfo = try container.decode(SessionInfo.self, forKey: .sessionInfo)
        agentActivities = try container.decodeIfPresent([AgentActivity].self, forKey: .agentActivities) ?? []
        orchestrationState = try container.decodeIfPresent(TeamRunState.self, forKey: .orchestrationState)
        orchestrationRunID = try container.decodeIfPresent(String.self, forKey: .orchestrationRunID)
        workerID = try container.decodeIfPresent(String.self, forKey: .workerID)
    }
}

struct SessionDetailResponse: Codable {
    let id: String
    let messages: [HistoryMessage]
    let preview: String
    let title: String?
    let pinned: Bool?
    let archived: Bool?
    let cwd: String?
    let model: String?
    let started: String?
    let agentActivities: [AgentActivity]?
    let orchestrationState: TeamRunState?
    let orchestrationRunID: String?
    let workerID: String?
    let task: TaskRecord?
    let team: SessionTeamReference?
    let workspaceRoot: String?
    let executionPath: String?

    enum CodingKeys: String, CodingKey {
        case id, messages, preview, title, pinned, archived, cwd, model, started, task, team
        case agentActivities = "agent_activities"
        case orchestrationState = "orchestration_state"
        case orchestrationRunID = "orchestration_run_id"
        case workerID = "worker_id"
        case workspaceRoot = "workspace_root"
        case executionPath = "execution_path"
    }
}

struct SessionHandoffResponse: Codable {
    let ok: Bool
    let environment: String
    let sessionInfo: SessionInfo
    let task: TaskRecord?
    let applied: Bool
    let paths: [String]

    enum CodingKeys: String, CodingKey {
        case ok, environment, task, applied, paths
        case sessionInfo = "session_info"
    }
}

struct TaskMutationResponse: Codable {
    let ok: Bool
    let task: TaskRecord
}

struct ContextLoadResult: Sendable {
    let files: [ContextFile]
    let notice: String?
}

struct ChatAttachmentLoadResult: Sendable {
    let attachments: [ChatAttachment]
    let notice: String?
}
