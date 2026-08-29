import Combine
import Foundation

struct TodoItem: Codable, Hashable, Identifiable {
    enum Status: String, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    var id: String { "\(content)-\(status.rawValue)" }
    let content: String
    let status: Status
}

/// The terminal state of one user turn. Kept on a transcript block so the
/// small "worked for" marker stays between the turn it closes and whatever
/// the user sends next (and survives local checkpoints).
struct TurnCompletion: Codable, Hashable {
    enum Outcome: String, Codable, Hashable {
        case complete
        case interrupted
        case maxIterations = "max_iterations"
        case modelCallBudget = "model_call_budget"
        case error

        init(reason: String) {
            self = Outcome(rawValue: reason) ?? .complete
        }
    }

    let outcome: Outcome
    let mode: WorkMode?
    let durationMilliseconds: Int
    /// The limit that was reached, when that is why the turn ended. Naming the
    /// number is the whole point: a config carrying `max_iterations: 5` stopped
    /// turns early for a week, and the app said only "Iteration limit reached" —
    /// which reads like the model gave up rather than like a setting to check.
    var iterationLimit: Int?

    var isSuccessful: Bool { outcome == .complete }

    var title: String {
        switch outcome {
        case .complete:
            switch mode {
            case .ask: "Chat finished"
            case .work: "Work finished"
            case .plan: "Plan finished"
            case .build: "Task finished"
            case nil: "Finished"
            }
        case .interrupted: "Stopped"
        case .maxIterations:
            if let iterationLimit, iterationLimit > 0 {
                "Iteration limit reached (\(iterationLimit) steps)"
            } else {
                "Iteration limit reached"
            }
        case .modelCallBudget:
            if let iterationLimit, iterationLimit > 0 {
                "Team call budget reached (\(iterationLimit) calls)"
            } else {
                "Team call budget reached"
            }
        case .error: "Run failed"
        }
    }

    var durationText: String {
        guard durationMilliseconds >= 1_000 else { return "<1s" }
        let seconds = max(Int((Double(durationMilliseconds) / 1_000).rounded()), 1)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s" }
        let hours = minutes / 60
        let minuteRemainder = minutes % 60
        return minuteRemainder == 0 ? "\(hours)h" : "\(hours)h \(minuteRemainder)m"
    }
}

/// How much of the model's streamed reasoning the transcript shows.
enum ThinkingVisibility: String, Codable, CaseIterable, Identifiable {
    /// Reasoning is not rendered at all; a minimal indicator shows while the
    /// model has produced nothing but reasoning.
    case hidden
    /// Reasoning renders as inline summary disclosures at its source position. Default.
    case collapsed
    /// Every reasoning card is open inline.
    case expanded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden: "Hidden"
        case .collapsed: "Collapsed"
        case .expanded: "Expanded"
        }
    }

    var detail: String {
        switch self {
        case .hidden: "Answers only — reasoning is not shown"
        case .collapsed: "Reasoning appears as inline summary disclosures"
        case .expanded: "Reasoning is always open inline"
        }
    }
}

/// How much tool activity the transcript shows. This changes presentation
/// only: every tool block remains in the conversation for permissions,
/// persistence, resume, and export.
enum ToolActivityVisibility: String, Codable, CaseIterable, Identifiable {
    /// One expandable card for every tool call, matching the original UI.
    case verbose
    /// Adjacent calls fold into inline summaries at their source position.
    case collapsed
    /// A generic status line is the only transcript trace of tool activity.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verbose: "Verbose"
        case .collapsed: "Collapsed"
        case .hidden: "Hidden"
        }
    }

    var detail: String {
        switch self {
        case .verbose: "Show every tool call as its own card"
        case .collapsed: "Show adjacent tool calls as inline activity summaries"
        case .hidden: "Show only a generic activity status line"
        }
    }
}

/// How much the agent may do without asking.
enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    /// Every write, command, and fetch asks first.
    case ask
    /// File edits run automatically; commands still ask.
    case acceptEdits = "accept_edits"
    /// Everything runs automatically.
    case bypass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask every time"
        case .acceptEdits: "Accept file edits"
        case .bypass: "Full access"
        }
    }

    var detail: String {
        switch self {
        case .ask: "Approve every file change, command, and fetch before it runs."
        case .acceptEdits: "File edits inside the workspace run automatically. Commands still ask."
        case .bypass: "Every tool runs without asking. Use only in a workspace you can throw away."
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "square.and.pencil"
        case .bypass: "exclamationmark.shield.fill"
        }
    }

    /// Short label for the always-visible indicator.
    var shortTitle: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Auto-edit"
        case .bypass: "Full access"
        }
    }

    var isRisky: Bool { self == .bypass }
}

struct SessionPermissions: Codable, Hashable {
    let skipAll: Bool
    let allowed: [String]
    /// Absent on older agents, which only reported `skip_all`.
    let mode: PermissionMode?

    init(skipAll: Bool, allowed: [String], mode: PermissionMode? = nil) {
        self.skipAll = skipAll
        self.allowed = allowed
        self.mode = mode
    }

    /// Falls back to the boolean when the agent predates permission modes.
    var effectiveMode: PermissionMode {
        mode ?? (skipAll ? .bypass : .ask)
    }

    enum CodingKeys: String, CodingKey {
        case skipAll = "skip_all"
        case allowed
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skipAll = try container.decodeIfPresent(Bool.self, forKey: .skipAll) ?? false
        allowed = try container.decodeIfPresent([String].self, forKey: .allowed) ?? []
        mode = try? container.decodeIfPresent(PermissionMode.self, forKey: .mode)
    }
}

