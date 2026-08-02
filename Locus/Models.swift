import Foundation

enum WorkMode: String, CaseIterable, Codable, Identifiable {
    case ask
    case plan
    case build

    var id: String { rawValue }

    var description: String {
        switch self {
        case .ask: "Answers without workspace access"
        case .plan: "Maps the work before editing"
        case .build: "Can edit files and run commands"
        }
    }

    var instruction: String {
        switch self {
        case .ask:
            "Answer conversationally using only the conversation and files or images the user explicitly attached to this message. Do not inspect attachment paths or browse, read, search, or modify any other workspace files. Do not call tools, skills, or external integrations."
        case .plan:
            "Create a concise, ordered implementation plan. Inspect files if useful, but do not modify anything."
        case .build:
            "Implement the request completely. Inspect, edit, and verify the relevant files, asking for permission when required."
        }
    }
}

enum ExecutionEngine: String, Codable, CaseIterable, Identifiable {
    case classic
    case langgraph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .langgraph: "LangGraph"
        }
    }

    var detail: String {
        switch self {
        case .classic: "Locus's standard single-agent loop"
        case .langgraph: "Durable visual and multi-agent workflows"
        }
    }
}

/// The answer to the "implement this plan?" prompt that follows a completed
/// Plan-mode turn.
enum PlanApprovalDecision {
    /// Switch to Build mode, raise permissions to accept-edits, implement.
    case implementAutoAccepting
    /// Switch to Build mode and implement, approving each edit as it comes.
    case implementReviewing
    /// Dismiss the prompt and stay in Plan mode.
    case keepPlanning
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
    case agents
    case workflows

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
        case .preview: "Preview"
        case .checkpoints: "Checkpoints"
        case .agents: "AGENTS.md"
        case .workflows: "Workflows"
        }
    }

    var symbol: String {
        switch self {
        case .plan: "list.bullet.clipboard"
        case .changes: "plusminus.circle"
        case .files: "folder"
        case .terminal: "terminal"
        case .preview: "safari"
        case .checkpoints: "clock.arrow.circlepath"
        case .agents: "doc.text.fill"
        case .workflows: "point.3.connected.trianglepath.dotted"
        }
    }

    /// ⌘1…⌘7, in declaration order. Existing shortcuts stay stable.
    var shortcutKey: Character {
        switch self {
        case .plan: "1"
        case .changes: "2"
        case .files: "3"
        case .terminal: "4"
        case .preview: "5"
        case .checkpoints: "6"
        case .agents: "7"
        case .workflows: "8"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case extensions = "Extensions"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .extensions: "puzzlepiece.extension"
        }
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
        case error

        init(reason: String) {
            self = Outcome(rawValue: reason) ?? .complete
        }
    }

    let outcome: Outcome
    let mode: WorkMode?
    let durationMilliseconds: Int

    var isSuccessful: Bool { outcome == .complete }

    var title: String {
        switch outcome {
        case .complete:
            switch mode {
            case .ask: "Chat finished"
            case .plan: "Plan finished"
            case .build: "Task finished"
            case nil: "Finished"
            }
        case .interrupted: "Stopped"
        case .maxIterations: "Iteration limit reached"
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
    let maxIterations: Int
    let hasProjectContext: Bool
    let provider: String?
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
        maxIterations: Int,
        hasProjectContext: Bool,
        provider: String? = nil,
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
        self.maxIterations = maxIterations
        self.hasProjectContext = hasProjectContext
        self.provider = provider
        self.permissions = permissions
    }

    /// A copy with different permissions, for optimistic local updates.
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
            maxIterations: maxIterations,
            hasProjectContext: hasProjectContext,
            provider: provider,
            permissions: permissions
        )
    }

    enum CodingKeys: String, CodingKey {
        case model, host, cwd, session, messages, provider, permissions
        case sessionID = "session_id"
        case approxTokens = "approx_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case contextLimit = "context_limit"
        case usableTokens = "usable_tokens"
        case maxIterations = "max_iterations"
        case hasProjectContext = "has_project_context"
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
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 0
        hasProjectContext = try container.decodeIfPresent(Bool.self, forKey: .hasProjectContext) ?? false
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
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

    enum CodingKeys: String, CodingKey {
        case name, size
        case parameterSize = "parameter_size"
        case contextLength = "context_length"
        case trainedContextLength = "trained_context_length"
    }

    init(
        name: String,
        size: Int64,
        parameterSize: String,
        contextLength: Int,
        trainedContextLength: Int = 0
    ) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
        self.contextLength = contextLength
        self.trainedContextLength = trainedContextLength
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

    init(
        id: String,
        name: String,
        preview: String,
        mtime: Double,
        size: Int,
        title: String? = nil,
        pinned: Bool? = nil,
        archived: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.mtime = mtime
        self.size = size
        self.title = title
        self.pinned = pinned
        self.archived = archived
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

    // A single null-content tool message must not fail an entire resume.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
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
    var isStreaming: Bool
    var tool: ToolPayload?
    /// Present only for the quiet end-of-turn note rendered after a run.
    /// Optional keeps checkpoints written by older Locus releases decodable.
    var completion: TurnCompletion?

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        isStreaming: Bool = false,
        tool: ToolPayload? = nil,
        completion: TurnCompletion? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isStreaming = isStreaming
        self.tool = tool
        self.completion = completion
    }
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

/// An explicitly selected, one-message input for Just Chat. Unlike a Work
/// context pack, these attachments do not grant access to their path or to any
/// neighboring workspace files, and they are removed after a successful send.
struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let kind: ChatAttachmentKind
    let textContent: String?
    let imageData: Data?
    let mimeType: String?
    let issue: String?

    init(
        id: UUID = UUID(),
        url: URL,
        kind: ChatAttachmentKind,
        textContent: String? = nil,
        imageData: Data? = nil,
        mimeType: String? = nil,
        issue: String? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.textContent = textContent
        self.imageData = imageData
        self.mimeType = mimeType
        self.issue = issue
    }

    var name: String { url.lastPathComponent }
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

struct AppSettings: Codable, Hashable {
    var backendURL = "http://127.0.0.1:8791"
    var backendRoot = NSString(string: "~/Documents/locus/agent").expandingTildeInPath
    var previewURL = "http://localhost:3000"
    var launchBackendAutomatically = true
    var notifyOnCompletion = true
    var provider: ModelProvider = .ollama
    /// Endpoint base URL. The API key is not stored here — see `Keychain`.
    ///
    /// Superseded by provider accounts: the migration moves this into a
    /// `.custom` account on first launch. Kept so a downgrade still decodes.
    var remoteBaseURL = ""
    var remoteModel = ""
    /// The provider account in use, as a UUID string, or nil for local Ollama.
    /// The accounts themselves live under `ProviderAccountStore.defaultsKey` —
    /// they carry keychain side effects that must not ride the settings draft.
    var activeAccountID: String?
    /// A context window for local Ollama, when the user wants to pin one
    /// rather than let it be measured. nil keeps the measured behaviour.
    var localContextWindow: Int?
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

    static let defaultInspectorWidth: Double = 340
    static let minimumInspectorWidth: Double = 280
    static let maximumInspectorWidth: Double = 520

    static func clampInspectorWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultInspectorWidth }
        return min(max(width, minimumInspectorWidth), maximumInspectorWidth)
    }

    var resolvedInspectorTab: InspectorTab {
        InspectorTab(rawValue: inspectorLastTab) ?? .plan
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
        launchBackendAutomatically = try container.decodeIfPresent(Bool.self, forKey: .launchBackendAutomatically)
            ?? defaults.launchBackendAutomatically
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
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let clientID: String
    let scopes: [String]
    let redirectURI: String?

    enum CodingKeys: String, CodingKey {
        case scopes
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

struct GraphPosition: Codable, Hashable {
    var x: Double
    var y: Double
}

struct GraphModelBinding: Codable, Hashable {
    var accountID: String? = nil
    var model: String? = nil
    var displayHint: String? = nil

    enum CodingKeys: String, CodingKey {
        case model
        case accountID = "account_id"
        case displayHint = "display_hint"
    }
}

struct GraphRouteRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var operation: String
    var path: String = "outputs"
    var value: String
    var target: String

    enum CodingKeys: String, CodingKey {
        case operation, path, value, target
    }

    init(operation: String, path: String = "outputs", value: String, target: String) {
        self.operation = operation
        self.path = path
        self.value = value
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(String.self, forKey: .operation)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? "outputs"
        target = try container.decode(String.self, forKey: .target)
        if let text = try? container.decode(String.self, forKey: .value) {
            value = text
        } else if let number = try? container.decode(Double.self, forKey: .value) {
            value = String(number)
        } else if let flag = try? container.decode(Bool.self, forKey: .value) {
            value = String(flag)
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        try container.encode(path, forKey: .path)
        try container.encode(value, forKey: .value)
        try container.encode(target, forKey: .target)
    }
}

struct GraphNodeConfiguration: Codable, Hashable {
    var prompt: String? = nil
    var tools: [String]? = nil
    var modelBinding: GraphModelBinding? = nil
    var rules: [GraphRouteRule]? = nil
    var retryCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case prompt, tools, rules
        case modelBinding = "model_binding"
        case retryCount = "retry_count"
    }
}

struct GraphPort: Codable, Hashable, Identifiable {
    var id: String
    var type: String
    var multiple: Bool? = nil
}

enum GraphNodeType: String, Codable, CaseIterable, Identifiable {
    case input
    case memory
    case model
    case supervisor
    case agent
    case router
    case toolSet = "tool_set"
    case approval
    case join
    case final

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: "Input"
        case .memory: "Memory"
        case .model: "Model"
        case .supervisor: "Supervisor"
        case .agent: "Agent"
        case .router: "Router"
        case .toolSet: "Tool Set"
        case .approval: "Approval"
        case .join: "Join"
        case .final: "Final Answer"
        }
    }

    var symbol: String {
        switch self {
        case .input: "arrow.right.circle"
        case .memory: "memorychip"
        case .model: "brain"
        case .supervisor: "person.3.sequence"
        case .agent: "person.crop.circle.badge.gearshape"
        case .router: "arrow.triangle.branch"
        case .toolSet: "wrench.and.screwdriver"
        case .approval: "hand.raised"
        case .join: "arrow.triangle.merge"
        case .final: "text.bubble"
        }
    }

    var defaultInputPorts: [GraphPort] {
        switch self {
        case .input: []
        case .memory: [GraphPort(id: "in", type: "state")]
        case .agent: [
            GraphPort(id: "in", type: "any"),
            GraphPort(id: "tool_results", type: "tool_results")
        ]
        case .toolSet: [GraphPort(id: "in", type: "tool_calls")]
        case .join: [GraphPort(id: "in", type: "any", multiple: true)]
        default: [GraphPort(id: "in", type: "any")]
        }
    }

    var defaultOutputPorts: [GraphPort] {
        switch self {
        case .input: [GraphPort(id: "out", type: "state")]
        case .memory, .join: [GraphPort(id: "out", type: "context")]
        case .supervisor, .router: [GraphPort(id: "out", type: "route")]
        case .agent: [
            GraphPort(id: "out", type: "text"),
            GraphPort(id: "tools", type: "tool_calls"),
            GraphPort(id: "final", type: "text")
        ]
        case .toolSet: [GraphPort(id: "out", type: "tool_results")]
        case .approval: [GraphPort(id: "out", type: "approval")]
        default: [GraphPort(id: "out", type: "text")]
        }
    }
}

