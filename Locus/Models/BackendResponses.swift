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
    let run: OrchestrationRun
}

struct ScheduleOccurrencesResponse: Codable {
    let occurrences: [ScheduleOccurrence]
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