struct SessionInfo: Codable, Hashable {
    let model: String
    let host: String
    let cwd: String
    let session: String
    let sessionID: String
    let messages: Int
    let approxTokens: Int
    let promptTokens: Int
    let completionTokens: Int
    /// The window the agent budgets compaction against. 0 means the backend
    /// could not determine one (remote endpoints report no window).
    let contextLimit: Int
    /// What a conversation may actually occupy, which is what the meter
    /// divides by. Optional: an older agent does not send it.
    let usableTokens: Int?
    /// Where `contextLimit` came from, so an assumed window is never drawn as a
    /// measured one. Optional: an older agent does not send it.
    let contextSource: String?
    let maxIterations: Int
    let hasProjectContext: Bool
    let provider: String?
    let task: TaskRecord?
    let workspaceRoot: String?
    let executionPath: String?
    let environment: [String: String]?
    let permissions: SessionPermissions

    init(
        model: String,
        host: String,
        cwd: String,
        session: String,
        sessionID: String,
        messages: Int,
        approxTokens: Int,
        promptTokens: Int,
        completionTokens: Int,
        contextLimit: Int = 0,
        usableTokens: Int? = nil,
        contextSource: String? = nil,
        maxIterations: Int,
        hasProjectContext: Bool,
        provider: String? = nil,
        task: TaskRecord? = nil,
        workspaceRoot: String? = nil,
        executionPath: String? = nil,
        environment: [String: String]? = nil,
        permissions: SessionPermissions
    ) {
        self.model = model
        self.host = host
        self.cwd = cwd
        self.session = session
        self.sessionID = sessionID
        self.messages = messages
        self.approxTokens = approxTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.contextLimit = contextLimit
        self.usableTokens = usableTokens
        self.contextSource = contextSource
        self.maxIterations = maxIterations
        self.hasProjectContext = hasProjectContext
        self.provider = provider
        self.task = task
        self.workspaceRoot = workspaceRoot
        self.executionPath = executionPath
        self.environment = environment
        self.permissions = permissions
    }

    /// A copy with different permissions, for optimistic local updates.
    ///
    /// Every other field has to be carried across explicitly. `usableTokens` and
    /// `contextSource` were both easy to miss here, and missing them blanked the
    /// context meter for a moment on every permission decision — a bug that
    /// looked like the meter flickering rather than like this function.
    func replacingPermissions(_ permissions: SessionPermissions) -> SessionInfo {
        SessionInfo(
            model: model,
            host: host,
            cwd: cwd,
            session: session,
            sessionID: sessionID,
            messages: messages,
            approxTokens: approxTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            contextLimit: contextLimit,
            usableTokens: usableTokens,
            contextSource: contextSource,
            maxIterations: maxIterations,
            hasProjectContext: hasProjectContext,
            provider: provider,
            task: task,
            workspaceRoot: workspaceRoot,
            executionPath: executionPath,
            environment: environment,
            permissions: permissions
        )
    }

    func replacingTask(_ task: TaskRecord?) -> SessionInfo {
        SessionInfo(
            model: model,
            host: host,
            cwd: cwd,
            session: session,
            sessionID: sessionID,
            messages: messages,
            approxTokens: approxTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            contextLimit: contextLimit,
            usableTokens: usableTokens,
            contextSource: contextSource,
            maxIterations: maxIterations,
            hasProjectContext: hasProjectContext,
            provider: provider,
            task: task,
            workspaceRoot: task?.workspaceRoot ?? workspaceRoot,
            executionPath: task?.executionPath ?? executionPath,
            environment: environment,
            permissions: permissions
        )
    }

    enum CodingKeys: String, CodingKey {
        case model, host, cwd, session, messages, provider, permissions, task, environment
        case sessionID = "session_id"
        case approxTokens = "approx_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case contextLimit = "context_limit"
        case usableTokens = "usable_tokens"
        case contextSource = "context_source"
        case maxIterations = "max_iterations"
        case hasProjectContext = "has_project_context"
        case workspaceRoot = "workspace_root"
        case executionPath = "execution_path"
    }

    // Tolerant decoding: `session_info` arrives on every turn, and a single
    // missing field must not nil the whole struct — that would silently break
    // the workspace path, file index, and permissions display at once.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        session = try container.decodeIfPresent(String.self, forKey: .session) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        messages = try container.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        approxTokens = try container.decodeIfPresent(Int.self, forKey: .approxTokens) ?? 0
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        contextLimit = try container.decodeIfPresent(Int.self, forKey: .contextLimit) ?? 0
        usableTokens = try container.decodeIfPresent(Int.self, forKey: .usableTokens)
        contextSource = try container.decodeIfPresent(String.self, forKey: .contextSource)
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 0
        hasProjectContext = try container.decodeIfPresent(Bool.self, forKey: .hasProjectContext) ?? false
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        task = try? container.decodeIfPresent(TaskRecord.self, forKey: .task)
        workspaceRoot = try? container.decodeIfPresent(String.self, forKey: .workspaceRoot)
        executionPath = try? container.decodeIfPresent(String.self, forKey: .executionPath)
        environment = try? container.decodeIfPresent([String: String].self, forKey: .environment)
        permissions = (try? container.decodeIfPresent(SessionPermissions.self, forKey: .permissions))
            ?? SessionPermissions(skipAll: false, allowed: [])
    }
}