struct GraphWorkflowNode: Codable, Hashable, Identifiable {
    var id: String
    var type: GraphNodeType
    var label: String
    var position: GraphPosition
    var config: GraphNodeConfiguration
    var inputPorts: [GraphPort]? = nil
    var outputPorts: [GraphPort]? = nil

    enum CodingKeys: String, CodingKey {
        case id, type, label, position, config
        case inputPorts = "input_ports"
        case outputPorts = "output_ports"
    }

    var resolvedInputPorts: [GraphPort] { inputPorts ?? type.defaultInputPorts }
    var resolvedOutputPorts: [GraphPort] { outputPorts ?? type.defaultOutputPorts }
}

struct GraphWorkflowEdge: Codable, Hashable, Identifiable {
    var id: String
    var source: String
    var sourcePort: String
    var target: String
    var targetPort: String

    enum CodingKeys: String, CodingKey {
        case id, source, target
        case sourcePort = "source_port"
        case targetPort = "target_port"
    }
}

struct GraphWorkflowSettings: Codable, Hashable {
    var maxSteps: Int
    var failurePolicy: String

    enum CodingKeys: String, CodingKey {
        case maxSteps = "max_steps"
        case failurePolicy = "failure_policy"
    }
}

struct GraphWorkflowCapabilities: Codable, Hashable {
    let nodeCount: Int?
    let edgeCount: Int?
    let parallelWidth: Int?
    let tools: [String]?
    let providerAccountIDs: [String]?
    let models: [String]?
    let mayMutate: Bool?
    let promptCharacters: Int?
    let promptDigest: String?

