import Combine
import Foundation

enum WorkMode: String, CaseIterable, Codable, Identifiable {
    case ask
    case work
    case plan
    case build

    var id: String { rawValue }

    var description: String {
        switch self {
        case .ask: "Answers without workspace access"
        case .work: "Chooses the right approach for the request"
        case .plan: "Maps the work before editing"
        case .build: "Can edit files and run commands"
        }
    }

    var instruction: String {
        switch self {
        case .ask:
            "Answer conversationally using only the conversation and files or images the user explicitly attached to this message. Do not inspect attachment paths or browse, read, search, or modify any other workspace files. Do not call tools, skills, or external integrations."
        case .work:
            "Solve the request using the workspace and tools when useful. Choose whether to answer, inspect, plan, or implement from the request itself. Follow the current permission policy for every action."
        case .plan:
            "Inspect files if useful, but do not modify anything. Ask clarifying questions when needed. When the plan is final and decision-complete, call submit_plan exactly once with its title, summary, ordered steps, and test scenarios; do not call submit_plan for a question or partial plan."
        case .build:
            "Implement the request completely. Inspect, edit, and verify the relevant files, asking for permission when required."
        }
    }
}

/// The answer to the "implement this plan?" prompt that follows a completed
/// Plan-mode turn.
enum PlanApprovalDecision {
    /// Switch to Build mode and implement with the current permissions.
    case proceed
    /// Dismiss the decision and continue refining in Plan mode.
    case revise
    /// Keep the plan for reference and return to adaptive Work.
    case cancel
}

/// A final, decision-complete plan submitted by the model for user approval.
/// Every field has a default so checkpoints and older agents remain tolerant.
struct PlanDocument: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var steps: [String]
    var tests: [String]

    init(
        id: String = UUID().uuidString,
        title: String = "Implementation plan",
        summary: String = "",
        steps: [String] = [],
        tests: [String] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.steps = steps
        self.tests = tests
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, steps, tests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Implementation plan"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        tests = try container.decodeIfPresent([String].self, forKey: .tests) ?? []
    }
}

