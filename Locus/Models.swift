import Foundation

enum WorkMode: String, CaseIterable, Codable, Identifiable {
    case ask
    case plan
    case build

    var id: String { rawValue }

    var description: String {
        switch self {
        case .ask: "Answers without changing files"
        case .plan: "Maps the work before editing"
        case .build: "Can edit files and run commands"
        }
    }

    var instruction: String {
        switch self {
        case .ask:
            "Answer the request using the available context. Do not modify files or run destructive commands."
        case .plan:
            "Create a concise, ordered implementation plan. Inspect files if useful, but do not modify anything."
        case .build:
            "Implement the request completely. Inspect, edit, and verify the relevant files, asking for permission when required."
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
        }
    }

    var symbol: String {
        switch self {
        case .plan: "list.bullet.clipboard"
        case .changes: "plusminus.circle"
        case .files: "folder"
        case .terminal: "terminal"
        case .preview: "safari"
        }
    }

    /// ⌘1…⌘5, in declaration order.
    var shortcutKey: Character {
        switch self {
        case .plan: "1"
        case .changes: "2"
        case .files: "3"
        case .terminal: "4"
        case .preview: "5"
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

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        isStreaming: Bool = false,
        tool: ToolPayload? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isStreaming = isStreaming
        self.tool = tool
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
    /// ⌘1–⌘5 or ⌘⌥I bring the panel back the moment it is needed.
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