    enum CodingKeys: String, CodingKey {
        case tools, models
        case nodeCount = "node_count"
        case edgeCount = "edge_count"
        case parallelWidth = "parallel_width"
        case providerAccountIDs = "provider_account_ids"
        case mayMutate = "may_mutate"
        case promptCharacters = "prompt_characters"
        case promptDigest = "prompt_digest"
    }
}

struct GraphWorkflowCapabilityDiff: Codable, Hashable {
    let firstTrust: Bool?
    let promptsChanged: Bool?
    let toolsAdded: [String]?
    let toolsRemoved: [String]?
    let modelsAdded: [String]?
    let modelsRemoved: [String]?
    let providerAccountsAdded: [String]?
    let providerAccountsRemoved: [String]?
    let mutationBefore: Bool?
    let mutationAfter: Bool?
    let parallelWidthBefore: Int?
    let parallelWidthAfter: Int?
    let changed: Bool?

    enum CodingKeys: String, CodingKey {
        case changed
        case firstTrust = "first_trust"
        case promptsChanged = "prompts_changed"
        case toolsAdded = "tools_added"
        case toolsRemoved = "tools_removed"
        case modelsAdded = "models_added"
        case modelsRemoved = "models_removed"
        case providerAccountsAdded = "provider_accounts_added"
        case providerAccountsRemoved = "provider_accounts_removed"
        case mutationBefore = "mutation_before"
        case mutationAfter = "mutation_after"
        case parallelWidthBefore = "parallel_width_before"
        case parallelWidthAfter = "parallel_width_after"
    }
}