enum PlanSignalDetector {
    static func document(from text: String, changedTodos: [TodoItem] = []) -> PlanDocument? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagged = taggedPlan(in: trimmed)
        let source = tagged ?? trimmed
        var steps = listItems(in: source)
        if steps.isEmpty { steps = changedTodos.map(\.content) }
        let hasPlanHeading = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let heading = line.trimmingCharacters(in: .whitespaces).lowercased()
                return heading.hasPrefix("#") && heading.contains("plan")
            }
        guard !isClarifyingResponse(source),
              tagged != nil || !changedTodos.isEmpty || (hasPlanHeading && steps.count >= 2),
              !steps.isEmpty
        else { return nil }
        let title = source
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("#") && $0.lowercased().contains("plan") })?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            .nilIfEmpty ?? "Implementation plan"
        return PlanDocument(title: title, summary: source, steps: steps, tests: [])
    }

    private static func taggedPlan(in text: String) -> String? {
        guard let open = text.range(of: "<proposed_plan>"),
              let close = text.range(of: "</proposed_plan>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listItems(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.range(
                of: #"^(?:[-*+]\s+|\d+[.)]\s+)(.+)$"#,
                options: .regularExpression
            ) != nil else { return nil }
            return line.replacingOccurrences(
                of: #"^(?:[-*+]\s+|\d+[.)]\s+)"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
    }

    static func isClarifyingResponse(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let question = lines.last(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              question.hasSuffix("?")
        else { return false }
        let lower = question.lowercased()
        if lower.contains("proceed")
            || lower.contains("implement this plan")
            || lower.contains("go ahead with this plan")
        {
            return false
        }
        return lower.hasPrefix("which ")
            || lower.hasPrefix("what ")
            || lower.hasPrefix("would ")
            || lower.hasPrefix("should ")
            || lower.hasPrefix("could ")
            || lower.hasPrefix("do you ")
            || lower.contains("clarify")
    }
}

/// A ready-made prompt offered when the user asks for a plan without having
/// described one. Titles are what the picker shows; prompts are what is sent.
struct PlanPromptSuggestion: Identifiable {
    let title: String
    let prompt: String

    var id: String { title }

    static let curated: [PlanPromptSuggestion] = [
        PlanPromptSuggestion(
            title: "Plan the current request",
            prompt: "Create a step-by-step implementation plan for the most recent request in this conversation."
        ),
        PlanPromptSuggestion(
            title: "Fix the latest problem",
            prompt: "Diagnose the most recent error or failing behavior we discussed and plan the fix."
        ),
        PlanPromptSuggestion(
            title: "Improve this codebase",
            prompt: "Review the workspace and plan the highest-impact improvements, ordered so the quickest wins come first."
        ),
        PlanPromptSuggestion(
            title: "Add missing tests",
            prompt: "Identify the most important untested behavior in this workspace and plan the test coverage for it."
        ),
        PlanPromptSuggestion(
            title: "Refactor a rough spot",
            prompt: "Find the most tangled part of the codebase and plan a safe, incremental refactor."
        ),
    ]
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case plan
    case changes
    case files
    case terminal
    case preview
    case checkpoints
    case runs
    case agents

    var id: String { rawValue }

    /// The visible label. Kept separate from `rawValue`, which is reserved for
    /// the accessibility identifier and the persisted preference — so copy can
    /// change without breaking either.
    var title: String {
        switch self {
        case .plan: "Plan"
        case .changes: "Changes"
        case .files: "Files"
        case .terminal: "Console"
        case .preview: "Browser"
        case .checkpoints: "Checkpoints"
        case .runs: "Runs"
        case .agents: "AGENTS.md"
        }
    }

    var symbol: String {
        switch self {
        case .plan: "list.bullet.clipboard"
        case .changes: "plusminus.circle"
        case .files: "folder"
        case .terminal: "terminal"
        case .preview: "globe"
        case .checkpoints: "clock.arrow.circlepath"
        case .runs: "point.3.connected.trianglepath.dotted"
        case .agents: "doc.text.fill"
        }
    }

    /// ⌘1…⌘8, in declaration order. Existing shortcuts stay stable.
    var shortcutKey: Character {
        switch self {
        case .plan: "1"
        case .changes: "2"
        case .files: "3"
        case .terminal: "4"
        case .preview: "5"
        case .checkpoints: "6"
        case .runs: "7"
        case .agents: "8"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case network = "Network"
    case accounts = "Accounts"
    case agents = "Agents & Teams"
    case knowledge = "Knowledge"
    case permissions = "Permissions"
    case extensions = "Extensions"
    case shortcuts = "Keyboard Shortcuts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .network: "network"
        case .accounts: "person.crop.circle"
        case .agents: "person.3.sequence.fill"
        case .knowledge: "books.vertical.fill"
        case .permissions: "lock.shield"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "keyboard"
        }
    }

    var accessibilityKey: String {
        self == .shortcuts ? "shortcuts" : rawValue.lowercased()
    }
}

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
    /// Reasoning renders as collapsed cards that expand per block. Default.
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
        case .collapsed: "Reasoning folds into expandable cards"
        case .expanded: "Reasoning is always open inline"
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
        case .bypass: "Bypass all"
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
        case .bypass: "bolt"
        }
    }

    /// Short label for the always-visible indicator.
    var shortTitle: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Auto-edit"
        case .bypass: "Bypass"
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
            permissions: permissions
        )
    }

    enum CodingKeys: String, CodingKey {
        case model, host, cwd, session, messages, provider, permissions, task
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
        permissions = (try? container.decodeIfPresent(SessionPermissions.self, forKey: .permissions))
            ?? SessionPermissions(skipAll: false, allowed: [])
    }
}

struct ModelInfo: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let size: Int64
    let parameterSize: String
    /// The window the model is actually running in — 0 when it is not loaded
    /// or the agent cannot tell. This is what sessions are metered against.
    let contextLength: Int
    /// The window the model was built for; the number to compare models by.
    let trainedContextLength: Int
    /// Whether the model accepts image input. Ollama states it outright; a
    /// remote listing says nothing, so nil means "not known", never a guess.
    let visionCapable: Bool?

    enum CodingKeys: String, CodingKey {
        case name, size
        case parameterSize = "parameter_size"
        case contextLength = "context_length"
        case trainedContextLength = "trained_context_length"
        case visionCapable = "vision"
    }

    init(
        name: String,
        size: Int64,
        parameterSize: String,
        contextLength: Int,
        trainedContextLength: Int = 0,
        visionCapable: Bool? = nil
    ) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
        self.contextLength = contextLength
        self.trainedContextLength = trainedContextLength
        self.visionCapable = visionCapable
    }

    // Only the name is essential; a model whose metadata is missing must
    // still appear in the picker rather than vanish from the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        parameterSize = try container.decodeIfPresent(String.self, forKey: .parameterSize) ?? ""
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? 0
        trainedContextLength = try container.decodeIfPresent(Int.self, forKey: .trainedContextLength) ?? 0
        visionCapable = try container.decodeIfPresent(Bool.self, forKey: .visionCapable)
    }

    var detail: String {
        // The picker compares models, so it shows the trained window; older
        // agents only report the single context_length, which fills in.
        let window = trainedContextLength > 0 ? trainedContextLength : contextLength
        let context = window > 0 ? "\(max(window / 1024, 1))k ctx" : ""
        return [parameterSize, context].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SessionSummary: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let preview: String
    let mtime: Double
    let size: Int
    let title: String?
    let pinned: Bool?
    let archived: Bool?
    /// Folder-backed workspace recorded in the transcript's leading meta row.
    /// Optional so sessions created by older agents remain visible.
    let cwd: String?
    let task: TaskRecord?
    let team: SessionTeamReference?
    let workspaceRoot: String?
    let executionPath: String?
    let environment: [String: String]?

    init(
        id: String,
        name: String,
        preview: String,
        mtime: Double,
        size: Int,
        title: String? = nil,
        pinned: Bool? = nil,
        archived: Bool? = nil,
        cwd: String? = nil,
        task: TaskRecord? = nil,
        team: SessionTeamReference? = nil,
        workspaceRoot: String? = nil,
        executionPath: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.mtime = mtime
        self.size = size
        self.title = title
        self.pinned = pinned
        self.archived = archived
        self.cwd = cwd
        self.task = task
        self.team = team
        self.workspaceRoot = workspaceRoot
        self.executionPath = executionPath
        self.environment = environment
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let trimmed = Self.cleanPreview(preview)
        return trimmed.isEmpty ? "Untitled session" : trimmed
    }

    /// Session previews come from the stored first message, which Locus wraps
    /// with mode headers before sending. Show only the user's own words.
    static func cleanPreview(_ preview: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[Locus mode:") else { return trimmed }
        if let range = trimmed.range(of: "User request:") {
            return trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    var date: Date { Date(timeIntervalSince1970: mtime) }
    var isPinned: Bool { pinned ?? false }
    var isArchived: Bool { archived ?? false }

    var workspacePath: String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return nil
        }
        return Self.canonicalWorkspacePath(cwd)
    }

    static func canonicalWorkspacePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardized) else { return standardized }
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }
}

