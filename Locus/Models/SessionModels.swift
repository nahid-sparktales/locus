import Combine
import Foundation

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
    let folderID: String?
    let sortOrder: Int?

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
        environment: [String: String]? = nil,
        folderID: String? = nil,
        sortOrder: Int? = nil
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
        self.folderID = folderID
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name, preview, mtime, size, title, pinned, archived, cwd, task, team, environment
        case workspaceRoot = "workspace_root"
        case executionPath = "execution_path"
        case folderID = "folder_id"
        case sortOrder = "sort_order"
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let trimmed = Self.cleanPreview(preview)
        return trimmed.isEmpty ? "Untitled session" : trimmed
    }

    var executionEnvironment: ChatExecutionEnvironment {
        if environment?["type"] == ChatExecutionEnvironment.worktree.rawValue
            || environment?["isolation"] == "managed_worktree" {
            return .worktree
        }
        return .local
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

    func withOrganization(folderID: String?, sortOrder: Int?) -> SessionSummary {
        SessionSummary(
            id: id,
            name: name,
            preview: preview,
            mtime: mtime,
            size: size,
            title: title,
            pinned: pinned,
            archived: archived,
            cwd: cwd,
            task: task,
            team: team,
            workspaceRoot: workspaceRoot,
            executionPath: executionPath,
            environment: environment,
            folderID: folderID,
            sortOrder: sortOrder
        )
    }

    static func canonicalWorkspacePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardized) else { return standardized }
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }
}

struct ChatFolderRecord: Codable, Hashable, Identifiable {
    let id: String
    let workspace: String
    let parentID: String?
    let name: String
    let order: Int

    enum CodingKeys: String, CodingKey {
        case id, workspace, name, order
        case parentID = "parent_id"
    }
}

struct ChatFoldersResponse: Codable {
    let version: Int
    let folders: [ChatFolderRecord]
}

struct ChatFolderMutationResponse: Codable {
    let ok: Bool
    let folder: ChatFolderRecord
}

struct ChatFolderDeleteResponse: Codable {
    let ok: Bool
    let id: String
    let promotedTo: String?

    enum CodingKeys: String, CodingKey {
        case ok, id
        case promotedTo = "promoted_to"
    }
}

struct ChatPlacement: Codable, Hashable {
    let sessionID: String
    let workspace: String
    let folderID: String?
    let order: Int

    enum CodingKeys: String, CodingKey {
        case workspace, order
        case sessionID = "session_id"
        case folderID = "folder_id"
    }
}

struct SessionOrganizationResponse: Codable {
    let ok: Bool
    let placement: ChatPlacement
}

struct DuplicateSessionResponse: Codable {
    let ok: Bool
    let session: SessionSummary
    let mode: String
}

enum ChatExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case markdown
    case plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        }
    }

    var pathExtension: String {
        switch self {
        case .pdf: "pdf"
        case .markdown: "md"
        case .plainText: "txt"
        }
    }
}

struct ChatExportOptions: Equatable {
    var includeReasoning = false
    var includeToolDetails = false
    var includeAttachments = true
}

struct ChatExportAttachment: Codable, Hashable {
    let name: String
    let mimeType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case name, data
        case mimeType = "mime_type"
    }
}

enum AssistantPhase: String, Codable, Hashable {
    case commentary
    case finalAnswer = "final_answer"

    static func resolved(_ rawValue: String?) -> AssistantPhase {
        rawValue.flatMap(AssistantPhase.init(rawValue:)) ?? .finalAnswer
    }
}

struct ChatExportMessage: Codable, Hashable {
    let role: String
    let content: String
    let name: String?
    let reasoning: String?
    let reasoningSections: [String]?
    let phase: AssistantPhase?
    let itemID: String?
    let attachments: [ChatExportAttachment]?

    enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning, phase, attachments
        case reasoningSections = "reasoning_sections"
        case itemID = "item_id"
    }
}

struct ChatExportDocument: Codable, Hashable {
    let id: String
    let title: String
    let cwd: String?
    let model: String?
    let provider: String?
    let started: String?
    let messages: [ChatExportMessage]
}

enum ChatPaneID: String, Codable, CaseIterable, Identifiable {
    case primary
    case secondary

    var id: String { rawValue }
    var other: ChatPaneID { self == .primary ? .secondary : .primary }
}

struct ChatSplitRestoration: Codable, Equatable {
    var primarySessionID: String?
    var secondarySessionID: String?
    var focusedPane: ChatPaneID
    var dividerRatio: Double

    static let empty = ChatSplitRestoration(
        primarySessionID: nil,
        secondarySessionID: nil,
        focusedPane: .primary,
        dividerRatio: 0.5
    )

    var isSplit: Bool { primarySessionID != nil && secondarySessionID != nil }

    func sessionID(for pane: ChatPaneID) -> String? {
        pane == .primary ? primarySessionID : secondarySessionID
    }
}

@MainActor
final class ChatPaneState: ObservableObject, Identifiable {
    let id: ChatPaneID
    @Published var sessionID: String?
    @Published var blocks: [ChatBlock] = []
    @Published var draft = ""
    @Published var attachments: [ChatAttachment] = []
    @Published var mode: WorkMode = .work
    @Published var selectedTeamID: UUID?
    @Published var soloRouting = false
    @Published var transcriptSearchQuery = ""
    @Published var contextFiles: [ContextFile] = []
    @Published var queuedMessages: [String] = []
    @Published var selectedRouteModel: String?
    @Published var runStatus: TeamRunState?
    @Published var isBusy = false
    @Published var hasPendingPermission = false

    init(id: ChatPaneID, sessionID: String? = nil) {
        self.id = id
        self.sessionID = sessionID
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
    /// The reasoning effort this workspace was last used with, overriding the
    /// account's own default. Optional, so profiles saved before it decode
    /// unchanged; nil and "" both fall back to the account, then to the
    /// model's default.
    var reasoningEffort: String? = nil
    /// Deprecated compatibility field. Solo now delegates adaptively without
    /// a per-workspace switch.
    var soloSwarmEnabled: Bool? = nil
    var landingCheckCommands: [String]? = nil

    var resolvedSoloSwarmEnabled: Bool { soloSwarmEnabled ?? true }

    var resolvedLandingCheckCommands: [String] {
        Array((landingCheckCommands ?? []).filter { !$0.isEmpty }.prefix(8))
    }
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