struct GraphWorkflow: Codable, Hashable, Identifiable {
    var schemaVersion: Int
    var id: String
    var slug: String
    var name: String
    var description: String
    var supportedModes: [WorkMode]
    var revision: Int
    var nodes: [GraphWorkflowNode]
    var edges: [GraphWorkflowEdge]
    var settings: GraphWorkflowSettings
    var scope: String?
    var path: String?
    var digest: String?
    var valid: Bool?
    var trusted: Bool?
    var errors: [String]?
    var capabilities: GraphWorkflowCapabilities?
    var capabilityDiff: GraphWorkflowCapabilityDiff?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, revision, nodes, edges, settings
        case scope, path, digest, valid, trusted, errors, capabilities
        case capabilityDiff = "capability_diff"
        case schemaVersion = "schema_version"
        case supportedModes = "supported_modes"
    }

    var isRunnable: Bool { valid != false && trusted != false }
}

struct GraphWorkflowsResponse: Codable {
    let workflows: [GraphWorkflow]
}

struct GraphRunStatePayload: Codable, Hashable {
    let requiredAccountIDs: [String]?
    let final: String?

    enum CodingKeys: String, CodingKey {
        case final
        case requiredAccountIDs = "required_account_ids"
    }
}

struct GraphSideEffect: Codable, Hashable, Identifiable {
    let effectID: String
    let nodeID: String
    let tool: String
    let preview: String
    let status: String
    let result: String
    let createdAt: String
    let updatedAt: String

    var id: String { effectID }

    enum CodingKeys: String, CodingKey {
        case tool, preview, status, result
        case effectID = "effect_id"
        case nodeID = "node_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GraphRunSummary: Codable, Hashable, Identifiable {
    let id: String
    let sessionID: String
    let workflowID: String
    let workflowDigest: String
    let mode: WorkMode
    let goal: String
    let status: String
    let state: GraphRunStatePayload
    let error: String
    let createdAt: String
    let updatedAt: String
    let sideEffects: [GraphSideEffect]?

    enum CodingKeys: String, CodingKey {
        case id, mode, goal, status, state, error
        case sideEffects = "side_effects"
        case sessionID = "session_id"
        case workflowID = "workflow_id"
        case workflowDigest = "workflow_digest"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GraphRunsResponse: Codable {
    let runs: [GraphRunSummary]
}

struct LangGraphStatusResponse: Codable {
    let available: Bool
    let version: String
    let checkpointVersion: String
    let error: String
    let activeRun: GraphRunSummary?
    let recoverableRuns: [GraphRunSummary]

    enum CodingKeys: String, CodingKey {
        case available, version, error
        case checkpointVersion = "checkpoint_version"
        case activeRun = "active_run"
        case recoverableRuns = "recoverable_runs"
    }
}

struct GraphOperationResponse: Codable {
    let ok: Bool
}

struct GraphWorkflowOperationResponse: Codable {
    let ok: Bool
    let workflow: GraphWorkflow
}

struct GraphNodeActivity: Identifiable, Hashable {
    var id: String { nodeID }
    let nodeID: String
    var agent: String
    var status: String
    var output: String
    var durationMilliseconds: Int?
    var error: String?
    var model: String? = nil
    var promptTokens: Int? = nil
    var completionTokens: Int? = nil
    var contextLimit: Int? = nil
    var isFinal: Bool = false
}

struct GraphReviewRequest: Identifiable, Hashable {
    var id: String { requestID }
    let requestID: String
    let runID: String
    let nodeID: String
    let title: String
    let message: String
    let summary: String
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
    var executionEngine: ExecutionEngine? = nil
    var planWorkflowID: String? = nil
    var buildWorkflowID: String? = nil

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