/// One folder-backed section in the session sidebar. A nil path is the
/// compatibility bucket for transcripts written before workspace provenance.
struct WorkspaceChatGroup: Identifiable, Equatable {
    let id: String
    let path: String?
    let title: String
    let chats: [SessionSummary]
    let lastOpened: Date
    let isAvailable: Bool
    let isOther: Bool
}

/// Transient app notification with an optional user action. The action itself
/// stays in AppModel so this value remains Equatable and safe for SwiftUI.
struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
    let actionTitle: String?

    init(
        message: String,
        systemImage: String = "checkmark",
        actionTitle: String? = nil
    ) {
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
    }
}

struct StreamingReplySnapshot: Equatable {
    var id: UUID?
    var text = ""
    var reasoning = ""
    var turnCharacterCount = 0

    var isActive: Bool { id != nil }
}

/// Token-level state lives outside AppModel's published transcript array.
/// Consequently an append invalidates only the active row and token label,
/// rather than every historical row, sidebar and composer.
@MainActor
final class StreamingReplyState: ObservableObject {
    @Published private(set) var snapshot = StreamingReplySnapshot()

    func begin(id: UUID) {
        var next = snapshot
        next.id = id
        next.text = ""
        next.reasoning = ""
        snapshot = next
    }

    func append(text: String, reasoning: String) {
        guard snapshot.id != nil, !text.isEmpty || !reasoning.isEmpty else { return }
        var next = snapshot
        next.text += text
        next.reasoning += reasoning
        next.turnCharacterCount += text.count + reasoning.count
        snapshot = next
    }

    func finish(id: UUID) -> StreamingReplySnapshot? {
        guard snapshot.id == id else { return nil }
        let finished = snapshot
        snapshot = StreamingReplySnapshot(
            id: nil,
            text: "",
            reasoning: "",
            turnCharacterCount: finished.turnCharacterCount
        )
        return finished
    }

    func resetTurn() {
        snapshot = StreamingReplySnapshot()
    }
}

struct HealthResponse: Codable {
    let ok: Bool
    let version: String?
    let ollama: Bool
    let host: String?
    let model: String?
    let error: String?
    let updateAvailable: Bool?
}

struct HistoryMessage: Codable {
    let role: String
    let content: String
    let name: String?
    let reasoning: String?
    let teamRunID: String?

    private enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning
        case teamRunID = "team_run_id"
    }

    // A single null-content tool message must not fail an entire resume.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        teamRunID = try? container.decodeIfPresent(String.self, forKey: .teamRunID)
    }
}

enum ToolStatus: String, Codable {
    case awaitingPermission
    case running
    case done
    case error
    case denied
}

struct ToolPayload: Codable, Hashable {
    var toolID: String
    var tool: String
    var summary: String
    var detail: String
    var status: ToolStatus
    var requestID: String?
    var result: String?
}

struct ChatBlock: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case user
        case assistant
        case tool
        case note
        case error
    }

    var id: UUID
    var kind: Kind
    var text: String
    /// Native provider reasoning, kept separate from visible answer text.
    /// Optional decoding keeps existing checkpoints readable.
    var reasoningText: String?
    var isStreaming: Bool
    var tool: ToolPayload?
    /// Present only for the quiet end-of-turn note rendered after a run.
    /// Optional keeps checkpoints written by older Locus releases decodable.
    var completion: TurnCompletion?
    /// Links a team request to its durable board without changing ordinary
    /// transcript rendering. Optional decoding keeps existing checkpoints.
    var teamRunID: String?
    /// Position in the restored message array, so a cross-session search hit
    /// can address this block even after empty messages were dropped.
    /// Optional decoding keeps existing checkpoints.
    var historyIndex: Int?

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        reasoningText: String? = nil,
        isStreaming: Bool = false,
        tool: ToolPayload? = nil,
        completion: TurnCompletion? = nil,
        teamRunID: String? = nil,
        historyIndex: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.reasoningText = reasoningText
        self.isStreaming = isStreaming
        self.tool = tool
        self.completion = completion
        self.teamRunID = teamRunID
        self.historyIndex = historyIndex
    }
}

/// One `/api/sessions/search` hit — a message position inside a saved session.
struct TranscriptSearchHit: Codable, Hashable, Identifiable {
    let sessionID: String
    let title: String?
    let pinned: Bool
    let mtime: Double
    let messageIndex: Int
    let role: String
    let snippet: String
    /// `[start, length]` character ranges inside `snippet` to emphasize.
    let highlights: [[Int]]
    let score: Double

    var id: String { "\(sessionID):\(messageIndex)" }

    enum CodingKeys: String, CodingKey {
        case title, pinned, mtime, role, snippet, highlights, score
        case sessionID = "session_id"
        case messageIndex = "message_index"
    }

    /// The first term the index actually matched — by construction it appears
    /// verbatim in the message text, so it can drive the in-conversation find.
    var firstMatchedTerm: String? {
        guard let range = stringRange(of: highlights.first) else { return nil }
        return String(snippet[range])
    }

    /// Highlight offsets are Python `str` positions — Unicode scalars, not
    /// Swift's grapheme clusters — so index math must run on the scalar view
    /// or any emoji in a snippet shifts every later highlight.
    func stringRange(of highlight: [Int]?) -> Range<String.Index>? {
        guard let highlight, highlight.count == 2 else { return nil }
        let scalars = snippet.unicodeScalars
        guard let start = scalars.index(
            scalars.startIndex, offsetBy: highlight[0], limitedBy: scalars.endIndex
        ), let end = scalars.index(
            start, offsetBy: highlight[1], limitedBy: scalars.endIndex
        ) else { return nil }
        return start..<end
    }
}

struct TranscriptSearchResponse: Codable {
    let query: String
    let indexing: Bool
    let results: [TranscriptSearchHit]
}

struct ContextFile: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    var content: String
    var isIncluded: Bool
    var modificationDate: Date?
    var issue: String?

    init(
        id: UUID = UUID(),
        url: URL,
        content: String = "",
        isIncluded: Bool = true,
        modificationDate: Date? = nil,
        issue: String? = nil
    ) {
        self.id = id
        self.url = url
        self.content = content
        self.isIncluded = isIncluded
        self.modificationDate = modificationDate
        self.issue = issue
    }

    var name: String { url.lastPathComponent }
    var displayPath: String { url.path(percentEncoded: false) }
    var estimatedTokens: Int { max(content.count / 4, 1) }
    var isAvailable: Bool { issue == nil && !content.isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, url, isIncluded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decode(URL.self, forKey: .url)
        content = ""
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? true
        modificationDate = nil
        issue = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(isIncluded, forKey: .isIncluded)
    }
}

enum ChatAttachmentKind: String, Hashable, Sendable {
    case text
    case image
}

/// An explicitly selected, one-message input for the composer, valid in every
/// mode. Unlike a Work context pack, these attachments do not grant access to
/// their path or to any neighboring workspace files, and they are removed
/// after a successful send.
struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let kind: ChatAttachmentKind
    let textContent: String?
    let imageData: Data?
    let mimeType: String?
    let issue: String?
    /// Display name for content with no real file behind it (pasted images);
    /// the synthesized `url` then only provides Hashable/dedupe identity.
    let overrideName: String?

    init(
        id: UUID = UUID(),
        url: URL,
        kind: ChatAttachmentKind,
        textContent: String? = nil,
        imageData: Data? = nil,
        mimeType: String? = nil,
        issue: String? = nil,
        overrideName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.textContent = textContent
        self.imageData = imageData
        self.mimeType = mimeType
        self.issue = issue
        self.overrideName = overrideName
    }

    static func pasted(imageData: Data, mimeType: String, date: Date = Date()) -> ChatAttachment {
        let stamp = date.formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
        let fileExtension = mimeType.split(separator: "/").last.map(String.init) ?? "png"
        let identity = UUID()
        return ChatAttachment(
            id: identity,
            url: URL(fileURLWithPath: "/dev/null/pasted-\(identity.uuidString).\(fileExtension)"),
            kind: .image,
            imageData: imageData,
            mimeType: mimeType,
            overrideName: "Pasted image \(stamp).\(fileExtension)"
        )
    }

    var name: String { overrideName ?? url.lastPathComponent }
    var isAvailable: Bool {
        guard issue == nil else { return false }
        switch kind {
        case .text: return !(textContent?.isEmpty ?? true)
        case .image: return !(imageData?.isEmpty ?? true) && mimeType != nil
        }
    }

    var detail: String {
        if let issue { return issue }
        switch kind {
        case .text:
            return "\(max((textContent?.count ?? 0) / 4, 1).formatted()) estimated tokens"
        case .image:
            return ByteCountFormatter.string(
                fromByteCount: Int64(imageData?.count ?? 0),
                countStyle: .file
            )
        }
    }
}

struct SessionCheckpoint: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let createdAt: Date
    let blocks: [ChatBlock]
    let todos: [TodoItem]
    let contextFiles: [ContextFile]
    let workspacePath: String
    let model: String
    /// Optional so checkpoints written before structured plans remain valid.
    var activePlan: PlanDocument? = nil
}

enum ModelProvider: String, Codable, CaseIterable, Identifiable {
    case ollama
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Local Ollama"
        case .remote: "Remote endpoint"
        }
    }

    var detail: String {
        switch self {
        case .ollama: "Models installed on this Mac"
        case .remote: "A Hugging Face endpoint, vLLM, or TGI on a rented GPU"
        }
    }
}

/// How outbound traffic leaves the machine. `off` is the pre-proxy behavior:
/// the app's own requests follow macOS system settings on their own, and the
/// agent keeps whatever environment the shell provided.
enum ProxyMode: String, CaseIterable {
    case off
    case system
    case manual
}

enum ProxyType: String, CaseIterable {
    case http
    case socks5
}

struct AppSettings: Codable, Hashable {
    var backendURL = "http://127.0.0.1:8791"
    var backendRoot = NSString(string: "~/Documents/locus/agent").expandingTildeInPath
    var previewURL = "http://localhost:3000"
    var notifyOnCompletion = true
    var provider: ModelProvider = .ollama
    /// Endpoint base URL. The API key is not stored here — see `CredentialStore`.
    ///
    /// Superseded by provider accounts: the migration moves this into a
    /// `.custom` account on first launch. Kept so a downgrade still decodes.
    var remoteBaseURL = ""
    var remoteModel = ""
    /// The provider account in use, as a UUID string, or nil for local Ollama.
    /// The accounts themselves live under `ProviderAccountStore.defaultsKey` —
    /// they carry credential-file side effects that must not ride the settings draft.
    var activeAccountID: String?
    /// A context window for local Ollama, when the user wants to pin one
    /// exactly rather than let Locus choose from the model's own ceiling.
    var localContextWindow: Int?
    /// Tool steps one turn may take. nil uses the agent's default of 40. Exposed
    /// because a bad value here is otherwise undiagnosable from inside the app:
    /// the turn just stops, and until this setting existed the only way to see
    /// or change the number was to hand-edit the agent's config file.
    var maxIterations: Int?
    var inspectorWidth: Double = AppSettings.defaultInspectorWidth
    /// The inspector starts collapsed: the conversation is the point, and
    /// ⌘1–⌘8 or ⌘⌥I bring the panel back the moment it is needed.
    var inspectorCollapsed = true
    /// The session sidebar starts open, the way Claude keeps the
    /// conversation list at hand; ⌘0 collapses it for focus.
    var sidebarCollapsed = false
    /// Stored as a raw string, not the enum: an unknown tab from a future
    /// version would otherwise fail the whole settings decode and reset
    /// everything else with it.
    var inspectorLastTab = InspectorTab.plan.rawValue
    /// Raw string for the same forward-compatibility reason as the tab.
    var thinkingVisibilityRaw = ThinkingVisibility.collapsed.rawValue
    /// One-time compatibility marker: releases before adaptive Work persisted
    /// Build because an agentic mode was mandatory, not necessarily chosen.
    var adaptiveWorkMigrationCompleted = false
    /// Computer control is opt-in and is ignored in sandboxed builds.
    var computerControlEnabled = false
    /// The browser is on by default and, unlike computer control, works in the
    /// sandboxed App Store build too — a web view needs no special access.
    var browserEnabled = true
    /// Raw string, like the tab: an unknown preset from a future version must
    /// not fail the whole settings decode.
    var browserViewportRaw = BrowserViewport.desktop.rawValue
    /// Cookies and logins survive relaunch only when the user opts in; the
    /// default forgets everything when the app quits, because an agent that
    /// can browse anywhere should not quietly accumulate a signed-in profile.
    var browserPersistProfile = false
    /// OpenTelemetry export is explicit and disabled by default. Endpoint
    /// authorization lives in CredentialStore, never in these settings.
    var otlpExportEnabled = false
    var otlpEndpoint = ""
    var otlpIncludeContent = false
    /// Raw strings, like the tab: an unknown mode or type saved by a future
    /// version must not fail the whole settings decode.
    var proxyModeRaw = ProxyMode.off.rawValue
    var proxyTypeRaw = ProxyType.http.rawValue
    /// Hostname or IP only — a pasted scheme or path is stripped on save.
    var proxyHost = ""
    /// nil is "not configured", which manual mode refuses to save. There is no
    /// default port, because guessing one would silently send traffic somewhere.
    var proxyPort: Int?
    /// Comma- or space-separated hosts that connect directly. Loopback, the
    /// agent, and the Ollama host are always direct without being listed here.
    var proxyBypass = ""
    /// Non-empty means the proxy requires sign-in. The password is not stored
    /// in settings — see `CredentialStore.proxyPassword`.
    var proxyUsername = ""

    static let defaultInspectorWidth: Double = 340
    static let minimumInspectorWidth: Double = 280
    static let maximumInspectorWidth: Double = 520

    static func clampInspectorWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultInspectorWidth }
        return min(max(width, minimumInspectorWidth), maximumInspectorWidth)
    }

    /// Ports outside 1...65535 read back as "not configured" rather than as a
    /// number the proxy layer would then try to dial.
    static func clampProxyPort(_ port: Int?) -> Int? {
        guard let port, (1...65535).contains(port) else { return nil }
        return port
    }

    var resolvedInspectorTab: InspectorTab {
        InspectorTab(rawValue: inspectorLastTab) ?? .plan
    }

    var resolvedBrowserViewport: BrowserViewport {
        BrowserViewport(rawValue: browserViewportRaw) ?? .desktop
    }

    var resolvedProxyMode: ProxyMode {
        ProxyMode(rawValue: proxyModeRaw) ?? .off
    }

    var resolvedProxyType: ProxyType {
        ProxyType(rawValue: proxyTypeRaw) ?? .http
    }

    var resolvedThinkingVisibility: ThinkingVisibility {
        ThinkingVisibility(rawValue: thinkingVisibilityRaw) ?? .collapsed
    }

    init() {}

    // Tolerant decoding so settings saved by older versions keep their values
    // when new fields are added instead of being reset to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        backendURL = try container.decodeIfPresent(String.self, forKey: .backendURL) ?? defaults.backendURL
        backendRoot = try container.decodeIfPresent(String.self, forKey: .backendRoot) ?? defaults.backendRoot
        previewURL = try container.decodeIfPresent(String.self, forKey: .previewURL) ?? defaults.previewURL
        notifyOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion)
            ?? defaults.notifyOnCompletion
        provider = try container.decodeIfPresent(ModelProvider.self, forKey: .provider)
            ?? defaults.provider
        remoteBaseURL = try container.decodeIfPresent(String.self, forKey: .remoteBaseURL)
            ?? defaults.remoteBaseURL
        remoteModel = try container.decodeIfPresent(String.self, forKey: .remoteModel)
            ?? defaults.remoteModel
        activeAccountID = try container.decodeIfPresent(String.self, forKey: .activeAccountID)
            ?? defaults.activeAccountID
        localContextWindow = try container.decodeIfPresent(Int.self, forKey: .localContextWindow)
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations)
        // Clamped on the way in as well as on the way out: a corrupt or
        // out-of-range stored value must not produce an unusable panel.
        inspectorWidth = Self.clampInspectorWidth(
            try container.decodeIfPresent(Double.self, forKey: .inspectorWidth)
                ?? defaults.inspectorWidth
        )
        inspectorCollapsed = try container.decodeIfPresent(Bool.self, forKey: .inspectorCollapsed)
            ?? defaults.inspectorCollapsed
        sidebarCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed)
            ?? defaults.sidebarCollapsed
        inspectorLastTab = try container.decodeIfPresent(String.self, forKey: .inspectorLastTab)
            ?? defaults.inspectorLastTab
        thinkingVisibilityRaw = try container.decodeIfPresent(String.self, forKey: .thinkingVisibilityRaw)
            ?? defaults.thinkingVisibilityRaw
        adaptiveWorkMigrationCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .adaptiveWorkMigrationCompleted
        ) ?? defaults.adaptiveWorkMigrationCompleted
        computerControlEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .computerControlEnabled
        ) ?? defaults.computerControlEnabled
        browserEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserEnabled)
            ?? defaults.browserEnabled
        browserViewportRaw = try container.decodeIfPresent(String.self, forKey: .browserViewportRaw)
            ?? defaults.browserViewportRaw
        browserPersistProfile = try container.decodeIfPresent(
            Bool.self,
            forKey: .browserPersistProfile
        ) ?? defaults.browserPersistProfile
        otlpExportEnabled = try container.decodeIfPresent(Bool.self, forKey: .otlpExportEnabled)
            ?? defaults.otlpExportEnabled
        otlpEndpoint = try container.decodeIfPresent(String.self, forKey: .otlpEndpoint)
            ?? defaults.otlpEndpoint
        otlpIncludeContent = try container.decodeIfPresent(Bool.self, forKey: .otlpIncludeContent)
            ?? defaults.otlpIncludeContent
        proxyModeRaw = try container.decodeIfPresent(String.self, forKey: .proxyModeRaw)
            ?? defaults.proxyModeRaw
        proxyTypeRaw = try container.decodeIfPresent(String.self, forKey: .proxyTypeRaw)
            ?? defaults.proxyTypeRaw
        proxyHost = try container.decodeIfPresent(String.self, forKey: .proxyHost)
            ?? defaults.proxyHost
        // Clamped on the way in like the inspector width: a corrupt port must
        // read as unconfigured, not as a destination.
        proxyPort = Self.clampProxyPort(
            try container.decodeIfPresent(Int.self, forKey: .proxyPort)
        )
        proxyBypass = try container.decodeIfPresent(String.self, forKey: .proxyBypass)
            ?? defaults.proxyBypass
        proxyUsername = try container.decodeIfPresent(String.self, forKey: .proxyUsername)
            ?? defaults.proxyUsername
    }
}

struct PermissionStateResponse: Codable {
    let mode: String
    let skipAll: Bool
    let allowed: [String]

    enum CodingKeys: String, CodingKey {
        case mode, allowed
        case skipAll = "skip_all"
    }
}

// MARK: - Extensions

struct ExtensionCapabilities: Codable, Hashable {
    var streamableHTTP = true
    var stdio = false
    var oauth = true
    var mcpApps = false
    var hooks = false
    var sandboxed = false

    enum CodingKeys: String, CodingKey {
        case stdio, oauth, hooks, sandboxed
        case streamableHTTP = "streamable_http"
        case mcpApps = "mcp_apps"
    }
}

struct ExtensionMarketplace: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let source: String
    let error: String?
    let workspaceDiscovered: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, source, error
        case workspaceDiscovered = "workspace_discovered"
    }
}

struct ExtensionMCPComponent: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]?
    let cwd: String?
}

struct ExtensionSkill: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let description: String
    let source: String
    let pluginID: String?
    let allowImplicitInvocation: Bool?
    let enabled: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, source, enabled, error
        case displayName = "display_name"
        case pluginID = "plugin_id"
        case allowImplicitInvocation = "allow_implicit_invocation"
    }
}

struct ExtensionPlugin: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let description: String?
    let version: String?
    let author: String?
    let digest: String?
    let enabledGlobal: Bool
    let enabledWorkspaces: [String]
    let disabledWorkspaces: [String]
    let previousVersions: [String]?
    let skills: [ExtensionSkill]?
    let mcpServers: [ExtensionMCPComponent]?
    let scripts: [String]?
    let unsupported: [String]?
    let updateAvailable: Bool?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, author, digest, skills, scripts, unsupported, error
        case displayName = "display_name"
        case enabledGlobal = "enabled_global"
        case enabledWorkspaces = "enabled_workspaces"
        case disabledWorkspaces = "disabled_workspaces"
        case previousVersions = "previous_versions"
        case mcpServers = "mcp_servers"
        case updateAvailable = "update_available"
    }
}

struct ExtensionMCPServer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let origin: String?
    let pluginID: String?
    let active: Bool?
    let enabled: Bool?
    let enabledGlobal: Bool?
    let enabledWorkspaces: [String]?
    let disabledWorkspaces: [String]?
    let state: String?
    let error: String?
    let toolCount: Int?
    let hasCredentials: Bool?
    let approvalMode: String?
    let auth: String?
    let oauth: MCPOAuthConfiguration?

    enum CodingKeys: String, CodingKey {
        case id, name, transport, url, command, args, cwd, origin, active, enabled, state, error, auth, oauth
        case pluginID = "plugin_id"
        case enabledGlobal = "enabled_global"
        case enabledWorkspaces = "enabled_workspaces"
        case disabledWorkspaces = "disabled_workspaces"
        case toolCount = "tool_count"
        case hasCredentials = "has_credentials"
        case approvalMode = "approval_mode"
    }
}

struct MCPOAuthConfiguration: Codable, Hashable {
    let issuer: String?
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let clientID: String
    let scopes: [String]
    let redirectURI: String?

    enum CodingKeys: String, CodingKey {
        case issuer, scopes
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
    }
}

struct ExtensionsResponse: Codable, Hashable {
    let capabilities: ExtensionCapabilities
    let marketplaces: [ExtensionMarketplace]
    let plugins: [ExtensionPlugin]
    let skills: [ExtensionSkill]
    let mcpServers: [ExtensionMCPServer]
    let errors: [String]
    let pendingUpdates: Int?

    enum CodingKeys: String, CodingKey {
        case capabilities, marketplaces, plugins, skills, errors
        case mcpServers = "mcp_servers"
        case pendingUpdates = "pending_updates"
    }

    static let empty = ExtensionsResponse(
        capabilities: ExtensionCapabilities(),
        marketplaces: [],
        plugins: [],
        skills: [],
        mcpServers: [],
        errors: [],
        pendingUpdates: 0
    )
}

struct ExtensionCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let description: String?
    let category: String?
    let marketplaceID: String
    let available: Bool
    let installed: Bool
    let installedVersion: String?
    let version: String?
    let author: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, available, installed, version, author, error
        case displayName = "display_name"
        case marketplaceID = "marketplace_id"
        case installedVersion = "installed_version"
    }
}

struct ExtensionCatalogResponse: Codable {
    let entries: [ExtensionCatalogEntry]
}

struct PluginTrustMCPServer: Codable, Hashable {
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let requestedEnv: [String]
    let requestedHeaders: [String]

    enum CodingKeys: String, CodingKey {
        case name, transport, url, command, args, cwd
        case requestedEnv = "requested_env"
        case requestedHeaders = "requested_headers"
    }
}

struct PluginTrustSummary: Codable, Hashable {
    let skills: Int
    let skillScripts: [String]
    let mcpServers: [PluginTrustMCPServer]
    let unsupported: [String]

    enum CodingKeys: String, CodingKey {
        case skills, unsupported
        case skillScripts = "skill_scripts"
        case mcpServers = "mcp_servers"
    }
}

struct PluginTrustDescription: Codable, Hashable {
    let name: String
    let displayName: String?
    let description: String?
    let version: String?
    let author: String?

    enum CodingKeys: String, CodingKey {
        case name, description, version, author
        case displayName = "display_name"
    }
}

struct PluginTrustResponse: Codable, Hashable, Identifiable {
    var id: String { digest }
    let plugin: PluginTrustDescription
    let digest: String
    let trust: PluginTrustSummary
    let source: [String: String]?
    let capabilityDiff: PluginCapabilityDiff?

    enum CodingKeys: String, CodingKey {
        case plugin, digest, trust, source
        case capabilityDiff = "capability_diff"
    }
}

struct PluginCapabilityDiff: Codable, Hashable {
    let kind: String
    let requiresRenewedTrust: Bool
    let changes: [String]

    enum CodingKeys: String, CodingKey {
        case kind, changes
        case requiresRenewedTrust = "requires_renewed_trust"
    }
}

struct ExtensionOperationResponse: Codable {
    let ok: Bool
}

struct ProjectContextReloadResponse: Codable {
    let ok: Bool
    let file: String?
}

/// `GET`/`POST /api/config`. Only the fields the app reads back — the route also
/// echoes the model, host and cwd, which the app already knows.
struct ConfigStateResponse: Codable {
    let contextWindow: Int?
    let maxIterations: Int?
    let sessionInfo: SessionInfo?

    enum CodingKeys: String, CodingKey {
        case contextWindow = "context_window"
        case maxIterations = "max_iterations"
        case sessionInfo = "session_info"
    }
}

struct MCPTestResponse: Codable {
    let status: MCPStatusResponse?
}

struct MCPStatusResponse: Codable {
    let id: String
    let name: String
    let state: String
    let error: String?
    let toolCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, state, error
        case toolCount = "tool_count"
    }
}

struct MCPStatusCredentialResponse: Codable {
    let ok: Bool
    let id: String
    let hasCredentials: Bool

    enum CodingKeys: String, CodingKey {
        case ok, id
        case hasCredentials = "has_credentials"
    }
}

struct ExtensionToolMetadata: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let origin: String
    let serverID: String?
    let serverName: String?
    let active: Bool
    let deferred: Bool
    let approvalMode: String?

    enum CodingKeys: String, CodingKey {
        case name, description, origin, active, deferred
        case serverID = "server_id"
        case serverName = "server_name"
        case approvalMode = "approval_mode"
    }
}

struct ExtensionToolsResponse: Codable {
    let tools: [ExtensionToolMetadata]
}

struct ProviderStateResponse: Codable {
    let provider: String
    let host: String
    let model: String
    let remoteBaseURL: String
    let remoteModel: String
    let hasAPIKey: Bool

    enum CodingKeys: String, CodingKey {
        case provider, host, model
        case remoteBaseURL = "remote_base_url"
        case remoteModel = "remote_model"
        case hasAPIKey = "has_api_key"
    }
}

struct WorkspaceProfile: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String
    var lastOpened: Date
    var model: String
    /// The provider account the model belongs to, or nil for local Ollama. A
    /// model name is no longer enough on its own: two accounts can offer the
    /// same one. Optional, so profiles saved before accounts still decode.
    var accountID: String?
    var mode: WorkMode
    var previewURL: String
    var contextFiles: [ContextFile]
    var draft: String
    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

struct SessionMetadataResponse: Codable {
    let ok: Bool
    let id: String
    let title: String
    let pinned: Bool
    let archived: Bool
}
